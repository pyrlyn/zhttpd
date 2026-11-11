//! Private staging for lego, encrypted PKCS#8 generations and atomic publication.
//! The master owns cleanup and publishes only after the ACME child exits.
const std = @import("std");
const c = std.c;
const os = @import("../os.zig");
const acme = @import("acme");
const tls = @import("tls.zig");
const PasswordFile = @import("password_file.zig").PasswordFile;
const BIO = opaque {};
const BIO_METHOD = opaque {};
const EVP_PKEY = opaque {};
const EVP_CIPHER = opaque {};
const PKCS8_PRIV_KEY_INFO = opaque {};
const X509_SIG = opaque {};
const SSL_CTX = opaque {};
extern "c" fn TLS_server_method() *const anyopaque;
extern "c" fn SSL_CTX_new(*const anyopaque) ?*SSL_CTX;
extern "c" fn SSL_CTX_free(*SSL_CTX) void;
extern "c" fn SSL_CTX_use_certificate_chain_file(*SSL_CTX, [*:0]const u8) c_int;
extern "c" fn SSL_CTX_use_PrivateKey(*SSL_CTX, *EVP_PKEY) c_int;
extern "c" fn SSL_CTX_check_private_key(*SSL_CTX) c_int;
const Callback = *const fn ([*]u8, c_int, c_int, ?*anyopaque) callconv(.c) c_int;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn flock(c_int, c_int) c_int;
extern "c" fn BIO_new_mem_buf(*const anyopaque, c_int) ?*BIO;
extern "c" fn BIO_s_mem() *const BIO_METHOD;
extern "c" fn BIO_new(*const BIO_METHOD) ?*BIO;
extern "c" fn BIO_free(*BIO) c_int;
extern "c" fn BIO_ctrl(*BIO, c_int, c_long, ?*anyopaque) c_long;
extern "c" fn PEM_read_bio_PrivateKey(*BIO, ?*?*EVP_PKEY, Callback, ?*anyopaque) ?*EVP_PKEY;
extern "c" fn PEM_write_bio_PrivateKey(*BIO, *EVP_PKEY, ?*const EVP_CIPHER, ?[*]const u8, c_int, Callback, ?*anyopaque) c_int;
extern "c" fn EVP_PKEY_free(*EVP_PKEY) void;
extern "c" fn EVP_PKEY_eq(*const EVP_PKEY, *const EVP_PKEY) c_int;
extern "c" fn EVP_PKEY2PKCS8(*const EVP_PKEY) ?*PKCS8_PRIV_KEY_INFO;
extern "c" fn PKCS8_PRIV_KEY_INFO_free(*PKCS8_PRIV_KEY_INFO) void;
extern "c" fn EVP_aes_256_cbc() *const EVP_CIPHER;
extern "c" fn PKCS8_encrypt(c_int, *const EVP_CIPHER, [*]const u8, c_int, [*]u8, c_int, c_int, *PKCS8_PRIV_KEY_INFO) ?*X509_SIG;
extern "c" fn PEM_write_bio_PKCS8(*BIO, *const X509_SIG) c_int;
extern "c" fn X509_SIG_free(*X509_SIG) void;
extern "c" fn RAND_bytes([*]u8, c_int) c_int;
extern "c" fn ERR_clear_error() void;

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    settings: acme.Settings,
    root: []const u8,
    stage: []const u8,
    lock_fd: c_int,
    password_digest: [32]u8,
    pid: c.pid_t = 0,

    pub fn deinit(j: *Job) void {
        removeTree(j.arena.allocator(), j.stage);
        _ = c.close(j.lock_fd);
        j.arena.deinit();
    }

    pub fn publish(j: *Job) !void {
        if (!tls.enabled) return error.TlsRequired;
        const a = j.arena.allocator();
        var passwords: PasswordFile = .{};
        defer passwords.deinit();
        try passwords.read(a, j.settings.password_file.?);
        if (!std.mem.eql(u8, &j.password_digest, &passwords.digest())) return error.EncryptionPasswordChanged;
        const prefix = try std.fmt.allocPrint(a, "{s}/certificates/{s}", .{ j.stage, j.settings.cert_name });
        const cert = try read(a, try std.fmt.allocPrint(a, "{s}.crt", .{prefix}));
        const raw = try read(a, try std.fmt.allocPrint(a, "{s}.key", .{prefix}));
        defer std.crypto.secureZero(u8, raw);
        const key = loadKey(raw, null) orelse loadAnyKey(raw, &passwords) orelse return error.InvalidIssuedKey;
        defer EVP_PKEY_free(key);
        const context = SSL_CTX_new(TLS_server_method()) orelse return error.OutOfMemory;
        defer SSL_CTX_free(context);
        if (SSL_CTX_use_certificate_chain_file(context, try std.fmt.allocPrintSentinel(a, "{s}.crt", .{prefix}, 0)) != 1) return error.InvalidIssuedCertificate;
        if (SSL_CTX_use_PrivateKey(context, key) != 1 or SSL_CTX_check_private_key(context) != 1) return error.IssuedKeyMismatch;

        // Reuse ciphertext on a no-op renewal. Changing the first password
        // deliberately re-encrypts the same key without forcing CA issuance.
        var reusable: ?[]const u8 = null;
        if (read(a, j.settings.key)) |old_raw| {
            defer std.crypto.secureZero(u8, old_raw);
            if (std.mem.startsWith(u8, old_raw, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) {
                if (loadKey(old_raw, passwords.lines[0])) |old_key| {
                    defer EVP_PKEY_free(old_key);
                    if (EVP_PKEY_eq(key, old_key) == 1) reusable = try a.dupe(u8, old_raw);
                }
            }
        } else |_| {}
        if (reusable != null) {
            if (read(a, j.settings.certificate)) |old_cert| {
                if (std.mem.eql(u8, old_cert, cert)) return;
            } else |_| {}
        }
        const generation = try temporary(a, j.root, "gen");
        errdefer removeTree(a, generation);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ generation, j.settings.cert_name });
        try write(a, try std.fmt.allocPrint(a, "{s}.crt", .{dest}), cert);
        const key_path = try std.fmt.allocPrint(a, "{s}.key", .{dest});
        if (reusable) |bytes| try write(a, key_path, bytes) else {
            const info = EVP_PKEY2PKCS8(key) orelse return error.EncodeKey;
            defer PKCS8_PRIV_KEY_INFO_free(info);
            var salt: [16]u8 = undefined;
            if (RAND_bytes(&salt, salt.len) != 1) return error.Random;
            const password = passwords.lines[0];
            const encrypted = PKCS8_encrypt(-1, EVP_aes_256_cbc(), password.ptr, @intCast(password.len), &salt, salt.len, 200_000, info) orelse return error.EncryptKey;
            defer X509_SIG_free(encrypted);
            const output = BIO_new(BIO_s_mem()) orelse return error.OutOfMemory;
            defer clearBio(output);
            if (PEM_write_bio_PKCS8(output, encrypted) != 1) return error.EncodeKey;
            try writeBio(a, key_path, output);
        }
        for ([_][]const u8{ ".json", ".issuer.crt", ".migration.json" }) |suffix| try copyOptional(a, try std.mem.concat(a, u8, &.{ prefix, suffix }), try std.mem.concat(a, u8, &.{ dest, suffix }));
        try syncDir(a, generation);
        // Re-read after the expensive encryption and all writes: changed/removed
        // password files must never publish a generation encrypted with stale data.
        try passwords.read(a, j.settings.password_file.?);
        if (!std.mem.eql(u8, &j.password_digest, &passwords.digest())) return error.EncryptionPasswordChanged;
        const link = try std.fmt.allocPrintSentinel(a, "{s}.link", .{generation}, 0);
        defer _ = c.unlink(link);
        const target = try a.dupeSentinel(u8, std.fs.path.basename(generation), 0);
        if (c.symlink(target, link) != 0) return error.PublishLink;
        const current = try std.fmt.allocPrintSentinel(a, "{s}/current", .{j.root}, 0);
        if (c.rename(link, current) != 0) return error.PublishGeneration;
        // The rename is the commit point. A subsequent fsync failure must not
        // report a rollback that did not occur; files were synced before commit.
        syncDir(a, j.root) catch {};
    }
};

