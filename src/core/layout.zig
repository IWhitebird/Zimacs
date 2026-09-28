//! Where things sit on screen: the tab bar, the line-number gutter, the text
//! area and the status bar.
//!
//! Nothing here is stored. `Layout.compute` runs fresh every frame from the
//! live window size, so resizing and zooming need no special handling.

const std = @import("std");
const pen = @import("raylib");
const Metrics = @import("font.zig").Metrics;

pub const padding: f32 = 8;

/// Width of the scrollbar down the right edge.
pub const scrollbar_width: f32 = 12;
/// A thumb shorter than this is hard to grab.
const min_thumb: f32 = 24;

/// Keeps the gutter from visibly jumping around in small files.
const min_digits: u32 = 3;

pub const Layout = struct {
    menu: pen.Rectangle,
    /// The folder tree down the left; empty when it is not showing.
    sidebar: pen.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tabs: pen.Rectangle,
    gutter: pen.Rectangle,
    text: pen.Rectangle,
    scrollbar: pen.Rectangle,
    status: pen.Rectangle,

    pub const Options = struct {
        line_count: u32,
        /// There are tabs to show.
        tabs: bool,
        /// The menu row is also the window's title bar, which wants to be a
        /// little taller than a menu on its own.
        titlebar: bool,
        /// Columns of the folder tree, or 0 when it is not showing.
        sidebar_columns: u32 = 0,
    };

    pub fn compute(cell: Metrics, o: Options) Layout {
        // Logical units, the ones raylib draws and reports the mouse in. The
        // render size is physical pixels, which differ on a scaled display.
        const width: f32 = @floatFromInt(pen.getScreenWidth());
        const height: f32 = @floatFromInt(pen.getScreenHeight());

        const menu_height = cell.height + padding * @as(f32, if (o.titlebar) 2 else 1);
        const tab_height = if (o.tabs) cell.height + padding * 1.5 else 0;
        const status_height = cell.height + padding;
        const body_top = menu_height + tab_height;
        const body_height = @max(height - body_top - status_height, 0);
        // Never so wide that the text has no room.
        const sidebar_width = @min(@as(f32, @floatFromInt(o.sidebar_columns)) * cell.width, width / 2);
        const gutter_width = @as(f32, @floatFromInt(@max(min_digits, digits(o.line_count)))) *
            cell.width + padding * 2;
        const text_x = sidebar_width + gutter_width;

        return .{
            .menu = .{ .x = 0, .y = 0, .width = width, .height = menu_height },
            .sidebar = .{ .x = 0, .y = menu_height, .width = sidebar_width, .height = @max(height - menu_height - status_height, 0) },
            .tabs = .{ .x = sidebar_width, .y = menu_height, .width = @max(width - sidebar_width, 0), .height = tab_height },
            .gutter = .{
                .x = sidebar_width,
                .y = body_top,
                .width = @min(gutter_width, @max(width - sidebar_width, 0)),
                .height = body_height,
            },
            .text = .{
                .x = text_x,
                .y = body_top,
                .width = @max(width - text_x - scrollbar_width, 0),
                .height = body_height,
            },
            .scrollbar = .{
                .x = @max(width - scrollbar_width, 0),
                .y = body_top,
                .width = scrollbar_width,
                .height = body_height,
            },
            .status = .{
                .x = 0,
                .y = body_top + body_height,
                .width = width,
                .height = status_height,
            },
        };
    }

    /// How many whole lines fit in the text area.
    pub fn rows(l: Layout, cell: Metrics) u32 {
        const n = @floor(l.text.height / cell.height);
        return if (n <= 0) 0 else @intFromFloat(n);
    }

    /// Columns of text that fit across the text area.
    pub fn columns(l: Layout, cell: Metrics) u32 {
        const n = @floor((l.text.width - padding * 2) / cell.width);
        return if (n <= 0) 0 else @intFromFloat(n);
    }

    /// Which screen row and column the given point falls on, counted from the
    /// top of the text area. Turning that into a document position is the
    /// caller's job, since it depends on whether lines are folded.
    pub fn hit(l: Layout, cell: Metrics, point: pen.Vector2) struct { row: u32, column: u32 } {
        const row = @max((point.y - l.text.y) / cell.height, 0);
        const col = @max((point.x - l.text.x - padding) / cell.width + 0.5, 0);
        return .{
            .row = @intFromFloat(@floor(row)),
            .column = @intFromFloat(@floor(col)),
        };
    }
};

