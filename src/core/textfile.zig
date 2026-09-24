//! Converts between a file's bytes and the editor's text. The buffer always
//! holds UTF-8 with LF line breaks; the file's encoding, byte order mark and
//! line endings are remembered and put back on save, so an unedited file
//! saves byte for byte as it was read.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Encoding = enum {
    utf8,
    utf8_bom,
    utf16le,
    utf16be,
    /// Anything that is not valid UTF-8. Every byte maps to a character, so
    /// even binary data survives a round trip.
    windows1252,

    pub fn label(e: Encoding) [:0]const u8 {
        return switch (e) {
            .utf8 => "UTF-8",
            .utf8_bom => "UTF-8 BOM",
            .utf16le => "UTF-16 LE",
            .utf16be => "UTF-16 BE",
            .windows1252 => "Windows-1252",
        };
    }
};

pub const LineEnding = enum {
    lf,
    crlf,

    pub fn label(l: LineEnding) [:0]const u8 {
        return switch (l) {
            .lf => "LF",
            .crlf => "CRLF",
        };
    }
};

pub const Format = struct {
    encoding: Encoding = .utf8,
    line_ending: LineEnding = .lf,
};

pub const Decoded = struct {
    text: []u8,
    format: Format,
};

pub fn decode(gpa: Allocator, bytes: []const u8) !Decoded {
    var encoding = detect(bytes);
    const utf8 = toUtf8(gpa, bytes, encoding) catch |err| switch (err) {
        // Unpaired surrogates: keep the bytes rather than refuse the file.
        error.DanglingSurrogateHalf, error.ExpectedSecondSurrogateHalf, error.UnexpectedSecondSurrogateHalf => blk: {
            encoding = .windows1252;
            break :blk try fromWindows1252(gpa, bytes);
        },
        else => return err,
    };
    defer gpa.free(utf8);
    return .{
        .text = try toLf(gpa, utf8),
        .format = .{ .encoding = encoding, .line_ending = lineEndingOf(utf8) },
    };
}

/// Fails with `error.Unrepresentable` when the text holds characters the
/// format's encoding cannot store.
pub fn encode(gpa: Allocator, text: []const u8, format: Format) ![]u8 {
    const lined = if (format.line_ending == .crlf) try toCrlf(gpa, text) else try gpa.dupe(u8, text);
    defer gpa.free(lined);
    return fromUtf8(gpa, lined, format.encoding);
}

/// Line breaks as the buffer holds them. A lone CR is kept.
pub fn toLf(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, bytes.len);
    errdefer out.deinit(gpa);
    for (bytes, 0..) |b, i| {
        if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        out.appendAssumeCapacity(b);
    }
    return out.toOwnedSlice(gpa);
}

fn toCrlf(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |b| {
        if (b == '\n') try out.append(gpa, '\r');
        try out.append(gpa, b);
    }
    return out.toOwnedSlice(gpa);
}

/// Whichever kind of line break the file uses most.
fn lineEndingOf(utf8: []const u8) LineEnding {
    var crlf: usize = 0;
    var lf: usize = 0;
    for (utf8, 0..) |b, i| {
        if (b != '\n') continue;
        if (i > 0 and utf8[i - 1] == '\r') crlf += 1 else lf += 1;
    }
    return if (crlf > lf) .crlf else .lf;
}

fn detect(bytes: []const u8) Encoding {
    if (std.mem.startsWith(u8, bytes, &bom_utf8)) return .utf8_bom;
    if (std.mem.startsWith(u8, bytes, &bom_utf16le) and bytes.len % 2 == 0) return .utf16le;
    if (std.mem.startsWith(u8, bytes, &bom_utf16be) and bytes.len % 2 == 0) return .utf16be;
    if (std.unicode.utf8ValidateSlice(bytes)) return .utf8;
    return .windows1252;
}

const bom_utf8 = [_]u8{ 0xEF, 0xBB, 0xBF };
const bom_utf16le = [_]u8{ 0xFF, 0xFE };
const bom_utf16be = [_]u8{ 0xFE, 0xFF };

fn toUtf8(gpa: Allocator, bytes: []const u8, encoding: Encoding) ![]u8 {
    return switch (encoding) {
        .utf8 => gpa.dupe(u8, bytes),
        .utf8_bom => gpa.dupe(u8, bytes[bom_utf8.len..]),
        .utf16le, .utf16be => blk: {
            const body = bytes[2..];
            const units = try gpa.alloc(u16, body.len / 2);
            defer gpa.free(units);
            for (units, 0..) |*u, i| {
                const pair = body[i * 2 ..][0..2];
                u.* = if (encoding == .utf16le) std.mem.readInt(u16, pair, .little) else std.mem.readInt(u16, pair, .big);
            }
            break :blk std.unicode.utf16LeToUtf8Alloc(gpa, units);
        },
        .windows1252 => fromWindows1252(gpa, bytes),
    };
}

