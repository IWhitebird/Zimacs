//! The small pieces panels are drawn from: text fields, toggles, buttons,
//! chevrons, ticks and crosses, and the title bar's caption glyphs.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const theme = @import("theme.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const titlebar = @import("titlebar.zig");
const find_mod = @import("find.zig");
const TextField = @import("field.zig").TextField;
const Metrics = @import("font.zig").Metrics;

/// Line width of the drawn icons, and the thinner one of the caption glyphs.
const stroke = 1.5;
const caption_stroke = 1.2;

pub fn drawTick(rect: pen.Rectangle, ink: pen.Color) void {
    const size = @round(rect.height * 0.45);
    const x = rect.x + (rect.width - size) / 2;
    const y = rect.y + (rect.height - size) / 2;
    pen.drawLineEx(.{ .x = x, .y = y + size * 0.55 }, .{ .x = x + size * 0.38, .y = y + size }, stroke, ink);
    pen.drawLineEx(.{ .x = x + size * 0.38, .y = y + size }, .{ .x = x + size, .y = y }, stroke, ink);
}

pub fn drawField(field: *const TextField, rect: pen.Rectangle, focused: bool, placeholder: [:0]const u8, cell: Metrics) void {
    const t = theme.current;
    pen.drawRectangleRec(rect, t.background);
    pen.drawRectangleLinesEx(rect, 1, if (focused) t.caret else t.scrollbar);

    const value = field.value();
    const y = rect.y + (rect.height - cell.height) / 2;
    const left = rect.x + layout.padding;
    if (value.len == 0 and !focused) {
        app.font.draw(placeholder, left, y, t.hint);
        return;
    }

    const visible = find_mod.fieldColumns(rect, app.font);
    const caret_column = text.columnOf(value, field.caret, 1);
    const first = find_mod.fieldScroll(caret_column, visible);
    const shift = @as(f32, @floatFromInt(first)) * cell.width;

    pen.beginScissorMode(@intFromFloat(rect.x + 1), @intFromFloat(rect.y), @intFromFloat(rect.width - 2), @intFromFloat(rect.height));
    defer pen.endScissorMode();

    if (field.selection()) |sel| {
        const from: f32 = @floatFromInt(text.columnOf(value, sel.start, 1));
        const to: f32 = @floatFromInt(text.columnOf(value, sel.end, 1));
        pen.drawRectangleRec(.{ .x = left + from * cell.width - shift, .y = y, .width = (to - from) * cell.width, .height = cell.height }, t.selection);
    }

    // Only what fits, so a long pasted value still draws.
    const start = text.characterAt(value, @intCast(first), 1);
    const end = text.offsetOf(value, @intCast(first + visible + 1), 1);
    var buf: [max_field_bytes]u8 = undefined;
    const shown = std.fmt.bufPrintZ(&buf, "{s}", .{value[start.offset..@min(end, start.offset + buf.len - 1)]}) catch return;
    app.font.draw(shown, left + @as(f32, @floatFromInt(start.column)) * cell.width - shift, y, t.text);
    if (focused) {
        const x = left + @as(f32, @floatFromInt(caret_column)) * cell.width - shift;
        pen.drawRectangleRec(.{ .x = x, .y = y, .width = 2, .height = cell.height }, t.caret);
    }
}

pub fn drawToggle(rect: pen.Rectangle, label: [:0]const u8, on: bool, point: pen.Vector2, cell: Metrics) void {
    const t = theme.current;
    const inner = shrink(rect, 2);
    if (on) {
        pen.drawRectangleRec(inner, t.selection);
        pen.drawRectangleLinesEx(inner, 1, t.caret);
    } else if (pen.checkCollisionPointRec(point, rect)) {
        pen.drawRectangleRec(inner, t.tab_active);
    }
    const x = rect.x + (rect.width - app.font.widthOf(label)) / 2;
    app.font.draw(label, x, rect.y + (rect.height - cell.height) / 2, if (on) t.tab_text_active else t.tab_text);
}

pub fn drawIconButton(rect: pen.Rectangle, point: pen.Vector2) void {
    if (pen.checkCollisionPointRec(point, rect)) pen.drawRectangleRec(shrink(rect, 2), theme.current.tab_active);
}

pub fn drawTextButton(rect: pen.Rectangle, label: [:0]const u8, point: pen.Vector2, cell: Metrics) void {
    const t = theme.current;
    drawIconButton(rect, point);
    pen.drawRectangleLinesEx(shrink(rect, 2), 1, t.scrollbar);
    const x = rect.x + (rect.width - app.font.widthOf(label)) / 2;
    app.font.draw(label, x, rect.y + (rect.height - cell.height) / 2, hoverInk(rect, point));
}

