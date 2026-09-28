//! What typing does in code beyond inserting the character: a bracket or
//! quote brings its closer, typing that closer steps over it, a selection is
//! wrapped instead of replaced, Backspace in an empty pair removes both, and
//! Enter between brackets opens an indented line inside them.

const std = @import("std");
const BufferView = @import("buffer.zig").BufferView;
const Language = @import("language.zig").Language;
const text = @import("text.zig");

const brackets = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };

pub fn typeText(view: *BufferView, typed: []const u8, lang: *const Language) !void {
    if (!lang.code or typed.len != 1) return view.insert(typed);
    const c = typed[0];

    if (view.cursor.selection()) |r| {
        const close = closerOf(c, lang) orelse return view.insert(typed);
        // The selection stays selected, now inside the pair.
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(view.gpa);
        try wrapped.append(view.gpa, c);
        try view.tree.copy(r.start, r.len(), &wrapped);
        try wrapped.append(view.gpa, close);
        try view.edit(r.start, r.len(), wrapped.items);
        view.cursor.anchor = r.start + 1;
        view.cursor.offset = r.start + 1 + r.len();
        return;
    }

    const caret = view.cursor.offset;
    const before = if (caret > 0) view.tree.byteAt(caret - 1) else null;
    const after = view.tree.byteAt(caret);

    if (after == c and isCloser(c, lang)) {
        view.cursor.moveTo(&view.tree, caret + 1, false);
        return;
    }
    if (closerOf(c, lang)) |close| {
        if (shouldClose(c, close, before, after)) {
            try view.insert(&.{ c, close });
            view.cursor.moveTo(&view.tree, caret + 1, false);
            return;
        }
    }
    try view.insert(typed);
}

pub fn backspace(view: *BufferView, lang: *const Language) !void {
    if (lang.code and view.cursor.selection() == null and view.cursor.offset > 0) {
        const caret = view.cursor.offset;
        const before = view.tree.byteAt(caret - 1).?;
        if (closerOf(before, lang)) |close| {
            if (view.tree.byteAt(caret) == close) return view.edit(caret - 1, 2, "");
        }
    }
    try view.backspace();
}

/// `indent_unit` is what one level of indentation is made of.
pub fn newline(view: *BufferView, lang: *const Language, indent_unit: []const u8) !void {
    const caret = view.cursor.offset;
    const between = lang.code and view.cursor.selection() == null and caret > 0 and
        isBracketPair(view.tree.byteAt(caret - 1).?, view.tree.byteAt(caret));
    if (!between) return view.newline();

    var indent: std.ArrayList(u8) = .empty;
    defer indent.deinit(view.gpa);
    try view.appendIndent(view.tree.positionAt(caret).line, caret, &indent);

    var inserted: std.ArrayList(u8) = .empty;
    defer inserted.deinit(view.gpa);
    try inserted.append(view.gpa, '\n');
    try inserted.appendSlice(view.gpa, indent.items);
    try inserted.appendSlice(view.gpa, indent_unit);
    const inside: u32 = @intCast(inserted.items.len);
    try inserted.append(view.gpa, '\n');
    try inserted.appendSlice(view.gpa, indent.items);
    try view.edit(caret, 0, inserted.items);
    view.cursor.moveTo(&view.tree, caret + inside, false);
}

fn closerOf(opener: u8, lang: *const Language) ?u8 {
    for (brackets) |pair| if (pair[0] == opener) return pair[1];
    if (std.mem.indexOfScalar(u8, lang.quotes, opener) != null) return opener;
    return null;
}

fn isCloser(c: u8, lang: *const Language) bool {
    for (brackets) |pair| if (pair[1] == c) return true;
    return std.mem.indexOfScalar(u8, lang.quotes, c) != null;
}

fn isBracketPair(open: u8, close: ?u8) bool {
    for (brackets) |pair| if (pair[0] == open and pair[1] == close) return true;
    return false;
}

/// A closer is added only where nothing is being typed into, and a quote
/// not straight after a word, so "don't" and 'x' stay as typed.
fn shouldClose(open: u8, close: u8, before: ?u8, after: ?u8) bool {
    const room = if (after) |a| switch (a) {
        ' ', '\t', '\r', '\n', ')', ']', '}', ',', ';', ':', '.', '>' => true,
        else => false,
    } else true;
    if (!room) return false;
    if (open != close) return true;
    const prev = before orelse return true;
    return !text.isWord(prev) and prev != open and prev != '\\';
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const language = @import("language.zig");

const zig = language.detect("x.zig");

fn expectText(view: *BufferView, expected: []const u8, caret: u32) !void {
    const all = try view.tree.allocText(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings(expected, all);
    try testing.expectEqual(caret, view.cursor.offset);
}

fn typeAll(view: *BufferView, s: []const u8, lang: *const Language) !void {
    for (s) |c| try typeText(view, &.{c}, lang);
}

test "a bracket brings its closer, and typing the closer steps over it" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newScratch();
    try typeAll(v, "f(", zig);
    try expectText(v, "f()", 2);
    try typeAll(v, "x)", zig);
    try expectText(v, "f(x)", 4);
}

test "quotes pair, but not after a word or inside one" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newScratch();
    try typeAll(v, "a = \"", zig);
    try expectText(v, "a = \"\"", 5);
    try typeAll(v, "hi\"", zig);
    try expectText(v, "a = \"hi\"", 8);
    try typeAll(v, " don't", zig);
    try expectText(v, "a = \"hi\" don't", 14);
}

test "no closer is added in front of a word" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newFilled("x.zig", "name");
    v.cursor.moveTo(&v.tree, 0, false);
    try typeText(v, "(", zig);
    try expectText(v, "(name", 1);
}

test "a selection is wrapped and stays selected" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newFilled("x.zig", "a word b");
    v.cursor.anchor = 2;
    v.cursor.offset = 6;
    try typeText(v, "[", zig);
    try expectText(v, "a [word] b", 7);
    try testing.expectEqual(@as(?u32, 3), v.cursor.anchor);
}

test "backspace in an empty pair removes both halves" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newScratch();
    try typeAll(v, "x{", zig);
    try backspace(v, zig);
    try expectText(v, "x", 1);
}

test "enter between braces opens an indented line inside them" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newScratch();
    try typeAll(v, "  fn() {", zig);
    try newline(v, zig, "    ");
    try expectText(v, "  fn() {\n      \n  }", 15);
}

test "prose is typed as is" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const v = try b.newScratch();
    try typeAll(v, "(\"", &language.plain);
    try expectText(v, "(\"", 2);
}
