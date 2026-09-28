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
const update_mod = @import("update.zig");
const find_mod = @import("find.zig");
const config_mod = @import("config.zig");
const textfile = @import("textfile.zig");
const dialog_mod = @import("dialog.zig");
const notice_mod = @import("notice.zig");
const selfupdate = @import("selfupdate.zig");
const build_info = @import("build_info");
const builtin = @import("builtin");
const crash = @import("crash.zig");
const report_mod = @import("report.zig");
const system = @import("system.zig");
const filedialog = @import("filedialog.zig");
const comment = @import("comment.zig");
const updatelog = @import("updatelog.zig");

pub fn run(action: Action) !void {
    switch (action) {
        .new_tab => _ = try app.buffer.newScratch(),
        .open_file => try browse(null),
        .open_recent => try app.prompt.beginWith(.open, app.recent.items()),
        .close_tab => try requestClose(app.buffer.active),
        .open_config => try openConfig(),
        .check_updates => checkForUpdates(),
        .report_problem => reportProblem(),
        .about => app.menu.showing_about = true,

        .save => try save(),
        .save_as => try browseToSave(false),

        .undo => if (app.buffer.current()) |v| try v.undo(),
        .redo => if (app.buffer.current()) |v| try v.redo(),
        .copy => if (app.buffer.current()) |v| try copy(v),
        .cut => if (app.buffer.current()) |v| {
            try copy(v);
            try v.deleteSelection();
        },
        .paste => if (app.buffer.current()) |v| try paste(v),
        .select_all => if (app.buffer.current()) |v| {
            v.cursor.selectAll(&v.tree);
            // Selecting everything should not throw the view to the bottom of
            // the file, which is what following the caret would do.
            v.followed = v.cursor.offset;
        },
        .delete_line => if (app.buffer.current()) |v| try v.deleteLine(),
        .duplicate_line => if (app.buffer.current()) |v| try v.duplicateLine(),
        .toggle_comment => if (app.buffer.current()) |v| {
            if (!try comment.toggle(v, v.language)) tell(.info, "{s} has no comments", .{v.language.name});
        },
        .move_line_up => if (app.buffer.current()) |v| try v.moveLine(.up),
        .move_line_down => if (app.buffer.current()) |v| try v.moveLine(.down),
        .open_line_below => if (app.buffer.current()) |v| try v.openLineBelow(),
        .open_line_above => if (app.buffer.current()) |v| try v.openLineAbove(),
        .indent => if (app.buffer.current()) |v| {
            var unit: [config_mod.max_indent_unit]u8 = undefined;
            try v.indentLines(app.config.indentUnit(&unit));
        },
        .outdent => if (app.buffer.current()) |v| try v.outdentLines(app.config.tab_width),
        .goto_line => try app.prompt.begin(.goto_line, ""),
        .find => try openFind(false),
        .replace => try openFind(true),
        .find_next => try findStep(.forward),
        .find_previous => try findStep(.backward),
        .toggle_wrap => toggleWrap(),

        .zoom_in => app.font.zoomIn(),
        .zoom_out => app.font.zoomOut(),
        .zoom_reset => app.font.zoomReset(),
    }
}

/// Saves, asking for a name first if the buffer has never had one.
pub fn save() !void {
    const view = app.buffer.current() orelse return;
    if (view.path == null) return browseToSave(false);
    _ = saveView(view);
}

/// True when the file was written.
fn saveView(view: *BufferView) bool {
    const outcome = app.buffer.save(view) catch |err| {
        report("Could not save", err);
        return false;
    };
    announceSave(view, outcome);
    return true;
}

/// Saves under a new name, then closes the tab if closing is what asked.
pub fn saveViewAs(view: *BufferView, path: []const u8) void {
    const pending = pending_save;
    pending_save = null;
    const outcome = app.buffer.saveAs(view, path) catch |err| return report("Could not save", err);
    announceSave(view, outcome);
    const p = pending orelse return;
    if (p.view == view.id and p.then_close) {
        if (app.buffer.indexOf(view)) |i| app.buffer.close(i) catch |err| report("Could not close", err);
    }
}

/// A Save As waiting on the user to pick a name.
const PendingSave = struct {
    /// The tab's id, since it may close while the choice is being made.
    view: u64,
    /// Closing the tab is what asked for it.
    then_close: bool,
};
var pending_save: ?PendingSave = null;

/// A Save As was cancelled, so nothing waits on it any more.
pub fn cancelSave() void {
    pending_save = null;
}

