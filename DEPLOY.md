# Cache-server deployment

The cache-server is a self-hosted [Attic](https://github.com/zhaofengli/attic) Nix binary cache.
CI is PR-first: `.github/workflows/auto-update.yml` opens one pull request per change source
(nixpkgs bump, each tracked input), `.github/workflows/nix-build.yml` builds each PR and pushes
**only icedos-custom paths** with `attic push`, and the PR is merged into `main` only after that
push succeeds — so `main` always describes a state the cache can fully serve. Paths already on
`cache.nixos.org` are skipped, and content is globally deduplicated. Clients fetch generic paths
from `cache.nixos.org` and custom paths from this cache.

## Published branches

Every successful build (and every `force` repair run on `main`) republishes the **`cache`**
branch as a single orphan commit — no history — containing:

- `nix-public.pem` — the cache's public key,
- `flake.lock` — the pinned `nixpkgs`/`core` revisions,
- `tracked-inputs.json` — the revision of every tracked input the cache was built against.
  These are the revs the CI build **actually resolved**, folded into the merge commit itself —
  not just what the detector saw — so they always describe servable closures.

Following `cache` and pinning your inputs to those revisions guarantees every closure resolves
from the cache instead of compiling locally. The legacy `key` branch (just the public key) is no
longer updated automatically; `core/flake.nix` should migrate its `cache-server` input from
`github:icedos/cache-server/key` to `github:icedos/cache-server/cache`.

## Stack

The whole stack is a **foreground supervisor** (`stack/supervisor.sh`) running three nix binaries —
no Docker, no containers, no daemon:

- **atticd** — the binary cache (localhost `127.0.0.1:8080`). SQLite + storage under `/nix/attic`.
- **nginx** — disk cache (`/nix/nar-cache`, 16 GB, 7-day eviction) on `127.0.0.1:8081`, shielding atticd's single
  core from repeat NAR reassembly.
- **caddy** — the public TLS edge (`:80`/`:443`) with **fully automatic HTTPS** (issue + renew,
  zero intervention). Uploads stream straight to atticd; everything else goes through the nginx cache.

`nix run .#stack` brings it up in the foreground; any signal, or any child dying, drops the **whole**
stack atomically. It does not daemonise — wrap it for keep-alive (below).

Host state: `/nix/attic` (atticd), `/nix/nar-cache` (nginx), `/var/lib/icedos-caddy` (Caddy's ACME
account + certs — **persist this** so Caddy never re-issues on restart).

## Keep-alive (Debian 13 / systemd)

```bash
cd /path/to/cache-server && git pull

# 1. JWT secret as a KEY=VALUE env file (reuse the existing secret value)
echo "ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=$(sudo cat /etc/icedos-attic-secret)" \
  | sudo tee /etc/icedos-attic-secret-env >/dev/null

# 2. stable symlink to the current built stack (rebuild on updates)
sudo nix build .#supervisor --out-link /var/lib/icedos-stack   # or path:.#supervisor before committing

# 3. systemd wrapper — keeps the foreground supervisor alive + restarts it
sudo tee /etc/systemd/system/icedos-stack.service >/dev/null <<'EOF'
[Unit]
Description=IceDOS cache stack (atticd + nginx + caddy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/icedos-attic-secret-env
ExecStart=/var/lib/icedos-stack/bin/icedos-cache
Restart=always
RestartSec=5
# optional hardening:
# ProtectSystem=strict
# ReadWritePaths=/nix/attic /nix/nar-cache /var/lib/icedos-caddy /run
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now icedos-stack.service
```

`systemctl stop` → SIGTERM → the supervisor drops the stack. The unit runs the supervisor in the
foreground (no detach); systemd just keeps it alive across reboots/crashes.

> On Alpine/OpenRC instead of systemd, run the same `/var/lib/icedos-stack/bin/icedos-cache` under
> `supervise-daemon` with the secret exported — the supervisor itself is init-agnostic.

## Migrating from the old Docker stack

```bash
docker compose -f stack/compose.yml down     # the old compose lives in git history
sudo systemctl disable --now docker          # optional: reclaim dockerd/containerd/shim/proxy RAM
```

The new atticd reads the **same `/nix/attic`**, so the cache contents + public key carry over —
**no re-bootstrap**. nginx reuses `/nix/nar-cache` too. With `:80`/`:443` now free, Caddy issues a
fresh cert on first start.

## Updating the stack

```bash
cd /path/to/cache-server && git pull
sudo nix build .#supervisor --out-link /var/lib/icedos-stack
sudo systemctl restart icedos-stack.service
```

Config/binary store paths are baked into the supervisor at build time, so an update = rebuild the
symlink + restart.

## TLS — zero intervention

Caddy issues and renews the `icedos.mirrors.knp.one` certificate automatically (ACME), persisting
state in `/var/lib/icedos-caddy`. Nothing to schedule, no timer, no cron. Set the ACME account email
in `stack/conf/Caddyfile` (currently `support@dtek.gr`). Requirements: ports 80 + 443 open, DNS for
`icedos.mirrors.knp.one` pointing at the box.

## Tokens (if ever needed)

`nix develop .#stack` exposes `generate_attic_admin_token` / `generate_attic_builder_token` — they run
`atticadm` directly (atticd is on the host now). Export the secret first:
`export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)"`. The CI
`ATTIC_TOKEN` (1y, pull+push `icedos`) is unchanged.

## Verify

```bash
free -m                                                              # dockerd/containerd/shims gone
systemctl status icedos-stack
curl -sI https://icedos.mirrors.knp.one/icedos/nix-cache-info        # 200, valid (Caddy) TLS
curl -sI https://icedos.mirrors.knp.one/<path>.narinfo | grep -i x-cache-status   # MISS then HIT
nix path-info --store https://icedos.mirrors.knp.one/icedos <path>   # a pushed custom path resolves
```

## Secrets

| Secret | Where | Purpose |
| --- | --- | --- |
| `ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64` | `/etc/icedos-attic-secret-env` | atticd JWT signing |
| `ATTIC_TOKEN` | GitHub repo secret | CI `attic push` auth (pull+push `icedos`) |
| `nix-public.pem` | repo file | cache public key clients trust |

Caddy manages the TLS certificate itself — no secret to handle.
