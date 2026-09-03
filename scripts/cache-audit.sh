#!/usr/bin/env bash
# Read-only. Counts what the cache holds, split by signature: a cache.nixos.org-1
# signature means upstream serves it too, no Sig line at all means no client can use it.
set -euo pipefail

BUCKET="${ICEDOS_S3_BUCKET:-icedos-nix-cache-fyi}"
REGION="${AWS_REGION:-eu-central-1}"
W="${1:-cache-audit}"

# One GET per narinfo; the default 10 in flight makes that crawl.
aws configure set default.s3.max_concurrent_requests 64

mkdir -p "$W/narinfo"

# Listed before the narinfos: a NAR uploaded in between then still shows up here,
# so a path being pushed right now cannot look orphaned.
echo "listing nar objects in s3://$BUCKET ..." >&2
aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" --prefix nar/ \
  --query 'Contents[].[Key,Size]' --output text 2>/dev/null \
  | grep -v '^None' | sort >"$W/nar-have.txt" || : >"$W/nar-have.txt"
cut -f1 "$W/nar-have.txt" >"$W/nar-keys.txt"

echo "syncing narinfos from s3://$BUCKET ..." >&2
aws s3 sync "s3://$BUCKET/" "$W/narinfo/" --region "$REGION" \
  --exclude '*' --include '*.narinfo' --only-show-errors

g() { grep -r --include='*.narinfo' "$@" "$W/narinfo" | sort; }
find "$W/narinfo" -name '*.narinfo' | sort  >"$W/all.txt"
g -l '^Sig: cache\.nixos\.org-1:'           >"$W/upstream.txt"
g -L '^Sig: '                               >"$W/unsigned.txt"
g -l '^Sig: icedos:'                        >"$W/icedos.txt"
comm -23 "$W/icedos.txt" "$W/upstream.txt"  >"$W/ours.txt"
cat "$W/upstream.txt" "$W/unsigned.txt" "$W/ours.txt" | sort >"$W/accounted.txt"
comm -23 "$W/all.txt" "$W/accounted.txt"    >"$W/other.txt"

# narinfo file -> the nar key it points at.
xargs -a "$W/all.txt" grep -H '^URL:' 2>/dev/null | sed 's|:URL: |\t|' | sort >"$W/url-map.txt"

# A narinfo whose NAR is gone 404s for every client, and neither the build nor the
# heal job repairs it: both skip paths whose narinfo already exists.
awk -F'\t' 'NR==FNR{have[$0]=1;next} !($2 in have){print $1}' \
  "$W/nar-keys.txt" "$W/url-map.txt" | sort >"$W/dangling-maybe.txt"
# The nar listing predates the narinfo sync, so re-check each: a path pushed in
# between would otherwise look broken.
: >"$W/dangling.txt"
while read -r f; do
  key=$(awk -F'\t' -v f="$f" '$1==f{print $2}' "$W/url-map.txt")
  aws s3api head-object --bucket "$BUCKET" --region "$REGION" --key "$key" >/dev/null 2>&1 \
    || printf '%s\n' "$f" >>"$W/dangling.txt"
done <"$W/dangling-maybe.txt"

# NARs no narinfo points at — what an interrupted prune or upload leaves behind.
awk -F'\t' 'NR==FNR{ref[$2]=1;next} !($1 in ref){print $1"\t"$2}' \
  "$W/url-map.txt" "$W/nar-have.txt" >"$W/orphan-nars.txt"
cut -f1 "$W/orphan-nars.txt" >"$W/orphan.txt"

bytes() { [ -s "$1" ] || { echo 0; return; }
  xargs -a "$1" grep -h '^FileSize:' 2>/dev/null | awk '{s+=$2} END{print s+0}'; }
line() { printf '%-26s %9d %15d %9.2f\n' "$1" "$2" "$3" \
  "$(awk -v b="$3" 'BEGIN{print b/1073741824}')"; }
row() { line "$1" "$(wc -l <"$2")" "$(bytes "$2")"; }

printf '%-26s %9s %15s %9s\n' category paths 'nar bytes' GiB
row 'upstream (deletable)' "$W/upstream.txt"
row 'unsigned (deletable)' "$W/unsigned.txt"
row 'ours, signed'         "$W/ours.txt"
row 'other signer'         "$W/other.txt"
row 'TOTAL'                "$W/all.txt"
echo
printf '%-26s %9s %15s %9s\n' 'broken / waste' objects 'nar bytes' GiB
row  'dangling narinfo'    "$W/dangling.txt"
line 'orphan nar'          "$(wc -l <"$W/orphan.txt")" \
  "$(awk -F'\t' '{s+=$2} END{print s+0}' "$W/orphan-nars.txt")"
echo "lists in $W/" >&2
