//! User settings, read from a plain `key = value` file.
//!
//! Everything has a working default, so a missing or partly broken config is
//! never fatal - unknown keys and bad values are reported and skipped.
//!
//! Colours are `#rrggbb`. See `writeDefault` for the file Zimacs creates on
//! first run.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CaretStyle = enum { line, block, underline };

pub const Colors = struct {
    background: u24 = 0x181818,
    text: u24 = 0xDEDEE6,
    current_line: u24 = 0x212121,
    selection: u24 = 0x264F78,
    gutter_text: u24 = 0x5C6070,
    gutter_text_active: u24 = 0xBEC3D7,
    status_background: u24 = 0x121212,
    status_text: u24 = 0xA0A5B9,
    tab_background: u24 = 0x101010,
    tab_active: u24 = 0x181818,
    tab_text: u24 = 0x8A8F9E,
    tab_text_active: u24 = 0xDEDEE6,
    caret: u24 = 0x78C8FF,
    hint: u24 = 0x6E7284,
    scrollbar: u24 = 0x3A3A42,
    scrollbar_hover: u24 = 0x55555F,

    /// Sets the field named `key`, if there is one.
    pub fn apply(c: *Colors, key: []const u8, value: []const u8) !void {
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            if (eq(key, field.name)) {
                @field(c, field.name) = try parseColor(value);
                return;
            }
        }
        return error.UnknownKey;
    }
};

pub const Config = struct {
    font_size: f32 = 18,
    caret_style: CaretStyle = .line,
    tab_width: u8 = 4,
    /// Insert spaces instead of a tab character.
    expand_tabs: bool = true,
    restore_session: bool = true,
    /// Fold long lines onto the next row instead of scrolling sideways.
    wrap_lines: bool = false,
    /// List dot-files in the file browser.
    show_hidden: bool = false,
    colors: Colors = .{},

    const Self = @This();

    /// Applies every `key = value` line in `text`. Bad lines are reported and
    /// skipped so one typo cannot stop the editor starting.
    pub fn applyText(c: *Self, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: u32 = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = trim(raw);
            if (line.len == 0 or line[0] == '#') continue;

            const split = std.mem.indexOfScalar(u8, line, '=') orelse {
                report(number, line, "expected key = value");
                continue;
            };
            const key = trim(line[0..split]);
            const value = trim(line[split + 1 ..]);
            c.applyPair(key, value) catch report(number, key, "bad value");
        }
    }

    fn applyPair(c: *Self, key: []const u8, value: []const u8) !void {
        if (eq(key, "font_size")) {
            c.font_size = try std.fmt.parseFloat(f32, value);
        } else if (eq(key, "caret_style")) {
            c.caret_style = std.meta.stringToEnum(CaretStyle, value) orelse return error.BadValue;
        } else if (eq(key, "tab_width")) {
            c.tab_width = try std.fmt.parseInt(u8, value, 10);
        } else if (eq(key, "expand_tabs")) {
            c.expand_tabs = try parseBool(value);
        } else if (eq(key, "restore_session")) {
            c.restore_session = try parseBool(value);
        } else if (eq(key, "wrap_lines")) {
            c.wrap_lines = try parseBool(value);
        } else if (eq(key, "show_hidden")) {
            c.show_hidden = try parseBool(value);
        } else {
            try c.colors.apply(key, value);
        }
    }

    pub fn writeDefault(io: std.Io, dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var opened = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer opened.close(io);
        try opened.writeFile(io, .{ .sub_path = file_name, .data = default_text });
    }
};

pub const file_name = "config.ini";

const default_text =
    \\# Zimacs settings. Delete this file to get the defaults back.
    \\
    \\font_size = 18
    \\
    \\# line, block or underline
    \\caret_style = line
    \\
    \\tab_width = 4
    \\expand_tabs = true
    \\
    \\# Reopen the buffers you had last time, including unsaved ones.
    \\restore_session = true
    \\
    \\# Fold long lines instead of scrolling sideways.
    \\wrap_lines = false
    \\
    \\# Show dot-files in the file browser.
    \\show_hidden = false
    \\
    \\background = #181818
    \\text = #dedee6
    \\current_line = #212121
    \\selection = #264f78
    \\gutter_text = #5c6070
    \\gutter_text_active = #bec3d7
    \\status_background = #121212
    \\status_text = #a0a5b9
    \\tab_background = #101010
    \\tab_active = #181818
    \\tab_text = #8a8f9e
    \\tab_text_active = #dedee6
    \\caret = #78c8ff
    \\hint = #6e7284
    \\scrollbar = #3a3a42
    \\scrollbar_hover = #55555f
    \\
;

fn parseColor(value: []const u8) !u24 {
    const digits = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (digits.len != 6) return error.BadValue;
    return std.fmt.parseInt(u24, digits, 16);
}

fn parseBool(value: []const u8) !bool {
    if (eq(value, "true") or eq(value, "yes") or eq(value, "1")) return true;
    if (eq(value, "false") or eq(value, "no") or eq(value, "0")) return false;
    return error.BadValue;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn report(line: u32, what: []const u8, why: []const u8) void {
    std.debug.print("{s} line {d}: {s} ({s})\n", .{ file_name, line, why, what });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "defaults survive an empty file" {
    var c = Config{};
    c.applyText("");
    try testing.expectEqual(@as(f32, 18), c.font_size);
    try testing.expectEqual(CaretStyle.line, c.caret_style);
    try testing.expectEqual(@as(u24, 0x181818), c.colors.background);
}

test "reads values and ignores comments and blank lines" {
    var c = Config{};
    c.applyText(
        \\# a comment
        \\
        \\font_size = 24
        \\caret_style = block
        \\tab_width = 2
        \\expand_tabs = false
        \\wrap_lines = true
        \\background = #202020
    );
    try testing.expectEqual(@as(f32, 24), c.font_size);
    try testing.expectEqual(CaretStyle.block, c.caret_style);
    try testing.expectEqual(@as(u8, 2), c.tab_width);
    try testing.expectEqual(false, c.expand_tabs);
    try testing.expectEqual(true, c.wrap_lines);
    try testing.expectEqual(@as(u24, 0x202020), c.colors.background);
}

test "a bad line does not disturb the others" {
    var c = Config{};
    c.applyText(
        \\font_size = enormous
        \\caret_style = underline
    );
    try testing.expectEqual(@as(f32, 18), c.font_size);
    try testing.expectEqual(CaretStyle.underline, c.caret_style);
}

test "colours accept a leading hash or not" {
    try testing.expectEqual(@as(u24, 0xAABBCC), try parseColor("#aabbcc"));
    try testing.expectEqual(@as(u24, 0xAABBCC), try parseColor("AABBCC"));
    try testing.expectError(error.BadValue, parseColor("#abc"));
}

test "booleans" {
    try testing.expectEqual(true, try parseBool("true"));
    try testing.expectEqual(true, try parseBool("YES"));
    try testing.expectEqual(false, try parseBool("0"));
    try testing.expectError(error.BadValue, parseBool("maybe"));
}
