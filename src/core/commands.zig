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
const foldersearch = @import("foldersearch.zig");
const comment = @import("comment.zig");
const updatelog = @import("updatelog.zig");
const wikilink = @import("wikilink.zig");
const editor = @import("editor.zig");
const mcp = @import("mcp.zig");

pub fn run(action: Action) !void {
    switch (action) {
        .new_tab => _ = try app.buffer.newScratch(),
        .open_file => try browse(null),
        .open_folder => try chooseFolder(),
        .close_folder => app.closeFolder(),
        .open_memory => openMemory(),
        .quick_open => try quickOpen(),
        .search_folder => try searchFolder(),
        .toggle_sidebar => toggleSidebar(),
        .open_recent => try openRecent(),
        .reopen_tab => if (!app.buffer.reopenClosed()) tell(.info, "No closed tab to reopen", .{}),
        .backlinks => try showBacklinks(),
        .graph_view => toggleGraph(),
        .close_tab => try requestClose(app.buffer.active),
        .close_others => try closeTabs(.others),
        .close_left => try closeTabs(.left),
        .close_right => try closeTabs(.right),
        .close_saved => try closeTabs(.saved),
        .close_all => try closeTabs(.all),
        .copy_path => copyPath(),
        .open_config => try openConfig(),
        .check_updates => checkForUpdates(),
        .report_problem => reportProblem(),
        .copy_mcp_command => copyMcpCommand(),
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
fn save() !void {
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
    afterSave(view, outcome);
    return true;
}

/// Saves under a new name, then closes the tab if closing is what asked.
pub fn saveViewAs(view: *BufferView, path: []const u8) void {
    const pending = pending_save;
    pending_save = null;
    const outcome = app.buffer.saveAs(view, path) catch |err| {
        stopClosing();
        return report("Could not save", err);
    };
    afterSave(view, outcome);
    const p = pending orelse return;
    if (p.view == view.id and p.then_close) {
        if (app.buffer.indexOf(view)) |i| app.buffer.close(i);
        continueClosing();
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
    stopClosing();
}

fn afterSave(view: *BufferView, outcome: buffer_mod.Buffer.Saved) void {
    if (outcome == .switched_to_utf8) {
        tell(.problem, "Saved {s} as UTF-8: it has characters its old encoding cannot hold", .{view.name});
    }
    // Its links may have changed.
    if (isFolderNote(view)) app.workspace.refresh(app.io.?);
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
        .folder => app.openFolder(path) catch |err| report("Could not open the folder", err),
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
    stopClosing();
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
            app.buffer.close(index);
            continueClosing();
        } else stopClosing(),
        .discard => {
            app.buffer.close(index);
            continueClosing();
        },
        .reload => app.buffer.reload(view) catch |err| report("Could not reload", err),
        .keep => app.buffer.acknowledgeDisk(view),
        .cancel => stopClosing(),
    }
}

/// Which tabs a close of several takes, around the one in front.
const TabSet = enum { others, left, right, saved, all };

/// Closes a set of tabs left to right, asking in turn about each with
/// unsaved changes. Cancelling stops there and keeps the rest.
fn closeTabs(set: TabSet) !void {
    const active = app.buffer.active;
    const closing = &app.buffer.closing;
    closing.clearRetainingCapacity();
    // Last first, so they come off the end left to right.
    var i = app.buffer.views.items.len;
    while (i > 0) {
        i -= 1;
        const view = app.buffer.views.items[i];
        const take = switch (set) {
            .others => i != active,
            .left => i < active,
            .right => i > active,
            .saved => !view.edited(),
            .all => true,
        };
        if (take) try closing.append(app.gpa, view.id);
    }
    continueClosing();
}

/// Closes the queued tabs, stopping to ask about one with unsaved changes.
fn continueClosing() void {
    while (app.buffer.closing.pop()) |id| {
        const view = app.buffer.withId(id) orelse continue;
        const index = app.buffer.indexOf(view) orelse continue;
        if (view.edited()) {
            app.buffer.select(index);
            app.dialog.ask(.{ .close_unsaved = view });
            return;
        }
        app.buffer.close(index);
    }
}

fn stopClosing() void {
    app.buffer.closing.clearRetainingCapacity();
}

fn copyPath() void {
    const view = app.buffer.current() orelse return;
    const path = view.path orelse return tell(.info, "{s} has not been saved yet", .{view.name});
    const text = app.gpa.dupeZ(u8, path) catch return;
    defer app.gpa.free(text);
    pen.setClipboardText(text);
    tell(.info, "Copied {s}", .{path});
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
fn browseToSave(then_close: bool) !void {
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

const desktop_only = "Folders need the desktop version of Zimacs";

/// A list commands build for the prompt to offer, such as Open Recent's.
/// One prompt is open at a time, so they share it.
var choices: std.ArrayList([]const u8) = .empty;
/// Holds `choices` too, so both go at once. The web build's heap belongs
/// to emscripten, so its allocator is libc's.
var choice_arena = std.heap.ArenaAllocator.init(if (app.on_web) std.heap.c_allocator else std.heap.page_allocator);

/// Empties `choices`, returning where to put the new ones.
fn newChoices() std.mem.Allocator {
    _ = choice_arena.reset(.retain_capacity);
    choices = .empty;
    return choice_arena.allocator();
}

/// The folders, each with a separator after it to tell it apart, then the
/// files.
fn openRecent() !void {
    const a = newChoices();
    for (app.recent_folders.items()) |folder| {
        try choices.append(a, try std.fmt.allocPrint(a, "{s}{c}", .{ folder, std.fs.path.sep }));
    }
    for (app.recent.items()) |file| try choices.append(a, file);
    try app.prompt.beginWith(.recent, choices.items);
}

// ---------------------------------------------------------------- notes

/// A Markdown note saved inside the open folder, whose links the graph and
/// backlinks follow.
fn isFolderNote(view: *const BufferView) bool {
    const path = view.path orelse return false;
    return wikilink.isNote(path) and app.workspace.relativeOf(path) != null;
}

/// Opens the note a link names, first making it if no file has it yet.
pub fn followLink(view: *const BufferView, written: []const u8) void {
    const io = app.io orelse return;
    const from = view.path orelse return tell(.info, "Save the note before following its links", .{});
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = linkedPath(from, wikilink.normalise(written, &buf)) catch |err| return report("Could not follow the link", err);
    defer app.gpa.free(path);
    createNote(io, path) catch |err| return report("Could not make the note", err);
    app.openFile(path) catch |err| report("Could not open", err);
}

/// The file a link in `from` means: one the folder has, or where a new note
/// for it goes. Caller frees.
fn linkedPath(from: []const u8, target: []const u8) ![]u8 {
    if (app.workspace.relativeOf(from)) |relative| {
        const files = app.workspace.files();
        if (wikilink.resolve(files, target, relative)) |i| return app.workspace.absolute(app.gpa, files[i]);
        const made = try wikilink.newNotePath(app.gpa, target, relative);
        defer app.gpa.free(made);
        return app.workspace.absolute(app.gpa, made);
    }
    // Outside the open folder only the notes beside it are known.
    const made = try wikilink.newNotePath(app.gpa, target, std.fs.path.basename(from));
    defer app.gpa.free(made);
    return std.fs.path.join(app.gpa, &.{ std.fs.path.dirname(from) orelse ".", made });
}

/// Makes an empty note at `path`, unless a file is there already.
fn createNote(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    file.close(io);
    app.workspace.refresh(io);
}

/// Offers the folder's notes to link to, once `[[` is typed in one.
pub fn linkNote() !void {
    const view = app.buffer.current() orelse return;
    if (!isFolderNote(view)) return;
    const a = newChoices();
    for (app.workspace.notes().notes) |n| {
        try choices.append(a, try a.dupe(u8, if (n.path) |p| wikilink.key(p) else n.name));
    }
    try app.prompt.beginWith(.link_note, choices.items);
}

/// Finishes the link being typed with the note chosen.
pub fn insertLink(chosen: []const u8) !void {
    const view = app.buffer.current() orelse return;
    try view.insert(shortestName(chosen));
    const at = view.cursor.offset;
    const closed = view.tree.byteAt(at) == ']' and view.tree.byteAt(at + 1) == ']';
    if (!closed) try view.insert("]]");
}

/// A note's name alone, unless another note on offer has it too.
fn shortestName(chosen: []const u8) []const u8 {
    const name = std.fs.path.basenamePosix(chosen);
    var count: usize = 0;
    for (choices.items) |c| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.basenamePosix(c), name)) count += 1;
    }
    return if (count == 1) name else chosen;
}

