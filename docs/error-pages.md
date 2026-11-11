# HTTP error pages

[Documentation index](../README.md#documentation)

Built-in error responses use the zhttpd icon, a warm paper background, graphite
text, and a lime accent. The symbol is a pair of chevrons around a packet, with
no letter monogram. Pages include a status code, a short explanation, a home
link, and the server token in the footer.

## When the page appears

No extra files or routes are needed. The HTML, CSS, SVG icon, and favicon are
embedded in the executable. Pages load without JavaScript, remote fonts, or
asset requests and adapt to mobile screens.

The current default-page status codes are:

```text
400 401 402 403 404 405 406 408 409 410 411 412 413 414 415 416 421 429
500 501 502 503 504 505 507
```

These are rendered when the server finalizes a supported error without a custom
body. The renderer does not change the HTTP status code. For example, a missing
file with `try_files $uri $uri/ =404` returns a branded page with status 404.

- Configured `error_page` responses take precedence.
- `return 404 "custom text"` sends that explicit body instead.
- An upstream's own error body is normally passed through.
- Redirects retain their compact nginx-style HTML.
- HEAD responses have the same Content-Length as GET, but no response body.
- 204 and 304 have no body. 444 closes the connection without a response.
- Other error codes without a default page, such as `return 418`, have no
  built-in HTML body unless a custom response is configured.

To hide the version in both the Server header and page footer:

```nginx
server_tokens off;
```

This leaves the `zhttpd` product name visible.

## Custom pages

Inside a server with `root html`, configure:

```nginx
error_page 404 /errors/404.html;
error_page 500 502 503 504 /errors/50x.html;
location ^~ /errors/ {
    internal;
}
```

Create `html/errors/404.html` and `html/errors/50x.html` beneath the runtime
prefix. Internal redirects can access these files; direct public requests
cannot. A plain `error_page 404 /errors/404.html` retains status 404.

Use `error_page 404 =200 /fallback.html` only if the fallback should intentionally
return 200. For a proxy location, `proxy_intercept_errors on` lets configured
local error-page mappings intercept matching upstream errors.

## Change the branding

| File | Purpose |
| --- | --- |
| [`icon.svg`](../src/http/assets/icon.svg) | Reusable icon; also embedded as the favicon |
| [`error.css`](../src/http/assets/error.css) | Colors, typography, layout and mobile breakpoint |
| [`error_page.zig`](../src/http/error_page.zig) | HTML and per-status headings/descriptions |
| [`response.zig`](../src/http/response.zig) | Status reasons, default-page selection and length checks |

Rebuild and restart the binary after editing embedded assets. The current
worker page buffer is 8192 bytes, defined by `error_page.buffer_size`; tests
check that all supported pages fit and that their lengths are exact.

## Preview and verify

Start the [quick-start server](../README.md#quick-start), then visit
[the missing-page URL](http://localhost:8080/missing). To preview another status,
add a temporary location to the example server and reload:

```nginx
location = /preview-503 {
    return 503;
}
```

```bash
curl -i http://127.0.0.1:8080/missing
curl -I http://127.0.0.1:8080/missing
zig build test
zig build
python3 tests/error-pages.py
```

The Python test starts its own temporary server and checks statuses, GET/HEAD,
Content-Length, server tokens, custom pages, redirects, and bodyless responses.
Default error HTML and its length intentionally differ from nginx in the
comparison smoke test.
