//! Folding long lines onto extra screen rows.
//!
//! A line breaks after the last space that fits on a row, so words stay
//! whole, and only a word wider than a whole row is cut at the edge.
//! Positions on a folded line are screen columns, as everywhere else; a
//! line's `breaks` say which column each of its rows starts at.

const std = @import("std");
const PieceTree = @import("piecetree.zig").PieceTree;
const text = @import("text.zig");

/// How lines are folded: the row width in columns, and the tab width.
pub const Fold = struct {
    width: u32,
    tab: u8,
};

/// The column each row of `line` starts at, into `out`. The first is 0.
pub fn breaks(gpa: std.mem.Allocator, line: []const u8, fold: Fold, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    try out.append(gpa, 0);
    if (fold.width == 0) return;

    var column: u32 = 0;
    var row_start: u32 = 0;
    // Where a row could start after the most recent run of spaces.
    var after_space: ?u32 = null;
    var i: usize = 0;
    while (i < line.len) {
        const is_space = line[i] == ' ' or line[i] == '\t';
        const width: u32, const len: usize = if (line[i] == '\t')
            .{ text.tabAdvance(column, fold.tab), 1 }
        else blk: {
            const at = text.decode(line, i);
            break :blk .{ text.columnsFor(at.code), at.len };
        };

        // Spaces may hang past the edge; the word after them moves down.
        if (!is_space and column + width > row_start + fold.width and column > row_start) {
            const start = if (after_space) |a| if (a > row_start) a else column else column;
            try out.append(gpa, start);
            row_start = start;
            after_space = null;
            // A word longer than the row it now starts is cut at the edge.
            if (column + width > row_start + fold.width and column > row_start) {
                try out.append(gpa, column);
                row_start = column;
            }
        }
        column += width;
        i += len;
        if (is_space) after_space = column;
    }
}

/// Which row a column falls on, given its line's `breaks`, and how far
/// along that row.
pub fn place(starts: []const u32, column: u32) struct { row: u32, column: u32 } {
    var row: usize = 0;
    while (row + 1 < starts.len and starts[row + 1] <= column) row += 1;
    return .{ .row = @intCast(row), .column = column - starts[row] };
}

