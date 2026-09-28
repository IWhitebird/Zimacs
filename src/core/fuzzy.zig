//! Ranking paths against a few typed letters, the way quick open works: the
//! letters must appear in order, and a match ranks higher where its letters
//! start words or path parts, run together, and fall in the file's own name.

const std = @import("std");

/// Paths longer than this are matched but not ranked.
const max_ranked = 512;

const boundary_bonus = 30;
const consecutive_bonus = 20;
/// For each letter matched inside the file's name rather than its folders.
const name_bonus = 10;
const gap_penalty = 1;
const unmatched: i32 = std.math.minInt(i32) / 2;

/// Null when `pattern` does not appear in `text` in order, ignoring case.
/// Higher is better.
pub fn score(text: []const u8, pattern: []const u8) ?i32 {
    if (pattern.len == 0) return 0;
    if (!inOrder(text, pattern)) return null;
    if (text.len > max_ranked) return 0;

    const name_start = if (std.mem.findScalarLast(u8, text, '/')) |slash| slash + 1 else 0;
    var rows: [2][max_ranked]i32 = undefined;
    var prev = &rows[0];
    var cur = &rows[1];

    for (pattern, 0..) |wanted, i| {
        // Best of the previous row up to the column before, less a penalty
        // for each letter skipped since.
        var running: i32 = unmatched;
        for (text, 0..) |c, j| {
            if (i > 0 and j > 0) running = @max(running - gap_penalty, prev[j - 1]);
            cur[j] = unmatched;
            if (std.ascii.toLower(c) != std.ascii.toLower(wanted)) continue;
            const here = bonus(text, j, name_start);
            if (i == 0) {
                cur[j] = here;
            } else if (j > 0 and running > unmatched) {
                const adjacent = if (prev[j - 1] > unmatched) prev[j - 1] + consecutive_bonus else unmatched;
                cur[j] = here + @max(running, adjacent);
            }
        }
        std.mem.swap(*[max_ranked]i32, &prev, &cur);
    }

    var best: i32 = unmatched;
    for (prev[0..text.len]) |s| best = @max(best, s);
    // Of two equally good matches, the shorter path.
    return best - @as(i32, @intCast(text.len / 8));
}

fn inOrder(text: []const u8, pattern: []const u8) bool {
    var at: usize = 0;
    for (text) |c| {
        if (std.ascii.toLower(c) == std.ascii.toLower(pattern[at])) {
            at += 1;
            if (at == pattern.len) return true;
        }
    }
    return false;
}

fn bonus(text: []const u8, j: usize, name_start: usize) i32 {
    var b: i32 = if (j >= name_start) name_bonus else 0;
    if (j == 0 or j == name_start) return b + boundary_bonus;
    const before = text[j - 1];
    const starts_word = switch (before) {
        '/', '\\', '_', '-', '.', ' ' => true,
        else => std.ascii.isLower(before) and std.ascii.isUpper(text[j]),
    };
    if (starts_word) b += boundary_bonus;
    return b;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "letters must come in order" {
    try testing.expect(score("src/core/buffer.zig", "buf") != null);
    try testing.expect(score("src/core/buffer.zig", "BUF") != null);
    try testing.expect(score("src/core/buffer.zig", "fub") == null);
    try testing.expect(score("a.txt", "") != null);
}

test "a match in the file's own name beats one spread over its folders" {
    try testing.expect(score("src/core/editor.zig", "ed").? > score("docs/extra/dump.txt", "ed").?);
    try testing.expect(score("src/core/buffer.zig", "buf").? > score("build/utils/fetch.zig", "buf").?);
}

test "letters that start words and run together rank higher" {
    try testing.expect(score("src/core/piece_tree.zig", "pt").? > score("src/core/prompt.zig", "pt").?);
    try testing.expect(score("src/zimacs.zig", "zim").? > score("src/core/zoomimage.zig", "zim").?);
    try testing.expect(score("src/core/fileDialog.zig", "fd").? > score("src/core/fiddle.zig", "fd").?);
}
