//! Links between notes, written `[[name]]` as in Obsidian: finding them in
//! Markdown and working out which file each one means.

const std = @import("std");

pub const Link = struct {
    /// What it points to, without any `|alias` or `#heading`.
    target: []const u8,
    /// Where the whole `[[...]]` starts and ends.
    start: usize,
    end: usize,
};

pub const note_extension = ".md";

/// The links in a Markdown text, skipping code: fenced blocks and spans in
/// backticks, where `[[` is usually just code.
pub const Iterator = struct {
    text: []const u8,
    /// Where the line being read starts.
    line: usize = 0,
    /// How far into it the reading has got.
    pos: usize = 0,
    in_fence: bool = false,

    pub fn next(it: *Iterator) ?Link {
        while (it.line < it.text.len) {
            const line_end = std.mem.findScalarPos(u8, it.text, it.line, '\n') orelse it.text.len;
            if (it.pos == it.line and isFence(it.text[it.line..line_end])) {
                it.in_fence = !it.in_fence;
            } else if (!it.in_fence) {
                if (scan(it.text, it.pos, line_end)) |link| {
                    it.pos = link.end;
                    return link;
                }
            }
            it.line = line_end + 1;
            it.pos = it.line;
        }
        return null;
    }
};

/// The link that byte `offset` of `line` falls in.
pub fn at(line: []const u8, offset: usize) ?Link {
    var it = Iterator{ .text = line };
    while (it.next()) |link| {
        if (offset >= link.start and offset < link.end) return link;
        if (link.start > offset) break;
    }
    return null;
}

fn isFence(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3) return false;
    return std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
}

/// The first link between `from` and `end`, on one line.
fn scan(text: []const u8, from: usize, end: usize) ?Link {
    var i = from;
    while (i < end) {
        switch (text[i]) {
            '\\' => i += 2,
            '`' => i = pastCodeSpan(text, i, end),
            '[' => {
                if (i + 1 < end and text[i + 1] == '[') {
                    if (linkAt(text, i, end)) |link| return link;
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// Past a span opened by a run of backticks, closed by a run as long.
fn pastCodeSpan(text: []const u8, start: usize, end: usize) usize {
    var run = start;
    while (run < end and text[run] == '`') run += 1;
    const opener = text[start..run];
    var i = run;
    while (std.mem.findPos(u8, text[0..end], i, opener)) |close| {
        var after = close + opener.len;
        // A longer run is not the closer.
        if (after < end and text[after] == '`') {
            while (after < end and text[after] == '`') after += 1;
            i = after;
            continue;
        }
        return after;
    }
    return run;
}

fn linkAt(text: []const u8, start: usize, end: usize) ?Link {
    const inner_start = start + 2;
    const close = std.mem.findPos(u8, text[0..end], inner_start, "]]") orelse return null;
    const inner = text[inner_start..close];
    if (std.mem.findAny(u8, inner, "[]") != null) return null;
    const named = inner[0 .. std.mem.findScalar(u8, inner, '|') orelse inner.len];
    const target = std.mem.trim(u8, named[0 .. std.mem.findAny(u8, named, "#^") orelse named.len], " \t");
    // `[[#heading]]` points into the same note.
    if (target.len == 0) return null;
    return .{ .target = target, .start = start, .end = close + 2 };
}

/// A path or link target, without the note extension, to compare by.
pub fn key(path: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(path, note_extension)) return path[0 .. path.len - note_extension.len];
    return path;
}

pub fn isNote(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, note_extension);
}

/// Whether `path`, relative to the folder, is a file `target` can name:
/// by its name alone, or by the end of its path, ignoring case.
pub fn matches(path: []const u8, target: []const u8) bool {
    const p = key(path);
    const t = key(target);
    if (std.ascii.eqlIgnoreCase(p, t)) return true;
    return p.len > t.len and p[p.len - t.len - 1] == '/' and std.ascii.endsWithIgnoreCase(p, t);
}

/// Of two files a target matches, whether `a` is the one meant: the one
/// beside the linking note, else the one nearest the top of the folder.
pub fn preferred(a: []const u8, b: []const u8, from: []const u8) bool {
    const here = folderOf(from);
    const a_here = std.mem.eql(u8, folderOf(a), here);
    if (a_here != std.mem.eql(u8, folderOf(b), here)) return a_here;
    return depth(a) < depth(b);
}

/// The file in `files` that `target`, linked from `from`, means.
pub fn resolve(files: []const []const u8, target: []const u8, from: []const u8) ?usize {
    var best: ?usize = null;
    for (files, 0..) |f, i| {
        if (!matches(f, target)) continue;
        if (best == null or preferred(f, files[best.?], from)) best = i;
    }
    return best;
}

/// Where a note a link names, but no file has yet, is made: beside the
/// linking note, or as its path says. Caller frees.
pub fn newNotePath(gpa: std.mem.Allocator, target: []const u8, from: []const u8) ![]u8 {
    const folder = if (std.mem.findScalar(u8, target, '/') != null) "" else folderOf(from);
    const sep = if (folder.len > 0) "/" else "";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ folder, sep, key(target), note_extension });
}

fn folderOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.findScalarLast(u8, path, '/') orelse 0];
}

