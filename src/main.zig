const std = @import("std");
const zimacs = @import("zimacs.zig");
const browser_calls = @import("core/web.zig");
const crash = @import("core/crash.zig");
const mcp = @import("core/mcp.zig");

/// Panics on the web go to the browser console.
///
/// They cannot go through `std.debug`, whose printing path pulls in the
/// threaded `Io` that does not build for emscripten - which is the same
/// reason `std_options_debug_io` is overridden below. Without this a crash
/// shows up as a bare "RuntimeError: unreachable" with no message at all.
pub const panic = if (zimacs.on_web)
    std.debug.FullPanic(webPanic)
else
    std.debug.FullPanic(crashPanic);

/// Everywhere else a crash is written to `crash.log` first, then reported
/// as usual.
fn crashPanic(message: []const u8, first_address: ?usize) noreturn {
    crash.record(message, first_address orelse @returnAddress(), null);
    std.debug.defaultPanic(message, first_address);
}

/// Crashes in C code, such as raylib's, arrive as segfaults instead.
pub const debug = struct {
    pub fn handleSegfault(address: ?usize, name: []const u8, context: ?std.debug.CpuContextPtr) noreturn {
        var buf: [96]u8 = undefined;
        const message = if (address) |a| std.fmt.bufPrint(&buf, "{s} at address 0x{x}", .{ name, a }) catch name else name;
        crash.record(message, null, context);
        std.debug.defaultHandleSegfault(address, name, context);
    }
};

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
    // `Zimacs mcp [folder]` serves notes to an AI agent instead of opening
    // a window.
    var args = try process.minimal.args.iterateAllocator(process.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |first| if (std.mem.eql(u8, first, "mcp")) {
        mcp.run(process.gpa, process.io, process.environ_map, args.next(), zimacs.version) catch |err| {
            std.debug.print("Zimacs could not serve notes: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    };

    zimacs.run(.{
        .args = process.minimal.args,
        .io = process.io,
        .env = process.environ_map,
    }) catch |err| switch (err) {
        error.NoDisplay => {
            std.debug.print("Zimacs could not open a window. It needs a graphical desktop to run.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
}

fn web(process: std.process.Init.Minimal) !void {
    try zimacs.run(.{ .args = process.args });
}
