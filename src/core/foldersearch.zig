//! Searching every file of the folder for some text, on a thread of its own
//! so typing the query never waits on the disk. A new query drops the one
//! before it, which stops at the next file it reaches.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const search = @import("search.zig");
const Reader = @import("workspace.zig").Reader;

/// Enough to be useful; past it the query wants narrowing.
pub const max_hits = 1000;
/// Larger files are skipped: they are logs and data, not source.
const max_file_bytes = 4 * 1024 * 1024;
/// How much of a line a hit shows.
const max_shown_line = 200;

pub const Hit = struct {
    /// Relative to the root.
    path: []const u8,
    /// From 0.
    line: u32,
    /// Bytes into the line. A line and column rather than an offset, since
    /// the tab may hold the file with other line breaks than the disk.
    column: u32,
};

/// Text to search instead of what is on disk, for a tab with unsaved changes.
pub const Unsaved = struct { path: []const u8, text: []const u8 };

/// One search's hits, all allocated in its arena.
const Results = struct {
    arena: std.heap.ArenaAllocator,
    hits: []Hit = &.{},
    /// What the list shows for each hit: `path:line: text`.
    labels: []const []const u8 = &.{},
    /// Stopped at `max_hits`.
    cut_short: bool = false,
    generation: u32,
};

/// What a search thread is given, all copied, since the folder's listing and
/// the tabs may change while it runs.
const Job = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    files: []const []const u8,
    unsaved: []const Unsaved,
    query: []const u8,
    options: search.Options,
    generation: u32,
};

pub const FolderSearch = struct {
    gpa: Allocator,
    results: ?*Results = null,
    pending: std.atomic.Value(?*Results) = .init(null),
    /// The query last searched for, to come back to. Owned.
    query: std.ArrayList(u8) = .empty,
    /// Bumped by every new query and by `stop`, so older searches give up.
    generation: std.atomic.Value(u32) = .init(0),
    /// A search is running for the current query.
    running: std.atomic.Value(bool) = .init(false),
    /// Called from the search thread when it is done, to wake the editor.
    on_found: ?*const fn () void = null,

    const Self = @This();

    pub fn deinit(s: *Self) void {
        s.stop();
        if (s.pending.swap(null, .acq_rel)) |r| free(s.gpa, r);
        s.query.deinit(s.gpa);
    }

    /// Starts searching `files` under `root` for `query`, dropping any
    /// search before.
    pub fn start(s: *Self, io: std.Io, root: []const u8, files: []const []const u8, unsaved: []const Unsaved, query: []const u8, options: search.Options) !void {
        // The web build has no threads, and no folders to search either.
        if (builtin.single_threaded) return;
        const generation = s.generation.fetchAdd(1, .acq_rel) + 1;
        s.dropResults();
        s.query.clearRetainingCapacity();
        try s.query.appendSlice(s.gpa, query);
        if (query.len == 0) {
            s.running.store(false, .release);
            return;
        }

        const job = try s.gpa.create(Job);
        errdefer s.gpa.destroy(job);
        job.* = .{ .arena = .init(s.gpa), .root = &.{}, .files = &.{}, .unsaved = &.{}, .query = &.{}, .options = options, .generation = generation };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.root = try a.dupe(u8, root);
        job.query = try a.dupe(u8, query);
        const copied = try a.alloc([]const u8, files.len);
        for (files, copied) |f, *c| c.* = try a.dupe(u8, f);
        job.files = copied;
        const texts = try a.alloc(Unsaved, unsaved.len);
        for (unsaved, texts) |u, *t| t.* = .{ .path = try a.dupe(u8, u.path), .text = try a.dupe(u8, u.text) };
        job.unsaved = texts;

        s.running.store(true, .release);
        const thread = try std.Thread.spawn(.{}, runJob, .{ s, io, job });
        thread.detach();
    }

    /// Drops the current query and its hits.
    pub fn stop(s: *Self) void {
        _ = s.generation.fetchAdd(1, .acq_rel);
        s.running.store(false, .release);
        s.dropResults();
    }

    /// Takes over a finished search of the current query. Called from the
    /// main loop; true when the hits changed, which frees the ones before.
    pub fn poll(s: *Self) bool {
        const done = s.pending.swap(null, .acq_rel) orelse return false;
        if (done.generation != s.generation.load(.acquire)) {
            free(s.gpa, done);
            return false;
        }
        s.dropResults();
        s.results = done;
        s.running.store(false, .release);
        return true;
    }

    pub fn hits(s: *const Self) []const Hit {
        return if (s.results) |r| r.hits else &.{};
    }

    pub fn labels(s: *const Self) []const []const u8 {
        return if (s.results) |r| r.labels else &.{};
    }

    pub fn cutShort(s: *const Self) bool {
        return if (s.results) |r| r.cut_short else false;
    }

    fn dropResults(s: *Self) void {
        if (s.results) |r| free(s.gpa, r);
        s.results = null;
    }

    fn runJob(s: *Self, io: std.Io, job: *Job) void {
        defer {
            job.arena.deinit();
            s.gpa.destroy(job);
        }
        const results = collect(s, io, job) catch return;
        if (job.generation != s.generation.load(.acquire)) return free(s.gpa, results);
        if (s.pending.swap(results, .acq_rel)) |older| free(s.gpa, older);
        if (s.on_found) |wake| wake();
    }
};

