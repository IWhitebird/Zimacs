//! A folder of notes as an AI agent's tools use it: notes found by name, as
//! links name them; read with their links; written, searched, and followed
//! from one to the next. Every answer is plain text for the agent to read.
//! The folder is read afresh for each, so edits made elsewhere are seen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Dir = std.Io.Dir;
const workspace = @import("workspace.zig");
const notes = @import("notes.zig");
const Graph = notes.Graph;
const wikilink = @import("wikilink.zig");
const safewrite = @import("safewrite.zig");

/// Lines a listing or search gives back when not told how many.
pub const default_limit = 100;
/// How far `related` follows links at most.
pub const max_depth = 3;
/// How much of a line a search hit shows.
const max_shown_line = 200;
/// Longer note names are refused.
const max_name = 200;
/// Characters a note name may not hold: they would not survive as a file
/// name everywhere, or as a link.
const unsafe_characters = "\\:*?\"<>|[]#^";

pub const Error = error{
    /// No note has the name.
    NoSuchNote,
    /// The name is empty, would put the note outside the folder, or holds a
    /// character a note name cannot.
    BadName,
};

pub const Mode = enum { replace, append };

pub const Notebook = struct {
    gpa: Allocator,
    io: std.Io,
    /// Absolute.
    root: []const u8,

    const Self = @This();

    fn scan(nb: Self) !*workspace.Listing {
        return workspace.scan(nb.gpa, nb.io, nb.root);
    }

    fn reader(nb: Self) workspace.Reader {
        return .{ .gpa = nb.gpa, .io = nb.io, .root = nb.root, .limit = notes.max_note_bytes };
    }

    /// The notes whose path holds `query`, with how many links go in and
    /// out of each, then the names linked to that have no note yet.
    pub fn list(nb: Self, out: *Writer, query: []const u8, limit: usize) !void {
        const listing = try nb.scan();
        defer listing.destroy(nb.gpa);
        const g = listing.notes;
        var matching: usize = 0;
        for (g.notes, 0..) |n, i| {
            const path = n.path orelse continue;
            if (std.ascii.findIgnoreCase(path, query) == null) continue;
            matching += 1;
            if (matching > limit) continue;
            const c = counts(g, @intCast(i));
            try out.print("{s} ({d} in, {d} out)\n", .{ path, c.in, c.out });
        }
        if (matching > limit) try out.print("...and {d} more.\n", .{matching - limit});
        if (matching == 0) {
            if (query.len > 0) return out.print("No note's path holds \"{s}\".\n", .{query});
            try out.print("There are no notes in {s} yet.\n", .{nb.root});
        }
        if (query.len > 0) return;
        var first = true;
        for (g.notes) |n| {
            if (n.path != null) continue;
            try out.writeAll(if (first) "Linked to, but not written yet: " else ", ");
            try out.print("[[{s}]]", .{n.name});
            first = false;
        }
        if (!first) try out.writeByte('\n');
    }

    /// A note's text, then the notes it links to and those linking to it.
    pub fn read(nb: Self, out: *Writer, name: []const u8) !void {
        const listing = try nb.scan();
        defer listing.destroy(nb.gpa);
        const g = listing.notes;
        const i = g.named(name) orelse return error.NoSuchNote;
        var r = nb.reader();
        defer r.deinit();
        const text = r.text(g.notes[i].path.?) orelse return error.NoSuchNote;
        try out.writeAll(text);
        if (text.len > 0 and text[text.len - 1] != '\n') try out.writeByte('\n');
        try out.print("\n---\n{s}\n", .{g.notes[i].path.?});
        try writeLinks(out, g, i);
    }

    /// Writes a note, as a new one if no note has the name. Says where it
    /// went and what it links to, including notes not written yet.
    pub fn write(nb: Self, out: *Writer, name: []const u8, content: []const u8, mode: Mode) !void {
        if (!safeName(name)) return error.BadName;
        const relative = blk: {
            const listing = try nb.scan();
            defer listing.destroy(nb.gpa);
            if (listing.notes.named(name)) |i| break :blk try nb.gpa.dupe(u8, listing.notes.notes[i].path.?);
            break :blk try wikilink.newNotePath(nb.gpa, name, "");
        };
        defer nb.gpa.free(relative);
        const full = try std.fs.path.join(nb.gpa, &.{ nb.root, relative });
        defer nb.gpa.free(full);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(nb.gpa);
        if (mode == .append) {
            if (Dir.cwd().readFileAlloc(nb.io, full, nb.gpa, .limited(notes.max_note_bytes))) |old| {
                defer nb.gpa.free(old);
                try bytes.appendSlice(nb.gpa, old);
            } else |err| if (err != error.FileNotFound) return err;
            if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(nb.gpa, '\n');
        }
        try bytes.appendSlice(nb.gpa, content);
        if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(nb.gpa, '\n');
        if (std.fs.path.dirname(full)) |dir| try Dir.cwd().createDirPath(nb.io, dir);
        try safewrite.write(nb.io, full, bytes.items);

        try out.print("{s} {s}.\n", .{ if (mode == .append) "Added to" else "Wrote", relative });
        const after = try nb.scan();
        defer after.destroy(nb.gpa);
        if (after.notes.find(relative)) |i| try writeLinks(out, after.notes, i);
    }

    /// The lines of any note that hold `query`, ignoring case, as
    /// `path:line: text`.
    pub fn search(nb: Self, out: *Writer, query: []const u8, limit: usize) !void {
        const listing = try nb.scan();
        defer listing.destroy(nb.gpa);
        var r = nb.reader();
        defer r.deinit();
        var found: usize = 0;
        for (listing.notes.notes) |n| {
            const path = n.path orelse continue;
            const text = r.text(path) orelse continue;
            var lines = std.mem.splitScalar(u8, text, '\n');
            var number: usize = 1;
            while (lines.next()) |line| : (number += 1) {
                if (std.ascii.findIgnoreCase(line, query) == null) continue;
                found += 1;
                if (found > limit) continue;
                try out.print("{s}:{d}: {s}\n", .{ path, number, shortened(std.mem.trim(u8, line, " \t\r")) });
            }
        }
        if (found > limit) try out.print("...and {d} more.\n", .{found - limit});
        if (found == 0) try out.print("No note holds \"{s}\".\n", .{query});
    }

    /// The notes within `depth` links of a note, following links either
    /// way, nearest first.
    pub fn related(nb: Self, out: *Writer, name: []const u8, depth: usize) !void {
        const listing = try nb.scan();
        defer listing.destroy(nb.gpa);
        const g = listing.notes;
        const start = g.named(name) orelse return error.NoSuchNote;

        const unseen = std.math.maxInt(u8);
        const distance = try nb.gpa.alloc(u8, g.notes.len);
        defer nb.gpa.free(distance);
        @memset(distance, unseen);
        distance[start] = 0;
        var any = false;
        for (1..@min(depth, max_depth) + 1) |d| {
            const step: u8 = @intCast(d);
            for (g.edges) |e| {
                if (distance[e.from] == step - 1 and distance[e.to] == unseen) distance[e.to] = step;
                if (distance[e.to] == step - 1 and distance[e.from] == unseen) distance[e.from] = step;
            }
            var first = true;
            for (g.notes, distance) |n, at| {
                if (at != step) continue;
                if (first) try out.print("{d} link{s} away: ", .{ d, if (d == 1) "" else "s" }) else try out.writeAll(", ");
                try writeName(out, n);
                first = false;
                any = true;
            }
            if (!first) try out.writeByte('\n');
        }
        if (!any) try out.print("{s} links to no notes, and none link to it.\n", .{g.notes[start].path.?});
    }

    /// Deletes a note, saying which notes still link to it.
    pub fn delete(nb: Self, out: *Writer, name: []const u8) !void {
        const listing = try nb.scan();
        defer listing.destroy(nb.gpa);
        const g = listing.notes;
        const i = g.named(name) orelse return error.NoSuchNote;
        const full = try std.fs.path.join(nb.gpa, &.{ nb.root, g.notes[i].path.? });
        defer nb.gpa.free(full);
        try Dir.cwd().deleteFile(nb.io, full);
        try out.print("Deleted {s}.\n", .{g.notes[i].path.?});

        var from: std.ArrayList(u32) = .empty;
        defer from.deinit(nb.gpa);
        try g.backlinks(nb.gpa, i, &from);
        if (from.items.len == 0) return;
        try out.writeAll("These notes still link to it: ");
        for (from.items, 0..) |f, n| {
            if (n > 0) try out.writeAll(", ");
            try writeName(out, g.notes[f]);
        }
        try out.writeByte('\n');
    }
};

