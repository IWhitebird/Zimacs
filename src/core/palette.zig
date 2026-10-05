//! The built-in themes: every colour Zimacs draws with, for each. A colour
//! set in the settings file goes on top of the chosen theme.

const std = @import("std");

/// Every colour in use, as `0xRRGGBB`. No field has a default, so a theme
/// that leaves one out does not compile.
pub const Colors = struct {
    background: u24,
    text: u24,
    current_line: u24,
    selection: u24,
    gutter_text: u24,
    gutter_text_active: u24,
    status_background: u24,
    status_text: u24,
    tab_background: u24,
    tab_active: u24,
    tab_text: u24,
    tab_text_active: u24,
    caret: u24,
    hint: u24,
    scrollbar: u24,
    scrollbar_hover: u24,
    close_hover: u24,
    close_hover_text: u24,
    find_match: u24,
    selection_match: u24,
    bracket_match: u24,
    syntax_keyword: u24,
    syntax_string: u24,
    syntax_escape: u24,
    syntax_comment: u24,
    syntax_number: u24,
    syntax_constant: u24,
    syntax_function: u24,
    syntax_type: u24,
    syntax_property: u24,
    syntax_tag: u24,
    syntax_builtin: u24,
    warning: u24,
};

/// As the settings file names them.
pub const Name = enum {
    dark,
    light,
    solarized_dark,
    solarized_light,
    gruvbox_dark,
    nord,

    /// As the settings window shows it.
    pub fn label(n: Name) []const u8 {
        return switch (n) {
            .dark => "Dark",
            .light => "Light",
            .solarized_dark => "Solarized Dark",
            .solarized_light => "Solarized Light",
            .gruvbox_dark => "Gruvbox Dark",
            .nord => "Nord",
        };
    }

    pub fn colors(n: Name) Colors {
        return switch (n) {
            .dark => dark,
            .light => light,
            .solarized_dark => solarized_dark,
            .solarized_light => solarized_light,
            .gruvbox_dark => gruvbox_dark,
            .nord => nord,
        };
    }
};

pub const dark = Colors{
    .background = 0x181818,
    .text = 0xDEDEE6,
    .current_line = 0x212121,
    .selection = 0x264F78,
    .gutter_text = 0x5C6070,
    .gutter_text_active = 0xBEC3D7,
    .status_background = 0x121212,
    .status_text = 0xA0A5B9,
    .tab_background = 0x101010,
    .tab_active = 0x181818,
    .tab_text = 0x8A8F9E,
    .tab_text_active = 0xDEDEE6,
    .caret = 0x78C8FF,
    .hint = 0x6E7284,
    .scrollbar = 0x3A3A42,
    .scrollbar_hover = 0x55555F,
    .close_hover = 0xC42B1C,
    .close_hover_text = 0xFFFFFF,
    .find_match = 0x5C3F12,
    .selection_match = 0x2F3B48,
    .bracket_match = 0x3B4252,
    .syntax_keyword = 0xC586C0,
    .syntax_string = 0xCE9178,
    .syntax_escape = 0xD7BA7D,
    .syntax_comment = 0x6A9955,
    .syntax_number = 0xB5CEA8,
    .syntax_constant = 0x4FC1FF,
    .syntax_function = 0xDCDCAA,
    .syntax_type = 0x4EC9B0,
    .syntax_property = 0x9CDCFE,
    .syntax_tag = 0x569CD6,
    .syntax_builtin = 0x569CD6,
    .warning = 0xE5A94B,
};

const light = Colors{
    .background = 0xFFFFFF,
    .text = 0x1F1F1F,
    .current_line = 0xF2F4F7,
    .selection = 0xADD6FF,
    .gutter_text = 0x9EA3AD,
    .gutter_text_active = 0x2C2F36,
    .status_background = 0xEEEFF2,
    .status_text = 0x4F535C,
    .tab_background = 0xE6E8EC,
    .tab_active = 0xFFFFFF,
    .tab_text = 0x6B707A,
    .tab_text_active = 0x1F1F1F,
    .caret = 0x0066BF,
    .hint = 0x868B96,
    .scrollbar = 0xCDD0D6,
    .scrollbar_hover = 0xADB1B9,
    .close_hover = 0xC42B1C,
    .close_hover_text = 0xFFFFFF,
    .find_match = 0xF9D9A2,
    .selection_match = 0xDCE8F5,
    .bracket_match = 0xD6DEE8,
    .syntax_keyword = 0xAF00DB,
    .syntax_string = 0xA31515,
    .syntax_escape = 0xCD3131,
    .syntax_comment = 0x008000,
    .syntax_number = 0x098658,
    .syntax_constant = 0x0070C1,
    .syntax_function = 0x795E26,
    .syntax_type = 0x267F99,
    .syntax_property = 0x001080,
    .syntax_tag = 0x0000FF,
    .syntax_builtin = 0x0000FF,
    .warning = 0xB26A00,
};

const solarized_dark = Colors{
    .background = 0x002B36,
    .text = 0x93A1A1,
    .current_line = 0x073642,
    .selection = 0x1D4D57,
    .gutter_text = 0x586E75,
    .gutter_text_active = 0x93A1A1,
    .status_background = 0x00212B,
    .status_text = 0x839496,
    .tab_background = 0x00212B,
    .tab_active = 0x002B36,
    .tab_text = 0x657B83,
    .tab_text_active = 0xEEE8D5,
    .caret = 0x268BD2,
    .hint = 0x657B83,
    .scrollbar = 0x174652,
    .scrollbar_hover = 0x2A5D69,
    .close_hover = 0xDC322F,
    .close_hover_text = 0xFDF6E3,
    .find_match = 0x58500E,
    .selection_match = 0x0D3F4B,
    .bracket_match = 0x174652,
    .syntax_keyword = 0x859900,
    .syntax_string = 0x2AA198,
    .syntax_escape = 0xCB4B16,
    .syntax_comment = 0x586E75,
    .syntax_number = 0xD33682,
    .syntax_constant = 0xCB4B16,
    .syntax_function = 0x268BD2,
    .syntax_type = 0xB58900,
    .syntax_property = 0x6C71C4,
    .syntax_tag = 0x268BD2,
    .syntax_builtin = 0xDC322F,
    .warning = 0xB58900,
};

