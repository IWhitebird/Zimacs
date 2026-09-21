//! Where the caret is, and what is selected.
//!
//! The byte offset is the only stored position. Line and column are always
//! asked of the piece tree, so they cannot drift out of step with the text.
//!
//! A selection is just an `anchor`: the place the selection started. The
//! selected range runs between the anchor and the caret, in either direction.
//! Every movement takes an `extend` flag - true keeps the anchor and grows the
//! selection, false drops it.

const std = @import("std");
const tree_mod = @import("piecetree.zig");
const PieceTree = tree_mod.PieceTree;
const Position = tree_mod.Position;

pub const Range = struct {
    start: u32,
    end: u32,

    pub fn len(r: Range) u32 {
        return r.end - r.start;
    }
};

pub const Cursor = struct {
    offset: u32 = 0,
    /// The column to aim for when moving up or down.
    ///
    /// Without it, moving down through a short line and back would leave the
    /// caret stuck at that line's width instead of returning to where it was.
    goal: u32 = 0,
    anchor: ?u32 = null,

    const Self = @This();

    /// 0-based line and column.
    pub fn position(c: Self, tree: *const PieceTree) Position {
        return tree.positionAt(c.offset);
    }

    /// 1-based line and column, for showing to the user.
    pub fn displayPosition(c: Self, tree: *const PieceTree) Position {
        const p = tree.positionAt(c.offset);
        return .{ .line = p.line + 1, .column = p.column + 1 };
    }

    pub fn hasSelection(c: Self) bool {
        return c.selection() != null;
    }

    /// The selected range, low offset first, or null if nothing is selected.
    pub fn selection(c: Self) ?Range {
        const anchor = c.anchor orelse return null;
        if (anchor == c.offset) return null;
        return .{
            .start = @min(anchor, c.offset),
            .end = @max(anchor, c.offset),
        };
    }

    pub fn clearSelection(c: *Self) void {
        c.anchor = null;
    }

    pub fn selectAll(c: *Self, tree: *const PieceTree) void {
        c.anchor = 0;
        c.offset = tree.len();
        c.resetGoal(tree);
    }

    pub fn selectLine(c: *Self, tree: *const PieceTree) void {
        const line = c.position(tree).line;
        c.anchor = tree.lineStart(line);
        c.offset = @min(tree.lineEnd(line) + 1, tree.len());
        c.resetGoal(tree);
    }

    /// Selects the word around the caret, for a double click.
    pub fn selectWord(c: *Self, tree: *const PieceTree) void {
        var from = c.offset;
        while (from > 0 and isWord(tree.byteAt(from - 1) orelse 0)) from -= 1;
        var to = c.offset;
        while (to < tree.len() and isWord(tree.byteAt(to) orelse 0)) to += 1;
        if (from == to) return;
        c.anchor = from;
        c.offset = to;
        c.resetGoal(tree);
    }

    pub fn left(c: *Self, tree: *const PieceTree, extend: bool) void {
        // Without extending, a left press collapses a selection to its start
        // rather than moving, which is what every editor does.
        if (!extend) if (c.selection()) |r| {
            c.offset = r.start;
            c.anchor = null;
            c.resetGoal(tree);
            return;
        };
        c.mark(extend);
        if (c.offset > 0) {
            c.offset -= 1;
            // Step over the rest of a multi-byte character, so one press
            // moves one character rather than one byte.
            while (c.offset > 0 and isTrailing(tree.byteAt(c.offset) orelse 0)) c.offset -= 1;
        }
        c.resetGoal(tree);
    }

    pub fn right(c: *Self, tree: *const PieceTree, extend: bool) void {
        if (!extend) if (c.selection()) |r| {
            c.offset = r.end;
            c.anchor = null;
            c.resetGoal(tree);
            return;
        };
        c.mark(extend);
        if (c.offset < tree.len()) {
            c.offset += 1;
            while (c.offset < tree.len() and isTrailing(tree.byteAt(c.offset) orelse 0)) c.offset += 1;
        }
        c.resetGoal(tree);
    }

    pub fn up(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.moveLines(tree, -1, extend);
    }

    pub fn down(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.moveLines(tree, 1, extend);
    }

    pub fn pageUp(c: *Self, tree: *const PieceTree, lines: u32, extend: bool) void {
        c.moveLines(tree, -@as(i64, lines), extend);
    }

    pub fn pageDown(c: *Self, tree: *const PieceTree, lines: u32, extend: bool) void {
        c.moveLines(tree, @as(i64, lines), extend);
    }

    pub fn home(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        c.offset = tree.lineStart(c.position(tree).line);
        c.resetGoal(tree);
    }

    pub fn end(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        c.offset = tree.lineEnd(c.position(tree).line);
        c.resetGoal(tree);
    }

    pub fn toStart(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        c.offset = 0;
        c.resetGoal(tree);
    }

    pub fn toEnd(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        c.offset = tree.len();
        c.resetGoal(tree);
    }

    /// Moves to the start of the previous word, the way Ctrl+Left does.
    pub fn wordLeft(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        while (c.offset > 0 and !isWord(tree.byteAt(c.offset - 1) orelse 0)) c.offset -= 1;
        while (c.offset > 0 and isWord(tree.byteAt(c.offset - 1) orelse 0)) c.offset -= 1;
        c.resetGoal(tree);
    }

    pub fn wordRight(c: *Self, tree: *const PieceTree, extend: bool) void {
        c.mark(extend);
        const total = tree.len();
        while (c.offset < total and isWord(tree.byteAt(c.offset) orelse 0)) c.offset += 1;
        while (c.offset < total and !isWord(tree.byteAt(c.offset) orelse 0)) c.offset += 1;
        c.resetGoal(tree);
    }

    /// Puts the caret at a given position, for a mouse click.
    pub fn moveTo(c: *Self, tree: *const PieceTree, offset: u32, extend: bool) void {
        c.mark(extend);
        c.offset = @min(offset, tree.len());
        c.resetGoal(tree);
    }

    /// Call after the text under the caret changed.
    pub fn afterEdit(c: *Self, tree: *const PieceTree) void {
        c.offset = @min(c.offset, tree.len());
        c.anchor = null;
        c.resetGoal(tree);
    }

    /// Starts a selection if one is being extended, drops it otherwise.
    fn mark(c: *Self, extend: bool) void {
        if (extend) {
            if (c.anchor == null) c.anchor = c.offset;
        } else {
            c.anchor = null;
        }
    }

    fn resetGoal(c: *Self, tree: *const PieceTree) void {
        c.goal = c.position(tree).column;
    }

    fn moveLines(c: *Self, tree: *const PieceTree, delta: i64, extend: bool) void {
        c.mark(extend);
        const wanted = @as(i64, c.position(tree).line) + delta;
        const line: u32 = if (wanted <= 0)
            0
        else
            @min(@as(u32, @intCast(wanted)), tree.lineCount() - 1);

        // offsetAt clamps an over-long column to the line's end, which is
        // exactly what the goal column relies on.
        c.offset = tree.offsetAt(.{ .line = line, .column = c.goal });
    }
};

