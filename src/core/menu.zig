//! What the menu bar contains and where each part of it sits.
//!
//! The menus are plain data: `bar` lists them, and picking an entry yields an
//! `Action` for `commands.zig` to carry out. Nothing here draws or touches
//! buffers, so the whole layer can be laid out and hit-tested in tests.

const std = @import("std");
const pen = @import("raylib");
const layout = @import("layout.zig");
const Font = @import("font.zig").Font;
const Layout = layout.Layout;

pub const Action = enum {
    new_tab,
    open_file,
    open_recent,
    save,
    save_as,
    close_tab,

    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    find,

    delete_line,
    duplicate_line,
    move_line_up,
    move_line_down,
    open_line_below,
    open_line_above,
    indent,
    outdent,
    goto_line,

    zoom_in,
    zoom_out,
    zoom_reset,

    open_config,
    check_updates,
    about,
};

pub const Entry = struct {
    label: [:0]const u8,
    shortcut: [:0]const u8 = "",
    action: Action,
};

pub const Group = struct {
    title: [:0]const u8,
    entries: []const Entry,
};

pub const bar = [_]Group{
    .{ .title = "File", .entries = &.{
        .{ .label = "New Tab", .shortcut = "Ctrl+N", .action = .new_tab },
        .{ .label = "Open...", .shortcut = "Ctrl+O", .action = .open_file },
        .{ .label = "Open Recent", .shortcut = "Ctrl+R", .action = .open_recent },
        .{ .label = "Save", .shortcut = "Ctrl+S", .action = .save },
        .{ .label = "Save As...", .shortcut = "Ctrl+Shift+S", .action = .save_as },
        .{ .label = "Close Tab", .shortcut = "Ctrl+W", .action = .close_tab },
    } },
    .{ .title = "Edit", .entries = &.{
        .{ .label = "Undo", .shortcut = "Ctrl+Z", .action = .undo },
        .{ .label = "Redo", .shortcut = "Ctrl+Y", .action = .redo },
        .{ .label = "Cut", .shortcut = "Ctrl+X", .action = .cut },
        .{ .label = "Copy", .shortcut = "Ctrl+C", .action = .copy },
        .{ .label = "Paste", .shortcut = "Ctrl+V", .action = .paste },
        .{ .label = "Select All", .shortcut = "Ctrl+A", .action = .select_all },
        .{ .label = "Find...", .shortcut = "Ctrl+F", .action = .find },
        .{ .label = "Go to Line...", .shortcut = "Ctrl+G", .action = .goto_line },
        .{ .label = "Delete Line", .shortcut = "Ctrl+Shift+K", .action = .delete_line },
        .{ .label = "Duplicate Line", .shortcut = "Ctrl+D", .action = .duplicate_line },
        .{ .label = "Move Line Up", .shortcut = "Alt+Up", .action = .move_line_up },
        .{ .label = "Move Line Down", .shortcut = "Alt+Down", .action = .move_line_down },
        .{ .label = "Insert Line Below", .shortcut = "Ctrl+Enter", .action = .open_line_below },
        .{ .label = "Insert Line Above", .shortcut = "Ctrl+Shift+Enter", .action = .open_line_above },
        .{ .label = "Indent", .shortcut = "Tab", .action = .indent },
        .{ .label = "Outdent", .shortcut = "Shift+Tab", .action = .outdent },
    } },
    .{ .title = "View", .entries = &.{
        .{ .label = "Zoom In", .shortcut = "Ctrl+=", .action = .zoom_in },
        .{ .label = "Zoom Out", .shortcut = "Ctrl+-", .action = .zoom_out },
        .{ .label = "Reset Zoom", .shortcut = "Ctrl+0", .action = .zoom_reset },
    } },
    .{ .title = "Help", .entries = &.{
        .{ .label = "Edit Settings", .shortcut = "Ctrl+,", .action = .open_config },
        .{ .label = "Check for Updates", .action = .check_updates },
        .{ .label = "About Zimacs", .action = .about },
    } },
};

/// Gap between an entry's label and its shortcut.
const shortcut_gap: f32 = 24;

pub const Menu = struct {
    /// Which menu is dropped down, if any.
    open: ?usize = null,
    showing_about: bool = false,

    /// True while the menu wants the pointer to itself.
    pub fn capturing(m: Menu) bool {
        return m.open != null or m.showing_about;
    }

    pub fn close(m: *Menu) void {
        m.open = null;
    }
};

// ------------------------------------------------------------- geometry

pub fn entryHeight(font: Font) f32 {
    return font.metrics.height + layout.padding * 0.75;
}

pub fn titleRect(index: usize, l: Layout, font: Font) pen.Rectangle {
    var x = l.menu.x;
    for (bar, 0..) |group, i| {
        const width = font.widthOf(group.title) + layout.padding * 2;
        if (i == index) return .{ .x = x, .y = l.menu.y, .width = width, .height = l.menu.height };
        x += width;
    }
    return .{ .x = x, .y = l.menu.y, .width = 0, .height = l.menu.height };
}

