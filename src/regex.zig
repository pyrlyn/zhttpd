//! Small backtracking regex engine covering the PCRE subset that nginx configs use
//! in `location ~`, `server_name ~`, `rewrite`, `map` and `if`.
//!
//! Supported: literals, `.`, classes `[a-z]` `[^...]` (with escapes and POSIX `[:alpha:]`),
//! `\d \D \w \W \s \S \b \B \A \z \Z`, anchors `^ $`, groups `( )`, `(?: )`,
//! named groups `(?<name> )` / `(?P<name> )` / `(?'name' )`, lookahead `(?= )` `(?! )`,
//! inline `(?i)` (whole pattern), alternation `|`, quantifiers `* + ? {n} {n,} {n,m}`
//! with lazy `?` suffix. Not supported (compile error): backreferences, lookbehind,
//! atomic groups, possessive quantifiers, unicode classes.
//!
//! Matching uses an explicit backtracking stack plus a step budget, so pathological
//! patterns fail with `error.StepLimit` instead of hanging or overflowing the stack.
const std = @import("std");

pub const max_groups = 16;

pub const CompileError = error{ OutOfMemory, BadPattern };

const Op = union(enum) {
    char: u8,
    any, // any byte except '\n'
    class: u16, // index into classes
    split: struct { a: u32, b: u32 }, // try a first, then b
    jmp: u32,
    save: u8, // capture slot
    bol,
    eol, // end or before final '\n'
    eot, // absolute end
    word_b,
    not_word_b,
    look: struct { neg: bool, start: u32, end: u32 }, // sub-program [start, end) ends in .match
    match,
};