fn fromUtf8(gpa: Allocator, utf8: []const u8, encoding: Encoding) ![]u8 {
    return switch (encoding) {
        .utf8 => gpa.dupe(u8, utf8),
        .utf8_bom => std.mem.concat(gpa, u8, &.{ &bom_utf8, utf8 }),
        .utf16le, .utf16be => blk: {
            const units = std.unicode.utf8ToUtf16LeAlloc(gpa, utf8) catch |err| switch (err) {
                error.InvalidUtf8 => return error.Unrepresentable,
                else => return err,
            };
            defer gpa.free(units);
            const out = try gpa.alloc(u8, 2 + units.len * 2);
            @memcpy(out[0..2], if (encoding == .utf16le) &bom_utf16le else &bom_utf16be);
            for (units, 0..) |u, i| {
                std.mem.writeInt(u16, out[2 + i * 2 ..][0..2], u, if (encoding == .utf16le) .little else .big);
            }
            break :blk out;
        },
        .windows1252 => toWindows1252(gpa, utf8),
    };
}

/// 0x80 to 0x9F, where Windows-1252 differs from Latin-1. The five bytes it
/// leaves undefined map to the matching C1 control, which keeps every byte
/// value distinct and so the round trip lossless.
const high = [32]u21{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

fn fromWindows1252(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |b| {
        const cp: u21 = if (b >= 0x80 and b < 0xA0) high[b - 0x80] else b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn toWindows1252(gpa: Allocator, utf8: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const view = std.unicode.Utf8View.init(utf8) catch return error.Unrepresentable;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        try out.append(gpa, windows1252Byte(cp) orelse return error.Unrepresentable);
    }
    return out.toOwnedSlice(gpa);
}

fn windows1252Byte(cp: u21) ?u8 {
    if (cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF)) return @intCast(cp);
    for (high, 0..) |h, i| {
        if (h == cp) return @intCast(0x80 + i);
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn roundTrip(bytes: []const u8) !void {
    const d = try decode(testing.allocator, bytes);
    defer testing.allocator.free(d.text);
    const back = try encode(testing.allocator, d.text, d.format);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, bytes, back);
}

test "plain UTF-8 with LF passes straight through" {
    const d = try decode(testing.allocator, "one\ntwo\n");
    defer testing.allocator.free(d.text);
    try testing.expectEqualStrings("one\ntwo\n", d.text);
    try testing.expectEqual(Format{}, d.format);
}

test "CRLF files are held as LF and saved back as CRLF" {
    const d = try decode(testing.allocator, "a\r\nb\r\n");
    defer testing.allocator.free(d.text);
    try testing.expectEqualStrings("a\nb\n", d.text);
    try testing.expectEqual(LineEnding.crlf, d.format.line_ending);
    try roundTrip("a\r\nb\r\n");
}

test "a mostly-LF file with one stray CRLF counts as LF" {
    const d = try decode(testing.allocator, "a\nb\nc\r\n");
    defer testing.allocator.free(d.text);
    try testing.expectEqual(LineEnding.lf, d.format.line_ending);
}

test "a UTF-8 byte order mark is hidden from the text and kept on save" {
    const bytes = "\xEF\xBB\xBFhello";
    const d = try decode(testing.allocator, bytes);
    defer testing.allocator.free(d.text);
    try testing.expectEqualStrings("hello", d.text);
    try testing.expectEqual(Encoding.utf8_bom, d.format.encoding);
    try roundTrip(bytes);
}

test "UTF-16 in both byte orders reads as text and saves back identically" {
    try roundTrip("\xFF\xFEh\x00i\x00\r\x00\n\x00");
    try roundTrip("\xFE\xFF\x00h\x00i");
    const d = try decode(testing.allocator, "\xFF\xFEh\x00\xE9\x00");
    defer testing.allocator.free(d.text);
    try testing.expectEqualStrings("hé", d.text);
}

test "Windows-1252 text is shown as the right characters" {
    const d = try decode(testing.allocator, "caf\xE9 \x80 \x93quoted\x94");
    defer testing.allocator.free(d.text);
    try testing.expectEqualStrings("café € “quoted”", d.text);
    try testing.expectEqual(Encoding.windows1252, d.format.encoding);
}

test "any byte sequence at all survives a round trip" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try roundTrip(&all);
}

test "a character Windows-1252 cannot hold is refused, not dropped" {
    try testing.expectError(error.Unrepresentable, encode(testing.allocator, "emoji 😀", .{ .encoding = .windows1252 }));
}

test "a lone CR is left alone" {
    try roundTrip("a\rb\n");
}

test "UTF-16 with an unpaired surrogate falls back to bytes and saves back unchanged" {
    const bytes = "\xFF\xFEa\x00\x00\xD8b\x00";
    const d = try decode(testing.allocator, bytes);
    defer testing.allocator.free(d.text);
    try testing.expectEqual(Encoding.windows1252, d.format.encoding);
    try roundTrip(bytes);
}
