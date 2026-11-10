//! nginx.conf lexer and parser.
//!
//! Follows `ngx_conf_read_token` / `ngx_conf_parse`:
//! * tokens are separated by whitespace; `;` ends a directive, `{` opens and `}` closes a block;
//! * `#` at the start of a token begins a comment that runs to the end of the line;
//! * `"..."` and `'...'` are quoted tokens; a closing quote must be followed by whitespace,
//!   `;`, `{` or `)` (`unexpected "x"` otherwise);
//! * escapes `\"` `\'` `\\` `\t` `\r` `\n` are translated, any other `\x` is kept verbatim;
//! * `${name}` keeps its braces inside a word;
//! * `include <path|glob>` is expanded while parsing, in any context, relative to the
//!   configuration prefix (the directory of the main file, or `-p`), like nginx.
//!
//! The result is a generic AST: every directive is kept, whether or not zhttpd knows it.
const std = @import("std");
const os = @import("../os.zig");
const Diag = @import("diag.zig").Diag;

pub const Directive = struct {
    name: []const u8,
    args: []const []const u8,
    /// `true` for args that were quoted (needed to tell `''` from a missing value).
    quoted: []const bool,
    block: ?[]Directive,
    file: []const u8,
    line: u32,

    pub fn arg(d: *const Directive, i: usize) []const u8 {
        return d.args[i];
    }
};

pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    root: []Directive,
    files: []const []const u8,

    pub fn deinit(a: *Ast) void {
        a.arena.deinit();
    }
};

pub const Error = error{ ParseFailed, OutOfMemory };

const Tok = union(enum) {
    word: struct { text: []const u8, quoted: bool, line: u32 },
    semi: u32,
    lbrace: u32,
    rbrace: u32,
    eof: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    alloc: std.mem.Allocator,
    file: []const u8,
    diag: *Diag,

    fn fail(l: *Lexer, comptime fmt: []const u8, args: anytype) Error {
        l.diag.add(.emerg, l.file, l.line, fmt, args);
        return error.ParseFailed;
    }

    pub fn next(l: *Lexer) Error!Tok {
        // skip whitespace and comments
        while (l.pos < l.src.len) {
            const ch = l.src[l.pos];
            if (ch == '\n') {
                l.line += 1;
                l.pos += 1;
            } else if (ch == ' ' or ch == '\t' or ch == '\r') {
                l.pos += 1;
            } else if (ch == '#') {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else break;
        }
        if (l.pos >= l.src.len) return .{ .eof = l.line };
        const ch = l.src[l.pos];
        switch (ch) {
            ';' => {
                l.pos += 1;
                return .{ .semi = l.line };
            },
            '{' => {
                l.pos += 1;
                return .{ .lbrace = l.line };
            },
            '}' => {
                l.pos += 1;
                return .{ .rbrace = l.line };
            },
            '"', '\'' => return l.quoted(ch),
            else => return l.word(),
        }
    }

    fn quoted(l: *Lexer, q: u8) Error!Tok {
        const start_line = l.line;
        l.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (l.pos >= l.src.len) return l.fail("unexpected end of file, expecting \"{c}\"", .{q});
            const ch = l.src[l.pos];
            if (ch == '\n') l.line += 1;
            if (ch == '\\' and l.pos + 1 < l.src.len) {
                try l.escape(&out);
                continue;
            }
            l.pos += 1;
            if (ch == q) break;
            try out.append(l.alloc, ch);
        }
        if (l.pos < l.src.len) {
            const nx = l.src[l.pos];
            if (!(nx == ' ' or nx == '\t' or nx == '\r' or nx == '\n' or nx == ';' or nx == '{' or nx == ')'))
                return l.fail("unexpected \"{c}\"", .{nx});
        }
        return .{ .word = .{ .text = try out.toOwnedSlice(l.alloc), .quoted = true, .line = start_line } };
    }

    fn escape(l: *Lexer, out: *std.ArrayList(u8)) !void {
        const e = l.src[l.pos + 1];
        switch (e) {
            '"', '\'', '\\' => try out.append(l.alloc, e),
            't' => try out.append(l.alloc, '\t'),
            'r' => try out.append(l.alloc, '\r'),
            'n' => try out.append(l.alloc, '\n'),
            else => {
                try out.append(l.alloc, '\\');
                try out.append(l.alloc, e);
            },
        }
        if (e == '\n') l.line += 1;
        l.pos += 2;
    }

    fn word(l: *Lexer) Error!Tok {
        const start_line = l.line;
        var out: std.ArrayList(u8) = .empty;
        var in_var_brace = false;
        while (l.pos < l.src.len) {
            const ch = l.src[l.pos];
            if (in_var_brace) {
                try out.append(l.alloc, ch);
                l.pos += 1;
                if (ch == '}') in_var_brace = false;
                continue;
            }
            switch (ch) {
                ' ', '\t', '\r', '\n', ';' => break,
                '{' => {
                    if (out.items.len > 0 and out.items[out.items.len - 1] == '$') {
                        in_var_brace = true;
                        try out.append(l.alloc, ch);
                        l.pos += 1;
                        continue;
                    }
                    break;
                },
                '}' => break,
                '"', '\'' => return l.fail("unexpected \"{c}\"", .{ch}),
                '\\' => {
                    if (l.pos + 1 < l.src.len) {
                        try l.escape(&out);
                    } else {
                        try out.append(l.alloc, ch);
                        l.pos += 1;
                    }
                },
                else => {
                    try out.append(l.alloc, ch);
                    l.pos += 1;
                },
            }
        }
        return .{ .word = .{ .text = try out.toOwnedSlice(l.alloc), .quoted = false, .line = start_line } };
    }
};

