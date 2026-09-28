//! The system's own Open and Save dialogs. Windows shows its common dialogs;
//! Linux runs zenity or kdialog, whichever is installed, on a thread of its
//! own so the editor keeps drawing. Where there is neither, `show` says so
//! and the caller falls back to the built-in browser.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");

pub const Kind = enum { open, save };

pub const Request = struct {
    kind: Kind,
    /// Where the dialog starts.
    dir: []const u8,
    /// For saving, the name it offers.
    name: []const u8 = "",
};

/// What a finished dialog chose. `path` is null when it was cancelled, and
/// owned by the caller otherwise.
pub const Outcome = struct {
    kind: Kind,
    path: ?[]u8,
};

/// The Linux programs that draw a native dialog, in the order they are tried.
pub const Tool = enum { zenity, kdialog };

pub const Dialog = struct {
    state: std.atomic.Value(State) = .init(.idle),
    kind: Kind = .open,
    /// Written before `state` becomes `done`.
    path: ?[]u8 = null,
    tool: ?Tool = null,
    /// The Linux tool's process while it runs, 0 otherwise, so closing the
    /// editor can close the dialog too.
    child: std.atomic.Value(i32) = .init(0),

    const State = enum(u8) { idle, showing, done };

    /// Picks the Linux tool once, from what is on `PATH`, preferring
    /// kdialog on KDE.
    pub fn setUp(d: *Dialog, io: std.Io, env: *const std.process.Environ.Map) void {
        if (builtin.os.tag != .linux) return;
        const on_kde = if (env.get("XDG_CURRENT_DESKTOP")) |desktop| std.mem.indexOf(u8, desktop, "KDE") != null else false;
        const order: []const Tool = if (on_kde) &.{ .kdialog, .zenity } else &.{ .zenity, .kdialog };
        const search = env.get("PATH") orelse return;
        for (order) |tool| {
            if (onPath(io, search, @tagName(tool))) {
                d.tool = tool;
                return;
            }
        }
    }

    pub fn showing(d: *const Dialog) bool {
        return d.state.load(.acquire) == .showing;
    }

    pub const Shown = enum {
        shown,
        /// Another dialog is still open, and is left to finish.
        busy,
        /// The system has none, so the caller uses the built-in browser.
        unavailable,
    };

    pub fn show(d: *Dialog, gpa: std.mem.Allocator, io: ?std.Io, req: Request) Shown {
        if (d.showing()) return .busy;
        const active_io = io orelse return .unavailable;
        // GTK starts a relative folder one level up, with it selected.
        const here = std.process.currentPathAlloc(active_io, gpa) catch return .unavailable;
        defer gpa.free(here);
        const dir = std.fs.path.resolve(gpa, &.{ here, req.dir }) catch return .unavailable;
        defer gpa.free(dir);
        var absolute = req;
        absolute.dir = dir;

        switch (builtin.os.tag) {
            .windows => {
                d.kind = req.kind;
                d.path = win32.pick(gpa, absolute) catch null;
                d.state.store(.done, .release);
                return .shown;
            },
            .linux => {
                const tool = d.tool orelse return .unavailable;
                const argv = arguments(gpa, tool, absolute) catch return .unavailable;
                d.kind = req.kind;
                d.state.store(.showing, .release);
                const thread = std.Thread.spawn(.{}, run, .{ d, gpa, active_io, argv }) catch {
                    freeArguments(gpa, argv);
                    d.state.store(.idle, .release);
                    return .unavailable;
                };
                thread.detach();
                return .shown;
            },
            else => return .unavailable,
        }
    }

    /// The outcome once the dialog has closed, exactly once.
    pub fn take(d: *Dialog) ?Outcome {
        if (d.state.load(.acquire) != .done) return null;
        const outcome = Outcome{ .kind = d.kind, .path = d.path };
        d.path = null;
        d.state.store(.idle, .release);
        return outcome;
    }

    /// Ends a dialog still open, which would otherwise outlive the editor.
    pub fn close(d: *Dialog) void {
        if (builtin.os.tag != .linux) return;
        const pid = d.child.load(.acquire);
        if (pid != 0) std.posix.kill(pid, .TERM) catch {};
    }

    fn run(d: *Dialog, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
        defer freeArguments(gpa, argv);
        d.path = d.runTool(gpa, io, argv) catch null;
        d.state.store(.done, .release);
        wake();
    }

    fn runTool(d: *Dialog, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
        var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
        d.child.store(child.id.?, .release);
        defer d.child.store(0, .release);

        var buf: [256]u8 = undefined;
        var reader = child.stdout.?.reader(io, &buf);
        const out = reader.interface.allocRemaining(gpa, .limited(std.Io.Dir.max_path_bytes)) catch |err| {
            child.kill(io);
            return err;
        };
        defer gpa.free(out);
        // Both tools exit with 1 on cancel; anything but 0 is not a choice.
        const chosen = switch (try child.wait(io)) {
            .exited => |code| code == 0,
            else => false,
        };
        const path = std.mem.trimEnd(u8, out, "\r\n");
        if (!chosen or path.len == 0) return null;
        return try gpa.dupe(u8, path);
    }
};

