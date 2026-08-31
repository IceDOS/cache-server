#!/usr/bin/env bash

set -e
set -o pipefail

root="$PWD"

# The CDN serves the S3 bucket; narinfo/NAR paths have no cache-name prefix.
ICEDOS_CACHE_URL="${ICEDOS_SUBSTITUTER:-https://icedos.fyi}"
# nix copy signs pushed paths with the icedos keypair, so consumers that trust
# the public key need no change.
if [ -n "${ICEDOS_SIGNING_KEY:-}" ]; then
  printf '%s\n' "$ICEDOS_SIGNING_KEY" > "$root/nix-secret.pem"
  chmod 600 "$root/nix-secret.pem"
  export NIX_CONFIG="secret-key-files = $root/nix-secret.pem"
fi

# Returns 0 if the store path is already in the S3 cache (probed via the CDN).
is_path_cached() {
  local store_path="$1"
  local hash="${store_path#/nix/store/}"
  hash="${hash:0:32}"

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    "$ICEDOS_CACHE_URL/$hash.narinfo") || code=000
  [ "$code" = 200 ]
}

[ -d build ] && rm -rf build
mkdir -p build/status

# Health gate: a broken origin makes nix treat CI-built paths as unavailable and
# recompile the world. Abort; the next cycle retries. 403 = missing via CloudFront+OAC.
probe_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  "$ICEDOS_CACHE_URL/00000000000000000000000000000000.narinfo") || probe_code=000
case "$probe_code" in
  200|403|404) ;;
  *) echo "::error::cache server unhealthy (HTTP $probe_code) — aborting build so the next cycle retries against a healthy server" >&2; exit 1 ;;
esac

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

# ICEDOS_BUILD_CONFIGS (external mode): space-separated basenames of the configs
# affected by the source repo, derived by nix-build.yml. The base warm-up always
# runs: it seeds BASE_LOCK with the pinned rev and realizes the shared closure.
# force overrides the subset; without it everything outside the subset is
# untouched and stays covered by the cache.
selected=()
if [ -n "${ICEDOS_BUILD_CONFIGS:-}" ] && [ -z "${ICEDOS_FORCE_BUILD:-}" ]; then
  for name in $ICEDOS_BUILD_CONFIGS; do
    [ -f "config/$name" ] || { echo "ICEDOS_BUILD_CONFIGS: no such config: $name" >&2; exit 1; }
    selected+=("$name")
  done
