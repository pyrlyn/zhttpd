//! Native TOML application settings and explicit compatibility dispatch.
const std = @import("std");
const http = @import("http");
const nginx = @import("nginx");
const apache = @import("apache");
const litespeed = @import("litespeed");
const caddy = @import("caddy");
const support = @import("settings");
const Error = support.Error || error{BadVariable};
const C = http.config;
pub const Compatibility = enum { self, nginx, apache, litespeed, caddy };
pub const Options = struct { prefix: []const u8, conf_prefix: []const u8, strict: bool = false, quiet_ignored: bool = false, compatibility: Compatibility = .nginx, acme_domains: []const []const u8 = &.{}, sources: ?*http.config_watch.Sources = null };
const Modules = struct { http: bool = true, self: bool = true, nginx: bool = true, apache: bool = true, litespeed: bool = true, caddy: bool = true, websocket: bool = true, logging: bool = true, fastcgi: bool = true, wsgi: bool = true, acme: bool = true };
const Route = struct { path: ?[]const u8 = null, match: enum { prefix, exact } = .prefix, response: ?[]const u8 = null, root: ?[]const u8 = null, proxy: ?[]const u8 = null, websocket: bool = false, fastcgi: ?[]const u8 = null, wsgi: ?[]const u8 = null, status: u16 = 200 };
const Native = struct {
    listen: ?[]const u8 = null,
    root: ?[]const u8 = null,
    response: ?[]const u8 = null,
    index: []const u8 = "index.html",
    http2: bool = false,
    http3: bool = false,
    certificate: ?[]const u8 = null,
    key: ?[]const u8 = null,
    max_body_size: u32 = 1048576,
    keepalive_timeout_ms: u32 = 75000,
    routes: std.ArrayList(Route) = .empty,
};
const Logging = struct { access: ?[]const u8 = null, format: []const u8 = "combined", error_path: ?[]const u8 = null, level: ?u8 = null };
const Settings = struct {
    acme: http.acme.Settings = .{},
    certificates: std.ArrayList(http.acme.Settings) = .empty,
    has_acme: bool = false,
    logging: Logging = .{},
    has_logging: bool = false,
    modules: Modules = .{},
    compatibility: ?Compatibility = null,
    config: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    pid: ?[]const u8 = null,
    auto_reload: bool = true,
    error_log: ?[]const u8 = null,
    native: Native = .{},
    has_http: bool = false,
};
const Value = union(enum) { strings: []const []const u8, string: []const u8, boolean: bool, number: u32 };
const Toml = struct {
    a: std.mem.Allocator,
    file: []const u8,
    diag: *http.diag.Diag,
    line: u32 = 0,
    fn fail(p: *Toml, comptime message: []const u8, args: anytype) Error {
        p.diag.add(.emerg, p.file, p.line, message, args);
        return error.ConfigFailed;
    }
    fn string(p: *Toml, v: Value) Error![]const u8 {
        return if (v == .string) v.string else p.fail("expected a TOML string", .{});
    }
    fn strings(p: *Toml, v: Value) Error![]const []const u8 {
        return if (v == .strings) v.strings else p.fail("expected a TOML string array", .{});
    }
    fn boolean(p: *Toml, v: Value) Error!bool {
        return if (v == .boolean) v.boolean else p.fail("expected a TOML boolean", .{});
    }
    fn number(p: *Toml, v: Value) Error!u32 {
        return if (v == .number) v.number else p.fail("expected a nonnegative integer", .{});
    }
    fn value(p: *Toml, input: []const u8) Error!Value {
        const text = std.mem.trim(u8, input, " \t\r");
        if (text.len == 0) return p.fail("missing TOML value", .{});
        if (text[0] == '[') {
            var items: std.ArrayList([]const u8) = .empty;
            var i: usize = 1;
            while (true) {
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
                if (i >= text.len) return p.fail("unterminated TOML string array (use one line)", .{});
                if (text[i] == ']') {
                    const rest = std.mem.trimStart(u8, text[i + 1 ..], " \t\r");
                    if (rest.len > 0 and rest[0] != '#') return p.fail("unexpected data after array", .{});
                    return .{ .strings = try items.toOwnedSlice(p.a) };
                }
                if (text[i] != '"' and text[i] != 39) return p.fail("expected a string array element", .{});
                const start = i;
                const quote = text[i];
                i += 1;
                while (i < text.len and text[i] != quote) : (i += 1) {
                    if (quote == '"' and text[i] == 92) i += 1;
                }
                if (i >= text.len) return p.fail("unterminated array string", .{});
                i += 1;
                try items.append(p.a, try p.string(try p.value(text[start..i])));
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
                if (i < text.len and text[i] == ',') i += 1 else if (i >= text.len or text[i] != ']') return p.fail("expected comma or closing bracket", .{});
            }
        }
        if (text[0] == '"' or text[0] == '\'') {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == text[0]) {
                    const rest = std.mem.trimStart(u8, text[i + 1 ..], " \t\r");
                    if (rest.len > 0 and rest[0] != '#') return p.fail("unexpected data after string", .{});
                    return .{ .string = try out.toOwnedSlice(p.a) };
                }
                if (text[i] < 0x20 and text[i] != '\t') return p.fail("control character in TOML string", .{});
                if (text[0] == '"' and text[i] == '\\') {
                    i += 1;
                    if (i >= text.len) return p.fail("unterminated escape", .{});
                    const ch: u8 = switch (text[i]) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'b' => 8,
                        'f' => 12,
                        '"' => '"',
                        '\\' => '\\',
                        'u', 'U' => blk: {
                            const count: usize = if (text[i] == 'u') 4 else 8;
                            if (text.len - i - 1 < count) return p.fail("short Unicode escape", .{});
                            const cp = std.fmt.parseInt(u21, text[i + 1 .. i + 1 + count], 16) catch return p.fail("invalid Unicode escape", .{});
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("invalid Unicode code point", .{});
                            try out.appendSlice(p.a, buf[0..n]);
                            i += count;
                            break :blk 0;
                        },
                        else => return p.fail("invalid TOML escape", .{}),
                    };
                    if (ch != 0) try out.append(p.a, ch);
                } else try out.append(p.a, text[i]);
            }
            return p.fail("unterminated TOML string", .{});
        }
        const end = std.mem.indexOfScalar(u8, text, '#') orelse text.len;
        const raw = std.mem.trim(u8, text[0..end], " \t\r");
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };
        var digits: std.ArrayList(u8) = .empty;
        for (raw, 0..) |ch, i| {
            if (ch == '_') {
                if (i == 0 or i + 1 == raw.len or !std.ascii.isDigit(raw[i - 1]) or !std.ascii.isDigit(raw[i + 1])) return p.fail("invalid numeric separator", .{});
            } else if (std.ascii.isDigit(ch) or (ch == '+' and i == 0)) try digits.append(p.a, ch) else return p.fail("unsupported TOML value; expected string, boolean or decimal integer", .{});
        }
        const number_text = if (digits.items.len > 0 and digits.items[0] == '+') digits.items[1..] else digits.items;
        if (number_text.len > 1 and number_text[0] == '0') return p.fail("leading zeros are not permitted", .{});
        return .{ .number = std.fmt.parseInt(u32, number_text, 10) catch return p.fail("invalid integer", .{}) };
    }
    fn parse(p: *Toml, text: []const u8) Error!Settings {
        var result: Settings = .{};
        var section: []const u8 = "";
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var tables: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            p.line += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
                const table = std.mem.trimEnd(u8, line[0..end], " \t\r");
                if (std.mem.eql(u8, table, "[[http.routes]]")) {
                    try result.native.routes.append(p.a, .{});
                    section = "http.routes";
                    result.has_http = true;
                    continue;
                }
                if (std.mem.eql(u8, table, "[[acme.certificates]]")) {
                    try result.certificates.append(p.a, .{});
                    section = "acme.certificates";
                    continue;
                }
                if (!std.mem.endsWith(u8, table, "]")) return p.fail("invalid table", .{});
                section = std.mem.trim(u8, table[1 .. table.len - 1], " \t");
                if (!std.mem.eql(u8, section, "modules") and !std.mem.eql(u8, section, "server") and !std.mem.eql(u8, section, "http") and !std.mem.eql(u8, section, "http.tls") and !std.mem.eql(u8, section, "logging") and !std.mem.eql(u8, section, "acme")) return p.fail("unknown table {s}", .{section});
                const entry = try tables.getOrPut(p.a, section);
                if (entry.found_existing) return p.fail("duplicate table {s}", .{section});
                continue;
            }
            const sep = std.mem.indexOfScalar(u8, line, '=') orelse return p.fail("expected key = value", .{});
            const key = std.mem.trim(u8, line[0..sep], " \t");
            const id = try std.fmt.allocPrint(p.a, "{s}.{d}.{s}", .{ section, if (std.mem.eql(u8, section, "http.routes")) result.native.routes.items.len else if (std.mem.eql(u8, section, "acme.certificates")) result.certificates.items.len else 0, key });
            const entry = try seen.getOrPut(p.a, id);
            if (entry.found_existing) return p.fail("duplicate key {s}", .{key});
            const v = try p.value(line[sep + 1 ..]);
            if (std.mem.eql(u8, section, "modules")) {
                var found = false;
                inline for (.{ "http", "self", "nginx", "apache", "litespeed", "caddy", "websocket", "logging", "fastcgi", "wsgi", "acme" }) |field| if (std.mem.eql(u8, key, field)) {
                    @field(result.modules, field) = try p.boolean(v);
                    found = true;
                };
                if (!found) return p.fail("unknown module {s}", .{key});
            } else if (std.mem.eql(u8, section, "acme") or std.mem.eql(u8, section, "acme.certificates")) {
                const legacy = std.mem.eql(u8, section, "acme");
                if (legacy) result.has_acme = true;
                const ac = if (legacy) &result.acme else &result.certificates.items[result.certificates.items.len - 1];
                if (std.mem.eql(u8, key, "name")) ac.name = try p.string(v) else if (std.mem.eql(u8, key, "dns_env_file")) ac.dns_env_file = try p.string(v) else if (std.mem.eql(u8, key, "domains")) ac.domains = try p.strings(v) else if (std.mem.eql(u8, key, "challenge")) ac.challenge = std.meta.stringToEnum(http.acme.Challenge, try p.string(v)) orelse return p.fail("ACME challenge must be http-01 or dns-01", .{}) else if (std.mem.eql(u8, key, "dns_provider")) ac.dns_provider = try p.string(v) else if (std.mem.eql(u8, key, "dns_resolvers")) ac.dns_resolvers = try p.strings(v) else if (std.mem.eql(u8, key, "dns_propagation_wait_seconds")) ac.dns_propagation_wait_seconds = try p.number(v) else if (std.mem.eql(u8, key, "operation_timeout_seconds")) ac.operation_timeout_seconds = try p.number(v) else if (std.mem.eql(u8, key, "domain")) ac.domain = try p.string(v) else if (std.mem.eql(u8, key, "email")) ac.email = try p.string(v) else if (std.mem.eql(u8, key, "directory")) ac.directory = try p.string(v) else if (std.mem.eql(u8, key, "storage")) ac.storage = try p.string(v) else if (std.mem.eql(u8, key, "client")) ac.client = try p.string(v) else if (std.mem.eql(u8, key, "accept_terms")) ac.accept_terms = try p.boolean(v) else if (std.mem.eql(u8, key, "check_interval_seconds")) ac.check_interval_seconds = try p.number(v) else if (std.mem.eql(u8, key, "http_port") or std.mem.eql(u8, key, "renew_before_days")) {
                    const value_ = try p.number(v);
                    if (value_ == 0 or value_ > 65535) return p.fail("invalid ACME port/days", .{});
                    if (std.mem.eql(u8, key, "http_port")) ac.http_port = @intCast(value_) else ac.renew_before_days = @intCast(value_);
                } else return p.fail("unknown ACME setting {s}", .{key});
            } else if (std.mem.eql(u8, section, "logging")) {
                result.has_logging = true;
                if (std.mem.eql(u8, key, "access")) result.logging.access = try p.string(v) else if (std.mem.eql(u8, key, "format")) {
                    const f = try p.string(v);
                    if (!std.mem.eql(u8, f, "combined") and !std.mem.eql(u8, f, "common") and !std.mem.eql(u8, f, "json")) return p.fail("logging.format must be combined, common or json", .{});
                    result.logging.format = f;
                } else if (std.mem.eql(u8, key, "error")) result.logging.error_path = try p.string(v) else if (std.mem.eql(u8, key, "level")) result.logging.level = http.logging.level(try p.string(v)) orelse return p.fail("unknown logging level", .{}) else return p.fail("unknown logging setting {s}", .{key});
            } else if (std.mem.eql(u8, section, "server")) {
                if (std.mem.eql(u8, key, "auto_reload")) result.auto_reload = try p.boolean(v) else if (std.mem.eql(u8, key, "compatibility")) result.compatibility = std.meta.stringToEnum(Compatibility, try p.string(v)) orelse return p.fail("compatibility must be self, nginx, apache, litespeed or caddy", .{}) else if (std.mem.eql(u8, key, "config")) result.config = try p.string(v) else if (std.mem.eql(u8, key, "prefix")) result.prefix = try p.string(v) else if (std.mem.eql(u8, key, "pid")) result.pid = try p.string(v) else if (std.mem.eql(u8, key, "error_log")) result.error_log = try p.string(v) else return p.fail("unknown server setting {s}", .{key});
            } else if (std.mem.eql(u8, section, "http")) {
                result.has_http = true;
                if (std.mem.eql(u8, key, "listen")) result.native.listen = try p.string(v) else if (std.mem.eql(u8, key, "root")) result.native.root = try p.string(v) else if (std.mem.eql(u8, key, "response")) result.native.response = try p.string(v) else if (std.mem.eql(u8, key, "index")) result.native.index = try p.string(v) else if (std.mem.eql(u8, key, "http2")) result.native.http2 = try p.boolean(v) else if (std.mem.eql(u8, key, "http3")) result.native.http3 = try p.boolean(v) else if (std.mem.eql(u8, key, "max_body_size")) result.native.max_body_size = try p.number(v) else if (std.mem.eql(u8, key, "keepalive_timeout_ms")) result.native.keepalive_timeout_ms = try p.number(v) else return p.fail("unknown HTTP setting {s}", .{key});
            } else if (std.mem.eql(u8, section, "http.tls")) {
                result.has_http = true;
                if (std.mem.eql(u8, key, "certificate")) result.native.certificate = try p.string(v) else if (std.mem.eql(u8, key, "key")) result.native.key = try p.string(v) else return p.fail("unknown TLS setting {s}", .{key});
            } else if (std.mem.eql(u8, section, "http.routes")) {
                const r = &result.native.routes.items[result.native.routes.items.len - 1];
                if (std.mem.eql(u8, key, "path")) r.path = try p.string(v) else if (std.mem.eql(u8, key, "match")) r.match = std.meta.stringToEnum(@TypeOf(r.match), try p.string(v)) orelse return p.fail("route match must be prefix or exact", .{}) else if (std.mem.eql(u8, key, "response")) r.response = try p.string(v) else if (std.mem.eql(u8, key, "root")) r.root = try p.string(v) else if (std.mem.eql(u8, key, "proxy")) r.proxy = try p.string(v) else if (std.mem.eql(u8, key, "fastcgi")) r.fastcgi = try p.string(v) else if (std.mem.eql(u8, key, "wsgi")) r.wsgi = try p.string(v) else if (std.mem.eql(u8, key, "websocket")) r.websocket = try p.boolean(v) else if (std.mem.eql(u8, key, "status")) {
                    const code = try p.number(v);
                    if (code < 200 or code > 599) return p.fail("route status must be 200..599", .{});
                    r.status = @intCast(code);
                } else return p.fail("unknown route setting {s}", .{key});
            } else return p.fail("key must be inside a known table", .{});
        }
        const mode = result.compatibility orelse return p.fail("server.compatibility is required", .{});
        if (!result.modules.http) return p.fail("http module is disabled", .{});
        const active = switch (mode) {
            .self => result.modules.self,
            .nginx => result.modules.nginx,
            .apache => result.modules.apache,
            .litespeed => result.modules.litespeed,
            .caddy => result.modules.caddy,
        };
        if (!active) return p.fail("selected compatibility module {s} is disabled", .{@tagName(mode)});
        if (mode != .self and result.config == null) return p.fail("server.config is required for external compatibility", .{});
        if (mode != .self and result.has_http) return p.fail("[http] settings are only valid with compatibility = self", .{});
        if (mode == .self and result.config != null) return p.fail("server.config is not used with compatibility = self", .{});
        for (result.native.routes.items) |r| {
            if (r.fastcgi != null and !result.modules.fastcgi) return p.fail("fastcgi module is disabled", .{});
            if (r.wsgi != null and (!result.modules.wsgi or !result.modules.fastcgi)) return p.fail("wsgi requires enabled wsgi and fastcgi modules", .{});
        }
        for (result.native.routes.items) |r| if (r.websocket and !result.modules.websocket) return p.fail("websocket module is disabled", .{});
        if (!result.modules.logging and result.has_logging) return p.fail("logging module is disabled", .{});
        if (result.has_acme and result.certificates.items.len > 0) return p.fail("use either [acme] or [[acme.certificates]], not both", .{});
        const legacy = result.has_acme;
        if (legacy) try result.certificates.append(p.a, result.acme);
        if (result.certificates.items.len > 0) {
            if (!result.modules.acme) return p.fail("acme module is disabled", .{});
            if (result.native.certificate != null or result.native.key != null) return p.fail("ACME manages TLS certificate paths; remove [http.tls]", .{});
            for (result.certificates.items, 0..) |*ac, i| {
                const prefix = if (legacy) "acme.0." else try std.fmt.allocPrint(p.a, "acme.certificates.{d}.", .{i + 1});
                if (!legacy and ac.name.len == 0) return p.fail("each ACME certificate requires a name", .{});
                for (ac.name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return p.fail("invalid ACME certificate name", .{});
                try p.normalizeAcme(ac, seen, prefix);
                if (ac.name.len == 0) ac.name = ac.domain;
                for (result.certificates.items[0..i]) |other| {
                    if (std.mem.eql(u8, ac.name, other.name)) return p.fail("duplicate ACME certificate name {s}", .{ac.name});
                    for (ac.domains) |domain| for (other.domains) |other_domain| {
                        if (std.mem.eql(u8, domain, other_domain)) return p.fail("domain {s} belongs to multiple ACME certificates", .{domain});
                    };
                }
            }
            result.has_acme = true;
            result.acme = result.certificates.items[0];
        }
        return result;
    }
    fn hasKey(p: *Toml, seen: std.StringHashMapUnmanaged(void), prefix: []const u8, key: []const u8) Error!bool {
        return seen.contains(try std.mem.concat(p.a, u8, &.{ prefix, key }));
    }
    fn normalizeAcme(p: *Toml, ac: *http.acme.Settings, seen: std.StringHashMapUnmanaged(void), prefix: []const u8) Error!void {
        if (!ac.accept_terms) return p.fail("acme.accept_terms must explicitly be true", .{});
        const has_domain = try p.hasKey(seen, prefix, "domain");
        const has_domains = try p.hasKey(seen, prefix, "domains");
        if (has_domain and has_domains) return p.fail("ACME domain and domains are mutually exclusive", .{});
        if (has_domain) ac.domains = try p.a.dupe([]const u8, &.{ac.domain});
        if (ac.domains.len == 0 or std.mem.indexOfScalar(u8, ac.email, '@') == null) return p.fail("ACME requires nonempty domains and contact email", .{});
        const normalized = try p.a.alloc([]const u8, ac.domains.len);
        for (ac.domains, 0..) |domain, i| {
            const wildcard = std.mem.startsWith(u8, domain, "*.");
            if (!http.acme.validDomain(if (wildcard) domain[2..] else domain)) return p.fail("invalid ACME DNS domain {s}", .{domain});
            if (wildcard and ac.challenge != .@"dns-01") return p.fail("wildcard certificates require dns-01", .{});
            normalized[i] = try std.ascii.allocLowerString(p.a, domain);
            for (normalized[0..i]) |previous| if (std.mem.eql(u8, previous, normalized[i])) return p.fail("duplicate ACME domain {s}", .{domain});
        }
        ac.domains = normalized;
        ac.domain = normalized[0];
        // Give each SAN set its own cache. A changed set cannot reuse a certificate
        // with stale names while waiting for its first background renewal.
        if (normalized.len == 1) {
            ac.cert_name = if (std.mem.startsWith(u8, ac.domain, "*.")) try std.fmt.allocPrint(p.a, "_{s}", .{ac.domain[1..]}) else ac.domain;
        } else {
            const sorted = try p.a.dupe([]const u8, normalized);
            std.mem.sort([]const u8, sorted, {}, struct {
                fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.lessThan(u8, lhs, rhs);
                }
            }.less);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            for (sorted) |domain| {
                hash.update(domain);
                hash.update("\n");
            }
            var digest: [32]u8 = undefined;
            hash.final(&digest);
            ac.cert_name = try std.fmt.allocPrint(p.a, "san-{s}", .{std.fmt.bytesToHex(digest, .lower)});
        }
        if (ac.challenge == .@"dns-01") {
            if (ac.dns_provider.len == 0 or std.mem.eql(u8, ac.dns_provider, "manual")) return p.fail("dns-01 requires an automatic dns_provider", .{});
            for (ac.dns_provider) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return p.fail("invalid DNS provider code", .{});
            for (ac.dns_resolvers) |resolver| {
                if (resolver.len == 0) return p.fail("empty DNS resolver", .{});
                for (resolver) |ch| if (ch <= 32 or ch == 127) return p.fail("invalid DNS resolver", .{});
            }
        } else if (try p.hasKey(seen, prefix, "dns_provider") or try p.hasKey(seen, prefix, "dns_resolvers") or try p.hasKey(seen, prefix, "dns_propagation_wait_seconds")) return p.fail("DNS settings require dns-01", .{});
        if (ac.dns_env_file) |path| {
            if (path.len == 0) return p.fail("dns_env_file must not be empty", .{});
            if (ac.challenge != .@"dns-01") return p.fail("DNS settings require dns-01", .{});
        }
        if (ac.operation_timeout_seconds == 0) return p.fail("ACME operation timeout must be positive", .{});
        if (ac.dns_propagation_wait_seconds >= ac.operation_timeout_seconds) return p.fail("DNS propagation wait must be shorter than operation timeout", .{});
        if (ac.check_interval_seconds == 0) return p.fail("ACME interval must be positive", .{});
        if (!std.mem.startsWith(u8, ac.directory, "https://")) return p.fail("ACME directory requires HTTPS", .{});
    }
};

