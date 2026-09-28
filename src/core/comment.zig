//! Commenting lines out and back in. Every selected line gets the language's
//! line comment at the block's shallowest indentation, so the markers line
//! up, unless all of them already have one, in which case it comes off.
//! Languages with only block comments wrap each line instead.

const std = @import("std");
const BufferView = @import("buffer.zig").BufferView;
const Language = @import("language.zig").Language;

/// One undoable edit. False when the language has no comments.
pub fn toggle(view: *BufferView, lang: *const Language) !bool {
    if (lang.line_comment == null and lang.block_comment == null) return false;
    const lines = view.selectedLines();
    const start = view.tree.lineStart(lines.first);
    const end = view.tree.lineEnd(lines.last);

    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(view.gpa);
    try view.tree.copy(start, end - start, &old);

    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(view.gpa);
    try rewrite(view.gpa, old.items, lang, &new);

    const selection = view.cursor.selection();
    const caret = view.cursor.offset;
    try view.edit(start, end - start, new.items);

    if (selection != null) {
        // Keep the whole block selected, so it can be toggled back.
        view.cursor.anchor = start;
        view.cursor.offset = start + @as(u32, @intCast(new.items.len));
    } else {
        // The caret stays on the same text, moved by what was added or taken.
        const moved = @as(i64, @intCast(new.items.len)) - @as(i64, @intCast(old.items.len));
        const at = @max(@as(i64, start), @as(i64, caret) + moved);
        view.cursor.moveTo(&view.tree, @intCast(@min(at, start + new.items.len)), false);
    }
    return true;
}

/// `lines` commented or uncommented, into `out`.
pub fn rewrite(gpa: std.mem.Allocator, lines: []const u8, lang: *const Language, out: *std.ArrayList(u8)) !void {
    if (lang.line_comment) |marker| return rewriteLines(gpa, lines, marker, out);
    const pair = lang.block_comment.?;
    return rewriteBlocks(gpa, lines, pair[0], pair[1], out);
}

fn rewriteLines(gpa: std.mem.Allocator, lines: []const u8, marker: []const u8, out: *std.ArrayList(u8)) !void {
    var all_commented = true;
    var column: usize = std.math.maxInt(usize);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0) continue;
        column = @min(column, line.len - body.len);
        if (!std.mem.startsWith(u8, body, marker)) all_commented = false;
    }
    // Only blank lines: comment them where they stand.
    const only_blank = column == std.math.maxInt(usize);
    if (only_blank) {
        column = 0;
        all_commented = false;
    }

    it = std.mem.splitScalar(u8, lines, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0 and !only_blank) {
            // Blank lines among others stay blank either way.
            try out.appendSlice(gpa, line);
        } else if (all_commented) {
            const indent = line[0 .. line.len - body.len];
            var rest = body[marker.len..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try out.appendSlice(gpa, indent);
            try out.appendSlice(gpa, rest);
        } else {
            const at = @min(column, line.len);
            try out.appendSlice(gpa, line[0..at]);
            try out.appendSlice(gpa, marker);
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, line[at..]);
        }
    }
}

fn rewriteBlocks(gpa: std.mem.Allocator, lines: []const u8, open: []const u8, close: []const u8, out: *std.ArrayList(u8)) !void {
    var all_commented = true;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const body = std.mem.trim(u8, line, " \t");
        if (body.len == 0) continue;
        if (!std.mem.startsWith(u8, body, open) or !std.mem.endsWith(u8, body, close)) all_commented = false;
    }

    it = std.mem.splitScalar(u8, lines, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const body = std.mem.trim(u8, line, " \t");
        if (body.len == 0) {
            try out.appendSlice(gpa, line);
            continue;
        }
        const indent = line[0..std.mem.indexOf(u8, line, body).?];
        try out.appendSlice(gpa, indent);
        if (all_commented) {
            const inner = std.mem.trim(u8, body[open.len .. body.len - close.len], " ");
            try out.appendSlice(gpa, inner);
        } else {
            try out.print(gpa, "{s} {s} {s}", .{ open, body, close });
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const language = @import("language.zig");

fn expectRewrite(lang_name: []const u8, before: []const u8, after: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try rewrite(testing.allocator, before, language.detect(lang_name), &out);
    try testing.expectEqualStrings(after, out.items);
}

test "lines are commented at the shallowest indentation, blank lines left alone" {
    try expectRewrite("a.zig", "    a();\n\n  if (x) {", "  //   a();\n\n  // if (x) {");
}

test "an all-commented block is uncommented, with the space after the marker" {
    try expectRewrite("a.zig", "  //   a();\n\n  // if (x) {", "    a();\n\n  if (x) {");
    try expectRewrite("a.py", "#x\n# y", "x\ny");
}

test "a mix of commented and plain lines is all commented" {
    try expectRewrite("a.sh", "# done\nls", "# # done\n# ls");
}

test "block-only languages wrap each line, and unwrap it again" {
    try expectRewrite("a.css", "  a { b: c; }", "  /* a { b: c; } */");
    try expectRewrite("a.css", "  /* a { b: c; } */", "  a { b: c; }");
    try expectRewrite("a.html", "<p>hi</p>", "<!-- <p>hi</p> -->");
}

test "the caret keeps its place on the line" {
    const Buffer = @import("buffer.zig").Buffer;
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newFilled("x.zig", "  const a = 1;\nnext");
    v.cursor.moveTo(&v.tree, 8, false);
    try testing.expect(try toggle(v, language.detect("x.zig")));
    const all = try v.tree.allocText(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("  // const a = 1;\nnext", all);
    try testing.expectEqual(@as(u32, 11), v.cursor.offset);
    try testing.expect(!try toggle(v, &language.plain));
}
