#!/usr/bin/env bash

set -e

[ -f nix-private.pem ] || {
  echo "Signing key not found" >/dev/stderr
  exit 1
}

[ -d build ] && rm -r build
mkdir -p build

do_handle_der() {
  der="$1"

  while read store_path; do
    do_verify "$store_path" && continue
    do_sign "$store_path"
  done < <(nix path-info -r "$der")

  nix copy --to "ssh-ng://cache-server" "$der"

  ssh cache-server bash '$HOME/register-gc-root.sh' "$der"
}

do_sign() {
  nix store sign --key-file nix-private.pem "$1"
}

do_verify() {
  nix store verify \
    --no-contents \
    --sigs-needed 1 "$1" \
    --option extra-trusted-public-keys "$(cat nix-public.pem)"
}

icedos_out="$PWD/build/icedos"
mkdir -p "$icedos_out"

[ -d "$PWD/.git" ] && mv "$PWD/.git" "$PWD/.git.bak"
TMPDIR="$icedos_out" nix run .#icedos -- --build \
  --build-args \
  --extra-substituters "$NIX_SUBSTITUTER" \
  --extra-trusted-public-keys "$(cat nix-public.pem)"
[ -d "$PWD/.git.bak" ] && mv "$PWD/.git.bak" "$PWD/.git"

icedos_result="$icedos_out/$(ls "$icedos_out")/result"
do_handle_der "$(readlink "$icedos_result")"
