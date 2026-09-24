//! Restores the editor as it was left: tabs with unsaved text, cursors,
//! selections, scroll, zoom and window placement.
//!
//! Stored as an `index` file plus one text file per unsaved buffer. Files
//! are written to a temporary name and renamed, so an interrupted save
//! leaves the previous session intact.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const BufferView = buffer_mod.BufferView;
const Format = buffer_mod.Format;
const Stamp = buffer_mod.Stamp;
const textfile = @import("textfile.zig");

pub const dir_name = "session";

const index_name = "index";
const header_v1 = "zimacs-session 1";
const header_v2 = "zimacs-session 2";
const header = "zimacs-session 3";
const max_index_bytes = 4 * 1024 * 1024;

/// Window position and size in window-system units. The rectangle is the
/// un-maximised one.
pub const Placement = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    maximized: bool = false,
};

pub const Extras = struct {
    /// Offset from the configured font size.
    zoom: f32 = 0,
    window: ?Placement = null,
};

/// Saves periodically, and only when the session has changed.
pub const Autosave = struct {
    interval: f64 = 10,
    last_check: f64 = 0,
    last_saved: u64 = 0,

    pub fn due(a: *Autosave, now: f64, b: *const Buffer, extras: Extras) bool {
        if (now - a.last_check < a.interval) return false;
        a.last_check = now;
        return signature(b, extras) != a.last_saved;
    }

    pub fn markSaved(a: *Autosave, b: *const Buffer, extras: Extras) void {
        a.last_saved = signature(b, extras);
    }
};

pub fn save(b: *Buffer, extras: Extras, io: std.Io, gpa: Allocator, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var open = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer open.close(io);

    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(gpa);

    try index.appendSlice(gpa, header);
    try index.append(gpa, '\n');
    try appendLine(&index, gpa, "active\t{d}", .{b.active});
    try appendLine(&index, gpa, "zoom\t{d}", .{extras.zoom});
    if (extras.window) |w| {
        try appendLine(&index, gpa, "window\t{d}\t{d}\t{d}\t{d}\t{d}", .{
            w.x, w.y, w.width, w.height, @intFromBool(w.maximized),
        });
    }

    for (b.views.items, 0..) |view, i| {
        const keep_text = view.edited() or view.path == null;
        var anchor_buf: [16]u8 = undefined;
        const anchor = if (view.cursor.anchor) |a|
            std.fmt.bufPrint(&anchor_buf, "{d}", .{a}) catch "-"
        else
            "-";
        var size_buf: [24]u8 = undefined;
        var mtime_buf: [40]u8 = undefined;
        const size = if (view.disk) |d| std.fmt.bufPrint(&size_buf, "{d}", .{d.size}) catch "-" else "-";
        const mtime = if (view.disk) |d| std.fmt.bufPrint(&mtime_buf, "{d}", .{d.mtime}) catch "-" else "-";
        // Path last: it is the only field that may contain a tab.
        try appendLine(&index, gpa, "buffer\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}", .{
            i,
            view.cursor.offset,
            view.top_line,
            @intFromBool(keep_text),
            view.left_column,
            anchor,
            @tagName(view.format.encoding),
            @tagName(view.format.line_ending),
            size,
            mtime,
            view.name,
            view.path orelse "",
        });

        if (!keep_text) continue;
        const text = try view.tree.allocText(gpa);
        defer gpa.free(text);

        var name_buf: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&name_buf, "{d}.txt", .{i});
        try writeAtomic(open, io, file, text);
    }

    try writeAtomic(open, io, index_name, index.items);
}

