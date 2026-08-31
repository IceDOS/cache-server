# Deploy

The cache is fully managed: GitHub Actions builds IceDOS configs on every
change source and pushes to S3; CloudFront serves them behind Cloudflare at
`https://icedos.fyi`. There is no self-hosted server.

## Architecture

- **AWS S3** — private bucket `icedos-nix-cache-fyi` (eu-central-1): NARs,
  narinfos, per-config locks (`locks/`), `state.lock`. 35-day lifecycle
  expiry; the weekly `heal-cache.yml` run re-pushes expired-but-current
  paths so live closures never 404.
- **CloudFront** — distribution `E1EEMYNS1YFLPR`, origin access control
  (signed reads only, no public bucket access), CachingOptimized policy.
- **Cloudflare** — proxied CNAME `@` → CloudFront; edge TTL: 200–299 → 30d,
  404/403 → 10s. The zone hosts only the cache hostname.
- **CI** — `nix-build.yml` gates `main` behind green builds (one PR per
  change source, native-rebase merge); pushes sign with `ICEDOS_SIGNING_KEY`.
  IAM user `icedos-ci` has S3 read/write on the bucket and nothing else.

## Consumers

Add `https://icedos.fyi` as a substituter with the public key from the
`cache` branch (`nix-public.pem`), served with priority below
cache.nixos.org. The upstream filter keeps the bucket to IceDOS-built
paths only.
