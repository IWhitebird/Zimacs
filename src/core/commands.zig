//! Everything the editor can be asked to do.
//!
//! The menu and the keyboard both end up here, so a command behaves the same
//! however it was reached, and there is one place to look for what it does.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const buffer_mod = @import("buffer.zig");
const BufferView = buffer_mod.BufferView;
const Action = @import("menu.zig").Action;
const browser_mod = @import("browser.zig");

/// The last thing searched for, so the menu and F3 repeat the same thing.
var query: std.ArrayList(u8) = .empty;

pub fn deinit() void {
    query.deinit(app.gpa);
}

pub fn run(action: Action) !void {
    switch (action) {
        .new_tab => _ = try app.buffer.newScratch(),
        .open_file => try browse(null),
        .open_recent => try app.prompt.beginWith(.open, app.recent.items()),
        .close_tab => try app.buffer.close(app.buffer.active),
        .open_config => try openConfig(),
        .about => {},

        .save => try save(),
        .save_as => try browseToSave(),

        .undo => if (app.buffer.current()) |v| try v.undo(),
        .redo => if (app.buffer.current()) |v| try v.redo(),
        .copy => if (app.buffer.current()) |v| try copy(v),
        .cut => if (app.buffer.current()) |v| {
            try copy(v);
            try v.deleteSelection();
        },
        .paste => if (app.buffer.current()) |v| try paste(v),
        .select_all => if (app.buffer.current()) |v| v.cursor.selectAll(&v.tree),
        .find => try app.prompt.begin(.find, query.items),

        .zoom_in => try app.font.zoomIn(),
        .zoom_out => try app.font.zoomOut(),
        .zoom_reset => try app.font.zoomReset(),
    }
}

/// Saves, asking for a name first if the buffer has never had one.
pub fn save() !void {
    const view = app.buffer.current() orelse return;
    if (view.path == null) return browseToSave();
    app.buffer.save(view) catch |err| report("Could not save", err);
}

/// Opens the browser to pick where to save. Typing a name and pressing Enter
/// saves into whichever directory is showing.
pub fn browseToSave() !void {
    const view = app.buffer.current() orelse return;
    const io = app.io orelse return app.prompt.begin(.save_as, view.path orelse "");

    const start = if (view.path) |p| std.fs.path.dirname(p) orelse "." else ".";
    app.browser.show(io, start, app.config.show_hidden) catch |err| {
        report("Could not read directory", err);
        return app.prompt.begin(.save_as, "");
    };
    try app.prompt.beginWith(.save_into, app.browser.items());
    // Start with the current name filled in, so it can just be confirmed.
    if (view.path != null) try app.prompt.append(std.fs.path.basename(view.name));
}

/// Handles Enter in the save browser: step into a directory, or write the
/// file into the one showing.
pub fn saveInBrowser(typed: []const u8) !void {
    const view = app.buffer.current() orelse return;

    // A directory that exactly matches what is typed means "go in there".
    if (browser_mod.isDirectory(typed) or std.mem.eql(u8, typed, browser_mod.parent)) {
        const full = app.browser.resolve(typed) catch |err| return report("Bad path", err);
        defer app.gpa.free(full);
        app.browser.show(app.io.?, full, app.config.show_hidden) catch |err| {
            return report("Could not read directory", err);
        };
        try app.prompt.beginWith(.save_into, app.browser.items());
        return;
    }

    const full = app.browser.resolve(typed) catch |err| return report("Bad path", err);
    defer app.gpa.free(full);
    app.prompt.cancel();
    app.buffer.saveAs(view, full) catch |err| report("Could not save", err);
}

/// Opens the file browser, starting beside the current file.
pub fn browse(at: ?[]const u8) !void {
    const io = app.io orelse return app.prompt.begin(.open, "");

    const start = at orelse blk: {
        const view = app.buffer.current() orelse break :blk ".";
        const path = view.path orelse break :blk ".";
        break :blk std.fs.path.dirname(path) orelse ".";
    };

    app.browser.show(io, start, app.config.show_hidden) catch |err| {
        report("Could not read directory", err);
        return;
    };
    try app.prompt.beginWith(.browse, app.browser.items());
}

/// Acts on whatever the browser has highlighted: step into a directory, or
/// open a file.
pub fn chooseInBrowser(name: []const u8) !void {
    const full = app.browser.resolve(name) catch |err| return report("Bad path", err);
    defer app.gpa.free(full);

    if (browser_mod.isDirectory(name) or std.mem.eql(u8, name, browser_mod.parent)) {
        try browse(full);
        return;
    }
    app.prompt.cancel();
    app.openFile(full) catch |err| report("Could not open", err);
}

pub fn openConfig() !void {
    const path = app.config_path orelse {
        std.debug.print("No settings file on this platform\n", .{});
        return;
    };
    app.openFile(path) catch |err| report("Could not open settings", err);
}

// ------------------------------------------------------------ clipboard

pub fn copy(view: *BufferView) !void {
    if (!view.cursor.hasSelection()) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app.gpa);
    try view.selectedText(&text);
    try text.append(app.gpa, 0);
    pen.setClipboardText(text.items[0 .. text.items.len - 1 :0]);
}

pub fn paste(view: *BufferView) !void {
    const clip = pen.getClipboardText();
    if (clip.len == 0) return;

    // Clipboards carry CRLF on some platforms; the buffer only holds LF.
    const text = try buffer_mod.toUnixNewlines(app.gpa, clip);
    defer app.gpa.free(text);
    try view.insert(text);
}

// --------------------------------------------------------------- search

pub const Direction = enum { forward, backward };

pub fn setQuery(needle: []const u8) !void {
    query.clearRetainingCapacity();
    try query.appendSlice(app.gpa, needle);
}

pub fn hasQuery() bool {
    return query.items.len > 0;
}

/// Jumps to the next match and selects it, wrapping round the ends.
pub fn search(direction: Direction) !void {
    const view = app.buffer.current() orelse return;
    if (query.items.len == 0) return;

    const found = switch (direction) {
        .forward => try view.tree.find(app.gpa, query.items, view.cursor.offset + 1) orelse
            try view.tree.find(app.gpa, query.items, 0),
        .backward => try view.tree.findLast(app.gpa, query.items, view.cursor.offset) orelse
            try view.tree.findLast(app.gpa, query.items, view.tree.len()),
    } orelse return;

    view.cursor.moveTo(&view.tree, found, false);
    view.cursor.anchor = found;
    view.cursor.offset = found + @as(u32, @intCast(query.items.len));
}

fn report(what: []const u8, err: anyerror) void {
    std.debug.print("{s}: {s}\n", .{ what, @errorName(err) });
}
