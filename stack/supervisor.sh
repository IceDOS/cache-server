#!/usr/bin/env bash
# Runs atticd + nginx + caddy as foreground children; any signal or child death drops the
# whole stack (wait -n + exit 1). Does NOT daemonise — wrap it (systemd Restart=always).
set -uo pipefail

: "${ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64:?must be set (systemd EnvironmentFile, or exported before run)}"

# Persist Caddy's ACME account + certs so restarts don't re-issue and hit rate limits.
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

# Wait ~15s for atticd's port so nginx/caddy don't 502 the first requests.
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

wait -n
echo "icedos-stack: a process exited — dropping the stack" >&2
exit 1