/// Where a scrollbar thumb sits along a track, or null when everything
/// already fits. `start` is measured from the start of the track.
///
/// The thumb travels over `track_len - thumb_len`, not the whole track, and
/// `offsetAt` reverses exactly that - otherwise a drag drifts away from the
/// pointer.
pub fn thumbSpan(track_len: f32, offset: u32, visible: u32, total: u32) ?struct { start: f32, len: f32 } {
    if (total <= visible or visible == 0 or track_len <= 0) return null;

    const fraction = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
    const len = @min(@max(track_len * fraction, min_thumb), track_len);
    const travel = track_len - len;
    const progress = @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(total - visible));

    return .{ .start = travel * std.math.clamp(progress, 0, 1), .len = len };
}

/// The scroll offset for a thumb whose start is at `position` along the track.
pub fn offsetAt(track_len: f32, position: f32, visible: u32, total: u32) u32 {
    const span = thumbSpan(track_len, 0, visible, total) orelse return 0;
    const travel = track_len - span.len;
    if (travel <= 0) return 0;
    const progress = std.math.clamp(position / travel, 0, 1);
    return @intFromFloat(progress * @as(f32, @floatFromInt(total - visible)));
}

/// The vertical scrollbar thumb.
pub fn thumb(track: pen.Rectangle, top_line: u32, rows: u32, total: u32) ?pen.Rectangle {
    const span = thumbSpan(track.height, top_line, rows, total) orelse return null;
    return .{
        .x = track.x + 2,
        .y = track.y + span.start,
        .width = @max(track.width - 4, 1),
        .height = span.len,
    };
}

/// Which line a point on the vertical track corresponds to.
pub fn lineAtTrack(track: pen.Rectangle, y: f32, rows: u32, total: u32) u32 {
    return offsetAt(track.height, y - track.y, rows, total);
}

/// The horizontal scrollbar, laid over the bottom of the text area so that
/// showing it does not reflow the text.
pub fn horizontalTrack(l: Layout) pen.Rectangle {
    return .{
        .x = l.text.x,
        .y = l.text.y + @max(l.text.height - scrollbar_width, 0),
        .width = l.text.width,
        .height = @min(scrollbar_width, l.text.height),
    };
}

pub fn horizontalThumb(track: pen.Rectangle, left: u32, visible: u32, total: u32) ?pen.Rectangle {
    const span = thumbSpan(track.width, left, visible, total) orelse return null;
    return .{
        .x = track.x + span.start,
        .y = track.y + 2,
        .width = span.len,
        .height = @max(track.height - 4, 1),
    };
}

pub fn columnAtTrack(track: pen.Rectangle, x: f32, visible: u32, total: u32) u32 {
    return offsetAt(track.width, x - track.x, visible, total);
}

/// The prompt panel takes this share of the text area's width, but no less
/// than the minimum where there is room.
const prompt_share = 0.6;
const prompt_min_width = 320;

/// The floating panel the prompt uses. Sits near the top of the text area,
/// out of the way of what you are reading.
pub fn promptPanel(l: Layout, cell: Metrics, rows: usize) pen.Rectangle {
    const width = @min(@max(l.text.width * prompt_share, prompt_min_width), l.text.width - padding * 2);
    const height = cell.height + padding * 2 +
        @as(f32, @floatFromInt(rows)) * listRowHeight(cell);
    return .{
        .x = l.text.x + (l.text.width - width) / 2,
        .y = l.text.y + padding * 2,
        .width = width,
        .height = height,
    };
}

