//! What the menus contain and where each part of them sits: the menu bar,
//! and the menu a right click on a tab opens.
//!
//! The menus are plain data: `bar` and `tab_menu` list them, and picking an
//! entry yields an `Action` for `commands.zig` to carry out. Nothing here
//! draws or touches buffers, so the whole layer can be laid out and
//! hit-tested in tests.

const std = @import("std");
const pen = @import("raylib");
const layout = @import("layout.zig");
const Font = @import("font.zig").Font;
const Layout = layout.Layout;

pub const Action = enum {
    new_tab,
    open_file,
    open_folder,
    close_folder,
    open_memory,
    quick_open,
    search_folder,
    open_recent,
    reopen_tab,
    save,
    save_as,
    close_tab,
    close_others,
    close_left,
    close_right,
    close_saved,
    close_all,
    copy_path,

    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    find,
    replace,
    find_next,
    find_previous,

    delete_line,
    duplicate_line,
    move_line_up,
    move_line_down,
    open_line_below,
    open_line_above,
    indent,
    outdent,
    toggle_comment,
    goto_line,

    command_palette,
    toggle_wrap,
    toggle_sidebar,
    backlinks,
    graph_view,
    zoom_in,
    zoom_out,
    zoom_reset,

    settings,
    open_config,
    check_updates,
    report_problem,
    copy_mcp_command,
    about,
};

pub const Entry = struct {
    label: [:0]const u8,
    shortcut: [:0]const u8 = "",
    action: Action,
    /// Shows a tick when the setting it toggles is on.
    checkable: bool = false,
};

pub const Group = struct {
    title: [:0]const u8,
    entries: []const Entry,
};

pub const bar = [_]Group{
    .{ .title = "File", .entries = &.{
        .{ .label = "New Tab", .shortcut = "Ctrl+N", .action = .new_tab },
        .{ .label = "Open...", .shortcut = "Ctrl+O", .action = .open_file },
        .{ .label = "Open Folder...", .shortcut = "Ctrl+Shift+O", .action = .open_folder },
        .{ .label = "Go to File...", .shortcut = "Ctrl+P", .action = .quick_open },
        .{ .label = "Close Folder", .action = .close_folder },
        .{ .label = "Open Memory Folder (Beta)", .action = .open_memory },
        .{ .label = "Open Recent", .shortcut = "Ctrl+R", .action = .open_recent },
        .{ .label = "Reopen Closed Tab", .shortcut = "Ctrl+Shift+T", .action = .reopen_tab },
        .{ .label = "Save", .shortcut = "Ctrl+S", .action = .save },
        .{ .label = "Save As...", .shortcut = "Ctrl+Shift+S", .action = .save_as },
        .{ .label = "Close Tab", .shortcut = "Ctrl+W", .action = .close_tab },
        .{ .label = "Close All Tabs", .action = .close_all },
    } },
    .{ .title = "Edit", .entries = &.{
        .{ .label = "Undo", .shortcut = "Ctrl+Z", .action = .undo },
        .{ .label = "Redo", .shortcut = "Ctrl+Y", .action = .redo },
        .{ .label = "Cut", .shortcut = "Ctrl+X", .action = .cut },
        .{ .label = "Copy", .shortcut = "Ctrl+C", .action = .copy },
        .{ .label = "Paste", .shortcut = "Ctrl+V", .action = .paste },
        .{ .label = "Select All", .shortcut = "Ctrl+A", .action = .select_all },
        .{ .label = "Find...", .shortcut = "Ctrl+F", .action = .find },
        .{ .label = "Replace...", .shortcut = "Ctrl+H", .action = .replace },
        .{ .label = "Find in Folder...", .shortcut = "Ctrl+Shift+F", .action = .search_folder },
        .{ .label = "Find Next", .shortcut = "F3", .action = .find_next },
        .{ .label = "Find Previous", .shortcut = "Shift+F3", .action = .find_previous },
        .{ .label = "Go to Line...", .shortcut = "Ctrl+G", .action = .goto_line },
        .{ .label = "Delete Line", .shortcut = "Ctrl+Shift+K", .action = .delete_line },
        .{ .label = "Duplicate Line", .shortcut = "Ctrl+D", .action = .duplicate_line },
        .{ .label = "Move Line Up", .shortcut = "Alt+Up", .action = .move_line_up },
        .{ .label = "Move Line Down", .shortcut = "Alt+Down", .action = .move_line_down },
        .{ .label = "Insert Line Below", .shortcut = "Ctrl+Enter", .action = .open_line_below },
        .{ .label = "Insert Line Above", .shortcut = "Ctrl+Shift+Enter", .action = .open_line_above },
        .{ .label = "Indent", .shortcut = "Tab", .action = .indent },
        .{ .label = "Outdent", .shortcut = "Shift+Tab", .action = .outdent },
        .{ .label = "Toggle Comment", .shortcut = "Ctrl+/", .action = .toggle_comment },
    } },
    .{ .title = "View", .entries = &.{
        .{ .label = "Command Palette...", .shortcut = "Ctrl+Shift+P", .action = .command_palette },
        .{ .label = "Word Wrap", .shortcut = "Alt+Z", .action = .toggle_wrap, .checkable = true },
        .{ .label = "Folder Tree", .shortcut = "Ctrl+B", .action = .toggle_sidebar, .checkable = true },
        .{ .label = "Backlinks", .shortcut = "Ctrl+Shift+B", .action = .backlinks },
        .{ .label = "Graph", .shortcut = "Ctrl+Shift+G", .action = .graph_view, .checkable = true },
        .{ .label = "Zoom In", .shortcut = "Ctrl+=", .action = .zoom_in },
        .{ .label = "Zoom Out", .shortcut = "Ctrl+-", .action = .zoom_out },
        .{ .label = "Reset Zoom", .shortcut = "Ctrl+0", .action = .zoom_reset },
    } },
    .{ .title = "Help", .entries = &.{
        .{ .label = "Settings...", .shortcut = "Ctrl+,", .action = .settings },
        .{ .label = "Open Settings File", .action = .open_config },
        .{ .label = "Check for Updates", .action = .check_updates },
        .{ .label = "Report a Problem", .action = .report_problem },
        .{ .label = "Copy MCP Command (Beta)", .action = .copy_mcp_command },
        .{ .label = "About Zimacs", .action = .about },
    } },
};