/// Returns false when there is nothing to restore.
pub fn restore(b: *Buffer, io: std.Io, gpa: Allocator, dir: []const u8) !bool {
    var open = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer open.close(io);

    const index = open.readFileAlloc(io, index_name, gpa, .limited(max_index_bytes)) catch return false;
    defer gpa.free(index);

    var lines = std.mem.splitScalar(u8, index, '\n');
    const version = versionOf(lines.next() orelse return false) orelse return false;

    var active: usize = 0;
    var restored: usize = 0;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, '\t');
        const kind = parts.next() orelse continue;

        if (std.mem.eql(u8, kind, "active")) {
            active = std.fmt.parseInt(usize, parts.next() orelse "0", 10) catch 0;
            continue;
        }
        if (!std.mem.eql(u8, kind, "buffer")) continue;

        const entry = parseBuffer(&parts, version) orelse continue;
        if (loadOne(b, io, gpa, open, entry)) {
            restored += 1;
        } else |_| {}
    }

    if (restored == 0) return false;
    b.active = @min(active, b.views.items.len - 1);
    return true;
}

/// Read before the window opens, so it opens at the saved size.
pub fn readExtras(io: std.Io, gpa: Allocator, dir: []const u8) Extras {
    var open = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return .{};
    defer open.close(io);
    const index = open.readFileAlloc(io, index_name, gpa, .limited(max_index_bytes)) catch return .{};
    defer gpa.free(index);
    return parseExtras(index);
}

/// Cheap summary of everything `save` writes.
pub fn signature(b: *const Buffer, extras: Extras) u64 {
    var h = std.hash.Wyhash.init(0);
    hashValue(&h, b.active);
    hashValue(&h, b.views.items.len);
    hashValue(&h, @as(u32, @bitCast(extras.zoom)));
    if (extras.window) |w| hashValue(&h, w);
    for (b.views.items) |view| {
        hashValue(&h, view.version);
        hashValue(&h, view.cursor.offset);
        hashValue(&h, view.cursor.anchor orelse std.math.maxInt(u32));
        hashValue(&h, view.top_line);
        hashValue(&h, view.left_column);
        hashValue(&h, view.saved orelse std.math.maxInt(u64));
        hashValue(&h, view.history.position());
        h.update(view.name);
        h.update(view.path orelse "");
    }
    return h.final();
}

// ------------------------------------------------------------ the parts

fn versionOf(first_line: []const u8) ?u8 {
    const line = std.mem.trim(u8, first_line, "\r");
    if (std.mem.eql(u8, line, header)) return 3;
    if (std.mem.eql(u8, line, header_v2)) return 2;
    if (std.mem.eql(u8, line, header_v1)) return 1;
    return null;
}

fn parseExtras(index: []const u8) Extras {
    var out = Extras{};
    var lines = std.mem.splitScalar(u8, index, '\n');
    _ = versionOf(lines.next() orelse return out) orelse return out;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        var parts = std.mem.splitScalar(u8, line, '\t');
        const kind = parts.next() orelse continue;

        if (std.mem.eql(u8, kind, "zoom")) {
            const zoom = std.fmt.parseFloat(f32, parts.next() orelse continue) catch continue;
            if (std.math.isFinite(zoom)) out.zoom = zoom;
        } else if (std.mem.eql(u8, kind, "window")) {
            out.window = parsePlacement(&parts);
        }
    }
    return out;
}

fn parsePlacement(parts: *std.mem.SplitIterator(u8, .scalar)) ?Placement {
    const x = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    const width = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    const height = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
    const maximized = std.mem.eql(u8, parts.next() orelse "0", "1");
    if (width <= 0 or height <= 0) return null;
    return .{ .x = x, .y = y, .width = width, .height = height, .maximized = maximized };
}

const Entry = struct {
    index: usize,
    cursor: u32,
    top_line: u32,
    has_text: bool,
    left_column: u32 = 0,
    anchor: ?u32 = null,
    format: Format = .{},
    disk: ?Stamp = null,
    name: []const u8,
    path: []const u8,
};