extern fn glfwPostEmptyEvent() void;

/// The editor may be waiting for an event; this is one.
fn wake() void {
    if (builtin.os.tag != .emscripten) glfwPostEmptyEvent();
}

/// The command line for `tool`. Caller frees with `freeArguments`.
pub fn arguments(gpa: std.mem.Allocator, tool: Tool, req: Request) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| gpa.free(arg);
        list.deinit(gpa);
    }
    const start = try std.fs.path.join(gpa, &.{ req.dir, req.name });
    defer gpa.free(start);
    // A trailing separator makes a bare directory open inside it.
    const sep = if (req.name.len == 0) "/" else "";

    switch (tool) {
        .zenity => {
            try list.append(gpa, try gpa.dupe(u8, "zenity"));
            try list.append(gpa, try gpa.dupe(u8, "--file-selection"));
            if (req.kind == .save) {
                try list.append(gpa, try gpa.dupe(u8, "--save"));
                // Needed before zenity 4, which always asks.
                try list.append(gpa, try gpa.dupe(u8, "--confirm-overwrite"));
            }
            try list.append(gpa, try std.fmt.allocPrint(gpa, "--title={s}", .{title(req.kind)}));
            try list.append(gpa, try std.fmt.allocPrint(gpa, "--filename={s}{s}", .{ start, sep }));
        },
        .kdialog => {
            try list.append(gpa, try gpa.dupe(u8, "kdialog"));
            try list.append(gpa, try gpa.dupe(u8, if (req.kind == .save) "--getsavefilename" else "--getopenfilename"));
            try list.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ start, sep }));
            try list.append(gpa, try gpa.dupe(u8, "--title"));
            try list.append(gpa, try gpa.dupe(u8, title(req.kind)));
        },
    }
    return list.toOwnedSlice(gpa);
}

pub fn freeArguments(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| gpa.free(arg);
    gpa.free(argv);
}

fn title(kind: Kind) []const u8 {
    return switch (kind) {
        .open => "Open File",
        .save => "Save As",
    };
}

