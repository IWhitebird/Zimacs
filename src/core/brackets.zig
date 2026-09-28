//! The bracket matching the one beside the caret, so both can be marked.

const std = @import("std");
const PieceTree = @import("piecetree.zig").PieceTree;

pub const Pair = struct { open: u32, close: u32 };

pub const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };

/// How far to look for the partner before giving up, so a stray bracket
/// in a large file cannot stall a frame.
const max_scan = 200_000;

/// The bracket just after the caret wins over the one just before it.
pub fn match(tree: *const PieceTree, caret: u32) ?Pair {
    if (tree.byteAt(caret)) |c| if (partner(tree, caret, c)) |p| return p;
    if (caret > 0) if (tree.byteAt(caret - 1)) |c| if (partner(tree, caret - 1, c)) |p| return p;
    return null;
}

fn partner(tree: *const PieceTree, at: u32, c: u8) ?Pair {
    for (pairs) |pair| {
        if (c == pair[0]) return .{ .open = at, .close = scan(tree, at, pair, .forward) orelse return null };
        if (c == pair[1]) return .{ .open = scan(tree, at, pair, .backward) orelse return null, .close = at };
    }
    return null;
}

fn scan(tree: *const PieceTree, from: u32, pair: [2]u8, direction: enum { forward, backward }) ?u32 {
    const same = if (direction == .forward) pair[0] else pair[1];
    const other = if (direction == .forward) pair[1] else pair[0];
    var depth: u32 = 0;
    var at = from;
    var scanned: u32 = 0;
    while (scanned < max_scan) : (scanned += 1) {
        if (direction == .forward) {
            at += 1;
            if (at >= tree.len()) return null;
        } else {
            if (at == 0) return null;
            at -= 1;
        }
        const c = tree.byteAt(at).?;
        if (c == same) depth += 1;
        if (c == other) {
            if (depth == 0) return at;
            depth -= 1;
        }
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectMatch(src: []const u8, caret: u32, want: ?Pair) !void {
    var tree = try PieceTree.initFromBytes(testing.allocator, src);
    defer tree.deinit();
    try testing.expectEqual(want, match(&tree, caret));
}

test "a bracket after or before the caret finds its partner across nesting" {
    //                    0123456789
    try expectMatch("f(a(b)c)", 1, .{ .open = 1, .close = 7 });
    try expectMatch("f(a(b)c)", 8, .{ .open = 1, .close = 7 });
    try expectMatch("f(a(b)c)", 4, .{ .open = 3, .close = 5 });
    try expectMatch("{ [ ] }", 7, .{ .open = 0, .close = 6 });
}

test "unmatched and absent brackets give nothing" {
    try expectMatch("f(a", 1, null);
    try expectMatch("plain", 2, null);
    try expectMatch("", 0, null);
}

test "the kinds are kept apart" {
    try expectMatch("( [ ) ]", 0, .{ .open = 0, .close = 4 });
}
