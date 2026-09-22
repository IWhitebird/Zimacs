//! The open files, in tab order.
//!
//! Each one is a `BufferView`: its text in a piece tree, plus the caret, the
//! undo history, and which line sits at the top of the screen. Opening a path
//! that is already open just switches to it.
//!
//! Every change to the text goes through `BufferView.edit`, the only place
//! that touches the tree, moves the caret and records undo - so those three
//! can never fall out of step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Artifact = @import("artifact.zig").Artifact;
const PieceTree = @import("piecetree.zig").PieceTree;
const Cursor = @import("cursor.zig").Cursor;
const History = @import("history.zig").History;
const text_mod = @import("text.zig");

/// Refuse anything larger. Piece tree offsets are u32, so 4 GiB is the hard
/// ceiling; this sits well below it.
const max_bytes = 512 * 1024 * 1024;

pub const BufferView = struct {
    gpa: Allocator,
    tree: PieceTree,
    cursor: Cursor = .{},
    history: History,
    /// First line drawn at the top of the screen.
    top_line: u32 = 0,
    /// First column drawn, for horizontal scrolling.
    left_column: u32 = 0,
    /// Which wrapped row of `top_line` sits at the top, when wrapping is on.
    top_row: u32 = 0,
    /// Widest line currently on screen, in columns. Sizes the horizontal
    /// scrollbar; measuring every line of a large file each frame would cost
    /// far more than it is worth.
    content_columns: u32 = 1,
    /// The caret position the view last scrolled to.
    ///
    /// Scrolling only chases the caret when it has actually moved. Doing it
    /// every frame would undo the scrollbar and the mouse wheel the moment
    /// the caret left the screen.
    followed: ?u32 = null,
    /// Where the file lives, or null if it has never been saved. Owned.
    path: ?[]const u8 = null,
    /// What the tab shows. Owned.
    name: []const u8,
    /// The point in the undo history that matches what is on disk.
    saved_at: usize = 0,

    const Self = @This();

    /// True when the text differs from the file on disk.
    pub fn edited(v: Self) bool {
        return v.history.applied != v.saved_at;
    }

    pub fn cursorLine(v: *const Self) u32 {
        return v.cursor.position(&v.tree).line;
    }

    pub fn deinit(v: *Self) void {
        v.tree.deinit();
        v.history.deinit();
        if (v.path) |p| v.gpa.free(p);
        v.gpa.free(v.name);
    }

    /// Replaces `len` bytes at `offset` with `text` and records it for undo.
    pub fn edit(v: *Self, offset: u32, len: u32, text: []const u8) !void {
        var removed: std.ArrayList(u8) = .empty;
        defer removed.deinit(v.gpa);
        if (len > 0) try v.tree.copy(offset, len, &removed);

        const before = v.cursor.offset;
        if (len > 0) try v.tree.delete(offset, len);
        if (text.len > 0) try v.tree.insert(offset, text);

        v.cursor.offset = offset + @as(u32, @intCast(text.len));
        v.cursor.afterEdit(&v.tree);
        try v.history.record(offset, removed.items, text, before, v.cursor.offset);
    }

    /// Inserts text, replacing the selection if there is one.
    pub fn insert(v: *Self, text: []const u8) !void {
        if (v.cursor.selection()) |r| return v.edit(r.start, r.len(), text);
        try v.edit(v.cursor.offset, 0, text);
    }

    pub fn backspace(v: *Self) !void {
        if (v.cursor.selection()) |r| return v.edit(r.start, r.len(), "");
        if (v.cursor.offset == 0) return;
        const start = v.charStartBefore(v.cursor.offset);
        try v.edit(start, v.cursor.offset - start, "");
    }

    pub fn deleteForward(v: *Self) !void {
        if (v.cursor.selection()) |r| return v.edit(r.start, r.len(), "");
        if (v.cursor.offset >= v.tree.len()) return;
        try v.edit(v.cursor.offset, v.charEndAfter(v.cursor.offset) - v.cursor.offset, "");
    }

    /// Deletes the word before the caret, the way Ctrl+Backspace does: any
    /// run of spaces first, then the word itself.
    pub fn deleteWordBefore(v: *Self) !void {
        if (v.cursor.selection()) |r| return v.edit(r.start, r.len(), "");
        if (v.cursor.offset == 0) return;

        var at = v.cursor.offset;
        while (at > 0 and !text_mod.isWord(v.tree.byteAt(at - 1) orelse 0)) at -= 1;
        while (at > 0 and text_mod.isWord(v.tree.byteAt(at - 1) orelse 0)) at -= 1;
        // A run of spaces alone still deletes something.
        if (at == v.cursor.offset) at -= 1;
        try v.edit(at, v.cursor.offset - at, "");
    }

    pub fn deleteWordAfter(v: *Self) !void {
        if (v.cursor.selection()) |r| return v.edit(r.start, r.len(), "");
        const total = v.tree.len();
        if (v.cursor.offset >= total) return;

        var at = v.cursor.offset;
        while (at < total and text_mod.isWord(v.tree.byteAt(at) orelse 0)) at += 1;
        while (at < total and !text_mod.isWord(v.tree.byteAt(at) orelse 0)) at += 1;
        if (at == v.cursor.offset) at += 1;
        try v.edit(v.cursor.offset, at - v.cursor.offset, "");
    }

    /// Removes the caret's line, newline included.
    pub fn deleteLine(v: *Self) !void {
        const line = v.cursorLine();
        const start = v.tree.lineStart(line);
        const end = @min(v.tree.lineEnd(line) + 1, v.tree.len());
        try v.edit(start, end - start, "");
    }

    /// Copies the caret's line onto the line below it.
    pub fn duplicateLine(v: *Self) !void {
        const line = v.cursorLine();
        const start = v.tree.lineStart(line);
        const end = v.tree.lineEnd(line);

        var copied: std.ArrayList(u8) = .empty;
        defer copied.deinit(v.gpa);
        try copied.append(v.gpa, '\n');
        if (end > start) try v.tree.copy(start, end - start, &copied);

        const was = v.cursor.offset;
        try v.edit(end, 0, copied.items);
        // Stay on the same column, one line further down.
        v.cursor.offset = was + @as(u32, @intCast(copied.items.len));
        v.cursor.afterEdit(&v.tree);
    }

    /// Swaps the caret's line with the one above or below, taking the caret
    /// with it.
    pub fn moveLine(v: *Self, direction: enum { up, down }) !void {
        const line = v.cursorLine();
        const last = v.tree.lineCount() - 1;
        if (direction == .up and line == 0) return;
        if (direction == .down and line >= last) return;

        const first = if (direction == .up) line - 1 else line;
        const column = v.cursor.offset - v.tree.lineStart(line);

        const start = v.tree.lineStart(first);
        const end = @min(v.tree.lineEnd(first + 1) + 1, v.tree.len());

        var upper: std.ArrayList(u8) = .empty;
        defer upper.deinit(v.gpa);
        var lower: std.ArrayList(u8) = .empty;
        defer lower.deinit(v.gpa);

        const middle = v.tree.lineStart(first + 1);
        try v.tree.copy(start, middle - start, &upper);
        try v.tree.copy(middle, end - middle, &lower);

        // The pair is rewritten in one edit, so one undo puts it back.
        var swapped: std.ArrayList(u8) = .empty;
        defer swapped.deinit(v.gpa);
        try swapped.appendSlice(v.gpa, trimNewline(lower.items));
        try swapped.append(v.gpa, '\n');
        try swapped.appendSlice(v.gpa, trimNewline(upper.items));
        if (end == v.tree.len() and !endsWithNewline(lower.items)) {
            // Nothing: the block did not end in a newline, so neither does it now.
        } else {
            try swapped.append(v.gpa, '\n');
        }

        try v.edit(start, end - start, swapped.items);

        const moved = if (direction == .up) first else first + 1;
        v.cursor.offset = v.tree.lineStart(moved) + @min(column, v.tree.lineLen(moved));
        v.cursor.afterEdit(&v.tree);
    }

    /// Starts a fresh line below the caret's, wherever the caret sits.
    pub fn openLineBelow(v: *Self) !void {
        const end = v.tree.lineEnd(v.cursorLine());
        try v.edit(end, 0, "\n");
    }

    /// Starts a fresh line above the caret's.
    pub fn openLineAbove(v: *Self) !void {
        const start = v.tree.lineStart(v.cursorLine());
        try v.edit(start, 0, "\n");
        v.cursor.offset = start;
        v.cursor.afterEdit(&v.tree);
    }

    /// The lines the selection touches, or just the caret's line.
    pub fn selectedLines(v: *const Self) struct { first: u32, last: u32 } {
        const range = v.cursor.selection() orelse {
            const line = v.cursorLine();
            return .{ .first = line, .last = line };
        };
        const first = v.tree.positionAt(range.start).line;
        var last = v.tree.positionAt(range.end).line;
        // A selection ending exactly at a line start does not include it.
        if (last > first and range.end == v.tree.lineStart(last)) last -= 1;
        return .{ .first = first, .last = last };
    }

    /// Adds `width` spaces to the front of every selected line, as one edit so
    /// a single undo takes it back.
    pub fn indentLines(v: *Self, width: u8) !void {
        const lines = v.selectedLines();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(v.gpa);

        var line = lines.first;
        while (line <= lines.last) : (line += 1) {
            try out.appendNTimes(v.gpa, ' ', width);
            try v.appendLineWithBreak(&out, line, lines.last);
        }
        try v.replaceLines(lines.first, lines.last, out.items);
    }

    /// Removes up to `width` leading spaces (or one tab) from every selected
    /// line.
    pub fn outdentLines(v: *Self, width: u8) !void {
        const lines = v.selectedLines();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(v.gpa);

        var line = lines.first;
        while (line <= lines.last) : (line += 1) {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(v.gpa);
            try v.tree.lineContent(line, &body);

            var strip: usize = 0;
            if (body.items.len > 0 and body.items[0] == '\t') {
                strip = 1;
            } else {
                while (strip < width and strip < body.items.len and body.items[strip] == ' ') strip += 1;
            }
            try out.appendSlice(v.gpa, body.items[strip..]);
            if (line < lines.last or v.tree.lineEnd(line) < v.tree.len()) try out.append(v.gpa, '\n');
        }
        try v.replaceLines(lines.first, lines.last, out.items);
    }

    fn appendLineWithBreak(v: *Self, out: *std.ArrayList(u8), line: u32, last: u32) !void {
        const start = v.tree.lineStart(line);
        const end = v.tree.lineEnd(line);
        if (end > start) try v.tree.copy(start, end - start, out);
        if (line < last or end < v.tree.len()) try out.append(v.gpa, '\n');
    }

    /// Rewrites a run of lines in one edit, keeping the selection over them.
    fn replaceLines(v: *Self, first: u32, last: u32, replacement: []const u8) !void {
        const start = v.tree.lineStart(first);
        const end = @min(v.tree.lineEnd(last) + 1, v.tree.len());
        try v.edit(start, end - start, replacement);

        v.cursor.anchor = start;
        v.cursor.offset = start + @as(u32, @intCast(replacement.len));
    }

    pub fn deleteSelection(v: *Self) !void {
        const r = v.cursor.selection() orelse return;
        try v.edit(r.start, r.len(), "");
    }

    /// Appends the selected text to `out`. Nothing if there is no selection.
    pub fn selectedText(v: *const Self, out: *std.ArrayList(u8)) !void {
        const r = v.cursor.selection() orelse return;
        try v.tree.copy(r.start, r.len(), out);
    }

    pub fn undo(v: *Self) !void {
        const e = v.history.undo() orelse return;
        if (e.inserted.len > 0) try v.tree.delete(e.offset, @intCast(e.inserted.len));
        if (e.removed.len > 0) try v.tree.insert(e.offset, e.removed);
        v.cursor.offset = e.cursor_before;
        v.cursor.afterEdit(&v.tree);
    }

    pub fn redo(v: *Self) !void {
        const e = v.history.redo() orelse return;
        if (e.removed.len > 0) try v.tree.delete(e.offset, @intCast(e.removed.len));
        if (e.inserted.len > 0) try v.tree.insert(e.offset, e.inserted);
        v.cursor.offset = e.cursor_after;
        v.cursor.afterEdit(&v.tree);
    }

    /// Steps back over a whole character, so multi-byte text is not split.
    fn charStartBefore(v: *const Self, offset: u32) u32 {
        var i = offset - 1;
        while (i > 0 and isTrailingByte(v.tree.byteAt(i) orelse 0)) i -= 1;
        return i;
    }

    fn charEndAfter(v: *const Self, offset: u32) u32 {
        var i = offset + 1;
        while (i < v.tree.len() and isTrailingByte(v.tree.byteAt(i) orelse 0)) i += 1;
        return i;
    }
};

