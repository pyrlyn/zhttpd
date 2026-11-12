const std = @import("std");
const sdk = @import("http_sdk");
extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
fn stop(_: c_int) callconv(.c) void {
    sdk.stop();
}
var writes: u32 = 0;
var middleware_calls: u32 = 0;
fn trace(ctx: *sdk.Context, next: *sdk.application.Next) !void {
    middleware_calls += 1;
    try ctx.addHeader("X-Middleware-Calls", try std.fmt.allocPrint(ctx.allocator, "{d}", .{middleware_calls}));
    try ctx.addHeader("X-Middleware", "before");
    try next.run(ctx);
    try ctx.addHeader("X-Middleware-After", "after");
}
fn echo(ctx: *sdk.Context) !void {
    const value = try ctx.json();
    try ctx.sendJson(200, value);
}
fn form(ctx: *sdk.Context) !void {
    try ctx.sendJson(200, try ctx.form());
}
fn query(ctx: *sdk.Context) !void {
    try ctx.sendJson(200, try ctx.query());
}
fn read(ctx: *sdk.Context) !void {
    try ctx.sendJson(200, .{ .writes = writes });
}
fn write(ctx: *sdk.Context) !void {
    writes += 1;
    try ctx.sendJson(201, .{ .writes = writes, .body = ctx.body });
}
fn cookies(ctx: *sdk.Context) !void {
    try ctx.setCookie("session", "example", .{});
    try ctx.deleteCookie("old", .{});
    try ctx.sendJson(200, .{ .cookie = ctx.getCookie("sid") });
}
fn fail(_: *sdk.Context) !void {
    return error.ExampleInternalFailure;
}
pub fn main(init: std.process.Init) !void {
    _ = signal(2, @ptrCast(&stop));
    _ = signal(15, @ptrCast(&stop));
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try sdk.serve(if (args.len > 1) args[1] else "127.0.0.1:8080", &.{
        .{ .path = "/json", .methods = &.{ "POST", "PUT", "PATCH", "DELETE" }, .application = .{ .handler = echo, .middleware = &.{trace} } },
        .{ .path = "/form", .methods = &.{"POST"}, .application = .{ .handler = form } },
        .{ .path = "/query", .application = .{ .handler = query } },
        .{ .path = "/items", .application = .{ .handler = read } },
        .{ .path = "/items", .methods = &.{ "POST", "PUT", "DELETE" }, .application = .{ .handler = write, .middleware = &.{trace} }, .idempotency = true },
        .{ .path = "/cookies", .application = .{ .handler = cookies } },
        .{ .path = "/fail", .application = .{ .handler = fail } },
    }, .{ .gzip = true });
}
