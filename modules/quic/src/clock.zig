//! Monotonic clock without std.Io: the transport core takes time as an
//! argument; this helper is for callers, tests and benchmarks.
const builtin = @import("builtin");

const Timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
const monotonic: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;

pub fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(monotonic, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn nowUs() u64 {
    return nowNs() / 1000;
}