/// Lists the notes that link to the one in front.
fn showBacklinks() !void {
    if (!folderOpen()) return;
    const view = app.buffer.current() orelse return;
    if (!isFolderNote(view)) return tell(.info, "Backlinks are for Markdown notes in the open folder", .{});
    const graph = app.workspace.notes();
    const note = graph.find(app.workspace.relativeOf(view.path.?).?) orelse return tell(.info, no_backlinks, .{});
    var from: std.ArrayList(u32) = .empty;
    defer from.deinit(app.gpa);
    try graph.backlinks(app.gpa, note, &from);
    if (from.items.len == 0) return tell(.info, no_backlinks, .{});
    const a = newChoices();
    for (from.items) |i| try choices.append(a, try a.dupe(u8, graph.notes[i].path.?));
    try app.prompt.beginWith(.backlinks, choices.items);
}

const no_backlinks = "No notes link here";

/// Shows the folder's notes as a graph, centred on the one in front, or
/// hides it again.
fn toggleGraph() void {
    if (app.graph.shown) return app.graph.hide();
    showGraph();
}

fn showGraph() void {
    if (!folderOpen()) return;
    const view = app.buffer.current();
    const path = if (view) |v| if (v.path) |p| app.workspace.relativeOf(p) else null else null;
    app.graph.show(path, editor.currentLayout().body()) catch |err| return report("Could not draw the graph", err);
    app.workspace.refresh(app.io.?);
}

