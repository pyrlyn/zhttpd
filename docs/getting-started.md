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
requiring the comparison nginx or downloaded OpenSSL sources. See the
[README quick start](../README.md#quick-start) for a complete runnable example.

## Build with TLS

With OpenSSL development libraries already available to the linker:

```bash
zig build -Doptimize=ReleaseFast -Dtls=true
```

Alternatively, use the repository's source-build scripts. They require a C
build toolchain, make, Perl, curl, tar, and `shasum`:

```bash
scripts/fetch-deps.sh
scripts/build-nginx.sh
scripts/build-zhttpd.sh
zig-out/bin/zhttpd -V
```

`build-nginx.sh` builds both the static OpenSSL installation in
`deps/openssl-install` and the comparison nginx in `tools/nginx`. The final
script links zhttpd against that OpenSSL installation. To use another prefix:

```bash
OPENSSL=/absolute/path/to/openssl scripts/build-zhttpd.sh
```

That prefix must contain headers in `include/` and static `libssl.a` and
`libcrypto.a` in `lib/`. For local smoke-test certificates, run
`scripts/gen-certs.sh`; its output is written to the ignored `bench/certs/`
directory. These self-signed certificates are for testing.

## Command-line reference

| Option | Behavior |
| --- | --- |
| `-h`, `-?` | Show usage |
| `-v` | Show zhttpd version |
| `-V` | Show version, Zig version, event backend and TLS build status |
| `-c FILE` | Read a configuration file; default `/etc/nginx/nginx.conf` |
| `-p DIRECTORY` | Set the prefix for relative runtime paths |
| `-t` | Validate configuration, including certificates in a TLS build, then exit |
| `-T` | Validate and dump the parsed configuration, then exit |
| `-q` | Suppress validation success messages and ignored-directive warnings |
| `--strict` | Treat unknown directives as errors |
| `--directives` | Print the supported/ignored directive table as Markdown |
| `-s SIGNAL` | Signal the master process using the configured PID file |
| `-g DIRECTIVES` | Apply global overrides for workers and PID; daemon/master-process flags are accepted but do not change process mode |

`--strict` does not reject known directives marked as ignored. Read the warnings
and [compatibility notes](configuration.md#compatibility). `-t` does not prove
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
