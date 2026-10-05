//! The settings window: each setting with a control to change it. A change
//! applies at once and is written to the settings file, which stays where
//! everything is kept. Holds the settings and where they sit; drawn by
//! `editor.zig`, used through `input.zig` and `commands.zig`.

const std = @import("std");
const pen = @import("raylib");
const layout = @import("layout.zig");
const Layout = layout.Layout;
const Font = @import("font.zig").Font;
const config_mod = @import("config.zig");
const Config = config_mod.Config;

/// Each is the `Config` field, and settings file key, of the same name.
pub const Setting = enum {
    theme,
    font_size,
    tab_width,
    expand_tabs,
    auto_close,
    wrap_lines,
    caret_style,
    show_hidden,
    restore_session,
    auto_update,
    custom_titlebar,

    pub fn label(s: Setting) [:0]const u8 {
        return switch (s) {
            .theme => "Theme",
            .font_size => "Text size",
            .tab_width => "Tab width",
            .expand_tabs => "Indent with spaces",
            .auto_close => "Close brackets and quotes",
            .wrap_lines => "Wrap long lines",
            .caret_style => "Caret",
            .show_hidden => "Show hidden files",
            .restore_session => "Reopen the last session",
            .auto_update => "Install updates",
            .custom_titlebar => "Zimacs title bar (on restart)",
        };
    }

    /// Switched on and off, rather than stepped through values.
    pub fn isToggle(s: Setting) bool {
        return switch (s) {
            inline else => |tag| @FieldType(Config, @tagName(tag)) == bool,
        };
    }

    /// The lowest and highest a number may be.
    fn limits(s: Setting) [2]f32 {
        return switch (s) {
            .font_size => .{ Font.min_size, Font.max_size },
            .tab_width => .{ 1, config_mod.max_indent_unit },
            else => .{ 0, 0 },
        };
    }
};

pub const count = @typeInfo(Setting).@"enum".fields.len;

/// Flips a toggle, or steps a choice or number by `delta`, wrapping
/// through choices and stopping at a number's limits.
pub fn change(c: *Config, s: Setting, delta: i32) void {
    switch (s) {
        inline else => |tag| {
            const field = &@field(c, @tagName(tag));
            const T = @TypeOf(field.*);
            switch (@typeInfo(T)) {
                .bool => field.* = !field.*,
                .@"enum" => |e| {
                    const n: i32 = e.fields.len;
                    const next = @mod(@as(i32, @intFromEnum(field.*)) + delta, n);
                    field.* = @enumFromInt(next);
                },
                .int, .float => {
                    const range = s.limits();
                    const now: f32 = if (T == f32) field.* else @floatFromInt(field.*);
                    const next = std.math.clamp(now + @as(f32, @floatFromInt(delta)), range[0], range[1]);
                    field.* = if (T == f32) next else @intFromFloat(next);
                },
                else => @compileError("no control for a setting of type " ++ @typeName(T)),
            }
        },
    }
}

/// Whether a toggle is on.
pub fn isOn(c: *const Config, s: Setting) bool {
    return switch (s) {
        inline else => |tag| if (@FieldType(Config, @tagName(tag)) == bool) @field(c, @tagName(tag)) else false,
    };
}

/// What a choice or number shows; toggles show a box instead.
pub fn shown(c: *const Config, s: Setting, buf: []u8) [:0]const u8 {
    return switch (s) {
        .theme => std.fmt.bufPrintZ(buf, "{s}", .{c.theme.label()}),
        .caret_style => std.fmt.bufPrintZ(buf, "{s}", .{switch (c.caret_style) {
            .line => "Line",
            .block => "Block",
            .underline => "Underline",
        }}),
        .font_size => std.fmt.bufPrintZ(buf, "{d}", .{c.font_size}),
        .tab_width => std.fmt.bufPrintZ(buf, "{d}", .{c.tab_width}),
        else => std.fmt.bufPrintZ(buf, "", .{}),
    } catch "";
}