fn isTrailing(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn isWord(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte) or byte >= 0x80;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn treeOf(text: []const u8) !PieceTree {
    return PieceTree.initFromBytes(testing.allocator, text);
}

test "horizontal movement stops at both ends" {
    var tree = try treeOf("ab");
    defer tree.deinit();
    var c = Cursor{};

    c.left(&tree, false);
    try testing.expectEqual(@as(u32, 0), c.offset);

    c.right(&tree, false);
    c.right(&tree, false);
    c.right(&tree, false);
    try testing.expectEqual(@as(u32, 2), c.offset);
}

test "moving left over a newline lands at the end of the line above" {
    var tree = try treeOf("ab\ncd");
    defer tree.deinit();
    var c = Cursor{ .offset = 3 };

    c.left(&tree, false);
    const p = c.position(&tree);
    try testing.expectEqual(@as(u32, 0), p.line);
    try testing.expectEqual(@as(u32, 2), p.column);
}

test "goal column survives a short line" {
    var tree = try treeOf("abcdef\nxy\nabcdef");
    defer tree.deinit();
    var c = Cursor{};

    c.end(&tree, false);
    try testing.expectEqual(@as(u32, 6), c.goal);

    c.down(&tree, false);
    try testing.expectEqual(@as(u32, 2), c.position(&tree).column);

    c.down(&tree, false);
    try testing.expectEqual(@as(u32, 6), c.position(&tree).column);
}

test "home and end" {
    var tree = try treeOf("hello\nworld");
    defer tree.deinit();
    var c = Cursor{ .offset = 8 };

    c.home(&tree, false);
    try testing.expectEqual(@as(u32, 6), c.offset);
    c.end(&tree, false);
    try testing.expectEqual(@as(u32, 11), c.offset);
}

test "display position is 1-based" {
    var tree = try treeOf("a\nb");
    defer tree.deinit();

    const d = (Cursor{ .offset = 2 }).displayPosition(&tree);
    try testing.expectEqual(@as(u32, 2), d.line);
    try testing.expectEqual(@as(u32, 1), d.column);
}

test "arrow keys move by character, not by byte" {
    // "a", U+00E9 (2 bytes), "b".
    var tree = try treeOf("a\u{00e9}b");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 4), tree.len());

    var c = Cursor{};
    c.right(&tree, false);
    try testing.expectEqual(@as(u32, 1), c.offset);
    c.right(&tree, false); // over the whole two-byte character
    try testing.expectEqual(@as(u32, 3), c.offset);
    c.right(&tree, false);
    try testing.expectEqual(@as(u32, 4), c.offset);

    c.left(&tree, false);
    try testing.expectEqual(@as(u32, 3), c.offset);
    c.left(&tree, false);
    try testing.expectEqual(@as(u32, 1), c.offset);
}

