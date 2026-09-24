//! Folding long lines onto extra screen rows.
//!
//! One document line becomes one or more rows. Wrapping happens at the last
//! column that fits rather than at word boundaries, which is what code editors
//! do and keeps the mapping between a column and its row exact.
//!
//! All of this is arithmetic on column counts, so the editor can ask where
//! something lands without measuring anything.

const std = @import("std");

/// How many rows a line of `columns` columns needs.
pub fn rowsFor(columns: u32, width: u32) u32 {
    if (width == 0) return 1;
    if (columns == 0) return 1;
    return (columns + width - 1) / width;
}

/// Which row of its line a column falls on, and where along that row.
pub fn place(column: u32, width: u32) struct { row: u32, column: u32 } {
    if (width == 0) return .{ .row = 0, .column = column };
    return .{ .row = column / width, .column = column % width };
}

/// The first column shown on `row` of a wrapped line.
pub fn rowStart(row: u32, width: u32) u32 {
    return row * width;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a short line is one row" {
    try testing.expectEqual(@as(u32, 1), rowsFor(0, 80));
    try testing.expectEqual(@as(u32, 1), rowsFor(1, 80));
    try testing.expectEqual(@as(u32, 1), rowsFor(80, 80));
}

test "a long line spills onto more rows" {
    try testing.expectEqual(@as(u32, 2), rowsFor(81, 80));
    try testing.expectEqual(@as(u32, 2), rowsFor(160, 80));
    try testing.expectEqual(@as(u32, 3), rowsFor(161, 80));
}

test "place splits a column into row and offset" {
    const a = place(0, 80);
    try testing.expectEqual(@as(u32, 0), a.row);
    try testing.expectEqual(@as(u32, 0), a.column);

    const b = place(79, 80);
    try testing.expectEqual(@as(u32, 0), b.row);
    try testing.expectEqual(@as(u32, 79), b.column);

    const c = place(80, 80);
    try testing.expectEqual(@as(u32, 1), c.row);
    try testing.expectEqual(@as(u32, 0), c.column);

    const d = place(165, 80);
    try testing.expectEqual(@as(u32, 2), d.row);
    try testing.expectEqual(@as(u32, 5), d.column);
}

test "rowStart is the inverse of place" {
    const width: u32 = 37;
    var column: u32 = 0;
    while (column < 400) : (column += 1) {
        const at = place(column, width);
        try testing.expectEqual(column, rowStart(at.row, width) + at.column);
    }
}

test "every column lands on a row that exists" {
    const width: u32 = 12;
    for ([_]u32{ 0, 1, 11, 12, 13, 100 }) |columns| {
        const rows = rowsFor(columns, width);
        var column: u32 = 0;
        while (column < columns) : (column += 1) {
            try testing.expect(place(column, width).row < rows);
        }
    }
}

test "a zero width does not divide by zero" {
    try testing.expectEqual(@as(u32, 1), rowsFor(50, 0));
    try testing.expectEqual(@as(u32, 0), place(50, 0).row);
}
