//! The files you opened lately, newest first.
//!
//! Kept as one path per line next to the session, so Ctrl+R can offer them
//! without having to search the disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const file_name = "recent";

const max_entries = 20;
const max_bytes = 64 * 1024;

pub const Recent = struct {
    gpa: Allocator = undefined,
    paths: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    pub fn deinit(r: *Self) void {
        for (r.paths.items) |p| r.gpa.free(p);
        r.paths.deinit(r.gpa);
    }

    pub fn items(r: Self) []const []const u8 {
        return r.paths.items;
    }

    /// Moves `path` to the front, dropping any older mention of it.
    pub fn add(r: *Self, path: []const u8) !void {
        if (path.len == 0) return;

        for (r.paths.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, path)) {
                const moved = r.paths.orderedRemove(i);
                try r.paths.insert(r.gpa, 0, moved);
                return;
            }
        }

        const owned = try r.gpa.dupe(u8, path);
        errdefer r.gpa.free(owned);
        try r.paths.insert(r.gpa, 0, owned);

        while (r.paths.items.len > max_entries) {
            r.gpa.free(r.paths.pop().?);
        }
    }

    pub fn load(r: *Self, io: std.Io, dir: []const u8) !void {
        var open = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return;
        defer open.close(io);

        const text = open.readFileAlloc(io, file_name, r.gpa, .limited(max_bytes)) catch return;
        defer r.gpa.free(text);

        // Read in reverse so `add` leaves the file's order intact.
        var lines = std.mem.splitScalar(u8, text, '\n');
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(r.gpa);
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) try all.append(r.gpa, trimmed);
        }
        var i = all.items.len;
        while (i > 0) {
            i -= 1;
            try r.add(all.items[i]);
        }
    }

    pub fn save(r: *Self, io: std.Io, dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var open = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer open.close(io);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(r.gpa);
        for (r.paths.items) |p| {
            try out.appendSlice(r.gpa, p);
            try out.append(r.gpa, '\n');
        }
        try open.writeFile(io, .{ .sub_path = file_name, .data = out.items });
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "newest first" {
    var r = Recent{ .gpa = testing.allocator };
    defer r.deinit();

    try r.add("/a");
    try r.add("/b");
    try r.add("/c");

    try testing.expectEqual(@as(usize, 3), r.items().len);
    try testing.expectEqualSlices(u8, "/c", r.items()[0]);
    try testing.expectEqualSlices(u8, "/a", r.items()[2]);
}

test "reopening moves a file to the front without duplicating it" {
    var r = Recent{ .gpa = testing.allocator };
    defer r.deinit();

    try r.add("/a");
    try r.add("/b");
    try r.add("/a");

    try testing.expectEqual(@as(usize, 2), r.items().len);
    try testing.expectEqualSlices(u8, "/a", r.items()[0]);
    try testing.expectEqualSlices(u8, "/b", r.items()[1]);
}

test "the list is capped" {
    var r = Recent{ .gpa = testing.allocator };
    defer r.deinit();

    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < max_entries + 5) : (i += 1) {
        try r.add(try std.fmt.bufPrint(&buf, "/file{d}", .{i}));
    }
    try testing.expectEqual(@as(usize, max_entries), r.items().len);
    // The newest survives, the oldest is gone.
    try testing.expectEqualSlices(u8, "/file24", r.items()[0]);
}

test "empty paths are ignored" {
    var r = Recent{ .gpa = testing.allocator };
    defer r.deinit();
    try r.add("");
    try testing.expectEqual(@as(usize, 0), r.items().len);
}