/// Where the folder tree's rows start: under the one naming the folder.
pub fn sidebarRowsTop(l: Layout, cell: Metrics) f32 {
    return l.sidebar.y + listRowHeight(cell);
}

/// A row of a list: the prompt's suggestions, or the folder tree.
pub fn listRowHeight(cell: Metrics) f32 {
    return cell.height + padding * 0.5;
}

/// Where suggestion `row` of the prompt sits.
/// Which of the `shown` suggestion rows `point` is on.
pub fn promptRowAt(l: Layout, cell: Metrics, shown: usize, point: pen.Vector2) ?usize {
    const panel = promptPanel(l, cell, shown);
    var row: usize = 0;
    while (row < shown) : (row += 1) {
        if (pen.checkCollisionPointRec(point, promptRow(panel, cell, row))) return row;
    }
    return null;
}

pub fn promptRow(panel: pen.Rectangle, cell: Metrics, row: usize) pen.Rectangle {
    const height = listRowHeight(cell);
    return .{
        .x = panel.x,
        .y = panel.y + cell.height + padding * 2 + @as(f32, @floatFromInt(row)) * height,
        .width = panel.width,
        .height = height,
    };
}

pub fn digits(n: u32) u32 {
    var count: u32 = 1;
    var rest = n;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

/// X position that right-aligns something `width` wide inside `rect`.
pub fn rightAlign(rect: pen.Rectangle, width: f32) f32 {
    return @max(rect.x + rect.width - width - padding, rect.x + padding);
}

test "thumb is absent when everything fits" {
    const track = pen.Rectangle{ .x = 0, .y = 0, .width = 12, .height = 100 };
    try std.testing.expect(thumb(track, 0, 50, 20) == null);
    try std.testing.expect(thumb(track, 0, 50, 50) == null);
}

test "thumb shrinks with the file and moves with the scroll" {
    const track = pen.Rectangle{ .x = 0, .y = 0, .width = 12, .height = 100 };

    const top = thumb(track, 0, 10, 100).?;
    try std.testing.expectEqual(@as(f32, 0), top.y);
    try std.testing.expect(top.height < track.height);

    const bottom = thumb(track, 90, 10, 100).?;
    try std.testing.expectApproxEqAbs(track.height - bottom.height, bottom.y, 0.01);
}

test "dragging the thumb lands back on the same line" {
    const track = pen.Rectangle{ .x = 0, .y = 0, .width = 12, .height = 200 };
    const rows: u32 = 20;
    const total: u32 = 500;

    // Whatever line we are on, placing the thumb there and reading it back
    // must return the same line - otherwise a drag drifts from the pointer.
    for ([_]u32{ 0, 1, 137, 300, 479, 480 }) |line| {
        const bar = thumb(track, line, rows, total).?;
        try std.testing.expectEqual(line, lineAtTrack(track, bar.y, rows, total));
    }
}

test "clicking the track maps back to a line" {
    const track = pen.Rectangle{ .x = 0, .y = 0, .width = 12, .height = 100 };
    try std.testing.expectEqual(@as(u32, 0), lineAtTrack(track, 0, 10, 110));
    try std.testing.expectEqual(@as(u32, 100), lineAtTrack(track, 1000, 10, 110));
}

test "horizontal thumb behaves the same way" {
    const track = pen.Rectangle{ .x = 0, .y = 0, .width = 200, .height = 12 };
    try std.testing.expect(horizontalThumb(track, 0, 80, 40) == null);

    const bar = horizontalThumb(track, 30, 40, 200).?;
    try std.testing.expectEqual(@as(u32, 30), columnAtTrack(track, bar.x, 40, 200));
}

test "digits" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 1), digits(0));
    try t.expectEqual(@as(u32, 1), digits(9));
    try t.expectEqual(@as(u32, 2), digits(10));
    try t.expectEqual(@as(u32, 3), digits(999));
    try t.expectEqual(@as(u32, 4), digits(1000));
}