/// A name that keeps its note inside the folder and can be linked to.
pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (std.mem.findAny(u8, name, unsafe_characters) != null) return false;
    for (name) |c| if (c < ' ') return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        // Empty, `.`, `..` and hidden names alike.
        if (part.len == 0 or part[0] == '.') return false;
    }
    return true;
}

fn counts(g: Graph, i: u32) struct { in: usize, out: usize } {
    var in: usize = 0;
    var out: usize = 0;
    for (g.edges) |e| {
        if (e.to == i) in += 1;
        if (e.from == i) out += 1;
    }
    return .{ .in = in, .out = out };
}

fn writeLinks(out: *Writer, g: Graph, i: u32) !void {
    for ([_]bool{ true, false }) |outgoing| {
        try out.writeAll(if (outgoing) "Links to: " else "Linked from: ");
        var any = false;
        for (g.edges) |e| {
            const other = if (outgoing and e.from == i) e.to else if (!outgoing and e.to == i) e.from else continue;
            if (any) try out.writeAll(", ");
            try writeName(out, g.notes[other]);
            any = true;
        }
        try out.writeAll(if (any) "\n" else "none\n");
    }
}

fn writeName(out: *Writer, n: notes.Note) !void {
    try out.print("[[{s}]]", .{n.name});
    if (n.path == null) try out.writeAll(" (not written yet)");
}

