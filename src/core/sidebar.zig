//! The folder tree down the left: folders open and shut in place, and a file
//! opens in a tab. The open folders are read again on every refresh, so the
//! tree follows files that come and go on disk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// Holds only version history, so it is never shown.
const hidden = ".git";

/// A tree this long has been opened too far to read; the rest is left off.
const max_rows = 20_000;

pub const Row = struct {
    /// How many folders deep it sits.
    depth: u16,
    name: []const u8,
    /// Relative to the root, with `/` between folders.
    path: []const u8,
    folder: bool,
    /// A folder showing what is in it.
    open: bool = false,
};

/// What a right click on the tree picked, for its menu to act on.
pub const Target = struct {
    /// Relative to the root; empty for the open folder itself. Owned.
    path: []u8,
    folder: bool,

    /// The folder something new is made in: this one, or the one holding
    /// this file.
    pub fn folderPath(t: Target) []const u8 {
        if (t.folder) return t.path;
        return std.fs.path.dirnamePosix(t.path) orelse "";
    }

    pub fn isRoot(t: Target) bool {
        return t.path.len == 0;
    }
};

pub const Sidebar = struct {
    gpa: Allocator,
    /// Showing while a folder is open; Ctrl+B hides and shows it.
    shown: bool = true,
    /// Folders showing what is in them, by their path in `Row`. Owned keys.
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// Holds the rows' names and paths, remade by every refresh.
    names: ?std.heap.ArenaAllocator = null,
    /// The first row in view.
    top: usize = 0,
    target: ?Target = null,

    const Self = @This();

    pub fn deinit(s: *Self) void {
        s.forget();
        s.expanded.deinit(s.gpa);
        s.rows.deinit(s.gpa);
    }

    /// Drops the tree and which folders were open, as when another folder
    /// becomes the project.
    pub fn forget(s: *Self) void {
        var keys = s.expanded.keyIterator();
        while (keys.next()) |k| s.gpa.free(k.*);
        s.expanded.clearRetainingCapacity();
        s.rows.clearRetainingCapacity();
        if (s.names) |*n| n.deinit();
        s.names = null;
        s.top = 0;
        s.aimAtNothing();
    }

    /// Picks the file or folder at `row` for the tree menu, or the open
    /// folder itself when there is no row.
    pub fn aim(s: *Self, row: ?usize) !void {
        s.aimAtNothing();
        const r = if (row) |i| s.rows.items[i] else Row{ .depth = 0, .name = "", .path = "", .folder = true };
        s.target = .{ .path = try s.gpa.dupe(u8, r.path), .folder = r.folder };
    }

    fn aimAtNothing(s: *Self) void {
        if (s.target) |t| s.gpa.free(t.path);
        s.target = null;
    }

    /// Opens the folders above `path` so it shows, and `path` itself when
    /// it is a folder. Takes effect at the next refresh.
    pub fn reveal(s: *Self, path: []const u8, folder: bool) !void {
        var end: usize = 0;
        while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) try s.expand(path[0..slash]);
        if (folder) try s.expand(path);
    }

    fn expand(s: *Self, path: []const u8) !void {
        if (s.expanded.contains(path)) return;
        const key = try s.gpa.dupe(u8, path);
        s.expanded.put(s.gpa, key, {}) catch |err| {
            s.gpa.free(key);
            return err;
        };
    }

    /// Reads the tree under `root` again, keeping which folders are open.
    pub fn refresh(s: *Self, io: std.Io, root: []const u8) void {
        if (s.names) |*n| _ = n.reset(.retain_capacity) else s.names = .init(s.gpa);
        s.rows.clearRetainingCapacity();
        s.addFolder(io, root, "", 0) catch {};
        s.top = @min(s.top, s.rows.items.len -| 1);
    }

    /// Opens or shuts the folder at `row`.
    pub fn toggle(s: *Self, io: std.Io, root: []const u8, row: usize) void {
        if (row >= s.rows.items.len or !s.rows.items[row].folder) return;
        const path = s.rows.items[row].path;
        if (s.expanded.fetchRemove(path)) |gone| {
            s.gpa.free(gone.key);
        } else {
            const key = s.gpa.dupe(u8, path) catch return;
            s.expanded.put(s.gpa, key, {}) catch return s.gpa.free(key);
        }
        s.refresh(io, root);
    }

    /// Scrolls by `delta` rows, keeping at least one in view.
    pub fn scrollBy(s: *Self, delta: i32) void {
        const next = @as(i64, @intCast(s.top)) + delta;
        s.top = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(s.rows.items.len -| 1))));
    }

    /// The row `y` falls on, for rows `row_height` tall starting at `from`.
    pub fn rowAt(s: *const Self, from: f32, row_height: f32, y: f32) ?usize {
        if (y < from or row_height <= 0) return null;
        const row = s.top + @as(usize, @intFromFloat((y - from) / row_height));
        return if (row < s.rows.items.len) row else null;
    }

    /// Where `path`, relative to the root, is in the tree, if its folders
    /// are open.
    pub fn rowOf(s: *const Self, path: []const u8) ?usize {
        for (s.rows.items, 0..) |r, i| if (!r.folder and std.mem.eql(u8, r.path, path)) return i;
        return null;
    }

    fn addFolder(s: *Self, io: std.Io, root: []const u8, folder: []const u8, depth: u16) !void {
        const a = s.names.?.allocator();
        const path = if (folder.len == 0) root else try std.fs.path.join(a, &.{ root, folder });
        var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var entries: std.ArrayList(Row) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (std.mem.eql(u8, entry.name, hidden)) continue;
            const is_folder = switch (entry.kind) {
                .directory => true,
                .sym_link => if (dir.statFile(io, entry.name, .{})) |st| st.kind == .directory else |_| false,
                else => false,
            };
            const name = try a.dupe(u8, entry.name);
            const child = if (folder.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, name });
            try entries.append(a, .{ .depth = depth, .name = name, .path = child, .folder = is_folder, .open = is_folder and s.expanded.contains(child) });
        }
        std.mem.sort(Row, entries.items, {}, before);

        for (entries.items) |row| {
            if (s.rows.items.len >= max_rows) return;
            try s.rows.append(s.gpa, row);
            if (row.open) try s.addFolder(io, root, row.path, depth + 1);
        }
    }
};

