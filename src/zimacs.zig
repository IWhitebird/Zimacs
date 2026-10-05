//! Zimacs: the application itself.
//!
//! Holds the state every part of the editor reaches for, and runs the main
//! loop. Each component is an `Artifact` in one list: set up in order,
//! rendered in order every frame, torn down in reverse.
//!
//! Render order matters. Input runs last, so what a key does is drawn on the
//! next frame, which `idle.pace` makes sure follows.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");

const build_info = @import("build_info");
const commands = @import("core/commands.zig");
const config_mod = @import("core/config.zig");
const crash = @import("core/crash.zig");
const idle = @import("core/idle.zig");
const paths = @import("core/paths.zig");
const recent_mod = @import("core/recent.zig");
const session = @import("core/session.zig");
const theme = @import("core/theme.zig");
const update_mod = @import("core/update.zig");
const web = @import("core/web.zig");
const window_mod = @import("core/window.zig");
const Interval = @import("core/interval.zig").Interval;

const Artifact = @import("core/artifact.zig").Artifact;
const Buffer = @import("core/buffer.zig").Buffer;
const Editor = @import("core/editor.zig").Editor;
const Font = @import("core/font.zig").Font;
const Input = @import("core/input.zig").Input;
const Menu = @import("core/menu.zig").Menu;
const Prompt = @import("core/prompt.zig").Prompt;
const Recent = recent_mod.Recent;
const Browser = @import("core/browser.zig").Browser;
const Update = update_mod.Update;
const Window = @import("core/window.zig").Window;
const Find = @import("core/find.zig").Find;
const Dialog = @import("core/dialog.zig").Dialog;
const Notice = @import("core/notice.zig").Notice;
const FileDialog = @import("core/filedialog.zig").Dialog;
const Workspace = @import("core/workspace.zig").Workspace;
const Sidebar = @import("core/sidebar.zig").Sidebar;
const FolderSearch = @import("core/foldersearch.zig").FolderSearch;
const GraphView = @import("core/graph.zig").GraphView;
const Settings = @import("core/settings.zig").Settings;
const native = @import("core/native.zig");

const leak_checks = builtin.mode == .Debug;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// Debug builds get leak checking, release builds get speed.
///
/// The web is the exception: emscripten owns the wasm heap, so Zig's page
/// allocator - which grows wasm memory itself - fights it. emscripten's libc
/// malloc is the one that works there.
pub const gpa: std.mem.Allocator = if (on_web)
    std.heap.c_allocator
else if (leak_checks)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

/// Shown in the About panel. Comes from build.zig.zon.
pub const version = build_info.version;

/// A large real file for the web demo, from a mirror that sends CORS headers.
const sqlite_url = "https://cdn.jsdelivr.net/gh/gittiver/sqlite3-amalgamation@master/src/sqlite3/sqlite3.c";
const welcome_data = @embedFile("welcome_data");

/// True for the web build, which has no filesystem and no child processes.
pub const on_web = web.on_web;

/// Zig 0.16 does all file access through an `Io`. Null where there is none.
pub var io: ?std.Io = null;

/// What `main` hands over. The web build supplies neither `io` nor `env`.
pub const Start = struct {
    args: std.process.Args,
    io: ?std.Io = null,
    env: ?*const std.process.Environ.Map = null,
};

pub var config = config_mod.Config{};
pub var font = Font{};
pub var editor = Editor{};
pub var window = Window{};
pub var buffer = Buffer{};
pub var input = Input{};
pub var prompt = Prompt{};
pub var recent = Recent{ .file_name = "recent" };
pub var recent_folders = Recent{ .file_name = "recent-folders" };
pub var menu = Menu{};
pub var browser = Browser{};
pub var update = Update{};
pub var find = Find{};
pub var dialog = Dialog{};
pub var notice = Notice{};
pub var file_dialog = FileDialog{};
pub var workspace = Workspace{ .gpa = gpa, .on_listed = native.wake };
pub var sidebar = Sidebar{ .gpa = gpa };
pub var folder_search = FolderSearch{ .gpa = gpa, .on_found = native.wake };
pub var graph = GraphView.init(gpa);
pub var settings = Settings{};

/// Where the settings file lives, once it is known. Owned.
pub var config_path: ?[]const u8 = null;
/// Where the session, recent files and logs live. Null where there is none.
pub var data_dir: ?[]const u8 = null;

var artifacts: std.ArrayList(Artifact) = .empty;

