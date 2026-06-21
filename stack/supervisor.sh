#!/usr/bin/env bash
# IceDOS cache stack supervisor — runs atticd + nginx + caddy as FOREGROUND
# children. On any signal, normal EXIT, or a child dying, the WHOLE stack drops
# (atomic). It does NOT daemonise. For keep-alive in production, wrap it:
#   Debian/systemd:  Type=simple, ExecStart=nix run .#stack, Restart=always
#   Alpine/OpenRC:   supervise-daemon ... -- nix run .#stack
# The placeholder tokens (binary + config store paths) are filled in by flake.nix.
set -uo pipefail

: "${ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64:?must be set (systemd EnvironmentFile, or exported before run)}"

# Caddy keeps its ACME account + issued certs here. Persist it so Caddy does NOT
# re-issue on every restart (which would hit Let's Encrypt rate limits). This is
# what makes TLS fully zero-intervention: Caddy auto-issues AND auto-renews.
caddy_home="${ICEDOS_CADDY_HOME:-/var/lib/icedos-caddy}"
export XDG_DATA_HOME="$caddy_home/data" XDG_CONFIG_HOME="$caddy_home/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" /nix/attic/storage /nix/nar-cache

pids=()
# shellcheck disable=SC2329  # invoked indirectly via the trap below
cleanup() {
  trap - TERM INT EXIT
  [ "${#pids[@]}" -gt 0 ] && kill "${pids[@]}" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup TERM INT EXIT

echo "icedos-stack: starting atticd (127.0.0.1:8080)"
@atticd@ -f @server@ --mode monolithic &
pids+=($!)

# Best-effort wait (~15s) until atticd's port is open, so nginx/caddy don't 502
# the first requests. Uses the bash /dev/tcp builtin — no extra binary needed.
for _ in $(seq 1 30); do
  (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && {
    exec 3>&- 3<&-
    break
  }
  sleep 0.5
done

echo "icedos-stack: starting nginx (disk cache, 127.0.0.1:8081)"
@nginx@ -c @nginxconf@ -g 'daemon off;' &
pids+=($!)

echo "icedos-stack: starting caddy (TLS edge, automatic HTTPS)"
@caddy@ run --config @caddyfile@ --adapter caddyfile &
pids+=($!)

# Any child exiting brings the whole stack down (atomic); the keep-alive wrapper
# then restarts the lot.
wait -n
echo "icedos-stack: a process exited — dropping the stack" >&2
exit 1
