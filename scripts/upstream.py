#!/usr/bin/env python3
"""Tiny HTTP/1.0 echo upstream for smoke tests: answers JSON describing the request."""
import http.server, json, sys

class Echo(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        hdrs = {k.lower(): v for k, v in self.headers.items() if k.lower() not in ("user-agent",)}
        out = json.dumps({"method": self.command, "path": self.path, "headers": hdrs,
                          "body": body.decode("latin1")}, sort_keys=True).encode() + b"\n"
        code = 200
        if self.path.startswith("/status/"):
            code = int(self.path.split("/")[2])
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Upstream", "echo")
        if "nolen" not in self.path:
            self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = handle_any

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Echo).serve_forever()
