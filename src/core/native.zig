//! Window-system calls raylib does not wrap: handing a move or resize to
//! the system, and reading the pointer's desktop position. Windows gets a
//! caption press, X11 a _NET_WM_MOVERESIZE request. Elsewhere these report
//! failure and the caller moves the window itself.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");
const Edges = @import("titlebar.zig").Edges;

/// Hands a move (no edges) or resize to the system. False if it cannot.
pub fn systemDrag(edges: Edges) bool {
    return switch (builtin.os.tag) {
        // Windows will not resize a frameless window.
        .windows => if (edges.any()) false else win32.dragByCaption(),
        .linux => x11.moveResize(edges),
        else => false,
    };
}

/// Asks for rounded window corners. Only Windows 11 draws them for a
/// frameless window; elsewhere the corners stay square.
pub fn roundCorners() void {
    if (builtin.os.tag == .windows) win32.roundCorners();
}

/// Desktop pointer position, in window-system pixels. Asked of the system
/// because window position plus pointer update a frame apart mid-drag.
pub fn cursorOnScreen() ?pen.Vector2 {
    return switch (builtin.os.tag) {
        .windows => win32.cursor(),
        .linux => x11.cursor(),
        else => null,
    };
}

const win32 = struct {
    const WM_NCLBUTTONDOWN: u32 = 0x00A1;
    const WM_LBUTTONUP: u32 = 0x0202;
    const HTCAPTION: usize = 2;
    const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
    const DWMWCP_ROUND: u32 = 2;

    const POINT = extern struct { x: c_long, y: c_long };

    extern "user32" fn ReleaseCapture() callconv(.winapi) c_int;
    extern "user32" fn SendMessageW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
    extern "user32" fn PostMessageW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) c_int;
    extern "user32" fn GetCursorPos(point: *POINT) callconv(.winapi) c_int;
    extern "dwmapi" fn DwmSetWindowAttribute(hwnd: ?*anyopaque, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) c_long;

    /// Fails harmlessly before Windows 11, which does not know the attribute.
    fn roundCorners() void {
        const preference = DWMWCP_ROUND;
        _ = DwmSetWindowAttribute(pen.getWindowHandle(), DWMWA_WINDOW_CORNER_PREFERENCE, &preference, @sizeOf(u32));
    }

    /// The move loop swallows the button release; post it back for GLFW.
    fn dragByCaption() bool {
        const hwnd = pen.getWindowHandle();
        _ = ReleaseCapture();
        _ = SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        _ = PostMessageW(hwnd, WM_LBUTTONUP, 0, 0);
        return true;
    }

    fn cursor() ?pen.Vector2 {
        var point: POINT = undefined;
        if (GetCursorPos(&point) == 0) return null;
        return .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
    }
};

