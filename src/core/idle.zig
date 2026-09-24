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

/// Waits for the next event unless the frame after this one has work: input
/// is read after the editor has drawn, so a frame that took input needs one
/// more to show it, and a held button or a stale font needs frames too.
pub fn pace() void {
    if (app.on_web) return;
    if (hadInput() or busy() or app.font.needsRefresh()) pen.disableEventWaiting() else pen.enableEventWaiting();
}

/// Frames also run back to back while a button is held, since a drag held
/// still past the edge of the text scrolls without sending events.
fn busy() bool {
    return pen.isMouseButtonDown(.left) or pen.isMouseButtonDown(.right) or pen.isMouseButtonDown(.middle);
}

fn hadInput() bool {
    if (pen.isWindowResized() or pen.isFileDropped()) return true;
    const moved = pen.getMouseDelta();
    const wheel = pen.getMouseWheelMoveV();
    if (moved.x != 0 or moved.y != 0 or wheel.x != 0 or wheel.y != 0) return true;
    for (std.enums.values(pen.MouseButton)) |button| {
        if (pen.isMouseButtonPressed(button) or pen.isMouseButtonReleased(button)) return true;
    }
    for (std.enums.values(pen.KeyboardKey)) |key| {
        if (pen.isKeyPressed(key) or pen.isKeyPressedRepeat(key) or pen.isKeyReleased(key)) return true;
    }
    return false;
}

fn beat(io: std.Io) void {
    while (!stopped.load(.acquire)) {
        io.sleep(.fromMilliseconds(heartbeat_ms), .awake) catch return;
        if (!stopped.load(.acquire)) glfwPostEmptyEvent();
    }
}