pub const Options = struct {
    /// Directory relative `include` paths are resolved against (nginx "conf prefix").
    conf_prefix: []const u8,
    max_include_depth: u32 = 32,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    gpa: std.mem.Allocator,
    diag: *Diag,
    opts: Options,
    files: std.ArrayList([]const u8) = .empty,
    depth: u32 = 0,

    /// Parse a file. `inside_block` controls whether `}` / EOF are expected at the end.
    fn parseFile(p: *Parser, path: []const u8, out: *std.ArrayList(Directive), from_file: ?[]const u8, from_line: u32) Error!void {
        var e: c_int = 0;
        const src = os.readFileAlloc(p.alloc, path, &e) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                p.diag.add(.emerg, from_file, from_line, "open() \"{s}\" failed ({d}: {s})", .{ path, e, os.strerror(e) });
                return error.ParseFailed;
            },
        };
        const fname = try p.alloc.dupe(u8, path);
        try p.files.append(p.alloc, fname);
        var lx: Lexer = .{ .src = src, .alloc = p.alloc, .file = fname, .diag = p.diag };
        try p.parseBlock(&lx, out, false);
    }

    fn parseBlock(p: *Parser, lx: *Lexer, out: *std.ArrayList(Directive), in_block: bool) Error!void {
        while (true) {
            const t = try lx.next();
            switch (t) {
                .eof => {
                    if (in_block) return lx.fail("unexpected end of file, expecting \"}}\"", .{});
                    return;
                },
                .rbrace => {
                    if (!in_block) return lx.fail("unexpected \"}}\"", .{});
                    return;
                },
                .semi => return lx.fail("unexpected \";\"", .{}),
                .lbrace => return lx.fail("unexpected \"{{\"", .{}),
                .word => |w| {
                    var args: std.ArrayList([]const u8) = .empty;
                    var quoted: std.ArrayList(bool) = .empty;
                    const line = w.line;
                    while (true) {
                        const a = try lx.next();
                        switch (a) {
                            .word => |aw| {
                                try args.append(p.alloc, aw.text);
                                try quoted.append(p.alloc, aw.quoted);
                            },
                            .semi => {
                                if (std.mem.eql(u8, w.text, "include") and !w.quoted) {
                                    try p.include(lx.file, line, args.items, out);
                                } else {
                                    try out.append(p.alloc, .{ .name = w.text, .args = try args.toOwnedSlice(p.alloc), .quoted = try quoted.toOwnedSlice(p.alloc), .block = null, .file = lx.file, .line = line });
                                }
                                break;
                            },
                            .lbrace => {
                                var children: std.ArrayList(Directive) = .empty;
                                try p.parseBlock(lx, &children, true);
                                try out.append(p.alloc, .{ .name = w.text, .args = try args.toOwnedSlice(p.alloc), .quoted = try quoted.toOwnedSlice(p.alloc), .block = try children.toOwnedSlice(p.alloc), .file = lx.file, .line = line });
                                break;
                            },
                            .rbrace => return lx.fail("unexpected \"}}\"", .{}),
                            .eof => return lx.fail("unexpected end of file, expecting \";\" or \"}}\"", .{}),
                        }
                    }
                },
            }
        }
    }

    fn include(p: *Parser, file: []const u8, line: u32, args: []const []const u8, out: *std.ArrayList(Directive)) Error!void {
        if (args.len != 1) {
            p.diag.add(.emerg, file, line, "invalid number of arguments in \"include\" directive", .{});
            return error.ParseFailed;
        }
        if (p.depth >= p.opts.max_include_depth) {
            p.diag.add(.emerg, file, line, "include nesting too deep", .{});
            return error.ParseFailed;
        }
        const full = try fullName(p.alloc, p.opts.conf_prefix, args[0]);
        p.depth += 1;
        defer p.depth -= 1;
        if (os.hasGlob(full)) {
            const matches = os.glob(p.gpa, full) catch return error.OutOfMemory;
            defer os.freeList(p.gpa, matches);
            for (matches) |m| {
                const meta = os.stat(m) orelse continue;
                if (meta.kind == .dir) continue;
                try p.parseFile(m, out, file, line);
            }
        } else {
            try p.parseFile(full, out, file, line);
        }
    }
};

