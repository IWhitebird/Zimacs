//! Finding text: matching with case and whole-word options, counting, and
//! building the result of a replace-all. Works on plain slices, so it is
//! independent of how the document is stored.

const std = @import("std");
const text = @import("text.zig");

pub const Options = struct {
    match_case: bool = false,
    whole_word: bool = false,
};

pub const Match = struct {
    start: usize,
    end: usize,
};

/// First match starting at or after `from`.
pub fn next(hay: []const u8, needle: []const u8, from: usize, o: Options) ?Match {
    if (needle.len == 0) return null;
    var at = from;
    while (at + needle.len <= hay.len) {
        const found = rawIndex(hay, needle, at, o) orelse return null;
        if (!o.whole_word or isWholeWord(hay, found, needle.len)) {
            return .{ .start = found, .end = found + needle.len };
        }
        at = found + 1;
    }
    return null;
}

/// Last match starting before `before`.
pub fn previous(hay: []const u8, needle: []const u8, before: usize, o: Options) ?Match {
    var best: ?Match = null;
    var at: usize = 0;
    while (next(hay, needle, at, o)) |m| {
        if (m.start >= before) break;
        best = m;
        at = m.start + 1;
    }
    return best;
}

/// Non-overlapping matches, the ones a replace-all would change.
pub fn count(hay: []const u8, needle: []const u8, o: Options) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (next(hay, needle, at, o)) |m| {
        n += 1;
        at = m.end;
    }
    return n;
}

/// Which match, counting from 1, starts at `start`. Null when none does.
pub fn ordinal(hay: []const u8, needle: []const u8, start: usize, o: Options) ?usize {
    var n: usize = 0;
    var at: usize = 0;
    while (next(hay, needle, at, o)) |m| {
        n += 1;
        if (m.start == start) return n;
        if (m.start > start) return null;
        at = m.end;
    }
    return null;
}

pub const Replaced = struct {
    /// The span of `hay` that changes, and what replaces it.
    start: usize,
    end: usize,
    text: []u8,
    count: usize,

    pub fn deinit(r: Replaced, gpa: std.mem.Allocator) void {
        gpa.free(r.text);
    }
};

/// Every match replaced, expressed as one span edit from the first match to
/// the end of the last, so it undoes in one step. Null when nothing matches.
pub fn replaceAll(
    gpa: std.mem.Allocator,
    hay: []const u8,
    needle: []const u8,
    replacement: []const u8,
    o: Options,
) !?Replaced {
    const first = next(hay, needle, 0, o) orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var n: usize = 0;
    var copied = first.start;
    var end = first.end;
    var at: usize = first.start;
    while (next(hay, needle, at, o)) |m| {
        try out.appendSlice(gpa, hay[copied..m.start]);
        try out.appendSlice(gpa, replacement);
        copied = m.end;
        end = m.end;
        at = m.end;
        n += 1;
    }
    return .{ .start = first.start, .end = end, .text = try out.toOwnedSlice(gpa), .count = n };
}

fn rawIndex(hay: []const u8, needle: []const u8, from: usize, o: Options) ?usize {
    if (o.match_case) return std.mem.indexOfPos(u8, hay, from, needle);
    return std.ascii.indexOfIgnoreCasePos(hay, from, needle);
}

fn isWholeWord(hay: []const u8, start: usize, len: usize) bool {
    const before_ok = start == 0 or !text.isWord(hay[start - 1]);
    const after_ok = start + len >= hay.len or !text.isWord(hay[start + len]);
    return before_ok and after_ok;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "finds matches ignoring case unless asked not to" {
    const hay = "Foo foo FOO";
    try testing.expectEqual(@as(usize, 0), next(hay, "foo", 0, .{}).?.start);
    try testing.expectEqual(@as(usize, 4), next(hay, "foo", 0, .{ .match_case = true }).?.start);
    try testing.expectEqual(@as(usize, 3), count(hay, "foo", .{}));
    try testing.expectEqual(@as(usize, 1), count(hay, "foo", .{ .match_case = true }));
}

test "whole word skips matches inside longer words" {
    const hay = "cat concat cats cat";
    try testing.expectEqual(@as(usize, 4), count(hay, "cat", .{}));
    try testing.expectEqual(@as(usize, 2), count(hay, "cat", .{ .whole_word = true }));
    try testing.expectEqual(@as(usize, 16), next(hay, "cat", 1, .{ .whole_word = true }).?.start);
}

test "previous finds the last match before a point" {
    const hay = "ab ab ab";
    try testing.expectEqual(@as(usize, 3), previous(hay, "ab", 6, .{}).?.start);
    try testing.expect(previous(hay, "ab", 0, .{}) == null);
}

test "ordinal numbers matches from one" {
    const hay = "x.x.x";
    try testing.expectEqual(@as(?usize, 2), ordinal(hay, "x", 2, .{}));
    try testing.expectEqual(@as(?usize, null), ordinal(hay, "x", 1, .{}));
}

test "an empty needle matches nothing" {
    try testing.expect(next("abc", "", 0, .{}) == null);
    try testing.expectEqual(@as(usize, 0), count("abc", "", .{}));
}

test "replace all produces one span covering every match" {
    const hay = "a cat and a cat.";
    const r = (try replaceAll(testing.allocator, hay, "cat", "dog", .{})).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expectEqual(@as(usize, 2), r.start);
    try testing.expectEqual(@as(usize, 15), r.end);
    try testing.expectEqualStrings("dog and a dog", r.text);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(testing.allocator);
    try whole.appendSlice(testing.allocator, hay[0..r.start]);
    try whole.appendSlice(testing.allocator, r.text);
    try whole.appendSlice(testing.allocator, hay[r.end..]);
    try testing.expectEqualStrings("a dog and a dog.", whole.items);
}

test "replace all does not rematch inside its own replacement" {
    const r = (try replaceAll(testing.allocator, "aaa", "a", "aa", .{})).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqualStrings("aaaaaa", r.text);
}

test "replace all with nothing to find changes nothing" {
    try testing.expect(try replaceAll(testing.allocator, "abc", "z", "y", .{}) == null);
}
