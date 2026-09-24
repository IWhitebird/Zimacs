//! Which characters a TrueType or OpenType font has glyphs for, read from its
//! `cmap` table, so the editor loads exactly what the font can draw.

const std = @import("std");

/// Appends each codepoint the font maps to a glyph and `keep` accepts, in
/// ascending order, until `out` is full. Returns the filled part; a font
/// without a usable table yields nothing.
pub fn codepoints(font: []const u8, out: []i32, keep: *const fn (u21) bool) []i32 {
    const table = subtable(font) orelse return out[0..0];
    var n: usize = 0;
    switch (read(u16, table, 0) orelse return out[0..0]) {
        4 => n = format4(table, out, keep),
        12 => n = format12(table, out, keep),
        else => {},
    }
    return out[0..n];
}

/// The Unicode subtable, preferring the full-range one over the BMP one.
fn subtable(font: []const u8) ?[]const u8 {
    const cmap = tableNamed(font, "cmap") orelse return null;
    const count = read(u16, cmap, 2) orelse return null;
    var bmp: ?[]const u8 = null;
    for (0..count) |i| {
        const record = 4 + i * 8;
        const platform = read(u16, cmap, record) orelse return null;
        const encoding = read(u16, cmap, record + 2) orelse return null;
        const offset = read(u32, cmap, record + 4) orelse return null;
        if (offset >= cmap.len) continue;
        const sub = cmap[offset..];
        const full = (platform == 3 and encoding == 10) or (platform == 0 and (encoding == 4 or encoding == 6));
        const basic = (platform == 3 and encoding == 1) or (platform == 0 and encoding <= 3);
        if (full and read(u16, sub, 0) == 12) return sub;
        if (basic and read(u16, sub, 0) == 4) bmp = sub;
    }
    return bmp;
}

fn tableNamed(font: []const u8, tag: *const [4]u8) ?[]const u8 {
    const count = read(u16, font, 4) orelse return null;
    for (0..count) |i| {
        const record = 12 + i * 16;
        if (record + 16 > font.len) return null;
        if (!std.mem.eql(u8, font[record..][0..4], tag)) continue;
        const offset = read(u32, font, record + 8) orelse return null;
        const length = read(u32, font, record + 12) orelse return null;
        if (@as(u64, offset) + length > font.len) return null;
        return font[offset..][0..length];
    }
    return null;
}

/// Segments of consecutive codepoints, for the Basic Multilingual Plane.
fn format4(table: []const u8, out: []i32, keep: *const fn (u21) bool) usize {
    const segments = (read(u16, table, 6) orelse return 0) / 2;
    const ends = 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;
    const range_offsets = deltas + segments * 2;

    var n: usize = 0;
    for (0..segments) |s| {
        const start = read(u16, table, starts + s * 2) orelse return n;
        const end = read(u16, table, ends + s * 2) orelse return n;
        const delta = read(u16, table, deltas + s * 2) orelse return n;
        const range_offset = read(u16, table, range_offsets + s * 2) orelse return n;
        if (start > end) continue;
        var c: u32 = start;
        while (c <= end and c != 0xFFFF) : (c += 1) {
            const glyph = if (range_offset == 0)
                (c +% delta) & 0xFFFF
            else blk: {
                const at = range_offsets + s * 2 + range_offset + (c - start) * 2;
                const id = read(u16, table, at) orelse return n;
                break :blk if (id == 0) 0 else (id +% delta) & 0xFFFF;
            };
            if (glyph == 0 or !keep(@intCast(c))) continue;
            if (n == out.len) return n;
            out[n] = @intCast(c);
            n += 1;
        }
    }
    return n;
}

/// Groups of consecutive codepoints, for all of Unicode.
fn format12(table: []const u8, out: []i32, keep: *const fn (u21) bool) usize {
    const groups = read(u32, table, 12) orelse return 0;
    var n: usize = 0;
    for (0..groups) |g| {
        const group = 16 + g * 12;
        const start = read(u32, table, group) orelse return n;
        const end = read(u32, table, group + 4) orelse return n;
        if (start > end or end > 0x10FFFF) continue;
        var c = start;
        while (c <= end) : (c += 1) {
            if (!keep(@intCast(c))) continue;
            if (n == out.len) return n;
            out[n] = @intCast(c);
            n += 1;
        }
    }
    return n;
}

fn read(comptime T: type, bytes: []const u8, at: usize) ?T {
    if (at + @sizeOf(T) > bytes.len) return null;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .big);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn any(_: u21) bool {
    return true;
}

fn notB(c: u21) bool {
    return c != 'B';
}

/// A font holding only a `cmap` with one format 4 subtable mapping A to C,
/// plus the 0xFFFF segment every format 4 table ends with.
fn tinyFont() [12 + 16 + 12 + 32]u8 {
    var f = std.mem.zeroes([12 + 16 + 12 + 32]u8);
    std.mem.writeInt(u16, f[4..6], 1, .big);
    @memcpy(f[12..16], "cmap");
    std.mem.writeInt(u32, f[20..24], 28, .big);
    std.mem.writeInt(u32, f[24..28], 44, .big);
    const cmap = f[28..];
    std.mem.writeInt(u16, cmap[2..4], 1, .big);
    std.mem.writeInt(u16, cmap[4..6], 3, .big);
    std.mem.writeInt(u16, cmap[6..8], 1, .big);
    std.mem.writeInt(u32, cmap[8..12], 12, .big);
    const sub = cmap[12..];
    std.mem.writeInt(u16, sub[0..2], 4, .big);
    std.mem.writeInt(u16, sub[6..8], 4, .big); // two segments
    std.mem.writeInt(u16, sub[14..16], 'C', .big); // end codes
    std.mem.writeInt(u16, sub[16..18], 0xFFFF, .big);
    std.mem.writeInt(u16, sub[20..22], 'A', .big); // start codes
    std.mem.writeInt(u16, sub[22..24], 0xFFFF, .big);
    std.mem.writeInt(u16, sub[24..26], @as(u16, 0) -% ('A' - 1), .big); // A is glyph 1
    std.mem.writeInt(u16, sub[26..28], 1, .big);
    return f;
}

test "reads the characters a format 4 table maps, skipping the terminator" {
    const font = tinyFont();
    var out: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 'A', 'B', 'C' }, codepoints(&font, &out, &any));
}

test "keep filters, and a full buffer stops early" {
    const font = tinyFont();
    var out: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 'A', 'C' }, codepoints(&font, &out, &notB));
    var small: [2]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 'A', 'B' }, codepoints(&font, &small, &any));
}

test "a truncated or foreign file yields nothing rather than reading past it" {
    const font = tinyFont();
    var out: [8]i32 = undefined;
    for (0..font.len) |len| _ = codepoints(font[0..len], &out, &any);
    try testing.expectEqual(@as(usize, 0), codepoints("not a font at all", &out, &any).len);
}