fn depth(path: []const u8) usize {
    return std.mem.count(u8, path, "/");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn targets(text: []const u8, out: *std.ArrayList(u8)) !void {
    var it = Iterator{ .text = text };
    while (it.next()) |link| {
        try out.appendSlice(testing.allocator, link.target);
        try out.append(testing.allocator, '|');
    }
}

test "links are found with their aliases and headings dropped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try targets("See [[Alpha]], [[beta|the second]] and [[ gamma#Intro ]].\n![[pic.png]]", &out);
    try testing.expectEqualStrings("Alpha|beta|gamma|pic.png|", out.items);
}

test "code, broken brackets and links into the same note are not links" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const text =
        \\`[[span]]` and ``a ` [[double]]`` then [[real]]
        \\```python
        \\x = [[1, 2], [3]]
        \\[[fenced]]
        \\```
        \\[[#heading]] [[a [b]] [[open
        \\\[[escaped]] [[after]]
    ;
    try targets(text, &out);
    try testing.expectEqualStrings("real|after|", out.items);
}

test "the link under a position is found" {
    const line = "go to [[one]] or [[two|2]]";
    try testing.expectEqualStrings("one", at(line, 8).?.target);
    try testing.expectEqualStrings("two", at(line, line.len - 1).?.target);
    try testing.expect(at(line, 2) == null);
    try testing.expect(at(line, 14) == null);
}

test "a target means a file by name or by the end of its path" {
    try testing.expect(matches("notes/Alpha.md", "alpha"));
    try testing.expect(matches("notes/Alpha.md", "notes/alpha.md"));
    try testing.expect(matches("img/pic.png", "pic.png"));
    try testing.expect(!matches("notes/Alpha.md", "pha"));
    try testing.expect(!matches("notes/Alpha.md", "other/alpha"));
}

test "of several files with one name, the nearest is meant" {
    const files = [_][]const u8{ "a/deep/x.md", "x.md", "b/x.md", "b/y.md" };
    try testing.expectEqual(@as(?usize, 2), resolve(&files, "x", "b/y.md"));
    try testing.expectEqual(@as(?usize, 1), resolve(&files, "x", "c/z.md"));
    try testing.expectEqual(@as(?usize, 0), resolve(&files, "deep/x", "b/y.md"));
    try testing.expect(resolve(&files, "missing", "x.md") == null);
}

test "a new note goes beside the one linking to it" {
    const gpa = testing.allocator;
    const beside = try newNotePath(gpa, "Idea", "notes/today.md");
    defer gpa.free(beside);
    try testing.expectEqualStrings("notes/Idea.md", beside);
    const top = try newNotePath(gpa, "Idea.md", "today.md");
    defer gpa.free(top);
    try testing.expectEqualStrings("Idea.md", top);
    const placed = try newNotePath(gpa, "people/Ada", "notes/today.md");
    defer gpa.free(placed);
    try testing.expectEqualStrings("people/Ada.md", placed);
}
