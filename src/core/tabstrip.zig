//! The tab bar's geometry: where each tab and its close button sit, the
//! button after them that opens a new tab, and horizontal scrolling once the
//! tabs no longer fit, which keeps the active tab in view and lets the wheel
//! scroll the rest.

const std = @import("std");
const pen = @import("raylib");
const padding = @import("layout.zig").padding;

pub const TabStrip = struct {
    /// Each tab's width, measured by the caller before `update`.
    widths: std.ArrayList(f32) = .empty,
    /// Side of the square close button at the right of each tab.
    close_size: f32 = 0,
    /// Side of the square button after the tabs that opens a new one; 0 for
    /// none.
    new_size: f32 = 0,
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

    /// Brings `active` into view when it changes, and keeps the scroll in
    /// range, in a strip `width` wide.
    pub fn update(s: *TabStrip, width: f32, active: usize) void {
        const widths = s.widths.items;
        const visible = @max(width - s.newSlot(), 0);
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

    /// The part of `strip` the tabs scroll in, which leaves room at its
    /// right for the new-tab button.
    pub fn tabArea(s: TabStrip, strip: pen.Rectangle) pen.Rectangle {
        return .{ .x = strip.x, .y = strip.y, .width = @max(strip.width - s.newSlot(), 0), .height = strip.height };
    }

    fn newSlot(s: TabStrip) f32 {
        return if (s.new_size > 0) s.new_size + padding else 0;
    }

    /// The new-tab button: just after the last tab, or at the right of the
    /// strip once the tabs fill it.
    pub fn newRect(s: TabStrip, strip: pen.Rectangle) pen.Rectangle {
        const area = s.tabArea(strip);
        return .{
            .x = area.x + @min(s.total - s.scroll, area.width) + padding / 2,
            .y = strip.y + (strip.height - s.new_size) / 2,
            .width = s.new_size,
            .height = s.new_size,
        };
    }

    /// Where tab `index` sits in `strip`, or null when it is scrolled wholly
    /// out of it.
    pub fn rect(s: TabStrip, strip: pen.Rectangle, index: usize) ?pen.Rectangle {
        const widths = s.widths.items;
        if (index >= widths.len) return null;
        const area = s.tabArea(strip);
        var x = area.x - s.scroll;
        for (widths[0..index]) |w| x += w;
        if (x >= area.x + area.width or x + widths[index] <= area.x) return null;
        return .{ .x = x, .y = area.y, .width = widths[index], .height = area.height };
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
        if (!pen.checkCollisionPointRec(point, s.tabArea(strip))) return null;
        for (0..s.widths.items.len) |i| {
            if (s.rect(strip, i)) |r| if (pen.checkCollisionPointRec(point, r)) return i;
        }
        return null;
    }

    /// Which tab's close button is under `point`.
    pub fn closeAt(s: TabStrip, strip: pen.Rectangle, point: pen.Vector2) ?usize {
        if (!pen.checkCollisionPointRec(point, s.tabArea(strip))) return null;
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

test "the new-tab button follows the last tab, and stays at the edge once they overflow" {
    const strip = pen.Rectangle{ .x = 0, .y = 0, .width = 300, .height = 30 };
    var s = TabStrip{ .new_size = 20 };
    defer s.deinit(testing.allocator);
    try setWidths(&s, &.{ 60, 60 });
    s.update(strip.width, 0);
    try testing.expectEqual(@as(f32, 120 + padding / 2), s.newRect(strip).x);

    try setWidths(&s, &.{ 100, 100, 100, 100 });
    s.update(strip.width, 3);
    const button = s.newRect(strip);
    try testing.expect(button.x + button.width <= strip.width);
    // The last tab ends where the button's room begins, not under it.
    const last = s.rect(strip, 3).?;
    try testing.expectApproxEqAbs(s.tabArea(strip).width, last.x + last.width, 0.01);
    try testing.expect(s.tabAt(strip, .{ .x = button.x + 5, .y = 15 }) == null);
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
