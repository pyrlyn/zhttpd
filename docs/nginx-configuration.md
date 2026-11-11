# nginx configuration

[Documentation index](../README.md#documentation)

zhttpd reads nginx-style blocks, semicolon-terminated directives, variables,
comments, and included files. Start from the complete
[example configuration](examples/nginx.conf).

## Paths and validation

Pass an explicit prefix for predictable behavior:

```bash
zig-out/bin/zhttpd -t --strict -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf"
```

Relative `root`, log, and PID paths resolve against `-p`. Relative includes
resolve against the configuration directory. A relative `-c` is resolved from
the current working directory, independently of `-p`.

Without `-p`, a configuration in a directory named `conf` uses that directory's
parent as prefix. Otherwise zhttpd uses `/usr/share/nginx/` if it exists, or the
configuration directory. Explicit paths avoid differences between machines.

## Static files and routing

Inside a `server` block:

```nginx
root html;
index index.html;
location / {
    try_files $uri $uri/ =404;
}
location = /health {
    default_type text/plain;
    return 200 "ok\n";
}
location /private/ {
    deny all;
}
```

`root` appends the request URI to the directory. `alias` replaces the matched
location prefix. Exact (`=`), prefix, `^~`, regex (`~`, `~*`), and named (`@name`)
locations are supported. MIME mappings come from `types` or an included
`mime.types`; set `default_type` for unmatched extensions.

`try_files ... =404` gives missing resources a real 404 response. A fallback such
as `try_files $uri $uri/ /index.html` serves the application entry point instead;
use it only when that is the intended routing behavior.

## HTTP reverse proxy

Add the upstream inside `http`, and the location inside the relevant `server`:

```nginx
upstream app {
    server 127.0.0.1:9000;
}
```

```nginx
location /api/ {
    proxy_pass http://app/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
    client_max_body_size 1m;
}
```

For this prefix location, the trailing `/` in `proxy_pass http://app/` replaces
`/api/`: `/api/users` becomes `/users`. With `proxy_pass http://app` the request
URI retains `/api/`. Backend availability is checked when processing a request,
not by `-t`.

Only HTTP upstreams are supported; `https://` upstreams are not implemented.
Upstream error responses are passed through by default. To use local custom
`error_page` rules for upstream errors, enable `proxy_intercept_errors on` in
the proxy location. See [error handling](error-pages.md).

## TLS

A TLS-enabled binary can use these directives inside `server`:

```nginx
listen 8443 ssl;
server_name example.test;
ssl_certificate /absolute/path/to/fullchain.pem;
ssl_certificate_key /absolute/path/to/privkey.pem;
# For an encrypted PEM key (optional):
# ssl_password_file /absolute/path/to/tls-passwords.txt;
ssl_protocols TLSv1.2 TLSv1.3;
```

The certificate chain and private key must exist and match. Validate with `-t`
before reloading. Separate TLS virtual hosts can select certificates through
SNI. [Build instructions](getting-started.md#build-with-tls) explain the OpenSSL
options.

## Compatibility

HTTP/1.0 and HTTP/1.1 are always available. HTTP/2 and HTTP/3 require a
TLS/protocol-enabled build; see [protocol configuration](../README.md#http2-and-http3).
For native TOML and the other adapters, see [configuration](configuration.md).

Use `zig-out/bin/zhttpd --directives` for the full table. Configuration support
has three outcomes:

| Category | Behavior |
| --- | --- |
| Supported | Applied, with any limitations noted in the table |
| Known but ignored | Warning by default; an error with `--strict`; no implementation of the requested feature |
| Unknown | Warning by default; an error with `--strict` |

Specific limitations matter when reusing an nginx config:

- `auth_basic`, `auth_request`, and client-certificate verification directives
  are ignored; they do not protect routes.
- `user` does not drop privileges. Run the process under the intended OS account.
- Rate limiting and gzip directives are ignored.
- FastCGI TCP responders are supported. Unix FastCGI and `fastcgi_split_path_info`
  are unsupported and produce 502. uWSGI, SCGI, and gRPC handlers are not
  implemented. See [adapter coverage](compatibility.md).
- nginx dynamic modules cannot be loaded. `stream` and `mail` blocks are skipped.
- The request header buffer is fixed at 16 KiB. Request bodies are buffered in
  memory up to `client_max_body_size`; body-buffer and temporary-file tuning
  directives are ignored.
- Upstream weight, backup, and failure-tuning parameters are ignored. The
  `resolver` directive does not configure a dynamic DNS resolver.

A successful configuration parse is not a claim of complete nginx behavior.