pub fn start(gpa: std.mem.Allocator, settings: acme.Settings, error_fd: c_int) !Job {
    var job = try prepare(gpa, settings);
    errdefer job.deinit();
    var staged = settings;
    staged.storage = job.stage;
    job.pid = try acme.startGrouped(gpa, staged, error_fd, true);
    return job;
}

/// Rotate encryption locally; the certificate, key material and renewal policy
/// remain unchanged. All supplied passwords may read the old key; only the first
/// encrypts the new generation. Never launches lego or contacts the CA.
pub fn reencrypt(gpa: std.mem.Allocator, settings: acme.Settings) !bool {
    if (!tls.enabled) return error.TlsRequired;
    if (!settings.encrypt_key or !acme.ready(settings)) return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var passwords: PasswordFile = .{};
    defer passwords.deinit();
    try passwords.read(a, settings.password_file.?);
    const raw = try read(a, settings.key);
    defer std.crypto.secureZero(u8, raw);
    if (std.mem.startsWith(u8, raw, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) {
        if (loadKey(raw, passwords.lines[0])) |key| {
            EVP_PKEY_free(key);
            return false;
        }
    }
    // prepare holds the publication lock, reads the current pair again and
    // captures the password digest. publish rechecks it before committing.
    var job = try prepare(gpa, settings);
    defer job.deinit();
    try job.publish();
    return true;
}

fn prepare(gpa: std.mem.Allocator, settings: acme.Settings) !Job {
    if (!tls.enabled) return error.TlsRequired;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var passwords: PasswordFile = .{};
    defer passwords.deinit();
    try passwords.read(a, settings.password_file orelse return error.MissingEncryptionPassword);
    const root = try std.fmt.allocPrint(a, "{s}/encrypted/{s}", .{ settings.storage, settings.cert_name });
    try mkdir(a, root);
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/lock", .{root}, 0);
    // Intentionally inherited by lego: a crashed master must not allow another
    // instance to remove staging files while its orphaned child still writes.
    const fd = c.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.EncryptionLock;
    errdefer _ = c.close(fd);
    if (flock(fd, 2 | 4) != 0) return error.EncryptionBusy;
    try clearStale(a, root);
    const stage = try temporary(a, root, "work");
    errdefer removeTree(a, stage);
    try mkdir(a, try std.fmt.allocPrint(a, "{s}/certificates", .{stage}));
    const accounts = try std.fmt.allocPrintSentinel(a, "{s}/accounts", .{settings.storage}, 0);
    try mkdir(a, accounts);
    const account_link = try std.fmt.allocPrintSentinel(a, "{s}/accounts", .{stage}, 0);
    if (c.symlink(accounts, account_link) != 0) return error.AccountLink;
    if (acme.ready(settings)) {
        const prefix = try std.fmt.allocPrint(a, "{s}/certificates/{s}", .{ stage, settings.cert_name });
        try write(a, try std.fmt.allocPrint(a, "{s}.crt", .{prefix}), try read(a, settings.certificate));
        const raw = try read(a, settings.key);
        defer std.crypto.secureZero(u8, raw);
        const key = loadAnyKey(raw, &passwords) orelse return error.CannotDecryptCurrentKey;
        defer EVP_PKEY_free(key);
        const output = BIO_new(BIO_s_mem()) orelse return error.OutOfMemory;
        defer clearBio(output);
        if (PEM_write_bio_PrivateKey(output, key, null, null, 0, tls.noPassword, null) != 1) return error.EncodeKey;
        try writeBio(a, try std.fmt.allocPrint(a, "{s}.key", .{prefix}), output);
        const current_dir = std.fs.path.dirname(settings.certificate).?;
        for ([_][]const u8{ ".json", ".issuer.crt", ".migration.json" }) |suffix| try copyOptional(a, try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ current_dir, settings.cert_name, suffix }), try std.mem.concat(a, u8, &.{ prefix, suffix }));
    }
    return .{ .arena = arena, .settings = settings, .root = root, .stage = stage, .lock_fd = fd, .password_digest = passwords.digest() };
}

