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
for s in ${SETS//,/ }; do
  [ -f "$W/$s.txt" ] || { echo "no $W/$s.txt; run cache-audit.sh first" >&2; exit 1; }
  cat "$W/$s.txt" >>"$W/drop.txt"
done
sort -u -o "$W/drop.txt" "$W/drop.txt"
comm -23 "$W/all.txt" "$W/drop.txt" >"$W/keep.txt"

nars() { [ -s "$1" ] || return 0
  xargs -a "$1" grep -h '^URL:' 2>/dev/null | awk '{print $2}' | sort -u; }
nars "$W/keep.txt" >"$W/nar-keep.txt"
nars "$W/drop.txt" >"$W/nar-drop-all.txt"
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

# delete-objects caps at 1000 keys per call.
split -l 1000 -d -a 5 "$W/delete-keys.txt" "$W/batch-"
for b in "$W"/batch-*; do
  jq -Rn '{Objects: [inputs | {Key: .}], Quiet: true}' <"$b" >"$b.json"
  aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
    --delete "file://$b.json" >/dev/null
  echo "deleted $(wc -l <"$b") keys" >&2
done
echo "done — purge the CDN or clients keep seeing narinfos for objects that are gone." >&2
