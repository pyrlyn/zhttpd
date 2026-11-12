//! Request processing in nginx phase order:
//! server rewrite -> find location -> location rewrite (loop on `rewrite ... last`) ->
//! access (`allow`/`deny`, `limit_except`, `internal`) -> try_files -> content
//! (proxy_pass or static files) -> error_page / default error page.
const std = @import("std");
const c = std.c;
const config = @import("../http/config.zig");
const expr = @import("expression");
const Regex = @import("../regex.zig").Regex;
const request = @import("../http/request.zig");
const response = @import("../http/response.zig");
const os = @import("../os.zig");
const vars = @import("vars.zig");
const router = @import("router.zig");
const net = @import("net.zig");
const Conn = @import("conn.zig").Conn;
const proxy = @import("proxy.zig");

const max_redirects = 10;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ------------------------------------------------------------------ entry points

pub fn process(conn: *Conn) void {
    const ctx = &conn.ctx;
    if (eql(ctx.uri, "*")) return writeSimple(conn, 204, null, "", "Allow: GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS\r\n");
    if (conn.w.cfg.load_balancer.enabled) {
        const lb = @import("load_balancer");
        if (lb.redirectedTarget(conn.req.target)) |clean| {
            conn.req.target = clean;
            conn.req.args = if (std.mem.indexOfScalar(u8, clean, '?')) |q| clean[q + 1 ..] else "";
            ctx.args = conn.req.args;
        } else if (conn.w.balancer.destination(conn.w.now_ms, ctx.scheme_https)) |origin| {
            if (lb.location(conn.arena(), origin, conn.req.target) catch null) |target| {
                // Send the final response immediately, including Expect: 100-continue.
                // Never consume/execute a non-idempotent request before redirecting it.
                conn.close_after = true;
                writeSimpleLoc(conn, 307, null, "", "Cache-Control: no-store\r\n", target);
                return;
            }
        }
    }
    switch (runStmts(conn, ctx.srv.stmts) catch return finalize(conn, 500)) {
        .done => return,
        .cont, .brk, .last => {},
    }
    findAndRun(conn);
}

const StmtResult = enum { cont, brk, last, done };

fn findAndRun(conn: *Conn) void {
    const ctx = &conn.ctx;
    while (true) {
        ctx.redirects += 1;
        if (ctx.redirects > max_redirects) {
            conn.w.errlog(.err, "rewrite or internal redirection cycle while processing \"{s}\"", .{ctx.uri});
            ctx.error_page_done = true;
            return finalize(conn, 500);
        }
        const m = router.findLocationMethod(ctx.srv.locations, ctx.uri, conn.req.method_raw);
        setLocation(conn, m.loc, m.caps, ctx.uri);
        if (!checkBodySize(conn)) return;
        if (!@import("policy.zig").check(conn)) return;
        if (m.loc) |loc| {
            switch (runStmts(conn, loc.stmts) catch return finalize(conn, 500)) {
                .done => return,
                .last => continue,
                .cont, .brk => {},
            }
        }
        return content(conn);
    }
}

fn setLocation(conn: *Conn, loc: ?*config.Location, caps: Regex.Captures, subject: []const u8) void {
    const ctx = &conn.ctx;
    ctx.loc = loc;
    ctx.conf = if (loc) |l| l.conf else ctx.srv.conf;
    if (loc) |l| if (l.re) |re| {
        ctx.caps = caps;
        ctx.caps_subject = subject;
        ctx.caps_re = re;
    };
}

fn checkBodySize(conn: *Conn) bool {
    const max = conn.ctx.conf.client_max_body_size;
    if (max != 0) if (conn.req.content_length) |len| if (len > max) {
        conn.w.errlog(.err, "client intended to send too large body: {d} bytes", .{len});
        conn.close_after = true;
        finalize(conn, 413);
        return false;
    };
    conn.body_limit = max;
    return true;
}

/// Jump to a named location (`@name`) from try_files or error_page.
fn runNamed(conn: *Conn, name: []const u8) void {
    const ctx = &conn.ctx;
    const loc = router.findNamed(ctx.srv, name) orelse {
        conn.w.errlog(.err, "could not find named location \"{s}\"", .{name});
        return finalize(conn, 500);
    };
    ctx.redirects += 1;
    if (ctx.redirects > max_redirects) return finalize(conn, 500);
    ctx.internal = true;
    setLocation(conn, loc, .{}, ctx.uri);
    if (!checkBodySize(conn) or !@import("policy.zig").check(conn)) return;
    switch (runStmts(conn, loc.stmts) catch return finalize(conn, 500)) {
        .done => return,
        .last => return findAndRun(conn),
        .cont, .brk => {},
    }
    content(conn);
}

