//! Compiled nginx "complex values": strings with `$var`, `${var}` and `$1`..`$9`.
//! Variable names are resolved once at config time into a `Var`, so evaluation in the
//! request path does no lookups by name for built-in variables.
const std = @import("std");

pub const Var = @import("http/expr.zig").Var;
pub const Part = @import("http/expr.zig").Part;
pub const Expr = @import("http/expr.zig").Expr;

const simple = std.StaticStringMap(Var).initComptime(.{
    .{ "fastcgi_script_name", .fastcgi_script_name },
    .{ "uri", .uri },
    .{ "document_uri", .uri },
    .{ "request_uri", .request_uri },
    .{ "args", .args },
    .{ "query_string", .args },
    .{ "is_args", .is_args },
    .{ "request_method", .request_method },
    .{ "request", .request },
    .{ "server_protocol", .server_protocol },
    .{ "scheme", .scheme },
    .{ "https", .https },
    .{ "host", .host },
    .{ "hostname", .hostname },
    .{ "server_name", .server_name },
    .{ "server_addr", .server_addr },
    .{ "server_port", .server_port },
    .{ "remote_addr", .remote_addr },
    .{ "remote_port", .remote_port },
    .{ "document_root", .document_root },
    .{ "realpath_root", .realpath_root },
    .{ "request_filename", .request_filename },
    .{ "content_type", .content_type },
    .{ "content_length", .content_length },
    .{ "request_length", .request_length },
    .{ "status", .status },
    .{ "body_bytes_sent", .body_bytes_sent },
    .{ "bytes_sent", .bytes_sent },
    .{ "request_time", .request_time },
    .{ "time_local", .time_local },
    .{ "time_iso8601", .time_iso8601 },
    .{ "msec", .msec },
    .{ "connection", .connection },
    .{ "connection_requests", .connection_requests },
    .{ "pid", .pid },
    .{ "nginx_version", .nginx_version },
    .{ "proxy_host", .proxy_host },
    .{ "proxy_port", .proxy_port },
    .{ "proxy_add_x_forwarded_for", .proxy_add_x_forwarded_for },
    .{ "upstream_addr", .upstream_addr },
    .{ "upstream_status", .upstream_status },
});

pub fn varFromName(name: []const u8) Var {
    if (simple.get(name)) |v| return v;
    if (name.len == 1 and std.ascii.isDigit(name[0])) return .{ .capture = name[0] - '0' };
    if (std.mem.startsWith(u8, name, "http_")) return .{ .http = name[5..] };
    if (std.mem.startsWith(u8, name, "sent_http_")) return .{ .sent_http = name[10..] };
    if (std.mem.startsWith(u8, name, "arg_")) return .{ .arg = name[4..] };
    if (std.mem.startsWith(u8, name, "cookie_")) return .{ .cookie = name[7..] };
    return .{ .named = name };
}

pub const CompileError = error{ OutOfMemory, BadVariable };

/// Compile a complex value. Memory comes from `alloc` (the config arena).
pub fn compile(alloc: std.mem.Allocator, s: []const u8) CompileError!Expr {
    var parts: std.ArrayList(Part) = .empty;
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < s.len) {
        if (s[i] != '$' or i + 1 >= s.len) {
            i += 1;
            continue;
        }
        var j = i + 1;
        var name: []const u8 = undefined;
        if (s[j] == '{') {
            const end = std.mem.indexOfScalarPos(u8, s, j, '}') orelse return error.BadVariable;
            name = s[j + 1 .. end];
            j = end + 1;
        } else if (std.ascii.isDigit(s[j])) {
            name = s[j .. j + 1];
            j += 1;
        } else {
            const st = j;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
            name = s[st..j];
        }
        if (name.len == 0) {
            i += 1;
            continue; // lone '$' stays literal
        }
        if (i > lit_start) try parts.append(alloc, .{ .lit = s[lit_start..i] });
        try parts.append(alloc, .{ .v = varFromName(name) });
        i = j;
        lit_start = j;
    }
    if (lit_start < s.len) try parts.append(alloc, .{ .lit = s[lit_start..] });
    return .{ .parts = try parts.toOwnedSlice(alloc), .raw = s };
}

test "expr compile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try compile(arena.allocator(), "https://$host${request_uri}x/$1$http_x_real_ip$");
    try std.testing.expectEqual(@as(usize, 7), e.parts.len);
    try std.testing.expectEqualStrings("https://", e.parts[0].lit);
    try std.testing.expect(e.parts[1].v == .host);
    try std.testing.expect(e.parts[2].v == .request_uri);
    try std.testing.expectEqual(@as(u8, 1), e.parts[4].v.capture);
    try std.testing.expectEqualStrings("x_real_ip", e.parts[5].v.http);
    try std.testing.expectEqualStrings("$", e.parts[6].lit);
}
