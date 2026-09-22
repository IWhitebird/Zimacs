//! The one-line prompt along the bottom, used to type a file path.
//!
//! raylib has no native file dialog, so opening and saving-as ask here
//! instead - the same idea as an Emacs minibuffer.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { open, save_as, find, browse, save_into, goto_line };

/// Case-insensitive substring test, for narrowing the suggestion list.
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const Prompt = struct {
    gpa: Allocator = undefined,
    active: bool = false,
    kind: Kind = .open,
    input: std.ArrayList(u8) = .empty,
    /// Suggestions the up and down keys step through, such as recent files.
    options: []const []const u8 = &.{},
    /// Indices into `options` that match what has been typed so far.
    matches: std.ArrayList(usize) = .empty,
    /// Which match is highlighted.
    option: usize = 0,

    const Self = @This();

    pub fn deinit(p: *Self) void {
        p.input.deinit(p.gpa);
        p.matches.deinit(p.gpa);
    }

    pub fn begin(p: *Self, kind: Kind, initial: []const u8) !void {
        p.active = true;
        p.kind = kind;
        p.options = &.{};
        p.option = 0;
        p.matches.clearRetainingCapacity();
        p.input.clearRetainingCapacity();
        try p.input.appendSlice(p.gpa, initial);
    }

    /// Opens the prompt on a list of suggestions, all of them showing.
    pub fn beginWith(p: *Self, kind: Kind, options: []const []const u8) !void {
        try p.begin(kind, "");
        p.options = options;
        try p.refilter();
    }

    /// Narrows the list to whatever contains the typed text, case-insensitively.
    pub fn refilter(p: *Self) !void {
        p.matches.clearRetainingCapacity();
        for (p.options, 0..) |option, i| {
            if (contains(option, p.input.items)) try p.matches.append(p.gpa, i);
        }
        p.option = 0;
    }

    /// Moves the highlight, wrapping at both ends.
    pub fn cycle(p: *Self, delta: i32) void {
        if (p.matches.items.len == 0) return;
        const count: i32 = @intCast(p.matches.items.len);
        p.option = @intCast(@mod(@as(i32, @intCast(p.option)) + delta, count));
    }

    /// The suggestion currently highlighted, if the list has any.
    pub fn choice(p: Self) ?[]const u8 {
        if (p.option >= p.matches.items.len) return null;
        return p.options[p.matches.items[p.option]];
    }

    /// What picking right now would use: the highlighted suggestion, or the
    /// typed text when nothing matches.
    ///
    /// The result borrows the prompt's own storage, so it stops being valid
    /// the moment the prompt is closed or typed into. Use `takeResult` unless
    /// you are finished with it before then.
    pub fn result(p: Self) []const u8 {
        return p.choice() orelse p.input.items;
    }

    /// `result`, copied so it outlives the prompt. Caller frees.
    pub fn takeResult(p: Self, gpa: Allocator) ![]u8 {
        return gpa.dupe(u8, p.result());
    }

    pub fn cancel(p: *Self) void {
        p.active = false;
        p.options = &.{};
        p.matches.clearRetainingCapacity();
        p.input.clearRetainingCapacity();
    }

    pub fn label(p: Self) []const u8 {
        return switch (p.kind) {
            .open => "Open: ",
            .save_as => "Save as: ",
            .find => "Find: ",
            .goto_line => "Go to line: ",
            // The browsers show the directory they are in instead.
            .browse, .save_into => "",
        };
    }

    pub fn append(p: *Self, bytes: []const u8) !void {
        try p.input.appendSlice(p.gpa, bytes);
        if (p.options.len > 0) try p.refilter();
    }

    pub fn backspace(p: *Self) void {
        defer if (p.options.len > 0) {
            p.refilter() catch {};
        };
        if (p.input.items.len == 0) return;
        var n: usize = 1;
        while (n < p.input.items.len and
            p.input.items[p.input.items.len - n] & 0b1100_0000 == 0b1000_0000) : (n += 1)
        {}
        p.input.shrinkRetainingCapacity(p.input.items.len - n);
    }

    pub fn text(p: Self) []const u8 {
        return p.input.items;
    }
};

test "the highlight moves through the suggestions and wraps" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    const options = [_][]const u8{ "/one", "/two", "/three" };
    try p.beginWith(.open, &options);
    try std.testing.expectEqualSlices(u8, "/one", p.choice().?);

    p.cycle(1);
    try std.testing.expectEqualSlices(u8, "/two", p.choice().?);
    p.cycle(-1);
    try std.testing.expectEqualSlices(u8, "/one", p.choice().?);
    p.cycle(-1);
    try std.testing.expectEqualSlices(u8, "/three", p.choice().?);
}

test "typing narrows the list" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    const options = [_][]const u8{ "/home/notes.txt", "/home/main.zig", "/tmp/other.zig" };
    try p.beginWith(.open, &options);
    try std.testing.expectEqual(@as(usize, 3), p.matches.items.len);

    try p.append("zig");
    try std.testing.expectEqual(@as(usize, 2), p.matches.items.len);
    try std.testing.expectEqualSlices(u8, "/home/main.zig", p.choice().?);

    try p.append("!!");
    try std.testing.expectEqual(@as(usize, 0), p.matches.items.len);
    // With nothing matching, the typed text is what gets used.
    try std.testing.expectEqualSlices(u8, "zig!!", p.result());
}

test "filtering ignores case" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    const options = [_][]const u8{"/home/README.md"};
    try p.beginWith(.open, &options);
    try p.append("readme");
    try std.testing.expectEqual(@as(usize, 1), p.matches.items.len);
}

test "a taken result outlives the prompt being closed" {
    const gpa = std.testing.allocator;
    var p = Prompt{ .gpa = gpa };
    defer p.deinit();

    try p.begin(.save_as, "notes.txt");
    const taken = try p.takeResult(gpa);
    defer gpa.free(taken);

    p.cancel();
    try std.testing.expectEqualSlices(u8, "notes.txt", taken);
}

test "with no suggestions the typed text is the result" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();
    try p.begin(.open, "abc");
    p.cycle(1);
    try std.testing.expectEqualSlices(u8, "abc", p.result());
}

test "typing and backspacing" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    try p.begin(.open, "/tmp/");
    try p.append("ab");
    try std.testing.expectEqualSlices(u8, "/tmp/ab", p.text());

    p.backspace();
    try std.testing.expectEqualSlices(u8, "/tmp/a", p.text());

    p.cancel();
    try std.testing.expect(!p.active);
}

test "backspace removes a whole multi-byte character" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    try p.begin(.save_as, "");
    try p.append("e\u{00e9}");
    try std.testing.expectEqual(@as(usize, 3), p.text().len);

    p.backspace();
    try std.testing.expectEqualSlices(u8, "e", p.text());
}
