//! The find and replace bar: its state, what its buttons do, and where its
//! parts sit. Drawn by `editor.zig`, driven by `input.zig`; matching itself
//! is `search.zig`.

const std = @import("std");
const pen = @import("raylib");
const search = @import("search.zig");
const layout = @import("layout.zig");
const TextField = @import("field.zig").TextField;
const BufferView = @import("buffer.zig").BufferView;
const Font = @import("font.zig").Font;
const Layout = layout.Layout;
const Allocator = std.mem.Allocator;

pub const Field = enum { find, replace };
pub const Direction = enum { forward, backward };

pub const Control = enum {
    expand,
    find_field,
    replace_field,
    match_case,
    whole_word,
    previous,
    next,
    close,
    replace_one,
    replace_all,
};

pub const Find = struct {
    gpa: Allocator = undefined,
    open: bool = false,
    /// The replace row is showing.
    replacing: bool = false,
    /// Which field has the keyboard; null while the document has it.
    focus: ?Field = null,
    query: TextField = .{},
    replacement: TextField = .{},
    options: search.Options = .{},
    /// Where the caret was when the bar opened; typing searches from here.
    origin: u32 = 0,

    /// The document's text, recopied only when it changes.
    snapshot: std.ArrayList(u8) = .empty,
    snapshot_of: ?*const BufferView = null,
    snapshot_version: u64 = 0,
    total: usize = 0,
    counted_for: ?u64 = null,

    const Self = @This();

    pub fn deinit(f: *Self) void {
        f.query.deinit(f.gpa);
        f.replacement.deinit(f.gpa);
        f.snapshot.deinit(f.gpa);
    }

    /// Opens with the keyboard in the find field. `seed`, usually the
    /// selection, replaces the query; otherwise the last one is selected.
    pub fn begin(f: *Self, view: ?*const BufferView, replacing: bool, seed: ?[]const u8) !void {
        f.open = true;
        f.replacing = f.replacing or replacing;
        f.focus = .find;
        if (seed) |s| try f.query.set(f.gpa, s) else f.query.selectAll();
        if (view) |v| f.origin = if (v.cursor.selection()) |r| r.start else v.cursor.offset;
    }

    pub fn close(f: *Self) void {
        f.open = false;
        f.focus = null;
        f.snapshot.clearAndFree(f.gpa);
        f.snapshot_of = null;
        f.counted_for = null;
    }

    pub fn field(f: *Self, which: Field) *TextField {
        return switch (which) {
            .find => &f.query,
            .replace => &f.replacement,
        };
    }

    pub fn focused(f: *Self) ?*TextField {
        return f.field(f.focus orelse return null);
    }

    pub fn toggle(f: *Self, control: Control) void {
        switch (control) {
            .match_case => f.options.match_case = !f.options.match_case,
            .whole_word => f.options.whole_word = !f.options.whole_word,
            .expand => {
                f.replacing = !f.replacing;
                if (!f.replacing and f.focus == .replace) f.focus = .find;
            },
            else => {},
        }
    }

    /// Brings the text copy and the match count up to date with `view`.
    pub fn sync(f: *Self, view: *const BufferView) !void {
        if (f.snapshot_of != view or f.snapshot_version != view.version) {
            f.snapshot.clearRetainingCapacity();
            try view.tree.copy(0, view.tree.len(), &f.snapshot);
            f.snapshot_of = view;
            f.snapshot_version = view.version;
            f.counted_for = null;
        }
        const key = f.countKey();
        if (f.counted_for != key) {
            f.total = search.count(f.snapshot.items, f.query.value(), f.options);
            f.counted_for = key;
        }
    }

    /// Which match the selection is, counting from 1, for "3 of 17".
    pub fn current(f: *const Self, view: *const BufferView) ?usize {
        const r = view.cursor.selection() orelse return null;
        if (r.len() != f.query.value().len) return null;
        return search.ordinal(f.snapshot.items, f.query.value(), r.start, f.options);
    }

    /// Matches starting in `[start, end)`, from the synced snapshot.
    pub fn matchesIn(f: *const Self, start: usize, end: usize, out: *std.ArrayList(search.Match)) !void {
        out.clearRetainingCapacity();
        var at = start;
        while (search.next(f.snapshot.items, f.query.value(), at, f.options)) |m| {
            if (m.start >= end) break;
            try out.append(f.gpa, m);
            at = m.end;
        }
    }

    /// Selects the next or previous match, wrapping round the ends.
    pub fn step(f: *Self, view: *BufferView, direction: Direction) !void {
        try f.sync(view);
        const hay = f.snapshot.items;
        const needle = f.query.value();
        const found = switch (direction) {
            .forward => search.next(hay, needle, view.cursor.offset, f.options) orelse
                search.next(hay, needle, 0, f.options),
            .backward => search.previous(hay, needle, selectionStart(view), f.options) orelse
                search.previous(hay, needle, hay.len, f.options),
        };
        if (found) |m| select(view, m);
    }

    /// Jumps to the first match from where the bar opened, as the query is typed.
    pub fn searchFromOrigin(f: *Self, view: *BufferView) !void {
        try f.sync(view);
        const hay = f.snapshot.items;
        const needle = f.query.value();
        const found = search.next(hay, needle, f.origin, f.options) orelse search.next(hay, needle, 0, f.options);
        if (found) |m| select(view, m) else view.cursor.moveTo(&view.tree, f.origin, false);
    }

    /// Replaces the selected match, if it is one, then moves to the next.
    pub fn replaceOne(f: *Self, view: *BufferView) !void {
        try f.sync(view);
        if (f.current(view) != null) try view.insert(f.replacement.value());
        try f.step(view, .forward);
    }

    /// Returns how many were replaced. One edit, so one undo.
    pub fn replaceAll(f: *Self, view: *BufferView) !usize {
        try f.sync(view);
        const r = try search.replaceAll(f.gpa, f.snapshot.items, f.query.value(), f.replacement.value(), f.options) orelse
            return 0;
        defer r.deinit(f.gpa);
        try view.edit(@intCast(r.start), @intCast(r.end - r.start), r.text);
        return r.count;
    }

    fn countKey(f: *const Self) u64 {
        var h = std.hash.Wyhash.init(f.snapshot_version);
        h.update(f.query.value());
        h.update(std.mem.asBytes(&f.options));
        return h.final();
    }
};

