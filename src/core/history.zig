//! Undo and redo.
//!
//! Every change is stored as what it took out and what it put in its place,
//! so undoing is the same edit applied backwards.
//!
//! Consecutive typing is merged into one entry, and so is a run of
//! backspaces. Without that, undo would step back one letter at a time, which
//! nobody wants.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Edit = struct {
    offset: u32,
    /// Text that was there before. Owned.
    removed: []const u8,
    /// Text that replaced it. Owned.
    inserted: []const u8,
    cursor_before: u32,
    cursor_after: u32,

    fn deinit(e: Edit, gpa: Allocator) void {
        gpa.free(e.removed);
        gpa.free(e.inserted);
    }

    fn isInsert(e: Edit) bool {
        return e.removed.len == 0 and e.inserted.len > 0;
    }

    fn isDelete(e: Edit) bool {
        return e.inserted.len == 0 and e.removed.len > 0;
    }
};

pub const History = struct {
    gpa: Allocator,
    edits: std.ArrayList(Edit) = .empty,
    /// How many entries are currently applied to the text. Entries past this
    /// point are the redo trail.
    applied: usize = 0,
    /// Oldest entries are dropped once there are more than this.
    limit: usize = 1000,

    const Self = @This();

    pub fn deinit(h: *Self) void {
        for (h.edits.items) |e| e.deinit(h.gpa);
        h.edits.deinit(h.gpa);
    }

    pub fn canUndo(h: Self) bool {
        return h.applied > 0;
    }

    pub fn canRedo(h: Self) bool {
        return h.applied < h.edits.items.len;
    }

    /// Records a change that has already been made to the text.
    pub fn record(
        h: *Self,
        offset: u32,
        removed: []const u8,
        inserted: []const u8,
        cursor_before: u32,
        cursor_after: u32,
    ) !void {
        h.dropRedoTrail();

        const edit = Edit{
            .offset = offset,
            .removed = try h.gpa.dupe(u8, removed),
            .inserted = try h.gpa.dupe(u8, inserted),
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        };
        errdefer edit.deinit(h.gpa);

        if (try h.merge(edit)) return;

        try h.edits.append(h.gpa, edit);
        h.applied = h.edits.items.len;
        try h.trim();
    }

    /// Returns the edit to reverse, or null. The caller applies it backwards:
    /// replace `inserted` at `offset` with `removed`.
    pub fn undo(h: *Self) ?Edit {
        if (!h.canUndo()) return null;
        h.applied -= 1;
        return h.edits.items[h.applied];
    }

    /// Returns the edit to reapply, or null.
    pub fn redo(h: *Self) ?Edit {
        if (!h.canRedo()) return null;
        const edit = h.edits.items[h.applied];
        h.applied += 1;
        return edit;
    }

    /// Anything undone is thrown away as soon as a fresh edit arrives.
    fn dropRedoTrail(h: *Self) void {
        while (h.edits.items.len > h.applied) {
            const dropped = h.edits.pop().?;
            dropped.deinit(h.gpa);
        }
    }

    /// Folds `edit` into the previous one when they are part of the same
    /// gesture. Returns true if it was absorbed.
    fn merge(h: *Self, edit: Edit) !bool {
        if (h.applied == 0 or h.applied != h.edits.items.len) return false;
        const last = &h.edits.items[h.applied - 1];

        // Typing straight on from where the last text was inserted.
        if (last.isInsert() and edit.isInsert() and
            edit.offset == last.offset + last.inserted.len and
            edit.inserted.len <= 4 and
            !endsLine(last.inserted) and !endsLine(edit.inserted))
        {
            const joined = try std.mem.concat(h.gpa, u8, &.{ last.inserted, edit.inserted });
            h.gpa.free(last.inserted);
            last.inserted = joined;
            last.cursor_after = edit.cursor_after;
            edit.deinit(h.gpa);
            return true;
        }

        // Backspacing straight back from where the last delete ended.
        if (last.isDelete() and edit.isDelete() and
            edit.offset + edit.removed.len == last.offset and
            edit.removed.len <= 4)
        {
            const joined = try std.mem.concat(h.gpa, u8, &.{ edit.removed, last.removed });
            h.gpa.free(last.removed);
            last.removed = joined;
            last.offset = edit.offset;
            last.cursor_after = edit.cursor_after;
            edit.deinit(h.gpa);
            return true;
        }

        return false;
    }

    fn trim(h: *Self) !void {
        if (h.edits.items.len <= h.limit) return;
        const excess = h.edits.items.len - h.limit;
        for (h.edits.items[0..excess]) |e| e.deinit(h.gpa);
        std.mem.copyForwards(Edit, h.edits.items, h.edits.items[excess..]);
        h.edits.shrinkRetainingCapacity(h.edits.items.len - excess);
        h.applied -= @min(h.applied, excess);
    }
};