/// How many rows each line of a document folds into, so scrolling and the
/// scrollbar can count rows without refolding the whole file. Edits say
/// which lines they touched and only those are worked out again.
pub const Rows = struct {
    gpa: std.mem.Allocator,
    /// Per line; 0 where not yet worked out, since every line has a row.
    counts: std.ArrayList(u32) = .empty,
    fold: Fold = .{ .width = 0, .tab = 0 },
    line_buf: std.ArrayList(u8) = .empty,
    starts_buf: std.ArrayList(u32) = .empty,

    pub fn deinit(r: *Rows) void {
        r.counts.deinit(r.gpa);
        r.line_buf.deinit(r.gpa);
        r.starts_buf.deinit(r.gpa);
    }

    /// After an edit starting on `line` that took out `removed` line breaks
    /// and put in `added`.
    pub fn edited(r: *Rows, line: u32, removed: u32, added: u32) void {
        if (r.counts.items.len == 0) return;
        const from = @min(line, r.counts.items.len);
        const gone = @min(removed + 1, r.counts.items.len - from);
        const fresh = r.gpa.alloc(u32, added + 1) catch {
            r.counts.clearRetainingCapacity();
            return;
        };
        defer r.gpa.free(fresh);
        @memset(fresh, 0);
        r.counts.replaceRange(r.gpa, from, gone, fresh) catch r.counts.clearRetainingCapacity();
    }

    /// Rows of `line`.
    pub fn count(r: *Rows, tree: *const PieceTree, fold: Fold, line: u32) u32 {
        r.prepare(tree, fold);
        if (line >= r.counts.items.len) return 1;
        if (r.counts.items[line] == 0) r.counts.items[line] = r.measure(tree, fold, line);
        return r.counts.items[line];
    }

    /// Rows above `line`.
    pub fn above(r: *Rows, tree: *const PieceTree, fold: Fold, line: u32) u32 {
        var rows: u32 = 0;
        var i: u32 = 0;
        while (i < line) : (i += 1) rows += r.count(tree, fold, i);
        return rows;
    }

    pub fn total(r: *Rows, tree: *const PieceTree, fold: Fold) u32 {
        return r.above(tree, fold, tree.lineCount());
    }

    /// The line holding row `row` of the document, and which of its rows.
    pub fn lineAt(r: *Rows, tree: *const PieceTree, fold: Fold, row: u32) struct { line: u32, row: u32 } {
        var left = row;
        var line: u32 = 0;
        while (line + 1 < tree.lineCount()) : (line += 1) {
            const rows = r.count(tree, fold, line);
            if (left < rows) break;
            left -= rows;
        }
        return .{ .line = line, .row = @min(left, r.count(tree, fold, line) - 1) };
    }

    /// The line's `breaks`, valid until the next call.
    pub fn breaksOf(r: *Rows, tree: *const PieceTree, fold: Fold, line: u32) []const u32 {
        r.line_buf.clearRetainingCapacity();
        tree.lineContent(line, &r.line_buf) catch return &.{0};
        breaks(r.gpa, r.line_buf.items, fold, &r.starts_buf) catch return &.{0};
        return r.starts_buf.items;
    }

    fn prepare(r: *Rows, tree: *const PieceTree, fold: Fold) void {
        if (std.meta.eql(fold, r.fold) and r.counts.items.len == tree.lineCount()) return;
        r.fold = fold;
        r.counts.resize(r.gpa, tree.lineCount()) catch {
            r.counts.clearRetainingCapacity();
            return;
        };
        @memset(r.counts.items, 0);
    }

    fn measure(r: *Rows, tree: *const PieceTree, fold: Fold, line: u32) u32 {
        // A line no wider than a row in bytes is one row; no need to fold it.
        if (tree.lineLen(line) <= fold.width) {
            r.line_buf.clearRetainingCapacity();
            tree.lineContent(line, &r.line_buf) catch return 1;
            if (std.mem.indexOfScalar(u8, r.line_buf.items, '\t') == null) return 1;
        }
        return @intCast(r.breaksOf(tree, fold, line).len);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectBreaks(line: []const u8, width: u32, want: []const u32) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try breaks(testing.allocator, line, .{ .width = width, .tab = 4 }, &out);
    try testing.expectEqualSlices(u32, want, out.items);
}

test "a line that fits is one row" {
    try expectBreaks("", 10, &.{0});
    try expectBreaks("short", 10, &.{0});
    try expectBreaks("0123456789", 10, &.{0});
}

test "lines break after the last space that fits, keeping words whole" {
    //                0123456789012345678
    try expectBreaks("the quick brown fox", 10, &.{ 0, 10 });
    try expectBreaks("aaa bbb ccc ddd", 7, &.{ 0, 8 });
    try expectBreaks("aaa bbb ccc ddd", 6, &.{ 0, 4, 8, 12 });
}

test "spaces at the edge hang, and the next word starts the row" {
    try expectBreaks("abcde     fgh", 5, &.{ 0, 10 });
}

test "a word wider than a row is cut at the edge" {
    try expectBreaks("abcdefghijkl", 5, &.{ 0, 5, 10 });
    try expectBreaks("ab abcdefghijkl", 5, &.{ 0, 3, 8, 13 });
}

test "place finds the row and the column along it" {
    const starts = [_]u32{ 0, 10, 18 };
    const a = place(&starts, 0);
    try testing.expectEqual(@as(u32, 0), a.row);
    const b = place(&starts, 12);
    try testing.expectEqual(@as(u32, 1), b.row);
    try testing.expectEqual(@as(u32, 2), b.column);
    const c = place(&starts, 30);
    try testing.expectEqual(@as(u32, 2), c.row);
    try testing.expectEqual(@as(u32, 12), c.column);
}

test "row counts follow edits and match folding from scratch" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "one\ntwo two two two two\nthree");
    defer tree.deinit();
    var rows = Rows{ .gpa = testing.allocator };
    defer rows.deinit();
    const fold = Fold{ .width = 8, .tab = 4 };

    try testing.expectEqual(@as(u32, 5), rows.total(&tree, fold));
    try testing.expectEqual(@as(u32, 1), rows.lineAt(&tree, fold, 1).line);
    try testing.expectEqual(@as(u32, 2), rows.lineAt(&tree, fold, 3).row);
    try testing.expectEqual(@as(u32, 2), rows.lineAt(&tree, fold, 4).line);

    // Split the long line in two and join the first pair.
    const at = tree.lineStart(1) + 8;
    try tree.insert(at, "\n");
    rows.edited(1, 0, 1);
    try tree.delete(3, 1);
    rows.edited(0, 1, 0);

    var fresh = Rows{ .gpa = testing.allocator };
    defer fresh.deinit();
    try testing.expectEqual(fresh.total(&tree, fold), rows.total(&tree, fold));
    var line: u32 = 0;
    while (line < tree.lineCount()) : (line += 1) {
        try testing.expectEqual(fresh.count(&tree, fold, line), rows.count(&tree, fold, line));
    }
}

test "a zero width folds nothing" {
    try expectBreaks("anything at all", 0, &.{0});
}