pub const Buffer = struct {
    /// Set by the app before `init`, so this file needs nothing from it.
    gpa: Allocator = undefined,
    /// Null where there is no filesystem, as on the web.
    io: ?std.Io = null,

    views: std.ArrayList(*BufferView) = .empty,
    active: usize = 0,
    untitled_count: u32 = 0,

    const Self = @This();

    const table = Artifact.Table{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(b: *Self) Artifact {
        return .{ .ctx = @ptrCast(b), .table = &table, .name = "Buffer" };
    }

    pub fn init(ctx: *anyopaque) !void {
        _ = ctx;
    }

    pub fn deinit(ctx: *anyopaque) !void {
        const b: *Self = @ptrCast(@alignCast(ctx));
        for (b.views.items) |v| {
            v.deinit();
            b.gpa.destroy(v);
        }
        b.views.deinit(b.gpa);
    }

    /// Holds state only; the Editor draws it.
    pub fn render(ctx: *anyopaque) !void {
        _ = ctx;
    }

    pub fn current(b: *const Self) ?*BufferView {
        if (b.views.items.len == 0) return null;
        return b.views.items[@min(b.active, b.views.items.len - 1)];
    }

    pub fn select(b: *Self, index: usize) void {
        if (index < b.views.items.len) b.active = index;
    }

    pub fn next(b: *Self) void {
        if (b.views.items.len == 0) return;
        b.active = (b.active + 1) % b.views.items.len;
    }

    pub fn previous(b: *Self) void {
        if (b.views.items.len == 0) return;
        b.active = (b.active + b.views.items.len - 1) % b.views.items.len;
    }

    /// An empty unnamed buffer, so there is always somewhere to type.
    pub fn newScratch(b: *Self) !*BufferView {
        b.untitled_count += 1;
        const name = try std.fmt.allocPrint(b.gpa, "untitled {d}", .{b.untitled_count});
        errdefer b.gpa.free(name);
        return b.add(try PieceTree.init(b.gpa), null, name);
    }

    /// Switches to `path` if it is already open, otherwise reads it.
    pub fn openOrSelect(b: *Self, path: []const u8) !void {
        for (b.views.items, 0..) |v, i| {
            if (v.path) |p| {
                if (std.mem.eql(u8, p, path)) {
                    b.active = i;
                    return;
                }
            }
        }

        const io = b.io orelse return error.NoFilesystem;
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, b.gpa, .limited(max_bytes));
        defer b.gpa.free(raw);

        const text = try toUnixNewlines(b.gpa, raw);
        defer b.gpa.free(text);

        const owned_path = try b.gpa.dupe(u8, path);
        errdefer b.gpa.free(owned_path);
        const name = try b.gpa.dupe(u8, std.fs.path.basename(owned_path));
        errdefer b.gpa.free(name);

        _ = try b.add(try PieceTree.initFromBytes(b.gpa, text), owned_path, name);
    }

    /// Opens a buffer holding `text` that remembers `path`. Used when a saved
    /// session is restored.
    pub fn restore(b: *Self, path: ?[]const u8, name: []const u8, text: []const u8) !*BufferView {
        const owned_path = if (path) |p| try b.gpa.dupe(u8, p) else null;
        errdefer if (owned_path) |p| b.gpa.free(p);
        const owned_name = try b.gpa.dupe(u8, name);
        errdefer b.gpa.free(owned_name);
        return b.add(try PieceTree.initFromBytes(b.gpa, text), owned_path, owned_name);
    }

    fn add(b: *Self, tree: PieceTree, path: ?[]const u8, name: []const u8) !*BufferView {
        const view = try b.gpa.create(BufferView);
        errdefer b.gpa.destroy(view);
        view.* = .{
            .gpa = b.gpa,
            .tree = tree,
            .history = .{ .gpa = b.gpa },
            .path = path,
            .name = name,
        };
        try b.views.append(b.gpa, view);
        b.active = b.views.items.len - 1;
        return view;
    }

    /// Closes a tab. Always leaves at least one buffer open.
    pub fn close(b: *Self, index: usize) !void {
        if (index >= b.views.items.len) return;
        const view = b.views.orderedRemove(index);
        view.deinit();
        b.gpa.destroy(view);

        if (b.views.items.len == 0) {
            _ = try b.newScratch();
            return;
        }
        if (b.active >= b.views.items.len) b.active = b.views.items.len - 1;
    }

    pub fn save(b: *Self, view: *BufferView) !void {
        const io = b.io orelse return error.NoFilesystem;
        const path = view.path orelse return error.NoFileName;
        const text = try view.tree.allocText(b.gpa);
        defer b.gpa.free(text);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        view.saved_at = view.history.applied;
    }

    pub fn saveAs(b: *Self, view: *BufferView, path: []const u8) !void {
        const owned_path = try b.gpa.dupe(u8, path);
        errdefer b.gpa.free(owned_path);
        const name = try b.gpa.dupe(u8, std.fs.path.basename(owned_path));
        errdefer b.gpa.free(name);

        if (view.path) |old| b.gpa.free(old);
        b.gpa.free(view.name);
        view.path = owned_path;
        view.name = name;
        try b.save(view);
    }
};