else
  for cfg in config/*.toml; do
    selected+=("$(basename "$cfg")")
  done
fi
in_selected() {
  local name="$1" s
  for s in "${selected[@]}"; do [ "$s" = "$name" ] && return 0; done
  return 1
}

# Apply the unpin list to the seed: nodes this run is meant to advance are
# removed so they resolve fresh (external: the pinned source repo; internal:
# nixpkgs/home-manager on the nixpkgs PR, the PR's leaf otherwise). Everything
# else keeps the rev the cache was last built with.
apply_unpin() {
  local seed="$1"
  [ -f "$seed" ] && [ -n "${ICEDOS_UNPIN:-}" ] || return 0
  python3 - "$seed" $ICEDOS_UNPIN <<'PYEOF'
import json, sys

path, patterns = sys.argv[1], sys.argv[2:]
lock = json.load(open(path))
nodes = lock.get("nodes", {})

# Same key lookup as cache-server's tracked-revs.py: exact match, else a
# "-<name>" suffixed node key.
targets = set()
for name in patterns:
    if name in nodes:
        targets.add(name)
    targets.update(k for k in nodes if k.endswith("-" + name))
for k in targets:
    nodes.pop(k, None)

def strip_refs(inputs):
    if not isinstance(inputs, dict):
        return
    for name, ref in list(inputs.items()):
        if isinstance(ref, str) and ref in targets:
            del inputs[name]

for node in nodes.values():
    strip_refs(node.get("inputs"))
strip_refs(nodes.get("root", {}).get("inputs"))

json.dump(lock, open(path, "w"), indent=2)
print(f"unpinned {len(targets)} node(s) from the seed: {sorted(targets)}")
PYEOF
}

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

    # Seed per config: the exact lock this config was last built with (the root
    # state.lock only covers whichever config published last). Placed before
    # the base-lock seed below: the warm-up's evolved lock wins for the rest.
    seed="$ICEDOS_SEED_DIR/$name.lock"
    [ -f "$seed" ] || seed="${ICEDOS_SEED_LOCK:-}"
    if [ -n "$seed" ] && [ -f "$seed" ]; then
      mkdir -p "$work/build/.state"
      cp "$seed" "$work/build/.state/flake.lock"
      apply_unpin "$work/build/.state/flake.lock"
    fi

    # Seed the base build's resolved lock so this build only resolves its OWN repos; nix
    # adds the missing ones in-memory (--no-update-lock-file doesn't block additions).
    if [ -n "${BASE_LOCK:-}" ] && [ -f "${BASE_LOCK:-}" ] && [ "$cfg" != "$base" ]; then
      mkdir -p "$work/build/.state"
      cp "$BASE_LOCK" "$work/build/.state/flake.lock"
    fi
    # Heal mode: rebuild from each config's own last-resolved lock so the copied
    # closure matches what that config actually serves its users.
    if [ -n "${ICEDOS_HEAL:-}" ] && [ -f "$root/build/locks/$name.lock" ]; then
      mkdir -p "$work/build/.state"
      cp "$root/build/locks/$name.lock" "$work/build/.state/flake.lock"
    fi

    mkdir -p "$out"

    cd "$work"

    # Skip when the top-level closure is already cached; genflake runs first for the pure outPath eval.
    # pipe-operators is REQUIRED — core/lib/icedos.nix uses `|>`; stderr kept so failed evals aren't silent.
    top_path=""
    if [ -z "${ICEDOS_HEAL:-}" ] && [ -n "${ICEDOS_CACHE_URL:-}" ] && [ -z "${ICEDOS_FORCE_BUILD:-}" ]; then
      # Evals are silent — a stalled fetch here hangs the whole fan-out, so bound them.
      if timeout 15m env TMPDIR="$out" nix run path:.#icedos -- --genflake-only; then
        # Write the resolved lock: the skip check eval reads it, and CI pins the built
        # input hashes from build/locks (gitignored).
        timeout 10m nix --extra-experimental-features "nix-command flakes" flake lock "$work/build/.state"
        mkdir -p "$root/build/locks"
        cp "$work/build/.state/flake.lock" "$root/build/locks/$name.lock"
        eval_err="$root/build/$name.eval.err"
        top_path=$(timeout 10m nix eval --raw --no-write-lock-file \
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
      --extra-substituters "$ICEDOS_CACHE_URL?priority=100" \
      --extra-trusted-public-keys "$(cat nix-public.pem)" \
      --extra-substituters "https://attic.xuyh0120.win/lantian?priority=90" \
      --extra-trusted-public-keys "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="

    shopt -s nullglob
    local results=("$out"/*/result)
    shopt -u nullglob
    [ "${#results[@]}" -eq 1 ] || {
      echo "expected 1 result under $out, found ${#results[@]}" >&2
      exit 1
    }
    result="$(readlink "${results[0]}")"

    # Refresh the persisted lock: the build may have resolved newer revs.
    timeout 10m nix --extra-experimental-features "nix-command flakes" flake lock "$work/build/.state"
    cp "$work/build/.state/flake.lock" "$root/build/locks/$name.lock"

    echo "pushing $cfg..."

    # Upstream filter: skip paths cache.nixos.org already serves — users prefer
    # it (priority 40 < 100), so pushing them is pure waste of upload + storage.
    mapfile -t closure_paths < <(nix path-info -r "$result")
    missing_paths=()
    printf '%s\n' "${closure_paths[@]}" | xargs -P 8 -I{} bash -c '
      h=$(basename "{}" | cut -c1-32)
      code=000
      for i in 1 2 3; do
        code=$(curl -s -o /dev/null -w "%{http_code}" --head --max-time 20 "https://cache.nixos.org/$h.narinfo")
        [ "$code" = 000 ] || break
        sleep $((i * 2))
      done
      # a failed probe is not proof of absence; pushing beats permanent skip
      [ "$code" = 200 ] || printf "%s\n" "{}"
    ' >"$out/missing-paths" || true
    mapfile -t missing_paths < "$out/missing-paths"
    echo "$cfg: $((${#closure_paths[@]} - ${#missing_paths[@]})) paths in upstream, pushing ${#missing_paths[@]}"

    # `nix copy` exits non-zero on any path failure, which would make the skip
    # check above permanent. Retry on failure.
    pushed=0
    for attempt in 1 2 3; do
      push_rc=0
      if [ "${#missing_paths[@]}" -eq 0 ]; then
        push_out="$cfg: nothing to push — entire closure already in upstream caches"
        printf '%s\n' "$push_out"
        pushed=1
        break
      fi
      push_out="$(flock "$root/build/push.lock" timeout 30m \
        nix copy --to "$ICEDOS_S3_URL" ${missing_paths[@]+"${missing_paths[@]}"} 2>&1)" || push_rc=$?
      printf '%s\n' "$push_out"

      if [ "$push_rc" -eq 0 ]; then
        pushed=1
        # Persist the config's resolved lock so the weekly heal job can restore
        # exactly this closure if the lifecycle rule expires any of its paths.
        # nix copy never writes nix-cache-info to S3; nix drops the substituter without it
        printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 100\n' \
          | aws s3 cp - "s3://$ICEDOS_S3_BUCKET/nix-cache-info" --region "$AWS_REGION" >/dev/null 2>&1 || \
          echo "warning: failed to upload nix-cache-info" >&2
        aws s3 cp "$root/build/locks/$name.lock" "s3://$ICEDOS_S3_BUCKET/locks/$name.lock" --region "$AWS_REGION" >/dev/null 2>&1 || \
          echo "$cfg: warning — could not upload the config lock" >&2
        break
      fi

      echo "$cfg: push attempt $attempt failed (rc=$push_rc), retrying" >&2
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
    BASE_LOCK="$workbase/00-base/build/.state/flake.lock"
  else
    echo "WARNING: base warm-up failed; parallel builds will each resolve their own inputs" >&2
  fi
fi

# Fan out the remaining configs in parallel against the now-warm store, throttled.
# Subset mode skips configs outside the selection (including the base itself,
# which the warm-up above already handled).
for cfg in config/*.toml; do
  [ "$cfg" = "$base" ] && continue
  in_selected "$(basename "$cfg")" || continue
  while [ "$(jobs -r | wc -l)" -ge "$max_parallel" ]; do wait -n || true; done
  build_and_push "$cfg" &
done
wait

failed=()
for cfg in config/*.toml; do
  [ "$cfg" = "$base" ] && continue
  in_selected "$(basename "$cfg")" || continue
  name="$(basename "$cfg" .toml)"
  [ "$(cat "$root/build/status/$name" 2>/dev/null)" = "ok" ] || failed+=("$cfg")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Build/upload failed for ${#failed[@]} config(s):" >/dev/stderr
  printf '  %s\n' "${failed[@]}" >/dev/stderr
  exit 1
fi

# Expose the built state lock for the publish step: it becomes the next run's
# seed, so the cache branch always describes what the cache was built with.
if [ -n "${BASE_LOCK:-}" ] && [ -f "${BASE_LOCK:-}" ]; then
  cp "$BASE_LOCK" "$root/state.lock"
fi

echo "All configs built successfully!"
