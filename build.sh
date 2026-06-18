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

cleanup() {
  rm -f config.toml
  [ -d "$PWD/.git.bak" ] && mv "$PWD/.git.bak" "$PWD/.git"
}
trap cleanup EXIT

[ -d "$PWD/.git" ] && mv "$PWD/.git" "$PWD/.git.bak"

# Βuild + upload each target config in turn, collecting failures so one
# bad config does not abort the rest. Each variant runs in its own subshell with
# errexit on (outer errexit off) so a failed build skips its upload but the loop
# continues.
failed=()

for cfg in config/*.toml; do
  set +e
  (
    set -e
    cp "$cfg" config.toml

    rm -rf "$icedos_out"
    mkdir -p "$icedos_out"

    echo "building $cfg..."

    TMPDIR="$icedos_out" nix run .#icedos -- --build \
      --nh-args --no-nom \
      --build-args \
      --extra-substituters "ssh-ng://cache-server?priority=100" \
      --extra-trusted-public-keys "$(cat nix-public.pem)" \
      --extra-substituters "https://attic.xuyh0120.win/lantian?priority=90" \
      --extra-trusted-public-keys "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="

    icedos_result="$icedos_out/$(ls "$icedos_out")/result"
    do_handle_der "$(readlink "$icedos_result")"
    echo "$cfg successfully built and uploaded to the cache server!"
  )
  status=$?
  set -e

  rm -f config.toml

  if [ "$status" -ne 0 ]; then
    echo "FAILED: $cfg" >/dev/stderr
    failed+=("$cfg")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Build/upload failed for ${#failed[@]} config(s):" >/dev/stderr
  printf '  %s\n' "${failed[@]}" >/dev/stderr
  exit 1
fi

echo "All configs built successfully!"