fn trimNewline(line: []const u8) []const u8 {
    return if (endsWithNewline(line)) line[0 .. line.len - 1] else line;
}

fn endsWithNewline(line: []const u8) bool {
    return line.len > 0 and line[line.len - 1] == '\n';
}

/// A UTF-8 byte that continues the character before it.
fn isTrailingByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// Turns CRLF into LF. A lone CR is left alone, since it can legitimately
/// appear in text.
///
/// A CRLF file will therefore not save back byte-identical. Carrying CRLF
/// through the piece tree means a piece boundary can split the pair, which is
/// complexity we have not taken on.
pub fn toUnixNewlines(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        out.appendAssumeCapacity(bytes[i]);
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testView(text: []const u8) !BufferView {
    const gpa = testing.allocator;
    return .{
        .gpa = gpa,
        .tree = try PieceTree.initFromBytes(gpa, text),
        .history = .{ .gpa = gpa },
        .name = try gpa.dupe(u8, "test"),
    };
}

fn textOf(v: *const BufferView) ![]u8 {
    return v.tree.allocText(testing.allocator);
}

test "insert moves the caret past the new text" {
    var v = try testView("ac");
    defer v.deinit();
    v.cursor.offset = 1;

    try v.insert("b");
    try testing.expectEqual(@as(u32, 2), v.cursor.offset);
    try testing.expect(v.edited());

    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "abc", text);
}