/// The value as the settings file writes it.
pub fn stored(c: *const Config, s: Setting, buf: []u8) []const u8 {
    return switch (s) {
        inline else => |tag| {
            const value = @field(c, @tagName(tag));
            return switch (@typeInfo(@TypeOf(value))) {
                .bool => if (value) "true" else "false",
                .@"enum" => @tagName(value),
                else => std.fmt.bufPrint(buf, "{d}", .{value}) catch "",
            };
        },
    };
}

pub const Settings = struct {
    shown: bool = false,
    /// The setting the keyboard changes.
    focus: Setting = .theme,

    pub fn open(s: *Settings) void {
        s.shown = true;
        s.focus = .theme;
    }

    /// Moves the focus up or down, wrapping round.
    pub fn move(s: *Settings, delta: i32) void {
        s.focus = @enumFromInt(@mod(@as(i32, @intFromEnum(s.focus)) + delta, @as(i32, count)));
    }
};

// ------------------------------------------------------------- geometry

pub const title = "Settings";
pub const open_file_label = "Open Settings File";
pub const close_label = "Close";
/// The widest value a choice shows, to size its column by.
const widest_value = "Solarized Light";

pub const Geometry = struct {
    panel: pen.Rectangle,
    /// Each setting's whole row.
    rows: [count]pen.Rectangle,
    /// The value of a choice or number, between the arrows that step it.
    value: [count]pen.Rectangle,
    less: [count]pen.Rectangle,
    more: [count]pen.Rectangle,
    /// The box of a toggle.
    check: [count]pen.Rectangle,
    open_file: pen.Rectangle,
    close: pen.Rectangle,
};

/// Centred over the window.
pub fn geometry(l: Layout, font: Font) Geometry {
    const pad = layout.padding;
    const line = font.metrics.height;
    const row_height = line + pad;
    const arrow = line;

    var labels: f32 = 0;
    inline for (@typeInfo(Setting).@"enum".fields) |field| labels = @max(labels, font.widthOf(@field(Setting, field.name).label()));
    const value_width = font.widthOf(widest_value);
    const control = arrow * 2 + value_width + pad * 2;
    const button_height = line + pad * 1.5;

    const window_width = l.menu.width;
    const window_height = l.status.y + l.status.height;
    const width = @min(labels + control + pad * 7, window_width - pad * 2);
    const height = pad * 3 + line + pad * 2 + row_height * count + pad * 2 + button_height + pad * 2;
    const panel = pen.Rectangle{
        .x = @round((window_width - width) / 2),
        .y = @round(@max((window_height - height) / 2, pad)),
        .width = width,
        .height = height,
    };

    var g: Geometry = undefined;
    g.panel = panel;
    const inner_x = panel.x + pad * 2;
    const inner_width = panel.width - pad * 4;
    const control_x = panel.x + panel.width - pad * 3 - control;
    var y = panel.y + pad * 3 + line + pad * 2;
    for (0..count) |i| {
        g.rows[i] = .{ .x = inner_x, .y = y, .width = inner_width, .height = row_height };
        const mid = y + (row_height - arrow) / 2;
        g.less[i] = .{ .x = control_x, .y = mid, .width = arrow, .height = arrow };
        g.value[i] = .{ .x = control_x + arrow + pad, .y = mid, .width = value_width, .height = arrow };
        g.more[i] = .{ .x = control_x + control - arrow, .y = mid, .width = arrow, .height = arrow };
        g.check[i] = .{ .x = control_x + control - arrow, .y = mid, .width = arrow, .height = arrow };
        y += row_height;
    }

    y += pad * 2;
    const close_width = font.widthOf(close_label) + pad * 4;
    const open_width = font.widthOf(open_file_label) + pad * 4;
    const right = panel.x + panel.width - pad * 3;
    g.close = .{ .x = right - close_width, .y = y, .width = close_width, .height = button_height };
    g.open_file = .{ .x = g.close.x - pad - open_width, .y = y, .width = open_width, .height = button_height };
    return g;
}