/// Version 1 has no scroll or selection fields; version 2 no format or stamp.
fn parseBuffer(parts: *std.mem.SplitIterator(u8, .scalar), version: u8) ?Entry {
    const index = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const cursor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const top = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const has_text = !std.mem.eql(u8, parts.next() orelse return null, "0");

    var left: u32 = 0;
    var anchor: ?u32 = null;
    if (version >= 2) {
        left = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch 0;
        const raw_anchor = parts.next() orelse return null;
        anchor = std.fmt.parseInt(u32, raw_anchor, 10) catch null;
    }

    var format = Format{};
    var disk: ?Stamp = null;
    if (version >= 3) {
        format.encoding = std.meta.stringToEnum(textfile.Encoding, parts.next() orelse return null) orelse .utf8;
        format.line_ending = std.meta.stringToEnum(textfile.LineEnding, parts.next() orelse return null) orelse .lf;
        const size = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch null;
        const mtime = std.fmt.parseInt(i96, parts.next() orelse return null, 10) catch null;
        if (size != null and mtime != null) disk = .{ .size = size.?, .mtime = mtime.? };
    }

    const name = parts.next() orelse return null;
    return .{
        .index = index,
        .cursor = cursor,
        .top_line = top,
        .has_text = has_text,
        .left_column = left,
        .anchor = anchor,
        .format = format,
        .disk = disk,
        .name = name,
        .path = parts.rest(),
    };
}

fn loadOne(b: *Buffer, io: std.Io, gpa: Allocator, dir: std.Io.Dir, entry: Entry) !void {
    const path: ?[]const u8 = if (entry.path.len > 0) entry.path else null;

    if (entry.has_text) {
        var name_buf: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&name_buf, "{d}.txt", .{entry.index});
        const text = try dir.readFileAlloc(io, file, gpa, .limited(buffer_mod.max_file_bytes));
        defer gpa.free(text);

        const view = try b.restore(path, entry.name, text);
        place(view, entry);
        view.format = entry.format;
        // The file as it was then, so a change made while closed is noticed.
        view.disk = entry.disk;
        // Unsaved text differs from disk, so no point in its history matches.
        view.saved = null;
    } else {
        try b.openOrSelect(path orelse return error.NoPath);
        if (b.current()) |view| place(view, entry);
    }
}

/// Clamped, since the file may have changed on disk since.
fn place(view: *BufferView, entry: Entry) void {
    const len = view.tree.len();
    view.cursor.offset = @min(entry.cursor, len);
    view.cursor.anchor = if (entry.anchor) |a| @min(a, len) else null;
    view.top_line = @min(entry.top_line, view.tree.lineCount() -| 1);
    view.left_column = entry.left_column;
    // Keeps the first frame from scrolling to the caret.
    view.followed = view.cursor.offset;
}

fn writeAtomic(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    errdefer dir.deleteFile(io, tmp) catch {};
    try dir.rename(tmp, dir, name, io);
}

/// Field by field, so padding bytes, which hold nothing in particular,
/// cannot make an unchanged session look changed.
fn hashValue(h: *std.hash.Wyhash, value: anytype) void {
    std.hash.autoHash(h, value);
}

fn appendLine(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try out.print(gpa, fmt, args);
    try out.append(gpa, '\n');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Buffers store absolute paths, so tests need one.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .path = try testing.allocator.dupe(u8, buf[0..len]) };
    }

    fn deinit(s: *Scratch) void {
        testing.allocator.free(s.path);
        s.tmp.cleanup();
    }

    fn join(s: Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ s.path, name });
    }
};

fn testBuffer() Buffer {
    return .{ .gpa = testing.allocator, .io = testing.io };
}

fn freeBuffer(b: *Buffer) void {
    Buffer.deinit(@ptrCast(b)) catch {};
}