test "backspace deletes one character and stops at the start" {
    var v = try testView("abc");
    defer v.deinit();
    v.cursor.offset = 2;

    try v.backspace();
    try testing.expectEqual(@as(u32, 1), v.cursor.offset);
    try testing.expectEqual(@as(u32, 2), v.tree.len());

    v.cursor.offset = 0;
    try v.backspace();
    try testing.expectEqual(@as(u32, 2), v.tree.len());
}

test "backspace removes a whole multi-byte character" {
    var v = try testView("e\u{00e9}");
    defer v.deinit();
    v.cursor.offset = v.tree.len();

    try v.backspace();
    try testing.expectEqual(@as(u32, 1), v.tree.len());
}

test "deleteForward stops at the end" {
    var v = try testView("abc");
    defer v.deinit();
    v.cursor.offset = 1;

    try v.deleteForward();
    try testing.expectEqual(@as(u32, 2), v.tree.len());

    v.cursor.offset = v.tree.len();
    try v.deleteForward();
    try testing.expectEqual(@as(u32, 2), v.tree.len());
}

test "typing over a selection replaces it" {
    var v = try testView("hello world");
    defer v.deinit();
    v.cursor.anchor = 0;
    v.cursor.offset = 5;

    try v.insert("bye");
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "bye world", text);
    try testing.expect(!v.cursor.hasSelection());
}

