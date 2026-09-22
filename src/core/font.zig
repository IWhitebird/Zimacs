//! The editor font: loading it, resizing it, and measuring a character cell.
//!
//! The font file is baked into the binary, so Zimacs runs from any directory.
//! Changing the size re-rasterises the glyph atlas and re-measures the cell,
//! which is what lets the gutter, caret and visible line count follow a zoom
//! without anyone tracking sizes by hand.

const std = @import("std");
const pen = @import("raylib");
const gui = @import("raygui");
const text = @import("text.zig");

const data = @embedFile("font_data");
const emoji_data = @embedFile("emoji_data");

/// Emoji blocks carried by the second font. Kept in step with
/// `text.isWide`, which decides how much room they take on screen.
const emoji_codepoints = blk: {
    const ranges = [_][2]i32{
        .{ 0x2600, 0x27BF },
        .{ 0x1F300, 0x1F5FF },
        .{ 0x1F600, 0x1F64F },
        .{ 0x1F680, 0x1F6FF },
        .{ 0x1F900, 0x1F9FF },
    };
    break :blk &collect(&ranges);
};

/// Which characters get a glyph in the atlas.
///
/// raylib's default is the 95 printable ASCII characters, which turns every
/// accented letter into a question mark. Latin-1 Supplement and Latin
/// Extended-A cover the European languages JetBrains Mono actually has glyphs
/// for; CJK and emoji would need a different font entirely.
const codepoints = blk: {
    const ranges = [_][2]i32{
        .{ 0x0020, 0x007E }, // printable ASCII
        .{ 0x00A0, 0x024F }, // Latin-1 Supplement, Latin Extended-A and B
        .{ 0x2010, 0x203A }, // dashes and quotation marks
        .{ 0x2190, 0x21FF }, // arrows
    };
    break :blk &collect(&ranges);
};

fn collect(comptime ranges: []const [2]i32) [count(ranges)]i32 {
    @setEvalBranchQuota(100_000);
    var list: [count(ranges)]i32 = undefined;
    var i = 0;
    for (ranges) |r| {
        var c = r[0];
        while (c <= r[1]) : (c += 1) {
            list[i] = c;
            i += 1;
        }
    }
    return list;
}

fn count(comptime ranges: []const [2]i32) usize {
    var total = 0;
    for (ranges) |r| total += r[1] - r[0] + 1;
    return total;
}

/// Size of one character cell. The font is monospaced, so one measurement
/// describes every glyph.
pub const Metrics = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const Font = struct {
    size: f32 = default_size,
    /// The size from the settings: what Ctrl+0 goes back to, and what the
    /// saved zoom is measured from.
    base: f32 = default_size,
    spacing: f32 = 0,
    handle: pen.Font = undefined,
    /// Second atlas, for the emoji the text font has no glyphs for.
    emoji: pen.Font = undefined,
    metrics: Metrics = .{},
    loaded: bool = false,

    pub const default_size: f32 = 18;
    pub const min_size: f32 = 8;
    pub const max_size: f32 = 72;
    pub const zoom_step: f32 = 2;

    const Self = @This();

    /// Rasterises the font at the current size. Safe to call repeatedly.
    pub fn load(f: *Self) !void {
        const size: i32 = @intFromFloat(f.size);
        const next = try pen.loadFontFromMemory(".ttf", data, size, codepoints);
        if (!pen.isFontValid(next)) return error.InvalidFont;

        // Emoji live in their own atlas rather than a merged one: raylib owns
        // the glyph arrays it allocates, and splicing Zig-allocated memory
        // into a Font would hand raylib a pointer it must not free.
        const next_emoji = try pen.loadFontFromMemory(
            ".ttf",
            emoji_data,
            @intFromFloat(f.size * 2),
            emoji_codepoints,
        );

        // raylib uploads a GPU texture per font, so the old ones must go.
        if (f.loaded) {
            pen.unloadFont(f.handle);
            pen.unloadFont(f.emoji);
        }

        f.handle = next;
        f.emoji = next_emoji;
        f.loaded = true;
        gui.setFont(next);
        f.metrics = f.measure();
    }

    pub fn unload(f: *Self) void {
        if (!f.loaded) return;
        pen.unloadFont(f.handle);
        pen.unloadFont(f.emoji);
        f.loaded = false;
    }

    pub fn setSize(f: *Self, size: f32) !void {
        const next = std.math.clamp(size, min_size, max_size);
        if (f.loaded and next == f.size) return;
        f.size = next;
        try f.load();
    }

    pub fn zoomIn(f: *Self) !void {
        try f.setSize(f.size + zoom_step);
    }

    pub fn zoomOut(f: *Self) !void {
        try f.setSize(f.size - zoom_step);
    }

    pub fn zoomReset(f: *Self) !void {
        try f.setSize(f.base);
    }

    /// How far the text is zoomed from the configured size.
    pub fn zoom(f: Self) f32 {
        return f.size - f.base;
    }

    /// Width of `s` as it will be drawn.
    ///
    /// The font is monospaced, so this is the column count times the cell
    /// width. Computing it rather than asking raylib also means layout maths
    /// works without a window, which keeps it testable.
    pub fn widthOf(f: Self, s: [:0]const u8) f32 {
        return @as(f32, @floatFromInt(text.width(s, 4))) * f.metrics.width;
    }

    /// Draws a string that sits on the character grid.
    ///
    /// Plain ASCII goes out in one call. Anything else is drawn a character at
    /// a time at exact column positions, which is both how emoji reach the
    /// second atlas and how wide characters stay aligned with the caret.
    pub fn draw(f: Self, s: [:0]const u8, x: f32, y: f32, colour: pen.Color) void {
        if (isAscii(s)) {
            pen.drawTextEx(f.handle, s, .{ .x = x, .y = y }, f.size, f.spacing, colour);
            return;
        }

        var column: u32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            const at = text.decode(s, i);
            const where = pen.Vector2{ .x = x + @as(f32, @floatFromInt(column)) * f.metrics.width, .y = y };
            if (text.isWide(at.code)) {
                pen.drawTextCodepoint(f.emoji, @intCast(at.code), where, f.metrics.width * 2, colour);
            } else {
                pen.drawTextCodepoint(f.handle, @intCast(at.code), where, f.size, colour);
            }
            column += text.columnsFor(at.code);
            i += at.len;
        }
    }

    fn isAscii(s: []const u8) bool {
        for (s) |byte| {
            if (byte >= 0x80) return false;
        }
        return true;
    }

    /// Measures two characters and subtracts one, so the result includes the
    /// gap raylib adds between glyphs. Measuring a single glyph would miss it
    /// and the caret would drift along long lines.
    fn measure(f: Self) Metrics {
        const one = pen.measureTextEx(f.handle, "M", f.size, f.spacing);
        const two = pen.measureTextEx(f.handle, "MM", f.size, f.spacing);
        return .{
            .width = @max(two.x - one.x, 1),
            .height = @max(one.y, 1),
        };
    }
};