pub const Regex = struct {
    ops: []Op,
    classes: []std.StaticBitSet(256),
    ngroups: u8, // including group 0
    names: []const Name,
    icase: bool,
    source: []const u8,

    pub const Name = struct { name: []const u8, group: u8 };

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, icase_default: bool) CompileError!Regex {
        var c: Compiler = .{ .gpa = gpa, .src = pattern, .icase = icase_default };
        errdefer c.deinitPartial();
        if (std.mem.startsWith(u8, pattern, "(?i)")) {
            c.icase = true;
            c.pos = 4;
        }
        try c.emit(.{ .save = 0 });
        try c.parseAlt();
        if (c.pos != c.src.len) return error.BadPattern;
        try c.emit(.{ .save = 1 });
        try c.emit(.match);
        return .{
            .ops = try c.ops.toOwnedSlice(gpa),
            .classes = try c.classes.toOwnedSlice(gpa),
            .ngroups = c.ngroups,
            .names = try c.names.toOwnedSlice(gpa),
            .icase = c.icase,
            .source = pattern,
        };
    }

    pub fn deinit(self: *Regex, gpa: std.mem.Allocator) void {
        gpa.free(self.ops);
        gpa.free(self.classes);
        gpa.free(self.names);
    }

    /// Capture slots: caps[2*i], caps[2*i+1] = start/end of group i, or -1.
    pub const Captures = struct {
        slots: [max_groups * 2]i32 = @splat(-1),
        n: u8 = 0,
        pub fn group(self: *const Captures, subject: []const u8, i: usize) ?[]const u8 {
            if (i >= self.n) return null;
            const s = self.slots[2 * i];
            const e = self.slots[2 * i + 1];
            if (s < 0 or e < 0) return null;
            return subject[@intCast(s)..@intCast(e)];
        }
    };

    pub const MatchError = error{StepLimit};

    /// Unanchored search (like PCRE). Returns true on match and fills `caps`.
    pub fn search(self: *const Regex, subject: []const u8, caps: ?*Captures) MatchError!bool {
        var budget: u32 = 2_000_000;
        var start: usize = 0;
        while (start <= subject.len) : (start += 1) {
            var local: Captures = .{ .n = self.ngroups };
            if (try self.run(0, @intCast(self.ops.len), subject, start, &local, &budget)) {
                if (caps) |cp| cp.* = local;
                return true;
            }
            // Pattern anchored with ^ at the very start: no need to retry other positions.
            if (self.ops.len > 1 and self.ops[1] == .bol) break;
        }
        return false;
    }

    pub fn isMatch(self: *const Regex, subject: []const u8) bool {
        return self.search(subject, null) catch false;
    }

    const Frame = union(enum) {
        branch: struct { pc: u32, sp: u32 },
        restore: struct { slot: u8, old: i32 },
    };

    fn run(self: *const Regex, start_pc: u32, end_pc: u32, s: []const u8, start_sp: usize, caps: *Captures, budget: *u32) MatchError!bool {
        _ = end_pc;
        var stack_buf: [512]Frame = undefined;
        var heap_stack: std.ArrayList(Frame) = .empty;
        defer heap_stack.deinit(std.heap.page_allocator);
        var sp_len: usize = 0;
        var pc: u32 = start_pc;
        var sp: usize = start_sp;
        const push = struct {
            fn f(buf: *[512]Frame, heap: *std.ArrayList(Frame), len: *usize, fr: Frame) void {
                if (len.* < buf.len) {
                    buf[len.*] = fr;
                } else {
                    heap.append(std.heap.page_allocator, fr) catch @panic("regex: out of memory");
                }
                len.* += 1;
            }
        }.f;
        while (true) {
            if (budget.* == 0) return error.StepLimit;
            budget.* -= 1;
            var fail = false;
            switch (self.ops[pc]) {
                .char => |ch| {
                    if (sp < s.len and (s[sp] == ch or (self.icase and std.ascii.toLower(s[sp]) == ch))) {
                        sp += 1;
                        pc += 1;
                    } else fail = true;
                },
                .any => {
                    if (sp < s.len and s[sp] != '\n') {
                        sp += 1;
                        pc += 1;
                    } else fail = true;
                },
                .class => |ci| {
                    if (sp < s.len and self.classes[ci].isSet(s[sp])) {
                        sp += 1;
                        pc += 1;
                    } else fail = true;
                },
                .split => |sb| {
                    push(&stack_buf, &heap_stack, &sp_len, .{ .branch = .{ .pc = sb.b, .sp = @intCast(sp) } });
                    pc = sb.a;
                },
                .jmp => |t| pc = t,
                .save => |slot| {
                    push(&stack_buf, &heap_stack, &sp_len, .{ .restore = .{ .slot = slot, .old = caps.slots[slot] } });
                    caps.slots[slot] = @intCast(sp);
                    pc += 1;
                },
                .bol => {
                    if (sp == 0) pc += 1 else fail = true;
                },
                .eol => {
                    if (sp == s.len or (sp + 1 == s.len and s[sp] == '\n')) pc += 1 else fail = true;
                },
                .eot => {
                    if (sp == s.len) pc += 1 else fail = true;
                },
                .word_b, .not_word_b => {
                    const a = sp > 0 and isWord(s[sp - 1]);
                    const b = sp < s.len and isWord(s[sp]);
                    const at = a != b;
                    if (at == (self.ops[pc] == .word_b)) pc += 1 else fail = true;
                },
                .look => |lk| {
                    var sub = caps.*;
                    const m = try self.run(lk.start, lk.end, s, sp, &sub, budget);
                    if (m != lk.neg) {
                        if (m) caps.* = sub;
                        pc = lk.end;
                    } else fail = true;
                },
                .match => return true,
            }
            if (fail) {
                while (true) {
                    if (sp_len == 0) return false;
                    sp_len -= 1;
                    const fr = if (sp_len < stack_buf.len) stack_buf[sp_len] else heap_stack.pop().?;
                    switch (fr) {
                        .restore => |r| caps.slots[r.slot] = r.old,
                        .branch => |br| {
                            pc = br.pc;
                            sp = br.sp;
                            break;
                        },
                    }
                }
            }
        }
    }
};

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    icase: bool,
    ops: std.ArrayList(Op) = .empty,
    classes: std.ArrayList(std.StaticBitSet(256)) = .empty,
    names: std.ArrayList(Regex.Name) = .empty,
    ngroups: u8 = 1,

    fn deinitPartial(c: *Compiler) void {
        c.ops.deinit(c.gpa);
        c.classes.deinit(c.gpa);
        c.names.deinit(c.gpa);
    }

    fn emit(c: *Compiler, op: Op) !void {
        try c.ops.append(c.gpa, op);
    }
    fn here(c: *Compiler) u32 {
        return @intCast(c.ops.items.len);
    }
    fn peek(c: *Compiler) ?u8 {
        return if (c.pos < c.src.len) c.src[c.pos] else null;
    }

    fn parseAlt(c: *Compiler) CompileError!void {
        const start = c.here();
        try c.parseSeq();
        if (c.peek() != '|') return;
        // Wrap: split L1, L2 ; L1: seq ; jmp end ; L2: rest
        var jumps: std.ArrayList(u32) = .empty;
        defer jumps.deinit(c.gpa);
        var branch_start = start;
        while (c.peek() == '|') {
            c.pos += 1;
            try c.insert(branch_start, .{ .split = .{ .a = 0, .b = 0 } });
            try c.emit(.{ .jmp = 0 });
            try jumps.append(c.gpa, c.here() - 1);
            const next = c.here();
            c.ops.items[branch_start] = .{ .split = .{ .a = branch_start + 1, .b = next } };
            branch_start = next;
            try c.parseSeq();
        }
        const end = c.here();
        for (jumps.items) |j| c.ops.items[j] = .{ .jmp = end };
    }

    /// Insert an op at `at`, shifting later ops and fixing jump targets.
    /// Ops located before `at` that target `at` keep pointing at `at` (the new op);
    /// ops located after it (the shifted ones) that target `at` follow the shift.
    fn insert(c: *Compiler, at: u32, op: Op) !void {
        try c.ops.insert(c.gpa, at, op);
        for (c.ops.items, 0..) |*o, i| {
            if (i == at) continue;
            const thr: u32 = if (i < at) at + 1 else at;
            switch (o.*) {
                .split => |*sb| {
                    if (sb.a >= thr) sb.a += 1;
                    if (sb.b >= thr) sb.b += 1;
                },
                .jmp => |*tg| {
                    if (tg.* >= thr) tg.* += 1;
                },
                .look => |*lk| {
                    if (lk.start >= thr) lk.start += 1;
                    if (lk.end >= thr) lk.end += 1;
                },
                else => {},
            }
        }
    }

    fn parseSeq(c: *Compiler) CompileError!void {
        while (c.peek()) |ch| {
            if (ch == '|' or ch == ')') return;
            const atom_start = c.here();
            try c.parseAtom();
            try c.parseQuant(atom_start);
        }
    }

    fn parseQuant(c: *Compiler, atom_start: u32) CompileError!void {
        const ch = c.peek() orelse return;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (ch) {
            '*' => c.pos += 1,
            '+' => {
                c.pos += 1;
                min = 1;
            },
            '?' => {
                c.pos += 1;
                max = 1;
            },
            '{' => {
                const save = c.pos;
                c.pos += 1;
                const n1 = c.parseNum() orelse {
                    c.pos = save; // literal '{'
                    return;
                };
                min = n1;
                max = n1;
                if (c.peek() == ',') {
                    c.pos += 1;
                    max = c.parseNum();
                }
                if (c.peek() != '}') {
                    c.pos = save;
                    return;
                }
                c.pos += 1;
                if (min > 100 or (max != null and max.? > 100)) return error.BadPattern;
            },
            else => return,
        }
        var lazy = false;
        if (c.peek() == '?') {
            c.pos += 1;
            lazy = true;
        } else if (c.peek() == '+') return error.BadPattern; // possessive
        if (c.peek()) |q| if (q == '*' or q == '+' or q == '?') return error.BadPattern;

        // Copy of the atom program for repetition.
        const atom_len = c.here() - atom_start;
        const atom = try c.gpa.dupe(Op, c.ops.items[atom_start..]);
        defer c.gpa.free(atom);
        c.ops.shrinkRetainingCapacity(atom_start);
        var i: u32 = 0;
        while (i < min) : (i += 1) try c.appendCopy(atom, atom_start);
        if (max) |mx| {
            // optional copies: split body, next
            var j: u32 = min;
            var fixups: std.ArrayList(u32) = .empty;
            defer fixups.deinit(c.gpa);
            while (j < mx) : (j += 1) {
                const sp = c.here();
                try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                try fixups.append(c.gpa, sp);
                try c.appendCopy(atom, atom_start);
            }
            const end = c.here();
            for (fixups.items) |sp| c.ops.items[sp] = if (lazy) .{ .split = .{ .a = end, .b = sp + 1 } } else .{ .split = .{ .a = sp + 1, .b = end } };
        } else {
            // star: L: split body, end ; body ; jmp L
            const l = c.here();
            try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
            try c.appendCopy(atom, atom_start);
            try c.emit(.{ .jmp = l });
            const end = c.here();
            c.ops.items[l] = if (lazy) .{ .split = .{ .a = end, .b = l + 1 } } else .{ .split = .{ .a = l + 1, .b = end } };
        }
        _ = atom_len;
    }

    /// Append ops copied from an atom that originally started at `orig`, relocating targets.
    fn appendCopy(c: *Compiler, atom: []const Op, orig: u32) !void {
        const base = c.here();
        for (atom) |op| {
            var o = op;
            switch (o) {
                .split => |*sb| {
                    sb.a = sb.a - orig + base;
                    sb.b = sb.b - orig + base;
                },
                .jmp => |*t| t.* = t.* - orig + base,
                .look => |*lk| {
                    lk.start = lk.start - orig + base;
                    lk.end = lk.end - orig + base;
                },
                else => {},
            }
            try c.emit(o);
        }
    }

    fn parseNum(c: *Compiler) ?u32 {
        const s = c.pos;
        while (c.peek()) |ch| {
            if (!std.ascii.isDigit(ch)) break;
            c.pos += 1;
        }
        if (s == c.pos) return null;
        return std.fmt.parseInt(u32, c.src[s..c.pos], 10) catch null;
    }

    fn emitChar(c: *Compiler, ch: u8) !void {
        if (c.icase and std.ascii.isAlphabetic(ch)) {
            try c.emit(.{ .char = std.ascii.toLower(ch) });
        } else try c.emit(.{ .char = ch });
    }

    fn addClass(c: *Compiler, set: std.StaticBitSet(256)) !void {
        var s = set;
        if (c.icase) {
            var ch: u16 = 'a';
            while (ch <= 'z') : (ch += 1) {
                const u: u8 = @intCast(ch);
                if (s.isSet(u) or s.isSet(std.ascii.toUpper(u))) {
                    s.set(u);
                    s.set(std.ascii.toUpper(u));
                }
            }
        }
        try c.classes.append(c.gpa, s);
        try c.emit(.{ .class = @intCast(c.classes.items.len - 1) });
    }

    fn parseAtom(c: *Compiler) CompileError!void {
        const ch = c.src[c.pos];
        c.pos += 1;
        switch (ch) {
            '.' => try c.emit(.any),
            '^' => try c.emit(.bol),
            '$' => try c.emit(.eol),
            '[' => try c.addClass(try c.parseClass()),
            '(' => try c.parseGroup(),
            '\\' => try c.parseEscape(),
            '*', '+', '?' => return error.BadPattern,
            else => try c.emitChar(ch),
        }
    }

    fn parseGroup(c: *Compiler) CompileError!void {
        var capture: ?u8 = null;
        if (c.peek() == '?') {
            c.pos += 1;
            const k = c.peek() orelse return error.BadPattern;
            c.pos += 1;
            switch (k) {
                ':' => {},
                '=', '!' => {
                    const look_at = c.here();
                    try c.emit(.{ .look = .{ .neg = k == '!', .start = 0, .end = 0 } });
                    try c.parseAlt();
                    if (c.peek() != ')') return error.BadPattern;
                    c.pos += 1;
                    try c.emit(.match);
                    c.ops.items[look_at] = .{ .look = .{ .neg = k == '!', .start = look_at + 1, .end = c.here() } };
                    return;
                },
                '<', 'P', '\'' => {
                    if (k == 'P') {
                        if (c.peek() != '<') return error.BadPattern;
                        c.pos += 1;
                    }
                    if (k == '<' and (c.peek() == '=' or c.peek() == '!')) return error.BadPattern; // lookbehind
                    const close: u8 = if (k == '\'') '\'' else '>';
                    const s = c.pos;
                    while (c.peek()) |x| {
                        if (x == close) break;
                        c.pos += 1;
                    }
                    if (c.peek() != close) return error.BadPattern;
                    const name = c.src[s..c.pos];
                    c.pos += 1;
                    if (c.ngroups >= max_groups) return error.BadPattern;
                    capture = c.ngroups;
                    try c.names.append(c.gpa, .{ .name = name, .group = c.ngroups });
                    c.ngroups += 1;
                },
                else => return error.BadPattern,
            }
        } else {
            if (c.ngroups >= max_groups) return error.BadPattern;
            capture = c.ngroups;
            c.ngroups += 1;
        }
        if (capture) |g| try c.emit(.{ .save = g * 2 });
        try c.parseAlt();
        if (c.peek() != ')') return error.BadPattern;
        c.pos += 1;
        if (capture) |g| try c.emit(.{ .save = g * 2 + 1 });
    }

    fn classFor(k: u8) ?std.StaticBitSet(256) {
        var s = std.StaticBitSet(256).empty;
        var i: u16 = 0;
        while (i < 256) : (i += 1) {
            const b: u8 = @intCast(i);
            const in = switch (std.ascii.toLower(k)) {
                'd' => std.ascii.isDigit(b),
                'w' => isWord(b),
                's' => b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0b or b == 0x0c,
                else => return null,
            };
            if (in != std.ascii.isUpper(k)) s.set(b);
        }
        return s;
    }

    fn escapedLiteral(c: *Compiler, k: u8) CompileError!u8 {
        return switch (k) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            'e' => 0x1b,
            '0' => 0,
            'x' => blk: {
                if (c.pos + 2 > c.src.len) return error.BadPattern;
                const v = std.fmt.parseInt(u8, c.src[c.pos .. c.pos + 2], 16) catch return error.BadPattern;
                c.pos += 2;
                break :blk v;
            },
            else => if (std.ascii.isAlphanumeric(k)) error.BadPattern else k,
        };
    }

    fn parseEscape(c: *Compiler) CompileError!void {
        const k = c.peek() orelse return error.BadPattern;
        c.pos += 1;
        if (classFor(k)) |set| return c.addClass(set);
        switch (k) {
            'b' => return c.emit(.word_b),
            'B' => return c.emit(.not_word_b),
            'A' => return c.emit(.bol),
            'z' => return c.emit(.eot),
            'Z' => return c.emit(.eol),
            else => {},
        }
        if (k >= '1' and k <= '9') return error.BadPattern; // backreference
        try c.emitChar(try c.escapedLiteral(k));
    }

    fn parseClass(c: *Compiler) CompileError!std.StaticBitSet(256) {
        var set = std.StaticBitSet(256).empty;
        var neg = false;
        if (c.peek() == '^') {
            neg = true;
            c.pos += 1;
        }
        var first = true;
        while (true) {
            const ch = c.peek() orelse return error.BadPattern;
            if (ch == ']' and !first) {
                c.pos += 1;
                break;
            }
            first = false;
            c.pos += 1;
            var lo: u8 = ch;
            if (ch == '[' and c.peek() == ':') {
                const end = std.mem.indexOfPos(u8, c.src, c.pos, ":]") orelse return error.BadPattern;
                const name = c.src[c.pos + 1 .. end];
                c.pos = end + 2;
                var i: u16 = 0;
                while (i < 256) : (i += 1) {
                    const b: u8 = @intCast(i);
                    const in = if (std.mem.eql(u8, name, "alpha")) std.ascii.isAlphabetic(b) else if (std.mem.eql(u8, name, "digit")) std.ascii.isDigit(b) else if (std.mem.eql(u8, name, "alnum")) std.ascii.isAlphanumeric(b) else if (std.mem.eql(u8, name, "space")) std.ascii.isWhitespace(b) else if (std.mem.eql(u8, name, "upper")) std.ascii.isUpper(b) else if (std.mem.eql(u8, name, "lower")) std.ascii.isLower(b) else if (std.mem.eql(u8, name, "xdigit")) std.ascii.isHex(b) else if (std.mem.eql(u8, name, "punct")) (std.ascii.isPrint(b) and !std.ascii.isAlphanumeric(b) and b != ' ') else return error.BadPattern;
                    if (in) set.set(b);
                }
                continue;
            }
            if (ch == '\\') {
                const k = c.peek() orelse return error.BadPattern;
                c.pos += 1;
                if (classFor(k)) |cs| {
                    set.setUnion(cs);
                    continue;
                }
                lo = try c.escapedLiteral(k);
            }
            var hi = lo;
            if (c.peek() == '-' and c.pos + 1 < c.src.len and c.src[c.pos + 1] != ']') {
                c.pos += 1;
                var h = c.src[c.pos];
                c.pos += 1;
                if (h == '\\') {
                    const k = c.peek() orelse return error.BadPattern;
                    c.pos += 1;
                    h = try c.escapedLiteral(k);
                }
                hi = h;
                if (hi < lo) return error.BadPattern;
            }
            var b: u16 = lo;
            while (b <= hi) : (b += 1) set.set(@intCast(b));
        }
        if (neg) set.toggleAll();
        return set;
    }
};

