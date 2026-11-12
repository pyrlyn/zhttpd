//! Minimal reverse proxy: HTTP/1.0 or 1.1 to the upstream, one connection per request
//! (`Connection: close`), response streamed back with nginx-like header handling.
//!
//! Buffers: the upstream request head is built in the per-request arena; upstream
//! response bytes are read straight into the connection's write buffer and forwarded
//! from there (re-chunked for HTTP/1.1 clients when the length is unknown).
const std = @import("std");
const c = std.c;
const config = @import("../http/config.zig");
const Addr = @import("../http/addr.zig").Addr;
const net = @import("net.zig");
const vars = @import("vars.zig");
const handler = @import("handler.zig");
const request = @import("../http/request.zig");
const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const fastcgi = @import("fastcgi.zig");

pub const Phase = enum { idle, connecting, sending, reading_head, streaming };
const Framing = enum { none, length, chunked, close };

pub const Upstream = struct {
    fcgi: bool = false,
    request_owned: ?[]u8 = null,
    fcgi_decoder: @import("fastcgi").Decoder = .{},
    fcgi_buffer: [8192]u8 = undefined,
    fcgi_pos: usize = 0,
    fcgi_len: usize = 0,
    fd: c_int = -1,
    phase: Phase = .idle,
    writable: bool = false,
    tries: u8 = 0,
    first_addr: usize = 0,
    addr: Addr = .{},
    req_head: []const u8 = "",
    head_off: usize = 0,
    body_off: usize = 0,
    rlen: usize = 0,
    framing: Framing = .none,
    remaining: u64 = 0,
    decoder: request.ChunkedDecoder = .{},
    rechunk: bool = false,
    eof: bool = false,
    finished: bool = false,
    head_sent: bool = false,
    size_line: [20]u8 = undefined,
    ups: ?*config.Upstream = null,
    dyn: config.Upstream = .{ .name = "", .addrs = &.{} },
    dyn_addr: [1]Addr = undefined,
    addr_text: [64]u8 = undefined,
};

pub fn release(conn: *Conn) void {
    disconnect(conn);
    if (conn.up.request_owned) |bytes| {
        conn.w.gpa.free(bytes);
        conn.up.request_owned = null;
    }
}
fn disconnect(conn: *Conn) void {
    const up = &conn.up;
    if (up.fd >= 0) {
        conn.w.loop.remove(up.fd);
        net.close(up.fd);
        up.fd = -1;
    }
    up.phase = .idle;
}

/// Called once the request body (if any) is in memory.
pub fn start(conn: *Conn) void {
    const lc = conn.ctx.conf;
    const p = lc.proxy.?;
    conn.state = .proxy;
    conn.up = .{};
    conn.up.ups = p.upstream;
    if (p.dyn_host) |dh| {
        if (!resolveDynamic(conn, dh)) return;
    }
    conn.up.fcgi = lc.gateway != .http;
    conn.up.req_head = (if (conn.up.fcgi) fastcgi.request(conn) else buildRequest(conn, p)) catch {
        handler.finalize(conn, 500);
        conn.state = .sending;
        return;
    };
    if (conn.up.fcgi) conn.up.request_owned = @constCast(conn.up.req_head);
    const ups = conn.up.ups.?;
    conn.up.first_addr = ups.rr;
    ups.rr +%= 1;
    connectNext(conn);
}

/// `proxy_pass http://$var`: the value must name an upstream block or be IP[:port].
fn resolveDynamic(conn: *Conn, dh: @import("expression").Expr) bool {
    const hostport = vars.eval(conn.arena(), &conn.ctx, dh) catch "";
    for (conn.w.cfg.upstreams) |u| if (std.mem.eql(u8, u.name, hostport)) {
        conn.up.ups = u;
        conn.ctx.proxy_host = hostport;
        return true;
    };
    const addr_mod = @import("../http/addr.zig");
    if (addr_mod.parseHostPort(hostport, 80)) |hp| {
        const literal = std.mem.eql(u8, hp.host, "localhost") or addr_mod.parseIp4(hp.host) != null or (hp.host.len > 0 and hp.host[0] == '[');
        if (literal) {
            conn.up.dyn_addr[0] = hp.addr;
            conn.up.dyn = .{ .name = hostport, .addrs = &conn.up.dyn_addr };
            conn.up.ups = &conn.up.dyn;
            conn.ctx.proxy_host = if (std.mem.endsWith(u8, hostport, ":80")) hostport[0 .. hostport.len - 3] else hostport;
            return true;
        }
    }
    conn.w.errlog(.err, "no resolver defined to resolve {s}", .{hostport});
    handler.finalize(conn, 502);
    conn.state = .sending;
    return false;
}