fn selectionStart(view: *const BufferView) usize {
    return if (view.cursor.selection()) |r| r.start else view.cursor.offset;
}

fn select(view: *BufferView, m: search.Match) void {
    view.cursor.moveTo(&view.tree, @intCast(m.start), false);
    view.cursor.anchor = @intCast(m.start);
    view.cursor.offset = @intCast(m.end);
}

// ------------------------------------------------------------- geometry

/// Width of the text fields, in character columns.
const field_columns = 26;
const narrowest_field = 8;
/// Room for "9999 of 9999".
const count_columns = 12;

pub const Geometry = struct {
    panel: pen.Rectangle,
    expand: pen.Rectangle,
    find_field: pen.Rectangle,
    replace_field: pen.Rectangle,
    match_case: pen.Rectangle,
    whole_word: pen.Rectangle,
    count: pen.Rectangle,
    previous: pen.Rectangle,
    next: pen.Rectangle,
    close: pen.Rectangle,
    replace_one: pen.Rectangle,
    replace_all: pen.Rectangle,

    pub fn rect(g: Geometry, c: Control) pen.Rectangle {
        return switch (c) {
            inline else => |tag| @field(g, @tagName(tag)),
        };
    }
};

pub const replace_one_label = "Replace";
pub const replace_all_label = "All";