fn native(gpa: std.mem.Allocator, file: []const u8, root: []const u8, n: Native, diag: *http.diag.Diag) Error!*C.Config {
    var b = try support.Builder.init(gpa, file, root, diag);
    errdefer support.destroy(gpa, b.cfg);
    const origin: support.Node = .{ .name = "http", .args = &.{}, .file = file, .line = 0 };
    const s = try b.server(origin, null);
    const listen = n.listen orelse return b.fail(origin, "http.listen is required", .{});
    const addr = try b.address(origin, listen, 80);
    if (n.root != null and n.response != null) return b.fail(origin, "http.root and http.response are mutually exclusive", .{});
    if (n.root) |path| s.conf.root = try b.literal(try b.fullPath(root, path));
    try b.indexes(s.conf, &.{n.index});
    s.conf.client_max_body_size = n.max_body_size;
    s.conf.keepalive_timeout_ms = n.keepalive_timeout_ms;
    s.http2 = n.http2;
    if ((n.certificate != null) != (n.key != null)) return b.fail(origin, "TLS certificate and key must be specified together", .{});
    const secure = n.certificate != null;
    if ((n.http2 or n.http3) and !secure) return b.fail(origin, "HTTP/2 and HTTP/3 require [http.tls]", .{});
    if (n.certificate) |cert| s.tls.certificate = try b.fullPath(root, cert);
    if (n.key) |key| s.tls.certificate_key = try b.fullPath(root, key);
    try b.listen(s, addr, secure, false);
    if (n.http3) try b.listen(s, addr, true, true);
    var fallback = false;
    for (n.routes.items) |r| {
        const route_path = r.path orelse return b.fail(origin, "each route requires path", .{});
        const count: u8 = @as(u8, @intFromBool(r.response != null)) + @as(u8, @intFromBool(r.root != null)) + @as(u8, @intFromBool(r.proxy != null)) + @as(u8, @intFromBool(r.websocket)) + @as(u8, @intFromBool(r.fastcgi != null)) + @as(u8, @intFromBool(r.wsgi != null));
        if (count != 1) return b.fail(origin, "route requires exactly one of response, root, proxy, websocket, fastcgi, wsgi", .{});
        if (r.status != 200 and r.response == null) return b.fail(origin, "route status only applies to response", .{});
        const loc = try b.locationKind(s, origin, route_path, if (r.match == .exact) .exact else .prefix);
        fallback = fallback or (r.match == .prefix and std.mem.eql(u8, route_path, "/"));
        if (r.response) |text| loc.stmts = try b.a.dupe(C.Stmt, &.{.{ .ret = .{ .code = r.status, .text = try b.literal(text) } }});
        if (r.root) |path| loc.conf.root = try b.literal(try b.fullPath(root, path));
        if (r.proxy) |url| try b.proxy(loc.conf, origin, url);
        if (r.websocket) loc.conf.websocket = .{};
        if (r.fastcgi orelse r.wsgi) |target| {
            if (std.mem.indexOfScalar(u8, target, '/') != null) return b.fail(origin, "gateway requires host:port", .{});
            try b.proxy(loc.conf, origin, target);
            loc.conf.gateway = if (r.wsgi != null) .wsgi else .fastcgi;
        }
    }
    if (n.root == null and !fallback) {
        const loc = try b.location(s, origin, "/");
        loc.stmts = try b.a.dupe(C.Stmt, &.{.{ .ret = .{ .code = if (n.response != null) 200 else 404, .text = if (n.response) |text| try b.literal(text) else null } }});
    } else if (fallback and n.response != null) return b.fail(origin, "http.response conflicts with a / prefix route", .{});
    b.cfg.source_files = try b.a.dupe([]const u8, &.{file});
    return b.cfg;
}