fn connectNext(conn: *Conn) void {
    const up = &conn.up;
    const ups = up.ups.?;
    while (up.tries < ups.addrs.len) {
        const a = ups.addrs[(up.first_addr + up.tries) % ups.addrs.len];
        up.tries += 1;
        up.addr = a;
        var e: c_int = 0;
        const fd = net.connectStart(a, &e) orelse {
            logUpstreamError(conn, "connect() failed", e);
            continue;
        };
        conn.w.loop.add(fd, @intFromPtr(&conn.up_tag)) catch {
            net.close(fd);
            continue;
        };
        up.fd = fd;
        up.phase = .connecting;
        up.writable = false;
        up.head_off = 0;
        up.body_off = 0;
        up.rlen = 0;
        conn.deadline = conn.w.now_ms + conn.ctx.conf.proxy_connect_timeout_ms;
        var ab: [48]u8 = undefined;
        conn.ctx.upstream_addr = std.fmt.bufPrint(&up.addr_text, "{s}:{d}", .{ a.formatIp(&ab), a.port }) catch "";
        return;
    }
    fail(conn, 502);
}

fn logUpstreamError(conn: *Conn, what: []const u8, e: c_int) void {
    var ab: [48]u8 = undefined;
    conn.w.errlog(.err, "{s} ({d}: {s}) while connecting to upstream, upstream: \"http://{s}:{d}\"", .{ what, e, @import("../os.zig").strerror(e), conn.up.addr.formatIp(&ab), conn.up.addr.port });
}

fn fail(conn: *Conn, status: u16) void {
    release(conn);
    if (conn.up.head_sent) {
        // response already started: we can only cut the connection
        conn.keep_alive = false;
        conn.finishRequest();
        return;
    }
    conn.ctx.upstream_status = if (status == 504) 504 else 502;
    handler.finalize(conn, status);
    conn.state = .sending;
}

pub fn onUpstreamEvent(conn: *Conn, writable: bool) void {
    if (writable) conn.up.writable = true;
    conn.drive();
}

pub fn onTimeout(conn: *Conn) void {
    const up = &conn.up;
    conn.w.errlog(.err, "upstream timed out (60: Operation timed out) while {s}", .{switch (up.phase) {
        .connecting => "connecting to upstream",
        .sending => "sending request to upstream",
        else => "reading response header from upstream",
    }});
    if (up.phase == .streaming and up.head_sent) {
        release(conn);
        conn.keep_alive = false;
        conn.finishRequest();
        return;
    }
    fail(conn, 504);
    conn.drive();
}

