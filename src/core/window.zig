//! The OS window: opening it, tracking its size, accepting dropped files, and
//! moving and resizing it when Zimacs draws its own title bar.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const Artifact = @import("artifact.zig").Artifact;
const native = @import("native.zig");
const Edges = @import("titlebar.zig").Edges;

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
    /// True when the system frame is off and Zimacs draws the title bar.
    custom_frame: bool = false,
    /// Set by the close button, since there is no system one to press.
    close_requested: bool = false,
    /// A move or resize in progress, while the pointer is held.
    drag: ?Drag = null,

    const Self = @This();

    /// Everything a drag is measured against, captured at the press. All of
    /// it is in the window system's own units; see `cursorOnScreen`.
    const Drag = struct {
        /// Which edges are being pulled. None means the window is moving.
        edges: Edges,
        cursor: pen.Vector2,
        position: pen.Vector2,
        size: pen.Vector2,
    };

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
        // A page is already inside the browser's own window, so the web
        // build never has a frame of its own to replace.
        w.custom_frame = app.config.custom_titlebar and !app.on_web;
        pen.setConfigFlags(.{
            .window_resizable = true,
            .window_highdpi = !app.on_web,
            .window_undecorated = w.custom_frame,
        });
        // raylib reports every texture, shader and glyph atlas it creates.
        // Useful while working on it, noise for anyone just using it.
        if (builtin.mode != .Debug) pen.setTraceLogLevel(.warning);
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

    /// Whether the main loop should stop, from either kind of close button.
    pub fn shouldClose(w: *const Self) bool {
        return w.close_requested or pen.windowShouldClose();
    }

    pub fn minimize(_: *Self) void {
        pen.minimizeWindow();
    }

    pub fn toggleMaximize(_: *Self) void {
        if (pen.isWindowMaximized()) pen.restoreWindow() else pen.maximizeWindow();
    }

    /// Starts moving the window with the pointer.
    pub fn beginMove(w: *Self) void {
        // Dragging a maximised window pulls it back to its normal size first,
        // keeping the pointer at the same fraction of the way across it.
        if (pen.isWindowMaximized()) w.restoreUnderCursor();

        w.beginDrag(.{});
    }

    pub fn beginResize(w: *Self, edges: Edges) void {
        if (pen.isWindowMaximized()) return;
        w.beginDrag(edges);
    }

    /// Hands the drag to the system when it will take it, since that is
    /// smoother than anything done frame by frame and gets the system's own
    /// snapping. Otherwise follows the pointer by hand from here.
    fn beginDrag(w: *Self, edges: Edges) void {
        if (native.systemDrag(edges)) return;
        w.drag = .{ .edges = edges, .cursor = cursorOnScreen(), .position = pen.getWindowPosition(), .size = renderSize() };
    }

    /// Follows the pointer while a move or resize is held.
    pub fn continueDrag(w: *Self) void {
        const d = w.drag orelse return;
        const now = cursorOnScreen();
        const dx = now.x - d.cursor.x;
        const dy = now.y - d.cursor.y;

        if (!d.edges.any()) {
            pen.setWindowPosition(round(d.position.x + dx), round(d.position.y + dy));
            return;
        }

        const scale = pen.getWindowScaleDPI();
        const min_width = 420 * scale.x;
        const min_height = 240 * scale.y;

        var width = d.size.x;
        var height = d.size.y;
        if (d.edges.right) width += dx;
        if (d.edges.left) width -= dx;
        if (d.edges.bottom) height += dy;
        if (d.edges.top) height -= dy;
        width = @max(width, min_width);
        height = @max(height, min_height);

        // Pulling the left or top edge moves the window as well, by however
        // much it grew, so the opposite edge stays where it was.
        if (d.edges.left or d.edges.top) {
            const x = if (d.edges.left) d.position.x + d.size.x - width else d.position.x;
            const y = if (d.edges.top) d.position.y + d.size.y - height else d.position.y;
            pen.setWindowPosition(round(x), round(y));
        }
        pen.setWindowSize(round(width), round(height));
    }

    pub fn endDrag(w: *Self) void {
        w.drag = null;
    }

    fn restoreUnderCursor(_: *Self) void {
        const mouse = pen.getMousePosition();
        const across = mouse.x / @as(f32, @floatFromInt(@max(pen.getScreenWidth(), 1)));
        const cursor = cursorOnScreen();
        const scale = pen.getWindowScaleDPI();

        pen.restoreWindow();
        const size = renderSize();
        pen.setWindowPosition(round(cursor.x - size.x * across), round(cursor.y - mouse.y * scale.y));
    }
};

/// Where the pointer is on the desktop, in the units the window's position
/// and size are measured in.
///
/// The system is asked directly where it can be; see `native.cursorOnScreen`
/// for why it is not worked out from the window. The fallback multiplies the
/// display's scale back in, because raylib divides the pointer by it while
/// positions and sizes stay in the window system's pixels.
fn cursorOnScreen() pen.Vector2 {
    if (native.cursorOnScreen()) |at| return at;
    const scale = pen.getWindowScaleDPI();
    const mouse = pen.getMousePosition();
    const at = pen.getWindowPosition();
    return .{ .x = at.x + mouse.x * scale.x, .y = at.y + mouse.y * scale.y };
}

fn renderSize() pen.Vector2 {
    return .{
        .x = @floatFromInt(pen.getRenderWidth()),
        .y = @floatFromInt(pen.getRenderHeight()),
    };
}

fn round(v: f32) i32 {
    return @intFromFloat(@round(v));
}

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