fn onPath(io: std.Io, search: []const u8, name: []const u8) bool {
    var dirs = std.mem.tokenizeScalar(u8, search, ':');
    while (dirs.next()) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        _ = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

const win32 = struct {
    const OPENFILENAMEW = extern struct {
        lStructSize: u32 = @sizeOf(OPENFILENAMEW),
        hwndOwner: ?*anyopaque = null,
        hInstance: ?*anyopaque = null,
        lpstrFilter: ?[*:0]const u16 = null,
        lpstrCustomFilter: ?[*]u16 = null,
        nMaxCustFilter: u32 = 0,
        nFilterIndex: u32 = 0,
        lpstrFile: [*]u16,
        nMaxFile: u32,
        lpstrFileTitle: ?[*]u16 = null,
        nMaxFileTitle: u32 = 0,
        lpstrInitialDir: ?[*:0]const u16 = null,
        lpstrTitle: ?[*:0]const u16 = null,
        Flags: u32 = 0,
        nFileOffset: u16 = 0,
        nFileExtension: u16 = 0,
        lpstrDefExt: ?[*:0]const u16 = null,
        lCustData: isize = 0,
        lpfnHook: ?*anyopaque = null,
        lpTemplateName: ?[*:0]const u16 = null,
        pvReserved: ?*anyopaque = null,
        dwReserved: u32 = 0,
        FlagsEx: u32 = 0,
    };

    const OFN_OVERWRITEPROMPT: u32 = 0x2;
    const OFN_NOCHANGEDIR: u32 = 0x8;
    const OFN_PATHMUSTEXIST: u32 = 0x800;
    const OFN_FILEMUSTEXIST: u32 = 0x1000;
    const OFN_EXPLORER: u32 = 0x80000;

    extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) c_int;
    extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) c_int;

    /// Modal, as on every Windows program: it returns once closed.
    fn pick(gpa: std.mem.Allocator, req: Request) !?[]u8 {
        var file: [std.os.windows.PATH_MAX_WIDE:0]u16 = @splat(0);
        const offered = try std.unicode.wtf8ToWtf16Le(&file, req.name);
        file[offered] = 0;
        const dir = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, req.dir);
        defer gpa.free(dir);
        const heading = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, title(req.kind));
        defer gpa.free(heading);
        const filter = std.unicode.utf8ToUtf16LeStringLiteral("All files\x00*.*\x00");

        var ofn = OPENFILENAMEW{
            .hwndOwner = pen.getWindowHandle(),
            .lpstrFilter = filter,
            .lpstrFile = &file,
            .nMaxFile = @intCast(file.len),
            .lpstrInitialDir = dir,
            .lpstrTitle = heading,
            .Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
                (if (req.kind == .save) OFN_OVERWRITEPROMPT else OFN_FILEMUSTEXIST),
        };
        const chosen = switch (req.kind) {
            .open => GetOpenFileNameW(&ofn),
            .save => GetSaveFileNameW(&ofn),
        };
        if (chosen == 0) return null;
        const len = std.mem.indexOfScalar(u16, &file, 0) orelse file.len;
        return try std.unicode.wtf16LeToWtf8Alloc(gpa, file[0..len]);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectArguments(expected: []const []const u8, tool: Tool, req: Request) !void {
    const argv = try arguments(testing.allocator, tool, req);
    defer freeArguments(testing.allocator, argv);
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "zenity opens in the directory and saves with the name offered" {
    try expectArguments(&.{ "zenity", "--file-selection", "--title=Open File", "--filename=/home/me/code/" }, .zenity, .{ .kind = .open, .dir = "/home/me/code" });
    try expectArguments(&.{ "zenity", "--file-selection", "--save", "--confirm-overwrite", "--title=Save As", "--filename=/home/me/notes.txt" }, .zenity, .{ .kind = .save, .dir = "/home/me", .name = "notes.txt" });
}

test "kdialog gets the same start point" {
    try expectArguments(&.{ "kdialog", "--getopenfilename", "/home/me/code/", "--title", "Open File" }, .kdialog, .{ .kind = .open, .dir = "/home/me/code" });
    try expectArguments(&.{ "kdialog", "--getsavefilename", "/home/me/notes.txt", "--title", "Save As" }, .kdialog, .{ .kind = .save, .dir = "/home/me", .name = "notes.txt" });
}

test "an outcome is handed over once" {
    var d = Dialog{};
    try testing.expect(d.take() == null);
    d.kind = .save;
    d.path = try testing.allocator.dupe(u8, "/tmp/x");
    d.state.store(.done, .release);
    const got = d.take().?;
    defer testing.allocator.free(got.path.?);
    try testing.expectEqual(Kind.save, got.kind);
    try testing.expect(d.take() == null);
}