/// Internal redirect to `target` (may carry `?args`).
fn internalRedirect(conn: *Conn, target: []const u8) void {
    const ctx = &conn.ctx;
    if (target.len > 0 and target[0] == '@') return runNamed(conn, target);
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        ctx.uri = target[0..q];
        ctx.args = target[q + 1 ..];
    } else ctx.uri = target;
    ctx.internal = true;
    ctx.caps = .{};
    ctx.caps_re = null;
    findAndRun(conn);
}

// ------------------------------------------------------------------ rewrite module

fn runStmts(conn: *Conn, stmts: []const config.Stmt) !StmtResult {
    const ctx = &conn.ctx;
    const a = conn.arena();
    for (stmts) |*st| switch (st.*) {
        .ret => |r| {
            const text: ?[]const u8 = if (r.text) |t| try vars.eval(a, ctx, t) else null;
            doReturn(conn, r.code, text);
            return .done;
        },
        .rewrite => |rw| {
            var caps: Regex.Captures = .{};
            if (!(rw.re.search(ctx.uri, &caps) catch false)) continue;
            const saved = .{ ctx.caps, ctx.caps_subject, ctx.caps_re };
            ctx.caps = caps;
            ctx.caps_subject = ctx.uri;
            ctx.caps_re = rw.re;
            const new = try vars.eval(a, ctx, rw.repl);
            _ = saved;
            const is_url = std.mem.startsWith(u8, new, "http://") or std.mem.startsWith(u8, new, "https://");
            const keep_args = !std.mem.endsWith(u8, rw.repl.raw, "?");
            var path = new;
            var args = ctx.args;
            if (!keep_args) path = new[0 .. new.len - 1];
            if (std.mem.indexOfScalar(u8, path, '?')) |q| {
                const new_args = path[q + 1 ..];
                path = path[0..q];
                args = if (keep_args and ctx.args.len > 0) try std.fmt.allocPrint(a, "{s}&{s}", .{ new_args, ctx.args }) else new_args;
            } else if (!keep_args) args = "";
            if (is_url or rw.flag == .redirect or rw.flag == .permanent) {
                const code: u16 = if (rw.flag == .permanent) 301 else 302;
                const loc_hdr = if (args.len > 0) try std.fmt.allocPrint(a, "{s}?{s}", .{ path, args }) else path;
                sendRedirect(conn, code, loc_hdr);
                return .done;
            }
            ctx.uri = path;
            ctx.args = args;
            switch (rw.flag) {
                .last => return .last,
                .brk => return .brk,
                else => {},
            }
        },
        .set => |s| ctx.setVar(s.name, try vars.eval(a, ctx, s.value)),
        .brk => return .brk,
        .if_ => |i| {
            if (!try evalCond(conn, &i.cond)) continue;
            if (i.conf) |lc| ctx.conf = lc;
            const r = try runStmts(conn, i.body);
            if (r != .cont) return r;
        },
    };
    return .cont;
}

fn evalCond(conn: *Conn, cond: *const config.Cond) !bool {
    const ctx = &conn.ctx;
    const a = conn.arena();
    const v = try vars.eval(a, ctx, cond.a);
    const res: bool = switch (cond.kind) {
        .truthy => v.len > 0 and !eql(v, "0"),
        .eq => eql(v, try vars.eval(a, ctx, cond.b)),
        .ne => !eql(v, try vars.eval(a, ctx, cond.b)),
        .re => blk: {
            var caps: Regex.Captures = .{};
            if (cond.re.?.search(v, &caps) catch false) {
                ctx.caps = caps;
                ctx.caps_subject = v;
                ctx.caps_re = cond.re;
                break :blk true;
            }
            break :blk false;
        },
        .file_f, .file_d, .file_e, .file_x => blk: {
            const z = try a.dupeSentinel(u8, v, 0);
            const m = os.statZ(z) orelse break :blk false;
            break :blk switch (cond.kind) {
                .file_f => m.kind == .file,
                .file_d => m.kind == .dir,
                .file_e => true,
                .file_x => c.access(z, 1) == 0,
                else => unreachable,
            };
        },
    };
    return if (cond.neg) !res else res;
}

fn doReturn(conn: *Conn, code: u16, text: ?[]const u8) void {
    if (code == 444) {
        conn.ctx.status = 444;
        conn.drop = true;
        conn.keep_alive = false;
        return;
    }
    if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) {
        if (text) |t| return sendRedirect(conn, code, t);
    }
    if (text) |t| {
        conn.ctx.status = code;
        const ctype = contentType(conn, conn.ctx.uri);
        writeSimple(conn, code, ctype, t, "");
        return;
    }
    finalize(conn, code);
}

