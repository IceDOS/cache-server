#!/usr/bin/env bash
# Stage a module repo's */build*.toml package configs as
# config/90-ext-<repo>-<pkg><variant>.toml pinned to <sha>, printing each staged
# basename. With a changed-files list, only packages owning a changed file stage.
set -euo pipefail

repo="$1"
sha="$2"
changed="${3:-}"

auth=()
[ -n "${GT:-}" ] && auth=(-H "Authorization: Bearer $GT")

tree=$(curl -fsS --retry 3 "${auth[@]}" \
  "https://api.github.com/repos/IceDOS/$repo/git/trees/$sha?recursive=1")

# Nesting-agnostic (apps: modules/<pkg>; hardware: modules/<group>/modules/<pkg>).
# The filename suffix names the variant: build-rc.toml -> <pkg>-rc.
jq -r '.tree[] | select(.path | test("(^|/)build(-[^/]+)?\\.toml$")) | .path' <<<"$tree" |
  while read -r bt; do
    dir=$(dirname "$bt")
    if [ -n "$changed" ] && [ -s "$changed" ]; then
      grep -q "^$dir/" "$changed" || continue
    fi
    fname=$(basename "$bt")
    variant=${fname#build}
    variant=${variant%.toml}
    target="config/90-ext-$repo-$(basename "$dir")$variant.toml"

    curl -fsSL --retry 3 -o "$target" "https://raw.githubusercontent.com/IceDOS/$repo/$sha/$bt"
    sed -i "s|url = \"github:icedos/$repo\"|url = \"github:icedos/$repo/$sha\"|" "$target"
    # A silent no-op sed would float the staged config to main, building content
    # nobody asked for.
    grep -q "github:icedos/$repo/$sha" "$target" ||
      { echo "pin to $sha failed for $target" >&2; rm -f "$target"; exit 1; }
    basename "$target"
  done