fn endsLine(text: []const u8) bool {
    return text.len > 0 and text[text.len - 1] == '\n';
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "nothing to undo at the start" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();
    try testing.expect(!h.canUndo());
    try testing.expect(!h.canRedo());
    try testing.expectEqual(@as(?Edit, null), h.undo());
}

test "undo then redo walks back and forth" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();

    try h.record(0, "", "a", 0, 1);
    try h.record(5, "", "b", 5, 6); // not adjacent, stays separate
    try testing.expectEqual(@as(usize, 2), h.edits.items.len);

    try testing.expectEqual(@as(u32, 5), h.undo().?.offset);
    try testing.expectEqual(@as(u32, 0), h.undo().?.offset);
    try testing.expect(!h.canUndo());

    try testing.expectEqual(@as(u32, 0), h.redo().?.offset);
    try testing.expectEqual(@as(u32, 5), h.redo().?.offset);
    try testing.expect(!h.canRedo());
}

test "consecutive typing merges into one entry" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();

    try h.record(0, "", "h", 0, 1);
    try h.record(1, "", "i", 1, 2);
    try h.record(2, "", "!", 2, 3);

    try testing.expectEqual(@as(usize, 1), h.edits.items.len);
    try testing.expectEqualSlices(u8, "hi!", h.edits.items[0].inserted);
    try testing.expectEqual(@as(u32, 3), h.edits.items[0].cursor_after);
}

test "a newline ends the run" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();

    try h.record(0, "", "a", 0, 1);
    try h.record(1, "", "\n", 1, 2);
    try h.record(2, "", "b", 2, 3);

    try testing.expectEqual(@as(usize, 3), h.edits.items.len);
}

test "backspaces merge" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();

    try h.record(4, "d", "", 5, 4);
    try h.record(3, "c", "", 4, 3);
    try h.record(2, "b", "", 3, 2);

    try testing.expectEqual(@as(usize, 1), h.edits.items.len);
    try testing.expectEqualSlices(u8, "bcd", h.edits.items[0].removed);
    try testing.expectEqual(@as(u32, 2), h.edits.items[0].offset);
}

test "a new edit throws away the redo trail" {
    var h = History{ .gpa = testing.allocator };
    defer h.deinit();

    try h.record(0, "", "a", 0, 1);
    try h.record(9, "", "b", 9, 10);
    _ = h.undo();
    try testing.expect(h.canRedo());

    try h.record(20, "", "c", 20, 21);
    try testing.expect(!h.canRedo());
    try testing.expectEqual(@as(usize, 2), h.edits.items.len);
}

test "the oldest entries are dropped at the limit" {
    var h = History{ .gpa = testing.allocator, .limit = 3 };
    defer h.deinit();

    // Spaced out so nothing merges.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        try h.record(i * 10, "", "x", i * 10, i * 10 + 1);
    }
    try testing.expectEqual(@as(usize, 3), h.edits.items.len);
    try testing.expectEqual(@as(u32, 30), h.edits.items[0].offset);
    try testing.expectEqual(@as(usize, 3), h.applied);
}
