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
const cmap = @import("cmap.zig");

const data = @embedFile("font_data");
const emoji_data = @embedFile("emoji_data");

/// Characters get a glyph in an atlas the first time something draws them,
/// so an atlas holds what the text uses rather than the whole font: all of
/// either font at a large zoom would not fit in one texture.
const Glyphs = struct {
    const Set = std.StaticBitSet(codepoint_limit);
    const codepoint_limit = 0x20000;

    /// What the font file can draw.
    available: Set = .initEmpty(),
    /// What the atlas holds, plus what has been drawn since.
    wanted: Set = .initEmpty(),
    loaded: Set = .initEmpty(),

    fn init(g: *Glyphs, font: []const u8, keep: *const fn (u21) bool) void {
        var found: [max_glyphs]i32 = undefined;
        for (cmap.codepoints(font, &found, keep)) |c| g.available.set(@intCast(c));
    }

    fn has(g: Glyphs, c: u21) bool {
        return c < codepoint_limit and g.available.isSet(c);
    }

    fn want(g: *Glyphs, c: u21) void {
        if (g.has(c)) g.wanted.set(c);
    }

    fn stale(g: Glyphs) bool {
        return !g.wanted.eql(g.loaded);
    }

    /// Everything wanted, marked as loaded.
    fn take(g: *Glyphs, out: []i32) []i32 {
        var n: usize = 0;
        var it = g.wanted.iterator(.{});
        while (it.next()) |c| {
            if (n == out.len) break;
            out[n] = @intCast(c);
            n += 1;
        }
        g.loaded = g.wanted;
        return out[0..n];
    }
};

/// More than either font has.
const max_glyphs = 4096;

/// Tab stops in interface text such as labels, which has no settings of its
/// own; the text being edited uses `tab_width`.
const label_tab_width = 4;

var text_glyphs: Glyphs = .{};
/// Emoji are drawn from a second font, since the text font has none.
/// `text.isWide` decides which font a character comes from.
var emoji_glyphs: Glyphs = .{};
var glyphs_ready = false;

fn isEmoji(c: u21) bool {
    return text.isWide(c);
}

fn anything(_: u21) bool {
    return true;
}

fn prepareGlyphs() void {
    if (glyphs_ready) return;
    glyphs_ready = true;
    text_glyphs.init(data, &anything);
    emoji_glyphs.init(emoji_data, &isEmoji);
    // Always in the atlas: ASCII and the accented letters of Latin-1.
    for (0x20..0x7F) |c| text_glyphs.want(@intCast(c));
    for (0xA0..0x100) |c| text_glyphs.want(@intCast(c));
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
    /// Physical pixels per logical one. The atlas is rasterised this much
    /// larger and drawn at the logical size, so text stays sharp when the
    /// display is scaled.
    density: f32 = 1,
    spacing: f32 = 0,
    handle: pen.Font = undefined,
    /// Second atlas, for the emoji the text font has no glyphs for.
    emoji: pen.Font = undefined,
    metrics: Metrics = .{},
    loaded: bool = false,
    /// The size or density changed and the atlas has not caught up.
    outdated: bool = false,

    pub const default_size: f32 = 18;
    pub const min_size: f32 = 8;
    pub const max_size: f32 = 72;
    pub const zoom_step: f32 = 2;

    const Self = @This();

    /// Rasterises the font at the current size. Safe to call repeatedly.
    pub fn load(f: *Self) !void {
        prepareGlyphs();
        var text_list: [max_glyphs]i32 = undefined;
        var emoji_list: [max_glyphs]i32 = undefined;
        const text_codepoints = text_glyphs.take(&text_list);
        const emoji_codepoints = emoji_glyphs.take(&emoji_list);

        const size: i32 = @intFromFloat(@round(f.size * f.density));
        const next = try pen.loadFontFromMemory(".ttf", data, size, text_codepoints);
        if (!pen.isFontValid(next)) return error.InvalidFont;

        // Emoji live in their own atlas rather than a merged one: raylib owns
        // the glyph arrays it allocates, and splicing Zig-allocated memory
        // into a Font would hand raylib a pointer it must not free.
        // With no emoji wanted yet, one stands in: raylib reads an empty
        // list as its default ASCII set.
        const placeholder = [_]i32{0x263A};
        const next_emoji = try pen.loadFontFromMemory(
            ".ttf",
            emoji_data,
            @intFromFloat(@round(f.size * 2 * f.density)),
            if (emoji_codepoints.len > 0) emoji_codepoints else &placeholder,
        );

        // raylib uploads a GPU texture per font, so the old ones must go.
        if (f.loaded) {
            pen.unloadFont(f.handle);
            pen.unloadFont(f.emoji);
        }

        f.handle = next;
        f.emoji = next_emoji;
        f.loaded = true;
        f.outdated = false;
        gui.setFont(next);
        f.metrics = f.measure();
    }

    pub fn unload(f: *Self) void {
        if (!f.loaded) return;
        pen.unloadFont(f.handle);
        pen.unloadFont(f.emoji);
        f.loaded = false;
    }

    /// Takes effect at the next `refresh`, since the atlas cannot change
    /// while a frame is drawing from it.
    pub fn setSize(f: *Self, size: f32) void {
        const next = std.math.clamp(size, min_size, max_size);
        if (next == f.size) return;
        f.size = next;
        f.outdated = true;
    }

    /// For a window that moved to a display with another scale. Takes effect
    /// at the next `refresh`.
    pub fn setDensity(f: *Self, density: f32) void {
        if (density <= 0 or density == f.density) return;
        f.density = density;
        f.outdated = true;
    }

    pub fn needsRefresh(f: Self) bool {
        return f.loaded and (f.outdated or text_glyphs.stale() or emoji_glyphs.stale());
    }

    /// Rebuilds the atlases for a new size or density, or for characters
    /// they lack. Called between frames.
    pub fn refresh(f: *Self) !void {
        if (f.needsRefresh()) try f.load();
    }

    pub fn zoomIn(f: *Self) void {
        f.setSize(f.size + zoom_step);
    }

    pub fn zoomOut(f: *Self) void {
        f.setSize(f.size - zoom_step);
    }

    pub fn zoomReset(f: *Self) void {
        f.setSize(f.base);
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
        return @as(f32, @floatFromInt(text.width(s, label_tab_width))) * f.metrics.width;
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
            // The emoji font lacks some of the blocks it covers, such as the
            // check marks, which the text font has.
            if (text.isWide(at.code) and emoji_glyphs.has(at.code)) {
                emoji_glyphs.want(at.code);
                pen.drawTextCodepoint(f.emoji, @intCast(at.code), where, f.metrics.width * 2, colour);
            } else {
                text_glyphs.want(at.code);
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
