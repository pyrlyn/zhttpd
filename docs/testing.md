# Tests


```bash
mise run test                 # all independent module + fixture unit tests
mise run test:e2e             # complete wire suite, builds required dependencies
mise run examples             # shared WebSocket examples in Zig, C and C++
```

The E2E suite starts actual binaries and tests HTTP/1.1 fallback, h2 and aioquic
HTTP/3 clients, multiplexing, cancellation, malformed requests, static/HEAD,
large uploads, proxy, ACLs, limits, vhosts, reload and shutdown. It also tests
all config adapters and module gates, log contents/escaping/USR1 reopening,
all three WebSocket SDK examples with the same contract, FastCGI framing and a
real WSGI app. ACME tests run the real pinned lego client against a local HTTPS
CA in every compatibility mode, check multi-domain HTTP-01 and wildcard DNS-01
with a local DNS provider/UDP server, issue and renew SAN certificates, verify
TXT cleanup, failure retention and isolation of unrelated SNI certificates.
Independent certificate tests use different DNS providers/credential files,
check exact/wildcard SNI priority, HTTP/2 and HTTP/3 handshakes, independent
renewal after provider failure, and configuration reordering during renewal.
Reload tests cover adding/removing records and SANs, cached re-addition, atomic
failure, superseded issuance, timeouts, and removal of the final managed certificate
in all five modes with both HTTP-01 and DNS-01, both manually and through file watching.
Watcher tests cover debounced saves, same-size/mtime edits, symlink swaps,
missing/invalid dependency recovery, glob membership changes, direct native configs
and accepted connections awaiting their first request during reload. TLS material
tests rotate certs and keys separately, retain working contexts on invalid files,
and exercise atomic/symlink replacement. Encrypted-key tests cover PKCS#8 and
traditional PEM, multiple passwords, SNI, invalid/missing password recovery,
nonblocking FIFO rejection, and native nginx inheritance. Real-lego DNS env tests cover per-certificate
retry isolation, missing files, credentials changed during issuance and loop prevention.
No public certificate is requested. Fixtures use temporary files/ports and
terminate their own process groups on failure.
