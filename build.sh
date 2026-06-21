#!/usr/bin/env bash

set -e
set -o pipefail

root="$PWD"

[ -d build ] && rm -rf build
mkdir -p build/status

# Work dirs live OUTSIDE the repo. icedos core generates a flake into the state
# dir and runs several nix commands against it (prefetch-inputs, flake update,
# the build) with plain flakerefs — inside a git repo those resolve to the repo
# toplevel and ignore untracked files, so the generated flake is invisible.
# Building under an external, git-less dir sidesteps that entirely (the old
# in-place build moved .git aside for the same reason).
workbase="$(mktemp -d -t icedos-cache-XXXXXX)"
trap 'rm -rf "$workbase"' EXIT

# Max configs to BUILD at once. All builds share the one /nix store, so nix
# builds the common base exactly once (per-derivation locks coalesce duplicate
# work) and only the unique parts of each config compile in parallel. Cap this to
# avoid oversubscribing the runner's RAM/CPU. Pushes are ALWAYS serialized (flock
# below), independent of this number.
max_parallel="${ICEDOS_MAX_PARALLEL:-4}"

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

    # -L (--print-build-logs) streams every derivation's full build log; rides the
    # --build-args channel (forwarded after `--` to nix; see core/build.sh). Kept
    # with --no-nom so CI logs stay linear/greppable and a failed config dumps its
    # whole log instead of a terse tail.
    # path:. (not .#) so each work dir is its own standalone flake: bare `.` is a
    # git flakeref and resolves to the *enclosing* repo toplevel (copying only
    # tracked files), which hides this untracked work dir + its config.toml.
    # path: uses the exact CWD and copies untracked files. (icedos core uses
    # path:. internally for the same reason.)
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

    # Serialized upload queue: push only icedos-custom paths (attic skips paths
    # already on cache.nixos.org and globally dedups). flock guarantees one push
    # at a time across all parallel builds.
    echo "pushing $cfg..."
    flock "$root/build/push.lock" attic push icedos "$result"
    echo "$cfg successfully built and uploaded to the cache server!"
  ) && echo ok >"$root/build/status/$name" || echo fail >"$root/build/status/$name"
}

# Warm-up: build the bare base ALONE first (best-effort) so its shared closure is
# realized, cached and pushed once. Without this the parallel builds below each
# race to (re)build/refetch the common base on a cold store (~57% of fetches were
# duplicated). With it, the first push uploads the base and the rest only push
# their own deltas.
base="config/00-base.toml"
if [ -f "$base" ]; then
  echo "=== warming shared base: $base ==="
  build_and_push "$base"
  [ "$(cat "$root/build/status/00-base" 2>/dev/null)" = "ok" ] \
    || echo "WARNING: base warm-up failed; parallel builds will each build their own base" >&2
fi

# Fan out the remaining configs in parallel against the now-warm store, throttled
# to $max_parallel. build_and_push records its outcome in build/status/<name> and
# always returns 0, so the throttling `wait` never trips errexit.
for cfg in config/*.toml; do
  [ "$cfg" = "$base" ] && continue
  while [ "$(jobs -r | wc -l)" -ge "$max_parallel" ]; do wait -n || true; done
  build_and_push "$cfg" &
done
wait

# Collect failures (build OR push) and fail the run if any real config did not
# finish. The base is a best-effort warm-up + bonus artifact — not counted here.
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
