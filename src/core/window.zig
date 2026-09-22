//! The OS window: opening it, tracking its size, and accepting dropped files.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const Artifact = @import("artifact.zig").Artifact;

const icon_data = @embedFile("icon_data");

/// The page's own idea of how big the canvas is, and how many real pixels
/// each of its pixels covers.
extern fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;
extern fn emscripten_get_device_pixel_ratio() f64;

pub const Window = struct {
    title: [:0]const u8 = "Zimacs",
    width: i32 = 800,
    height: i32 = 450,
    target_fps: i32 = 165,

    const Self = @This();

    const table = Artifact.Table{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(w: *Self) Artifact {
        return .{ .ctx = @ptrCast(w), .table = &table, .name = "Window" };
    }

    pub fn init(ctx: *anyopaque) !void {
        const w: *Self = @ptrCast(@alignCast(ctx));
        // High-DPI is left off on the web: `fitToCanvas` already sizes the
        // buffer to the display's real pixels, and letting raylib scale as
        // well makes its screen size half the render size - which silently
        // breaks scissor rectangles, since those flip y using the screen size.
        pen.setConfigFlags(.{
            .window_resizable = true,
            .window_highdpi = !app.on_web,
        });
        pen.initWindow(w.width, w.height, w.title);
        pen.setTargetFPS(w.target_fps);
        // raylib closes the window on Escape by default, which is no good in
        // an editor. Close via the title bar instead.
        pen.setExitKey(.null);
        setIcon();
    }

    pub fn deinit(ctx: *anyopaque) !void {
        _ = ctx;
        pen.closeWindow();
    }

    pub fn render(ctx: *anyopaque) !void {
        const w: *Self = @ptrCast(@alignCast(ctx));
        if (pen.isWindowResized()) {
            w.width = pen.getRenderWidth();
            w.height = pen.getRenderHeight();
        }
        openDroppedFiles();
    }
};

/// Matches the drawing buffer to the canvas, at the display's real pixel
/// density.
///
/// The page stretches the canvas to fill the window with CSS, but the buffer
/// raylib made is whatever `initWindow` asked for. Left alone the browser
/// scales that small buffer up, which is why text looks soft. Sizing the
/// buffer to the CSS size times the device pixel ratio gives one buffer pixel
/// per screen pixel.
///
/// Must run before `beginDrawing`: resizing throws away the framebuffer, so
/// doing it mid-frame would discard everything already drawn.
pub fn fitToCanvas() void {
    if (!app.on_web) return;

    var css_width: f64 = 0;
    var css_height: f64 = 0;
    if (emscripten_get_element_css_size("#canvas", &css_width, &css_height) != 0) return;

    const density = emscripten_get_device_pixel_ratio();
    const want_width: i32 = @intFromFloat(@round(css_width * density));
    const want_height: i32 = @intFromFloat(@round(css_height * density));
    if (want_width <= 0 or want_height <= 0) return;

    if (want_width != pen.getRenderWidth() or want_height != pen.getRenderHeight()) {
        pen.setWindowSize(want_width, want_height);
    }
}

/// The window manager keeps its own copy, so ours is freed straight away.
fn setIcon() void {
    const image = pen.loadImageFromMemory(".png", icon_data) catch return;
    defer pen.unloadImage(image);
    pen.setWindowIcon(image);
}

fn openDroppedFiles() void {
    if (!pen.isFileDropped()) return;

    const dropped = pen.loadDroppedFiles();
    // raylib owns this list until it is handed back.
    defer pen.unloadDroppedFiles(dropped);

    for (0..dropped.count) |i| {
        const path: [:0]const u8 = std.mem.span(dropped.paths[i]);
        app.openFile(path) catch |err| {
            std.debug.print("Could not open {s}: {s}\n", .{ path, @errorName(err) });
        };
    }
}