const x11 = struct {
    const Display = opaque {};
    const Window = c_ulong;
    const Atom = c_ulong;

    const Success: c_int = 0;
    const ButtonRelease: c_int = 5;
    const ClientMessage: c_int = 33;
    const ButtonReleaseMask: c_long = 1 << 3;
    const SubstructureNotifyMask: c_long = 1 << 19;
    const SubstructureRedirectMask: c_long = 1 << 20;
    const Button1Mask: c_uint = 1 << 8;
    const XA_ATOM: Atom = 4;
    const CurrentTime: c_ulong = 0;

    const ClientMessageEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: Window,
        message_type: Atom,
        format: c_int,
        data: [5]c_long,
    };

    const ButtonEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        window: Window,
        root: Window,
        subwindow: Window,
        time: c_ulong,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: c_uint,
        button: c_uint,
        same_screen: c_int,
    };

    /// Xlib's XEvent union.
    const Event = extern union {
        client: ClientMessageEvent,
        button: ButtonEvent,
        pad: [24]c_long,
    };

    // GLFW's connection, which holds the press's pointer grab.
    extern fn glfwGetCurrentContext() ?*anyopaque;
    extern fn glfwGetX11Display() ?*Display;
    extern fn glfwGetX11Window(window: ?*anyopaque) Window;

    extern "X11" fn XDefaultRootWindow(d: *Display) Window;
    extern "X11" fn XQueryPointer(
        d: *Display,
        w: Window,
        root: *Window,
        child: *Window,
        root_x: *c_int,
        root_y: *c_int,
        win_x: *c_int,
        win_y: *c_int,
        mask: *c_uint,
    ) c_int;
    extern "X11" fn XInternAtom(d: *Display, name: [*:0]const u8, only_if_exists: c_int) Atom;
    extern "X11" fn XUngrabPointer(d: *Display, time: c_ulong) c_int;
    extern "X11" fn XSendEvent(d: *Display, w: Window, propagate: c_int, mask: c_long, event: *Event) c_int;
    extern "X11" fn XFlush(d: *Display) c_int;
    extern "X11" fn XGetWindowProperty(
        d: *Display,
        w: Window,
        property: Atom,
        offset: c_long,
        length: c_long,
        delete: c_int,
        req_type: Atom,
        actual_type: *Atom,
        actual_format: *c_int,
        count: *c_ulong,
        bytes_after: *c_ulong,
        data: *?[*]u8,
    ) c_int;
    extern "X11" fn XFree(data: ?*anyopaque) c_int;

    /// Whether the window manager lists _NET_WM_MOVERESIZE. Asked once.
    var supported: ?bool = null;

    fn cursor() ?pen.Vector2 {
        const d = glfwGetX11Display() orelse return null;
        var root: Window = 0;
        var child: Window = 0;
        var root_x: c_int = 0;
        var root_y: c_int = 0;
        var win_x: c_int = 0;
        var win_y: c_int = 0;
        var mask: c_uint = 0;
        if (XQueryPointer(d, XDefaultRootWindow(d), &root, &child, &root_x, &root_y, &win_x, &win_y, &mask) == 0) {
            return null;
        }
        return .{ .x = @floatFromInt(root_x), .y = @floatFromInt(root_y) };
    }

    fn moveResize(edges: Edges) bool {
        const d = glfwGetX11Display() orelse return false;
        if (!managerSupports(d)) return false;
        const at = cursor() orelse return false;
        const window = glfwGetX11Window(glfwGetCurrentContext());
        const root = XDefaultRootWindow(d);
        const x: c_int = @intFromFloat(at.x);
        const y: c_int = @intFromFloat(at.y);

        _ = XUngrabPointer(d, CurrentTime);

        var request = Event{
            .client = .{
                .type = ClientMessage,
                .serial = 0,
                .send_event = 1,
                .display = d,
                .window = window,
                .message_type = XInternAtom(d, "_NET_WM_MOVERESIZE", 0),
                .format = 32,
                // Pointer, direction, button, and 1 for an ordinary application.
                .data = .{ x, y, direction(edges), 1, 1 },
            },
        };
        _ = XSendEvent(d, root, 0, SubstructureRedirectMask | SubstructureNotifyMask, &request);

        // The window manager now gets the release; send GLFW one too.
        var release = Event{ .button = .{
            .type = ButtonRelease,
            .serial = 0,
            .send_event = 1,
            .display = d,
            .window = window,
            .root = root,
            .subwindow = 0,
            .time = CurrentTime,
            .x = 0,
            .y = 0,
            .x_root = x,
            .y_root = y,
            .state = Button1Mask,
            .button = 1,
            .same_screen = 1,
        } };
        _ = XSendEvent(d, window, 0, ButtonReleaseMask, &release);
        _ = XFlush(d);
        return true;
    }

    /// Clockwise from top-left; 8 is move.
    fn direction(e: Edges) c_long {
        if (e.top and e.left) return 0;
        if (e.top and e.right) return 2;
        if (e.bottom and e.right) return 4;
        if (e.bottom and e.left) return 6;
        if (e.top) return 1;
        if (e.right) return 3;
        if (e.bottom) return 5;
        if (e.left) return 7;
        return 8;
    }

    fn managerSupports(d: *Display) bool {
        if (supported) |known| return known;
        supported = listsMoveResize(d);
        return supported.?;
    }

    fn listsMoveResize(d: *Display) bool {
        const wanted = XInternAtom(d, "_NET_WM_MOVERESIZE", 0);
        var kind: Atom = 0;
        var format: c_int = 0;
        var count: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        const status = XGetWindowProperty(
            d,
            XDefaultRootWindow(d),
            XInternAtom(d, "_NET_SUPPORTED", 0),
            0,
            4096,
            0,
            XA_ATOM,
            &kind,
            &format,
            &count,
            &after,
            &data,
        );
        defer if (data) |bytes| {
            _ = XFree(bytes);
        };
        if (status != Success or kind != XA_ATOM or format != 32) return false;
        const bytes = data orelse return false;

        // Format-32 properties come back as C longs.
        const atoms: [*]const c_ulong = @ptrCast(@alignCast(bytes));
        return std.mem.indexOfScalar(c_ulong, atoms[0..count], wanted) != null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "every edge and corner maps to its _NET_WM_MOVERESIZE direction" {
    try testing.expectEqual(@as(c_long, 8), x11.direction(.{}));
    try testing.expectEqual(@as(c_long, 0), x11.direction(.{ .top = true, .left = true }));
    try testing.expectEqual(@as(c_long, 1), x11.direction(.{ .top = true }));
    try testing.expectEqual(@as(c_long, 2), x11.direction(.{ .top = true, .right = true }));
    try testing.expectEqual(@as(c_long, 3), x11.direction(.{ .right = true }));
    try testing.expectEqual(@as(c_long, 4), x11.direction(.{ .bottom = true, .right = true }));
    try testing.expectEqual(@as(c_long, 5), x11.direction(.{ .bottom = true }));
    try testing.expectEqual(@as(c_long, 6), x11.direction(.{ .bottom = true, .left = true }));
    try testing.expectEqual(@as(c_long, 7), x11.direction(.{ .left = true }));
}

test "Xlib event layouts match the C ABI on this target" {
    try testing.expectEqual(24 * @sizeOf(c_long), @sizeOf(x11.Event));
    if (@sizeOf(c_long) == 8) {
        try testing.expectEqual(@as(usize, 96), @sizeOf(x11.ClientMessageEvent));
        try testing.expectEqual(@as(usize, 56), @offsetOf(x11.ClientMessageEvent, "data"));
        try testing.expectEqual(@as(usize, 96), @sizeOf(x11.ButtonEvent));
    }
}