const solarized_light = Colors{
    .background = 0xFDF6E3,
    .text = 0x586E75,
    .current_line = 0xF3ECD8,
    .selection = 0xE2DCC6,
    .gutter_text = 0xA0AAAA,
    .gutter_text_active = 0x586E75,
    .status_background = 0xEEE8D5,
    .status_text = 0x657B83,
    .tab_background = 0xEEE8D5,
    .tab_active = 0xFDF6E3,
    .tab_text = 0x839496,
    .tab_text_active = 0x073642,
    .caret = 0x268BD2,
    .hint = 0x93A1A1,
    .scrollbar = 0xDCD6C2,
    .scrollbar_hover = 0xC8C2AE,
    .close_hover = 0xDC322F,
    .close_hover_text = 0xFDF6E3,
    .find_match = 0xF2DC9C,
    .selection_match = 0xEDE5CC,
    .bracket_match = 0xE4DEC8,
    .syntax_keyword = 0x859900,
    .syntax_string = 0x2AA198,
    .syntax_escape = 0xCB4B16,
    .syntax_comment = 0x93A1A1,
    .syntax_number = 0xD33682,
    .syntax_constant = 0xCB4B16,
    .syntax_function = 0x268BD2,
    .syntax_type = 0xB58900,
    .syntax_property = 0x6C71C4,
    .syntax_tag = 0x268BD2,
    .syntax_builtin = 0xDC322F,
    .warning = 0xB58900,
};

const gruvbox_dark = Colors{
    .background = 0x282828,
    .text = 0xEBDBB2,
    .current_line = 0x32302F,
    .selection = 0x504945,
    .gutter_text = 0x7C6F64,
    .gutter_text_active = 0xD5C4A1,
    .status_background = 0x1D2021,
    .status_text = 0xA89984,
    .tab_background = 0x1D2021,
    .tab_active = 0x282828,
    .tab_text = 0x928374,
    .tab_text_active = 0xEBDBB2,
    .caret = 0xFABD2F,
    .hint = 0x928374,
    .scrollbar = 0x3C3836,
    .scrollbar_hover = 0x504945,
    .close_hover = 0xCC241D,
    .close_hover_text = 0xFBF1C7,
    .find_match = 0x5E4D1E,
    .selection_match = 0x3C3836,
    .bracket_match = 0x45403D,
    .syntax_keyword = 0xFB4934,
    .syntax_string = 0xB8BB26,
    .syntax_escape = 0xFE8019,
    .syntax_comment = 0x928374,
    .syntax_number = 0xD3869B,
    .syntax_constant = 0xD3869B,
    .syntax_function = 0x8EC07C,
    .syntax_type = 0xFABD2F,
    .syntax_property = 0x83A598,
    .syntax_tag = 0x83A598,
    .syntax_builtin = 0xFE8019,
    .warning = 0xFABD2F,
};

const nord = Colors{
    .background = 0x2E3440,
    .text = 0xD8DEE9,
    .current_line = 0x353C4A,
    .selection = 0x434C5E,
    .gutter_text = 0x4C566A,
    .gutter_text_active = 0xD8DEE9,
    .status_background = 0x272C36,
    .status_text = 0xAEB7C6,
    .tab_background = 0x272C36,
    .tab_active = 0x2E3440,
    .tab_text = 0x6E7889,
    .tab_text_active = 0xECEFF4,
    .caret = 0x88C0D0,
    .hint = 0x616E88,
    .scrollbar = 0x434C5E,
    .scrollbar_hover = 0x4C566A,
    .close_hover = 0xBF616A,
    .close_hover_text = 0xECEFF4,
    .find_match = 0x5F5E4B,
    .selection_match = 0x3E4757,
    .bracket_match = 0x4C566A,
    .syntax_keyword = 0x81A1C1,
    .syntax_string = 0xA3BE8C,
    .syntax_escape = 0xEBCB8B,
    .syntax_comment = 0x616E88,
    .syntax_number = 0xB48EAD,
    .syntax_constant = 0xEBCB8B,
    .syntax_function = 0x88C0D0,
    .syntax_type = 0x8FBCBB,
    .syntax_property = 0x8FBCBB,
    .syntax_tag = 0x81A1C1,
    .syntax_builtin = 0x81A1C1,
    .warning = 0xEBCB8B,
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "every theme has a label, and text that stands out from its background" {
    inline for (@typeInfo(Name).@"enum".fields) |field| {
        const name = @field(Name, field.name);
        try testing.expect(name.label().len > 0);
        const c = name.colors();
        try testing.expect(contrast(c.text, c.background) > 4.5);
    }
}

/// The WCAG contrast ratio of two colours.
fn contrast(a: u24, b: u24) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

fn luminance(c: u24) f32 {
    const channels = [3]u8{ @intCast(c >> 16), @intCast(c >> 8 & 0xFF), @intCast(c & 0xFF) };
    const weights = [3]f32{ 0.2126, 0.7152, 0.0722 };
    var total: f32 = 0;
    for (channels, weights) |channel, weight| {
        const v = @as(f32, @floatFromInt(channel)) / 255;
        total += weight * (if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4));
    }
    return total;
}