// ------------------------------------------------------------------ content phase

fn content(conn: *Conn) void {
    const ctx = &conn.ctx;
    const lc = ctx.conf;
    if (lc.internal and !ctx.internal) return finalize(conn, 404);
    if (!accessAllowed(conn, lc.access)) return finalize(conn, 403);
    if (lc.limit_except) |le| {
        var allowed = false;
        for (le.methods) |m| {
            if (eql(m, conn.req.method_raw) or (eql(m, "GET") and conn.req.method == .HEAD)) allowed = true;
        }
        if (!allowed and !accessAllowed(conn, le.access)) return finalize(conn, 403);
    }
    if (lc.try_files) |tf| return tryFiles(conn, tf);
    contentHandler(conn);
}

fn contentHandler(conn: *Conn) void {
    const lc = conn.ctx.conf;
    if (lc.application != null) {
        conn.after_body = .application;
        conn.body_store = true;
        return;
    }
    if (lc.websocket) |callbacks| return @import("websocket.zig").upgrade(conn, callbacks);
    if (lc.unsupported_handler) |h| {
        conn.w.errlog(.err, "\"{s}\" is not supported by zhttpd", .{h});
        return finalize(conn, 502);
    }
    if (lc.proxy != null) {
        conn.after_body = .proxy;
        conn.body_store = true;
        return;
    }
    staticFile(conn);
}

fn accessAllowed(conn: *Conn, rules: []const config.AccessRule) bool {
    for (rules) |r| {
        if (r.all or r.cidr.contains(conn.peer)) {
            if (!r.allow) conn.w.errlog(.err, "access forbidden by rule", .{});
            return r.allow;
        }
    }
    return true;
}

/// Filesystem path for `uri` under `root` or `alias` (no trailing NUL).
fn mapUri(conn: *Conn, uri: []const u8) ![:0]u8 {
    const ctx = &conn.ctx;
    const a = conn.arena();
    const lc = ctx.conf;
    if (lc.alias) |al| {
        const base = try vars.eval(a, ctx, al);
        ctx.document_root = base;
        const loc = ctx.loc;
        if (loc != null and (loc.?.kind == .regex or loc.?.kind == .regex_icase)) {
            // regex alias: the alias is the complete path
            return a.dupeSentinel(u8, base, 0);
        }
        const plen = if (loc) |l| @min(l.name.len, uri.len) else 0;
        return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ base, uri[plen..] }, 0);
    }
    var root = try vars.eval(a, ctx, lc.root);
    if (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
    ctx.document_root = root;
    return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ root, uri }, 0);
}

fn tryFiles(conn: *Conn, tf: []const expr.Expr) void {
    const ctx = &conn.ctx;
    const a = conn.arena();
    for (tf[0 .. tf.len - 1]) |e| {
        const v = vars.eval(a, ctx, e) catch return finalize(conn, 500);
        if (v.len == 0) continue;
        // like nginx, "test as directory" depends on the template, not the value
        const want_dir = e.raw.len > 0 and e.raw[e.raw.len - 1] == '/';
        const path = mapUri(conn, v) catch return finalize(conn, 500);
        const m = conn.w.files.stat(ctx.conf.open_file_cache, path, @intCast(conn.w.now_ms)) orelse continue;
        if (want_dir and m.kind != .dir) continue;
        if (!want_dir and m.kind != .file) continue;
        // nginx: the found name becomes $uri (without redirect); a directory match
        // drops the trailing slash, so `/dir` then gets the usual 301 to `/dir/`
        ctx.uri = if (want_dir and v.len > 1) v[0 .. v.len - 1] else v;
        return contentHandler(conn);
    }
    const last = vars.eval(a, ctx, tf[tf.len - 1]) catch return finalize(conn, 500);
    if (last.len > 1 and last[0] == '=') {
        const code = std.fmt.parseInt(u16, last[1..], 10) catch return finalize(conn, 500);
        return finalize(conn, code);
    }
    internalRedirect(conn, last);
}