fn loadKey(bytes: []const u8, pass: ?[]const u8) ?*EVP_PKEY {
    ERR_clear_error();
    defer ERR_clear_error();
    const bio = BIO_new_mem_buf(bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer _ = BIO_free(bio);
    var password = pass orelse &.{};
    return PEM_read_bio_PrivateKey(bio, null, if (pass != null) tls.filePassword else tls.noPassword, if (pass != null) @ptrCast(&password) else null);
}
fn loadAnyKey(bytes: []const u8, passwords: *const PasswordFile) ?*EVP_PKEY {
    for (passwords.lines[0..passwords.count]) |password| if (loadKey(bytes, password)) |key| return key;
    return null;
}
fn clearBio(bio: *BIO) void {
    var data: ?[*]u8 = null;
    const size = BIO_ctrl(bio, 3, 0, @ptrCast(&data));
    if (size > 0) std.crypto.secureZero(u8, data.?[0..@intCast(size)]);
    _ = BIO_free(bio);
}
fn writeBio(a: std.mem.Allocator, path: []const u8, bio: *BIO) !void {
    var data: ?[*]u8 = null;
    const size = BIO_ctrl(bio, 3, 0, @ptrCast(&data));
    if (size <= 0) return error.EmptyPem;
    try write(a, path, data.?[0..@intCast(size)]);
}
fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return readTracked(a, path, false, null);
}
fn readTracked(a: std.mem.Allocator, path: []const u8, no_follow: bool, metadata: ?*os.Meta) ![]u8 {
    return readTrackedAt(a, c.AT.FDCWD, path, no_follow, metadata);
}
fn readTrackedAt(a: std.mem.Allocator, dir: c_int, path: []const u8, no_follow: bool, metadata: ?*os.Meta) ![]u8 {
    const fd = c.openat(dir, try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOFOLLOW = no_follow });
    if (fd < 0) return if (os.errnoNow() == .NOENT) error.FileNotFound else error.OpenFile;
    defer _ = c.close(fd);
    const meta = os.fstat(fd) orelse return error.StatFile;
    if (meta.kind != .file or meta.size > 2 * 1024 * 1024) return error.InvalidFile;
    if (metadata) |out| out.* = meta;
    const bytes = try a.alloc(u8, @intCast(meta.size));
    errdefer std.crypto.secureZero(u8, bytes);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0 and os.errnoNow() == .INTR) continue;
        if (n <= 0) return error.ReadFile;
        used += @intCast(n);
    }
    return bytes;
}
fn write(a: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    return writeAt(a, c.AT.FDCWD, path, bytes);
}
fn writeAt(a: std.mem.Allocator, dir: c_int, path: []const u8, bytes: []const u8) !void {
    const fd = c.openat(dir, try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFile;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and os.errnoNow() == .INTR) continue;
        if (n <= 0) return error.WriteFile;
        offset += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.SyncFile;
}
fn copyOptional(a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const bytes = read(a, from) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    try write(a, to, bytes);
}
fn mkdir(a: std.mem.Allocator, path: []const u8) !void {
    if (os.stat(path)) |meta| {
        if (meta.kind != .dir) return error.NotDirectory;
        return;
    }
    if (std.fs.path.dirname(path)) |parent| try mkdir(a, parent);
    if (c.mkdir(try a.dupeSentinel(u8, path, 0), 0o700) != 0 and os.errnoNow() != .EXIST) return error.CreateDirectory;
}
fn temporary(a: std.mem.Allocator, root: []const u8, prefix: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}-XXXXXX", .{ root, prefix }, 0);
    if (mkdtemp(path) == null) return error.CreateDirectory;
    return path;
}
fn syncDir(a: std.mem.Allocator, path: []const u8) !void {
    const fd = c.open(try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return error.OpenDirectory;
    defer _ = c.close(fd);
    if (c.fsync(fd) != 0) return error.SyncDirectory;
}
fn removeTree(a: std.mem.Allocator, path: []const u8) void {
    const z = a.dupeSentinel(u8, path, 0) catch return;
    if (c.unlink(z) == 0 or os.errnoNow() == .NOENT) return; // Includes symlinks: never traverse them.
    const names = os.listDir(a, path) catch return;
    for (names) |name| removeTree(a, std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch continue);
    _ = c.rmdir(z);
}
fn clearStale(a: std.mem.Allocator, root: []const u8) !void {
    const names = try os.listDir(a, root);
    for (names) |name| {
        // Published generations may still be required by the active config or
        // rollback. Retire them only after a successful activation.
        if (std.mem.startsWith(u8, name, "work-")) removeTree(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name }));
    }
}

