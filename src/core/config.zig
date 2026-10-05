//! User settings, read from a plain `key = value` file.
//!
//! Everything has a working default, so a missing or partly broken config is
//! never fatal - unknown keys and bad values are reported and skipped.
//!
//! The colours come from a built-in theme, and any colour set as `#rrggbb`
//! changes the theme's. See `writeDefault` for the file Zimacs creates on
//! first run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const palette = @import("palette.zig");

pub const CaretStyle = enum { line, block, underline };

pub const Colors = palette.Colors;
/// A colour of the theme, by name.
pub const ColorKey = std.meta.FieldEnum(Colors);
/// Colours the settings file sets on top of the theme's.
pub const Overrides = std.EnumArray(ColorKey, ?u24);

/// The widest indentation unit `tab_width` can ask for.
pub const max_indent_unit = 16;

pub const Config = struct {
    theme: palette.Name = .dark,
    font_size: f32 = 18,
    caret_style: CaretStyle = .line,
    tab_width: u8 = 4,
    /// Insert spaces instead of a tab character.
    expand_tabs: bool = true,
    /// In code, pair brackets and quotes as they are typed.
    auto_close: bool = true,
    restore_session: bool = true,
    /// Fold long lines onto the next row instead of scrolling sideways.
    wrap_lines: bool = false,
    /// List dot-files in the file browser.
    show_hidden: bool = false,
    /// Width of the folder tree, in columns of text.
    sidebar_columns: u16 = 30,
    /// Draw our own title bar instead of the operating system's frame.
    custom_titlebar: bool = true,
    /// Install new releases in the background. Only official builds ever do.
    auto_update: bool = true,
    overrides: Overrides = .initFill(null),
    /// The first line that could not be used, to tell the user about.
    problem: ?Problem = null,

    /// The theme's colours, with the file's own on top. A colour equal to
    /// the dark theme's is not taken as one: settings files written before
    /// there were themes listed every colour at that value.
    pub fn colors(c: *const Config) Colors {
        var result = c.theme.colors();
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            if (c.overrides.get(@field(ColorKey, field.name))) |value| {
                if (value != @field(palette.dark, field.name)) @field(result, field.name) = value;
            }
        }
        return result;
    }

    /// What one level of indentation is made of: a tab, or `tab_width` spaces.
    pub fn indentUnit(c: *const Config, buf: *[max_indent_unit]u8) []const u8 {
        if (!c.expand_tabs) return "\t";
        const width = @min(c.tab_width, buf.len);
        @memset(buf[0..width], ' ');
        return buf[0..width];
    }

    pub const Problem = struct { line: u32, why: []const u8 };

    const Self = @This();

    fn note(c: *Self, line: u32, why: []const u8) void {
        if (c.problem == null) c.problem = .{ .line = line, .why = why };
    }

    /// Applies every `key = value` line in `text`. Bad lines are reported and
    /// skipped so one typo cannot stop the editor starting.
    pub fn applyText(c: *Self, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: u32 = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = trim(raw);
            if (line.len == 0 or line[0] == '#') continue;

            const split = std.mem.findScalar(u8, line, '=') orelse {
                c.note(number, "expected key = value");
                continue;
            };
            const key = trim(line[0..split]);
            const value = trim(line[split + 1 ..]);
            c.applyPair(key, value) catch c.note(number, "bad value");
        }
    }

    /// A setting is the field of the same name, so a new one needs nothing
    /// here; colours have keys of their own.
    fn applyPair(c: *Self, key: []const u8, value: []const u8) !void {
        inline for (@typeInfo(Self).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "overrides") or std.mem.eql(u8, field.name, "problem")) continue;
            if (eq(key, field.name)) {
                @field(c, field.name) = try parseSetting(field.type, value);
                return;
            }
        }
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            if (eq(key, field.name)) {
                c.overrides.set(@field(ColorKey, field.name), try parseColor(value));
                return;
            }
        }
        return error.UnknownKey;
    }

    pub fn writeDefault(io: std.Io, dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var opened = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer opened.close(io);
        try opened.writeFile(io, .{ .sub_path = file_name, .data = default_text });
    }
};

pub const file_name = "config.ini";
/// Far more than any settings file needs.
pub const max_bytes = 1024 * 1024;

/// Writes one setting into the file at `path`, keeping everything else.
pub fn store(io: std.Io, gpa: std.mem.Allocator, path: []const u8, key: []const u8, value: []const u8) !void {
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
    defer gpa.free(old);
    const new = try withSetting(gpa, old, key, value);
    defer gpa.free(new);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new });
}

/// `text` with the line for `key` set to `value`, or appended if absent.
/// Comments and every other line are left exactly as they were.
pub fn withSetting(gpa: std.mem.Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (!found and isSettingFor(line, key)) {
            found = true;
            try out.print(gpa, "{s} = {s}", .{ key, value });
        } else {
            try out.appendSlice(gpa, line);
        }
    }
    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(gpa);
}

fn isSettingFor(line: []const u8, key: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const split = std.mem.findScalar(u8, trimmed, '=') orelse return false;
    return eq(trim(trimmed[0..split]), key);
}