/// Advance the proxy. Returns true when the connection changed state (caller loops).
pub fn drive(conn: *Conn) bool {
    const up = &conn.up;
    const lc = conn.ctx.conf;
    while (true) switch (up.phase) {
        .idle => return false,
        .connecting => {
            if (!up.writable) return false;
            const e = net.soError(up.fd);
            if (e != 0) {
                logUpstreamError(conn, "connect() failed", e);
                disconnect(conn);
                connectNext(conn);
                if (conn.state != .proxy) return true;
                continue;
            }
            up.phase = .sending;
            conn.deadline = conn.w.now_ms + lc.proxy_send_timeout_ms;
        },
        .sending => {
            const body = if (up.fcgi) "" else conn.body.items;
            while (up.head_off < up.req_head.len or up.body_off < body.len) {
                const r = if (up.head_off < up.req_head.len and body.len > 0) blk: {
                    const iov = [_]c.iovec_const{
                        .{ .base = up.req_head.ptr + up.head_off, .len = up.req_head.len - up.head_off },
                        .{ .base = body.ptr, .len = body.len },
                    };
                    break :blk net.writev(up.fd, &iov);
                } else if (up.head_off < up.req_head.len)
                    net.write(up.fd, up.req_head[up.head_off..])
                else
                    net.write(up.fd, body[up.body_off..]);
                switch (r) {
                    .ok => |n0| {
                        var n = n0;
                        const h = @min(n, up.req_head.len - up.head_off);
                        up.head_off += h;
                        n -= h;
                        up.body_off += n;
                    },
                    .again => return false,
                    .eof, .err => {
                        logUpstreamError(conn, "writev() failed", net.errno());
                        disconnect(conn);
                        connectNext(conn);
                        if (conn.state != .proxy) return true;
                        break;
                    },
                }
            } else {
                up.phase = .reading_head;
                conn.deadline = conn.w.now_ms + lc.proxy_read_timeout_ms;
            }
        },
        .reading_head => {
            switch (readUpstream(conn, conn.wbuf[up.rlen..])) {
                .ok => |n| up.rlen += n,
                .again => return false,
                .eof, .err => {
                    conn.w.errlog(.err, "upstream prematurely closed connection while reading response header from upstream", .{});
                    fail(conn, 502);
                    return true;
                },
            }
            switch (parseResponseHead(conn)) {
                .incomplete => {
                    if (up.rlen == conn.wbuf.len) {
                        conn.w.errlog(.err, "upstream sent too big header while reading response header from upstream", .{});
                        fail(conn, 502);
                        return true;
                    }
                },
                .bad => {
                    conn.w.errlog(.err, "upstream sent invalid header while reading response header from upstream", .{});
                    fail(conn, 502);
                    return true;
                },
                .intercepted => return true,
                .ok => {
                    up.phase = .streaming;
                    up.head_sent = true;
                },
            }
        },
        .streaming => {
            switch (conn.flush()) {
                .done => {},
                .again => return false,
                .err => {
                    release(conn);
                    conn.keep_alive = false;
                    conn.finishRequest();
                    return false;
                },
            }
            if (up.finished) {
                release(conn);
                conn.finishRequest();
                return conn.state != .closed;
            }
            if (up.eof) {
                if (up.framing == .close or (up.fcgi and up.fcgi_decoder.done and up.framing == .length and up.remaining == 0)) {
                    finishStream(conn);
                    continue;
                }
                // truncated upstream response
                conn.w.errlog(.err, "upstream prematurely closed connection while reading upstream", .{});
                release(conn);
                conn.keep_alive = false;
                conn.finishRequest();
                return false;
            }
            const room = conn.wbuf.len - 2;
            switch (readUpstream(conn, conn.wbuf[0..room])) {
                .ok => |n| {
                    conn.deadline = conn.w.now_ms + lc.proxy_read_timeout_ms;
                    forward(conn, conn.wbuf[0..n]);
                },
                .again => return false,
                .eof => up.eof = true,
                .err => {
                    fail(conn, 502);
                    return true;
                },
            }
        },
    };
}

fn readUpstream(conn: *Conn, buf: []u8) net.Io {
    return if (conn.up.fcgi) fastcgi.read(conn, buf) else net.read(conn.up.fd, buf);
}

/// Queue `data` (in wbuf) for the client according to the framing.
fn forward(conn: *Conn, data_in: []u8) void {
    const up = &conn.up;
    var data = data_in;
    switch (up.framing) {
        .none => {
            up.finished = true;
            conn.setOutput(&.{});
            return;
        },
        .length => {
            if (data.len > up.remaining) data = data[0..@intCast(up.remaining)];
            up.remaining -= data.len;
            if (up.remaining == 0 and !up.fcgi) up.finished = true;
        },
        .chunked => {
            const r = up.decoder.feed(data) catch {
                up.eof = true;
                up.framing = .length; // forces "truncated" handling
                up.remaining = 1;
                conn.setOutput(&.{});
                return;
            };
            data = data[0..r.produced];
            if (up.decoder.isDone()) up.finished = true;
        },
        .close => {},
    }
    conn.ctx.body_bytes_sent += data.len;
    if (up.rechunk) {
        if (data.len == 0) {
            conn.setOutput(if (up.finished) &.{"0\r\n\r\n"} else &.{});
            return;
        }
        const line = std.fmt.bufPrint(&up.size_line, "{x}\r\n", .{data.len}) catch unreachable;
        conn.setOutput(&.{ line, data, if (up.finished) "\r\n0\r\n\r\n" else "\r\n" });
    } else conn.setOutput(&.{data});
}

