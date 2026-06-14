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
  nix store sign --key-file nix-private.pem --recursive "$der"
  nix copy --to "ssh-ng://cache-server" "$der"
  ssh cache-server bash "/opt/cache-server/utils/register-gc-root.sh" "$der"
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
  --extra-substituters "ssh-ng://cache-server" \
  --extra-trusted-public-keys "$(cat nix-public.pem)"
[ -d "$PWD/.git.bak" ] && mv "$PWD/.git.bak" "$PWD/.git"

icedos_result="$icedos_out/$(ls "$icedos_out")/result"
do_handle_der "$(readlink "$icedos_result")"