/// What a right click on a tab offers, for that tab.
pub const tab_menu = [_]Entry{
    .{ .label = "Close", .shortcut = "Ctrl+W", .action = .close_tab },
    .{ .label = "Close Others", .action = .close_others },
    .{ .label = "Close Tabs to the Left", .action = .close_left },
    .{ .label = "Close Tabs to the Right", .action = .close_right },
    .{ .label = "Close Saved Tabs", .action = .close_saved },
    .{ .label = "Close All Tabs", .action = .close_all },
    .{ .label = "Copy Path", .action = .copy_path },
    .{ .label = "Reopen Closed Tab", .shortcut = "Ctrl+Shift+T", .action = .reopen_tab },
};

/// Gap between an entry's label and its shortcut.
const shortcut_gap: f32 = 24;

pub const Menu = struct {
    /// Which menu of the bar is dropped down, if any.
    open: ?usize = null,
    /// Where the tab menu was opened, while it is.
    tab_menu_at: ?pen.Vector2 = null,
    showing_about: bool = false,

    /// True while the menu wants the pointer to itself.
    pub fn capturing(m: Menu) bool {
        return m.open != null or m.tab_menu_at != null or m.showing_about;
    }

    pub fn close(m: *Menu) void {
        m.open = null;
        m.tab_menu_at = null;
    }

    /// The menu showing, if one is.
    pub fn panel(m: Menu, l: Layout, font: Font) ?Panel {
        if (m.open) |index| return dropdown(index, l, font);
        if (m.tab_menu_at) |at| return tabMenu(at, l, font);
        return null;
    }
};

// ------------------------------------------------------------- geometry

/// The menu entry that runs `action`, for its name and keys.
pub fn entryFor(action: Action) ?Entry {
    for (bar) |group| for (group.entries) |e| if (e.action == action) return e;
    return null;
}

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