test "extending builds a selection, plain movement drops it" {
    var tree = try treeOf("hello");
    defer tree.deinit();
    var c = Cursor{};

    try testing.expect(!c.hasSelection());

    c.right(&tree, true);
    c.right(&tree, true);
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 0), sel.start);
    try testing.expectEqual(@as(u32, 2), sel.end);

    c.right(&tree, false);
    try testing.expect(!c.hasSelection());
}

test "selection reports low offset first when built backwards" {
    var tree = try treeOf("hello");
    defer tree.deinit();
    var c = Cursor{ .offset = 4 };

    c.left(&tree, true);
    c.left(&tree, true);
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 2), sel.start);
    try testing.expectEqual(@as(u32, 4), sel.end);
}

test "plain left collapses a selection to its start" {
    var tree = try treeOf("hello");
    defer tree.deinit();
    var c = Cursor{ .offset = 1 };

    c.right(&tree, true);
    c.right(&tree, true);
    try testing.expectEqual(@as(u32, 3), c.offset);

    c.left(&tree, false);
    try testing.expectEqual(@as(u32, 1), c.offset);
    try testing.expect(!c.hasSelection());
}

test "select all and select line" {
    var tree = try treeOf("one\ntwo\nthree");
    defer tree.deinit();
    var c = Cursor{ .offset = 5 };

    c.selectLine(&tree);
    const line = c.selection().?;
    try testing.expectEqual(@as(u32, 4), line.start);
    try testing.expectEqual(@as(u32, 8), line.end);

    c.selectAll(&tree);
    const all = c.selection().?;
    try testing.expectEqual(@as(u32, 0), all.start);
    try testing.expectEqual(tree.len(), all.end);
}

test "select word" {
    var tree = try treeOf("foo bar_baz qux");
    defer tree.deinit();
    var c = Cursor{ .offset = 6 };

    c.selectWord(&tree);
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 4), sel.start);
    try testing.expectEqual(@as(u32, 11), sel.end);
}

test "word movement" {
    var tree = try treeOf("alpha beta gamma");
    defer tree.deinit();
    var c = Cursor{};

    c.wordRight(&tree, false);
    try testing.expectEqual(@as(u32, 6), c.offset);
    c.wordRight(&tree, false);
    try testing.expectEqual(@as(u32, 11), c.offset);

    c.wordLeft(&tree, false);
    try testing.expectEqual(@as(u32, 6), c.offset);
    c.wordLeft(&tree, false);
    try testing.expectEqual(@as(u32, 0), c.offset);
}