test "a session comes back exactly as it was left" {
    var s = try Scratch.init();
    defer s.deinit();
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);

    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "one\ntwo\nthree\nfour\n" });
    const notes = try s.join("notes.txt");
    defer testing.allocator.free(notes);

    var before = testBuffer();
    defer freeBuffer(&before);
    try before.openOrSelect(notes);
    before.current().?.cursor.offset = 9;
    before.current().?.cursor.anchor = 4;
    before.current().?.top_line = 2;
    before.current().?.left_column = 3;
    const scratch = try before.newScratch();
    try scratch.insert("never saved anywhere");
    before.active = 0;

    const extras = Extras{ .zoom = 4, .window = .{ .x = 120, .y = 80, .width = 1000, .height = 700, .maximized = true } };
    try save(&before, extras, testing.io, testing.allocator, session_dir);

    var after = testBuffer();
    defer freeBuffer(&after);
    try testing.expect(try restore(&after, testing.io, testing.allocator, session_dir));

    try testing.expectEqual(@as(usize, 2), after.views.items.len);
    try testing.expectEqual(@as(usize, 0), after.active);

    const file_view = after.views.items[0];
    try testing.expectEqual(@as(u32, 9), file_view.cursor.offset);
    try testing.expectEqual(@as(?u32, 4), file_view.cursor.anchor);
    try testing.expectEqual(@as(u32, 2), file_view.top_line);
    try testing.expectEqual(@as(u32, 3), file_view.left_column);
    try testing.expect(!file_view.edited());

    const scratch_view = after.views.items[1];
    const text = try scratch_view.tree.allocText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("never saved anywhere", text);
    try testing.expect(scratch_view.edited());

    const back = readExtras(testing.io, testing.allocator, session_dir);
    try testing.expectEqual(@as(f32, 4), back.zoom);
    try testing.expectEqual(extras.window.?, back.window.?);
}

test "a version 1 session from before this format still restores" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(testing.io, "session");
    try s.tmp.dir.writeFile(testing.io, .{
        .sub_path = "session/index",
        .data = "zimacs-session 1\nactive\t0\ncount\t1\nbuffer\t0\t3\t0\t1\tuntitled 1\t\n",
    });
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "session/0.txt", .data = "hello" });
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);

    var b = testBuffer();
    defer freeBuffer(&b);
    try testing.expect(try restore(&b, testing.io, testing.allocator, session_dir));
    try testing.expectEqual(@as(u32, 3), b.views.items[0].cursor.offset);
    try testing.expectEqual(@as(?u32, null), b.views.items[0].cursor.anchor);

    const extras = readExtras(testing.io, testing.allocator, session_dir);
    try testing.expectEqual(@as(f32, 0), extras.zoom);
    try testing.expect(extras.window == null);
}

test "a file that shrank since the session was saved does not leave the caret past its end" {
    var s = try Scratch.init();
    defer s.deinit();
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "a long line of text\nand more\n" });
    const f = try s.join("f.txt");
    defer testing.allocator.free(f);

    var before = testBuffer();
    defer freeBuffer(&before);
    try before.openOrSelect(f);
    before.current().?.cursor.offset = 25;
    before.current().?.cursor.anchor = 20;
    before.current().?.top_line = 1;
    try save(&before, .{}, testing.io, testing.allocator, session_dir);

    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "tiny" });

    var after = testBuffer();
    defer freeBuffer(&after);
    try testing.expect(try restore(&after, testing.io, testing.allocator, session_dir));
    const view = after.views.items[0];
    try testing.expectEqual(@as(u32, 4), view.cursor.offset);
    try testing.expectEqual(@as(?u32, 4), view.cursor.anchor);
    try testing.expectEqual(@as(u32, 0), view.top_line);
}

test "nothing to restore, or rubbish, means a fresh start rather than an error" {
    var s = try Scratch.init();
    defer s.deinit();
    const missing = try s.join("nowhere");
    defer testing.allocator.free(missing);

    var b = testBuffer();
    defer freeBuffer(&b);
    try testing.expect(!try restore(&b, testing.io, testing.allocator, missing));
    try testing.expectEqual(Extras{}, readExtras(testing.io, testing.allocator, missing));

    try s.tmp.dir.createDirPath(testing.io, "bad");
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "bad/index", .data = "not a session at all\nzoom\t9\n" });
    const bad = try s.join("bad");
    defer testing.allocator.free(bad);
    try testing.expect(!try restore(&b, testing.io, testing.allocator, bad));
    try testing.expectEqual(Extras{}, readExtras(testing.io, testing.allocator, bad));
}