/// Folders first, then by name ignoring case.
fn before(_: void, a: Row, b: Row) bool {
    if (a.folder != b.folder) return a.folder;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn scratch(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src/core");
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/x.zig", .data = "" });
    return buf[0..try tmp.dir.realPath(io, buf)];
}

fn names(s: *const Sidebar, out: *std.ArrayList(u8)) ![]const u8 {
    for (s.rows.items) |r| {
        try out.appendNTimes(testing.allocator, ' ', r.depth * 2);
        try out.appendSlice(testing.allocator, r.name);
        try out.append(testing.allocator, '\n');
    }
    return out.items;
}

test "folders come first, open ones show what is inside, and .git is left out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = try scratch(&tmp, &buf);

    var s = Sidebar{ .gpa = testing.allocator };
    defer s.deinit();
    s.refresh(testing.io, root);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("src\nA.md\nb.txt\n", try names(&s, &out));

    s.toggle(testing.io, root, 0);
    out.clearRetainingCapacity();
    try testing.expectEqualStrings("src\n  core\n  main.zig\nA.md\nb.txt\n", try names(&s, &out));
    try testing.expectEqual(@as(?usize, 2), s.rowOf("src/main.zig"));

    // Shutting and opening again remembers the folders inside.
    s.toggle(testing.io, root, 1);
    s.toggle(testing.io, root, 0);
    s.toggle(testing.io, root, 0);
    out.clearRetainingCapacity();
    try testing.expectEqualStrings("src\n  core\n    x.zig\n  main.zig\nA.md\nb.txt\n", try names(&s, &out));
}

test "a refresh picks up a file made since" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = try scratch(&tmp, &buf);

    var s = Sidebar{ .gpa = testing.allocator };
    defer s.deinit();
    s.refresh(testing.io, root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "" });
    s.refresh(testing.io, root);
    try testing.expectEqual(@as(usize, 4), s.rows.items.len);
}

test "rows are found under the pointer, scrolled or not" {
    var s = Sidebar{ .gpa = testing.allocator };
    defer s.deinit();
    for (0..10) |_| try s.rows.append(testing.allocator, .{ .depth = 0, .name = "f", .path = "f", .folder = false });
    try testing.expectEqual(@as(?usize, 2), s.rowAt(100, 20, 145));
    try testing.expect(s.rowAt(100, 20, 90) == null);
    s.scrollBy(3);
    try testing.expectEqual(@as(?usize, 5), s.rowAt(100, 20, 145));
    s.scrollBy(100);
    try testing.expectEqual(@as(usize, 9), s.top);
}