fn staticFile(conn: *Conn) void {
    const ctx = &conn.ctx;
    const a = conn.arena();
    const lc = ctx.conf;
    const method = conn.req.method;
    const is_head = method == .HEAD and !ctx.method_override_get;
    if (!(method == .GET or method == .HEAD or ctx.method_override_get)) {
        return finalizeExtra(conn, 405, "Allow: GET, HEAD\r\n");
    }
    const uri = ctx.uri;
    if (uri.len > 0 and uri[uri.len - 1] == '/') {
        const dir_path = mapUri(conn, uri) catch return finalize(conn, 500);
        ctx.request_filename = dir_path;
        for (lc.index) |ie| {
            const idx = vars.eval(a, ctx, ie) catch return finalize(conn, 500);
            if (idx.len == 0) continue;
            if (idx[0] == '/') return internalRedirect(conn, idx);
            const p = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ dir_path, idx }, 0) catch return finalize(conn, 500);
            if (conn.w.files.stat(lc.open_file_cache, p, @intCast(conn.w.now_ms)) != null) {
                const target = std.fmt.allocPrint(a, "{s}{s}", .{ uri, idx }) catch return finalize(conn, 500);
                return internalRedirect(conn, target);
            }
        }
        const m = os.statZ(dir_path);
        if (m != null and m.?.kind == .dir) {
            if (lc.autoindex) return autoindex(conn, dir_path, is_head);
            conn.w.errlog(.err, "directory index of \"{s}\" is forbidden", .{dir_path});
            return finalize(conn, 403);
        }
        if (lc.log_not_found) conn.w.errlog(.err, "\"{s}\" is not found (2: No such file or directory)", .{dir_path});
        return finalize(conn, 404);
    }
    const path = mapUri(conn, uri) catch return finalize(conn, 500);
    ctx.request_filename = path;
    const meta = switch (conn.w.files.open(lc.open_file_cache, path, @intCast(conn.w.now_ms))) {
        .err => |e| {
            if (e == @backingInt(c.E.ACCES)) {
                conn.w.errlog(.err, "open() \"{s}\" failed (13: Permission denied)", .{path});
                return finalize(conn, 403);
            }
            if (lc.log_not_found) conn.w.errlog(.err, "open() \"{s}\" failed ({d}: {s})", .{ path, e, os.strerror(e) });
            return finalize(conn, 404);
        },
        .other => |m| {
            if (m.kind == .dir) {
                const loc = std.fmt.allocPrint(a, "{s}/{s}{s}", .{ uri, if (ctx.args.len > 0) "?" else "", ctx.args }) catch return finalize(conn, 500);
                return sendRedirect(conn, 301, loc);
            }
            return finalize(conn, 404);
        },
        .file => |f| blk: {
            conn.file_fd = f.fd;
            conn.file_borrowed = !f.owned;
            break :blk f.meta;
        },
    };
    serveOpenFile(conn, meta, is_head);
}

fn serveOpenFile(conn: *Conn, meta: os.Meta, is_head: bool) void {
    const ctx = &conn.ctx;
    const lc = ctx.conf;
    var status: u16 = 200;
    if (ctx.status != 0 and ctx.error_page_done) status = ctx.status; // error_page target keeps the error status
    const gzip_variant = compressible(conn, status, contentType(conn, ctx.uri), @intCast(meta.size));
    const vary: []const u8 = if (gzip_variant) "Vary: Accept-Encoding\r\n" else "";
    var etag_buf: [48]u8 = undefined;
    const etag: ?[]const u8 = if (lc.etag) std.fmt.bufPrint(&etag_buf, "{s}\"{x}-{x}\"", .{ if (gzip_variant) "W/" else "", meta.mtime, meta.size }) catch null else null;
    var size = meta.size;
    var start: u64 = 0;
    var range_hdr: []const u8 = "";
    var range_buf: [96]u8 = undefined;
    if (status == 200) {
        if (notModified(conn, meta, etag)) {
            conn.closeFile();
            ctx.status = 304;
            writeHead(conn, 304, .{ .last_modified = meta.mtime, .etag = etag, .no_length = true, .extra = vary });
            conn.setOutput(&.{conn.headSlice()});
            return;
        }
        if (conn.req.header("range")) |rh| switch (parseRange(rh, meta.size)) {
            .none => {},
            .bad => {
                conn.closeFile();
                range_hdr = std.fmt.bufPrint(&range_buf, "Content-Range: bytes */{d}\r\n", .{meta.size}) catch "";
                return finalizeExtra(conn, 416, range_hdr);
            },
            .ok => |r| {
                status = 206;
                start = r.start;
                size = r.end - r.start + 1;
                range_hdr = std.fmt.bufPrint(&range_buf, "Content-Range: bytes {d}-{d}/{d}\r\n", .{ r.start, r.end, meta.size }) catch "";
            },
        };
    }
    ctx.status = status;
    const ctype = contentType(conn, ctx.uri);
    if (compressible(conn, status, ctype, @intCast(size)) and @import("compression.zig").accepts(conn.req.header("accept-encoding") orelse "")) {
        const bytes = conn.appAllocator().alloc(u8, @intCast(size)) catch return finalize(conn, 500);
        if (net.pread(conn.file_fd, bytes, 0) != @as(isize, @intCast(size))) return finalize(conn, 500);
        conn.closeFile();
        var out: std.Io.Writer.Allocating = .init(conn.appAllocator());
        if (etag) |value| out.writer.print("ETag: {s}\r\n", .{value}) catch return finalize(conn, 500);
        out.writer.print("Last-Modified: {s}\r\n", .{conn.w.lastModified(meta.mtime)}) catch return finalize(conn, 500);
        return writeSimple(conn, status, ctype, bytes, out.written());
    }
    writeHead(conn, status, .{
        .ctype = ctype,
        .length = size,
        .last_modified = meta.mtime,
        .etag = etag,
        .accept_ranges = status == 200,
        .extra = if (range_hdr.len > 0) range_hdr else vary,
    });
    const head = conn.headSlice();
    if (is_head or size == 0) {
        conn.closeFile();
        conn.setOutput(&.{head});
        return;
    }
    // small files: one read into the write buffer, one write for head + body
    const room = conn.wbuf.len - head.len;
    if (size <= room) {
        const n = net.pread(conn.file_fd, conn.wbuf[head.len..][0..@intCast(size)], start);
        if (n == @as(isize, @intCast(size))) {
            conn.closeFile();
            ctx.body_bytes_sent = size;
            conn.setOutput(&.{conn.wbuf[0 .. head.len + size]});
            return;
        }
    }
    if (conn.file_borrowed) {
        // the response outlives this call: take a private descriptor, since the
        // cache may close or replace its own on revalidation or eviction
        const d = c.dup(conn.file_fd);
        conn.file_fd = -1;
        conn.file_borrowed = false;
        if (d < 0) return finalize(conn, 500);
        conn.file_fd = d;
    }
    conn.setOutput(&.{head});
    conn.file_off = start;
    conn.file_end = start + size;
    conn.file_sendfile = lc.sendfile;
    ctx.body_bytes_sent = size;
}

