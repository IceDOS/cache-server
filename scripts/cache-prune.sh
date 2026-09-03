#!/usr/bin/env bash
# Deletes the sets cache-audit.sh flagged; dry run unless --apply. A NAR two
# store paths share is kept while either path stays.
set -euo pipefail

BUCKET="${ICEDOS_S3_BUCKET:-icedos-nix-cache-fyi}"
REGION="${AWS_REGION:-eu-central-1}"
W="cache-audit"
SETS="upstream,unsigned"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --sets)  SETS="$2"; shift ;;
    *)       W="$1" ;;
  esac
  shift
done

: >"$W/drop.txt"
: >"$W/orphan-drop.txt"
for s in ${SETS//,/ }; do
  [ -f "$W/$s.txt" ] || { echo "no $W/$s.txt; run cache-audit.sh first" >&2; exit 1; }
  # orphan.txt holds nar keys, every other set holds narinfo files.
  if [ "$s" = orphan ]; then cat "$W/$s.txt" >>"$W/orphan-drop.txt"
  else cat "$W/$s.txt" >>"$W/drop.txt"; fi
done
sort -u -o "$W/drop.txt" "$W/drop.txt"
sort -u -o "$W/orphan-drop.txt" "$W/orphan-drop.txt"
comm -23 "$W/all.txt" "$W/drop.txt" >"$W/keep.txt"

nars() { [ -s "$1" ] || return 0
  xargs -a "$1" grep -h '^URL:' 2>/dev/null | awk '{print $2}' | sort -u; }
nars "$W/keep.txt" >"$W/nar-keep.txt"
nars "$W/drop.txt" >"$W/nar-drop-all.txt"
cat "$W/orphan-drop.txt" >>"$W/nar-drop-all.txt"
sort -u -o "$W/nar-drop-all.txt" "$W/nar-drop-all.txt"
comm -23 "$W/nar-drop-all.txt" "$W/nar-keep.txt" >"$W/nar-drop.txt"

sed 's|.*/||' "$W/drop.txt" >"$W/delete-keys.txt"
cat "$W/nar-drop.txt" >>"$W/delete-keys.txt"

shared=$(( $(wc -l <"$W/nar-drop-all.txt") - $(wc -l <"$W/nar-drop.txt") ))
printf 'sets=%s: %s narinfo + %s nar objects to delete (%s nars kept, shared with paths that stay)\n' \
  "$SETS" "$(wc -l <"$W/drop.txt")" "$(wc -l <"$W/nar-drop.txt")" "$shared"

if [ "$APPLY" -ne 1 ]; then
  echo "dry run — keys in $W/delete-keys.txt; re-run with --apply" >&2
  exit 0
fi

# Returns 200 with a per-key Errors array when a delete is denied, so the exit
# code proves nothing; the response body has to be read.
delete_batch() {
  local out n
  out=$(aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" --delete "file://$1")
  [ -n "$out" ] || return 0
  n=$(jq -r '(.Errors // []) | length' <<<"$out")
  [ "$n" -eq 0 ] && return 0
  jq -r '.Errors[] | "  \(.Key): \(.Code) \(.Message)"' <<<"$out" | head -5 >&2
  echo "delete-objects reported $n errors" >&2
  return 1
}

# Probe first: a denied policy otherwise fails silently on every batch. Deleting
# a key that does not exist is a no-op when permitted.
jq -n '{Objects: [{Key: "__prune-permission-probe__"}], Quiet: true}' >"$W/probe.json"
delete_batch "$W/probe.json" || { echo 'no s3:DeleteObject on this bucket; nothing deleted' >&2; exit 1; }

# delete-objects caps at 1000 keys per call.
split -l 1000 -d -a 5 "$W/delete-keys.txt" "$W/batch-"
for b in "$W"/batch-*; do
  jq -Rn '{Objects: [inputs | {Key: .}], Quiet: true}' <"$b" >"$b.json"
  delete_batch "$b.json"
  echo "deleted $(wc -l <"$b") keys" >&2
done
echo "done — purge the CDN or clients keep seeing narinfos for objects that are gone." >&2
if [ -s "$W/dangling.txt" ] && [ "${SETS#*dangling}" != "$SETS" ]; then
  echo "run heal-cache.yml next: those paths are gone from the cache until it re-pushes them." >&2
fi
