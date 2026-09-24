//! Browser calls for the web build: fetching a file over HTTP and writing
//! to the console. They compile to nothing elsewhere.

const builtin = @import("builtin");

const on_web = builtin.os.tag == .emscripten;

/// The bytes are freed when this returns; copy anything kept.
pub const OnLoad = *const fn (bytes: []const u8) void;

/// One request at a time, single threaded.
var pending: ?OnLoad = null;

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

pub fn consoleError(text: [*:0]const u8) void {
    if (on_web) emscripten_console_error(text);
}

extern fn emscripten_console_error(text: [*:0]const u8) void;
extern fn emscripten_async_wget_data(
    url: [*:0]const u8,
    arg: ?*anyopaque,
    onload: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    onerror: *const fn (?*anyopaque) callconv(.c) void,
) void;
