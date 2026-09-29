//! The one-line prompt, for typing a path, a line number, or a name in the
//! built-in file browser, which stands in when the system has no file
//! dialog - the same idea as an Emacs minibuffer.

const std = @import("std");
const text_mod = @import("text.zig");
const fuzzy = @import("fuzzy.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { open, recent, open_folder, quick_open, search_folder, save_as, browse, save_into, goto_line };

/// Case-insensitive substring test, for narrowing the suggestion list.
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

const Ranked = struct {
    index: usize,
    score: i32,

    /// Higher scores first; the sort is stable, so ties keep path order.
    fn better(_: void, a: Ranked, b: Ranked) bool {
        return a.score > b.score;
    }
};

pub const Prompt = struct {
    gpa: Allocator = undefined,
    active: bool = false,
    kind: Kind = .open,
    input: std.ArrayList(u8) = .empty,
    /// Suggestions the up and down keys step through, such as recent files.
    options: []const []const u8 = &.{},
    /// Indices into `options` that match what has been typed so far.
    matches: std.ArrayList(usize) = .empty,
    /// Quick open's matches with their scores, while they are sorted.
    ranked: std.ArrayList(Ranked) = .empty,
    /// Which match is highlighted, counting through all of them.
    option: usize = 0,
    /// The first match in view; the list scrolls past `max_shown`.
    first: usize = 0,
    /// The highlight was moved there with the arrows or the mouse, rather
    /// than resting on the first match.
    picked: bool = false,

    /// How many matches the list shows at once.
    pub const max_shown: usize = 8;

    const Self = @This();

    pub fn deinit(p: *Self) void {
        p.input.deinit(p.gpa);
        p.matches.deinit(p.gpa);
        p.ranked.deinit(p.gpa);
    }

    pub fn begin(p: *Self, kind: Kind, initial: []const u8) !void {
        p.active = true;
        p.kind = kind;
        p.options = &.{};
        p.option = 0;
        p.picked = false;
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

    /// Swaps in a newer list of suggestions, keeping what has been typed.
    pub fn replaceOptions(p: *Self, options: []const []const u8) !void {
        p.options = options;
        try p.refilter();
    }

    /// Narrows the list to whatever contains the typed text, case-insensitively;
    /// quick open ranks its files instead.
    fn refilter(p: *Self) !void {
        p.matches.clearRetainingCapacity();
        switch (p.kind) {
            .quick_open => try p.rank(),
            // The typed text is what was searched for, not a filter.
            .search_folder => for (0..p.options.len) |i| try p.matches.append(p.gpa, i),
            else => for (p.options, 0..) |option, i| {
                if (contains(option, p.input.items)) try p.matches.append(p.gpa, i);
            },
        }
        p.option = 0;
        p.first = 0;
        p.picked = false;
    }

    /// The best matches first, for picking a file by a few of its letters.
    fn rank(p: *Self) !void {
        p.ranked.clearRetainingCapacity();
        for (p.options, 0..) |option, i| {
            if (fuzzy.score(option, p.input.items)) |s| try p.ranked.append(p.gpa, .{ .index = i, .score = s });
        }
        std.mem.sort(Ranked, p.ranked.items, {}, Ranked.better);
        for (p.ranked.items) |r| try p.matches.append(p.gpa, r.index);
    }

    /// How many matches the list is showing.
    pub fn shown(p: Self) usize {
        return @min(p.matches.items.len -| p.first, max_shown);
    }

    /// The matches in view, as indices into `options`.
    pub fn visible(p: *const Self) []const usize {
        return p.matches.items[p.first..][0..p.shown()];
    }

    /// Moves the highlight through the matches, wrapping at both ends and
    /// scrolling to keep it in view.
    pub fn cycle(p: *Self, delta: i32) void {
        const count = p.matches.items.len;
        if (count == 0) return;
        p.option = @intCast(@mod(@as(i64, @intCast(p.option)) + delta, @as(i64, @intCast(count))));
        p.picked = true;
        if (p.option < p.first) p.first = p.option;
        if (p.option >= p.first + max_shown) p.first = p.option + 1 - max_shown;
    }

    /// Scrolls the list by `delta` rows without moving the highlight.
    pub fn scrollBy(p: *Self, delta: i32) void {
        const last = p.matches.items.len -| max_shown;
        p.first = @intCast(std.math.clamp(@as(i64, @intCast(p.first)) + delta, 0, @as(i64, @intCast(last))));
    }

    /// Highlights a row in view, as a click does.
    pub fn pick(p: *Self, row: usize) void {
        if (row >= p.shown()) return;
        p.option = p.first + row;
        p.picked = true;
    }

    /// Which match is highlighted. Saving highlights nothing until a row is
    /// picked, because a match only contains the typed name: taking it would
    /// save over a different file.
    pub fn highlighted(p: Self) ?usize {
        if (p.option >= p.matches.items.len) return null;
        if (p.kind == .save_into and !p.picked) return null;
        return p.option;
    }

    /// The highlighted suggestion's place in `options`.
    pub fn chosenOption(p: Self) ?usize {
        return p.matches.items[p.highlighted() orelse return null];
    }

    /// The suggestion currently highlighted, if any.
    fn choice(p: Self) ?[]const u8 {
        return p.options[p.chosenOption() orelse return null];
    }

    /// What picking right now would use: the highlighted suggestion, or the
    /// typed text when nothing is highlighted.
    ///
    /// The result borrows the prompt's own storage, so it stops being valid
    /// the moment the prompt is closed or typed into. Use `takeResult` unless
    /// you are finished with it before then.
    fn result(p: Self) []const u8 {
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
            .recent => "Open recent: ",
            .open_folder => "Open folder: ",
            .quick_open => "Go to file: ",
            .search_folder => "Search folder: ",
            .save_as => "Save as: ",
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
            text_mod.isTrailing(p.input.items[p.input.items.len - n])) : (n += 1)
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

test "saving takes the typed name, not a file that merely contains it" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    const options = [_][]const u8{ "changelog.txt", "notes.txt" };
    try p.beginWith(.save_into, &options);
    try p.append("log.txt");
    try std.testing.expectEqual(@as(usize, 1), p.matches.items.len);
    try std.testing.expectEqualSlices(u8, "log.txt", p.result());

    p.cycle(1);
    try std.testing.expectEqualSlices(u8, "changelog.txt", p.result());
}

test "the highlight wraps through every match, and the list scrolls to show it" {
    var p = Prompt{ .gpa = std.testing.allocator };
    defer p.deinit();

    var options: [Prompt.max_shown + 4][]const u8 = undefined;
    for (&options) |*o| o.* = "same";
    try p.beginWith(.open, &options);
    p.cycle(-1);
    try std.testing.expectEqual(@as(?usize, options.len - 1), p.highlighted());
    try std.testing.expectEqual(@as(usize, options.len - Prompt.max_shown), p.first);
    p.cycle(1);
    try std.testing.expectEqual(@as(?usize, 0), p.highlighted());
    try std.testing.expectEqual(@as(usize, 0), p.first);

    p.scrollBy(100);
    try std.testing.expectEqual(@as(usize, options.len - Prompt.max_shown), p.first);
    p.pick(1);
    try std.testing.expectEqual(@as(?usize, options.len - Prompt.max_shown + 1), p.highlighted());
}
