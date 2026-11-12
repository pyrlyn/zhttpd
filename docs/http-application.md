# Native HTTP applications and server policies

The `http_sdk` build module runs synchronous Zig handlers on the existing zhttpd
worker. It uses the same request framing, body limits, timeouts, logging, static
file handlers and optional TLS/HTTP/2/HTTP/3 transports as the executable.
Callbacks must not block the event loop. Request/response values are valid until
the response finishes; allocate response data through `Context.allocator`.

## Run the example

```sh
zig build http-example
zig-out/bin/http-app 127.0.0.1:8080
curl -H 'Content-Type: application/json' -d '{"value":42}' localhost:8080/json
curl -H 'Idempotency-Key: example-1' -d 'create' localhost:8080/items
```

`examples/http/app.zig` demonstrates method routing, JSON, forms, query fields,
cookies, middleware, errors and idempotency. Its in-memory counter is a demo,
not a persistent database. `sdk.stop()` ends the loop; install process signal
handlers as the example does.

## API

```zig
const sdk = @import("http_sdk");
fn handle(ctx: *sdk.Context) !void {
    const value = try ctx.json();
    try ctx.sendJson(200, value);
}
fn middleware(ctx: *sdk.Context, next: *sdk.application.Next) !void {
    try ctx.addHeader("X-App", "example");
    try next.run(ctx);
}
// In main:
// try sdk.serve("127.0.0.1:8080", &.{.{
//     .path = "/items", .methods = &.{"POST"},
//     .application = .{ .handler = handle, .middleware = &.{middleware} },
//     .idempotency = true,
// }}, .{ .max_body_size = 1048576, .gzip = true });
```

Routes match exact paths and distinguish methods. GET includes HEAD; conflicting
method registrations fail. Unsupported methods receive 405 and the union of
allowed methods in `Allow`. OPTIONS can be registered explicitly; CORS policies
handle preflight and `OPTIONS *` returns server capabilities. Static files allow
GET/HEAD; PUT/DELETE do not modify the filesystem. CONNECT tunnelling and TRACE
reflection are not provided.

`Context.request` exposes headers, raw method, normalized path and raw query.
`Context.body` is the complete decoded request body. `query()` and URL-encoded
`form()` decode `%XX` and `+`, preserve case and repeated names, and return up to
256 fields. `json()` requires `application/json` and returns `std.json.Value`.
`form()` also accepts `multipart/form-data`, with quoted boundaries and binary
field values, optional filename and content type. Part headers are limited to
8 KiB. Uploads are kept in bounded memory and are never written to filenames
provided by clients. Malformed input returns 400; unsupported media types 415.

Middleware runs in registration order, can short-circuit by not calling `next`,
and resumes in reverse order after the handler. Calling the same `next` twice is
an error. Exceptions map to the common JSON error body:

```json
{"error":{"status":500,"message":"Internal Server Error"}}
```

Internal error names are not exposed. `BadRequest`, `Unauthorized`, `Forbidden`,
`NotFound`, `Conflict` and `UnsupportedMediaType` map to their HTTP statuses.
Applications can catch errors in middleware to customize the response.
`sendJson`, `redirect`, `addHeader` and `response` support normal responses.
Header names/values are checked; framing headers are owned by the transport.

`getCookie(name)`, `setCookie(name, value, options)` and
`deleteCookie(name, options)` provide cookie handling. Defaults are Path=/,
Secure, HttpOnly and SameSite=Lax. Options include domain, max_age, secure,
http_only and Strict/Lax/None. SameSite=None requires Secure. `__Host-` and
`__Secure-` prefixes are validated. Deletion uses Max-Age=0 and must use the same
path/domain as the original cookie. Multiple Set-Cookie headers are preserved.
These helpers do not create a session store; authentication uses JWT.

## Native TOML settings

These optional settings apply in `[http]` and inherit into `[[http.routes]]`;
a route can override them. Defaults preserve existing behavior.

| Setting | Default | Meaning |
| --- | --- | --- |
| `gzip` | false | Negotiate gzip for eligible local responses |
| `json_errors` | false | Common JSON format for locally generated errors |
| `content_type` | text/plain | Default content type for configured responses |
| `cors_origins` | [] | Exact origins or `*` without credentials; [] disables CORS |
| `cors_methods` | GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS | Permitted preflight methods |
| `cors_headers` | Content-Type, Authorization | Permitted preflight request headers |
| `cors_credentials` | false | Emit Access-Control-Allow-Credentials |
| `rate_limit` | 0 | Requests per second per peer IP and location, per worker; 0 disables |
| `rate_burst` | 1 | Token bucket capacity, 1..1,000,000 |
| `jwt_secret_file` | unset | Enable HS256 verification with a regular local secret file |
| `jwt_issuer`, `jwt_audience` | required with secret | Expected iss/aud |
| `jwt_scope` | empty | Space-separated scopes, all required |