const Identity = struct { inode: u64, size: u64, hash: [32]u8 };
const Manifest = struct { version: u8 = 1, files: [acme.cache_suffixes.len]?Identity = @splat(null) };
const Captured = struct { bytes: []u8, identity: Identity };
fn capture(a: std.mem.Allocator, path: []const u8) !?Captured {
    var meta: os.Meta = undefined;
    const bytes = readTracked(a, path, true, &meta) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = bytes, .identity = .{ .inode = meta.ino, .size = meta.size, .hash = digest } };
}
fn equalIdentity(left: Identity, right: Identity) bool {
    return left.inode == right.inode and left.size == right.size and std.mem.eql(u8, &left.hash, &right.hash);
}

pub const Snapshot = struct { target: [10]u8, certificate: [32]u8, key: [32]u8, password: [32]u8 };
fn generationName(name: []const u8) bool {
    if (name.len != 10 or !std.mem.startsWith(u8, name, "gen-")) return false;
    for (name[4..]) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}
fn openDirAt(a: std.mem.Allocator, dir: c_int, path: []const u8) !c_int {
    const fd = c.openat(dir, try a.dupeSentinel(u8, path, 0), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.OpenGenerationDirectory;
    return fd;
}
fn currentTarget(root: c_int) ![10]u8 {
    var buffer: [11]u8 = undefined;
    const n = c.readlinkat(root, "current", &buffer, buffer.len);
    if (n != 10 or !generationName(buffer[0..10])) return error.InvalidCurrentGeneration;
    return buffer[0..10].*;
}
pub fn snapshot(gpa: std.mem.Allocator, settings: acme.Settings) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try openDirAt(a, c.AT.FDCWD, try std.fmt.allocPrint(a, "{s}/encrypted/{s}", .{ settings.storage, settings.cert_name }));
    defer _ = c.close(root);
    return snapshotAt(a, root, settings);
}
fn snapshotAt(a: std.mem.Allocator, root: c_int, settings: acme.Settings) !Snapshot {
    const target = try currentTarget(root);
    const dir = try openDirAt(a, root, &target);
    defer _ = c.close(dir);
    var passwords: PasswordFile = .{};
    defer passwords.deinit();
    try passwords.read(a, settings.password_file.?);
    var result: Snapshot = .{ .target = target, .certificate = undefined, .key = undefined, .password = passwords.digest() };
    for ([_][]const u8{ ".crt", ".key" }, [_]*[32]u8{ &result.certificate, &result.key }) |suffix, hash| {
        const bytes = try readTrackedAt(a, dir, try std.mem.concat(a, u8, &.{ settings.cert_name, suffix }), true, null);
        defer std.crypto.secureZero(u8, bytes);
        std.crypto.hash.sha2.Sha256.hash(bytes, hash, .{});
    }
    if (!std.mem.eql(u8, &target, &(try currentTarget(root)))) return error.CurrentGenerationChanged;
    return result;
}
pub fn sameSnapshot(left: Snapshot, right: Snapshot) bool {
    return std.mem.eql(u8, &left.target, &right.target) and std.mem.eql(u8, &left.certificate, &right.certificate) and
        std.mem.eql(u8, &left.key, &right.key) and std.mem.eql(u8, &left.password, &right.password);
}
const generation_suffixes = [_][]const u8{ ".crt", ".key", ".json", ".issuer.crt", ".migration.json" };
const Retirement = struct { version: u8 = 1, inode: u64, files: [generation_suffixes.len]?Identity = @splat(null) };
const retirement_marker = "retirement.json";
const retired_prefix = ".retired-";
fn listAt(a: std.mem.Allocator, fd: c_int) ![][]u8 {
    const copy = try openDirAt(a, fd, ".");
    const dir = c.fdopendir(copy) orelse {
        _ = c.close(copy);
        return error.OpenGenerationDirectory;
    };
    defer _ = c.closedir(dir);
    var names: std.ArrayList([]u8) = .empty;
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (os.errnoInt() != 0) return error.ReadGenerationDirectory;
            break;
        };
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try names.append(a, try a.dupe(u8, name));
    }
    return names.toOwnedSlice(a);
}
fn captureAt(a: std.mem.Allocator, dir: c_int, path: []const u8) !?Captured {
    var meta: os.Meta = undefined;
    const bytes = readTrackedAt(a, dir, path, true, &meta) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return .{ .bytes = bytes, .identity = .{ .inode = meta.ino, .size = meta.size, .hash = hash } };
}
fn generationInUse(cfg: *const @import("../http/config.zig").Config, expected: Identity) bool {
    for (cfg.servers) |server| for ([_]?[]const u8{ server.tls.certificate, server.tls.certificate_key }) |maybe| {
        if (maybe) |path| if (os.stat(path)) |meta| {
            if (meta.ino == expected.inode and meta.size == expected.size) return true;
        };
    };
    return false;
}