pub fn load(gpa: std.mem.Allocator, file: []const u8, opts: Options, diag: *http.diag.Diag) Error!*C.Config {
    if (opts.sources) |sources| try sources.observe(file, .file);
    if (!std.mem.endsWith(u8, file, ".toml")) return adapter(gpa, file, opts.prefix, opts, opts.compatibility, diag);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var errno: c_int = 0;
    const text = http.os.readFileAlloc(a, file, &errno) catch {
        diag.add(.emerg, file, 0, "cannot read TOML ({d})", .{errno});
        return error.ConfigFailed;
    };
    if (text.len > 1024 * 1024) return error.ConfigFailed;
    var parser: Toml = .{ .a = a, .file = file, .diag = diag };
    var settings = try parser.parse(text);
    const dir = std.fs.path.dirname(file) orelse opts.prefix;
    const root = if (settings.prefix) |p| try std.fs.path.resolve(a, &.{ dir, p }) else dir;
    var acme_domains: std.ArrayList([]const u8) = .empty;
    for (settings.certificates.items) |*ac| {
        ac.storage = try std.fs.path.resolve(a, &.{ root, ac.storage });
        if (ac.dns_env_file) |path| {
            ac.dns_env_file = try std.fs.path.resolve(a, &.{ root, path });
            if (http.acme.fingerprint(ac.dns_env_file.?) == null) return parser.fail("cannot read nonempty dns_env_file for ACME certificate {s}", .{ac.name});
        }
        if (std.mem.indexOfScalar(u8, ac.client, '/')) |_| ac.client = try std.fs.path.resolve(a, &.{ root, ac.client });
        ac.certificate = try std.fmt.allocPrint(a, "{s}/certificates/{s}.crt", .{ ac.storage, ac.cert_name });
        ac.key = try std.fmt.allocPrint(a, "{s}/certificates/{s}.key", .{ ac.storage, ac.cert_name });
        try acme_domains.appendSlice(a, ac.domains);
    }
    if (settings.has_acme) {
        settings.native.certificate = settings.certificates.items[0].certificate;
        settings.native.key = settings.certificates.items[0].key;
    }
    const cfg = if (settings.compatibility.? == .self) try native(gpa, file, root, settings.native, diag) else blk: {
        const source = try std.fs.path.resolve(a, &.{ dir, settings.config.? });
        var adapter_opts = opts;
        adapter_opts.acme_domains = acme_domains.items;
        break :blk try adapter(gpa, source, root, adapter_opts, settings.compatibility.?, diag);
    };
    errdefer support.destroy(gpa, cfg);
    const own = cfg.arena.allocator();
    if (settings.has_acme) {
        for (settings.certificates.items) |ac| for (cfg.listens) |listener| {
            if (ac.challenge == .@"http-01" and !listener.opts.quic and listener.addr.port == ac.http_port) return parser.fail("HTTP-01 challenge port must be reserved for the ACME client", .{});
        };
        try applyAcme(&parser, cfg, settings.certificates.items, settings.compatibility.?);
    }
    if (settings.pid) |p| cfg.pid_path = try std.fs.path.resolve(own, &.{ root, p });
    if (settings.error_log) |p| cfg.error_log.path = if (std.mem.eql(u8, p, "stderr")) p else try std.fs.path.resolve(own, &.{ root, p });
    for (cfg.servers) |srv| {
        try validateModuleHandlers(&parser, settings.modules, srv.conf);
        try validateModuleLocations(&parser, settings.modules, srv.locations);
        try validateModuleLocations(&parser, settings.modules, srv.named);
    }
    cfg.auto_reload = settings.auto_reload;
    cfg.logging_enabled = settings.modules.logging;
    var log_builder: support.Builder = .{ .cfg = cfg, .a = own, .diag = diag };
    const origin: support.Node = .{ .name = "logging", .args = &.{}, .file = file, .line = 0 };
    if (settings.logging.error_path) |p| cfg.error_log.path = try log_builder.logPath(origin, p);
    if (settings.logging.level) |level| cfg.error_log.level = level;
    if (settings.logging.access) |p| {
        const f = settings.logging.format;
        const is_json = std.mem.eql(u8, f, "json");
        const text_ = if (is_json) http.logging.json else if (std.mem.eql(u8, f, "common")) http.logging.common else http.logging.combined;
        const format = try log_builder.logFormat(origin, f, text_, if (is_json) .json else .default);
        const logs_: ?[]C.AccessLog = if (std.mem.eql(u8, p, "off")) null else try own.dupe(C.AccessLog, &.{.{ .path = try log_builder.logPath(origin, p), .format = format }});
        for (cfg.servers) |srv| {
            srv.conf.access_logs = logs_;
            overrideLogs(srv.locations, logs_);
            overrideLogs(srv.named, logs_);
        }
    }
    // Adapters may keep source paths and literals from the TOML arena.
    cfg.retained_arenas = try own.dupe(std.heap.ArenaAllocator, &.{arena});
    return cfg;
}
// Adapter-independent certificate ownership. Never turn a plaintext listener
// into TLS or assign a domain certificate to unrelated virtual hosts.
fn acmeHost(p: *Toml, name: C.ServerName) Error!?[]const u8 {
    return switch (name) {
        .exact => |value| value,
        .lead => |value| try std.fmt.allocPrint(p.a, "*{s}", .{value}),
        else => null,
    };
}
fn applyAcme(p: *Toml, cfg: *C.Config, certificates: []const http.acme.Settings, mode: Compatibility) Error!void {
    const matched = try p.a.alloc(bool, certificates.len);
    @memset(matched, false);
    for (cfg.listens) |listener| {
        if (!listener.opts.ssl) continue;
        for (listener.entries) |entry| {
            const srv = entry.server;
            if (srv.tls.acme_certificates.len > 0) continue;
            var selected: std.ArrayList(usize) = .empty;
            for (certificates, 0..) |ac, index| {
                var intersects = mode == .self;
                for (srv.names) |name| {
                    const host = (try acmeHost(p, name)) orelse continue;
                    intersects = intersects or http.acme.covers(ac.domains, host);
                    // An exact certificate may override part of a wildcard virtual host.
                    for (ac.domains) |domain| intersects = intersects or http.acme.covers(&.{host}, domain);
                }
                if (intersects) try selected.append(p.a, index);
            }
            if (selected.items.len == 0) continue;
            if (mode != .self) for (srv.names) |name| {
                const host = (try acmeHost(p, name)) orelse return p.fail("ACME certificate must cover every name of a managed HTTPS virtual host", .{});
                var covered = false;
                for (selected.items) |index| covered = covered or http.acme.covers(certificates[index].domains, host);
                if (!covered) return p.fail("ACME certificate must cover every name of a managed HTTPS virtual host", .{});
            };
            if (srv.tls.reject_handshake) return p.fail("ACME host rejects TLS handshakes", .{});
            // The first configured certificate is the no-SNI/default fallback.
            srv.tls.certificate = certificates[selected.items[0]].certificate;
            srv.tls.certificate_key = certificates[selected.items[0]].key;
            srv.tls.acme_certificates = try selected.toOwnedSlice(p.a);
            for (srv.tls.acme_certificates) |index| matched[index] = true;
        }
    }
    for (matched, certificates) |used, ac| if (!used) return p.fail("ACME domain {s} requires a matching HTTPS virtual host", .{ac.domain});
    cfg.acme = certificates;
}
fn validateModuleHandlers(p: *Toml, modules: Modules, lc: *C.LocConf) Error!void {
    if (lc.gateway != .http and !modules.fastcgi) return p.fail("fastcgi module is disabled", .{});
    if (lc.gateway == .wsgi and !modules.wsgi) return p.fail("wsgi module is disabled", .{});
    if (lc.websocket != null and !modules.websocket) return p.fail("websocket module is disabled", .{});
}
fn validateModuleLocations(p: *Toml, modules: Modules, locations: []*C.Location) Error!void {
    for (locations) |loc| {
        try validateModuleHandlers(p, modules, loc.conf);
        try validateModuleLocations(p, modules, loc.children);
    }
}
fn overrideLogs(locations: []*C.Location, logs: ?[]C.AccessLog) void {
    for (locations) |loc| {
        loc.conf.access_logs = logs;
        overrideLogs(loc.children, logs);
    }
}
fn adapter(gpa: std.mem.Allocator, file: []const u8, root: []const u8, opts: Options, mode: Compatibility, diag: *http.diag.Diag) Error!*C.Config {
    return switch (mode) {
        .self => {
            diag.add(.emerg, file, 0, "self compatibility requires a .toml configuration", .{});
            return error.ConfigFailed;
        },
        .nginx => blk: {
            const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{std.fs.path.dirname(file) orelse root});
            defer gpa.free(prefix);
            break :blk nginx.load(gpa, file, .{ .prefix = root, .conf_prefix = prefix, .strict = opts.strict, .quiet_ignored = opts.quiet_ignored, .sources = opts.sources }, diag);
        },
        .apache => apache.load(gpa, file, .{ .server_root = root, .sources = opts.sources }, diag),
        .litespeed => litespeed.loadObserved(gpa, file, root, opts.sources, diag),
        .caddy => caddy.loadObserved(gpa, file, root, opts.acme_domains, opts.sources, diag),
    };
}