pub fn run(start: Start) !void {
    // Declared first so it runs last, once everything else has been freed.
    defer if (leak_checks and !on_web) {
        if (debug_allocator.deinit() == .leak) std.debug.print("memory leak detected\n", .{});
    };

    io = start.io;
    buffer.gpa = gpa;
    buffer.io = start.io;
    prompt.gpa = gpa;
    defer prompt.deinit();
    recent.gpa = gpa;
    defer recent.deinit();
    recent_folders.gpa = gpa;
    defer recent_folders.deinit();
    browser.gpa = gpa;
    defer browser.deinit();
    find.gpa = gpa;
    defer find.deinit();
    defer workspace.deinit();
    defer sidebar.deinit();
    defer folder_search.deinit();
    defer graph.deinit();
    defer if (config_path) |p| gpa.free(p);

    const config_failure = loadConfig(start);
    theme.apply(config.colors());

    data_dir = if (start.env) |env| try paths.dataDir(gpa, env) else null;
    defer if (data_dir) |d| gpa.free(d);
    // Before the window opens, so it opens at the saved size and zoom.
    const session_dir = if (data_dir) |d| try std.fs.path.join(gpa, &.{ d, session.dir_name }) else null;
    defer if (session_dir) |d| gpa.free(d);
    const last = lastExtras(session_dir);
    font.base = config.font_size;
    font.size = std.math.clamp(config.font_size + last.zoom, Font.min_size, Font.max_size);
    window.restoreTo(last.window);
    if (start.env) |env| window.startup_id = env.get("DESKTOP_STARTUP_ID");

    defer artifacts.deinit(gpa);
    try artifacts.appendSlice(gpa, &.{
        editor.artifact(),
        window.artifact(),
        buffer.artifact(),
        input.artifact(),
    });

    // Torn down in reverse, and only those that started.
    var started: usize = 0;
    defer while (started > 0) {
        started -= 1;
        artifacts.items[started].deinit();
    };
    for (artifacts.items) |a| {
        try a.init();
        started += 1;
    }

    // After the window exists, because the glyph atlas is a GPU texture, and
    // released before the window closes for the same reason.
    font.density = window_mod.density();
    try font.load();
    defer font.unload();

    var crashed_last_time = false;
    if (data_dir) |d| {
        update.log.setDir(d);
        if (io) |active_io| {
            recent.load(active_io, d) catch {};
            recent_folders.load(active_io, d) catch {};
            crash.setUp(active_io, d, version);
            crashed_last_time = crash.takeNew(active_io, d);
        }
    }

    try openStartingBuffers(start, session_dir);
    if (config_failure) |err| commands.report("Could not read " ++ config_mod.file_name, err);
    if (config.problem) |problem| {
        commands.tell(.problem, "{s} line {d}: {s}", .{ config_mod.file_name, problem.line, problem.why });
    }
    if (crashed_last_time) commands.tell(.problem, "Zimacs crashed last time. Help > Report a Problem sends the details.", .{});

    if (io) |active_io| if (start.env) |env| file_dialog.setUp(active_io, env);
    defer file_dialog.close();
    commands.removeUpdateLeftovers();
    if (io) |active_io| idle.start(active_io);
    defer idle.stop();

    defer if (data_dir) |d| if (io) |active_io| {
        recent.save(active_io, d) catch {};
        recent_folders.save(active_io, d) catch {};
    };

    // Registered last so it runs first, while the buffers still exist.
    defer if (session_dir) |d| saveSession(d);
    autosave.markSaved(&buffer, currentExtras());

    while (!window.shouldClose()) {
        if (session_dir) |d| if (autosave.due(pen.getTime(), &buffer, currentExtras())) saveSession(d);
        if (disk_watch.due(pen.getTime())) {
            commands.checkDisk();
            refreshSidebar();
        }
        if (update_schedule.due(pen.getTime(), &update)) commands.updateInBackground();
        if (file_dialog.take()) |outcome| commands.finishFileDialog(outcome);
        if (workspace.poll()) commands.folderListed();
        if (graph.wantsRescan(pen.getTime())) if (io) |active_io| workspace.refresh(active_io);
        graph.tick() catch |err| reportFrameError("Graph", err);
        if (folder_search.poll()) commands.folderSearched();
        // Before drawing, because resizing the canvas clears it.
        window_mod.fitToCanvas();
        // Before drawing too: the atlas cannot change under a frame using it.
        font.setDensity(window_mod.density());
        font.refresh() catch |err| reportFrameError("Font", err);

        pen.beginDrawing();
        defer pen.endDrawing();
        pen.clearBackground(theme.current.background);
        for (artifacts.items) |a| a.render() catch |err| reportFrameError(a.name, err);
        idle.pace();
    }
}

var autosave = session.Autosave{};
/// How often files are checked for changes made by other programs.
var disk_watch = Interval{ .seconds = 2 };
var update_schedule = update_mod.Schedule{};

fn lastExtras(session_dir: ?[]const u8) session.Extras {
    const d = session_dir orelse return .{};
    const active_io = io orelse return .{};
    return session.readExtras(active_io, gpa, d);
}

