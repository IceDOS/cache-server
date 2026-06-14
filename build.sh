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

  gc_script="$(nix-store --add ./utils/register-gc-root.sh)"
  nix copy --to "ssh-ng://cache-server" "$gc_script"
  ssh cache-server bash "$gc_script" "$der"
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

# Build base NixOS without substituter, as it's faster locally
cp config/config.toml.base config.toml
nix run .#icedos -- --build --nh-args --no-nom
rm config.toml

# Then switch to the target config
cp config/config.toml.final config.toml

TMPDIR="$icedos_out" nix run .#icedos -- --build \
  --nh-args --no-nom \
  --build-args \
  --extra-substituters "$NIX_SUBSTITUTER" \
  --extra-trusted-public-keys "$(cat nix-public.pem)"
[ -d "$PWD/.git.bak" ] && mv "$PWD/.git.bak" "$PWD/.git"

icedos_result="$icedos_out/$(ls "$icedos_out")/result"
do_handle_der "$(readlink "$icedos_result")"