test "TOML requires known, enabled compatibility and rejects typos" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: http.diag.Diag = .{ .gpa = t.allocator };
    defer d.deinit();
    var p: Toml = .{ .a = arena.allocator(), .file = "config.toml", .diag = &d };
    try t.expectError(error.ConfigFailed, p.parse("[http]\nlisten = '8080'\n"));
    try t.expectError(error.ConfigFailed, p.parse("[server]\ncompatibility = 'unknown'\n"));
    try t.expectError(error.ConfigFailed, p.parse("[modules]\napache = false\n[server]\ncompatibility = 'apache'\nconfig = 'httpd.conf'\n"));
    try t.expectError(error.ConfigFailed, p.parse("[server]\ncompatibility = 'self'\n[http]\nlistne = '8080'\n"));
    const valid = try p.parse("[server]\ncompatibility = 'self'\n[http]\nlisten = '8080'\nresponse = \"hello # world\" # comment\n[[http.routes]]\npath = '/health'\nresponse = 'ok'\n");
    try t.expectEqualStrings("hello # world", valid.native.response.?);
    try t.expectEqual(@as(usize, 1), valid.native.routes.items.len);
}

test "ACME cache identity follows normalized SAN set and preserves legacy paths" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: http.diag.Diag = .{ .gpa = t.allocator };
    defer d.deinit();
    var p: Toml = .{ .a = arena.allocator(), .file = "config.toml", .diag = &d };
    const base = "[server]\ncompatibility='self'\n[http]\nlisten='8443'\n[acme]\nemail='admin@example.com'\naccept_terms=true\n";
    const legacy = try p.parse(base ++ "domain='Example.COM'\n");
    const single = try p.parse(base ++ "domains=['example.com',] # one-line array\n");
    try t.expectEqualStrings("example.com", legacy.acme.cert_name);
    try t.expectEqualStrings(legacy.acme.cert_name, single.acme.cert_name);
    const first = try p.parse(base ++ "domains=['example.com', 'www.example.com']\n");
    const reordered = try p.parse(base ++ "domains=['WWW.EXAMPLE.COM', 'example.com']\n");
    try t.expectEqualStrings(first.acme.cert_name, reordered.acme.cert_name);
    const changed = try p.parse(base ++ "domains=['example.com', 'new.example.com']\n");
    try t.expect(!std.mem.eql(u8, first.acme.cert_name, changed.acme.cert_name));
    const wildcard = try p.parse(base ++ "domains=['*.Example.com']\nchallenge='dns-01'\ndns_provider='cloudflare'\n");
    try t.expectEqualStrings("_.example.com", wildcard.acme.cert_name);
    try t.expectEqualStrings("*.example.com", wildcard.acme.domains[0]);
}

