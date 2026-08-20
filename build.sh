#!/usr/bin/env bash

set -e
set -o pipefail

root="$PWD"

# Returns 0 if the store path is already in the Attic cache.
is_path_cached() {
  local store_path="$1"
  # get-missing-paths wants only the 32-char hash.
  local hash="${store_path#/nix/store/}"
  hash="${hash:0:32}"

  local resp
  resp=$(curl -sf -X POST \
    -H "Authorization: Bearer $ATTIC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"cache\":\"icedos\",\"store_path_hashes\":[\"$hash\"]}" \
    "$ICEDOS_SUBSTITUTER/_api/v1/get-missing-paths" 2>/dev/null) || return 1

  local missing_count
  missing_count=$(echo "$resp" | jq '.missing_paths | length')
  [ "$missing_count" -eq 0 ]
}

[ -d build ] && rm -rf build
mkdir -p build/status

# The work dir is baked into the closure via `icedos.configurationLocation`, so a mktemp base
# gives every run fresh hashes for ~38 paths per config. CI pins ICEDOS_WORKBASE instead.
workbase="${ICEDOS_WORKBASE:-}"
if [ -n "$workbase" ]; then
  # Clear the CONTENTS, never the directory: CI creates it under root-owned /mnt, so the
  # runner can write inside it but `rm -rf "$workbase"` fails with EACCES.
  clean_workbase() { find "$workbase" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; }
  mkdir -p "$workbase"
  clean_workbase
else
  workbase="$(mktemp -d -t icedos-cache-XXXXXX)"
  clean_workbase() { rm -rf "$workbase"; }
fi
trap clean_workbase EXIT

max_parallel="${ICEDOS_MAX_PARALLEL:-6}"

# Build one config in an isolated, git-less work dir so the flake eval sees the untracked
# config.toml. Pushes go behind a flock: the 1-core server only chunks one closure at a time.
build_and_push() {
  local cfg="$1"
  local name work out result top_path pushed attempt push_rc push_out eval_err
  name="$(basename "$cfg" .toml)"
  work="$workbase/$name"
  out="$work/out"

  (
    set -e
    # Isolated copy so parallel builds never race on config.toml or the flake state.
    rsync -a --exclude=build --exclude=.git "$root/" "$work/"
    cp "$cfg" "$work/config.toml"

    # Seed the base build's resolved lock so this build only resolves its OWN repos; nix
    # adds the missing ones in-memory (--no-update-lock-file doesn't block additions).
    if [ -n "${BASE_LOCK:-}" ] && [ -f "${BASE_LOCK:-}" ] && [ "$cfg" != "$base" ]; then
      mkdir -p "$work/build/.state"
      cp "$BASE_LOCK" "$work/build/.state/flake.lock"
    fi

    mkdir -p "$out"

    cd "$work"

    # Skip the build when this config's toplevel is already cached. The NixOS system lives
    # in the GENERATED flake, so genflake must run first; the outPath eval is then pure.
    #
    # pipe-operators is REQUIRED — core/lib/icedos.nix uses `|>` and the workflow's shell
    # only enables nix-command + flakes. stderr is kept so a failed eval isn't silent.
    top_path=""
    if [ -n "${ATTIC_TOKEN:-}" ] && [ -n "${ICEDOS_SUBSTITUTER:-}" ] && [ -z "${ICEDOS_FORCE_BUILD:-}" ]; then
      if TMPDIR="$out" nix run path:.#icedos -- --genflake-only; then
        eval_err="$root/build/$name.eval.err"
        top_path=$(nix eval --raw --no-write-lock-file \
          --extra-experimental-features "nix-command flakes pipe-operators" \
          "path:$work/build/.state#nixosConfigurations.icedos.config.system.build.toplevel.outPath" \
          2>"$eval_err") || {
          top_path=""
          echo "$cfg: could not evaluate the top-level closure, building unconditionally:" >&2
          cat "$eval_err" >&2
        }
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

    # Exactly one build dir lands under $out (TMPDIR).
    shopt -s nullglob
    local results=("$out"/*/result)
    shopt -u nullglob
    [ "${#results[@]}" -eq 1 ] || {
      echo "expected 1 result under $out, found ${#results[@]}" >&2
      exit 1
    }
    result="$(readlink "${results[0]}")"

    echo "pushing $cfg..."

    # `attic push` exits 0 even when individual paths fail, and the skip check above would
    # then make the gap permanent. Retry on attic's own ❌ verdict, not get-missing-paths.
    pushed=0
    for attempt in 1 2 3; do
      push_rc=0
      push_out="$(flock "$root/build/push.lock" attic push icedos "$result" 2>&1)" || push_rc=$?
      printf '%s\n' "$push_out"

      if [ "$push_rc" -eq 0 ] && ! printf '%s' "$push_out" | grep -q '❌'; then
        pushed=1
        break
      fi

      echo "$cfg: push attempt $attempt reported failed paths (rc=$push_rc), retrying" >&2
      sleep $((attempt * 15))
    done
    [ "$pushed" -eq 1 ] || {
      echo "$cfg: push failed after 3 attempts; the cached closure for $result is incomplete" >&2
      exit 1
    }

    echo "$cfg successfully built and uploaded to the cache server!"
  ) && echo ok >"$root/build/status/$name" || echo fail >"$root/build/status/$name"
}

# Build the bare base alone first so its shared closure is realized and pushed once; the
# parallel builds then only handle their own deltas instead of racing on a cold store.
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