fn announceSave(view: *BufferView, outcome: buffer_mod.Buffer.Saved) void {
    if (outcome == .switched_to_utf8) {
        tell(.problem, "Saved {s} as UTF-8: it has characters its old encoding cannot hold", .{view.name});
    }
}

// ------------------------------------------------------- file dialogs

const dialog_open = "Finish the open file dialog first";

/// Acts on what a system file dialog chose, once it has closed.
pub fn finishFileDialog(outcome: filedialog.Outcome) void {
    const path = outcome.path orelse {
        if (outcome.kind == .save) cancelSave();
        return;
    };
    defer app.gpa.free(path);
    switch (outcome.kind) {
        .open => app.openFile(path) catch |err| report("Could not open", err),
        .save => {
            const p = pending_save orelse return;
            // The tab may have been closed while the dialog was up.
            const view = app.buffer.withId(p.view) orelse return cancelSave();
            saveViewAs(view, path);
        },
    }
}

// ------------------------------------------------------------ closing

/// Closes a tab, first asking what to do with unsaved changes.
pub fn requestClose(index: usize) !void {
    if (index >= app.buffer.views.items.len) return;
    const view = app.buffer.views.items[index];
    if (!view.edited()) return app.buffer.close(index);
    app.buffer.select(index);
    app.dialog.ask(.{ .close_unsaved = view });
}

pub fn answer(a: dialog_mod.Answer) !void {
    const q = app.dialog.question orelse return;
    app.dialog.close();
    const view = q.view();
    const index = app.buffer.indexOf(view) orelse return;
    switch (a) {
        .save => if (view.path == null) {
            try browseToSave(true);
        } else if (saveView(view)) {
            try app.buffer.close(index);
        },
        .discard => try app.buffer.close(index),
        .reload => app.buffer.reload(view) catch |err| report("Could not reload", err),
        .keep => app.buffer.acknowledgeDisk(view),
        .cancel => {},
    }
}

// ------------------------------------------------------------ the disk

/// Picks up files changed by other programs. Clean buffers are reloaded
/// quietly; one with unsaved work asks first.
pub fn checkDisk() void {
    if (app.dialog.question != null) return;
    for (app.buffer.views.items) |view| {
        switch (app.buffer.diskState(view)) {
            .unchanged => {},
            .missing => {
                tell(.problem, "{s} was deleted or moved; saving will write it again", .{view.name});
                view.disk = null;
            },
            .changed => if (view.edited()) {
                app.dialog.ask(.{ .changed_on_disk = view });
                return;
            } else {
                app.buffer.reload(view) catch |err| report("Could not reload", err);
                tell(.info, "Reloaded {s}, which changed on disk", .{view.name});
            },
        }
    }
}

/// Asks where to save the current tab, and closes it afterwards if
/// `then_close`. Typing a name in the built-in browser and pressing Enter
/// saves into whichever directory is showing.
pub fn browseToSave(then_close: bool) !void {
    const view = app.buffer.current() orelse return;
    const io = app.io orelse return app.prompt.begin(.save_as, view.path orelse "");

    const start = if (view.path) |p| std.fs.path.dirname(p) orelse "." else ".";
    const name = if (view.path != null) std.fs.path.basename(view.name) else "";
    const shown = app.file_dialog.show(app.gpa, io, .{ .kind = .save, .dir = start, .name = name });
    if (shown == .busy) return tell(.info, dialog_open, .{});
    pending_save = .{ .view = view.id, .then_close = then_close };
    if (shown == .shown) return;
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
    saveViewAs(view, full);
}

