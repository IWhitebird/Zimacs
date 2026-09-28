//! The small part of regular expressions that highlight queries use in
//! their #match? predicates: anchors, literals, `.`, classes such as
//! `[A-Z\d_]`, a group of alternatives, and the `*`, `+` and `?` repeats.
//! Anything else fails to match, which only leaves a node uncoloured.

const std = @import("std");

pub fn matches(pattern: []const u8, subject: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') return matchHere(pattern[1..], subject, 0);
    var start: usize = 0;
    while (start <= subject.len) : (start += 1) {
        if (matchHere(pattern, subject, start)) return true;
    }
    return false;
}

/// Whether `pattern` matches `subject` starting at `at`, to its own end
/// or, with a final `$`, to the end of `subject`.
fn matchHere(pattern: []const u8, subject: []const u8, at: usize) bool {
    if (pattern.len == 0) return true;
    if (pattern.len == 1 and pattern[0] == '$') return at == subject.len;
    if (pattern[0] == '(') return matchGroup(pattern, subject, at);

    const atom = atomLen(pattern) orelse return false;
    const repeat: u8 = if (atom < pattern.len) pattern[atom] else 0;
    const rest_start = atom + @intFromBool(repeat == '*' or repeat == '+' or repeat == '?');
    const rest = pattern[rest_start..];

    switch (repeat) {
        '*', '+', '?' => {
            var count: usize = 0;
            while (at + count < subject.len and atomMatches(pattern[0..atom], subject[at + count])) : (count += 1) {
                if (repeat == '?' and count == 1) break;
            }
            const least: usize = if (repeat == '+') 1 else 0;
            // Longest first, backing off one at a time.
            var n = count;
            while (true) : (n -= 1) {
                if (n < least) return false;
                if (matchHere(rest, subject, at + n)) return true;
                if (n == 0) return false;
            }
        },
        else => {
            if (at >= subject.len or !atomMatches(pattern[0..atom], subject[at])) return false;
            return matchHere(rest, subject, at + 1);
        },
    }
}

/// `(a|b|c)` followed by the rest of the pattern.
fn matchGroup(pattern: []const u8, subject: []const u8, at: usize) bool {
    const close = std.mem.findScalar(u8, pattern, ')') orelse return false;
    const rest = pattern[close + 1 ..];
    var options = std.mem.splitScalar(u8, pattern[1..close], '|');
    while (options.next()) |option| {
        if (at + option.len > subject.len) continue;
        if (!std.mem.eql(u8, subject[at..][0..option.len], option)) continue;
        if (matchHere(rest, subject, at + option.len)) return true;
    }
    return false;
}

/// Bytes the first atom of `pattern` takes: a character, an escape, or a
/// bracketed class. Null when it is not something this module handles.
fn atomLen(pattern: []const u8) ?usize {
    return switch (pattern[0]) {
        '\\' => if (pattern.len >= 2) 2 else null,
        '[' => if (std.mem.findScalarPos(u8, pattern, 2, ']')) |end| end + 1 else null,
        '*', '+', '?', ')', '|' => null,
        else => 1,
    };
}

fn atomMatches(atom: []const u8, c: u8) bool {
    return switch (atom[0]) {
        '.' => true,
        '\\' => escapeMatches(atom[1], c),
        '[' => classMatches(atom[1 .. atom.len - 1], c),
        else => atom[0] == c,
    };
}

fn escapeMatches(e: u8, c: u8) bool {
    return switch (e) {
        'd' => std.ascii.isDigit(c),
        'w' => std.ascii.isAlphanumeric(c) or c == '_',
        's' => std.ascii.isWhitespace(c),
        else => e == c,
    };
}

fn classMatches(class: []const u8, c: u8) bool {
    const negated = class.len > 0 and class[0] == '^';
    const body = if (negated) class[1..] else class;
    var i: usize = 0;
    var hit = false;
    while (i < body.len) {
        if (body[i] == '\\' and i + 1 < body.len) {
            hit = hit or escapeMatches(body[i + 1], c);
            i += 2;
        } else if (i + 2 < body.len and body[i + 1] == '-') {
            hit = hit or (c >= body[i] and c <= body[i + 2]);
            i += 3;
        } else {
            hit = hit or body[i] == c;
            i += 1;
        }
    }
    return hit != negated;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the constant patterns highlight queries use" {
    try testing.expect(matches("^[A-Z][A-Z\\d_]+$", "MAX_SIZE"));
    try testing.expect(matches("^[A-Z][A-Z\\d_]+$", "A1"));
    try testing.expect(!matches("^[A-Z][A-Z\\d_]+$", "A"));
    try testing.expect(!matches("^[A-Z][A-Z\\d_]+$", "Max"));
    try testing.expect(matches("^_*[A-Z][A-Z\\d_]+$", "__FILE_NAME"));
    try testing.expect(matches("^[A-Z_][a-zA-Z0-9_]*", "Point"));
    try testing.expect(!matches("^[A-Z_][a-zA-Z0-9_]*", "point"));
    try testing.expect(matches("^[A-Z]", "Type"));
}

test "a group of names matches whole words only" {
    const builtins = "^(len|make|new|print|println)$";
    try testing.expect(matches(builtins, "len"));
    try testing.expect(matches(builtins, "println"));
    try testing.expect(!matches(builtins, "lens"));
    try testing.expect(!matches(builtins, "printl"));
}

test "prefixes and unanchored searches" {
    try testing.expect(matches("^//!", "//! module doc"));
    try testing.expect(!matches("^//!", "// plain"));
    try testing.expect(matches("^--", "--flag"));
    try testing.expect(matches("b+c", "aabbbcd"));
    try testing.expect(matches("colou?r", "color"));
    try testing.expect(!matches("[^a-z]", "abc"));
}

test "a pattern it cannot read never matches" {
    try testing.expect(!matches("^(unclosed", "unclosed"));
    try testing.expect(!matches("[abc", "a"));
}
