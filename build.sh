#!/usr/bin/env bash

set -e
set -o pipefail

root="$PWD"

[ -d build ] && rm -rf build
mkdir -p build/status

workbase="$(mktemp -d -t icedos-cache-XXXXXX)"
trap 'rm -rf "$workbase"' EXIT

max_parallel="${ICEDOS_MAX_PARALLEL:-6}"

# Build one config in an isolated, git-less work dir (so the flake eval sees the
# untracked config.toml), then push its result. The push is taken behind a flock
# so only one `attic push` ever runs at a time: the first build to finish uploads
# the shared base, the rest find it already present and skip it. The 1-core cache
# server therefore only ever chunks one closure at a time — same gentle ingest as
# the old sequential build, but the builds themselves overlap.
build_and_push() {
  local cfg="$1"
  local name work out result
  name="$(basename "$cfg" .toml)"
  work="$workbase/$name"
  out="$work/out"

  (
    set -e
    # Isolated copy of the flake (sans build artifacts + git) so parallel builds
    # never race on config.toml or the generated flake state.
    rsync -a --exclude=build --exclude=.git "$root/" "$work/"
    cp "$cfg" "$work/config.toml"
    mkdir -p "$out"

    echo "building $cfg..."
    cd "$work"

    TMPDIR="$out" nix run path:.#icedos -- --build \
      --nh-args --no-nom \
      --build-args \
      -L \
      --extra-substituters "$ICEDOS_SUBSTITUTER/icedos?priority=100" \
      --extra-trusted-public-keys "$(cat nix-public.pem)" \
      --extra-substituters "https://attic.xuyh0120.win/lantian?priority=90" \
      --extra-trusted-public-keys "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="

    # Exactly one build dir lands under $out (TMPDIR); take its result link.
    shopt -s nullglob
    local results=("$out"/*/result)
    shopt -u nullglob
    [ "${#results[@]}" -eq 1 ] || {
      echo "expected 1 result under $out, found ${#results[@]}" >&2
      exit 1
    }
    result="$(readlink "${results[0]}")"

    # flock guarantees one push at a time across all parallel builds.
    echo "pushing $cfg..."
    flock "$root/build/push.lock" attic push icedos "$result"
    echo "$cfg successfully built and uploaded to the cache server!"
  ) && echo ok >"$root/build/status/$name" || echo fail >"$root/build/status/$name"
}

for cfg in config/*.toml; do
  while [ "$(jobs -r | wc -l)" -ge "$max_parallel" ]; do wait -n || true; done
  build_and_push "$cfg" &
done
wait

# Collect failures (build OR push) and fail the run if any real config did not finish.
failed=()
for cfg in config/*.toml; do
  [ "$cfg" = "$base" ] && continue
  name="$(basename "$cfg" .toml)"
  [ "$(cat "$root/build/status/$name" 2>/dev/null)" = "ok" ] || failed+=("$cfg")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Build/upload failed for ${#failed[@]} config(s):" >/dev/stderr
  printf '  %s\n' "${failed[@]}" >/dev/stderr
  exit 1
fi

echo "All configs built successfully!"