test "backspace over a selection deletes all of it" {
    var v = try testView("hello world");
    defer v.deinit();
    v.cursor.anchor = 5;
    v.cursor.offset = 11;

    try v.backspace();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "hello", text);
}

test "selected text can be read out" {
    var v = try testView("hello world");
    defer v.deinit();
    v.cursor.anchor = 6;
    v.cursor.offset = 11;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try v.selectedText(&out);
    try testing.expectEqualSlices(u8, "world", out.items);
}

test "undo and redo restore the text and the caret" {
    var v = try testView("abc");
    defer v.deinit();
    v.cursor.offset = 3;

    try v.insert("XYZ");
    {
        const text = try textOf(&v);
        defer testing.allocator.free(text);
        try testing.expectEqualSlices(u8, "abcXYZ", text);
    }

    try v.undo();
    {
        const text = try textOf(&v);
        defer testing.allocator.free(text);
        try testing.expectEqualSlices(u8, "abc", text);
        try testing.expectEqual(@as(u32, 3), v.cursor.offset);
    }

    try v.redo();
    {
        const text = try textOf(&v);
        defer testing.allocator.free(text);
        try testing.expectEqualSlices(u8, "abcXYZ", text);
        try testing.expectEqual(@as(u32, 6), v.cursor.offset);
    }
}

