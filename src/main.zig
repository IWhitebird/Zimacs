const std = @import("std");
const zimacs = @import("zimacs.zig");
const browser_calls = @import("core/web.zig");

/// Panics on the web go to the browser console.
///
/// They cannot go through `std.debug`, whose printing path pulls in the
/// threaded `Io` that does not build for emscripten - which is the same
/// reason `std_options_debug_io` is overridden below. Without this a crash
/// shows up as a bare "RuntimeError: unreachable" with no message at all.
pub const panic = if (zimacs.on_web)
    std.debug.FullPanic(webPanic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

fn webPanic(message: []const u8, _: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "Zimacs panic: {s}", .{message}) catch "Zimacs panic";
    browser_calls.consoleError(text);
    @trap();
}

/// Where `std.debug` writes panics.
///
/// On the web this must not be the threaded implementation: pulling it in
/// drags along child-process handling, which does not compile for emscripten
/// in Zig 0.16. Everywhere else this is exactly what std would have chosen.
pub const std_options_debug_io: std.Io = if (zimacs.on_web)
    .failing
else
    std.Io.Threaded.global_single_threaded.io();

/// The web build takes the minimal start-up, for the same reason: the full
/// one builds a threaded `Io` before `main` is even called.
pub const main = if (zimacs.on_web) web else native;

fn native(process: std.process.Init) !void {
    try zimacs.run(.{
        .args = process.minimal.args,
        .io = process.io,
        .env = process.environ_map,
    });
}

fn web(process: std.process.Init.Minimal) !void {
    try zimacs.run(.{ .args = process.args });
}
