//! Lets the editor sleep until something happens instead of redrawing at the
//! full frame rate. A heartbeat wakes it now and then for what runs on a
//! timer: autosave, the disk watch, notices expiring, the update check.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");

const heartbeat_ms = 500;

extern fn glfwPostEmptyEvent() void;

var stopped = std.atomic.Value(bool).init(false);

pub fn start(io: std.Io) void {
    if (app.on_web) return;
    const thread = std.Thread.spawn(.{}, beat, .{io}) catch return;
    thread.detach();
    pen.enableEventWaiting();
}

pub fn stop() void {
    stopped.store(true, .release);
}

/// Whether the next frame is the one that shows what the last woken frame
/// did, since input is read after the editor has drawn.
var follow_up = false;

/// Frames also run back to back while something moves without sending
/// events, such as a drag held still past the edge of the text.
pub fn pace() void {
    if (app.on_web) return;
    follow_up = !follow_up;
    if (follow_up or busy()) pen.disableEventWaiting() else pen.enableEventWaiting();
}

fn busy() bool {
    return pen.isMouseButtonDown(.left) or pen.isMouseButtonDown(.right) or pen.isMouseButtonDown(.middle);
}

fn beat(io: std.Io) void {
    while (!stopped.load(.acquire)) {
        io.sleep(.fromMilliseconds(heartbeat_ms), .awake) catch return;
        if (!stopped.load(.acquire)) glfwPostEmptyEvent();
    }
}
