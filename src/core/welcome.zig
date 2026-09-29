//! What shows when no tab is open: buttons to start a file or open one or a
//! folder, and below them the folders and files opened lately.

const std = @import("std");
const pen = @import("raylib");
const layout = @import("layout.zig");
const Layout = layout.Layout;
const Metrics = @import("font.zig").Metrics;
const Action = @import("menu.zig").Action;

/// The buttons, as menu commands, which give them their names and keys.
pub const actions = [_]Action{ .new_tab, .open_file, .open_folder };

/// Recent folders and files the list shows at most.
pub const max_rows = 10;
/// Of those, folders take at most this many, at the top.
const max_folders = 4;

/// The column takes this share of the text area's width, but no less than
/// the minimum where there is room.
const width_share = 0.5;
const min_width = 380;

pub const Row = struct { path: []const u8, folder: bool };

/// The recent folders, then files, that fit, into `out`.
pub fn rows(folders: []const []const u8, files: []const []const u8, out: *[max_rows]Row) []const Row {
    var n: usize = 0;
    for (folders[0..@min(folders.len, max_folders)]) |f| {
        out[n] = .{ .path = f, .folder = true };
        n += 1;
    }
    for (files) |f| {
        if (n == max_rows) break;
        out[n] = .{ .path = f, .folder = false };
        n += 1;
    }
    return out[0..n];
}

pub const Geometry = struct {
    buttons: [actions.len]pen.Rectangle,
    /// Where the heading over the recent list sits.
    heading_y: f32,
    first_row: pen.Rectangle,

    pub fn row(g: Geometry, index: usize) pen.Rectangle {
        var r = g.first_row;
        r.y += @as(f32, @floatFromInt(index)) * r.height;
        return r;
    }
};

/// A column centred in the text area: the buttons, then `row_count` rows.
pub fn geometry(l: Layout, cell: Metrics, row_count: usize) Geometry {
    const width = @min(@max(l.text.width * width_share, min_width), l.text.width - layout.padding * 2);
    const button_height = cell.height + layout.padding;
    const row_height = layout.listRowHeight(cell);
    const gap = layout.padding;
    const buttons_height = @as(f32, @floatFromInt(actions.len)) * (button_height + gap);
    const list_height = if (row_count == 0) 0 else @as(f32, @floatFromInt(row_count + 1)) * row_height + gap * 2;
    const x = l.text.x + (l.text.width - width) / 2;
    var y = l.text.y + @max((l.text.height - buttons_height - list_height) / 2, layout.padding);

    var g: Geometry = undefined;
    for (&g.buttons) |*b| {
        b.* = .{ .x = x, .y = y, .width = width, .height = button_height };
        y += button_height + gap;
    }
    y += gap * 2;
    g.heading_y = y;
    g.first_row = .{ .x = x, .y = y + row_height, .width = width, .height = row_height };
    return g;
}

pub const Hit = union(enum) { button: usize, row: usize };

pub fn hit(g: Geometry, row_count: usize, point: pen.Vector2) ?Hit {
    for (g.buttons, 0..) |b, i| if (pen.checkCollisionPointRec(point, b)) return .{ .button = i };
    for (0..row_count) |i| if (pen.checkCollisionPointRec(point, g.row(i))) return .{ .row = i };
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "folders come first, a few of them, and files fill the rest" {
    var out: [max_rows]Row = undefined;
    const folders = [_][]const u8{ "/a", "/b", "/c", "/d", "/e" };
    const files = [_][]const u8{ "/1", "/2", "/3", "/4", "/5", "/6", "/7", "/8" };
    const got = rows(&folders, &files, &out);
    try testing.expectEqual(@as(usize, max_rows), got.len);
    try testing.expect(got[0].folder and got[max_folders - 1].folder);
    try testing.expect(!got[max_folders].folder);
    try testing.expectEqualStrings("/1", got[max_folders].path);
}

test "the buttons and rows are found where they are laid out" {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const l = Layout{
        .menu = zero,
        .tabs = zero,
        .gutter = zero,
        .text = .{ .x = 0, .y = 30, .width = 800, .height = 500 },
        .scrollbar = zero,
        .status = zero,
    };
    const cell = Metrics{ .width = 9, .height = 18 };
    const g = geometry(l, cell, 3);
    const middle = pen.Vector2{ .x = 400, .y = 0 };
    var at = middle;
    at.y = g.buttons[1].y + 2;
    try testing.expectEqual(Hit{ .button = 1 }, hit(g, 3, at).?);
    at.y = g.row(2).y + 2;
    try testing.expectEqual(Hit{ .row = 2 }, hit(g, 3, at).?);
    at.y = g.row(3).y + 2;
    try testing.expect(hit(g, 3, at) == null);
}
