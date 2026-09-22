//! Turning stored bytes into screen columns.
//!
//! The buffer stores UTF-8 and tab characters, but the screen is a grid of
//! equal cells. A tab runs to the next tab stop, most characters take one
//! cell, and emoji take two - so a byte offset within a line is not the
//! column it is drawn at. Everything that positions the caret or a selection
//! goes through here.

const std = @import("std");

/// A byte that continues the character before it.
pub fn isTrailing(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// Part of a word, for word-wise movement and deletion. Bytes above ASCII
/// count as word characters so accented and non-Latin text holds together.
pub fn isWord(byte: u8) bool {
    return byte == '_' or std.ascii.isAlphanumeric(byte) or byte >= 0x80;
}

/// How many cells a character takes. Emoji are drawn double-width, the way a
/// terminal does, because their glyphs are square while the text font is not.
pub fn columnsFor(codepoint: u21) u32 {
    return if (isWide(codepoint)) 2 else 1;
}

pub fn isWide(codepoint: u21) bool {
    return switch (codepoint) {
        0x1F300...0x1F5FF, // pictographs
        0x1F600...0x1F64F, // emoticons
        0x1F680...0x1F6FF, // transport
        0x1F900...0x1F9FF, // supplemental
        0x2600...0x27BF, // misc symbols and dingbats
        => true,
        else => false,
    };
}

/// The codepoint starting at `i`, and how many bytes it spans. Invalid bytes
/// are reported as one byte so a broken file still renders.
pub fn decode(line: []const u8, i: usize) struct { code: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(line[i]) catch return .{ .code = line[i], .len = 1 };
    if (i + len > line.len) return .{ .code = line[i], .len = 1 };
    const code = std.unicode.utf8Decode(line[i .. i + len]) catch return .{ .code = line[i], .len = 1 };
    return .{ .code = code, .len = len };
}

/// The screen column that `byte_offset` within `line` falls on.
pub fn columnOf(line: []const u8, byte_offset: usize, tab_width: u8) u32 {
    const stop = @min(byte_offset, line.len);
    var column: u32 = 0;
    var i: usize = 0;
    while (i < stop) {
        if (line[i] == '\t') {
            column += tabAdvance(column, tab_width);
            i += 1;
            continue;
        }
        const at = decode(line, i);
        column += columnsFor(at.code);
        i += at.len;
    }
    return column;
}

/// The byte offset in `line` that sits at screen column `column`.
pub fn offsetOf(line: []const u8, column: u32, tab_width: u8) u32 {
    var at: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (at >= column) return @intCast(i);
        if (line[i] == '\t') {
            at += tabAdvance(at, tab_width);
            i += 1;
            continue;
        }
        const ch = decode(line, i);
        at += columnsFor(ch.code);
        i += ch.len;
    }
    return @intCast(line.len);
}

/// Total columns `line` occupies.
pub fn width(line: []const u8, tab_width: u8) u32 {
    return columnOf(line, line.len, tab_width);
}

/// Writes `line` with tabs turned into spaces, so what is drawn lines up with
/// the columns everything else computes.
pub fn expand(line: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator, tab_width: u8) !void {
    var column: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\t') {
            const spaces = tabAdvance(column, tab_width);
            try out.appendNTimes(gpa, ' ', spaces);
            column += spaces;
            i += 1;
            continue;
        }
        const at = decode(line, i);
        try out.appendSlice(gpa, line[i .. i + at.len]);
        column += columnsFor(at.code);
        i += at.len;
    }
}

fn tabAdvance(column: u32, tab_width: u8) u32 {
    const stop = @max(tab_width, 1);
    return stop - column % stop;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "word characters" {
    try testing.expect(isWord('a'));
    try testing.expect(isWord('Z'));
    try testing.expect(isWord('7'));
    try testing.expect(isWord('_'));
    try testing.expect(!isWord(' '));
    try testing.expect(!isWord('.'));
    try testing.expect(!isWord('\n'));
    // A continuation byte of an accented letter.
    try testing.expect(isWord(0xC3));
}

test "plain ascii is one column per byte" {
    try testing.expectEqual(@as(u32, 0), columnOf("hello", 0, 4));
    try testing.expectEqual(@as(u32, 3), columnOf("hello", 3, 4));
    try testing.expectEqual(@as(u32, 5), width("hello", 4));
}

test "a multi-byte character is one column" {
    // "e" then U+00E9 (2 bytes) then "f".
    const line = "e\u{00e9}f";
    try testing.expectEqual(@as(usize, 4), line.len);
    try testing.expectEqual(@as(u32, 1), columnOf(line, 1, 4));
    // Byte 3 is just past the two-byte character.
    try testing.expectEqual(@as(u32, 2), columnOf(line, 3, 4));
    try testing.expectEqual(@as(u32, 3), width(line, 4));
}

test "an emoji takes two columns" {
    const line = "a\u{1F600}b";
    try testing.expectEqual(@as(u32, 4), width(line, 4));
    try testing.expectEqual(@as(u32, 1), columnOf(line, 1, 4));
    // Byte 5 is just past the four-byte emoji.
    try testing.expectEqual(@as(u32, 3), columnOf(line, 5, 4));
}

test "wide ranges" {
    try testing.expect(isWide(0x1F600));
    try testing.expect(isWide(0x1F389));
    try testing.expect(isWide(0x2764));
    try testing.expect(!isWide('a'));
    try testing.expect(!isWide(0x00E9));
}

test "decode reports whole characters and survives broken bytes" {
    const line = "a\u{00e9}";
    try testing.expectEqual(@as(usize, 1), decode(line, 0).len);
    try testing.expectEqual(@as(usize, 2), decode(line, 1).len);

    const broken = [_]u8{ 0xFF, 'a' };
    try testing.expectEqual(@as(usize, 1), decode(&broken, 0).len);
}

test "tabs run to the next stop" {
    try testing.expectEqual(@as(u32, 4), width("\t", 4));
    try testing.expectEqual(@as(u32, 4), width("a\t", 4));
    try testing.expectEqual(@as(u32, 4), width("abc\t", 4));
    try testing.expectEqual(@as(u32, 8), width("abcd\t", 4));
}

test "offsetOf is the inverse of columnOf" {
    const line = "ab\u{00e9}\tcd";
    var column: u32 = 0;
    while (column <= width(line, 4)) : (column += 1) {
        const byte = offsetOf(line, column, 4);
        // Landing back on a column at or before where we asked is the
        // guarantee; a tab covers several columns with one offset.
        try testing.expect(columnOf(line, byte, 4) <= column);
    }
    try testing.expectEqual(@as(u32, 0), offsetOf(line, 0, 4));
    try testing.expectEqual(@as(u32, 1), offsetOf(line, 1, 4));
}

test "expand turns tabs into spaces" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try expand("a\tb", &out, gpa, 4);
    try testing.expectEqualSlices(u8, "a   b", out.items);

    out.clearRetainingCapacity();
    try expand("\tx", &out, gpa, 4);
    try testing.expectEqualSlices(u8, "    x", out.items);

    out.clearRetainingCapacity();
    try expand("no tabs", &out, gpa, 4);
    try testing.expectEqualSlices(u8, "no tabs", out.items);
}