pub fn drawChevron(rect: pen.Rectangle, pointing: Pointing, ink: pen.Color) void {
    const size = @round(@min(rect.width, rect.height) * 0.28);
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const half = size / 2;
    const tips: [3]pen.Vector2 = switch (pointing) {
        .up => .{ .{ .x = cx - size, .y = cy + half }, .{ .x = cx, .y = cy - half }, .{ .x = cx + size, .y = cy + half } },
        .down => .{ .{ .x = cx - size, .y = cy - half }, .{ .x = cx, .y = cy + half }, .{ .x = cx + size, .y = cy - half } },
        .left => .{ .{ .x = cx + half, .y = cy - size }, .{ .x = cx - half, .y = cy }, .{ .x = cx + half, .y = cy + size } },
        .right => .{ .{ .x = cx - half, .y = cy - size }, .{ .x = cx + half, .y = cy }, .{ .x = cx - half, .y = cy + size } },
    };
    pen.drawLineEx(tips[0], tips[1], stroke, ink);
    pen.drawLineEx(tips[1], tips[2], stroke, ink);
}

pub fn hoverInk(rect: pen.Rectangle, point: pen.Vector2) pen.Color {
    return if (pen.checkCollisionPointRec(point, rect)) theme.current.tab_text_active else theme.current.tab_text;
}

pub fn shrink(r: pen.Rectangle, by: f32) pen.Rectangle {
    return .{ .x = r.x + by, .y = r.y + by, .width = r.width - by * 2, .height = r.height - by * 2 };
}

/// A square centred in `r`, for glyphs that should not stretch.
pub fn squareIn(r: pen.Rectangle) pen.Rectangle {
    const side = @min(r.width, r.height);
    return .{ .x = r.x + (r.width - side) / 2, .y = r.y + (r.height - side) / 2, .width = side, .height = side };
}

/// Fixed-size glyphs, centred, so they do not stretch with the button.
pub fn drawCaptionGlyph(b: titlebar.Button, rect: pen.Rectangle, ink: pen.Color) void {
    const size = @round(rect.height * 0.3);
    const x = @round(rect.x + (rect.width - size) / 2);
    const y = @round(rect.y + (rect.height - size) / 2);

    switch (b) {
        .minimize => pen.drawRectangleRec(.{ .x = x, .y = y + @round(size / 2), .width = size, .height = 1 }, ink),
        .maximize => if (pen.isWindowMaximized()) {
            // Restore: the visible edges of a second square behind the first.
            const side = @round(size * 0.8);
            const offset = size - side;
            pen.drawRectangleRec(.{ .x = x + offset, .y = y, .width = side, .height = 1 }, ink);
            pen.drawRectangleRec(.{ .x = x + size - 1, .y = y, .width = 1, .height = side }, ink);
            pen.drawRectangleLinesEx(.{ .x = x, .y = y + offset, .width = side, .height = side }, 1, ink);
        } else {
            pen.drawRectangleLinesEx(.{ .x = x, .y = y, .width = size, .height = size }, 1, ink);
        },
        .close => {
            pen.drawLineEx(.{ .x = x, .y = y }, .{ .x = x + size, .y = y + size }, caption_stroke, ink);
            pen.drawLineEx(.{ .x = x + size, .y = y }, .{ .x = x, .y = y + size }, caption_stroke, ink);
        },
    }
}

pub fn drawCross(rect: pen.Rectangle, colour: pen.Color) void {
    const inset = rect.width * 0.3;
    const a = pen.Vector2{ .x = rect.x + inset, .y = rect.y + inset };
    const b = pen.Vector2{ .x = rect.x + rect.width - inset, .y = rect.y + rect.height - inset };
    pen.drawLineEx(a, b, stroke, colour);
    pen.drawLineEx(
        .{ .x = b.x, .y = a.y },
        .{ .x = a.x, .y = b.y },
        stroke,
        colour,
    );
}

/// A plus sign, as on the button that opens a new tab.
pub fn drawPlus(rect: pen.Rectangle, colour: pen.Color) void {
    const inset = rect.width * 0.22;
    const mid = pen.Vector2{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    pen.drawLineEx(.{ .x = rect.x + inset, .y = mid.y }, .{ .x = rect.x + rect.width - inset, .y = mid.y }, stroke, colour);
    pen.drawLineEx(.{ .x = mid.x, .y = rect.y + inset }, .{ .x = mid.x, .y = rect.y + rect.height - inset }, stroke, colour);
}

/// Room for the visible part of a field's text.
const max_field_bytes = 1024;

pub const Pointing = enum { up, down, left, right };
