//! The folder opened as a project. Its files are listed on a thread of their
//! own, so a large tree never holds up the editor; quick open and search use
//! the list once the main loop has picked it up.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const notes_mod = @import("notes.zig");

/// Folders never listed: version control, dependencies and build output,
/// which hold many files nobody opens by name.
const skipped = [_][]const u8{
    ".git",   ".hg",         ".svn",  "node_modules", ".zig-cache", "zig-cache",   "zig-out", "zig-pkg",
    "target", "__pycache__", ".venv", "venv",         ".next",      ".mypy_cache", ".gradle",
};

/// Past this many files the listing stops, so opening a home folder or a
/// drive's root stays usable.
pub const max_files = 200_000;
/// A zero byte in this much of the start marks a file as binary.
const binary_probe = 8000;

/// The files of one walk, all allocated in its arena.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    /// Relative to the root, with `/` between folders, sorted.
    files: []const []const u8 = &.{},
    /// The walk stopped at `max_files`.
    cut_short: bool = false,
    /// The notes among the files, and their links.
    notes: notes_mod.Graph = .{},
    /// Which opening of a folder it belongs to.
    generation: u32,

    pub fn destroy(l: *Listing, gpa: Allocator) void {
        free(gpa, l);
    }
};

/// Lists `root` and reads its notes there and then, for a caller that can
/// wait. Destroy the listing when done.
pub fn scan(gpa: Allocator, io: std.Io, root: []const u8) !*Listing {
    return walk(gpa, io, root, 0);
}

pub const Workspace = struct {
    gpa: Allocator,
    /// The folder, absolute. Owned. Null while none is open.
    root: ?[]u8 = null,
    listing: ?*Listing = null,
    /// A finished walk, handed from its thread to `poll`.
    pending: std.atomic.Value(?*Listing) = .init(null),
    /// Bumped by every open and close, so a walk of an earlier folder is
    /// dropped when it finishes.
    generation: std.atomic.Value(u32) = .init(0),
    /// Called from the walking thread when it is done, to wake the editor.
    on_listed: ?*const fn () void = null,

    const Self = @This();

    pub fn deinit(w: *Self) void {
        w.close();
        // A walk still running frees its own listing when it sees it is stale.
        if (w.pending.swap(null, .acq_rel)) |l| free(w.gpa, l);
    }

    /// Opens `path`, which must be a folder, and starts listing it.
    pub fn open(w: *Self, io: std.Io, path: []const u8) !void {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const real = buf[0..try Dir.cwd().realPathFile(io, path, &buf)];
        var dir = try Dir.cwd().openDir(io, real, .{});
        dir.close(io);

        const root = try w.gpa.dupe(u8, real);
        w.close();
        w.root = root;
        w.refresh(io);
    }

    pub fn close(w: *Self) void {
        _ = w.generation.fetchAdd(1, .acq_rel);
        if (w.listing) |l| free(w.gpa, l);
        w.listing = null;
        if (w.root) |r| w.gpa.free(r);
        w.root = null;
    }

    /// Lists the folder again, as after files were added to it.
    pub fn refresh(w: *Self, io: std.Io) void {
        // The web build has no threads, and no folders to open either.
        if (builtin.single_threaded) return;
        const root = w.root orelse return;
        const owned = w.gpa.dupe(u8, root) catch return;
        const generation = w.generation.load(.acquire);
        const thread = std.Thread.spawn(.{}, walkInBackground, .{ w, io, owned, generation }) catch {
            w.gpa.free(owned);
            return;
        };
        thread.detach();
    }

    /// Takes over a walk that has finished, if it is of the folder still
    /// open. Called from the main loop. True when `files` changed, which
    /// frees the slices it handed out before.
    pub fn poll(w: *Self) bool {
        const done = w.pending.swap(null, .acq_rel) orelse return false;
        if (done.generation != w.generation.load(.acquire)) {
            free(w.gpa, done);
            return false;
        }
        if (w.listing) |l| free(w.gpa, l);
        w.listing = done;
        return true;
    }

    /// Every file found, relative to the root; empty until the first walk
    /// is in.
    pub fn files(w: *const Self) []const []const u8 {
        return if (w.listing) |l| l.files else &.{};
    }

    pub fn notes(w: *const Self) notes_mod.Graph {
        return if (w.listing) |l| l.notes else .{};
    }

    pub fn cutShort(w: *const Self) bool {
        return if (w.listing) |l| l.cut_short else false;
    }

    /// The folder's own name, for headings.
    pub fn name(w: *const Self) []const u8 {
        return std.fs.path.basename(w.root orelse return "");
    }

    /// `relative` joined onto the root. Caller frees.
    pub fn absolute(w: *const Self, gpa: Allocator, relative: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ w.root orelse return error.NoFolder, relative });
    }

    /// `path` relative to the root, when it lies inside it.
    pub fn relativeOf(w: *const Self, path: []const u8) ?[]const u8 {
        const root = w.root orelse return null;
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return null;
        if (!std.fs.path.isSep(path[root.len])) return null;
        return path[root.len + 1 ..];
    }

    fn walkInBackground(w: *Self, io: std.Io, root: []u8, generation: u32) void {
        defer w.gpa.free(root);
        const listing = walk(w.gpa, io, root, generation) catch return;
        if (generation != w.generation.load(.acquire)) return free(w.gpa, listing);
        // A newer walk of the same folder may have got there first.
        if (w.pending.swap(listing, .acq_rel)) |older| free(w.gpa, older);
        if (w.on_listed) |wake| wake();
    }
};