/// Resolve `name` against `prefix` unless absolute (ngx_conf_full_name).
pub fn fullName(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (name.len > 0 and name[0] == '/') return alloc.dupe(u8, name);
    if (prefix.len == 0) return alloc.dupe(u8, name);
    const sep: []const u8 = if (prefix[prefix.len - 1] == '/') "" else "/";
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, sep, name });
}

/// Parse a configuration file (and everything it includes) into an AST.
pub fn parseFile(gpa: std.mem.Allocator, path: []const u8, opts: Options, diag: *Diag) Error!Ast {
    var ast: Ast = .{ .arena = .init(gpa), .root = &.{}, .files = &.{} };
    errdefer ast.arena.deinit();
    var p: Parser = .{ .alloc = ast.arena.allocator(), .gpa = gpa, .diag = diag, .opts = opts };
    var out: std.ArrayList(Directive) = .empty;
    try p.parseFile(path, &out, null, 0);
    ast.root = try out.toOwnedSlice(p.alloc);
    ast.files = try p.files.toOwnedSlice(p.alloc);
    return ast;
}

/// Parse configuration text held in memory (tests, `-g` directives). `include` still reads files.
pub fn parseString(gpa: std.mem.Allocator, src: []const u8, name: []const u8, opts: Options, diag: *Diag) Error!Ast {
    var ast: Ast = .{ .arena = .init(gpa), .root = &.{}, .files = &.{} };
    errdefer ast.arena.deinit();
    var p: Parser = .{ .alloc = ast.arena.allocator(), .gpa = gpa, .diag = diag, .opts = opts };
    var out: std.ArrayList(Directive) = .empty;
    var lx: Lexer = .{ .src = src, .alloc = p.alloc, .file = name, .diag = diag };
    try p.parseBlock(&lx, &out, false);
    ast.root = try out.toOwnedSlice(p.alloc);
    ast.files = try p.files.toOwnedSlice(p.alloc);
    return ast;
}

