# Development

[Documentation index](../README.md#documentation)

## Source map

| Location | Responsibility |
| --- | --- |
| `src/main.zig` | CLI, configuration loading, master process, signals and worker lifecycle |
| `src/root.zig` | Library entry point and test imports |
| `src/conf/` | nginx-style parser, directive catalog, configuration, expressions and diagnostics |
| `src/http/request.zig` | HTTP request parsing |
| `src/http/response.zig` | Status reasons, response-page helpers and dates |
| `src/http/error_page.zig`, `src/http/assets/` | Branded HTML, CSS and icon |
| `src/server/worker.zig`, `loop.zig`, `conn.zig` | Event loop, workers, connections and buffers |
| `src/server/router.zig`, `handler.zig`, `vars.zig` | Host/location matching, request phases and variables |
| `src/server/proxy.zig` | HTTP upstream handling |
| `src/server/tls.zig`, `aws_lc.c` | Nonblocking TLS and optional AWS-LC adapter |
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
This option covers the HTTP/1.1 server in this branch; it does not provide an
OpenSSL QUIC API. Do not assume compatibility with OpenSSL providers or another
branch's HTTP/3 implementation.

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
in `src/conf/directives.zig` is the source for `zhttpd --directives`; use it rather
than maintaining a separate full directive list. When adding a built-in status
page, update its explanation, the documented code list, and the buffer/length
checks.