fn finishStream(conn: *Conn) void {
    const up = &conn.up;
    up.finished = true;
    if (up.rechunk) conn.setOutput(&.{"0\r\n\r\n"}) else conn.setOutput(&.{});
}

const HeadResult = enum { incomplete, bad, ok, intercepted };

fn parseResponseHead(conn: *Conn) HeadResult {
    const up = &conn.up;
    const buf = conn.wbuf[0..up.rlen];
    const end = blk: {
        if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |i| break :blk i + 4;
        if (std.mem.indexOf(u8, buf, "\n\n")) |i| break :blk i + 2;
        return .incomplete;
    };
    const head = buf[0..end];
    var lines = std.mem.splitScalar(u8, head, '\n');
    const sl = std.mem.trimEnd(u8, lines.next() orelse return .bad, "\r");
    var status: u16 = 200;
    if (up.fcgi) {
        lines = std.mem.splitScalar(u8, head, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.ascii.startsWithIgnoreCase(line, "Status:")) {
                const value = std.mem.trim(u8, line[7..], " \t");
                if (value.len < 3) return .bad;
                status = std.fmt.parseInt(u16, value[0..3], 10) catch return .bad;
                if (status < 200 or status > 599) return .bad;
            }
        }
        lines = std.mem.splitScalar(u8, head, '\n');
    } else {
        if (!std.mem.startsWith(u8, sl, "HTTP/1.") or sl.len < 12) return .bad;
        status = std.fmt.parseInt(u16, sl[9..12], 10) catch return .bad;
    }
    conn.ctx.upstream_status = status;

    const lc = conn.ctx.conf;
    if (lc.proxy_intercept_errors and status >= 300) {
        for (lc.error_pages) |ep| if (std.mem.indexOfScalar(u16, ep.codes, status) != null) {
            release(conn);
            handler.finalize(conn, status);
            conn.state = .sending;
            return .intercepted;
        };
    }

    const a = conn.arena();
    var hdrs: std.ArrayList(u8) = .empty;
    var length: ?u64 = null;
    var chunked = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .bad;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (up.fcgi and std.ascii.eqlIgnoreCase(name, "status")) continue;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            length = std.fmt.parseInt(u64, value, 10) catch return .bad;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.findIgnoreCase(value, "chunked") != null) chunked = true;
            continue;
        }
        if (hidden(name, lc)) continue;
        hdrs.print(a, "{s}: {s}\r\n", .{ name, value }) catch return .bad;
    }
    const no_body = conn.req.method == .HEAD or status == 204 or status == 304 or (status >= 100 and status < 200);
    const up_ = up;
    up_.decoder = .{};
    if (no_body) {
        up_.framing = .none;
    } else if (chunked) {
        up_.framing = .chunked;
    } else if (length) |l| {
        up_.framing = .length;
        up_.remaining = l;
    } else up_.framing = .close;

    const known_len = up_.framing == .length;
    if (!known_len and !no_body) {
        if (conn.req.version == .http11 and lc.chunked_transfer_encoding) up_.rechunk = true else conn.close_after = true;
    }
    // client head, built in the arena (wbuf still holds upstream bytes)
    conn.keep_alive = handler.decideKeepAlive(conn);
    var hw: std.Io.Writer.Allocating = .init(a);
    handler.writeHeadTo(conn, &hw.writer, status, .{
        .length = if (known_len) length else if (no_body) length else null,
        .chunked = up_.rechunk,
        .upstream = hdrs.items,
    }) catch return .bad;
    const client_head = hw.written();
    conn.ctx.status = status;
    conn.ctx.sent_headers = client_head;
    if (conn.req.method == .HEAD) up_.framing = .none;

    // body bytes that arrived with the head
    const leftover = conn.wbuf[end..up.rlen];
    if (up_.framing == .none) {
        up_.finished = true;
        conn.setOutput(&.{client_head});
        return .ok;
    }
    if (leftover.len == 0) {
        conn.setOutput(&.{client_head});
        return .ok;
    }
    forward(conn, leftover);
    // prepend the head to whatever forward() queued
    var segs: [4][]const u8 = undefined;
    segs[0] = client_head;
    var n: usize = 1;
    for (conn.segs[0..conn.nsegs]) |s| {
        if (n < 4) {
            segs[n] = s;
            n += 1;
        }
    }
    conn.setOutput(segs[0..n]);
    return .ok;
}

