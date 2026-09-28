//! What a crash leaves behind: its message and stack trace in `crash.log`
//! beside the session, so the next start can say so and Help > Report a
//! Problem can include it.

const std = @import("std");
const builtin = @import("builtin");
const Utc = @import("utc.zig").Utc;

pub const file_name = "crash.log";
/// Where a crash is kept once the start after it has mentioned it.
pub const seen_name = "last-crash.log";
/// A trace deep enough to find the fault, and small enough to write from a
/// crashing process without allocating.
const max_bytes = 32 * 1024;

var io: ?std.Io = null;
var version: []const u8 = "";
var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var dir_len: usize = 0;
var recording = std.atomic.Value(bool).init(false);

/// Copies `dir`, which may be freed before a crash happens.
pub fn setUp(active_io: std.Io, dir: []const u8, running_version: []const u8) void {
    if (dir.len > dir_buf.len) return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_len = dir.len;
    version = running_version;
    io = active_io;
}

/// Writes `crash.log`. Called from the panic and segfault handlers, so it
/// allocates nothing, and a second crash while recording is ignored.
pub fn record(message: []const u8, first_address: ?usize, context: ?std.debug.CpuContextPtr) void {
    if (recording.swap(true, .acq_rel)) return;
    const active_io = io orelse return;
    if (dir_len == 0) return;

    var buf: [max_bytes]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("Zimacs {s} on {s}-{s}, {f} UTC\n\n{s}\n\n", .{
        version,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        Utc{ .seconds = std.Io.Clock.real.now(active_io).toSeconds() },
        message,
    }) catch {};
    std.debug.writeCurrentStackTrace(.{
        .first_address = first_address,
        .context = context,
        // Crashing anyway, so try every way of unwinding.
        .allow_unsafe_unwind = context != null,
    }, .{ .writer = &w, .mode = .no_color }) catch {};

    // A first run may crash before anything else has made the directory.
    std.Io.Dir.cwd().createDirPath(active_io, dir_buf[0..dir_len]) catch return;
    var dir = std.Io.Dir.cwd().openDir(active_io, dir_buf[0..dir_len], .{}) catch return;
    defer dir.close(active_io);
    dir.writeFile(active_io, .{ .sub_path = file_name, .data = w.buffered() }) catch {};
}

/// True if the last run crashed, and only once: the log is moved aside so
/// the next start does not say so again. Report a Problem still finds it.
pub fn takeNew(active_io: std.Io, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(active_io, dir_path, .{}) catch return false;
    defer dir.close(active_io);
    dir.rename(file_name, dir, seen_name, active_io) catch return false;
    return true;
}

/// The most recent crash, if there has been one. Caller frees.
pub fn last(gpa: std.mem.Allocator, active_io: std.Io, dir_path: []const u8) ?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(active_io, dir_path, .{}) catch return null;
    defer dir.close(active_io);
    for ([_][]const u8{ file_name, seen_name }) |name| {
        return dir.readFileAlloc(active_io, name, gpa, .limited(max_bytes)) catch continue;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a crash is announced once and still found afterwards" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try testing.expect(!takeNew(testing.io, dir));
    try testing.expect(last(testing.allocator, testing.io, dir) == null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "panic: boom" });
    try testing.expect(takeNew(testing.io, dir));
    try testing.expect(!takeNew(testing.io, dir));

    const text = last(testing.allocator, testing.io, dir).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("panic: boom", text);
}