test "undo of a deletion puts the text back" {
    var v = try testView("hello world");
    defer v.deinit();
    v.cursor.anchor = 0;
    v.cursor.offset = 6;

    try v.deleteSelection();
    {
        const text = try textOf(&v);
        defer testing.allocator.free(text);
        try testing.expectEqualSlices(u8, "world", text);
    }

    try v.undo();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "hello world", text);
}

test "undoing back to the saved point clears the edited flag" {
    var v = try testView("abc");
    defer v.deinit();
    try testing.expect(!v.edited());

    try v.insert("d");
    try testing.expect(v.edited());

    try v.undo();
    try testing.expect(!v.edited());
}

test "deleteWordBefore takes the word and the spaces before it" {
    var v = try testView("hello big world");
    defer v.deinit();
    v.cursor.offset = 15;

    try v.deleteWordBefore();
    var text = try textOf(&v);
    try testing.expectEqualSlices(u8, "hello big ", text);
    testing.allocator.free(text);

    try v.deleteWordBefore();
    text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "hello ", text);
}

test "deleteWordBefore stops at the start" {
    var v = try testView("abc");
    defer v.deinit();
    v.cursor.offset = 0;
    try v.deleteWordBefore();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "abc", text);
}

test "deleteWordAfter takes the word and the spaces after it" {
    var v = try testView("hello big world");
    defer v.deinit();
    v.cursor.offset = 0;

    try v.deleteWordAfter();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "big world", text);
}

test "deleteLine removes the whole line" {
    var v = try testView("one\ntwo\nthree\n");
    defer v.deinit();
    v.cursor.offset = 5; // on "two"

    try v.deleteLine();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\nthree\n", text);
}

test "duplicateLine copies it below and keeps the column" {
    var v = try testView("one\ntwo\n");
    defer v.deinit();
    v.cursor.offset = 5; // column 1 of "two"

    try v.duplicateLine();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\ntwo\ntwo\n", text);
    try testing.expectEqual(@as(u32, 2), v.cursorLine());
    try testing.expectEqual(@as(u32, 1), v.cursor.position(&v.tree).column);
}

test "moveLine swaps with the neighbour and carries the caret" {
    var v = try testView("one\ntwo\nthree\n");
    defer v.deinit();
    v.cursor.offset = 4; // start of "two"

    try v.moveLine(.up);
    var text = try textOf(&v);
    try testing.expectEqualSlices(u8, "two\none\nthree\n", text);
    try testing.expectEqual(@as(u32, 0), v.cursorLine());
    testing.allocator.free(text);

    try v.moveLine(.down);
    text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\ntwo\nthree\n", text);
    try testing.expectEqual(@as(u32, 1), v.cursorLine());
}

