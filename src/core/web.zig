//! Browser calls for the web build: fetching a file over HTTP, opening a
//! link, writing to the console and reading the canvas size. They compile
//! to nothing elsewhere.

const std = @import("std");
const builtin = @import("builtin");

pub const on_web = builtin.os.tag == .emscripten;

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

/// `url` must already be percent-encoded, so it holds no quote to escape.
pub fn openUrl(url: []const u8) void {
    if (!on_web) return;
    var buf: [8192]u8 = undefined;
    const script = std.fmt.bufPrintZ(&buf, "window.open(\"{s}\", \"_blank\")", .{url}) catch return;
    emscripten_run_script(script);
}

pub fn consoleError(text: [*:0]const u8) void {
    if (on_web) emscripten_console_error(text);
}

/// The canvas's size on the page in device pixels, which the drawing buffer
/// matches to stay sharp. Null off the web, or before the page lays it out.
pub fn canvasPixels() ?struct { width: i32, height: i32 } {
    if (!on_web) return null;
    var css_width: f64 = 0;
    var css_height: f64 = 0;
    if (emscripten_get_element_css_size("#canvas", &css_width, &css_height) != 0) return null;
    const ratio = emscripten_get_device_pixel_ratio();
    const width: i32 = @intFromFloat(@round(css_width * ratio));
    const height: i32 = @intFromFloat(@round(css_height * ratio));
    if (width <= 0 or height <= 0) return null;
    return .{ .width = width, .height = height };
}

extern fn emscripten_console_error(text: [*:0]const u8) void;
extern fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;
extern fn emscripten_get_device_pixel_ratio() f64;
extern fn emscripten_run_script(script: [*:0]const u8) void;
extern fn emscripten_async_wget_data(
    url: [*:0]const u8,
    arg: ?*anyopaque,
    onload: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    onerror: *const fn (?*anyopaque) callconv(.c) void,
) void;