/// Anchored to the top right of the text area, as editors usually place it.
pub fn geometry(l: Layout, font: Font, replacing: bool) Geometry {
    const pad = layout.padding;
    const gap = pad / 2;
    const cell = font.metrics.width;
    const row = font.metrics.height + pad;
    const toggle_width = cell * 2 + pad;
    const square = row;

    const fixed = gap + toggle_width + gap + gap + toggle_width * 2 + gap + cell * count_columns + square * 3 + gap;
    const room = l.text.width - pad * 2 - fixed;
    const field_width = std.math.clamp(room, cell * narrowest_field, cell * field_columns);
    const width = fixed + field_width;
    const rows: f32 = if (replacing) 2 else 1;

    const panel = pen.Rectangle{
        .x = l.text.x + l.text.width - width - pad,
        .y = l.text.y,
        .width = width,
        .height = gap + rows * row + (rows - 1) * gap + gap,
    };
    const top = panel.y + gap;
    const second = top + row + gap;

    var x = panel.x + gap;
    const expand = pen.Rectangle{ .x = x, .y = top, .width = toggle_width, .height = if (replacing) row * 2 + gap else row };
    x += toggle_width + gap;
    const find_field = pen.Rectangle{ .x = x, .y = top, .width = field_width, .height = row };
    const replace_field = pen.Rectangle{ .x = x, .y = second, .width = field_width, .height = row };
    x += field_width + gap;
    const match_case = pen.Rectangle{ .x = x, .y = top, .width = toggle_width, .height = row };
    x += toggle_width;
    const whole_word = pen.Rectangle{ .x = x, .y = top, .width = toggle_width, .height = row };
    x += toggle_width + gap;
    const count = pen.Rectangle{ .x = x, .y = top, .width = cell * count_columns, .height = row };
    x += cell * count_columns;
    const previous = pen.Rectangle{ .x = x, .y = top, .width = square, .height = row };
    x += square;
    const next = pen.Rectangle{ .x = x, .y = top, .width = square, .height = row };
    x += square;
    const close = pen.Rectangle{ .x = x, .y = top, .width = square, .height = row };

    const after_field = replace_field.x + replace_field.width + gap;
    const one_width = font.widthOf(replace_one_label) + pad * 2;
    const all_width = font.widthOf(replace_all_label) + pad * 2;
    return .{
        .panel = panel,
        .expand = expand,
        .find_field = find_field,
        .replace_field = replace_field,
        .match_case = match_case,
        .whole_word = whole_word,
        .count = count,
        .previous = previous,
        .next = next,
        .close = close,
        .replace_one = .{ .x = after_field, .y = second, .width = one_width, .height = row },
        .replace_all = .{ .x = after_field + one_width + gap, .y = second, .width = all_width, .height = row },
    };
}

pub fn controlAt(point: pen.Vector2, g: Geometry, replacing: bool) ?Control {
    inline for (@typeInfo(Control).@"enum".fields) |field_info| {
        const c: Control = @enumFromInt(field_info.value);
        const replace_only = c == .replace_field or c == .replace_one or c == .replace_all;
        if (!replace_only or replacing) {
            if (pen.checkCollisionPointRec(point, g.rect(c))) return c;
        }
    }
    return null;
}

/// Whole character columns that fit in a field.
pub fn fieldColumns(rect: pen.Rectangle, font: Font) usize {
    const room = rect.width - layout.padding * 2;
    if (room <= 0 or font.metrics.width <= 0) return 0;
    return @intFromFloat(@floor(room / font.metrics.width));
}

/// First column shown, so the caret stays in view in a field too narrow for
/// its text. Stateless, so drawing and clicking always agree.
pub fn fieldScroll(caret_column: usize, visible: usize) usize {
    if (visible == 0 or caret_column < visible) return 0;
    return caret_column - visible + 1;
}

