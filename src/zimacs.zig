//! Zimacs: the application itself.
//!
//! Holds the state every part of the editor reaches for, and runs the main
//! loop. Each component is an `Artifact` in one list: set up in order,
//! rendered in order every frame, torn down in reverse.
//!
//! Render order matters. Input runs last, so a key pressed this frame is acted
//! on at the start of the next one.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");

const build_info = @import("build_info");
const commands = @import("core/commands.zig");
const config_mod = @import("core/config.zig");
const paths = @import("core/paths.zig");
const recent_mod = @import("core/recent.zig");
const session = @import("core/session.zig");
const web = @import("core/web.zig");

/// The SQLite amalgamation, from a mirror that serves it with CORS headers,
/// which sqlite.org itself does not.
const sqlite_url = "https://cdn.jsdelivr.net/gh/gittiver/sqlite3-amalgamation@master/src/sqlite3/sqlite3.c";
const welcome_data = @embedFile("welcome_data");
const update_mod = @import("core/update.zig");
const theme = @import("core/theme.zig");
const window_mod = @import("core/window.zig");

pub const Artifact = @import("core/artifact.zig").Artifact;
pub const Buffer = @import("core/buffer.zig").Buffer;
pub const Editor = @import("core/editor.zig").Editor;
pub const Font = @import("core/font.zig").Font;
pub const Input = @import("core/input.zig").Input;
pub const Menu = @import("core/menu.zig").Menu;
pub const Prompt = @import("core/prompt.zig").Prompt;
pub const Recent = recent_mod.Recent;
pub const Browser = @import("core/browser.zig").Browser;
pub const Update = update_mod.Update;
pub const Window = @import("core/window.zig").Window;

const leak_checks = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
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

/// True for the web build, which has no filesystem and no child processes.
pub const on_web = builtin.os.tag == .emscripten;

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
pub var recent = Recent{};
pub var menu = Menu{};
pub var browser = Browser{};
pub var update = Update{};

/// Where the settings file lives, once it is known. Owned.
pub var config_path: ?[]const u8 = null;

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
    browser.gpa = gpa;
    defer browser.deinit();
    defer commands.deinit();
    defer if (config_path) |p| gpa.free(p);

    loadConfig(start);
    theme.apply(config.colors);
    font.size = config.font_size;

    defer artifacts.deinit(gpa);
    try artifacts.appendSlice(gpa, &.{
        editor.artifact(),
        window.artifact(),
        buffer.artifact(),
        input.artifact(),
    });

    for (artifacts.items) |a| try a.init();
    defer for (artifacts.items) |a| {
        a.deinit() catch {};
    };

    // After the window exists, because the glyph atlas is a GPU texture, and
    // released before the window closes for the same reason.
    try font.load();
    defer font.unload();

    const session_dir = try sessionDir(start);
    defer if (session_dir) |d| gpa.free(d);

    const data_dir = try dataDir(start);
    defer if (data_dir) |d| gpa.free(d);
    if (data_dir) |d| if (io) |active_io| recent.load(active_io, d) catch {};

    try openStartingBuffers(start, session_dir);

    defer if (data_dir) |d| if (io) |active_io| {
        recent.save(active_io, d) catch {};
    };

    // Registered last so it runs first, while the buffers still exist.
    defer if (session_dir) |d| if (io) |active_io| {
        session.save(&buffer, active_io, gpa, d) catch |err| {
            std.debug.print("Could not save session: {s}\n", .{@errorName(err)});
        };
    };

    while (!window.shouldClose()) {
        // Before drawing, because resizing the canvas clears it.
        window_mod.fitToCanvas();

        pen.beginDrawing();
        defer pen.endDrawing();
        pen.clearBackground(theme.current.background);
        for (artifacts.items) |a| a.render() catch |err| reportFrameError(a.name, err);
    }
}

/// Files named on the command line win; otherwise the last session comes
/// back; failing both, an empty buffer so there is always somewhere to type.
fn openStartingBuffers(start: Start, session_dir: ?[]const u8) !void {
    // iterateAllocator rather than iterate: on Windows the plain one refuses,
    // because the command line has to be decoded from WTF-16 first.
    var args = try start.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // program name
    var opened: usize = 0;
    while (args.next()) |path| {
        openFile(path) catch |err| {
            std.debug.print("Could not open {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        opened += 1;
    }
    if (opened > 0) return;

    if (config.restore_session) if (session_dir) |dir| if (io) |active_io| {
        const restored = session.restore(&buffer, active_io, gpa, dir) catch false;
        if (restored) return;
    };

    // A page has no files and no session, so an empty buffer would leave a
    // visitor staring at nothing. Give the web build something to poke at.
    if (on_web) {
        _ = try buffer.newFilled("welcome.txt", welcome_data);
        // Fetched from a CDN rather than served by us: it is nine megabytes
        // of someone else's source and has no business in this repository.
        // It arrives in the background, so the editor is usable immediately.
        web.fetch(sqlite_url, sqliteArrived);
        return;
    }

    _ = try buffer.newScratch();
}

/// The demo's second tab: a real 9 MB file, so the piece tree is doing
/// something more convincing than holding a paragraph of welcome text.
fn sqliteArrived(bytes: []const u8) void {
    // Opening a tab selects it, and yanking the view out from under someone
    // mid-sentence is rude, so put the selection back where it was.
    const was_active = buffer.active;
    _ = buffer.newFilled("sqlite3.c", bytes) catch return;
    buffer.active = was_active;
}

extern fn emscripten_console_error(text: [*:0]const u8) void;

/// A failure while drawing must not take the whole editor down, and on the
/// web it has to be said out loud: `std.debug` cannot print there, so an
/// error returned out of the frame loop would vanish without trace.
fn reportFrameError(who: []const u8, err: anyerror) void {
    if (on_web) {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "Zimacs: {s} failed: {s}", .{ who, @errorName(err) }) catch
            "Zimacs: render failed";
        emscripten_console_error(text);
    } else {
        std.debug.print("{s} failed: {s}\n", .{ who, @errorName(err) });
    }
}

/// Opens a file and remembers it. Every way of opening goes through here so
/// the recent list cannot drift out of date.
pub fn openFile(path: []const u8) !void {
    try buffer.openOrSelect(path);
    recent.add(path) catch {};
}

fn loadConfig(start: Start) void {
    const active_io = start.io orelse return;
    const env = start.env orelse return;
    const dir = paths.configDir(gpa, env) catch return orelse return;
    defer gpa.free(dir);

    const file = std.fs.path.join(gpa, &.{ dir, config_mod.file_name }) catch return;
    config_path = file;

    const text = std.Io.Dir.cwd().readFileAlloc(active_io, file, gpa, .limited(1 << 20)) catch {
        // No config yet: leave one behind so it is easy to find and edit.
        config_mod.Config.writeDefault(active_io, dir) catch {};
        return;
    };
    defer gpa.free(text);
    config.applyText(text);
}

fn sessionDir(start: Start) !?[]u8 {
    const base = try dataDir(start) orelse return null;
    defer gpa.free(base);
    return try std.fs.path.join(gpa, &.{ base, session.dir_name });
}

fn dataDir(start: Start) !?[]u8 {
    const env = start.env orelse return null;
    return paths.dataDir(gpa, env);
}