/// Print the AST back as nginx syntax (used by `-T`).
pub fn dump(w: *std.Io.Writer, dirs: []const Directive, indent: usize) !void {
    for (dirs) |d| {
        try w.splatByteAll(' ', indent * 4);
        try w.writeAll(d.name);
        for (d.args) |a| {
            try w.writeByte(' ');
            if (needsQuote(a)) {
                try w.writeByte('"');
                for (a) |ch| {
                    if (ch == '"' or ch == '\\') try w.writeByte('\\');
                    try w.writeByte(ch);
                }
                try w.writeByte('"');
            } else try w.writeAll(a);
        }
        if (d.block) |b| {
            try w.writeAll(" {\n");
            try dump(w, b, indent + 1);
            try w.splatByteAll(' ', indent * 4);
            try w.writeAll("}\n");
        } else try w.writeAll(";\n");
    }
}

fn needsQuote(a: []const u8) bool {
    if (a.len == 0) return true;
    for (a) |ch| switch (ch) {
        ' ', '\t', '\n', '\r', ';', '{', '}', '"', '\'', '#' => return true,
        else => {},
    };
    return false;
}

// ---------------------------------------------------------------- tests
const tst = std.testing;

fn parseOk(src: []const u8) !Ast {
    var diag: Diag = .{ .gpa = tst.allocator };
    defer diag.deinit();
    return parseString(tst.allocator, src, "test.conf", .{ .conf_prefix = "." }, &diag);
}

test "lexer: quotes, escapes, comments, variables" {
    var ast = try parseOk(
        \\# comment
        \\user nobody; # trailing
        \\http {
        \\  log_format main '$remote_addr - "$request" ${status}x';
        \\  add_header X-A "a \"b\" \\ c\td";
        \\  map $http_upgrade $connection_upgrade { default upgrade; '' close; }
        \\  if ($request_uri ~* "^/a{2,3}") { return 403; }
        \\}
    );
    defer ast.deinit();
    try tst.expectEqual(@as(usize, 2), ast.root.len);
    const http = ast.root[1].block.?;
    try tst.expectEqualStrings("$remote_addr - \"$request\" ${status}x", http[0].args[1]);
    try tst.expectEqualStrings("a \"b\" \\ c\td", http[1].args[1]);
    const map = http[2].block.?;
    try tst.expectEqualStrings("", map[1].name);
    try tst.expect(map[1].block == null);
    try tst.expectEqualStrings("($request_uri", http[3].args[0]);
    try tst.expectEqualStrings("^/a{2,3}", http[3].args[2]);
    try tst.expectEqualStrings(")", http[3].args[3]);
}

test "lexer errors carry file:line" {
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{ .src = "http {\n server {\n", .msg = "unexpected end of file, expecting \"}\" in test.conf:3" },
        .{ .src = "a b\n", .msg = "unexpected end of file, expecting \";\" or \"}\" in test.conf:2" },
        .{ .src = "}\n", .msg = "unexpected \"}\" in test.conf:1" },
        .{ .src = "a \"b\"c;\n", .msg = "unexpected \"c\" in test.conf:1" },
        .{ .src = "include /nonexistent/zhttpd-test.conf;", .msg = "open() \"/nonexistent/zhttpd-test.conf\" failed (2: No such file or directory) in test.conf:1" },
    };
    for (cases) |cs| {
        var diag: Diag = .{ .gpa = tst.allocator };
        defer diag.deinit();
        try tst.expectError(error.ParseFailed, parseString(tst.allocator, cs.src, "test.conf", .{ .conf_prefix = "." }, &diag));
        tst.expect(diag.has(cs.msg)) catch |e| {
            for (diag.messages.items) |m| std.debug.print("got: {s}\n", .{m.text});
            return e;
        };
    }
}