fn currentExtras() session.Extras {
    return .{ .zoom = font.zoom(), .window = window.placement(), .folder = workspace.root };
}

fn saveSession(d: []const u8) void {
    const active_io = io orelse return;
    const extras = currentExtras();
    session.save(&buffer, extras, active_io, gpa, d) catch |err| {
        commands.report("Could not save the session", err);
        return;
    };
    autosave.markSaved(&buffer, extras);
}

/// Files named on the command line win; otherwise the last session comes
/// back; failing both, an empty buffer so there is always somewhere to type.
fn openStartingBuffers(start: Start, session_dir: ?[]const u8) !void {
    // The last session comes back first, so text it holds unsaved is not
    // lost to a file named on the command line; those open on top.
    if (config.restore_session) if (session_dir) |dir| if (io) |active_io| {
        _ = session.restore(&buffer, active_io, gpa, dir) catch false;
        if (session.readFolder(active_io, gpa, dir)) |folder| {
            defer gpa.free(folder);
            openFolder(folder) catch {};
        }
    };

    // iterateAllocator rather than iterate: on Windows the plain one refuses,
    // because the command line has to be decoded from WTF-16 first.
    var args = try start.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // program name
    while (args.next()) |path| {
        openPath(path) catch |err| commands.tell(.problem, "Could not open {s}: {s}", .{ path, @errorName(err) });
    }
    if (buffer.views.items.len > 0) return;

    // The web build has no files or session, so it opens a welcome text.
    // Elsewhere, with nothing to open, the empty screen offers what to do.
    if (on_web) {
        _ = try buffer.newFilled("welcome.txt", welcome_data);
        web.fetch(sqlite_url, sqliteArrived);
    }
}

fn sqliteArrived(bytes: []const u8) void {
    // Opening a tab selects it; keep the one being read in front.
    const was_active = buffer.active;
    _ = buffer.newFilled("sqlite3.c", bytes) catch return;
    buffer.active = was_active;
}

/// A failure while drawing must not take the whole editor down, and on the
/// web it has to be said out loud: `std.debug` cannot print there, so an
/// error returned out of the frame loop would vanish without trace.
fn reportFrameError(who: []const u8, err: anyerror) void {
    if (on_web) {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "Zimacs: {s} failed: {s}", .{ who, @errorName(err) }) catch
            "Zimacs: render failed";
        web.consoleError(text);
    } else {
        std.debug.print("{s} failed: {s}\n", .{ who, @errorName(err) });
        commands.report(who, err);
    }
}

/// Opens a file and remembers it. Every way of opening goes through here so
/// the recent list cannot drift out of date.
/// A folder becomes the project, and a file opens in a tab.
pub fn openPath(path: []const u8) !void {
    const active_io = io orelse return openFile(path);
    const st = std.Io.Dir.cwd().statFile(active_io, path, .{}) catch return openFile(path);
    if (st.kind == .directory) return openFolder(path);
    return openFile(path);
}

pub fn openFolder(path: []const u8) !void {
    try workspace.open(io orelse return error.NoFilesystem, path);
    if (workspace.root) |root| recent_folders.add(root) catch {};
    folder_search.stop();
    sidebar.forget();
    sidebar.shown = true;
    refreshSidebar();
}

pub fn closeFolder() void {
    graph.hide();
    folder_search.stop();
    workspace.close();
    sidebar.forget();
}

/// Reads the folder tree again, so it shows files made or removed since.
pub fn refreshSidebar() void {
    const root = workspace.root orelse return;
    if (!sidebar.shown) return;
    sidebar.refresh(io orelse return, root);
}

pub fn openFile(path: []const u8) !void {
    try buffer.openOrSelect(path);
    graph.hide();
    // As the buffer stored it: absolute, so it means the same file later.
    if (buffer.current()) |view| if (view.path) |stored| recent.add(stored) catch {};
}

/// The settings file, read into `config`. Returns why it could not be read,
/// other than not existing yet.
fn loadConfig(start: Start) ?anyerror {
    const active_io = start.io orelse return null;
    const env = start.env orelse return null;
    const dir = (paths.configDir(gpa, env) catch |err| return err) orelse return null;
    defer gpa.free(dir);

    const file = std.fs.path.join(gpa, &.{ dir, config_mod.file_name }) catch |err| return err;
    config_path = file;

    const text = std.Io.Dir.cwd().readFileAlloc(active_io, file, gpa, .limited(config_mod.max_bytes)) catch |err| {
        if (err != error.FileNotFound) return err;
        // No config yet: leave one behind so it is easy to find and edit.
        config_mod.Config.writeDefault(active_io, dir) catch {};
        return null;
    };
    defer gpa.free(text);
    config.applyText(text);
    return null;
}
