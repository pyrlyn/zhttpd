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
| `src/server/tls.zig`, `aws_lc.c` | Nonblocking TLS and optional AWS-LC adapter |
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

The optional AWS-LC 5.14.0 backend uses its optimized TLS/crypto implementation.
The versioned Linux CPU-detection patch recognizes Apple Silicon via MIDR while
retaining HWCAP instruction checks. Algorithms and assembly stay upstream. Build
the pinned dependency with `bash scripts/build-aws-lc.sh`, then add
`-Dtls=true -Dtls-backend=aws_lc -Dopenssl="$PWD/deps/aws-lc-install"` to the
build and test commands. OpenSSL remains the default; omit `-Dtls-backend` and
use the OpenSSL prefix to switch back. AWS-LC's headers and static libraries must
come from the same installation. `zhttpd -V` identifies the selected backend.
This option covers HTTP/1.1; zquic needs OpenSSL's QUIC TLS callback API.
The build rejects combining AWS-LC with `-Dhttp=true`; use the default OpenSSL
backend for HTTP/2 and HTTP/3. OpenSSL providers are not supported by AWS-LC.

Run `OPENSSL_CLI=/path/to/openssl3 python3 tests/tls-config.py /path/to/zhttpd`
for SNI rejection, configured cipher/group restrictions and TLS 1.2/1.3 ticket
resumption. Run this and `tests/tls-io.py` against both TLS builds when changing
the adapter. The AWS-LC adapter uses public typed configuration calls and a
bounded ciphertext BIO; it does not change the negotiated TLS record format.

AWS-LC initializes ticket keys before the worker fork, so initial ticket
resumption works across workers. Its automatic ticket-key rotation remains
active (48 hours in the pinned release); rotations are worker-local, so tickets
issued after rotation may fall back to a full handshake on another worker.
As with the existing OpenSSL implementation, nginx's shared session cache is
not a shared-memory cache in zhttpd. The performance report distinguishes fresh
handshakes from resumption and does not claim complete nginx TLS compatibility.

## GitHub Actions CI

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests and manual
workflow dispatch. It uses the versions in `mise.toml` and the locked Python
E2E dependencies.

- Linux and macOS build the release server and Raft companion, run Zig unit
  tests, Go race/mTLS tests, and real load-balancer/Raft cluster E2E tests.
- Nine parallel Linux E2E groups cover the full HTTP/1.1, HTTP/2, HTTP/3,
  configuration/reload, TLS/password, ACME, gateway and WebSocket suite. Each
  runner has isolated fixtures. ACME/DNS groups (`reload`, `acme`, `encryption`,
  `rotation`, `acme_reload`, `acme_auto`) fan out by adapter: `self`, `nginx`,
  `apache`, `litespeed`, `caddy`. At most five test processes run per runner,
  sharing the compiled server but using separate temporary directories and local
  CA/DNS servers. Every shard is required; HTTP-01/DNS-01 and manual/automatic
  reload scenarios remain intact. The `core` group also builds the release server
  and runs TLS/HTTP unit tests.
  `fail-fast: false` lets all groups report failures.

The ACME/DNS and Raft checks use local fixtures and require no production
credentials. Mise toolchains, compiled protocol dependencies, Zig's local/global
compilation caches, and Go's module/build caches are reused. Cache keys separate
OS, architecture, native/protocol builds and pinned dependency versions. A new
commit restores the previous compatible compilation cache; compilers validate
source changes before reuse. Unit tests always execute (including Go's
`-race -count=1`); cached test results never replace a check. Job timeouts and
per-ref cancellation prevent obsolete runs from piling up. Manual and automatic runs use separate concurrency groups so manual checks
do not cancel push/PR checks. The workflow token has read-only repository access.

## Full protocol and module checks

```bash
mise run test:e2e
```

This prepares dependencies and tests actual HTTP/1.1, HTTP/2 and HTTP/3 clients,
multiplexed streams, uploads, cancellation, virtual hosts, reload, configuration
adapters, automatic config reload, logging, FastCGI/WSGI, local ACME
issuance/renewal/reload and WebSocket examples.
ACME tests use a local CA; they do not request public certificates.
`zig build test-e2e` still runs every E2E check sequentially. To select the same
subset as a CI runner, add `-De2e-group=core`, `reload`, `tls`, `sni`, `acme`,
`encryption`, `rotation`, `acme_reload` or `acme_auto`. No group is selected by
default; an invalid group is rejected. Add `-De2e-parallel-adapters=true -j5`
to use CI's adapter parallelism; omit it for the original sequential execution.
The `core`, `tls` and `sni` groups retain their existing execution order.

After preparing dependencies, run just the protocol checks with:

```bash
mise exec -- zig build test-protocols -Dtls=true -Dhttp=true \
  -Dopenssl=deps/openssl-install -Dhttp-deps=deps/http-install \
  -De2e-python=.run/venv/bin/python
```

The protocol suite also downloads large HTTP/3 responses with small flow-control
windows and deterministic packet loss, checking exact bodies before and after
reload. A UDP relay also exercises reordering and late duplicate packets.
A second relay switches the client to a new UDP source port mid-download and
checks that the response completes on the validated new path.
The OpenSSL build still applies `deps/patches/openssl-quic-stream-gc.patch` and
runs `tests/quic-stream-gc.c` against the installed archive; zhttpd no longer
uses OpenSSL's QUIC stack, but nginx comparison builds do. With `-Dhttp=true`,
`zig build test` also runs the zquic unit tests (varints, packet protection
and RFC 9001 test vectors, ACK ranges, RTT/NewReno, stream buffers, transport
parameters and QPACK) and the HTTP/2 codec test; connection behaviour is
covered by the protocol suite. Run them alone with:

```bash
mise exec -- zig build test-quic test-h2-codec -Dtls=true -Dhttp=true \
  -Dopenssl=deps/openssl-install -Dhttp-deps=deps/http-install
```

The package also builds and tests on its own from `modules/quic`; see its
[README](../modules/quic/README.md).

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
Set `OPENSSL_CLI` to the OpenSSL 3.5.9 CLI used by the KeyUpdate checks
(`s_client -adv` is unavailable in older distribution CLIs). The test streams
and hashes 100 MiB responses over HTTP and both TLS versions.
This generates a temporary test certificate with the `openssl` CLI and checks
TLS 1.2 and 1.3 record fragmentation, coalesced records, pipelining, request body
draining, HEAD/ranges, large responses with a slow reader, idle connections,
Last-Modified headers, changes to open files, and TCP half-close with a pending
response. Set `OPENSSL_CLI=/path/to/openssl` to use OpenSSL 3 for the additional
TLS 1.3 KeyUpdate checks (older CLIs explicitly skip this check).
ETag checks change file size and timestamp independently, revalidate metadata,
and verify conditional 200/304 responses. Unit tests also verify that unrelated
queued TLS errors do not corrupt nonblocking handshake/read/write retries.
`OPENSSL_BIN` is also supported, so the normal mise environment uses the pinned OpenSSL.
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