fn hidden(name: []const u8, lc: *const config.LocConf) bool {
    const always = [_][]const u8{ "connection", "keep-alive", "server", "date", "x-accel-redirect", "x-accel-expires", "x-accel-limit-rate", "x-accel-buffering", "x-accel-charset", "proxy-connection", "upgrade", "te", "trailer" };
    for (always) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    for (lc.proxy_hide_headers) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// Request line + headers for the upstream.
fn buildRequest(conn: *Conn, p: config.Proxy) ![]const u8 {
    const ctx = &conn.ctx;
    const lc = ctx.conf;
    const a = conn.arena();
    var out: std.ArrayList(u8) = .empty;
    const method = if (ctx.method_override_get) "GET" else conn.req.method_raw;
    // URI
    var uri_changed = !std.mem.eql(u8, ctx.uri, conn.req.path) or ctx.internal;
    var path: []const u8 = undefined;
    if (p.uri) |pu| {
        const base = try vars.eval(a, ctx, pu);
        const loc = ctx.loc;
        if (loc != null and (loc.?.kind == .prefix or loc.?.kind == .prefix_noregex or loc.?.kind == .exact) and pu.isLiteral()) {
            const plen = @min(loc.?.name.len, ctx.uri.len);
            path = try escapedConcat(a, base, ctx.uri[plen..]);
        } else path = base;
        uri_changed = true;
    } else if (!uri_changed) {
        path = conn.req.target;
        if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) path = try escapedConcat(a, "", ctx.uri);
    } else path = try escapedConcat(a, "", ctx.uri);
    try out.print(a, "{s} {s}{s}{s} HTTP/{s}\r\n", .{ method, path, if (ctx.args.len > 0) "?" else "", ctx.args, if (lc.proxy_http_11) "1.1" else "1.0" });

    // proxy_set_header (defaults: Host $proxy_host, Connection close)
    var set_host = false;
    var set_conn = false;
    for (lc.proxy_set_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) set_host = true;
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) set_conn = true;
    }
    // nginx 1.30 defaults: Host $proxy_host; Connection "" (not sent). zhttpd never reuses
    // upstream connections, it closes them after each response.
    _ = &set_conn;
    if (!set_host) try out.print(a, "Host: {s}\r\n", .{if (ctx.proxy_host.len > 0) ctx.proxy_host else p.host});
    for (lc.proxy_set_headers) |h| {
        const v = try vars.eval(a, ctx, h.value);
        if (v.len == 0) continue;
        try out.print(a, "{s}: {s}\r\n", .{ h.name, v });
    }
    if (conn.body_mode != .none or conn.req.content_length != null) {
        try out.print(a, "Content-Length: {d}\r\n", .{conn.body.items.len});
    }
    if (lc.proxy_pass_request_headers) {
        for (conn.req.headers[0..conn.req.nheaders]) |h| {
            if (skipRequestHeader(h.name)) continue;
            var overridden = false;
            for (lc.proxy_set_headers) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, h.name)) overridden = true;
            }
            if (overridden) continue;
            try out.print(a, "{s}: {s}\r\n", .{ h.name, h.value });
        }
    }
    try out.appendSlice(a, "\r\n");
    return out.items;
}

fn skipRequestHeader(name: []const u8) bool {
    const skip = [_][]const u8{ "host", "connection", "keep-alive", "proxy-connection", "te", "upgrade", "transfer-encoding", "content-length", "expect" };
    for (skip) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

fn escapedConcat(a: std.mem.Allocator, prefix: []const u8, decoded: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, prefix);
    for (decoded) |ch| {
        if (ch <= 0x20 or ch >= 0x7f or ch == '%' or ch == '?' or ch == '#' or ch == '"') {
            try out.print(a, "%{X:0>2}", .{ch});
        } else try out.append(a, ch);
    }
    return out.items;
}
