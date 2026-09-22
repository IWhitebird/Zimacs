//! The OS window: opening it, remembering where it was, moving and resizing
//! it for the custom title bar, and accepting dropped files.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const Artifact = @import("artifact.zig").Artifact;
const native = @import("native.zig");
const Placement = @import("session.zig").Placement;
const Edges = @import("titlebar.zig").Edges;

const icon_data = @embedFile("icon_data");

/// Smallest size a window can be resized to, in logical pixels.
const min_width = 420;
const min_height = 240;

/// How much of a restored window's top edge must be on a monitor.
const reachable_width = 120;
const reachable_height = 24;

extern fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;
extern fn emscripten_get_device_pixel_ratio() f64;

pub const Window = struct {
    title: [:0]const u8 = "Zimacs",
    width: i32 = 800,
    height: i32 = 450,
    target_fps: i32 = 165,
    /// The system frame is off and Zimacs draws the title bar.
    custom_frame: bool = false,
    close_requested: bool = false,
    drag: ?Drag = null,
    restore_to: ?Placement = null,
    /// Last size and position while neither maximised nor minimised.
    normal: ?Placement = null,
    was_maximized: bool = false,

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
        w.custom_frame = app.config.custom_titlebar and !app.on_web;
        // Hidden until placed, so it does not appear and then jump.
        const hidden = w.restore_to != null;
        // High-DPI stays off on the web: `fitToCanvas` handles density there,
        // and raylib scaling as well breaks scissor rectangles.
        pen.setConfigFlags(.{
            .window_resizable = true,
            .window_highdpi = !app.on_web,
            .window_undecorated = w.custom_frame,
            .window_hidden = hidden,
        });
        if (builtin.mode != .Debug) pen.setTraceLogLevel(.warning);
        pen.initWindow(w.width, w.height, w.title);
        pen.setTargetFPS(w.target_fps);
        // raylib closes on Escape by default.
        pen.setExitKey(.null);
        setIcon();

        if (w.restore_to) |p| w.putBack(p);
        if (hidden) pen.clearWindowState(.{ .window_hidden = true });
        // Maximised after showing: some window managers ignore it before.
        if (w.restore_to) |p| if (p.maximized) pen.maximizeWindow();
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
        w.trackNormal();
        openDroppedFiles();
    }

    pub fn shouldClose(w: *const Self) bool {
        return w.close_requested or pen.windowShouldClose();
    }

    // ------------------------------------------------------------ placement

    /// Called before `init`, since the size is fixed when the window opens.
    pub fn restoreTo(w: *Self, p: ?Placement) void {
        if (app.on_web) return;
        const saved = p orelse return;
        w.width = saved.width;
        w.height = saved.height;
        w.restore_to = saved;
    }

    pub fn placement(w: *const Self) ?Placement {
        var p = w.normal orelse return null;
        p.maximized = pen.isWindowMaximized();
        return p;
    }

    fn putBack(w: *Self, p: Placement) void {
        // A monitor that has since been unplugged leaves it where the system put it.
        if (onSomeMonitor(p)) pen.setWindowPosition(p.x, p.y);
        // A window opened maximised never reports its normal size.
        w.normal = p;
        w.normal.?.maximized = false;
    }

    fn trackNormal(w: *Self) void {
        if (app.on_web) return;
        const maximized = pen.isWindowMaximized();
        defer w.was_maximized = maximized;
        // The frame after a maximise can have the new size before the new
        // state, so it is skipped too.
        if (maximized or w.was_maximized or pen.isWindowMinimized()) return;
        const at = pen.getWindowPosition();
        w.normal = .{
            .x = round(at.x),
            .y = round(at.y),
            .width = pen.getScreenWidth(),
            .height = pen.getScreenHeight(),
        };
    }

    // ------------------------------------------------------------- controls

    pub fn minimize(_: *Self) void {
        pen.minimizeWindow();
    }

    pub fn toggleMaximize(_: *Self) void {
        if (pen.isWindowMaximized()) pen.restoreWindow() else pen.maximizeWindow();
    }

    pub fn beginMove(w: *Self) void {
        if (pen.isWindowMaximized()) restoreUnderCursor();
        w.drag = Drag.start(.{});
    }

    pub fn beginResize(w: *Self, edges: Edges) void {
        if (pen.isWindowMaximized()) return;
        w.drag = Drag.start(edges);
    }

    pub fn continueDrag(w: *Self) void {
        if (w.drag) |d| d.follow();
    }

    pub fn endDrag(w: *Self) void {
        w.drag = null;
    }
};

