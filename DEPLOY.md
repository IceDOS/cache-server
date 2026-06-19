# Cache-server deployment

The cache-server is a self-hosted [Attic](https://github.com/zhaofengli/attic) Nix binary cache.
CI (`.github/workflows/nix-build.yml`) builds the configs under `config/` and pushes **only
icedos-custom paths** with `attic push` — paths already on `cache.nixos.org` are skipped, and
content is globally deduplicated. Clients fetch generic paths from `cache.nixos.org` and custom
paths from this cache.

## Stack

`stack/compose.yml` runs three containers (chain: `web → nar-cache → app`):

- **app** — `atticd` (binary cache server). SQLite + local storage in the `attic_data` volume;
  config in `stack/conf/server.toml`. The JWT signing secret is supplied via the
  `ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64` environment variable (never committed).
- **nar-cache** — nginx disk cache (`/nix/nar-cache`, 16 GB) in front of atticd, so repeat pulls of
  a hot path are served from disk instead of re-reassembling/decompressing the NAR each time
  (offloads the single core; `proxy_cache_lock` coalesces concurrent misses).
- **web** — Caddy, TLS-terminating reverse proxy for `icedos.mirrors.knp.one` → `nar-cache:8080`.

The `atticd` binary is injected by the flake wrapper (`packages.stack.docker`), so run compose via
`nix run .#stack.docker -- <args>`.

## First-time deployment (server: `icedos.mirrors.knp.one`)

### 1. Pull + generate the JWT secret

```bash
cd /path/to/cache-server && git pull

# Generate once and store root-only:
openssl rand 64 | base64 -w0 | sudo tee /etc/icedos-attic-secret >/dev/null
export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)"
```

`docker compose` substitutes the secret into the container at `up` time and keeps it across
restarts/reboots, so it only needs to be exported when you run `up`.

### 2. Bring up the stack

```bash
nix run .#stack.docker -- down                       # stop the previous stack (if any)
nix run .#stack.docker -- up -d --remove-orphans     # --remove-orphans drops the retired nar-cache
nix run .#stack.docker -- logs -f app                # confirm atticd started, then Ctrl-C
```

The `caddy_data` volume (TLS certs) is reused; `attic_data` is created fresh. If atticd reports a
missing `/data/storage`, create it inside the volume.

### 3. Bootstrap the cache

```bash
# Admin token — atticadm signs with the same secret (already exported):
ATTICADM="$(nix build nixpkgs#attic-server --no-link --print-out-paths)/bin/atticadm"
ROOT="$("$ATTICADM" make-token --sub admin --validity '100y' \
        --pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*')"

nix shell nixpkgs#attic-client
attic login central https://icedos.mirrors.knp.one "$ROOT"
attic cache create icedos
attic cache configure icedos --public          # unauthenticated pull for end users
attic cache info icedos                        # copy the printed  icedos:<base64>  public key
```

> Confirm exact flags with `atticadm make-token --help` / `attic cache configure --help` — the flag
> set changes between attic versions.

### 4. Publish the cache public key

```bash
echo 'icedos:<paste-the-public-key>' > nix-public.pem   # replaces the old nix-serve key
git add nix-public.pem && git commit -m 'attic: cache public key' && git push
```

`core/modules/cache.nix` reads `nix-public.pem` (via the `cache-server` flake input) for
`cache.key`, and `build.sh` uses it as the build substituter's trusted key.

### 5. CI push token → GitHub secret

```bash
"$ATTICADM" make-token --sub ci --validity '1y' --pull icedos --push icedos
```

Add the result as the repo secret **`ATTIC_TOKEN`**. The old `SSH_KEY`, `SSH_HOST_KEY`, `SSH_HOST`,
`SSH_USER`, and `NIX_SIGNING_KEY` secrets are no longer used — remove them.

### 6. Point clients at the new cache

Bump the core lock in your config (`icedos rebuild --update`) **after** steps 1–5 are live and
`nix-public.pem` is pushed, so clients pick up the `…/icedos` URL and the matching key together.

**Order matters:** export the secret before `up` (2); make the cache public and push the key (3–4)
before clients bump the lock (6).

## Verify

```bash
curl -sI https://icedos.mirrors.knp.one/icedos/nix-cache-info        # 200 — atticd responding
nix path-info --store https://icedos.mirrors.knp.one/icedos <path>   # a pushed custom path resolves
```

After a CI run, its log should show `attic push` reporting paths **skipped (already on
cache.nixos.org)** vs pushed — only custom paths upload.

## Ongoing operation

- **Garbage collection** — atticd GCs on `[garbage-collection].interval` (12h) using
  `default-retention-period` (30d) from `server.toml`. It is **LRU/access-based**: an object is
  removed once it has not been accessed (pulled, or re-pushed by CI) for the retention period, so
  active paths stay and only stale ones age out. Override live with
  `attic cache configure icedos --retention-period <dur>`.
- **Auto-update** — `.github/workflows/auto-update.yml` runs every 3h: it updates the `nixpkgs`
  input and, if its rev changed, commits the lock and dispatches `nix-build.yml`, refreshing the
  cache against the new nixpkgs.
- **Reclaim old space** — closures pushed during the previous nix-serve setup still sit in the
  server's `/nix` store and are now unused; run `nix-collect-garbage -d` when convenient.

## Secrets summary

| Secret | Where | Purpose |
| --- | --- | --- |
| `ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64` | server env (`/etc/icedos-attic-secret`) | atticd JWT signing |
| `ATTIC_TOKEN` | GitHub repo secret | CI `attic push` auth (pull+push `icedos`) |
| `nix-public.pem` | repo file | cache public key clients trust |
