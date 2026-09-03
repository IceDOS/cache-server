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

bytes() { [ -s "$1" ] || { echo 0; return; }
  xargs -a "$1" grep -h '^FileSize:' 2>/dev/null | awk '{s+=$2} END{print s+0}'; }
row() { local b; b=$(bytes "$2")
  printf '%-26s %9d %15d %9.2f\n' "$1" "$(wc -l <"$2")" "$b" "$(awk -v b="$b" 'BEGIN{print b/1073741824}')"; }

printf '%-26s %9s %15s %9s\n' category paths 'nar bytes' GiB
row 'upstream (deletable)' "$W/upstream.txt"
row 'unsigned (deletable)' "$W/unsigned.txt"
row 'ours, signed'         "$W/ours.txt"
row 'other signer'         "$W/other.txt"
row 'TOTAL'                "$W/all.txt"
echo "lists in $W/" >&2