test "separate certificate records have independent settings and key namespaces" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: http.diag.Diag = .{ .gpa = t.allocator };
    defer d.deinit();
    var p: Toml = .{ .a = arena.allocator(), .file = "config.toml", .diag = &d };
    const prefix = "[server]\ncompatibility='self'\n[http]\nlisten='8443'\n";
    const first = "[[acme.certificates]]\nname='wild'\ndomains=['*.example.com']\nemail='a@example.com'\naccept_terms=true\nchallenge='dns-01'\ndns_provider='cloudflare'\ndns_env_file='a.env'\ncheck_interval_seconds=123\n";
    const second = "[[acme.certificates]]\nname='api'\ndomain='api.example.com'\nemail='b@example.com'\naccept_terms=true\nchallenge='dns-01'\ndns_provider='route53'\ndns_env_file='b.env'\ncheck_interval_seconds=456\n";
    const result = try p.parse(prefix ++ first ++ second);
    try t.expectEqual(@as(usize, 2), result.certificates.items.len);
    try t.expectEqualStrings("cloudflare", result.certificates.items[0].dns_provider);
    try t.expectEqualStrings("b.env", result.certificates.items[1].dns_env_file.?);
    try t.expectEqual(@as(u32, 456), result.certificates.items[1].check_interval_seconds);
    try t.expectError(error.ConfigFailed, p.parse(prefix ++ first ++ "dns_provider='route53'\n"));
    try t.expectError(error.ConfigFailed, p.parse(prefix ++ first ++ first));
    try t.expectError(error.ConfigFailed, p.parse(prefix ++ "[acme]\ndomain='example.com'\n" ++ second));
}
