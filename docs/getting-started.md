# Getting started

[Documentation index](../README.md#documentation)

Run the commands below from the repository root. zhttpd targets macOS and Linux
and requires Zig **0.17.1**, as pinned in `mise.toml` and `build.zig.zon`.
Python 3 is used by the HTTP tests; curl is used by the smoke checks.

## Build plain HTTP

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/zhttpd -V
```

TLS is disabled by default. The build produces `zig-out/bin/zhttpd` without
requiring the comparison nginx or downloaded OpenSSL sources. HTTP/2 and HTTP/3 are also disabled. See the
[README quick start](../README.md#quick-start) for a complete runnable example.

## Build with TLS

The full build uses pinned OpenSSL and nghttp2 libraries; HTTP/3 comes from the
in-tree zquic package:

```bash
mise trust
mise install
mise run build
mise exec -- zig-out/bin/zhttpd -V
```

`mise run build` downloads and verifies the pinned sources, builds static TLS
and codec libraries, and enables HTTP/2 and HTTP/3. For an HTTP/1.x TLS-only
build with system OpenSSL development libraries, use
`zig build -Doptimize=ReleaseFast -Dtls=true`.

For a full build using existing dependency installations:

```bash
mise exec -- zig build -Doptimize=ReleaseFast -Dtls=true -Dhttp=true \
  -Dopenssl="$PWD/deps/openssl-install" -Dhttp-deps="$PWD/deps/http-install"
```

The prefixes must contain headers in `include/` and static libraries in `lib/`.
`mise run deps:nginx` builds the optional reference nginx. `mise run deps:certs`
generates self-signed local certificates in the ignored `bench/certs/` directory.
See [HTTP/2 and HTTP/3](../README.md#http2-and-http3) for listener configuration,
ALPN, UDP reachability, and current protocol limitations.

For the optional AWS-LC backend (C compiler, CMake, Ninja and git required):

```bash
bash scripts/build-aws-lc.sh
zig build -Doptimize=ReleaseFast -Dtls=true -Dtls-backend=aws_lc \
  -Dopenssl="$PWD/deps/aws-lc-install"
```

The script pins AWS-LC 5.14.0 and applies a versioned Linux Apple CPU-detection
patch; other tracked dependency edits are rejected. OpenSSL stays the default;
switch back by omitting `-Dtls-backend` and selecting its library prefix.
See [backend validation](development.md) and the measured scope and limits in
the [HTTPS/TLS report](../bench/TLS-OPTIMIZATION.md).

## Command-line reference

| Option | Behavior |
| --- | --- |
| `-h`, `-?` | Show usage |
| `-v` | Show zhttpd version |
| `-V` | Show version, Zig version, event backend and TLS build status |
| `-c FILE` | Read a configuration file; default `config.toml`; direct `.conf` files retain nginx parsing |
| `-p DIRECTORY` | Set the prefix for relative runtime paths |
| `-t` | Validate configuration, including certificates in a TLS build, then exit |
| `-T` | Validate and dump the parsed configuration, then exit |
| `-q` | Suppress validation success messages and ignored-directive warnings |
| `--strict` | Reject unknown and ignored nginx directives |
| `--compatibility FORMAT` | Select a direct nginx, Apache, LiteSpeed or Caddy file |
| `--directives` | Print the supported/ignored directive table as Markdown |
| `-s SIGNAL` | Signal the master process using the configured PID file |
| `-g DIRECTIVES` | Apply global overrides for workers and PID; daemon/master-process flags are accepted but do not change process mode |

TOML uses explicit module and compatibility settings; see
[native configuration](configuration.md). For direct nginx files, read the
[compatibility notes](nginx-configuration.md#compatibility). `-t` does not prove
that a port can be bound or that a document root or upstream is reachable.

## Process lifecycle

zhttpd always runs in the foreground with a master process and worker processes.
Keep the same config and prefix when sending a signal. After starting the README
example, use another terminal:

```bash
zig-out/bin/zhttpd -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf" -s reload
zig-out/bin/zhttpd -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf" -s reopen
zig-out/bin/zhttpd -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf" -s quit
```

`reload` reads the configuration and starts a new worker generation; invalid
configuration keeps the previous generation. `reopen` reopens worker logs.
`quit` requests graceful shutdown; `stop` requests immediate shutdown. Signal
commands need a valid PID file; `pid off` disables that mechanism. Create log and
PID directories before starting the server.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `listen ... ssl` rejected | Build with `-Dtls=true` and verify with `-V` |
| Missing `libssl.a` or headers | Build OpenSSL first or correct `OPENSSL` |
| Address already in use | Change `listen` or stop the process owning that port |
| Unexpected 404 | Check `root`, `alias`, `try_files`, and the `-p` prefix |
| No branded error page | Check `error_page`, explicit `return` bodies, proxy responses, or an SPA fallback |
| Configuration accepted but feature absent | Inspect warnings and `--directives`; accepted can mean ignored |