fn free(gpa: Allocator, results: *Results) void {
    results.arena.deinit();
    gpa.destroy(results);
}

fn collect(s: *const FolderSearch, io: std.Io, job: *const Job) !*Results {
    const results = try s.gpa.create(Results);
    results.* = .{ .arena = .init(s.gpa), .generation = job.generation };
    errdefer free(s.gpa, results);
    const a = results.arena.allocator();

    var found: std.ArrayList(Hit) = .empty;
    var labels: std.ArrayList([]const u8) = .empty;
    var reader = Reader{ .gpa = s.gpa, .io = io, .root = job.root, .limit = max_file_bytes };
    defer reader.deinit();

    for (job.files) |path| {
        // A newer query has taken over.
        if (job.generation != s.generation.load(.acquire)) break;
        const text = unsavedText(job, path) orelse (reader.text(path) orelse continue);
        var line: u32 = 0;
        var line_start: usize = 0;
        var counted: usize = 0;
        var at: usize = 0;
        while (search.next(text, job.query, at, job.options)) |m| : (at = m.end) {
            // Lines are counted only as far as each match, once.
            for (text[counted..m.start], counted..) |c, i| if (c == '\n') {
                line += 1;
                line_start = i + 1;
            };
            counted = m.start;
            const line_end = std.mem.findScalarPos(u8, text, m.start, '\n') orelse text.len;
            const shown = std.mem.trim(u8, text[line_start..@min(line_end, line_start + max_shown_line)], " \t\r");
            try found.append(a, .{ .path = path, .line = line, .column = @intCast(m.start - line_start) });
            try labels.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, line + 1, shown }));
            if (found.items.len >= max_hits) {
                results.cut_short = true;
                break;
            }
        }
        if (results.cut_short) break;
    }
    // The paths now live in the results, not the job, which goes away.
    for (found.items) |*hit| hit.path = try a.dupe(u8, hit.path);
    results.hits = found.items;
    results.labels = labels.items;
    return results;
}

fn unsavedText(job: *const Job, path: []const u8) ?[]const u8 {
    for (job.unsaved) |u| if (std.mem.eql(u8, u.path, path)) return u.text;
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn waitFor(s: *FolderSearch) !void {
    var tries: usize = 0;
    while (!s.poll() and tries < 1000) : (tries += 1) try testing.io.sleep(.fromMilliseconds(2), .awake);
}

test "every match in every file is found, with its line, and binaries are skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one needle\ntwo\n  needle three needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.zig", .data = "nothing here\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.bin", .data = "needle\x00\x01" });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    var s = FolderSearch{ .gpa = testing.allocator };
    defer s.deinit();
    try s.start(io, root, &.{ "a.txt", "c.bin", "src/b.zig" }, &.{}, "needle", .{});
    try waitFor(&s);

    try testing.expectEqual(@as(usize, 3), s.hits().len);
    try testing.expectEqualStrings("a.txt:1: one needle", s.labels()[0]);
    try testing.expectEqualStrings("a.txt:3: needle three needle", s.labels()[1]);
    try testing.expectEqual(@as(u32, 2), s.hits()[2].line);
    const line = "  needle three needle";
    try testing.expectEqual(@as(u32, @intCast(std.mem.findLast(u8, line, "needle").?)), s.hits()[2].column);
}

test "a tab's unsaved text is searched instead of the file on disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "old words\n" });
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var s = FolderSearch{ .gpa = testing.allocator };
    defer s.deinit();
    try s.start(testing.io, root, &.{"a.txt"}, &.{.{ .path = "a.txt", .text = "new words\nnew\n" }}, "new", .{});
    try waitFor(&s);
    try testing.expectEqual(@as(usize, 2), s.hits().len);
}

test "an empty query stops the search and clears the hits" {
    var s = FolderSearch{ .gpa = testing.allocator };
    defer s.deinit();
    try s.start(testing.io, "/nowhere", &.{}, &.{}, "", .{});
    try testing.expect(!s.running.load(.acquire));
    try testing.expectEqual(@as(usize, 0), s.hits().len);
}