/// At most `max_shown_line` bytes, never ending part way through a
/// character.
fn shortened(line: []const u8) []const u8 {
    if (line.len <= max_shown_line) return line;
    var end: usize = max_shown_line;
    while (end > 0 and line[end] & 0xC0 == 0x80) end -= 1;
    return line[0..end];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root_buf: [Dir.max_path_bytes]u8 = undefined,
    nb: Notebook = undefined,
    out: std.Io.Writer.Allocating,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.out = .init(testing.allocator);
        const root = f.root_buf[0..try f.tmp.dir.realPath(testing.io, &f.root_buf)];
        f.nb = .{ .gpa = testing.allocator, .io = testing.io, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.out.deinit();
        f.tmp.cleanup();
    }

    /// What the last call wrote, cleared for the next.
    fn said(f: *Fixture) []const u8 {
        defer f.out.clearRetainingCapacity();
        return f.out.written();
    }
};

test "notes are written, read back with their links, and appended to" {
    var f = Fixture{ .tmp = undefined, .out = undefined };
    try f.init();
    defer f.deinit();
    const out = &f.out.writer;

    try f.nb.write(out, "people/Ada", "Ada wrote the first program. See [[Babbage]].", .replace);
    try testing.expect(std.mem.find(u8, f.said(), "Links to: [[Babbage]] (not written yet)") != null);
    try f.nb.write(out, "Babbage", "Built engines with [[Ada]].", .replace);
    _ = f.said();
    try f.nb.write(out, "ada", "Also a mathematician.", .append);
    try testing.expect(std.mem.startsWith(u8, f.said(), "Added to people/Ada.md."));

    try f.nb.read(out, "Ada");
    const ada = f.said();
    try testing.expect(std.mem.startsWith(u8, ada, "Ada wrote the first program. See [[Babbage]].\nAlso a mathematician.\n"));
    try testing.expect(std.mem.find(u8, ada, "Linked from: [[Babbage]]") != null);
    try testing.expectError(error.NoSuchNote, f.nb.read(out, "Lovelace"));
}

test "names that would leave the folder or cannot be linked are refused" {
    var f = Fixture{ .tmp = undefined, .out = undefined };
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "", "../escape", "a/../../b", "/etc/x", ".hidden", "C:\\x", "a|b", "line\nbreak" }) |bad| {
        try testing.expectError(error.BadName, f.nb.write(&f.out.writer, bad, "x", .replace));
    }
    try testing.expect(safeName("people/Ada Lovelace"));
}

test "notes are listed, searched, followed through their links, and deleted" {
    var f = Fixture{ .tmp = undefined, .out = undefined };
    try f.init();
    defer f.deinit();
    const out = &f.out.writer;
    try f.nb.write(out, "a", "Links to [[b]].", .replace);
    try f.nb.write(out, "b", "Links to [[c]]. The Needle is here.", .replace);
    try f.nb.write(out, "c", "Plain.", .replace);
    _ = f.said();

    try f.nb.list(out, "", default_limit);
    try testing.expectEqualStrings("a.md (0 in, 1 out)\nb.md (1 in, 1 out)\nc.md (1 in, 0 out)\n", f.said());
    try f.nb.search(out, "needle", default_limit);
    try testing.expectEqualStrings("b.md:1: Links to [[c]]. The Needle is here.\n", f.said());
    try f.nb.related(out, "a", 2);
    try testing.expectEqualStrings("1 link away: [[b]]\n2 links away: [[c]]\n", f.said());

    try f.nb.delete(out, "b");
    try testing.expectEqualStrings("Deleted b.md.\nThese notes still link to it: [[a]]\n", f.said());
    try f.nb.list(out, "", default_limit);
    try testing.expectEqualStrings("a.md (0 in, 1 out)\nc.md (0 in, 0 out)\nLinked to, but not written yet: [[b]]\n", f.said());
}
