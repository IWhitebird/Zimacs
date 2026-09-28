//! The tab bar's geometry: where each tab and its close button sit, and
//! horizontal scrolling once the tabs no longer fit, which keeps the active
//! tab in view and lets the wheel scroll the rest.

const std = @import("std");
const pen = @import("raylib");
const padding = @import("layout.zig").padding;

pub const TabStrip = struct {
    /// Each tab's width, measured by the caller before `update`.
    widths: std.ArrayList(f32) = .empty,
    /// Side of the square close button at the right of each tab.
    close_size: f32 = 0,
    /// Pixels scrolled from the first tab.
    scroll: f32 = 0,
    /// Width of all tabs, and of the room for them, as of the last update.
    total: f32 = 0,
    visible: f32 = 0,
    /// The tab last brought into view, so the wheel is not undone next frame.
    followed: ?usize = null,

    pub fn deinit(s: *TabStrip, gpa: std.mem.Allocator) void {
        s.widths.deinit(gpa);
    }

    /// Brings `active` into view when it changes, and keeps the scroll in range.
    pub fn update(s: *TabStrip, visible: f32, active: usize) void {
        const widths = s.widths.items;
        s.visible = visible;
        s.total = 0;
        for (widths) |w| s.total += w;

        if (active < widths.len and s.followed != active) {
            s.followed = active;
            var start: f32 = 0;
            for (widths[0..active]) |w| start += w;
            const end = start + widths[active];
            if (start < s.scroll) s.scroll = start;
            if (end > s.scroll + visible) s.scroll = end - visible;
        }
        s.clamp();
    }

    pub fn scrollBy(s: *TabStrip, delta: f32) void {
        s.scroll += delta;
        s.clamp();
    }

    pub fn hiddenLeft(s: TabStrip) bool {
        return s.scroll > edge_slack;
    }

    pub fn hiddenRight(s: TabStrip) bool {
        return s.scroll + s.visible < s.total - edge_slack;
    }

    /// Where tab `index` sits in `strip`, or null when it is scrolled wholly
    /// out of it.
    pub fn rect(s: TabStrip, strip: pen.Rectangle, index: usize) ?pen.Rectangle {
        const widths = s.widths.items;
        if (index >= widths.len) return null;
        var x = strip.x - s.scroll;
        for (widths[0..index]) |w| x += w;
        if (x >= strip.x + strip.width or x + widths[index] <= strip.x) return null;
        return .{ .x = x, .y = strip.y, .width = widths[index], .height = strip.height };
    }

    /// The close button of tab `index`.
    pub fn closeRect(s: TabStrip, strip: pen.Rectangle, index: usize) ?pen.Rectangle {
        const tab = s.rect(strip, index) orelse return null;
        return .{
            .x = tab.x + tab.width - s.close_size - padding / 2,
            .y = tab.y + (tab.height - s.close_size) / 2,
            .width = s.close_size,
            .height = s.close_size,
        };
    }

    /// Which tab is under `point`.
    pub fn tabAt(s: TabStrip, strip: pen.Rectangle, point: pen.Vector2) ?usize {
        if (!pen.checkCollisionPointRec(point, strip)) return null;
        for (0..s.widths.items.len) |i| {
            if (s.rect(strip, i)) |r| if (pen.checkCollisionPointRec(point, r)) return i;
        }
        return null;
    }

    /// Which tab's close button is under `point`.
    pub fn closeAt(s: TabStrip, strip: pen.Rectangle, point: pen.Vector2) ?usize {
        if (!pen.checkCollisionPointRec(point, strip)) return null;
        for (0..s.widths.items.len) |i| {
            if (s.closeRect(strip, i)) |r| if (pen.checkCollisionPointRec(point, r)) return i;
        }
        return null;
    }

    fn clamp(s: *TabStrip) void {
        s.scroll = std.math.clamp(s.scroll, 0, @max(s.total - s.visible, 0));
    }
};

/// Scroll within this much of an end counts as at it, so rounding does not
/// leave an edge fade showing.
const edge_slack = 0.5;

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn stripOf(widths: []const f32, visible: f32, active: usize) !TabStrip {
    var s = TabStrip{};
    try s.widths.appendSlice(testing.allocator, widths);
    s.update(visible, active);
    return s;
}

fn setWidths(s: *TabStrip, widths: []const f32) !void {
    s.widths.clearRetainingCapacity();
    try s.widths.appendSlice(testing.allocator, widths);
}

test "tabs that fit never scroll" {
    var s = try stripOf(&.{ 100, 100 }, 500, 1);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0), s.scroll);
    try testing.expect(!s.hiddenLeft() and !s.hiddenRight());
}

test "switching to a tab off the right edge scrolls it fully into view" {
    var s = try stripOf(&.{ 100, 100, 100, 100, 100 }, 250, 0);
    defer s.deinit(testing.allocator);
    s.update(250, 4);
    try testing.expectEqual(@as(f32, 250), s.scroll);
    try testing.expect(s.hiddenLeft() and !s.hiddenRight());

    s.update(250, 1);
    try testing.expectEqual(@as(f32, 100), s.scroll);
}

test "the wheel scrolls, but only within the tabs" {
    var s = try stripOf(&.{ 100, 100, 100 }, 150, 0);
    defer s.deinit(testing.allocator);
    s.scrollBy(1000);
    try testing.expectEqual(@as(f32, 150), s.scroll);
    s.scrollBy(-1000);
    try testing.expectEqual(@as(f32, 0), s.scroll);
}

test "a wheel scroll is not undone while the active tab stays the same" {
    var s = try stripOf(&.{ 100, 100, 100 }, 150, 0);
    defer s.deinit(testing.allocator);
    s.scrollBy(80);
    s.update(150, 0);
    try testing.expectEqual(@as(f32, 80), s.scroll);
}

test "closing tabs pulls the scroll back in range" {
    var s = try stripOf(&.{ 100, 100, 100, 100 }, 150, 3);
    defer s.deinit(testing.allocator);
    try setWidths(&s, &.{ 100, 100 });
    s.update(150, 1);
    try testing.expect(s.scroll <= 50);
}

test "tabs are found where they are drawn, scrolled or not" {
    // Four 60-wide tabs in a 150-wide strip that starts at x 10.
    var s = try stripOf(&.{ 60, 60, 60, 60 }, 150, 0);
    defer s.deinit(testing.allocator);
    s.close_size = 10;
    const strip = pen.Rectangle{ .x = 10, .y = 0, .width = 150, .height = 30 };
    try testing.expectEqual(@as(?usize, 1), s.tabAt(strip, .{ .x = 100, .y = 15 }));
    try testing.expect(s.rect(strip, 3) == null);
    const close = s.closeRect(strip, 0).?;
    try testing.expectEqual(@as(?usize, 0), s.closeAt(strip, .{ .x = close.x + 5, .y = close.y + 5 }));

    // Scrolled to the end, the first tab is gone and the last in view.
    s.scrollBy(1000);
    try testing.expect(s.rect(strip, 0) == null);
    try testing.expectEqual(@as(?usize, 3), s.tabAt(strip, .{ .x = 120, .y = 15 }));
}