test "a nonsensical window placement is dropped rather than applied" {
    const extras = parseExtras("zimacs-session 2\nwindow\t10\t10\t0\t-5\t0\nzoom\tnan\n");
    try testing.expect(extras.window == null);
    try testing.expectEqual(@as(f32, 0), extras.zoom);
}

test "saving leaves no temporary files behind" {
    var s = try Scratch.init();
    defer s.deinit();
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);

    var b = testBuffer();
    defer freeBuffer(&b);
    const view = try b.newScratch();
    try view.insert("text");
    try save(&b, .{}, testing.io, testing.allocator, session_dir);
    try save(&b, .{}, testing.io, testing.allocator, session_dir);

    var dir = try std.Io.Dir.cwd().openDir(testing.io, session_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |item| {
        try testing.expect(!std.mem.endsWith(u8, item.name, ".tmp"));
    }
}

test "the signature moves with anything worth saving, and only then" {
    var b = testBuffer();
    defer freeBuffer(&b);
    const view = try b.newScratch();
    try view.insert("hello");

    const first = signature(&b, .{});
    try testing.expectEqual(first, signature(&b, .{}));

    view.cursor.offset = 2;
    const moved = signature(&b, .{});
    try testing.expect(moved != first);

    try view.insert("!");
    try testing.expect(signature(&b, .{}) != moved);

    const typed = signature(&b, .{});
    try testing.expect(signature(&b, .{ .zoom = 2 }) != typed);
    try testing.expect(signature(&b, .{ .window = .{ .x = 0, .y = 0, .width = 5, .height = 5 } }) != typed);
}

test "autosave waits for the interval and skips unchanged sessions" {
    var b = testBuffer();
    defer freeBuffer(&b);
    const view = try b.newScratch();
    var a = Autosave{ .interval = 10 };
    a.markSaved(&b, .{});

    try testing.expect(!a.due(11, &b, .{}));
    try view.insert("x");
    try testing.expect(!a.due(15, &b, .{}));
    try testing.expect(a.due(22, &b, .{}));
}

test "an unsaved buffer keeps its file format and disk stamp across a restart" {
    var s = try Scratch.init();
    defer s.deinit();
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);

    var before = testBuffer();
    defer freeBuffer(&before);
    const view = try before.newScratch();
    try view.insert("edited");
    view.format = .{ .encoding = .windows1252, .line_ending = .crlf };
    view.disk = .{ .size = 42, .mtime = 1234567890123 };
    try save(&before, .{}, testing.io, testing.allocator, session_dir);

    var after = testBuffer();
    defer freeBuffer(&after);
    try testing.expect(try restore(&after, testing.io, testing.allocator, session_dir));
    try testing.expectEqual(view.format, after.views.items[0].format);
    try testing.expectEqual(view.disk.?, after.views.items[0].disk.?);
}

test "a version 2 session still restores, with the default format" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(testing.io, "session");
    try s.tmp.dir.writeFile(testing.io, .{
        .sub_path = "session/index",
        .data = "zimacs-session 2\nactive\t0\nbuffer\t0\t1\t0\t1\t0\t-\tuntitled 1\t\n",
    });
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "session/0.txt", .data = "hi" });
    const session_dir = try s.join("session");
    defer testing.allocator.free(session_dir);

    var b = testBuffer();
    defer freeBuffer(&b);
    try testing.expect(try restore(&b, testing.io, testing.allocator, session_dir));
    try testing.expectEqual(Format{}, b.views.items[0].format);
}
