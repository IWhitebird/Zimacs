//! Geometry of the custom title bar, which shares the menu row: caption
//! buttons, drag area, title placement and window resize edges.

const std = @import("std");
const pen = @import("raylib");
const menu = @import("menu.zig");
const layout = @import("layout.zig");
const Font = @import("font.zig").Font;
const Layout = layout.Layout;

pub const Button = enum { minimize, maximize, close };

/// Left to right, the order they are drawn in.
pub const buttons = [_]Button{ .minimize, .maximize, .close };

/// How close to the edge of the window the pointer has to be to resize it.
pub const grip: f32 = 5;

/// Windows 11 caption button proportions.
pub fn buttonWidth(l: Layout) f32 {
    return @round(l.menu.height * 1.4);
}

pub fn buttonRect(b: Button, l: Layout) pen.Rectangle {
    const width = buttonWidth(l);
    const from_right: f32 = @floatFromInt(buttons.len - @intFromEnum(b));
    return .{
        .x = l.menu.x + l.menu.width - from_right * width,
        .y = l.menu.y,
        .width = width,
        .height = l.menu.height,
    };
}

pub fn buttonAt(point: pen.Vector2, l: Layout) ?Button {
    for (buttons) |b| {
        if (pen.checkCollisionPointRec(point, buttonRect(b, l))) return b;
    }
    return null;
}

/// Between the last menu title and the first button.
pub fn dragRect(l: Layout, font: Font) pen.Rectangle {
    const last = menu.titleRect(menu.bar.len - 1, l, font);
    const start = last.x + last.width;
    const end = buttonRect(.minimize, l).x;
    return .{ .x = start, .y = l.menu.y, .width = @max(end - start, 0), .height = l.menu.height };
}

pub fn inDragArea(point: pen.Vector2, l: Layout, font: Font) bool {
    return pen.checkCollisionPointRec(point, dragRect(l, font));
}

/// Centred on the window, shifted to clear the menus and buttons, or null
/// when it does not fit.
pub fn titleRect(text_width: f32, l: Layout, font: Font) ?pen.Rectangle {
    const room = dragRect(l, font);
    const margin = layout.padding * 2;
    if (text_width + margin * 2 > room.width) return null;

    const centred = l.menu.x + (l.menu.width - text_width) / 2;
    const x = std.math.clamp(centred, room.x + margin, room.x + room.width - margin - text_width);
    return .{ .x = x, .y = l.menu.y, .width = text_width, .height = l.menu.height };
}

pub const Edges = struct {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

    pub fn any(e: Edges) bool {
        return e.left or e.right or e.top or e.bottom;
    }

    pub fn cursor(e: Edges) pen.MouseCursor {
        if ((e.left and e.top) or (e.right and e.bottom)) return .resize_nwse;
        if ((e.right and e.top) or (e.left and e.bottom)) return .resize_nesw;
        if (e.left or e.right) return .resize_ew;
        if (e.top or e.bottom) return .resize_ns;
        return .default;
    }
};

/// The top edge stops short of the buttons, so Close is not a resize grip.
pub fn edgesAt(point: pen.Vector2, l: Layout) Edges {
    const width = l.menu.width;
    const height = l.status.y + l.status.height;
    if (point.x < 0 or point.y < 0 or point.x > width or point.y > height) return .{};

    const below_buttons = point.x < buttonRect(.minimize, l).x;
    return .{
        .left = point.x < grip,
        .right = point.x >= width - grip,
        .top = point.y < grip and below_buttons,
        .bottom = point.y >= height - grip,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testLayout() Layout {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .menu = .{ .x = 0, .y = 0, .width = 800, .height = 32 },
        .tabs = zero,
        .gutter = zero,
        .text = .{ .x = 0, .y = 32, .width = 800, .height = 400 },
        .scrollbar = zero,
        .status = .{ .x = 0, .y = 432, .width = 800, .height = 24 },
    };
}

const test_font = Font{ .metrics = .{ .width = 8, .height = 16 } };

test "buttons fill the right end of the bar in order, without gaps" {
    const l = testLayout();
    var x = buttonRect(.minimize, l).x;
    for (buttons) |b| {
        const rect = buttonRect(b, l);
        try testing.expectApproxEqAbs(x, rect.x, 0.01);
        x = rect.x + rect.width;
    }
    try testing.expectApproxEqAbs(l.menu.width, x, 0.01);
}

test "the middle of each button picks that button" {
    const l = testLayout();
    for (buttons) |b| {
        const rect = buttonRect(b, l);
        const middle = pen.Vector2{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
        try testing.expectEqual(b, buttonAt(middle, l).?);
    }
    try testing.expect(buttonAt(.{ .x = 10, .y = 10 }, l) == null);
}

test "the drag area runs from the last menu to the first button" {
    const l = testLayout();
    const drag = dragRect(l, test_font);
    const last = menu.titleRect(menu.bar.len - 1, l, test_font);

    try testing.expectApproxEqAbs(last.x + last.width, drag.x, 0.01);
    try testing.expectApproxEqAbs(buttonRect(.minimize, l).x, drag.x + drag.width, 0.01);
    try testing.expect(!inDragArea(.{ .x = 4, .y = 10 }, l, test_font));
    try testing.expect(!inDragArea(.{ .x = 790, .y = 10 }, l, test_font));
    try testing.expect(inDragArea(.{ .x = drag.x + 1, .y = 10 }, l, test_font));
}

test "a title is centred when there is room, and dropped when there is not" {
    const l = testLayout();
    const rect = titleRect(100, l, test_font).?;
    try testing.expectApproxEqAbs(@as(f32, 350), rect.x, 0.01);

    const drag = dragRect(l, test_font);
    try testing.expect(titleRect(drag.width, l, test_font) == null);
}

test "a long title slides clear of the menus rather than covering them" {
    const l = testLayout();
    const drag = dragRect(l, test_font);
    const wide = drag.width - layout.padding * 4 - 1;
    const rect = titleRect(wide, l, test_font).?;
    try testing.expect(rect.x >= drag.x);
    try testing.expect(rect.x + rect.width <= drag.x + drag.width);
}

test "edges and corners resize, the middle does not" {
    const l = testLayout();
    try testing.expect(!edgesAt(.{ .x = 400, .y = 200 }, l).any());

    const left = edgesAt(.{ .x = 1, .y = 200 }, l);
    try testing.expect(left.left and !left.top);
    try testing.expectEqual(pen.MouseCursor.resize_ew, left.cursor());

    const corner = edgesAt(.{ .x = 799, .y = 455 }, l);
    try testing.expect(corner.right and corner.bottom);
    try testing.expectEqual(pen.MouseCursor.resize_nwse, corner.cursor());
}

test "the strip above the close button closes, it does not resize" {
    const l = testLayout();
    const close = buttonRect(.close, l);
    const edges = edgesAt(.{ .x = close.x + close.width / 2, .y = 1 }, l);
    try testing.expect(!edges.top);
}
