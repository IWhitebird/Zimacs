//! Fetching a file over HTTP, for the web build only.
//!
//! A page has no filesystem, so this is the only way the demo can open
//! anything that is not baked into the binary. On every other target the
//! functions here compile away to nothing.

const std = @import("std");
const builtin = @import("builtin");

const on_web = builtin.os.tag == .emscripten;

/// Handed the bytes that arrived. They belong to emscripten and are freed as
/// soon as this returns, so anything kept must be copied.
pub const OnLoad = *const fn (bytes: []const u8) void;

/// Only one request is ever in flight, and the web build is single threaded,
/// so the callback lives here rather than being smuggled through a void
/// pointer and cast back.
var pending: ?OnLoad = null;

/// Starts a request and returns immediately. `url` is resolved against the
/// page, so a bare name means "next to Zimacs.html".
pub fn fetch(url: [*:0]const u8, on_load: OnLoad) void {
    if (!on_web) return;
    pending = on_load;
    emscripten_async_wget_data(url, null, loaded, failed);
}

fn loaded(_: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const on_load = pending orelse return;
    pending = null;
    if (size <= 0) return;
    const bytes: [*]const u8 = @ptrCast(data orelse return);
    on_load(bytes[0..@intCast(size)]);
}

fn failed(_: ?*anyopaque) callconv(.c) void {
    pending = null;
}

extern fn emscripten_async_wget_data(
    url: [*:0]const u8,
    arg: ?*anyopaque,
    onload: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    onerror: *const fn (?*anyopaque) callconv(.c) void,
) void;