pub const Hit = union(enum) {
    less: Setting,
    more: Setting,
    toggle: Setting,
    open_file,
    close,
    /// Elsewhere on the panel, which a click leaves alone.
    panel,
};

pub fn hit(g: Geometry, point: pen.Vector2) ?Hit {
    if (pen.checkCollisionPointRec(point, g.open_file)) return .open_file;
    if (pen.checkCollisionPointRec(point, g.close)) return .close;
    for (g.rows, 0..) |row, i| {
        if (!pen.checkCollisionPointRec(point, row)) continue;
        const s: Setting = @enumFromInt(i);
        if (s.isToggle()) return .{ .toggle = s };
        if (pen.checkCollisionPointRec(point, g.less[i])) return .{ .less = s };
        if (pen.checkCollisionPointRec(point, g.more[i]) or pen.checkCollisionPointRec(point, g.value[i])) return .{ .more = s };
        return .panel;
    }
    if (pen.checkCollisionPointRec(point, g.panel)) return .panel;
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const palette = @import("palette.zig");

test "toggles flip, choices wrap round, and numbers stop at their limits" {
    var c = Config{};
    change(&c, .wrap_lines, 1);
    try testing.expect(c.wrap_lines);
    change(&c, .theme, -1);
    try testing.expectEqual(palette.Name.nord, c.theme);
    change(&c, .theme, 1);
    try testing.expectEqual(palette.Name.dark, c.theme);
    c.tab_width = 1;
    change(&c, .tab_width, -1);
    try testing.expectEqual(@as(u8, 1), c.tab_width);
    change(&c, .font_size, 1);
    try testing.expectEqual(@as(f32, 19), c.font_size);
}

test "the focus moves round the list both ways" {
    var s = Settings{};
    s.open();
    s.move(-1);
    try testing.expectEqual(Setting.custom_titlebar, s.focus);
    s.move(2);
    try testing.expectEqual(Setting.font_size, s.focus);
}

test "each setting is written as the file reads it back" {
    var c = Config{};
    change(&c, .theme, 3);
    change(&c, .font_size, 2);
    change(&c, .expand_tabs, 1);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var buf: [32]u8 = undefined;
    inline for (@typeInfo(Setting).@"enum".fields) |field| {
        const s = @field(Setting, field.name);
        try text.print(testing.allocator, "{s} = {s}\n", .{ field.name, stored(&c, s, &buf) });
    }
    var back = Config{};
    back.applyText(text.items);
    try testing.expect(back.problem == null);
    try testing.expectEqualDeep(c, back);
}

test "each row's controls are found where they are laid out" {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const l = Layout{
        .menu = .{ .x = 0, .y = 0, .width = 1200, .height = 30 },
        .tabs = zero,
        .gutter = zero,
        .text = zero,
        .scrollbar = zero,
        .status = .{ .x = 0, .y = 770, .width = 1200, .height = 30 },
    };
    const font = Font{ .metrics = .{ .width = 8, .height = 16 } };
    const g = geometry(l, font);
    const middle = struct {
        fn of(r: pen.Rectangle) pen.Vector2 {
            return .{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
        }
    }.of;
    try testing.expectEqual(Hit{ .less = .theme }, hit(g, middle(g.less[0])).?);
    try testing.expectEqual(Hit{ .more = .font_size }, hit(g, middle(g.value[1])).?);
    const wrap = @intFromEnum(Setting.wrap_lines);
    try testing.expectEqual(Hit{ .toggle = .wrap_lines }, hit(g, middle(g.rows[wrap])).?);
    try testing.expectEqual(Hit.close, hit(g, middle(g.close)).?);
    try testing.expect(hit(g, .{ .x = 1, .y = 1 }) == null);
    try testing.expect(g.panel.y + g.panel.height <= l.status.y + l.status.height);
}