// ---------------------------------------------------------------- tests
const tst = std.testing;

fn expectMatch(p: []const u8, s: []const u8, want: bool) !void {
    var re = try Regex.compile(tst.allocator, p, false);
    defer re.deinit(tst.allocator);
    tst.expectEqual(want, re.isMatch(s)) catch |e| {
        std.debug.print("pattern {s} subject {s}\n", .{ p, s });
        return e;
    };
}

test "regex basics" {
    try expectMatch("\\.php$", "/index.php", true);
    try expectMatch("\\.php$", "/index.phpx", false);
    try expectMatch("^/(assets|_astro|_next/static|_nuxt)/", "/_next/static/x.js", true);
    try expectMatch("^/(assets|_astro|_next/static|_nuxt)/", "/static/x.js", false);
    try expectMatch("\\.(?:css|js|mjs|map|json|xml|txt|woff2?|ttf|otf|eot|svg|ico|png|jpe?g|gif|webp|avif|mp4|webm|pdf)$", "/a/b.woff2", true);
    try expectMatch("\\.(?:css|js|woff2?|jpe?g)$", "/a/b.jpeg", true);
    try expectMatch("\\.(?:css|js|woff2?|jpe?g)$", "/a/b.jpgx", false);
    try expectMatch("/\\.(?!well-known/)", "/.git/config", true);
    try expectMatch("/\\.(?!well-known/)", "/.well-known/acme", false);
    try expectMatch("a{2,3}b", "caab", true);
    try expectMatch("^a{2,3}b", "ab", false);
    try expectMatch("^[^/]+\\.example\\.com$", "www.example.com", true);
    try expectMatch("^[[:digit:]]+$", "123", true);
    try expectMatch("\\bfoo\\b", "a foo b", true);
    try expectMatch("(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaac", false);
}