/// A move (no edges) or resize followed by hand, for when the system will
/// not take the drag itself. Everything is in window-system units.
const Drag = struct {
    edges: Edges,
    cursor: pen.Vector2,
    position: pen.Vector2,
    size: pen.Vector2,

    /// Null when the system has taken the drag over.
    fn start(edges: Edges) ?Drag {
        if (native.systemDrag(edges)) return null;
        return .{
            .edges = edges,
            .cursor = cursorOnScreen(),
            .position = pen.getWindowPosition(),
            .size = renderSize(),
        };
    }

    fn follow(d: Drag) void {
        const now = cursorOnScreen();
        const dx = now.x - d.cursor.x;
        const dy = now.y - d.cursor.y;

        if (!d.edges.any()) {
            pen.setWindowPosition(round(d.position.x + dx), round(d.position.y + dy));
            return;
        }

        const scale = pen.getWindowScaleDPI();
        var width = d.size.x;
        var height = d.size.y;
        if (d.edges.right) width += dx;
        if (d.edges.left) width -= dx;
        if (d.edges.bottom) height += dy;
        if (d.edges.top) height -= dy;
        width = @max(width, min_width * scale.x);
        height = @max(height, min_height * scale.y);

        // Left and top edges move the window so the opposite edge stays put.
        if (d.edges.left or d.edges.top) {
            const x = if (d.edges.left) d.position.x + d.size.x - width else d.position.x;
            const y = if (d.edges.top) d.position.y + d.size.y - height else d.position.y;
            pen.setWindowPosition(round(x), round(y));
        }
        pen.setWindowSize(round(width), round(height));
    }
};

/// Restores a maximised window with the pointer at the same fraction across.
fn restoreUnderCursor() void {
    const mouse = pen.getMousePosition();
    const across = mouse.x / @as(f32, @floatFromInt(@max(pen.getScreenWidth(), 1)));
    const cursor = cursorOnScreen();
    const scale = pen.getWindowScaleDPI();

    pen.restoreWindow();
    const size = renderSize();
    pen.setWindowPosition(round(cursor.x - size.x * across), round(cursor.y - mouse.y * scale.y));
}

/// The pointer on the desktop. The fallback scales the pointer back up,
/// since raylib divides it by the DPI scale but not window positions.
fn cursorOnScreen() pen.Vector2 {
    if (native.cursorOnScreen()) |at| return at;
    const scale = pen.getWindowScaleDPI();
    const mouse = pen.getMousePosition();
    const at = pen.getWindowPosition();
    return .{ .x = at.x + mouse.x * scale.x, .y = at.y + mouse.y * scale.y };
}

fn onSomeMonitor(p: Placement) bool {
    const count: usize = @intCast(@max(pen.getMonitorCount(), 0));
    for (0..count) |i| {
        const index: i32 = @intCast(i);
        const at = pen.getMonitorPosition(index);
        const left: i32 = round(at.x);
        const top: i32 = round(at.y);
        const right = left + pen.getMonitorWidth(index);
        const bottom = top + pen.getMonitorHeight(index);

        const overlap_x = @min(p.x + p.width, right) - @max(p.x, left);
        const overlap_y = @min(p.y + reachable_height, bottom) - @max(p.y, top);
        if (overlap_x >= reachable_width and overlap_y >= reachable_height) return true;
    }
    return false;
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

/// Sizes the web canvas buffer to its CSS size times the pixel ratio, so the
/// browser does not upscale it. Must run before `beginDrawing`, since a
/// resize clears the framebuffer.
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

fn setIcon() void {
    const image = pen.loadImageFromMemory(".png", icon_data) catch return;
    defer pen.unloadImage(image);
    pen.setWindowIcon(image);
}

fn openDroppedFiles() void {
    if (!pen.isFileDropped()) return;

    const dropped = pen.loadDroppedFiles();
    defer pen.unloadDroppedFiles(dropped);

    for (0..dropped.count) |i| {
        const path: [:0]const u8 = std.mem.span(dropped.paths[i]);
        app.openFile(path) catch |err| {
            std.debug.print("Could not open {s}: {s}\n", .{ path, @errorName(err) });
        };
    }
}