/// Opens the folder `Zimacs mcp` keeps notes in when given none, with its
/// graph, to see what agents have written there.
fn openMemory() void {
    const dir = app.data_dir orelse return tell(.info, desktop_only, .{});
    const io = app.io orelse return;
    const folder = std.fs.path.join(app.gpa, &.{ dir, mcp.memory_folder }) catch |err| return report("Could not open the memory folder", err);
    defer app.gpa.free(folder);
    std.Io.Dir.cwd().createDirPath(io, folder) catch |err| return report("Could not make the memory folder", err);
    app.openFolder(folder) catch |err| return report("Could not open the memory folder", err);
    showGraph();
}

/// Copies the command that gives Claude Code this editor's notes tools.
fn copyMcpCommand() void {
    const io = app.io orelse return tell(.info, desktop_only, .{});
    const exe = std.process.executablePathAlloc(io, app.gpa) catch |err| return report("Could not find Zimacs itself", err);
    defer app.gpa.free(exe);
    const command = std.fmt.allocPrintSentinel(app.gpa, "claude mcp add --scope user zimacs -- \"{s}\" mcp", .{exe}, 0) catch return;
    defer app.gpa.free(command);
    pen.setClipboardText(command);
    tell(.info, "Copied: {s}", .{command});
}

/// Opens the note of dot `index` in the graph, making it first if it is one
/// links name but no file has yet.
pub fn openGraphNode(index: u32) void {
    const io = app.io orelse return;
    const node = app.graph.nodes.items[index];
    if (node.path()) |p| return openInFolder(p);
    const made = wikilink.newNotePath(app.gpa, node.name(), "") catch |err| return report("Could not make the note", err);
    defer app.gpa.free(made);
    const path = app.workspace.absolute(app.gpa, made) catch |err| return report("Could not make the note", err);
    defer app.gpa.free(path);
    createNote(io, path) catch |err| return report("Could not make the note", err);
    app.openFile(path) catch |err| report("Could not open", err);
}

/// Whether a folder is open, saying how to open one when it is not.
fn folderOpen() bool {
    if (app.io == null) {
        tell(.info, desktop_only, .{});
        return false;
    }
    if (app.workspace.root == null) {
        tell(.info, "Open a folder first: File > Open Folder", .{});
        return false;
    }
    return true;
}

/// Picks one of the folder's files by a few letters of its path. The folder
/// is listed again each time, and the list swaps in once that is done.
fn quickOpen() !void {
    if (!folderOpen()) return;
    app.workspace.refresh(app.io.?);
    try app.prompt.beginWith(.quick_open, app.workspace.files());
}

/// A new listing of the folder is in; the old one's names are gone.
pub fn folderListed() void {
    app.graph.sync(app.workspace.notes()) catch |err| report("Could not draw the graph", err);
    if (!app.prompt.active) return;
    switch (app.prompt.kind) {
        .quick_open => app.prompt.replaceOptions(app.workspace.files()) catch app.prompt.cancel(),
        // It may have started before there was a listing to search.
        .search_folder => searchQueryEdited(),
        else => {},
    }
}

/// Searches every file of the folder, again as the query is typed. Opens
/// on the last query and its hits.
fn searchFolder() !void {
    if (!folderOpen()) return;
    try app.prompt.begin(.search_folder, app.folder_search.query.items);
    try app.prompt.replaceOptions(app.folder_search.labels());
}

/// The query changed: search again, with unsaved tabs as they are now.
pub fn searchQueryEdited() void {
    const io = app.io orelse return;
    const root = app.workspace.root orelse return;
    // The hits the prompt shows are about to be freed.
    app.prompt.replaceOptions(&.{}) catch {};

    var unsaved: std.ArrayList(foldersearch.Unsaved) = .empty;
    defer {
        for (unsaved.items) |u| app.gpa.free(u.text);
        unsaved.deinit(app.gpa);
    }
    for (app.buffer.views.items) |view| {
        if (!view.edited()) continue;
        const relative = app.workspace.relativeOf(view.path orelse continue) orelse continue;
        const text = view.tree.allocText(app.gpa) catch continue;
        unsaved.append(app.gpa, .{ .path = relative, .text = text }) catch app.gpa.free(text);
    }
    app.folder_search.start(io, root, app.workspace.files(), unsaved.items, app.prompt.text(), .{}) catch |err|
        report("Could not search", err);
}