/// Only the exact encrypted pair loaded by the activated workers authorizes GC.
/// Each retired directory is its own durable journal, so one SNI record cannot
/// lose another record's recovery state. Never recursively follows a pathname.
pub const CleanupResult = struct { removed: usize = 0, deferred: ?anyerror = null };
/// One retry schedule per activated SNI record. Successful records stop polling;
/// persistent failures back off without repeatedly logging the same error.
pub const CleanupRetry = struct {
    next_attempt_ms: ?i64 = 0,
    delay_ms: i64 = 1000,
    last_error: ?anyerror = null,

    pub fn due(s: *const CleanupRetry, now: i64) bool {
        return if (s.next_attempt_ms) |deadline| now >= deadline else false;
    }
    pub fn record(s: *CleanupRetry, result: CleanupResult, now: i64) bool {
        const changed = s.last_error != result.deferred;
        s.last_error = result.deferred;
        if (result.deferred != null) {
            s.next_attempt_ms = now + s.delay_ms;
            s.delay_ms = @min(s.delay_ms * 2, 30_000);
        } else {
            s.next_attempt_ms = null;
            s.delay_ms = 1000;
        }
        return changed;
    }
};

test "cleanup retry deadlines are independent, bounded and stop on success" {
    const t = std.testing;
    var first: CleanupRetry = .{};
    var second: CleanupRetry = .{};
    try t.expect(first.due(0));
    try t.expect(first.record(.{ .deferred = error.EncryptionBusy }, 100));
    try t.expect(!first.due(1099));
    try t.expect(first.due(1100));
    try t.expect(!first.record(.{ .deferred = error.EncryptionBusy }, 1100));
    try t.expectEqual(@as(?i64, 3100), first.next_attempt_ms);
    try t.expect(!second.record(.{}, 1100));
    try t.expect(!second.due(100_000));
    for (0..10) |_| _ = first.record(.{ .deferred = error.EncryptionBusy }, 2000);
    try t.expectEqual(@as(?i64, 32_000), first.next_attempt_ms);
    try t.expect(first.record(.{ .deferred = error.RetiredGenerationChanged }, 32_000));
    try t.expect(first.record(.{ .removed = 1 }, 62_000));
    try t.expect(!first.due(1_000_000));
}
pub fn cleanupGenerations(gpa: std.mem.Allocator, settings: acme.Settings, cfg: *const @import("../http/config.zig").Config, active: Snapshot, protected_inodes: []const u64) !CleanupResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root_path = try std.fmt.allocPrint(a, "{s}/encrypted/{s}", .{ settings.storage, settings.cert_name });
    const root = try openDirAt(a, c.AT.FDCWD, root_path);
    defer _ = c.close(root);
    const lock = c.openat(root, "lock", .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true });
    if (lock < 0) return error.EncryptionLock;
    defer _ = c.close(lock);
    if (flock(lock, 2 | 4) != 0) return error.EncryptionBusy;
    if (!sameSnapshot(active, try snapshotAt(a, root, settings))) return error.CurrentGenerationChanged;
    if (c.fsync(root) != 0) return error.SyncDirectory;
    try syncDir(a, std.fs.path.dirname(root_path).?);
    var result: CleanupResult = .{};
    for (try listAt(a, root)) |name| {
        const retired = std.mem.startsWith(u8, name, retired_prefix);
        const original = if (retired) name[retired_prefix.len..] else name;
        if (!generationName(original) or std.mem.eql(u8, original, &active.target)) continue;
        retireGeneration(a, root, name, retired, settings, cfg, protected_inodes) catch |err| {
            result.deferred = err;
            continue;
        };
        result.removed += 1;
    }
    return result;
}
fn retireGeneration(a: std.mem.Allocator, root: c_int, name: []const u8, retired: bool, settings: acme.Settings, cfg: *const @import("../http/config.zig").Config, protected_inodes: []const u64) !void {
    const dir = try openDirAt(a, root, name);
    defer _ = c.close(dir);
    const inode = (os.fstat(dir) orelse return error.StatFile).ino;
    const entries = try listAt(a, dir);
    if (retired and entries.len == 0) {
        if (c.unlinkat(root, try a.dupeSentinel(u8, name, 0), c.AT.REMOVEDIR) != 0 or c.fsync(root) != 0) return error.RemoveGeneration;
        return;
    }
    var journal: Retirement = .{ .inode = inode };
    var has_journal = false;
    if (try captureAt(a, dir, retirement_marker)) |file| {
        journal = (try std.json.parseFromSlice(Retirement, a, file.bytes, .{})).value;
        if (journal.version != 1 or journal.inode != inode or journal.files[0] == null or journal.files[1] == null) return error.InvalidRetirementJournal;
        has_journal = true;
    } else if (retired) return error.MissingRetirementJournal;
    var files: [generation_suffixes.len][:0]const u8 = undefined;
    var held: [generation_suffixes.len][:0]const u8 = undefined;
    for (generation_suffixes, 0..) |suffix, i| {
        files[i] = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ settings.cert_name, suffix }, 0);
        held[i] = try std.fmt.allocPrintSentinel(a, ".unlink-{d}", .{i}, 0);
    }
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, retirement_marker) or std.mem.eql(u8, entry, ".retirement.tmp")) continue;
        var known = false;
        for (files, held) |file, hold| if (std.mem.eql(u8, entry, file) or (has_journal and std.mem.eql(u8, entry, hold))) {
            known = true;
        };
        if (!known) return error.UnrecognizedGenerationFile;
    }
    // Enrol pre-existing generations only if they have the known encrypted
    // layout. Once journalled, changed/replaced files are retained, not adopted.
    for (files, held, 0..) |file, hold, i| {
        for ([_][]const u8{ file, hold }, 0..) |path, k| {
            if (k == 1 and !has_journal) continue;
            if (try captureAt(a, dir, path)) |captured| {
                defer std.crypto.secureZero(u8, captured.bytes);
                if (!has_journal) {
                    if (i == 1 and !std.mem.startsWith(u8, captured.bytes, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) return error.ExpectedEncryptedKey;
                    journal.files[i] = captured.identity;
                } else if (journal.files[i] == null or !equalIdentity(captured.identity, journal.files[i].?)) return error.RetiredGenerationChanged;
                if (generationInUse(cfg, captured.identity)) return error.RetiredGenerationInUse;
                // Retries run without rebuilding TLS contexts. Keep the files
                // actually loaded at activation even if an alias was retargeted
                // since then and its replacement config failed validation.
                for (protected_inodes) |used| if (used == captured.identity.inode) return error.RetiredGenerationInUse;
            } else if (!has_journal and i < 2) return error.IncompleteGeneration;
        }
    }
    if (!has_journal) {
        if (c.unlinkat(dir, ".retirement.tmp", 0) != 0 and os.errnoNow() != .NOENT) return error.WriteRetirementJournal;
        try writeAt(a, dir, ".retirement.tmp", try std.json.Stringify.valueAlloc(a, journal, .{}));
        if (c.renameat(dir, ".retirement.tmp", dir, retirement_marker) != 0 or c.fsync(dir) != 0) return error.WriteRetirementJournal;
    }
    const destination = try a.dupeSentinel(u8, if (retired) name else try std.mem.concat(a, u8, &.{ retired_prefix, name }), 0);
    if (!retired) {
        // Never replace another journal. Operations on file contents use the
        // opened directory descriptor even if a pathname is replaced externally.
        if (c.faccessat(root, destination, c.F_OK, c.AT.SYMLINK_NOFOLLOW) == 0 or os.errnoNow() != .NOENT) return error.RetirementExists;
        if (c.renameat(root, try a.dupeSentinel(u8, name, 0), root, destination) != 0) return error.RetireGeneration;
    }
    const renamed = try openDirAt(a, root, destination);
    defer _ = c.close(renamed);
    if ((os.fstat(renamed) orelse return error.StatFile).ino != inode) return error.RetiredGenerationChanged;
    if (c.fsync(root) != 0) return error.SyncDirectory;
    // Preflight above covered the entire set. A rename-before-unlink and another
    // identity check protect replacements made after that preflight.
    for (files, held, journal.files) |file, hold, expected| if (expected) |identity| {
        if (try captureAt(a, dir, hold)) |captured| {
            defer std.crypto.secureZero(u8, captured.bytes);
            if (!equalIdentity(captured.identity, identity)) return error.RetiredGenerationChanged;
            if (c.unlinkat(dir, hold, 0) != 0) return error.RemoveGenerationFile;
        }
        if (try captureAt(a, dir, file)) |captured| {
            defer std.crypto.secureZero(u8, captured.bytes);
            if (!equalIdentity(captured.identity, identity)) return error.RetiredGenerationChanged;
            if (c.renameat(dir, file, dir, hold) != 0) return error.RetireGenerationFile;
            const moved = captureAt(a, dir, hold) catch |err| {
                restoreAt(dir, hold, file);
                return err;
            } orelse return error.RetiredGenerationChanged;
            defer std.crypto.secureZero(u8, moved.bytes);
            if (!equalIdentity(moved.identity, identity)) {
                restoreAt(dir, hold, file);
                return error.RetiredGenerationChanged;
            }
            if (c.unlinkat(dir, hold, 0) != 0) return error.RemoveGenerationFile;
        }
    };
    if (c.fsync(dir) != 0) return error.SyncDirectory;
    if (c.unlinkat(dir, retirement_marker, 0) != 0 or c.fsync(dir) != 0) return error.RemoveRetirementJournal;
    if (c.unlinkat(root, destination, c.AT.REMOVEDIR) != 0 or c.fsync(root) != 0) return error.RemoveGeneration;
}
fn restoreAt(dir: c_int, from: [:0]const u8, to: [:0]const u8) void {
    if (c.linkat(dir, from, dir, to, 0) == 0) _ = c.unlinkat(dir, from, 0);
}

