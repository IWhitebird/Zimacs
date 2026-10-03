//! The notes of the open folder and the links between them: the graph the
//! graph view draws and backlinks are read from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wikilink = @import("wikilink.zig");

/// Notes past this many are left out of the graph.
pub const max_notes = 20_000;
/// Larger notes are not read for links.
pub const max_note_bytes = 1024 * 1024;
/// Longer link targets are ignored.
const max_target = 256;

pub const Note = struct {
    /// Relative to the folder. Null for a name links use that no file has yet.
    path: ?[]const u8,
    /// The file name without `.md`, or the name the links use.
    name: []const u8,
};

pub const Edge = struct { from: u32, to: u32 };

pub const Graph = struct {
    notes: []const Note = &.{},
    edges: []const Edge = &.{},

    /// The graph of the notes among `files`, reading each through `source`,
    /// whose `text(path)` gives a note's text, valid until it is called
    /// again. Everything is allocated in `a`.
    pub fn build(a: Allocator, files: []const []const u8, source: anytype) !Graph {
        var b = Builder{ .a = a };
        for (files) |f| try b.addFile(f);
        const on_disk: u32 = @intCast(b.notes.items.len);
        for (0..on_disk) |i| {
            const from = b.notes.items[i].path.?;
            const text = source.text(from) orelse continue;
            var it = wikilink.Iterator{ .text = text };
            while (it.next()) |link| {
                const to = try b.noteFor(link.target, from) orelse continue;
                try b.link(@intCast(i), to);
            }
        }
        return .{ .notes = b.notes.items, .edges = b.edges.items };
    }

    /// The note kept in the file at `path`, relative to the folder.
    pub fn find(g: Graph, path: []const u8) ?u32 {
        for (g.notes, 0..) |n, i| if (n.path) |p| if (std.mem.eql(u8, p, path)) return @intCast(i);
        return null;
    }

    /// The notes that link to `note`, in the order they were read.
    pub fn backlinks(g: Graph, gpa: Allocator, note: u32, out: *std.ArrayList(u32)) !void {
        for (g.edges) |e| if (e.to == note) try out.append(gpa, e.from);
    }
};

const Builder = struct {
    a: Allocator,
    notes: std.ArrayList(Note) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    /// Notes by lowercase file name, so a link is resolved without a scan.
    by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// Other files by lowercase name: a link to an image is no missing note.
    others: std.StringHashMapUnmanaged(void) = .empty,
    /// Names linked to that no file has, by lowercase name.
    missing: std.StringHashMapUnmanaged(u32) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn addFile(b: *Builder, path: []const u8) !void {
        const name = wikilink.key(std.fs.path.basenamePosix(path));
        const lower = try std.ascii.allocLowerString(b.a, name);
        if (!wikilink.isNote(path)) return b.others.put(b.a, lower, {});
        if (b.notes.items.len >= max_notes) return;
        const entry = try b.by_name.getOrPutValue(b.a, lower, .empty);
        try entry.value_ptr.append(b.a, @intCast(b.notes.items.len));
        try b.notes.append(b.a, .{ .path = path, .name = name });
    }

    /// The note `target`, linked from `from`, means; a new one standing for
    /// it if no file has it. Null for a link to some other kind of file.
    fn noteFor(b: *Builder, written: []const u8, from: []const u8) !?u32 {
        if (written.len > max_target) return null;
        var clean_buf: [max_target]u8 = undefined;
        const target = wikilink.normalise(written, &clean_buf);
        var buf: [max_target]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, wikilink.key(target));
        const name = std.fs.path.basenamePosix(lower);

        var best: ?u32 = null;
        if (b.by_name.get(name)) |candidates| for (candidates.items) |c| {
            const path = b.notes.items[c].path.?;
            if (!wikilink.matches(path, target)) continue;
            if (best == null or wikilink.preferred(path, b.notes.items[best.?].path.?, from)) best = c;
        };
        if (best) |found| return found;
        if (b.others.contains(name)) return null;

        const entry = try b.missing.getOrPut(b.a, lower);
        if (!entry.found_existing) {
            entry.key_ptr.* = try b.a.dupe(u8, lower);
            entry.value_ptr.* = @intCast(b.notes.items.len);
            try b.notes.append(b.a, .{ .path = null, .name = try b.a.dupe(u8, wikilink.key(target)) });
        }
        return entry.value_ptr.*;
    }

    fn link(b: *Builder, from: u32, to: u32) !void {
        if (from == to) return;
        const entry = try b.seen.getOrPut(b.a, (@as(u64, from) << 32) | to);
        if (entry.found_existing) return;
        try b.edges.append(b.a, .{ .from = from, .to = to });
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Texts = struct {
    map: []const [2][]const u8,

    pub fn text(t: Texts, path: []const u8) ?[]const u8 {
        for (t.map) |pair| if (std.mem.eql(u8, pair[0], path)) return pair[1];
        return null;
    }
};

test "notes link to each other, to names with no file yet, but not to other files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const files = [_][]const u8{ "Alpha.md", "img/pic.png", "people/Ada.md", "src/main.zig" };
    const texts = Texts{ .map = &.{
        .{ "Alpha.md", "Met [[Ada]] about [[Plans]], see ![[pic.png]], [Ada](people/Ada.md), [[Alpha]]." },
        .{ "people/Ada.md", "Works on [[plans]] and [[Alpha]]." },
    } };
    const g = try Graph.build(arena.allocator(), &files, texts);

    try testing.expectEqual(@as(usize, 3), g.notes.len);
    try testing.expectEqualStrings("Plans", g.notes[2].name);
    try testing.expect(g.notes[2].path == null);
    // Alpha to Ada and Plans; Ada to Plans and Alpha. Repeats and links to
    // itself or to the image are dropped.
    try testing.expectEqual(@as(usize, 4), g.edges.len);
    try testing.expectEqual(Edge{ .from = 0, .to = 1 }, g.edges[0]);
    try testing.expectEqual(Edge{ .from = 1, .to = 2 }, g.edges[2]);

    var back: std.ArrayList(u32) = .empty;
    defer back.deinit(testing.allocator);
    try g.backlinks(testing.allocator, g.find("Alpha.md").?, &back);
    try testing.expectEqualSlices(u32, &.{1}, back.items);
}
