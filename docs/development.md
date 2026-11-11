# Development

[Documentation index](../README.md#documentation)

## Source map

| Location | Responsibility |
| --- | --- |
| `src/main.zig` | CLI, configuration loading, master process, signals and worker lifecycle |
| `src/root.zig` | Library entry point and test imports |
| `src/nginx/` | nginx parser, directive catalog and adapter |
| `src/http/config.zig`, `src/app_config.zig` | Shared HTTP model and native TOML settings |
| `src/apache.zig`, `src/litespeed.zig`, `src/caddy.zig` | Other configuration adapters |
| `src/http/request.zig` | HTTP request parsing |
| `src/http/response.zig` | Status reasons, response-page helpers and dates |
| `src/http/error_page.zig`, `src/http/assets/` | Branded HTML, CSS and icon |
| `src/server/worker.zig`, `loop.zig`, `conn.zig` | Event loop, workers, connections and buffers |
| `src/server/router.zig`, `handler.zig`, `vars.zig` | Host/location matching, request phases and variables |
| `src/server/proxy.zig` | HTTP upstream handling |
| `src/server/tls.zig` | Nonblocking TLS, ALPN and SNI |
| `src/server/multiplex.zig`, `multiplex.c` | HTTP/2 and HTTP/3 stream transport |
| `modules/raft/`, `scripts/build-raft.sh` | Optional durable Raft companion, state machine, TLS API and committed metrics/config exports |
| `src/load_balancer.zig`, `src/load_balancer/backend.c` | Independent load policy, one-hop redirect URLs and background shared metrics |
| `src/server/filecache.zig` | Open-file cache |
| `src/os.zig`, `src/server/net.zig` | Platform and socket operations |
| `tests/fixtures/` | nginx and Debian configuration fixtures |

A request passes through server rewrites, location selection and rewrites,
access checks, `try_files`, and then static or proxy content handling. Local
errors go through configured `error_page` mappings before the default renderer.

## Build and unit tests

```bash
zig build test
zig build
zig build -Doptimize=ReleaseFast
```

`zig build test` includes configuration, routing, parsing, dates, response pages,
and the real-world configuration fixtures. Run it from the repository root so
fixture paths resolve. The default build disables TLS; add `-Dtls=true` and the
appropriate OpenSSL prefix to test a TLS build.

## GitHub Actions CI

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests and manual
workflow dispatch. It uses the versions in `mise.toml` and the locked Python
E2E dependencies.

- Linux and macOS build the release server and Raft companion, run Zig unit
  tests, Go race/mTLS tests, and real load-balancer/Raft cluster E2E tests.
- A separate Linux job builds the pinned OpenSSL and HTTP codec libraries,
  compiles the complete server, and runs unit tests plus the full HTTP/1.1,
  HTTP/2, HTTP/3, configuration/reload, ACME, gateway and WebSocket E2E suite.

The ACME/DNS and Raft checks use local fixtures and require no production
credentials. Compiled protocol dependencies and mise toolchains are cached;
changes to their versions or build scripts invalidate the native dependency
cache. Job timeouts and per-ref cancellation prevent obsolete runs from piling
up. The workflow token has read-only repository access.

## Full protocol and module checks

```bash
mise run test:e2e
```

This prepares dependencies and tests actual HTTP/1.1, HTTP/2 and HTTP/3 clients,
multiplexed streams, uploads, cancellation, virtual hosts, reload, configuration
adapters, automatic config reload, logging, FastCGI/WSGI, local ACME
issuance/renewal/reload and WebSocket examples.
ACME tests use a local CA; they do not request public certificates.
After preparing dependencies, run just the protocol checks with:

```bash
mise exec -- zig build test-protocols -Dtls=true -Dhttp=true \
  -Dopenssl=deps/openssl-install -Dhttp-deps=deps/http-install \
  -De2e-python=.run/venv/bin/python
```

After building with TLS and HTTP/2+HTTP/3, run just the ACME reload checks with:

```bash
mise exec -- .run/venv/bin/python tests/acme_reload_e2e.py zig-out/bin/zhttpd
mise exec -- .run/venv/bin/python tests/acme_reload_e2e.py zig-out/bin/zhttpd --auto
```

Optional trailing mode names (`self`, `nginx`, `apache`, `litespeed`, `caddy`)
select adapters; the default tests all five with both HTTP-01 and DNS-01.
The suite checks certificate additions/removals, SAN changes, cached re-addition,
atomic failure, superseded issuance and timeout recovery without restarting master.
`--auto` runs the same scenarios by saving configuration files instead of sending
reload signals.

The configuration watcher checks also run with a minimal build:

```bash
mise exec -- .run/venv/bin/python tests/auto_reload_e2e.py zig-out/bin/zhttpd
```

They cover all five adapters, native includes/imports, glob membership, invalid
and missing files, atomic saves, debounce, and disabling/re-enabling the watcher.

With TLS and HTTP/2+HTTP/3 enabled, check certificate/key and DNS env rotation:

```bash
mise exec -- .run/venv/bin/python tests/tls_files_e2e.py zig-out/bin/zhttpd
mise exec -- .run/venv/bin/python tests/dns_env_reload_e2e.py zig-out/bin/zhttpd
```

Both accept optional trailing adapter names. These checks cover mismatched,
missing and encrypted keys, atomic and symlink replacement, independent DNS
credential retries, changes during issuance, and prevention of reload loops.

## HTTP error regression checks

```bash
python3 tests/error-pages.py
python3 tests/error-pages.py /absolute/path/to/zhttpd
```

This uses Python's standard library and a temporary config and port. It checks
response codes, GET/HEAD, body lengths, server tokens, custom `error_page`
responses, redirects, and 204/304 handling. It terminates its test server on exit.

For a TLS-enabled build, run `python3 tests/tls-io.py /path/to/zhttpd`.
This generates a temporary test certificate with the `openssl` CLI and checks
TLS 1.2 and 1.3 record fragmentation, coalesced records, pipelining, request body
draining, HEAD/ranges, large responses with a slow reader, idle connections,
Last-Modified headers, changes to open files, and TCP half-close with a pending
response. Set `OPENSSL_CLI=/path/to/openssl` to use OpenSSL 3 for the additional
TLS 1.3 KeyUpdate checks (older CLIs explicitly skip this check). `OPENSSL_BIN`
is also supported, so the normal mise environment uses the pinned OpenSSL.
These TLS checks and the benchmark-gate checks below run in `test-e2e` as well.

`python3 tests/bench-target.py` verifies that the performance gate rejects p99
regressions against nginx or a saved baseline, incomplete samples, errors, and
insufficient throughput.

## nginx comparison smoke checks

Build the TLS binary and comparison nginx using the
[TLS instructions](getting-started.md#build-with-tls), then:

```bash
scripts/gen-certs.sh
scripts/smoke.sh
```

To run only zhttpd:

```bash
NGINX=none scripts/smoke.sh
```

The smoke script still needs a TLS-enabled zhttpd binary when nginx is disabled.
It starts an HTTP upstream and exercises static files, rewriting, proxying,
virtual hosts, TLS, request limits, ranges, keep-alive, and pipelining. Results
are written beneath `.run/smoke/`. `ZHTTPD`, `NGINX`, `PORT`, `TLSPORT`, and
`UPORT` can override its binaries and ports.

The script reports normalized response differences; it is not a complete
pass/fail assertion suite when run without nginx. Branded default error bodies
and Content-Length values intentionally differ from nginx, so inspect those
differences rather than expecting an empty diff. Custom error bodies should
still match.

`scripts/check-real-configs.py /path/to/infra` is an optional check against an
external infrastructure checkout. It copies and adapts configs under
`.run/realconf/`; it requires that checkout, both server binaries, and the local
test certificates. It is not needed for the self-contained unit tests.

## Benchmarks

```bash
bench/run.sh --quick
bench/run.sh
```

Read [the plan](../bench/PLAN.md) for prerequisites and methodology, and
[the results](../bench/RESULTS.md) for recorded measurements. A dedicated Linux
benchmark setup is described in [bench/lima/README.md](../bench/lima/README.md).

## Documentation maintenance

Keep runnable commands rooted at the repository directory, and distinguish
implemented behavior from ignored compatibility directives. Check example
configs with the current binary's `-t --strict` command. The directive catalog
in `src/nginx/directives.zig` is the source for `zhttpd --directives`; use it rather
than maintaining a separate full directive list. When adding a built-in status
page, update its explanation, the documented code list, and the buffer/length
checks.