/// Copy and encrypt an existing legacy pair locally. Never executes lego, even
/// if the legacy cache is incomplete or invalid. Source files remain untouched.
pub fn migrate(gpa: std.mem.Allocator, settings: acme.Settings) !bool {
    if (!tls.enabled) return error.TlsRequired;
    if (!settings.encrypt_key or acme.ready(settings)) return false;
    var job = try prepare(gpa, settings);
    defer job.deinit();
    // Another master may have published between the initial check and locking.
    if (acme.ready(settings)) return false;
    const a = job.arena.allocator();
    var manifest: Manifest = .{};
    var captured: [acme.cache_suffixes.len]?Captured = @splat(null);
    defer for (captured) |item| if (item) |file| std.crypto.secureZero(u8, file.bytes);
    var any = false;
    for (acme.cache_suffixes, 0..) |suffix, i| {
        captured[i] = try capture(a, try acme.legacyPath(a, settings, suffix));
        if (captured[i]) |file| {
            manifest.files[i] = file.identity;
            any = true;
        }
    }
    if (!any) return false;
    if (captured[0] == null or captured[1] == null) return error.IncompleteLegacyCache;
    const prefix = try std.fmt.allocPrint(a, "{s}/certificates/{s}", .{ job.stage, settings.cert_name });
    for (acme.cache_suffixes[0..4], 0..) |suffix, i| if (captured[i]) |file| {
        try write(a, try std.mem.concat(a, u8, &.{ prefix, suffix }), file.bytes);
    };
    const marker = try std.json.Stringify.valueAlloc(a, manifest, .{});
    try write(a, try std.fmt.allocPrint(a, "{s}.migration.json", .{prefix}), marker);
    // The snapshot must still describe the source after all copies are made.
    for (acme.cache_suffixes, 0..) |suffix, i| {
        const current = try capture(a, try acme.legacyPath(a, settings, suffix));
        defer if (current) |file| std.crypto.secureZero(u8, file.bytes);
        if (current) |file| {
            if (manifest.files[i] == null or !equalIdentity(file.identity, manifest.files[i].?)) return error.LegacyCacheChanged;
        } else if (manifest.files[i] != null) return error.LegacyCacheChanged;
    }
    try job.publish();
    return true;
}

