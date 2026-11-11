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
| `src/server/tls.zig` | Nonblocking OpenSSL integration |
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

## HTTP error regression checks

```bash
python3 tests/error-pages.py
python3 tests/error-pages.py /absolute/path/to/zhttpd
```

This uses Python's standard library and a temporary config and port. It checks
response codes, GET/HEAD, body lengths, server tokens, custom `error_page`
responses, redirects, and 204/304 handling. It terminates its test server on exit.

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
