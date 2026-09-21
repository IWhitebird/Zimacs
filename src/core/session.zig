//! Remembers your open tabs between runs, unsaved work included.
//!
//! On exit, each buffer is written to the data directory: an `index` file
//! listing the tabs, plus one numbered file per buffer holding its text.
//! Buffers that match their file on disk store no text - they are simply
//! reopened from the file next time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const dir_name = "session";

const index_name = "index";
const header = "zimacs-session 1";
const max_index_bytes = 4 * 1024 * 1024;
const max_text_bytes = 512 * 1024 * 1024;

/// Writes the open tabs to `dir`. Never fatal: a session that cannot be
/// written just means it cannot be restored.
pub fn save(b: *Buffer, io: std.Io, gpa: Allocator, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var open = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer open.close(io);

    var index: std.ArrayList(u8) = .empty;
    defer index.deinit(gpa);

    try index.appendSlice(gpa, header);
    try index.append(gpa, '\n');
    try appendLine(&index, gpa, "active\t{d}", .{b.active});
    try appendLine(&index, gpa, "count\t{d}", .{b.views.items.len});

    for (b.views.items, 0..) |view, i| {
        // Only unsaved work needs storing; a clean file is reopened from disk.
        const keep_text = view.edited() or view.path == null;
        try appendLine(&index, gpa, "buffer\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}", .{
            i,
            view.cursor.offset,
            view.top_line,
            @intFromBool(keep_text),
            view.name,
            view.path orelse "",
        });

        if (!keep_text) continue;
        const text = try view.tree.allocText(gpa);
        defer gpa.free(text);

        var name_buf: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&name_buf, "{d}.txt", .{i});
        try open.writeFile(io, .{ .sub_path = file, .data = text });
    }

    try open.writeFile(io, .{ .sub_path = index_name, .data = index.items });
}

/// Reopens whatever `save` last wrote. Returns false if there was nothing to
/// restore, so the caller can start a fresh buffer instead.
pub fn restore(b: *Buffer, io: std.Io, gpa: Allocator, dir: []const u8) !bool {
    var open = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer open.close(io);

    const index = open.readFileAlloc(io, index_name, gpa, .limited(max_index_bytes)) catch return false;
    defer gpa.free(index);

    var lines = std.mem.splitScalar(u8, index, '\n');
    const first = lines.next() orelse return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, "\r"), header)) return false;

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

        const entry = parseBuffer(&parts) orelse continue;
        if (loadOne(b, io, gpa, open, entry)) {
            restored += 1;
        } else |_| {
            // One unreadable tab should not stop the rest coming back.
        }
    }

    if (restored == 0) return false;
    b.active = @min(active, b.views.items.len - 1);
    return true;
}

const Entry = struct {
    index: usize,
    cursor: u32,
    top_line: u32,
    has_text: bool,
    name: []const u8,
    path: []const u8,
};

fn parseBuffer(parts: *std.mem.SplitIterator(u8, .scalar)) ?Entry {
    const index = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const cursor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const top = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const has_text = !std.mem.eql(u8, parts.next() orelse return null, "0");
    const name = parts.next() orelse return null;
    const path = parts.rest();
    return .{
        .index = index,
        .cursor = cursor,
        .top_line = top,
        .has_text = has_text,
        .name = name,
        .path = path,
    };
}

fn loadOne(b: *Buffer, io: std.Io, gpa: Allocator, dir: std.Io.Dir, entry: Entry) !void {
    const path: ?[]const u8 = if (entry.path.len > 0) entry.path else null;

    if (entry.has_text) {
        var name_buf: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&name_buf, "{d}.txt", .{entry.index});
        const text = try dir.readFileAlloc(io, file, gpa, .limited(max_text_bytes));
        defer gpa.free(text);

        const view = try b.restore(path, entry.name, text);
        view.cursor.offset = @min(entry.cursor, view.tree.len());
        view.top_line = entry.top_line;
        // Restored unsaved text differs from disk, so it must look edited.
        view.saved_at = 1;
    } else {
        try b.openOrSelect(path orelse return error.NoPath);
        if (b.current()) |view| {
            view.cursor.offset = @min(entry.cursor, view.tree.len());
            view.top_line = entry.top_line;
        }
    }
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
