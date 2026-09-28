//! Asking the operating system to do what Zimacs leaves to it: opening a
//! link in the browser.

const std = @import("std");
const builtin = @import("builtin");
const web = @import("web.zig");

/// Opens `url`, which must be percent-encoded, in the default browser.
/// Returns without waiting for the browser.
pub fn openUrl(gpa: std.mem.Allocator, io: ?std.Io, url: []const u8) !void {
    switch (builtin.os.tag) {
        .emscripten => web.openUrl(url),
        .windows => try win32.open(gpa, url),
        else => {
            const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
            try runDetached(io orelse return error.NoIo, &.{ opener, url });
        },
    }
}

/// Starts `argv` and reaps it on a thread of its own, so the editor never
/// waits on it and it never lingers as a zombie.
fn runDetached(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const thread = std.Thread.spawn(.{}, reap, .{ child, io }) catch {
        _ = child.wait(io) catch {};
        return;
    };
    thread.detach();
}

fn reap(child: std.process.Child, io: std.Io) void {
    var c = child;
    _ = c.wait(io) catch {};
}

const win32 = struct {
    const SW_SHOWNORMAL: c_int = 1;

    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        operation: [*:0]const u16,
        file: [*:0]const u16,
        parameters: ?[*:0]const u16,
        directory: ?[*:0]const u16,
        show: c_int,
    ) callconv(.winapi) isize;

    fn open(gpa: std.mem.Allocator, url: []const u8) !void {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, url);
        defer gpa.free(wide);
        const operation = std.unicode.utf8ToUtf16LeStringLiteral("open");
        // Anything above 32 is success.
        if (ShellExecuteW(null, operation, wide, null, null, SW_SHOWNORMAL) <= 32) return error.OpenFailed;
    }
};
