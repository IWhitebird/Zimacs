//! The colours in use.
//!
//! Built from the config once at start-up, so every drawing call reads plain
//! fields rather than converting hex numbers each frame.

const std = @import("std");
const pen = @import("raylib");
const Colors = @import("config.zig").Colors;

pub const Theme = struct {
    background: pen.Color,
    text: pen.Color,
    current_line: pen.Color,
    selection: pen.Color,
    gutter_text: pen.Color,
    gutter_text_active: pen.Color,
    status_background: pen.Color,
    status_text: pen.Color,
    tab_background: pen.Color,
    tab_active: pen.Color,
    tab_text: pen.Color,
    tab_text_active: pen.Color,
    caret: pen.Color,
    hint: pen.Color,
    scrollbar: pen.Color,
    scrollbar_hover: pen.Color,
    close_hover: pen.Color,
    close_hover_text: pen.Color,
};

pub var current: Theme = build(.{});

pub fn apply(colors: Colors) void {
    current = build(colors);
}

fn build(c: Colors) Theme {
    return .{
        .background = rgb(c.background),
        .text = rgb(c.text),
        .current_line = rgb(c.current_line),
        .selection = rgb(c.selection),
        .gutter_text = rgb(c.gutter_text),
        .gutter_text_active = rgb(c.gutter_text_active),
        .status_background = rgb(c.status_background),
        .status_text = rgb(c.status_text),
        .tab_background = rgb(c.tab_background),
        .tab_active = rgb(c.tab_active),
        .tab_text = rgb(c.tab_text),
        .tab_text_active = rgb(c.tab_text_active),
        .caret = rgb(c.caret),
        .hint = rgb(c.hint),
        .scrollbar = rgb(c.scrollbar),
        .scrollbar_hover = rgb(c.scrollbar_hover),
        .close_hover = rgb(c.close_hover),
        .close_hover_text = rgb(c.close_hover_text),
    };
}

fn rgb(value: u24) pen.Color {
    return .{
        .r = @intCast(value >> 16 & 0xFF),
        .g = @intCast(value >> 8 & 0xFF),
        .b = @intCast(value & 0xFF),
        .a = 255,
    };
}

test "hex splits into channels" {
    const c = rgb(0x181818);
    try std.testing.expectEqual(@as(u8, 24), c.r);
    try std.testing.expectEqual(@as(u8, 24), c.g);
    try std.testing.expectEqual(@as(u8, 24), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "config colours reach the theme" {
    apply(.{ .background = 0x102030, .caret = 0xFFEEDD });
    try std.testing.expectEqual(@as(u8, 0x10), current.background.r);
    try std.testing.expectEqual(@as(u8, 0xDD), current.caret.b);
    apply(.{});
}
