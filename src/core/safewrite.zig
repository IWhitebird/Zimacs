//! Writing a file so that a failure part way, such as a full disk, leaves
//! the old contents whole: the new bytes go to a temporary file beside it,
//! which is synced and then renamed over the original in one step.

const std = @import("std");
const Dir = std.Io.Dir;
const Permissions = std.Io.File.Permissions;

/// Replaces the file at `path` with `bytes`. A link is followed, so the file
/// it points at changes and the link stays.
pub fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var real_buf: [Dir.max_path_bytes]u8 = undefined;
    const target = if (Dir.cwd().realPathFile(io, path, &real_buf)) |n| real_buf[0..n] else |_| path;

    const existing = Dir.cwd().statFile(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    // Another name for the same file would go on holding the old text.
    if (existing) |st| if (st.nlink > 1) return inPlace(io, target, bytes);

    var dir = try Dir.cwd().openDir(io, std.fs.path.dirname(target) orelse ".", .{});
    defer dir.close(io);
    replaceIn(dir, io, std.fs.path.basename(target), bytes, if (existing) |st| st.permissions else null) catch |err| switch (err) {
        // A folder the file may be written in but not added to, or a file
        // another program holds open against being replaced.
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return inPlace(io, target, bytes),
        else => return err,
    };
}

/// Replaces `name` in `dir` with `bytes` through a temporary file beside it,
/// giving it `permissions` when there are some to keep.
pub fn replaceIn(dir: Dir, io: std.Io, name: []const u8, bytes: []const u8, permissions: ?Permissions) !void {
    var tmp_buf: [Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}" ++ temp_suffix, .{name});
    {
        const file = try dir.createFile(io, tmp, .{});
        defer file.close(io);
        errdefer dir.deleteFile(io, tmp) catch {};
        // Set on the open file, since at creation the umask would trim them.
        if (permissions) |p| try file.setPermissions(io, p);
        try file.writeStreamingAll(io, bytes);
        // On disk before the rename, or a crash could leave an empty file
        // under the old name.
        try file.sync(io);
    }
    dir.rename(tmp, dir, name, io) catch |err| {
        dir.deleteFile(io, tmp) catch {};
        return err;
    };
}

pub const temp_suffix = ".zimacs-save";

fn inPlace(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn scratchPath(tmp: *testing.TmpDir, buf: []u8, name: []const u8) ![]const u8 {
    var dir_buf: [Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name });
}

fn readBack(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
}

test "a new file is written, and an old one replaced, with nothing left beside it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = try scratchPath(&tmp, &buf, "a.txt");

    try write(testing.io, path, "first");
    try write(testing.io, path, "second");
    const back = try readBack(&tmp, "a.txt");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("second", back);

    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "a link is followed, so the link stays a link" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = try scratchPath(&tmp, &buf, "link.txt");

    try write(testing.io, path, "new");
    const back = try readBack(&tmp, "real.txt");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("new", back);
    const st = try tmp.dir.statFile(testing.io, "link.txt", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
}

test "a file's permissions are kept" {
    if (!Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "run.sh", .data = "echo old", .flags = .{ .permissions = .executable_file } });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = try scratchPath(&tmp, &buf, "run.sh");

    const before = try tmp.dir.statFile(testing.io, "run.sh", .{});
    try write(testing.io, path, "echo new");
    const after = try tmp.dir.statFile(testing.io, "run.sh", .{});
    try testing.expectEqual(before.permissions, after.permissions);
    try testing.expect(before.inode != after.inode);
}

test "a file with a second hard link is written in place, so both names see it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.txt", .data = "old" });
    try tmp.dir.hardLink("one.txt", tmp.dir, "two.txt", testing.io, .{});
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = try scratchPath(&tmp, &buf, "one.txt");

    try write(testing.io, path, "new");
    const back = try readBack(&tmp, "two.txt");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("new", back);
}