/// A box of entries: a menu dropped down from the bar, or the tab menu.
pub const Panel = struct {
    entries: []const Entry,
    /// Where its top left corner sits.
    origin: pen.Vector2,

    pub fn rect(p: Panel, font: Font) pen.Rectangle {
        var widest: f32 = 0;
        for (p.entries) |entry| {
            var width = p.checkWidth(font) + font.widthOf(entry.label) + layout.padding * 2;
            if (entry.shortcut.len > 0) width += font.widthOf(entry.shortcut) + shortcut_gap;
            widest = @max(widest, width);
        }
        return .{
            .x = p.origin.x,
            .y = p.origin.y,
            .width = widest,
            .height = @as(f32, @floatFromInt(p.entries.len)) * entryHeight(font) + layout.padding,
        };
    }

    /// Room for the tick, reserved only where an entry can have one.
    pub fn checkWidth(p: Panel, font: Font) f32 {
        for (p.entries) |entry| {
            if (entry.checkable) return font.metrics.width * 2;
        }
        return 0;
    }

    /// Where entry `row` sits.
    pub fn entryRect(p: Panel, row: usize, font: Font) pen.Rectangle {
        const height = entryHeight(font);
        return .{
            .x = p.origin.x,
            .y = p.origin.y + layout.padding / 2 + @as(f32, @floatFromInt(row)) * height,
            .width = p.rect(font).width,
            .height = height,
        };
    }

    pub fn entryAt(p: Panel, point: pen.Vector2, font: Font) ?Entry {
        const box = p.rect(font);
        if (!pen.checkCollisionPointRec(point, box)) return null;
        const offset = point.y - (box.y + layout.padding / 2);
        if (offset < 0) return null;
        const row: usize = @intFromFloat(@floor(offset / entryHeight(font)));
        if (row >= p.entries.len) return null;
        return p.entries[row];
    }
};

/// Menu `index` of the bar, dropped down below its title.
pub fn dropdown(index: usize, l: Layout, font: Font) Panel {
    const anchor = titleRect(index, l, font);
    return .{ .entries = bar[index].entries, .origin = .{ .x = anchor.x, .y = anchor.y + anchor.height } };
}

/// The tab menu, opened at `at` and moved in as far as it takes to keep it
/// inside the window.
pub fn tabMenu(at: pen.Vector2, l: Layout, font: Font) Panel {
    var p = Panel{ .entries = &tab_menu, .origin = at };
    const box = p.rect(font);
    p.origin.x = @max(@min(at.x, l.menu.width - box.width), 0);
    p.origin.y = @max(@min(at.y, l.status.y + l.status.height - box.height), 0);
    return p;
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

test "every action is in some menu, and no menu lists one twice" {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        var in_bar: usize = 0;
        for (bar) |group| {
            for (group.entries) |entry| {
                if (entry.action == action) in_bar += 1;
            }
        }
        var in_tab_menu: usize = 0;
        for (tab_menu) |entry| {
            if (entry.action == action) in_tab_menu += 1;
        }
        try testing.expect(in_bar <= 1 and in_tab_menu <= 1 and in_bar + in_tab_menu >= 1);
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
        const panel = dropdown(i, l, font).rect(font);
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
        const panel = dropdown(i, l, font);
        for (group.entries, 0..) |entry, row| {
            const rect = panel.entryRect(row, font);
            const middle = pen.Vector2{
                .x = rect.x + rect.width / 2,
                .y = rect.y + rect.height / 2,
            };
            try testing.expectEqual(entry.action, panel.entryAt(middle, font).?.action);
        }
    }
}

test "a point outside the dropdown picks nothing" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();
    const panel = dropdown(0, l, font);
    const box = panel.rect(font);

    try testing.expect(panel.entryAt(.{ .x = box.x - 5, .y = box.y + 5 }, font) == null);
    try testing.expect(panel.entryAt(.{ .x = box.x + 5, .y = box.y + box.height + 50 }, font) == null);
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
    m.showing_about = false;
    m.tab_menu_at = .{ .x = 10, .y = 10 };
    try testing.expect(m.capturing());
    m.close();
    try testing.expect(!m.capturing());
}

test "the tab menu opens at the pointer but stays inside the window" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const l = testLayout();
    const here = tabMenu(.{ .x = 50, .y = 30 }, l, font);
    try testing.expectEqual(@as(f32, 50), here.origin.x);
    const corner = tabMenu(.{ .x = 790, .y = 440 }, l, font).rect(font);
    try testing.expect(corner.x + corner.width <= l.menu.width);
    try testing.expect(corner.y + corner.height <= l.status.y + l.status.height);
}

test "only a menu with a checkable entry reserves room for the tick" {
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    for (bar, 0..) |group, i| {
        var any = false;
        for (group.entries) |entry| any = any or entry.checkable;
        try testing.expectEqual(any, dropdown(i, testLayout(), font).checkWidth(font) > 0);
    }
}
