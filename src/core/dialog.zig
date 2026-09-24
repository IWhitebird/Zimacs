//! A modal question with a row of buttons, such as whether to save before
//! closing a tab. Holds what is asked and where its parts sit; drawn by
//! `editor.zig`, answered through `input.zig` and `commands.zig`.

const std = @import("std");
const pen = @import("raylib");
const layout = @import("layout.zig");
const text = @import("text.zig");
const Font = @import("font.zig").Font;
const BufferView = @import("buffer.zig").BufferView;
const Layout = layout.Layout;

pub const Answer = enum { save, discard, cancel, reload, keep };

pub const Question = union(enum) {
    close_unsaved: *BufferView,
    changed_on_disk: *BufferView,

    pub fn view(q: Question) *BufferView {
        return switch (q) {
            inline else => |v| v,
        };
    }

    /// Left to right; the first is the default.
    pub fn answers(q: Question) []const Answer {
        return switch (q) {
            .close_unsaved => &.{ .save, .discard, .cancel },
            .changed_on_disk => &.{ .reload, .keep },
        };
    }

    /// What Escape means: whichever choice loses nothing.
    pub fn dismissal(q: Question) Answer {
        return switch (q) {
            .close_unsaved => .cancel,
            .changed_on_disk => .keep,
        };
    }
};

pub fn label(a: Answer) [:0]const u8 {
    return switch (a) {
        .save => "Save",
        .discard => "Don't Save",
        .cancel => "Cancel",
        .reload => "Reload",
        .keep => "Keep Mine",
    };
}

/// Names wider than this many columns are shortened in the title.
const max_name = 48;

pub fn title(buf: []u8, q: Question) [:0]const u8 {
    // Cut from the start, whole characters only, so the extension shows.
    var name_buf: [title_capacity]u8 = undefined;
    const name = text.fitStart(&name_buf, q.view().name, max_name);
    return switch (q) {
        .close_unsaved => std.fmt.bufPrintZ(buf, "Save changes to {s}?", .{name}),
        .changed_on_disk => std.fmt.bufPrintZ(buf, "{s} changed on disk.", .{name}),
    } catch "";
}

pub fn detail(q: Question) [:0]const u8 {
    return switch (q) {
        .close_unsaved => "Your changes will be lost if you don't save them.",
        .changed_on_disk => "Reload it, or keep the version you have been editing?",
    };
}

/// Room for any title `title` can produce.
pub const title_capacity = 128;

pub const Dialog = struct {
    question: ?Question = null,
    focus: usize = 0,

    pub fn ask(d: *Dialog, q: Question) void {
        d.question = q;
        d.focus = 0;
    }

    pub fn close(d: *Dialog) void {
        d.question = null;
    }

    pub fn move(d: *Dialog, delta: i32) void {
        const q = d.question orelse return;
        const n: i32 = @intCast(q.answers().len);
        d.focus = @intCast(@mod(@as(i32, @intCast(d.focus)) + delta, n));
    }

    pub fn focused(d: Dialog) ?Answer {
        const q = d.question orelse return null;
        return q.answers()[d.focus];
    }
};

// ------------------------------------------------------------- geometry

pub const max_buttons = 3;

pub const Geometry = struct {
    panel: pen.Rectangle,
    buttons: [max_buttons]pen.Rectangle,
    count: usize,
};

/// Centred over the window.
pub fn geometry(l: Layout, font: Font, q: Question) Geometry {
    const pad = layout.padding;
    var title_buf: [title_capacity]u8 = undefined;
    const heading = title(&title_buf, q);
    const answers = q.answers();

    var widths: [max_buttons]f32 = undefined;
    var buttons_width: f32 = 0;
    for (answers, 0..) |a, i| {
        widths[i] = font.widthOf(label(a)) + pad * 4;
        buttons_width += widths[i] + if (i > 0) pad else 0;
    }

    const window_width = l.menu.width;
    const window_height = l.status.y + l.status.height;
    const content = @max(font.widthOf(heading), font.widthOf(detail(q)), buttons_width);
    const width = @min(content + pad * 6, window_width - pad * 2);
    const line = font.metrics.height;
    const button_height = line + pad * 1.5;
    const height = pad * 3 + line * 2 + pad * 1.5 + button_height + pad * 2;

    const panel = pen.Rectangle{
        .x = @round((window_width - width) / 2),
        .y = @round((window_height - height) / 2),
        .width = width,
        .height = height,
    };

    var g = Geometry{ .panel = panel, .buttons = undefined, .count = answers.len };
    var x = panel.x + panel.width - pad * 3;
    var i = answers.len;
    while (i > 0) {
        i -= 1;
        x -= widths[i];
        g.buttons[i] = .{ .x = x, .y = panel.y + panel.height - pad * 2 - button_height, .width = widths[i], .height = button_height };
        x -= pad;
    }
    return g;
}

pub fn buttonAt(point: pen.Vector2, g: Geometry) ?usize {
    for (g.buttons[0..g.count], 0..) |r, i| {
        if (pen.checkCollisionPointRec(point, r)) return i;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

fn testLayout() Layout {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .menu = .{ .x = 0, .y = 0, .width = 900, .height = 32 },
        .tabs = zero,
        .gutter = zero,
        .text = zero,
        .scrollbar = zero,
        .status = .{ .x = 0, .y = 600, .width = 900, .height = 24 },
    };
}

const test_font = Font{ .metrics = .{ .width = 8, .height = 16 } };

test "buttons sit inside the panel, in order, without overlapping" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try b.newScratch();

    for ([_]Question{ .{ .close_unsaved = view }, .{ .changed_on_disk = view } }) |q| {
        const g = geometry(testLayout(), test_font, q);
        try testing.expectEqual(q.answers().len, g.count);
        var previous_end: f32 = g.panel.x;
        for (g.buttons[0..g.count]) |r| {
            try testing.expect(r.x >= previous_end);
            try testing.expect(r.x + r.width <= g.panel.x + g.panel.width);
            try testing.expect(r.y + r.height <= g.panel.y + g.panel.height);
            previous_end = r.x + r.width;
        }
    }
}

test "the middle of each button picks it" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const g = geometry(testLayout(), test_font, .{ .close_unsaved = try b.newScratch() });
    for (g.buttons[0..g.count], 0..) |r, i| {
        try testing.expectEqual(i, buttonAt(.{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 }, g).?);
    }
    try testing.expect(buttonAt(.{ .x = 1, .y = 1 }, g) == null);
}

test "escape always picks the choice that loses nothing" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try b.newScratch();
    try testing.expectEqual(Answer.cancel, (Question{ .close_unsaved = view }).dismissal());
    try testing.expectEqual(Answer.keep, (Question{ .changed_on_disk = view }).dismissal());
}

test "focus cycles through the buttons and wraps" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    var d = Dialog{};
    d.ask(.{ .close_unsaved = try b.newScratch() });
    try testing.expectEqual(Answer.save, d.focused().?);
    d.move(-1);
    try testing.expectEqual(Answer.cancel, d.focused().?);
    d.move(1);
    d.move(1);
    try testing.expectEqual(Answer.discard, d.focused().?);
}

test "a very long file name is shortened in the title" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try b.newFilled("x" ** 200, "");
    var buf: [title_capacity]u8 = undefined;
    const t = title(&buf, .{ .close_unsaved = view });
    try testing.expect(std.mem.startsWith(u8, t, "Save changes to ..."));
    try testing.expect(t.len < title_capacity);
}