pub fn inPanel(point: pen.Vector2, g: Geometry) bool {
    return pen.checkCollisionPointRec(point, g.panel);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

fn testLayout(width: f32) Layout {
    const zero = pen.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{
        .menu = .{ .x = 0, .y = 0, .width = width, .height = 32 },
        .tabs = zero,
        .gutter = zero,
        .text = .{ .x = 40, .y = 60, .width = width - 52, .height = 400 },
        .scrollbar = zero,
        .status = zero,
    };
}

const test_font = Font{ .metrics = .{ .width = 8, .height = 16 } };

fn inside(inner: pen.Rectangle, outer: pen.Rectangle) bool {
    return inner.x >= outer.x - 0.01 and inner.y >= outer.y - 0.01 and
        inner.x + inner.width <= outer.x + outer.width + 0.01 and
        inner.y + inner.height <= outer.y + outer.height + 0.01;
}

test "every control sits inside the panel, and the panel inside the text area" {
    for ([_]bool{ false, true }) |replacing| {
        const l = testLayout(1000);
        const g = geometry(l, test_font, replacing);
        try testing.expect(inside(g.panel, l.text));
        inline for (@typeInfo(Control).@"enum".fields) |f| {
            const c: Control = @enumFromInt(f.value);
            const replace_only = c == .replace_field or c == .replace_one or c == .replace_all;
            if (!replace_only or replacing) try testing.expect(inside(g.rect(c), g.panel));
        }
    }
}

test "the middle of each control picks that control" {
    const g = geometry(testLayout(1000), test_font, true);
    inline for (@typeInfo(Control).@"enum".fields) |f| {
        const c: Control = @enumFromInt(f.value);
        const r = g.rect(c);
        const middle = pen.Vector2{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
        try testing.expectEqual(c, controlAt(middle, g, true).?);
    }
}

test "the replace row can only be clicked while it shows" {
    const g = geometry(testLayout(1000), test_font, true);
    const r = g.replace_all;
    const middle = pen.Vector2{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
    try testing.expect(controlAt(middle, geometry(testLayout(1000), test_font, false), false) == null);
}

test "a narrow window narrows the fields instead of spilling out" {
    const wide = geometry(testLayout(1200), test_font, false);
    const narrow = geometry(testLayout(520), test_font, false);
    try testing.expect(narrow.find_field.width < wide.find_field.width);
    try testing.expect(narrow.find_field.width >= test_font.metrics.width * narrowest_field);
}

fn testView(b: *Buffer, content: []const u8) !*BufferView {
    const view = try b.newScratch();
    try view.insert(content);
    view.cursor.moveTo(&view.tree, 0, false);
    return view;
}

test "stepping selects matches in order and wraps" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try testView(&b, "one two one two one");
    var f = Find{ .gpa = testing.allocator };
    defer f.deinit();
    try f.query.set(testing.allocator, "one");

    try f.step(view, .forward);
    try testing.expectEqual(@as(u32, 3), view.cursor.offset);
    try f.step(view, .forward);
    try testing.expectEqual(@as(u32, 11), view.cursor.offset);
    try f.sync(view);
    try testing.expectEqual(@as(usize, 3), f.total);
    try testing.expectEqual(@as(?usize, 2), f.current(view));

    try f.step(view, .forward);
    try f.step(view, .forward);
    try testing.expectEqual(@as(u32, 3), view.cursor.offset);
    try f.step(view, .backward);
    try testing.expectEqual(@as(u32, 19), view.cursor.offset);
}

test "replace all is one edit and undoes in one step" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try testView(&b, "cat cat cat");
    var f = Find{ .gpa = testing.allocator };
    defer f.deinit();
    try f.query.set(testing.allocator, "cat");
    try f.replacement.set(testing.allocator, "dog");

    try testing.expectEqual(@as(usize, 3), try f.replaceAll(view));
    const after = try view.tree.allocText(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("dog dog dog", after);

    try view.undo();
    const undone = try view.tree.allocText(testing.allocator);
    defer testing.allocator.free(undone);
    try testing.expectEqualStrings("cat cat cat", undone);
}

test "replace one only replaces a selected match, then moves on" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try testView(&b, "a b a");
    var f = Find{ .gpa = testing.allocator };
    defer f.deinit();
    try f.query.set(testing.allocator, "a");
    try f.replacement.set(testing.allocator, "X");

    try f.replaceOne(view);
    try f.replaceOne(view);
    const out = try view.tree.allocText(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("X b a", out);
}

test "the snapshot follows edits to the document" {
    var b = Buffer{ .gpa = testing.allocator, .io = testing.io };
    defer Buffer.deinit(@ptrCast(&b)) catch {};
    const view = try testView(&b, "x");
    var f = Find{ .gpa = testing.allocator };
    defer f.deinit();
    try f.query.set(testing.allocator, "x");
    try f.sync(view);
    try testing.expectEqual(@as(usize, 1), f.total);

    view.cursor.moveTo(&view.tree, 1, false);
    try view.insert(" x x");
    try f.sync(view);
    try testing.expectEqual(@as(usize, 3), f.total);
}

test "a field scrolls only once the caret passes its right edge" {
    try testing.expectEqual(@as(usize, 0), fieldScroll(5, 10));
    try testing.expectEqual(@as(usize, 1), fieldScroll(10, 10));
    try testing.expectEqual(@as(usize, 11), fieldScroll(20, 10));
}
