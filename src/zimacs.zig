//* Zimacs *//
const std = @import("std");

pub const pen = @import("raylib");
pub const gfx = @import("./core/gfx.zig");
pub const Window = @import("./core/window.zig").Window;
pub const Editor = @import("./core/editor.zig").Editor;

pub const thread = std.Thread;
pub const print = std.debug.print;

pub const ZiError = anyerror;

pub const User = struct {
    name: []const u8,
};

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
    //TODO : change the  font
    font: pen.Font = undefined,

    pub fn init() Setting {
        return Setting{
            .frames = 60,
            // .font = pen.getFontDefault(),
        };
    }
};

pub var editor = Editor{};
pub var settings = Setting.init();
pub var window = Window{};
pub var artifacts = std.ArrayList(Artifact).init(std.heap.page_allocator);

pub fn init() ZiError!void {
    print("Running Zimacs ... \n", .{});

    try artifacts.append(editor.artifact());
    try artifacts.append(window.artifact());

    for (artifacts.items) |*artifact| {
        try Artifact.init(artifact.*);
    }

    while (!pen.windowShouldClose()) {
        pen.beginDrawing();
        defer pen.endDrawing();
        defer pen.clearBackground(pen.Color.black);
        try renderArtifacts(&artifacts);
    }
}

fn renderArtifacts(coreArtifacts: *std.ArrayList(Artifact)) ZiError!void {
    if (coreArtifacts.items.len == 0) {
        return;
    }
    // Spawn a thread for each artifact
    var threadHandles = std.StringHashMap(std.Thread).init(std.heap.page_allocator);
    defer threadHandles.deinit();

    for (coreArtifacts.items) |*artifact| {
        // Create a closure to pass to the thread
        const t = try std.Thread.spawn(.{}, threadFunc, .{artifact});
        try threadHandles.put(artifact.*.name, t);
    }

    // Join all threads after spawning
    var mapIt = threadHandles.iterator();
    while (mapIt.next()) |entry| {
        // print("Joining thread for artifact: {s}\n", .{entry.key_ptr.*});
        // Wait for each thread to complete its execution
        entry.value_ptr.*.join();
    }
}

// Define the thread function that will call artifact.initialize
fn threadFunc(artifact: *Artifact) !void {
    // print("Running Artifact {s}", .{artifact.*.name});
    try artifact.*.render();
}