fn notModified(conn: *Conn, meta: os.Meta, etag: ?[]const u8) bool {
    if (conn.req.header("if-none-match")) |inm| {
        if (etag) |et| {
            if (eql(std.mem.trim(u8, inm, " "), "*")) return true;
            var it = std.mem.tokenizeAny(u8, inm, ", ");
            while (it.next()) |tok| {
                const t = if (std.mem.startsWith(u8, tok, "W/")) tok[2..] else tok;
                const validator = if (std.mem.startsWith(u8, et, "W/")) et[2..] else et;
                if (eql(t, validator)) return true;
            }
        }
        return false;
    }
    if (conn.ctx.conf.if_modified_since == .off) return false;
    if (conn.req.header("if-modified-since")) |ims| {
        const t = response.parseHttpDate(ims) orelse return false;
        return switch (conn.ctx.conf.if_modified_since) {
            .exact => t == meta.mtime,
            .before => t >= meta.mtime,
            .off => false,
        };
    }
    return false;
}

const Range = union(enum) { none, bad, ok: struct { start: u64, end: u64 } };

fn parseRange(h: []const u8, size: u64) Range {
    if (!std.mem.startsWith(u8, h, "bytes=")) return .none;
    const spec = std.mem.trim(u8, h[6..], " ");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none; // multipart ranges: send whole file
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .bad;
    const a = std.mem.trim(u8, spec[0..dash], " ");
    const b = std.mem.trim(u8, spec[dash + 1 ..], " ");
    if (a.len == 0) {
        const n = std.fmt.parseInt(u64, b, 10) catch return .bad;
        if (n == 0 or size == 0) return .bad;
        return .{ .ok = .{ .start = size - @min(n, size), .end = size - 1 } };
    }
    const s = std.fmt.parseInt(u64, a, 10) catch return .bad;
    if (s >= size) return .bad;
    var e = size - 1;
    if (b.len > 0) e = @min(std.fmt.parseInt(u64, b, 10) catch return .bad, size - 1);
    if (e < s) return .bad;
    return .{ .ok = .{ .start = s, .end = e } };
}

fn autoindex(conn: *Conn, dir: []const u8, is_head: bool) void {
    const a = conn.arena();
    const names = os.listDir(conn.w.gpa, dir) catch return finalize(conn, 403);
    defer os.freeList(conn.w.gpa, names);
    std.mem.sort([]u8, names, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    const uri = conn.ctx.uri;
    out.print(a, "<html>\r\n<head><title>Index of {s}</title></head>\r\n<body>\r\n<h1>Index of {s}</h1><hr><pre><a href=\"../\">../</a>\r\n", .{ uri, uri }) catch return finalize(conn, 500);
    for (names) |n| {
        if (n.len == 0 or n[0] == '.') continue;
        const p = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ dir, n }, 0) catch return finalize(conn, 500);
        const m = os.statZ(p) orelse continue;
        const slash = if (m.kind == .dir) "/" else "";
        out.print(a, "<a href=\"{s}{s}\">{s}{s}</a>\r\n", .{ n, slash, n, slash }) catch return finalize(conn, 500);
    }
    out.appendSlice(a, "</pre><hr></body>\r\n</html>\r\n") catch return finalize(conn, 500);
    conn.ctx.status = 200;
    _ = is_head; // writeSimple drops the body for HEAD
    writeSimple(conn, 200, "text/html", out.items, "");
}