/// Opens the file browser, starting beside the current file.
pub fn browse(at: ?[]const u8) !void {
    const io = app.io orelse return app.prompt.begin(.open, "");

    const start = at orelse blk: {
        const view = app.buffer.current() orelse break :blk ".";
        const path = view.path orelse break :blk ".";
        break :blk std.fs.path.dirname(path) orelse ".";
    };
    // The system's dialog when there is one; stepping between directories
    // of the built-in browser stays in it.
    if (at == null) switch (app.file_dialog.show(app.gpa, io, .{ .kind = .open, .dir = start })) {
        .shown => return,
        .busy => return tell(.info, dialog_open, .{}),
        .unavailable => {},
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

/// Opens a new GitHub issue, filled in with the version and the latest crash
/// and update log, for the user to read over and send.
pub fn reportProblem() void {
    const crash_text = if (app.data_dir) |d| if (app.io) |io| crash.last(app.gpa, io, d) else null else null;
    defer if (crash_text) |t| app.gpa.free(t);
    const update_log = readDataFile(updatelog.file_name);
    defer if (update_log) |t| app.gpa.free(t);

    const url = report_mod.issueUrl(app.gpa, .{
        .version = app.version,
        .platform = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        .crash = crash_text,
        .update_log = update_log,
    }) catch |err| return report("Could not write the report", err);
    defer app.gpa.free(url);
    system.openUrl(app.gpa, app.io, url) catch |err| report("Could not open the browser", err);
}

fn readDataFile(name: []const u8) ?[]u8 {
    const dir_path = app.data_dir orelse return null;
    const io = app.io orelse return null;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    return dir.readFileAlloc(io, name, app.gpa, .limited(64 * 1024)) catch null;
}

/// From the Help menu. Official builds also install what they find.
pub fn checkForUpdates() void {
    startUpdate(.{ .install = build_info.self_update, .announce = true });
}

/// Silent unless there is news. Official builds with `auto_update` only.
pub fn updateInBackground() void {
    if (!build_info.self_update or !app.config.auto_update) return;
    startUpdate(.{ .install = true, .announce = false });
}

/// Once at startup: the copy an update on Windows set aside is no longer
/// running, whichever way that update was started.
pub fn removeUpdateLeftovers() void {
    if (!build_info.self_update) return;
    if (app.io) |io| selfupdate.removeLeftovers(app.gpa, io);
}

fn startUpdate(options: update_mod.Options) void {
    const io = app.io orelse return;
    const current = update_mod.Version.parse(app.version) orelse return;
    app.update.start(app.gpa, io, current, options);
}

pub fn openConfig() !void {
    const path = app.config_path orelse {
        tell(.problem, "There is no settings file on this platform", .{});
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
    const text = try textfile.toLf(app.gpa, clip);
    defer app.gpa.free(text);
    try view.insert(text);
}

// --------------------------------------------------------------- search

/// Selections longer than this are not used to seed the search.
const max_seed = 256;

/// Opens the find bar, seeded with the selection when it is a single line.
pub fn openFind(replacing: bool) !void {
    app.prompt.cancel();
    const view = app.buffer.current();
    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(app.gpa);
    if (view) |v| if (v.cursor.selection()) |r| if (r.len() <= max_seed) {
        try v.tree.copy(r.start, r.len(), &seed);
        if (std.mem.indexOfScalar(u8, seed.items, '\n') != null) seed.clearRetainingCapacity();
    };
    try app.find.begin(view, replacing, if (seed.items.len > 0) seed.items else null);
}

/// F3 and Shift+F3: repeats the last search, or opens the bar if there is none.
pub fn findStep(direction: find_mod.Direction) !void {
    const view = app.buffer.current() orelse return;
    if (app.find.query.value().len == 0) return openFind(false);
    try app.find.step(view, direction);
}

pub fn toggleWrap() void {
    app.config.wrap_lines = !app.config.wrap_lines;
    for (app.buffer.views.items) |v| {
        v.left_column = 0;
        v.top_row = 0;
        // Keeps the caret on screen after the text reflows.
        v.followed = null;
    }
    const io = app.io orelse return;
    const path = app.config_path orelse return;
    config_mod.store(io, app.gpa, path, "wrap_lines", if (app.config.wrap_lines) "true" else "false") catch |err|
        report("Could not save the setting", err);
}

/// Whether a checkable menu entry shows its tick.
pub fn checked(action: Action) bool {
    return switch (action) {
        .toggle_wrap => app.config.wrap_lines,
        else => false,
    };
}

/// Jumps to a 1-based line number typed into the prompt.
pub fn gotoLine(typed: []const u8) void {
    const view = app.buffer.current() orelse return;
    const wanted = std.fmt.parseInt(u32, std.mem.trim(u8, typed, " "), 10) catch {
        report("Not a line number", error.InvalidCharacter);
        return;
    };
    const line = @min(wanted -| 1, view.tree.lineCount() - 1);
    view.cursor.moveTo(&view.tree, view.tree.lineStart(line), false);
}

pub fn report(what: []const u8, err: anyerror) void {
    tell(.problem, "{s}: {s}", .{ what, @errorName(err) });
}

pub fn tell(kind: notice_mod.Notice.Kind, comptime fmt: []const u8, args: anytype) void {
    app.notice.show(pen.getTime(), kind, fmt, args);
}