pub fn titleAt(point: pen.Vector2, l: Layout, font: Font) ?usize {
    if (!pen.checkCollisionPointRec(point, l.menu)) return null;
    for (bar, 0..) |_, i| {
        if (pen.checkCollisionPointRec(point, titleRect(i, l, font))) return i;
    }
    return null;
}

pub fn dropdownRect(index: usize, l: Layout, font: Font) pen.Rectangle {
    const anchor = titleRect(index, l, font);
    var widest: f32 = 0;
    for (bar[index].entries) |entry| {
        var width = font.widthOf(entry.label) + layout.padding * 2;
        if (entry.shortcut.len > 0) width += font.widthOf(entry.shortcut) + shortcut_gap;
        widest = @max(widest, width);
    }
    return .{
        .x = anchor.x,
        .y = anchor.y + anchor.height,
        .width = widest,
        .height = @as(f32, @floatFromInt(bar[index].entries.len)) * entryHeight(font) +
            layout.padding,
    };
}

/// Where entry `row` of the open menu sits.
pub fn entryRect(index: usize, row: usize, l: Layout, font: Font) pen.Rectangle {
    const panel = dropdownRect(index, l, font);
    const height = entryHeight(font);
    return .{
        .x = panel.x,
        .y = panel.y + layout.padding / 2 + @as(f32, @floatFromInt(row)) * height,
        .width = panel.width,
        .height = height,
    };
}

pub fn entryAt(point: pen.Vector2, index: usize, l: Layout, font: Font) ?Action {
    const panel = dropdownRect(index, l, font);
    if (!pen.checkCollisionPointRec(point, panel)) return null;

    const offset = point.y - (panel.y + layout.padding / 2);
    if (offset < 0) return null;
    const row: usize = @intFromFloat(@floor(offset / entryHeight(font)));
    if (row >= bar[index].entries.len) return null;
    return bar[index].entries[row].action;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A window-sized layout, so geometry can be checked without a window.
fn testLayout() Layout {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .menu = .{ .x = 0, .y = 0, .width = 800, .height = 24 },
        .tabs = zero,
        .gutter = zero,
        .text = .{ .x = 0, .y = 24, .width = 800, .height = 400 },
        .scrollbar = zero,
        .status = .{ .x = 0, .y = 424, .width = 800, .height = 24 },
    };
}

test "every action appears in the bar exactly once" {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        var seen: usize = 0;
        for (bar) |group| {
            for (group.entries) |entry| {
                if (entry.action == action) seen += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
}

test "labels are never empty" {
    for (bar) |group| {
        try testing.expect(group.title.len > 0);
        for (group.entries) |entry| try testing.expect(entry.label.len > 0);
    }
}

test "titles sit side by side and do not overlap" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();

    var previous_end: f32 = -1;
    for (bar, 0..) |_, i| {
        const rect = titleRect(i, l, font);
        try testing.expect(rect.x >= previous_end);
        try testing.expect(rect.width > 0);
        previous_end = rect.x + rect.width;
    }
}

test "a dropdown hangs below its title and is wide enough for its entries" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();

    for (bar, 0..) |group, i| {
        const title = titleRect(i, l, font);
        const panel = dropdownRect(i, l, font);
        try testing.expectEqual(title.x, panel.x);
        try testing.expectApproxEqAbs(title.y + title.height, panel.y, 0.01);
        try testing.expect(panel.width >= title.width);
        try testing.expect(panel.height >= @as(f32, @floatFromInt(group.entries.len)) * entryHeight(font));
    }
}

test "the point at each entry's middle picks that entry" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();

    for (bar, 0..) |group, i| {
        for (group.entries, 0..) |entry, row| {
            const rect = entryRect(i, row, l, font);
            const middle = pen.Vector2{
                .x = rect.x + rect.width / 2,
                .y = rect.y + rect.height / 2,
            };
            try testing.expectEqual(entry.action, entryAt(middle, i, l, font).?);
        }
    }
}

test "a point outside the dropdown picks nothing" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();
    const panel = dropdownRect(0, l, font);

    try testing.expect(entryAt(.{ .x = panel.x - 5, .y = panel.y + 5 }, 0, l, font) == null);
    try testing.expect(entryAt(.{ .x = panel.x + 5, .y = panel.y + panel.height + 50 }, 0, l, font) == null);
}

test "capturing follows the open state" {
    var m = Menu{};
    try testing.expect(!m.capturing());
    m.open = 0;
    try testing.expect(m.capturing());
    m.close();
    try testing.expect(!m.capturing());
    m.showing_about = true;
    try testing.expect(m.capturing());
}
