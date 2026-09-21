//! The in-editor file browser.
//!
//! Reads a directory into a list of names and hands it to the prompt, which
//! already knows how to show, filter and pick from a list. Directories carry a
//! trailing slash, which is both how they are told apart and how they sort
//! ahead of files.
//!
//! Drawing it ourselves rather than calling an OS dialog keeps the editor free
//! of GTK and friends, and is the only approach that also works on the web.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Shown first so there is always a way back up.
pub const parent = "../";

pub const Browser = struct {
    gpa: Allocator = undefined,
    /// The directory being shown. Owned.
    dir: []const u8 = "",
    /// Entry names, directories suffixed with '/'. Owned.
    names: std.ArrayList([]const u8) = .empty,
    /// Borrowed views of `names`, which the prompt shows and filters.
    listing: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    pub fn deinit(b: *Self) void {
        b.clear();
        b.names.deinit(b.gpa);
        b.listing.deinit(b.gpa);
        if (b.dir.len > 0) b.gpa.free(b.dir);
        b.dir = "";
    }

    fn clear(b: *Self) void {
        for (b.names.items) |n| b.gpa.free(n);
        b.names.clearRetainingCapacity();
        b.listing.clearRetainingCapacity();
    }

    /// Reads `path` and replaces the listing with its contents.
    ///
    /// The directory is recorded as an absolute path. Keeping a relative one
    /// like "." would break stepping upwards, since it has no parent to take.
    pub fn show(b: *Self, io: std.Io, path: []const u8, show_hidden: bool) !void {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const absolute = path_buf[0..try dir.realPath(io, &path_buf)];

        b.clear();
        try b.names.append(b.gpa, try b.gpa.dupe(u8, parent));

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            const is_dir = entry.kind == .directory;
            const name = if (is_dir)
                try std.fmt.allocPrint(b.gpa, "{s}/", .{entry.name})
            else
                try b.gpa.dupe(u8, entry.name);
            errdefer b.gpa.free(name);
            try b.names.append(b.gpa, name);
        }

        // `..` stays pinned at the top; everything else sorts.
        std.mem.sort([]const u8, b.names.items[1..], {}, before);

        try b.listing.ensureTotalCapacity(b.gpa, b.names.items.len);
        for (b.names.items) |n| b.listing.appendAssumeCapacity(n);

        const owned = try b.gpa.dupe(u8, absolute);
        if (b.dir.len > 0) b.gpa.free(b.dir);
        b.dir = owned;
    }

    pub fn items(b: Self) []const []const u8 {
        return b.listing.items;
    }

    /// The full path `name` refers to. Caller frees.
    pub fn resolve(b: Self, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, parent)) {
            return b.gpa.dupe(u8, std.fs.path.dirname(b.dir) orelse "/");
        }
        return std.fs.path.join(b.gpa, &.{ b.dir, trimSlash(name) });
    }
};

pub fn isDirectory(name: []const u8) bool {
    return name.len > 0 and name[name.len - 1] == '/';
}

pub fn trimSlash(name: []const u8) []const u8 {
    return if (isDirectory(name)) name[0 .. name.len - 1] else name;
}

/// Directories first, then by name, ignoring case so `Makefile` and `main.zig`
/// end up next to each other.
fn before(_: void, a: []const u8, b: []const u8) bool {
    const a_dir = isDirectory(a);
    const b_dir = isDirectory(b);
    if (a_dir != b_dir) return a_dir;
    return std.ascii.lessThanIgnoreCase(trimSlash(a), trimSlash(b));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "directories are told apart by their slash" {
    try testing.expect(isDirectory("src/"));
    try testing.expect(!isDirectory("main.zig"));
    try testing.expect(!isDirectory(""));
    try testing.expectEqualSlices(u8, "src", trimSlash("src/"));
    try testing.expectEqualSlices(u8, "main.zig", trimSlash("main.zig"));
}

test "directories sort before files, then by name ignoring case" {
    var names = [_][]const u8{ "zebra.txt", "src/", "Makefile", "assets/", "build.zig" };
    std.mem.sort([]const u8, &names, {}, before);

    try testing.expectEqualSlices(u8, "assets/", names[0]);
    try testing.expectEqualSlices(u8, "src/", names[1]);
    try testing.expectEqualSlices(u8, "build.zig", names[2]);
    try testing.expectEqualSlices(u8, "Makefile", names[3]);
    try testing.expectEqualSlices(u8, "zebra.txt", names[4]);
}

test "resolve joins onto the current directory" {
    var b = Browser{ .gpa = testing.allocator };
    defer b.deinit();
    b.dir = try testing.allocator.dupe(u8, "/home/user/proj");

    const file = try b.resolve("main.zig");
    defer testing.allocator.free(file);
    try testing.expectEqualSlices(u8, "/home/user/proj/main.zig", file);

    const dir = try b.resolve("src/");
    defer testing.allocator.free(dir);
    try testing.expectEqualSlices(u8, "/home/user/proj/src", dir);
}

test "resolve on .. goes up a level" {
    var b = Browser{ .gpa = testing.allocator };
    defer b.deinit();
    b.dir = try testing.allocator.dupe(u8, "/home/user/proj");

    const up = try b.resolve(parent);
    defer testing.allocator.free(up);
    try testing.expectEqualSlices(u8, "/home/user", up);
}

test "going up from the root stays at the root" {
    var b = Browser{ .gpa = testing.allocator };
    defer b.deinit();
    b.dir = try testing.allocator.dupe(u8, "/");

    const up = try b.resolve(parent);
    defer testing.allocator.free(up);
    try testing.expectEqualSlices(u8, "/", up);
}

test "reading a real directory lists it with .. first" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var b = Browser{ .gpa = gpa };
    defer b.deinit();

    try b.show(threaded.io(), "src/core", false);
    try testing.expectEqualSlices(u8, parent, b.items()[0]);
    try testing.expect(b.items().len > 1);

    // This file is in there, and nothing is listed twice.
    var seen: usize = 0;
    for (b.items()) |name| {
        if (std.mem.eql(u8, name, "browser.zig")) seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "a relative directory is stored absolutely, so stepping up works" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var b = Browser{ .gpa = gpa };
    defer b.deinit();

    try b.show(threaded.io(), ".", false);
    try testing.expect(std.fs.path.isAbsolute(b.dir));

    // Going up must reach the parent, not the filesystem root.
    const up = try b.resolve(parent);
    defer gpa.free(up);
    try testing.expect(!std.mem.eql(u8, up, "/"));
    try testing.expectEqualSlices(u8, std.fs.path.dirname(b.dir).?, up);
}

test "walking up from a nested directory goes one level at a time" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var b = Browser{ .gpa = gpa };
    defer b.deinit();

    try b.show(threaded.io(), "src/core", false);
    const deep = try gpa.dupe(u8, b.dir);
    defer gpa.free(deep);

    const up = try b.resolve(parent);
    defer gpa.free(up);
    try b.show(threaded.io(), up, false);

    try testing.expectEqualSlices(u8, std.fs.path.dirname(deep).?, b.dir);
    try testing.expect(std.mem.endsWith(u8, b.dir, "src"));
}