// ------------------------------------------------------------------ errors and redirects

/// Finish the request with `status`: apply `error_page`, else send the default page.
pub fn finalize(conn: *Conn, status: u16) void {
    finalizeExtra(conn, status, "");
}

pub fn finalizeExtra(conn: *Conn, status: u16, extra: []const u8) void {
    const ctx = &conn.ctx;
    conn.closeFile();
    conn.after_body = .respond;
    if (status == 444) {
        ctx.status = 444;
        conn.drop = true;
        conn.keep_alive = false;
        return;
    }
    if (status >= 300 and !ctx.error_page_done) {
        for (ctx.conf.error_pages) |*ep| {
            if (std.mem.indexOfScalar(u16, ep.codes, status) == null) continue;
            ctx.error_page_done = true;
            const target = vars.eval(conn.arena(), ctx, ep.uri) catch break;
            ctx.status = ep.override orelse status;
            if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
                const code: u16 = if (ep.override) |o| (if (o >= 301 and o <= 308) o else 302) else 302;
                return sendRedirect(conn, code, target);
            }
            if (ep.use_page_status) ctx.status = 0; // `=` without code: status of the target
            if (conn.req.method != .HEAD) ctx.method_override_get = true;
            conn.body_store = false;
            return internalRedirect(conn, target);
        }
    }
    ctx.status = status;
    if (status == 413 or status == 400 or status == 414 or status == 408 or status == 500 or status == 501 or status == 505) conn.close_after = true;
    if (ctx.conf.json_errors and status >= 400) {
        const body = std.fmt.allocPrint(conn.arena(), "{{\"error\":{{\"status\":{d},\"message\":\"{s}\"}}}}\n", .{ status, response.reason(status) }) catch "";
        return writeSimple(conn, status, "application/json", body, extra);
    }
    const tokens = conn.w.tokens(ctx.conf.server_tokens);
    var body_w: std.Io.Writer = .fixed(&conn.w.page_buf);
    if (response.hasDefaultPage(status)) response.writeDefaultPage(&body_w, status, tokens) catch {};
    const body = body_w.buffered();
    writeSimple(conn, status, if (body.len > 0) "text/html" else null, body, extra);
}

/// Redirect with nginx's absolute_redirect / port_in_redirect handling.
pub fn sendRedirect(conn: *Conn, code: u16, target: []const u8) void {
    const ctx = &conn.ctx;
    const lc = ctx.conf;
    var loc = target;
    if (target.len > 0 and target[0] == '/' and lc.absolute_redirect) {
        var hb: [256]u8 = undefined;
        const host = if (lc.server_name_in_redirect) ctx.srv.primary_name else if (conn.req.host) |h| (router.normalizeHost(h, &hb) orelse ctx.srv.primary_name) else blk: {
            break :blk if (ctx.srv.primary_name.len > 0) ctx.srv.primary_name else hostLocal(conn, &hb);
        };
        const https = conn.ssl != null;
        const port = conn.local.port;
        const default_port: u16 = if (https) 443 else 80;
        loc = if (lc.port_in_redirect and port != default_port)
            std.fmt.allocPrint(conn.arena(), "{s}://{s}:{d}{s}", .{ if (https) "https" else "http", host, port, target }) catch target
        else
            std.fmt.allocPrint(conn.arena(), "{s}://{s}{s}", .{ if (https) "https" else "http", host, target }) catch target;
    }
    ctx.status = code;
    const tokens = conn.w.tokens(lc.server_tokens);
    var body_w: std.Io.Writer = .fixed(&conn.w.page_buf);
    if (response.hasDefaultPage(code)) response.writeDefaultPage(&body_w, code, tokens) catch {};
    const body = body_w.buffered();
    writeSimpleLoc(conn, code, if (body.len > 0) "text/html" else null, body, "", loc);
}

fn hostLocal(conn: *Conn, buf: []u8) []const u8 {
    return conn.local.formatIp(buf);
}

// ------------------------------------------------------------------ response heads

pub const HeadOpts = struct {
    ctype: ?[]const u8 = null,
    length: ?u64 = null,
    no_length: bool = false,
    last_modified: ?i64 = null,
    etag: ?[]const u8 = null,
    location: ?[]const u8 = null,
    accept_ranges: bool = false,
    chunked: bool = false,
    extra: []const u8 = "", // preformatted "Name: value\r\n" lines
    /// raw upstream header lines placed before our trailing headers (proxy)
    upstream: []const u8 = "",
};

