//* Zimacs *//
const std = @import("std");
const stdx = @import("./stdx/stdx.zig");
pub const pen = @import("raylib");
pub const gui = @import("raygui");
pub const gfx = @import("./core/gfx.zig");
pub const Window = @import("./core/window.zig").Window;
pub const Editor = @import("./core/editor.zig").Editor;
pub const Buffer = @import("./core/buffer.zig").Buffer;

pub const thread = std.Thread;
pub const print = std.debug.print;

pub const ZiError = anyerror;

pub const User = struct {
    name: []const u8,
};

pub const gpa = std.heap.page_allocator;

pub const Artifact = struct {
    ctx: *anyopaque,
    vTable: *const VTable,

    name: []const u8,
    artifactType: []const u8 = "core",
    version: []const u8 = "0.1",

    //* We need to make a vTable for runtime polymorphism *//

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque) ZiError!void,
        deinit: *const fn (ctx: *anyopaque) ZiError!void,
        render: *const fn (ctx: *anyopaque) ZiError!void,
    };

    pub fn init(artifact: Artifact) ZiError!void {
        return artifact.vTable.init(artifact.ctx);
    }

    pub fn deinit(artifact: Artifact) ZiError!void {
        return artifact.vTable.deinit(artifact.ctx);
    }

    pub fn render(artifact: Artifact) ZiError!void {
        return artifact.vTable.render(artifact.ctx);
    }
};

pub const Info = struct {
    platform: []const u8 = "linux",
    version: []const u8 = "0.1",
    license: []const u8 = "MIT",
};

pub const Setting = struct {
    frames: i32 = 60,
    fontSize: f32 = 18,
    spacing: f32 = 0,
    font: pen.Font = undefined,
    defaultFontName: []const u8 = "jetbrainsmono.ttf",
    defaultFontPath: []const u8 = "C:/zigging/assets/font/JetBrainsMono-Medium.ttf.ttf",

    const Self = @This();

    pub fn init(s: *Self) !void {
        try s.loadFont();
    }

    pub fn loadFont(s: *Self) !void {
        var fontFile = try std.fs.openFileAbsolute(s.defaultFontPath, .{});
        defer fontFile.close();
        const fontBuffer = try fontFile.readToEndAlloc(gpa, 1024 * 1024 * 1024);
        const myFont = pen.loadFontFromMemory(".ttf", fontBuffer, @intFromFloat(s.fontSize), null);
        gui.guiSetFont(myFont);
        while (!pen.isFontReady(myFont)) {
            print("Loading font\n", .{});
        }
        print("Font loaded {}", .{pen.isFontReady(myFont)});
        s.font = myFont;
    }
};

pub var settings = Setting{};
pub var editor = Editor{};
pub var window = Window{};
pub var buffer = Buffer{};
pub var artifacts = std.ArrayList(Artifact).init(gpa);

pub fn init() ZiError!void {
    print("Initializing Zimacs\n", .{});

    artifacts.append(editor.artifact()) catch unreachable;
    artifacts.append(window.artifact()) catch unreachable;
    artifacts.append(buffer.artifact()) catch unreachable;

    for (artifacts.items) |*artifact| {
        try Artifact.init(artifact.*);
    }

    // var threadHandles = std.StringHashMap(std.Thread).init(gpa);
    // defer threadHandles.deinit();

    try settings.init();

    while (!pen.windowShouldClose()) {
        pen.beginDrawing();
        defer pen.endDrawing();
        pen.clearBackground(pen.Color.black);
        try renderArtifactsLinearly(&artifacts);
        // Raylib use OpenGL , Which needs main thread to render
        // try renderArtifactsConcurrently(&artifacts, &threadHandles);
    }
}

fn renderArtifactsConcurrently(coreArtifacts: *std.ArrayList(Artifact), threadHandles: *std.StringHashMap(std.Thread)) ZiError!void {
    if (coreArtifacts.items.len == 0) {
        return;
    }

    for (coreArtifacts.items) |*artifact| {
        const t = try std.Thread.spawn(.{}, threadFunc, .{artifact});
        try threadHandles.put(artifact.*.name, t);
    }

    var mapIt = threadHandles.iterator();
    while (mapIt.next()) |entry| {
        // print("Joining thread for artifact: {s}\n", .{entry.key_ptr.*});
        entry.value_ptr.join();
    }
}

fn renderArtifactsLinearly(coreArtifacts: *std.ArrayList(Artifact)) ZiError!void {
    if (coreArtifacts.items.len == 0) {
        return;
    }
    for (coreArtifacts.items) |*artifact| {
        try artifact.*.render();
    }
}

// Define the thread function that will call artifact.initialize
fn threadFunc(artifact: *Artifact) !void {
    // print("Running Artifact {s}", .{artifact.*.name});
    try artifact.*.render();
}
