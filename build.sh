#!/usr/bin/env bash

set -e
set -o pipefail

root="$PWD"

# Check if a store path already exists in the Attic cache.
# Returns 0 if the path IS in the cache (i.e., we can skip building it).
is_path_cached() {
  local store_path="$1"
  # Attic's get-missing-paths expects just the hash part (first 32 chars after /nix/store/)
  local hash="${store_path#/nix/store/}"
  hash="${hash:0:32}"

  local resp
  resp=$(curl -sf -X POST \
    -H "Authorization: Bearer $ATTIC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"cache\":\"icedos\",\"store_path_hashes\":[\"$hash\"]}" \
    "$ICEDOS_SUBSTITUTER/_api/v1/get-missing-paths" 2>/dev/null) || return 1

  # If missing_paths is empty, the path exists in cache
  local missing_count
  missing_count=$(echo "$resp" | jq '.missing_paths | length')
  [ "$missing_count" -eq 0 ]
}

[ -d build ] && rm -rf build
mkdir -p build/status

# The work dir path is BAKED into the closure: core exports `ICEDOS_STATE_DIR=$PWD/build/.state`
# and genflake bakes it into `icedos.configurationLocation`, which nearly every `icedos` subcommand
# script interpolates. A `mktemp` base therefore gives every run fresh hashes for ~38 paths per
# config — rebuilt and re-pushed forever, and never a cache hit below. CI pins ICEDOS_WORKBASE to a
# stable directory so identical inputs produce identical store paths; local runs keep mktemp.
workbase="${ICEDOS_WORKBASE:-}"
if [ -n "$workbase" ]; then
  # Clear the CONTENTS, never the directory itself: CI creates it under root-owned
  # /mnt (mode 1777), so the runner may write inside it but cannot unlink its entry
  # in /mnt — `rm -rf "$workbase"` fails with EACCES.
  clean_workbase() { find "$workbase" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; }
  mkdir -p "$workbase"
  clean_workbase
else
  workbase="$(mktemp -d -t icedos-cache-XXXXXX)"
  clean_workbase() { rm -rf "$workbase"; }
fi
trap clean_workbase EXIT

max_parallel="${ICEDOS_MAX_PARALLEL:-6}"

# Build one config in an isolated, git-less work dir (so the flake eval sees the
# untracked config.toml), then push its result. The push is taken behind a flock
# so only one `attic push` ever runs at a time: the first build to finish uploads
# the shared base, the rest find it already present and skip it. The 1-core cache
# server therefore only ever chunks one closure at a time — same gentle ingest as
# the old sequential build, but the builds themselves overlap.
build_and_push() {
  local cfg="$1"
  local name work out result top_path pushed attempt
  name="$(basename "$cfg" .toml)"
  work="$workbase/$name"
  out="$work/out"

  (
    set -e
    # Isolated copy of the flake (sans build artifacts + git) so parallel builds
    # never race on config.toml or the generated flake state.
    rsync -a --exclude=build --exclude=.git "$root/" "$work/"
    cp "$cfg" "$work/config.toml"

    # Reuse the shared inputs (nixpkgs, icedos-core, home-manager, …) already
    # resolved by the base build: seed its lock so this build only resolves its
    # OWN repos. nix populates the missing repo inputs on top (it locks them
    # in-memory for the build; --no-update-lock-file doesn't block additions).
    if [ -n "${BASE_LOCK:-}" ] && [ -f "${BASE_LOCK:-}" ] && [ "$cfg" != "$base" ]; then
      mkdir -p "$work/build/.state"
      cp "$BASE_LOCK" "$work/build/.state/flake.lock"
    fi

    mkdir -p "$out"

    cd "$work"

    # Skip the whole build when this config's top-level closure is already cached.
    # The NixOS system lives in the GENERATED flake (build/.state), not in the config
    # root, so genflake has to run first — `--genflake-only` writes and locks it
    # without realising anything, and the outPath is then a pure eval. The generated
    # `nixosConfigurations.icedos` never uses `self`, so this is the same path
    # `nh os build path:.` produces from its rsync'd copy.
    top_path=""
    if [ -n "${ATTIC_TOKEN:-}" ] && [ -n "${ICEDOS_SUBSTITUTER:-}" ]; then
      if TMPDIR="$out" nix run path:.#icedos -- --genflake-only; then
        top_path=$(nix eval --raw --no-write-lock-file \
          "path:$work/build/.state#nixosConfigurations.icedos.config.system.build.toplevel.outPath" \
          2>/dev/null) || top_path=""
      fi

      if [ -n "$top_path" ] && is_path_cached "$top_path"; then
        echo "$cfg: top-level closure already in cache ($top_path), skipping build"
        echo ok >"$root/build/status/$name"
        return 0
      fi
    fi

    echo "building $cfg..."

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

    # `attic push` exits 0 even when individual paths fail (the 1-core server 500s
    # under load), which silently leaves a half-populated cache and defeats the skip
    # check above on the next run. `$result` IS the toplevel, so query it back as the
    # witness that the closure landed, retry, and fail the config if it never does.
    pushed=0
    for attempt in 1 2 3; do
      flock "$root/build/push.lock" attic push icedos "$result" || true
      if [ -z "${ATTIC_TOKEN:-}" ] || [ -z "${ICEDOS_SUBSTITUTER:-}" ] || is_path_cached "$result"; then
        pushed=1
        break
      fi
      echo "$cfg: push attempt $attempt did not land $result, retrying" >&2
      sleep $((attempt * 15))
    done
    [ "$pushed" -eq 1 ] || {
      echo "$cfg: push failed after 3 attempts; $result still missing from the cache" >&2
      exit 1
    }

    echo "$cfg successfully built and uploaded to the cache server!"
  ) && echo ok >"$root/build/status/$name" || echo fail >"$root/build/status/$name"
}

# Warm-up: build the bare base ALONE first (best-effort) so its shared closure is
# realized, cached and pushed once. The parallel builds then only build/push their
# own deltas instead of racing to (re)build the common base on a cold store —
# measurably faster.
base="config/00-base.toml"
BASE_LOCK=""
if [ -f "$base" ]; then
  echo "=== warming shared base: $base ==="
  build_and_push "$base"
  if [ "$(cat "$root/build/status/00-base" 2>/dev/null)" = "ok" ]; then
    # Hand the base's resolved input lock to every later build (see build_and_push).
    BASE_LOCK="$workbase/00-base/build/.state/flake.lock"
  else
    echo "WARNING: base warm-up failed; parallel builds will each resolve their own inputs" >&2
  fi
fi

# Fan out the remaining configs in parallel against the now-warm store, throttled.
for cfg in config/*.toml; do
  [ "$cfg" = "$base" ] && continue
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