`methods = ["GET"]` on a route enables method selection, including automatic
HEAD. Omitting it preserves the route's existing all-method behavior.
`health_path = "/health"` in `[http]` adds an exact GET/HEAD liveness route,
returning `{"status":"ok"}` with `Cache-Control: no-store`. It deliberately skips
JWT and rate limits; it does not test external services or database readiness.
`header_timeout_ms`, `body_timeout_ms` and `send_timeout_ms` in `[http]` default
to 60000. Existing `max_body_size` and `keepalive_timeout_ms` remain available.

```toml
[server]
compatibility = "self"

[http]
listen = "127.0.0.1:8080"
json_errors = true
gzip = true
health_path = "/health"

[[http.routes]]
path = "/api"
response = "authenticated"
methods = ["GET"]
jwt_secret_file = "jwt.secret"
jwt_issuer = "my-service"
jwt_audience = "my-api"
jwt_scope = "read"
cors_origins = ["https://app.example"]
cors_credentials = true
rate_limit = 10
rate_burst = 20
```

The JWT secret is one line, at least 32 bytes. Provision an unpredictable secret;
there is no built-in default. The verifier accepts only HS256, verifies the MAC
in constant time, requires exp/iss/aud/nonempty sub, checks nbf when present, and
rejects unsupported critical headers and duplicate Authorization headers.
Missing/invalid authentication returns 401 with WWW-Authenticate; missing scopes
return 403. `Context.identity` exposes verified subject and scope. Secret file
changes participate in automatic reload; invalid rotations keep the active
configuration. Tokens are issued by the application or identity provider.

A disallowed CORS origin or preflight method/header receives 403. Successful
preflight receives 204. Origin-dependent replies include Vary: Origin. No origin
is reflected unless explicitly permitted. Credentials with `*` fail validation.

Rate state is bounded to 4096 buckets per worker and resets on worker restart or
reload. Active hash collisions are rejected conservatively instead of evicting
another peer's quota. Rate rejection returns 429 and Retry-After: 1. The key uses
the socket peer, not untrusted forwarding headers. This is not a cluster-wide
quota; multiple workers/nodes maintain separate limits.

Gzip supports local static and in-memory text, JSON, JavaScript and SVG responses
with status 200, from 256 bytes through 8 MiB. It respects gzip;q=0, sets Vary and
correct compressed lengths, handles HEAD, and uses weak validators for static
variants. Range responses, already encoded responses and requests carrying
Authorization/Cookie are not compressed. Responses setting cookies or explicit
application Cache-Control headers or strong application ETags are also excluded. Larger files and upstream
streams remain streamed without local recompression; compressed upstream
responses pass through normally. No external compression library is required.

JSON error mode covers server-generated errors and native handler exceptions.
Application/upstream bodies and explicitly configured `error_page` responses
keep their own formats. Existing nginx `auth_basic`, `auth_request`, `limit_req`
and `gzip` directives remain unsupported; use these native policies instead.

## Configured native applications and TLS

`sdk.serveConfig(cfg)` runs a caller-owned `http.config.Config`, including its
TLS, logging, timeout and static-file settings, in one event loop. Load it with
`zhttpd.app_config.load`, then attach `.application` to the desired location's
`.conf`. Clear that location's `.stmts` when replacing a configured `response`,
so a rewrite-phase return cannot precede the callback. Set `.idempotency = true`
on its configuration when needed. The standalone executable does not load Zig
functions dynamically. `serve(address, routes, options)` is the simpler plain
HTTP entry point; use `serveConfig` for configured TLS listeners.

## Idempotency contract

Enable `Route.idempotency` for native mutating handlers. GET/HEAD/OPTIONS bypass
this mechanism. Other methods require an Idempotency-Key of 1..128 printable
non-space ASCII characters. The key is scoped by location, host, method, path
and authenticated subject (peer IP without JWT). A fingerprint covers target,
body and canonicalized application headers, plus verified scopes.

Matching retries replay the handler status, headers and body with
`Idempotency-Replayed: true`, without calling the handler again. Middleware runs
on every attempt, including authentication/authorization and response transforms.
Only the handler result is cached; middleware headers are recomputed. A different fingerprint
returns 409. Errors are retained too: an exception does not prove that an
application made no side effects. Each worker retains at most 128 entries for
five minutes and refuses new keys with 503 when full. Responses up to 64 KiB
including headers are retained; larger responses leave a tombstone, making a
retry return 409 instead of executing again.

State is in memory and disappears on restart/reload. Separate workers/nodes do
not share it. This does not promise exactly-once execution across crashes or
atomically commit external database changes. For that guarantee, store the key
and business mutation in the same durable application transaction. Native
applications use the single-worker SDK by default.

## Verification

```sh
zig build test
zig build test-features
```

`test-features` builds the server and native example and exercises their real
HTTP interfaces using Python's standard library. It is included in the core E2E
group. Existing protocol, TLS, configuration, logging and gateway tests remain
applicable.
