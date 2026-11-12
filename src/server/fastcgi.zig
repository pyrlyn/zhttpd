//! Request environment and nonblocking FastCGI transport filter for the proxy.
const std = @import("std");
const fcgi = @import("fastcgi");
const Conn = @import("conn.zig").Conn;
const vars = @import("vars.zig");
const net = @import("net.zig");
pub fn request(c: *Conn) ![]u8 {
    const a = c.arena();
    c.ctx.document_root = try vars.eval(a, c.ctx, c.ctx.conf.root);
    const script = if (std.mem.endsWith(u8, c.ctx.uri, "/")) try std.fmt.allocPrint(a, "{s}{s}", .{ c.ctx.uri, c.ctx.conf.fastcgi_index }) else c.ctx.uri;
    c.ctx.request_filename = try std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trimEnd(u8, c.ctx.document_root, "/"), script });
    var params: std.ArrayList(fcgi.Param) = .empty;
    const fields = .{ .{ "REQUEST_METHOD", .request_method }, .{ "REQUEST_URI", .request_uri }, .{ "QUERY_STRING", .args }, .{ "SERVER_PROTOCOL", .server_protocol }, .{ "SERVER_NAME", .host }, .{ "SERVER_PORT", .server_port }, .{ "REMOTE_ADDR", .remote_addr }, .{ "REMOTE_PORT", .remote_port }, .{ "DOCUMENT_ROOT", .document_root }, .{ "SCRIPT_FILENAME", .request_filename }, .{ "CONTENT_TYPE", .content_type } };
    inline for (fields) |field| {
        var value: std.ArrayList(u8) = .empty;
        try vars.appendVar(a, c.ctx, field[1], &value, 0);
        try params.append(a, .{ .name = field[0], .value = value.items });
    }
    try params.appendSlice(a, &.{
        .{ .name = "GATEWAY_INTERFACE", .value = "CGI/1.1" },
        .{ .name = "SERVER_SOFTWARE", .value = "zhttpd" },
        .{ .name = "CONTENT_LENGTH", .value = try std.fmt.allocPrint(a, "{d}", .{c.body.items.len}) },
        .{ .name = "SCRIPT_NAME", .value = if (c.ctx.conf.gateway == .wsgi) "" else script },
        .{ .name = "PATH_INFO", .value = if (c.ctx.conf.gateway == .wsgi) c.ctx.uri else "" },
        .{ .name = "HTTPS", .value = if (c.ctx.scheme_https) "on" else "off" },
    });
    for (c.req.headers[0..c.req.nheaders]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or std.ascii.eqlIgnoreCase(h.name, "content-type") or std.ascii.eqlIgnoreCase(h.name, "proxy") or std.ascii.eqlIgnoreCase(h.name, "connection") or std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
        const key = try std.fmt.allocPrint(a, "HTTP_{s}", .{h.name});
        for (key) |*ch| ch.* = if (ch.* == '-') '_' else std.ascii.toUpper(ch.*);
        try params.append(a, .{ .name = key, .value = h.value });
    }
    for (c.ctx.conf.fastcgi_params) |p| {
        const value = try vars.eval(a, c.ctx, p.value);
        if (p.if_not_empty and value.len == 0) continue;
        var replaced = false;
        for (params.items) |*entry| if (std.mem.eql(u8, entry.name, p.name)) {
            entry.value = value;
            replaced = true;
        };
        if (!replaced) try params.append(a, .{ .name = p.name, .value = value });
    }
    return fcgi.encode(c.w.gpa, params.items, c.body.items);
}
pub fn read(c: *Conn, output: []u8) net.Io {
    const up = c.up;
    while (true) {
        if (up.fcgi_pos < up.fcgi_len) {
            const r = up.fcgi_decoder.feed(up.fcgi_buffer[up.fcgi_pos..up.fcgi_len], output) catch return .{ .err = 71 };
            up.fcgi_pos += r.consumed;
            if (r.produced > 0) return .{ .ok = r.produced };
        }
        if (up.fcgi_decoder.done) return .eof;
        if (up.fcgi_pos != up.fcgi_len) return .{ .err = 71 };
        switch (net.read(up.fd, &up.fcgi_buffer)) {
            .ok => |n| {
                up.fcgi_pos = 0;
                up.fcgi_len = n;
            },
            .again => return .again,
            else => return .{ .err = 71 }, // only END_REQUEST is clean EOF
        }
    }
}
