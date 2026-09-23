//! Horizontal scrolling of the tab bar once its tabs no longer fit: the
//! active tab is kept in view, and the wheel scrolls the rest.

const std = @import("std");

pub const TabStrip = struct {
    /// Pixels scrolled from the first tab.
    scroll: f32 = 0,
    /// Width of all tabs, and of the room for them, as of the last update.
    total: f32 = 0,
    visible: f32 = 0,
    /// The tab last brought into view, so the wheel is not undone next frame.
    followed: ?usize = null,

    /// Brings `active` into view when it changes, and keeps the scroll in range.
    pub fn update(s: *TabStrip, widths: []const f32, visible: f32, active: usize) void {
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
        return s.scroll > 0.5;
    }

    pub fn hiddenRight(s: TabStrip) bool {
        return s.scroll + s.visible < s.total - 0.5;
    }

    fn clamp(s: *TabStrip) void {
        s.scroll = std.math.clamp(s.scroll, 0, @max(s.total - s.visible, 0));
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "tabs that fit never scroll" {
    var s = TabStrip{};
    s.update(&.{ 100, 100 }, 500, 1);
    try testing.expectEqual(@as(f32, 0), s.scroll);
    try testing.expect(!s.hiddenLeft() and !s.hiddenRight());
}

test "switching to a tab off the right edge scrolls it fully into view" {
    var s = TabStrip{};
    const widths = [_]f32{ 100, 100, 100, 100, 100 };
    s.update(&widths, 250, 0);
    s.update(&widths, 250, 4);
    try testing.expectEqual(@as(f32, 250), s.scroll);
    try testing.expect(s.hiddenLeft() and !s.hiddenRight());

    s.update(&widths, 250, 1);
    try testing.expectEqual(@as(f32, 100), s.scroll);
}

test "the wheel scrolls, but only within the tabs" {
    var s = TabStrip{};
    const widths = [_]f32{ 100, 100, 100 };
    s.update(&widths, 150, 0);
    s.scrollBy(1000);
    try testing.expectEqual(@as(f32, 150), s.scroll);
    s.scrollBy(-1000);
    try testing.expectEqual(@as(f32, 0), s.scroll);
}

test "a wheel scroll is not undone while the active tab stays the same" {
    var s = TabStrip{};
    const widths = [_]f32{ 100, 100, 100 };
    s.update(&widths, 150, 0);
    s.scrollBy(80);
    s.update(&widths, 150, 0);
    try testing.expectEqual(@as(f32, 80), s.scroll);
}

test "closing tabs pulls the scroll back in range" {
    var s = TabStrip{};
    s.update(&.{ 100, 100, 100, 100 }, 150, 3);
    s.update(&.{ 100, 100 }, 150, 1);
    try testing.expect(s.scroll <= 50);
}