test "moveLine does nothing at the ends" {
    var v = try testView("one\ntwo\n");
    defer v.deinit();

    v.cursor.offset = 0;
    try v.moveLine(.up);
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\ntwo\n", text);
}

test "openLineBelow starts a new line from anywhere on the line" {
    var v = try testView("hello");
    defer v.deinit();
    v.cursor.offset = 2;

    try v.openLineBelow();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "hello\n", text);
    try testing.expectEqual(@as(u32, 1), v.cursorLine());
}

test "openLineAbove puts the caret on the new line" {
    var v = try testView("one\ntwo\n");
    defer v.deinit();
    v.cursor.offset = 5; // on "two"

    try v.openLineAbove();
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\n\ntwo\n", text);
    try testing.expectEqual(@as(u32, 1), v.cursorLine());
}

test "selectedLines covers what the selection touches" {
    var v = try testView("one\ntwo\nthree\nfour\n");
    defer v.deinit();

    v.cursor.offset = 5;
    var lines = v.selectedLines();
    try testing.expectEqual(@as(u32, 1), lines.first);
    try testing.expectEqual(@as(u32, 1), lines.last);

    v.cursor.anchor = 5; // inside "two"
    v.cursor.offset = 10; // inside "three"
    lines = v.selectedLines();
    try testing.expectEqual(@as(u32, 1), lines.first);
    try testing.expectEqual(@as(u32, 2), lines.last);

    // Ending exactly on a line start does not pull that line in.
    v.cursor.anchor = 4;
    v.cursor.offset = 8;
    lines = v.selectedLines();
    try testing.expectEqual(@as(u32, 1), lines.first);
    try testing.expectEqual(@as(u32, 1), lines.last);
}

test "indent and outdent a block" {
    var v = try testView("one\ntwo\nthree\n");
    defer v.deinit();
    v.cursor.anchor = 0;
    v.cursor.offset = 8; // "one" and "two"

    try v.indentLines(2);
    var text = try textOf(&v);
    try testing.expectEqualSlices(u8, "  one\n  two\nthree\n", text);
    testing.allocator.free(text);

    try v.outdentLines(2);
    text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\ntwo\nthree\n", text);
}

test "outdent removes a tab or stops at the margin" {
    var v = try testView("\ttabbed\n  spaced\nflush\n");
    defer v.deinit();
    v.cursor.anchor = 0;
    v.cursor.offset = v.tree.len();

    try v.outdentLines(4);
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "tabbed\nspaced\nflush\n", text);
}

test "indent with no selection does the caret's line only" {
    var v = try testView("one\ntwo\n");
    defer v.deinit();
    v.cursor.offset = 5;

    try v.indentLines(4);
    const text = try textOf(&v);
    defer testing.allocator.free(text);
    try testing.expectEqualSlices(u8, "one\n    two\n", text);
}

test "toUnixNewlines" {
    const gpa = testing.allocator;

    const crlf = try toUnixNewlines(gpa, "a\r\nb\r\n");
    defer gpa.free(crlf);
    try testing.expectEqualSlices(u8, "a\nb\n", crlf);

    const lone_cr = try toUnixNewlines(gpa, "a\rb");
    defer gpa.free(lone_cr);
    try testing.expectEqualSlices(u8, "a\rb", lone_cr);
}

test "saveAs renames the buffer and survives the caller reusing its path buffer" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A directory of its own, so the test does not depend on anything already
    // existing in the tree.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "saved.txt" });
    defer gpa.free(path);

    var b = Buffer{ .gpa = gpa, .io = io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};

    const view = try b.newScratch();
    try view.insert("ok man\n");

    // The path handed in often points into a caller's scratch buffer, so
    // saveAs must not keep borrowing it.
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(gpa);
    try typed.appendSlice(gpa, path);

    try b.saveAs(view, typed.items);
    @memset(typed.items, 0xAA);

    try testing.expectEqualSlices(u8, "saved.txt", view.name);
    try testing.expectEqualSlices(u8, path, view.path.?);
    try testing.expect(!view.edited());
}
