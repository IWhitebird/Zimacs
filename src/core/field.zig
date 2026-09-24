//! A single-line editable text field: caret, selection, word jumps and
//! deletion, keeping UTF-8 characters whole.

const std = @import("std");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;

pub const TextField = struct {
    bytes: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    /// The other end of the selection, when there is one.
    anchor: ?usize = null,

    const Self = @This();

    pub fn deinit(f: *Self, gpa: Allocator) void {
        f.bytes.deinit(gpa);
    }

    pub fn value(f: Self) []const u8 {
        return f.bytes.items;
    }

    /// Replaces the contents and selects all of it, ready to be typed over.
    pub fn set(f: *Self, gpa: Allocator, s: []const u8) !void {
        f.bytes.clearRetainingCapacity();
        try f.bytes.appendSlice(gpa, s);
        f.selectAll();
    }

    pub fn selectAll(f: *Self) void {
        f.anchor = 0;
        f.caret = f.bytes.items.len;
    }

    pub fn selection(f: Self) ?struct { start: usize, end: usize } {
        const a = f.anchor orelse return null;
        if (a == f.caret) return null;
        return .{ .start = @min(a, f.caret), .end = @max(a, f.caret) };
    }

    /// Types `s`, replacing the selection. Line breaks are dropped.
    pub fn insert(f: *Self, gpa: Allocator, s: []const u8) !void {
        _ = f.deleteSelection();
        for (s) |byte| {
            if (byte == '\n' or byte == '\r') continue;
            try f.bytes.insert(gpa, f.caret, byte);
            f.caret += 1;
        }
    }

    pub fn backspace(f: *Self) void {
        if (f.deleteSelection()) return;
        if (f.caret == 0) return;
        f.remove(charBefore(f.bytes.items, f.caret), f.caret);
    }

    pub fn delete(f: *Self) void {
        if (f.deleteSelection()) return;
        if (f.caret >= f.bytes.items.len) return;
        f.remove(f.caret, charAfter(f.bytes.items, f.caret));
    }

    pub fn deleteWordBefore(f: *Self) void {
        if (f.deleteSelection()) return;
        f.remove(wordBefore(f.bytes.items, f.caret), f.caret);
    }

    pub fn deleteWordAfter(f: *Self) void {
        if (f.deleteSelection()) return;
        f.remove(f.caret, wordAfter(f.bytes.items, f.caret));
    }

    pub fn left(f: *Self, extend: bool) void {
        if (!extend) if (f.selection()) |s| return f.place(s.start, false);
        f.place(if (f.caret == 0) 0 else charBefore(f.bytes.items, f.caret), extend);
    }

    pub fn right(f: *Self, extend: bool) void {
        if (!extend) if (f.selection()) |s| return f.place(s.end, false);
        f.place(if (f.caret >= f.bytes.items.len) f.caret else charAfter(f.bytes.items, f.caret), extend);
    }

    pub fn wordLeft(f: *Self, extend: bool) void {
        f.place(wordBefore(f.bytes.items, f.caret), extend);
    }

    pub fn wordRight(f: *Self, extend: bool) void {
        f.place(wordAfter(f.bytes.items, f.caret), extend);
    }

    pub fn home(f: *Self, extend: bool) void {
        f.place(0, extend);
    }

    pub fn end(f: *Self, extend: bool) void {
        f.place(f.bytes.items.len, extend);
    }

    fn place(f: *Self, at: usize, extend: bool) void {
        if (extend) {
            if (f.anchor == null) f.anchor = f.caret;
        } else {
            f.anchor = null;
        }
        f.caret = at;
    }

    fn deleteSelection(f: *Self) bool {
        const s = f.selection() orelse {
            f.anchor = null;
            return false;
        };
        f.remove(s.start, s.end);
        return true;
    }

    fn remove(f: *Self, start: usize, stop: usize) void {
        if (stop <= start) return;
        const tail = f.bytes.items[stop..];
        std.mem.copyForwards(u8, f.bytes.items[start..], tail);
        f.bytes.shrinkRetainingCapacity(f.bytes.items.len - (stop - start));
        f.caret = start;
        f.anchor = null;
    }
};

fn charBefore(s: []const u8, at: usize) usize {
    var i = at - 1;
    while (i > 0 and text.isTrailing(s[i])) i -= 1;
    return i;
}

fn charAfter(s: []const u8, at: usize) usize {
    var i = at + 1;
    while (i < s.len and text.isTrailing(s[i])) i += 1;
    return i;
}

fn wordBefore(s: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and !text.isWord(s[i - 1])) i -= 1;
    while (i > 0 and text.isWord(s[i - 1])) i -= 1;
    return i;
}

fn wordAfter(s: []const u8, at: usize) usize {
    var i = at;
    while (i < s.len and !text.isWord(s[i])) i += 1;
    while (i < s.len and text.isWord(s[i])) i += 1;
    return i;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "typing inserts at the caret and replaces a selection" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.insert(testing.allocator, "hello");
    f.left(false);
    try f.insert(testing.allocator, "X");
    try testing.expectEqualStrings("hellXo", f.value());

    f.selectAll();
    try f.insert(testing.allocator, "new");
    try testing.expectEqualStrings("new", f.value());
}

test "set selects everything so the first keystroke replaces it" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.set(testing.allocator, "old query");
    try f.insert(testing.allocator, "q");
    try testing.expectEqualStrings("q", f.value());
}

test "backspace and delete keep multi-byte characters whole" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.insert(testing.allocator, "aé");
    f.backspace();
    try testing.expectEqualStrings("a", f.value());
    try f.insert(testing.allocator, "ü");
    f.home(false);
    f.right(false);
    f.delete();
    try testing.expectEqualStrings("a", f.value());
}

test "word jumps and word deletion" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.insert(testing.allocator, "find the word");
    f.deleteWordBefore();
    try testing.expectEqualStrings("find the ", f.value());
    f.home(false);
    f.wordRight(false);
    try testing.expectEqual(@as(usize, 4), f.caret);
    f.deleteWordAfter();
    try testing.expectEqualStrings("find ", f.value());
}

test "shift extends the selection, a plain arrow collapses it" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.insert(testing.allocator, "abcd");
    f.left(true);
    f.left(true);
    try testing.expectEqual(@as(usize, 2), f.selection().?.start);
    f.right(false);
    try testing.expect(f.selection() == null);
    try testing.expectEqual(@as(usize, 4), f.caret);
}

test "pasted line breaks are dropped" {
    var f = TextField{};
    defer f.deinit(testing.allocator);
    try f.insert(testing.allocator, "one\r\ntwo");
    try testing.expectEqualStrings("onetwo", f.value());
}