/// The file written on first run: every setting at its default, so the
/// values come from `Config` and `Colors` rather than a second copy here.
const default_text = blk: {
    const d = Config{};
    var text: []const u8 = std.fmt.comptimePrint(
        \\# Zimacs settings. Delete this file to get the defaults back.
        \\
        \\# dark, light, solarized_dark, solarized_light, gruvbox_dark or nord
        \\theme = {s}
        \\
        \\font_size = {d}
        \\
        \\# line, block or underline
        \\caret_style = {s}
        \\
        \\tab_width = {d}
        \\expand_tabs = {}
        \\
        \\# In code, add the closing bracket or quote as the opening one is typed.
        \\auto_close = {}
        \\
        \\# Reopen the buffers you had last time, including unsaved ones.
        \\restore_session = {}
        \\
        \\# Fold long lines instead of scrolling sideways.
        \\wrap_lines = {}
        \\
        \\# Show dot-files in the file browser.
        \\show_hidden = {}
        \\
        \\# Width of the folder tree, in columns of text.
        \\sidebar_columns = {d}
        \\
        \\# Draw Zimacs's own title bar. Set to false for your system's window
        \\# frame instead. Takes effect the next time Zimacs starts.
        \\custom_titlebar = {}
        \\
        \\# Download and install new releases in the background. They are only
        \\# installed if signed by the Zimacs release key, and run next start.
        \\auto_update = {}
        \\
        \\
    , .{
        @tagName(d.theme),
        d.font_size,
        @tagName(d.caret_style),
        d.tab_width,
        d.expand_tabs,
        d.auto_close,
        d.restore_session,
        d.wrap_lines,
        d.show_hidden,
        d.sidebar_columns,
        d.custom_titlebar,
        d.auto_update,
    });
    text = text ++ "# Any of these colours, set as #rrggbb, changes the theme's.\n";
    for (@typeInfo(Colors).@"struct".fields) |field| {
        text = text ++ std.fmt.comptimePrint("# {s} = #{x:0>6}\n", .{ field.name, @field(palette.dark, field.name) });
    }
    break :blk text;
};

fn parseColor(value: []const u8) !u24 {
    const digits = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (digits.len != 6) return error.BadValue;
    return std.fmt.parseInt(u24, digits, 16);
}

fn parseSetting(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .bool => parseBool(value),
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .@"enum" => std.meta.stringToEnum(T, value) orelse error.BadValue,
        else => @compileError("no way to read a setting of type " ++ @typeName(T)),
    };
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "defaults survive an empty file" {
    var c = Config{};
    c.applyText("");
    try testing.expectEqual(@as(f32, 18), c.font_size);
    try testing.expectEqual(CaretStyle.line, c.caret_style);
    try testing.expectEqual(@as(u24, 0x181818), c.colors().background);
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
        \\custom_titlebar = false
        \\auto_update = false
        \\background = #202020
    );
    try testing.expectEqual(@as(f32, 24), c.font_size);
    try testing.expectEqual(CaretStyle.block, c.caret_style);
    try testing.expectEqual(@as(u8, 2), c.tab_width);
    try testing.expectEqual(false, c.expand_tabs);
    try testing.expectEqual(true, c.wrap_lines);
    try testing.expectEqual(false, c.custom_titlebar);
    try testing.expectEqual(false, c.auto_update);
    try testing.expectEqual(@as(u24, 0x202020), c.colors().background);
}

test "a theme gives every colour, and the file's own go on top" {
    var c = Config{};
    c.applyText(
        \\theme = light
        \\text = #102030
        \\background = #181818
    );
    try testing.expectEqual(palette.Name.light, c.theme);
    try testing.expectEqual(@as(u24, 0x102030), c.colors().text);
    // An old file's dark default is not a choice, so the theme's stays.
    try testing.expectEqual(@as(u24, 0xFFFFFF), c.colors().background);
    try testing.expectEqual(palette.Name.light.colors().caret, c.colors().caret);
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

test "storing a setting changes only its own line" {
    const before = "# comment\nfont_size = 18\nwrap_lines = false\n";
    const after = try withSetting(testing.allocator, before, "wrap_lines", "true");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("# comment\nfont_size = 18\nwrap_lines = true\n", after);
}

test "a setting the file lacks is appended, and a commented one is left alone" {
    const before = "# wrap_lines = false\nfont_size = 18";
    const after = try withSetting(testing.allocator, before, "wrap_lines", "true");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("# wrap_lines = false\nfont_size = 18\nwrap_lines = true\n", after);

    var c = Config{};
    c.applyText(after);
    try testing.expect(c.wrap_lines);
}

test "the first bad line is remembered so it can be shown" {
    var c = Config{};
    c.applyText("font_size = 18\nnonsense\ntab_width = lots\n");
    try testing.expectEqual(@as(u32, 2), c.problem.?.line);
}

test "the generated file reads back as the defaults" {
    var c = Config{};
    c.applyText(default_text);
    try testing.expect(c.problem == null);
    try testing.expectEqualDeep(Config{}, c);
}
