//! Self-contained error pages: no scripts, remote fonts, or asset requests.
const std = @import("std");
const icon = @embedFile("assets/icon.svg");
const css = @embedFile("assets/error.css");
const favicon = blk: {
    @setEvalBranchQuota(10000);
    var encoded: [std.base64.standard.Encoder.calcSize(icon.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, icon);
    break :blk encoded;
};

pub const buffer_size = 8192;

fn description(code: u16) []const u8 {
    return switch (code) {
        400 => "We could not understand this request. Check the address and try again.",
        401 => "You need to sign in before you can access this resource.",
        402 => "Payment is required to access this resource.",
        403 => "This resource is off limits. You may need permission to access it.",
        404 => "The page you are looking for is not here. It may have moved, or the address may be incorrect.",
        405 => "This resource does not support the request method used.",
        406 => "This resource is not available in a format your client accepts.",
        408 => "The request took too long to arrive. Check your connection and try again.",
        409 => "This request conflicts with the current state of the resource. Check your changes before trying again.",
        410 => "This resource has been removed and is no longer available at this address.",
        411 => "This request needs a Content-Length header before it can be processed.",
        412 => "The resource no longer meets the conditions in your request. Fetch the latest version and try again.",
        413 => "This request is larger than the server allows. Reduce its size before trying again.",
        414 => "This address is too long for the server to process. Try a shorter address.",
        415 => "This resource does not support the format of the data you sent.",
        416 => "The requested portion of this resource is not available. Try requesting the whole resource.",
        421 => "This request reached a server that cannot answer for the requested host.",
        429 => "Too many requests arrived in a short time. Take a moment before trying again.",
        500 => "Something went wrong while processing your request. Please try again later.",
        501 => "The server does not support the functionality needed for this request.",
        502 => "The upstream service did not return a valid response. Please try again later.",
        503 => "This service is temporarily unavailable. Please try again in a little while.",
        504 => "The upstream service took too long to respond. Please try again later.",
        505 => "The server does not support the HTTP version used in this request.",
        507 => "The server does not have enough storage to complete this request.",
        else => "The server could not complete this request.",
    };
}

fn heading(code: u16, reason: []const u8) []const u8 {
    return switch (code) {
        403 => "This one's off limits.",
        404 => "A little off the map.",
        429 => "Let's take a breather.",
        500 => "An unexpected detour.",
        502 => "A break in the connection.",
        503 => "Taking a short pause.",
        504 => "The wait was too long.",
        else => reason,
    };
}

fn writeEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(ch),
    };
}

pub fn write(w: *std.Io.Writer, code: u16, reason: []const u8, tokens: []const u8) !void {
    try w.print(
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \\<meta name="color-scheme" content="light"><meta name="robots" content="noindex">
        \\<title>{d} {s} | zhttpd</title>
        \\<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,{s}">
        \\<style>{s}</style></head><body><div class="shell">
        \\<header><a class="brand" href="/" aria-label="zhttpd home">{s}<span>zhttpd</span></a><span class="header-note mono">Small server. Open web.</span></header>
        \\<main><section aria-labelledby="error-title"><div class="eyebrow mono"><span class="dot" aria-hidden="true"></span>HTTP response &middot; {d}</div>
        \\<div class="code" aria-hidden="true">{d}</div><h1 id="error-title">{s}</h1><p class="description">{s}</p>
        \\<div class="actions"><a class="home" href="/">Back to home <span class="arrow" aria-hidden="true">&rarr;</span></a></div></section>
        \\<div aria-hidden="true"><div class="visual"><span class="visual-label mono">The space between requests</span><span class="cross">+</span>
        \\<div class="route"></div><span class="node left"></span><span class="node right"></span><div class="symbol">{s}</div>
        \\<div class="visual-caption mono"><span>Request</span><span>Response</span></div></div>
        \\<div class="status-note mono"><span>{d} / {s}</span><span>zhttpd</span></div></div></main>
        \\<footer><span>Served with care. Even when things go wrong.</span><span>
    , .{ code, reason, favicon, css, icon, code, code, heading(code, reason), description(code), icon, code, reason });
    try writeEscaped(w, tokens);
    try w.writeAll("</span></footer></div></body></html>\n");
}