/// Called only after a generation using the encrypted paths has been activated.
/// A manifest is durable across retries/crashes and never contains private data.
pub fn cleanupLegacy(gpa: std.mem.Allocator, settings: acme.Settings, cfg: *const @import("../http/config.zig").Config) !void {
    if (!tls.enabled) return error.TlsRequired;
    if (!acme.migrationPending(gpa, settings)) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, "{s}/encrypted/{s}", .{ settings.storage, settings.cert_name });
    const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/lock", .{root}, 0);
    const fd = c.open(lock_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return error.EncryptionLock;
    defer _ = c.close(fd);
    if (flock(fd, 2 | 4) != 0) return error.EncryptionBusy;
    const marker = try acme.migrationPath(a, settings);
    const raw = try readTracked(a, marker, true, null);
    const decoded = try std.json.parseFromSlice(Manifest, a, raw, .{});
    const manifest = decoded.value;
    if (manifest.version != 1 or manifest.files[0] == null or manifest.files[1] == null) return error.InvalidMigrationManifest;
    // Require the exact migrated certificate and its encrypted private key to
    // remain readable before deleting the last legacy representation.
    const cert = try read(a, settings.certificate);
    var cert_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cert, &cert_hash, .{});
    if (!std.mem.eql(u8, &cert_hash, &manifest.files[0].?.hash)) return error.MigratedCertificateChanged;
    const encrypted = try read(a, settings.key);
    defer std.crypto.secureZero(u8, encrypted);
    if (!std.mem.startsWith(u8, encrypted, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) return error.ExpectedEncryptedKey;
    var passwords: PasswordFile = .{};
    defer passwords.deinit();
    try passwords.read(a, settings.password_file.?);
    const key = loadAnyKey(encrypted, &passwords) orelse return error.CannotDecryptCurrentKey;
    defer EVP_PKEY_free(key);
    const context = SSL_CTX_new(TLS_server_method()) orelse return error.OutOfMemory;
    defer SSL_CTX_free(context);
    if (SSL_CTX_use_certificate_chain_file(context, try a.dupeSentinel(u8, settings.certificate, 0)) != 1 or
        SSL_CTX_use_PrivateKey(context, key) != 1 or SSL_CTX_check_private_key(context) != 1) return error.IssuedKeyMismatch;
    // Publication cannot roll back after rename; defer destructive cleanup if
    // its directory entry could not be made durable at that commit point.
    try syncDir(a, root);
    try syncDir(a, std.fs.path.dirname(root).?);
    // Do not remove a cache still referenced by any active manual TLS host,
    // including symlink/hardlink aliases. Old workers already own loaded keys.
    for (acme.cache_suffixes[0..2]) |suffix| {
        const legacy = try acme.legacyPath(a, settings, suffix);
        const meta = os.stat(legacy);
        for (cfg.servers) |server| {
            for ([_]?[]const u8{ server.tls.certificate, server.tls.certificate_key }) |maybe| if (maybe) |path| {
                const normalized = try std.fs.path.resolve(a, &.{path});
                if (std.mem.eql(u8, normalized, legacy)) return error.LegacyCacheInUse;
                if (meta) |old| if (os.stat(path)) |used| {
                    if (old.ino == used.ino and old.size == used.size) return error.LegacyCacheInUse;
                };
            };
        }
    }
    const quarantine = try std.fmt.allocPrint(a, "{s}/cleanup", .{root});
    try mkdir(a, quarantine);
    // Preflight the entire set before removing any member. A changed optional
    // export or metadata file must not cause partial cleanup of an intact cache.
    for (acme.cache_suffixes, manifest.files) |suffix, maybe| if (maybe) |expected| {
        const source = try acme.legacyPath(a, settings, suffix);
        const held = try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ quarantine, settings.cert_name, suffix });
        for ([_][]const u8{ source, held }) |path| if (try capture(a, path)) |file| {
            defer std.crypto.secureZero(u8, file.bytes);
            if (!equalIdentity(file.identity, expected)) return error.LegacyCacheChanged;
        };
    };
    for (acme.cache_suffixes, manifest.files) |suffix, maybe| if (maybe) |expected| {
        const source = try acme.legacyPath(a, settings, suffix);
        const held = try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ quarantine, settings.cert_name, suffix });
        // Resume a rename completed before a previous master stopped.
        if (try capture(a, held)) |file| {
            defer std.crypto.secureZero(u8, file.bytes);
            if (!equalIdentity(file.identity, expected)) {
                restore(a, held, source);
                return error.LegacyCacheChanged;
            }
            if (c.unlink(try a.dupeSentinel(u8, held, 0)) != 0) return error.RemoveLegacyCache;
        }
        const current = try capture(a, source) orelse continue;
        defer std.crypto.secureZero(u8, current.bytes);
        if (!equalIdentity(current.identity, expected)) return error.LegacyCacheChanged;
        // Rename before final verification: a replacement at the source path
        // can never be accidentally unlinked after a stale pathname check.
        if (c.rename(try a.dupeSentinel(u8, source, 0), try a.dupeSentinel(u8, held, 0)) != 0) return error.MoveLegacyCache;
        const moved = capture(a, held) catch |err| {
            restore(a, held, source);
            return err;
        } orelse return error.LegacyCacheChanged;
        defer std.crypto.secureZero(u8, moved.bytes);
        if (!equalIdentity(moved.identity, expected)) {
            restore(a, held, source);
            return error.LegacyCacheChanged;
        }
        if (c.unlink(try a.dupeSentinel(u8, held, 0)) != 0) {
            restore(a, held, source);
            return error.RemoveLegacyCache;
        }
    };
    try syncDir(a, try std.fmt.allocPrint(a, "{s}/certificates", .{settings.storage}));
    try syncDir(a, quarantine);
    _ = c.rmdir(try a.dupeSentinel(u8, quarantine, 0));
    if (c.unlink(try a.dupeSentinel(u8, marker, 0)) != 0) return error.RemoveMigrationManifest;
    try syncDir(a, std.fs.path.dirname(marker).?);
}
fn restore(a: std.mem.Allocator, held: []const u8, source: []const u8) void {
    const from = a.dupeSentinel(u8, held, 0) catch return;
    const to = a.dupeSentinel(u8, source, 0) catch return;
    // link() never overwrites a newly created source. If it cannot be restored,
    // the changed file stays in the private cleanup directory for recovery.
    if (c.link(from, to) == 0) _ = c.unlink(from);
}