/// Decide keep-alive for this response.
pub fn decideKeepAlive(conn: *Conn) bool {
    const lc = conn.ctx.conf;
    return conn.req.keep_alive and !conn.close_after and !conn.w.stopping and
        lc.keepalive_timeout_ms > 0 and conn.requests < lc.keepalive_requests;
}

/// Write status line and headers into conn.wbuf (nginx header order). Sets conn.keep_alive.
pub fn writeHead(conn: *Conn, status: u16, o: HeadOpts) void {
    conn.keep_alive = decideKeepAlive(conn);
    conn.ctx.status = status;
    var w: std.Io.Writer = .fixed(&conn.wbuf);
    writeHeadTo(conn, &w, status, o) catch {
        // headers do not fit: fall back to a bare 500
        w = .fixed(&conn.wbuf);
        conn.keep_alive = false;
        conn.ctx.status = 500;
        w.print("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch {};
    };
    conn.head_len = w.end;
    conn.ctx.sent_headers = conn.wbuf[0..w.end];
}

pub fn writeHeadTo(conn: *Conn, w: *std.Io.Writer, status: u16, o: HeadOpts) !void {
    const lc = conn.ctx.conf;
    const reason = response.reason(status);
    try w.print("HTTP/1.1 {d} {s}\r\nServer: {s}\r\nDate: {s}\r\n", .{ status, reason, conn.w.tokens(lc.server_tokens), conn.w.date() });
    if (o.ctype) |ct| {
        if (lc.charset) |cs| {
            if (std.mem.startsWith(u8, ct, "text/") or eql(ct, "application/javascript") or eql(ct, "application/json")) {
                try w.print("Content-Type: {s}; charset={s}\r\n", .{ ct, cs });
            } else try w.print("Content-Type: {s}\r\n", .{ct});
        } else try w.print("Content-Type: {s}\r\n", .{ct});
    }
    if (o.length) |l| {
        try w.print("Content-Length: {d}\r\n", .{l});
    }
    // nginx sends Last-Modified only with 200/206/304
    if (o.last_modified) |t| if (status == 200 or status == 206 or status == 304) {
        try w.print("Last-Modified: {s}\r\n", .{conn.w.lastModified(t)});
    };
    if (o.chunked) try w.writeAll("Transfer-Encoding: chunked\r\n");
    try w.writeAll(if (conn.keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n");
    if (o.location) |l| try w.print("Location: {s}\r\n", .{l});
    if (o.etag) |e| try w.print("ETag: {s}\r\n", .{e});
    if (o.accept_ranges) try w.writeAll("Accept-Ranges: bytes\r\n");
    try w.writeAll(o.upstream);
    try w.writeAll(o.extra);
    try writeExpires(conn, w, status, o.last_modified);
    try writeAddHeaders(conn, w, status);
    try @import("policy.zig").headers(conn, w);
    try w.writeAll("\r\n");
}

fn writeExpires(conn: *Conn, w: *std.Io.Writer, status: u16, mtime: ?i64) !void {
    const ex = conn.ctx.conf.expires orelse return;
    switch (status) {
        200, 201, 204, 206, 301, 302, 303, 304, 307, 308 => {},
        else => return,
    }
    var db: [29]u8 = undefined;
    const now = conn.w.wall_sec;
    switch (ex) {
        .epoch => try w.writeAll("Expires: Thu, 01 Jan 1970 00:00:01 GMT\r\nCache-Control: no-cache\r\n"),
        .max => try w.writeAll("Expires: Thu, 31 Dec 2037 23:55:55 GMT\r\nCache-Control: max-age=315360000\r\n"),
        .offset => |s| {
            try w.print("Expires: {s}\r\n", .{response.httpDate(&db, now + s)});
            if (s < 0) try w.writeAll("Cache-Control: no-cache\r\n") else try w.print("Cache-Control: max-age={d}\r\n", .{s});
        },
        .modified => |s| {
            const t = (mtime orelse now) + s;
            try w.print("Expires: {s}\r\n", .{response.httpDate(&db, t)});
            try w.print("Cache-Control: max-age={d}\r\n", .{@max(0, t - now)});
        },
    }
}

fn writeAddHeaders(conn: *Conn, w: *std.Io.Writer, status: u16) !void {
    const ok_status = switch (status) {
        200, 201, 204, 206, 301, 302, 303, 304, 307, 308 => true,
        else => false,
    };
    for (conn.ctx.conf.add_headers) |h| {
        if (!ok_status and !h.always) continue;
        const v = vars.eval(conn.arena(), &conn.ctx, h.value) catch continue;
        if (v.len == 0) continue;
        try w.print("{s}: {s}\r\n", .{ h.name, v });
    }
}

fn hasHeader(raw: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, raw, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return true;
    }
    return false;
}

fn strongEtag(raw: []const u8) bool {
    var it = std.mem.splitSequence(u8, raw, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "ETag") and !std.mem.startsWith(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), "W/")) return true;
    }
    return false;
}