/// Reads files of a folder one at a time, into one buffer.
pub const Reader = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    /// Larger files are skipped.
    limit: usize,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(r: *Reader) void {
        r.buf.deinit(r.gpa);
    }

    /// The text of `path`, relative to the root, or null when it cannot be
    /// read, is too large, or looks binary. Valid until the next call.
    pub fn text(r: *Reader, path: []const u8) ?[]const u8 {
        var full_buf: [Dir.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ r.root, path }) catch return null;
        const bytes = Dir.cwd().readFileAlloc(r.io, full, r.gpa, .limited(r.limit)) catch return null;
        r.buf.deinit(r.gpa);
        r.buf = .fromOwnedSlice(bytes);
        if (std.mem.findScalar(u8, bytes[0..@min(bytes.len, binary_probe)], 0) != null) return null;
        return bytes;
    }
};

fn free(gpa: Allocator, listing: *Listing) void {
    listing.arena.deinit();
    gpa.destroy(listing);
}

/// Every file under `root`, depth first, skipping the folders in `skipped`
/// and not following links to folders, which could loop.
fn walk(gpa: Allocator, io: std.Io, root: []const u8, generation: u32) !*Listing {
    const listing = try gpa.create(Listing);
    listing.* = .{ .arena = .init(gpa), .generation = generation };
    errdefer free(gpa, listing);
    const a = listing.arena.allocator();

    var found: std.ArrayList([]const u8) = .empty;
    var folders: std.ArrayList([]const u8) = .empty;
    defer folders.deinit(gpa);
    try folders.append(gpa, "");

    outer: while (folders.pop()) |folder| {
        const path = try std.fs.path.join(a, &.{ root, folder });
        var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const kind = switch (entry.kind) {
                .sym_link => if (dir.statFile(io, entry.name, .{})) |st| if (st.kind == .file) .file else continue else |_| continue,
                else => entry.kind,
            };
            switch (kind) {
                .directory => if (!isSkipped(entry.name)) try folders.append(gpa, try joinRelative(a, folder, entry.name)),
                .file => {
                    try found.append(a, try joinRelative(a, folder, entry.name));
                    if (found.items.len >= max_files) {
                        listing.cut_short = true;
                        break :outer;
                    }
                },
                else => {},
            }
        }
    }
    std.mem.sort([]const u8, found.items, {}, before);
    listing.files = found.items;

    var reader = Reader{ .gpa = gpa, .io = io, .root = root, .limit = notes_mod.max_note_bytes };
    defer reader.deinit();
    listing.notes = try notes_mod.Graph.build(a, listing.files, &reader);
    return listing;
}

fn isSkipped(name: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Always with `/`, which every system here accepts, so paths read the
/// same everywhere.
fn joinRelative(a: Allocator, folder: []const u8, entry: []const u8) ![]const u8 {
    if (folder.len == 0) return a.dupe(u8, entry);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ folder, entry });
}

fn before(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn scratchTree(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src/core");
    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.createDirPath(io, "node_modules/left-pad");
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "See [[main notes]]." });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/buffer.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/left-pad/index.js", .data = "" });
}

fn rootOf(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

test "a walk finds every file, sorted, and skips dependency and history folders" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scratchTree(&tmp);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const listing = try walk(testing.allocator, testing.io, try rootOf(&tmp, &buf), 0);
    defer free(testing.allocator, listing);

    try testing.expectEqual(@as(usize, 3), listing.files.len);
    try testing.expectEqualStrings("README.md", listing.files[0]);
    try testing.expectEqualStrings("src/core/buffer.zig", listing.files[1]);
    try testing.expectEqualStrings("src/main.zig", listing.files[2]);
    try testing.expect(!listing.cut_short);
    // The README, and the note it links to that has no file yet.
    try testing.expectEqual(@as(usize, 2), listing.notes.notes.len);
    try testing.expectEqual(@as(usize, 1), listing.notes.edges.len);
}

test "opening a folder lists it in the background, and paths map both ways" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try scratchTree(&tmp);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &buf);

    var w = Workspace{ .gpa = testing.allocator };
    defer w.deinit();
    try w.open(testing.io, root);
    var tries: usize = 0;
    while (w.files().len == 0 and tries < 500) : (tries += 1) {
        _ = w.poll();
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expectEqual(@as(usize, 3), w.files().len);

    const full = try w.absolute(testing.allocator, "src/main.zig");
    defer testing.allocator.free(full);
    try testing.expectEqualStrings("src/main.zig", w.relativeOf(full).?);
    try testing.expect(w.relativeOf("/elsewhere/main.zig") == null);
}

test "opening a file instead of a folder is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "" });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &buf);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "note.txt" });
    defer testing.allocator.free(file);

    var w = Workspace{ .gpa = testing.allocator };
    defer w.deinit();
    try testing.expectError(error.NotDir, w.open(testing.io, file));
    try testing.expect(w.root == null);
}