/// The hits of the current query are in.
pub fn folderSearched() void {
    if (app.prompt.active and app.prompt.kind == .search_folder) {
        app.prompt.replaceOptions(app.folder_search.labels()) catch app.prompt.cancel();
    }
}

/// Opens the file of search hit `index` with its match selected.
pub fn openHit(index: usize) void {
    const hits = app.folder_search.hits();
    if (index >= hits.len) return;
    const hit = hits[index];
    openInFolder(hit.path);
    const view = app.buffer.current() orelse return;
    const tree = &view.tree;
    const line = @min(hit.line, tree.lineCount() - 1);
    const start = @min(tree.lineStart(line) + hit.column, tree.lineEnd(line));
    const end = @min(start + @as(u32, @intCast(app.folder_search.query.items.len)), tree.lineEnd(line));
    view.cursor.moveTo(tree, start, false);
    view.cursor.moveTo(tree, end, true);
}

/// Opens a file of the folder, given relative to it.
pub fn openInFolder(relative: []const u8) void {
    const path = app.workspace.absolute(app.gpa, relative) catch |err| return report("Could not open", err);
    defer app.gpa.free(path);
    app.openFile(path) catch |err| report("Could not open", err);
}

fn toggleSidebar() void {
    if (!folderOpen()) return;
    app.sidebar.shown = !app.sidebar.shown;
    app.refreshSidebar();
}

/// Asks for a folder to open as the project, in the system's dialog or else
/// by typing its path.
fn chooseFolder() !void {
    const io = app.io orelse return tell(.info, desktop_only, .{});
    const start = app.workspace.root orelse ".";
    switch (app.file_dialog.show(app.gpa, io, .{ .kind = .folder, .dir = start })) {
        .shown => {},
        .busy => tell(.info, dialog_open, .{}),
        .unavailable => try app.prompt.begin(.open_folder, start),
    }
}

/// Opens the file browser, starting beside the current file.
fn browse(at: ?[]const u8) !void {
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
fn reportProblem() void {
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
fn checkForUpdates() void {
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

fn openConfig() !void {
    const path = app.config_path orelse {
        tell(.problem, "There is no settings file on this platform", .{});
        return;
    };
    app.openFile(path) catch |err| report("Could not open settings", err);
}

// ------------------------------------------------------------ clipboard

fn copy(view: *BufferView) !void {
    if (!view.cursor.hasSelection()) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app.gpa);
    try view.selectedText(&text);
    try text.append(app.gpa, 0);
    pen.setClipboardText(text.items[0 .. text.items.len - 1 :0]);
}

fn paste(view: *BufferView) !void {
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
fn openFind(replacing: bool) !void {
    app.prompt.cancel();
    const view = app.buffer.current();
    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(app.gpa);
    if (view) |v| if (v.cursor.selection()) |r| if (r.len() <= max_seed) {
        try v.tree.copy(r.start, r.len(), &seed);
        if (std.mem.findScalar(u8, seed.items, '\n') != null) seed.clearRetainingCapacity();
    };
    try app.find.begin(view, replacing, if (seed.items.len > 0) seed.items else null);
}

/// F3 and Shift+F3: repeats the last search, or opens the bar if there is none.
pub fn findStep(direction: find_mod.Direction) !void {
    const view = app.buffer.current() orelse return;
    if (app.find.query.value().len == 0) return openFind(false);
    try app.find.step(view, direction);
}

fn toggleWrap() void {
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
/// Whether an entry can do anything now; one that cannot is greyed out.
pub fn enabled(action: Action) bool {
    const views = app.buffer.views.items;
    const active = app.buffer.active;
    return switch (action) {
        .close_others => views.len > 1,
        .close_left => views.len > 0 and active > 0,
        .close_right => active + 1 < views.len,
        .close_saved => for (views) |v| {
            if (!v.edited()) break true;
        } else false,
        .copy_path => if (app.buffer.current()) |v| v.path != null else false,
        .reopen_tab => app.buffer.closed.items.len > 0,
        else => true,
    };
}

pub fn checked(action: Action) bool {
    return switch (action) {
        .toggle_wrap => app.config.wrap_lines,
        .toggle_sidebar => app.sidebar.shown and app.workspace.root != null,
        .graph_view => app.graph.shown,
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
