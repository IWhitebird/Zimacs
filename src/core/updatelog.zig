//! A record of every update check and install, kept with the session, so a
//! failure that happened while nobody was looking can still be explained.

const std = @import("std");

pub const file_name = "update.log";
/// Past this the older half is dropped.
const max_bytes = 32 * 1024;

pub const Log = struct {
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,

    /// Copied, so the log outlives whoever owns `dir`.
    pub fn setDir(l: *Log, dir: []const u8) void {
        if (dir.len > l.dir_buf.len) return;
        @memcpy(l.dir_buf[0..dir.len], dir);
        l.dir_len = dir.len;
    }

    /// Best effort: an update must not fail because its log could not be
    /// written.
    pub fn write(l: *const Log, gpa: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) void {
        if (l.dir_len == 0) return;
        const seconds = std.Io.Clock.real.now(io).toSeconds();
        l.append(gpa, io, seconds, fmt, args) catch {};
    }

    fn append(l: *const Log, gpa: std.mem.Allocator, io: std.Io, seconds: i64, comptime fmt: []const u8, args: anytype) !void {
        const dir_path = l.dir_buf[0..l.dir_len];
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);

        const old = dir.readFileAlloc(io, file_name, gpa, .limited(max_bytes * 2)) catch |err| switch (err) {
            error.FileNotFound, error.StreamTooLong => try gpa.alloc(u8, 0),
            else => return err,
        };
        defer gpa.free(old);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, keptPart(old));
        try writeStamp(gpa, &out, seconds);
        try out.print(gpa, "  " ++ fmt ++ "\n", args);
        try dir.writeFile(io, .{ .sub_path = file_name, .data = out.items });
    }
};

/// All of `old`, or its newer half starting at a line once it has grown.
fn keptPart(old: []const u8) []const u8 {
    if (old.len < max_bytes) return old;
    const half = old[old.len - max_bytes / 2 ..];
    const line = std.mem.indexOfScalar(u8, half, '\n') orelse return "";
    return half[line + 1 ..];
}

/// UTC, as `2026-09-24 11:08:00`.
fn writeStamp(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seconds: i64) !void {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    try out.print(gpa, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        day.year,               month_day.month.numeric(), month_day.day_index + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testLog(tmp: *testing.TmpDir, buf: []u8) !Log {
    const dir = try tmp.dir.realPath(testing.io, buf);
    var l = Log{};
    l.setDir(buf[0..dir]);
    return l;
}

test "entries are appended with a UTC timestamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const l = try testLog(&tmp, &buf);

    try l.append(testing.allocator, testing.io, 1790157813, "check: latest {s}", .{"0.1.7"});
    try l.append(testing.allocator, testing.io, 1790157873, "install 0.1.7: {s}", .{"ReadFailed"});

    const text = try tmp.dir.readFileAlloc(testing.io, file_name, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "2026-09-23 10:03:33  check: latest 0.1.7\n2026-09-23 10:04:33  install 0.1.7: ReadFailed\n",
        text,
    );
}

test "a full log keeps its newer half, cut at a line" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(testing.allocator);
    var i: usize = 0;
    while (old.items.len < max_bytes) : (i += 1) try old.print(testing.allocator, "line {d}\n", .{i});

    const kept = keptPart(old.items);
    try testing.expect(kept.len <= max_bytes / 2);
    try testing.expect(std.mem.startsWith(u8, kept, "line "));
    try testing.expect(std.mem.endsWith(u8, kept, "\n"));
    try testing.expectEqualStrings(old.items[old.items.len - kept.len ..], kept);
}

test "without a directory nothing is written" {
    const l = Log{};
    l.write(testing.allocator, testing.io, "nothing {d}", .{1});
}