fn configuredHeader(conn: *Conn, name: []const u8) bool {
    for (conn.ctx.conf.add_headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

fn compressible(conn: *Conn, status: u16, ctype: ?[]const u8, size: usize) bool {
    if (!conn.ctx.conf.gzip or status != 200 or size < 256 or size > @import("compression.zig").max_bytes or conn.req.header("authorization") != null or conn.req.header("cookie") != null) return false;
    const ct = ctype orelse return false;
    return std.mem.startsWith(u8, ct, "text/") or eql(ct, "application/json") or eql(ct, "application/javascript") or eql(ct, "image/svg+xml");
}

/// Head + small in-memory body. Body is copied after the head when it fits.
pub fn writeSimple(conn: *Conn, status: u16, ctype: ?[]const u8, body: []const u8, extra: []const u8) void {
    writeSimpleLoc(conn, status, ctype, body, extra, null);
}

fn writeSimpleLoc(conn: *Conn, status: u16, ctype: ?[]const u8, original: []const u8, extra: []const u8, location: ?[]const u8) void {
    var body = original;
    var extras = extra;
    if (compressible(conn, status, ctype, body.len) and !hasHeader(extra, "Content-Encoding") and !hasHeader(extra, "Set-Cookie") and !hasHeader(extra, "Cache-Control") and !strongEtag(extra) and !configuredHeader(conn, "Set-Cookie") and !configuredHeader(conn, "Content-Encoding") and !configuredHeader(conn, "ETag") and !configuredHeader(conn, "Cache-Control")) {
        extras = std.fmt.allocPrint(conn.appAllocator(), "{s}Vary: Accept-Encoding\r\n", .{extra}) catch extra;
        if (@import("compression.zig").accepts(conn.req.header("accept-encoding") orelse "")) {
            if (@import("compression.zig").encode(conn.appAllocator(), body)) |encoded| {
                const compressed_headers = std.fmt.allocPrint(conn.appAllocator(), "{s}Content-Encoding: gzip\r\n", .{extras}) catch return finalize(conn, 500);
                body = encoded;
                extras = compressed_headers;
            } else |_| {}
        }
    }
    const no_body = status == 204 or status == 304 or (status >= 100 and status < 200);
    writeHead(conn, status, .{ .ctype = ctype, .length = if (no_body) null else body.len, .location = location, .extra = extras });
    const head = conn.headSlice();
    if (conn.ctx.status != status) {
        conn.setOutput(&.{head});
        return;
    }
    const send_body = !(conn.req.method == .HEAD and !conn.ctx.method_override_get) and !no_body;
    if (!send_body) {
        conn.setOutput(&.{head});
        return;
    }
    conn.ctx.body_bytes_sent = body.len;
    if (body.len <= conn.wbuf.len - head.len) {
        @memcpy(conn.wbuf[head.len..][0..body.len], body);
        conn.setOutput(&.{conn.wbuf[0 .. head.len + body.len]});
    } else {
        const copy = conn.arena().dupe(u8, body) catch body;
        conn.setOutput(&.{ head, copy });
    }
}

pub fn contentType(conn: *Conn, uri: []const u8) []const u8 {
    const lc = conn.ctx.conf;
    const slash = std.mem.lastIndexOfScalar(u8, uri, '/') orelse 0;
    if (std.mem.lastIndexOfScalar(u8, uri[slash..], '.')) |dot| {
        const ext = uri[slash + dot + 1 ..];
        if (ext.len > 0 and ext.len <= 16) {
            var lb: [16]u8 = undefined;
            const lower = std.ascii.lowerString(&lb, ext);
            if (lc.types.get(lower)) |t| return t;
        }
    }
    return lc.default_type;
}

test "range parsing" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 0), parseRange("bytes=0-9", 100).ok.start);
    try t.expectEqual(@as(u64, 9), parseRange("bytes=0-9", 100).ok.end);
    try t.expectEqual(@as(u64, 90), parseRange("bytes=-10", 100).ok.start);
    try t.expectEqual(@as(u64, 99), parseRange("bytes=50-", 100).ok.end);
    try t.expect(parseRange("bytes=200-", 100) == .bad);
    try t.expect(parseRange("items=1-2", 100) == .none);
}