test "regex icase and captures" {
    var re = try Regex.compile(tst.allocator, "\\.HTML?$", true);
    defer re.deinit(tst.allocator);
    try tst.expect(re.isMatch("/Index.html"));
    var re2 = try Regex.compile(tst.allocator, "^/users/(?<id>\\d+)/(\\w+)$", false);
    defer re2.deinit(tst.allocator);
    var caps: Regex.Captures = .{};
    try tst.expect(try re2.search("/users/42/posts", &caps));
    try tst.expectEqualStrings("42", caps.group("/users/42/posts", 1).?);
    try tst.expectEqualStrings("posts", caps.group("/users/42/posts", 2).?);
    try tst.expectEqualStrings("id", re2.names[0].name);
    var re3 = try Regex.compile(tst.allocator, "(?i)^/API/", false);
    defer re3.deinit(tst.allocator);
    try tst.expect(re3.isMatch("/api/x"));
    var re4 = try Regex.compile(tst.allocator, "^(.+?)(\\d*)$", false);
    defer re4.deinit(tst.allocator);
    try tst.expect(try re4.search("abc123", &caps));
    try tst.expectEqualStrings("abc", caps.group("abc123", 1).?);
}

test "regex rejects unsupported" {
    try tst.expectError(error.BadPattern, Regex.compile(tst.allocator, "(a)\\1", false));
    try tst.expectError(error.BadPattern, Regex.compile(tst.allocator, "(?<=a)b", false));
    try tst.expectError(error.BadPattern, Regex.compile(tst.allocator, "(ab", false));
}
