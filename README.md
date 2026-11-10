# zhttpd

A Zig HTTP/1.0+1.1 server that reads `nginx.conf`. TLS 1.3 via OpenSSL. Event
backends: kqueue (macOS) and epoll (Linux).

## Build

Requires Zig 0.17.1 (see `mise.toml`).

```bash
scripts/fetch-deps.sh          # once: OpenSSL, nginx, pcre2, zlib
scripts/build-nginx.sh         # comparison nginx into tools/nginx
scripts/build-zhttpd.sh        # zig-out/bin/zhttpd (ReleaseFast + TLS)
scripts/gen-certs.sh           # self-signed certs in bench/certs (gitignored)
```

The private key for the bench certificate is generated locally and is not in
the repository. Regenerate it with `scripts/gen-certs.sh` before a TLS run.

## Run

```bash
scripts/smoke.sh               # short smoke vs nginx
zig-out/bin/zhttpd -c path/to/nginx.conf
```

## Benchmarks

```bash
bench/run.sh --quick           # short comparison vs nginx and dusty-tuned
bench/run.sh                   # full plan: see bench/PLAN.md
```

Official results are in [bench/RESULTS.md](bench/RESULTS.md). The exact nginx
config is generated from `bench/nginx.conf.in`. Linux epoll runs can use the
dedicated Lima VM described in [bench/lima/README.md](bench/lima/README.md).


## Container image

Images are published to `ghcr.io/pyrlyn/zhttpd` by a **manual** Coolify deploy
(git pull of the branch, `docker build` of this repository's Dockerfile, push,
then deploy). There is no GitHub Actions image-build workflow and no auto-deploy
on git push.

Tag mapping (also in the Coolify workflow comments / pyrlyn/infra `paas/config/apps.yml`):

| Git event | Tags |
| --- | --- |
| push to `dev` | `:dev` and `:dev-<short-sha>` |
| push to `main` | `:prod` and `:latest` |
| release tag `vX.Y.Z` (on main) | `:prod-X.Y.Z`, plus refresh `:prod` and `:latest` |

The dev stand pulls `:dev` (or a pinned `:dev-<sha>`). Production pins `:prod-<version>`.
The image is labelled with `org.opencontainers.image.source=https://github.com/pyrlyn/zhttpd`.
