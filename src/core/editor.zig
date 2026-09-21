//! Draws everything: the tab bar, line numbers, the text with its selection
//! and caret, the scrollbars and the status bar.
//!
//! Only the lines currently on screen are touched and the scratch buffers are
//! reused, so a steady frame allocates nothing however large the file.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const theme = @import("theme.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const menu = @import("menu.zig");
const wrap = @import("wrap.zig");
const Artifact = @import("artifact.zig").Artifact;
const BufferView = @import("buffer.zig").BufferView;
const Metrics = @import("font.zig").Metrics;
const Layout = layout.Layout;

pub const Editor = struct {
    /// One line as stored, then the same line with tabs expanded.
    raw: std.ArrayList(u8) = .empty,
    shown: std.ArrayList(u8) = .empty,
    status: std.ArrayList(u8) = .empty,
    /// For each screen row, the document line it starts, or null when it is
    /// the continuation of a folded line. Filled while drawing the text and
    /// read by the gutter, so the two cannot disagree.
    row_lines: std.ArrayList(?u32) = .empty,

    const Self = @This();

    const table = Artifact.Table{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(e: *Self) Artifact {
        return .{ .ctx = @ptrCast(e), .table = &table, .name = "Editor" };
    }

    pub fn init(ctx: *anyopaque) !void {
        _ = ctx;
    }

    pub fn deinit(ctx: *anyopaque) !void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        e.raw.deinit(app.gpa);
        e.shown.deinit(app.gpa);
        e.status.deinit(app.gpa);
        e.row_lines.deinit(app.gpa);
    }

    pub fn render(ctx: *anyopaque) !void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        const cell = app.font.metrics;
        const l = currentLayout();

        const view = app.buffer.current() orelse {
            try drawHint(l, cell);
            drawMenu(l, cell);
            return;
        };

        try e.follow(view, l, cell);
        try e.drawText(view, l, cell);
        try e.drawGutter(view, l, cell);
        drawScrollbars(view, l, cell);
        drawTabs(l);
        try e.drawStatus(view, l, cell);
        try e.drawPrompt(l, cell);
        // Last, so the dropdown and the About panel sit over everything else.
        drawMenu(l, cell);
    }

    /// Scrolls vertically without moving the caret.
    pub fn scroll(e: *Self, lines: i32) void {
        _ = e;
        const view = app.buffer.current() orelse return;
        const rows = currentLayout().rows(app.font.metrics);
        const max = view.tree.lineCount() -| rows;
        const next = @as(i64, view.top_line) + lines;
        view.top_line = if (next <= 0) 0 else @min(@as(u32, @intCast(next)), max);
    }

    pub fn scrollSideways(e: *Self, columns: i32) void {
        _ = e;
        const view = app.buffer.current() orelse return;
        const visible = visibleColumns(currentLayout(), app.font.metrics);
        const max = view.content_columns -| visible;
        const next = @as(i64, view.left_column) + columns;
        view.left_column = if (next <= 0) 0 else @min(@as(u32, @intCast(next)), max);
    }

    // ----------------------------------------------------------- scrolling

    /// Keeps the caret on screen, but only when it has actually moved.
    /// Chasing it every frame would fight the scrollbar and the wheel.
    fn follow(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        const rows = l.rows(cell);
        if (rows == 0) return;
        defer view.top_line = @min(view.top_line, view.tree.lineCount() -| rows);

        if (view.followed) |seen| if (seen == view.cursor.offset) return;
        view.followed = view.cursor.offset;

        const at = view.cursor.position(&view.tree);
        if (at.line < view.top_line) {
            view.top_line = at.line;
            view.top_row = 0;
        } else if (at.line >= view.top_line + rows) {
            view.top_line = at.line - rows + 1;
            view.top_row = 0;
        }

        if (app.config.wrap_lines) {
            // Sideways scrolling has no meaning while lines are folded.
            view.left_column = 0;
            return;
        }

        const column = try e.columnOf(view, at.line, at.column);
        const visible = visibleColumns(l, cell);
        if (column < view.left_column) {
            view.left_column = column;
        } else if (visible > 0 and column >= view.left_column + visible) {
            view.left_column = column - visible + 1;
        }
    }

    /// Where a document line and column land on screen, or null when they are
    /// scrolled out of view.
    fn screenRowOf(
        e: *Self,
        view: *BufferView,
        l: Layout,
        cell: Metrics,
        line: u32,
        column: u32,
    ) !?struct { row: u32, column: u32 } {
        if (line < view.top_line) return null;
        if (!app.config.wrap_lines) {
            return .{ .row = line - view.top_line, .column = column };
        }

        const span = visibleColumns(l, cell);
        const placed = wrap.place(column, span);

        // Count the rows taken by the lines above this one.
        var row: u32 = 0;
        var scan = view.top_line;
        while (scan < line) : (scan += 1) {
            e.raw.clearRetainingCapacity();
            try view.tree.lineContent(scan, &e.raw);
            row += wrap.rowsFor(text.width(e.raw.items, app.config.tab_width), span);
            if (row > l.rows(cell)) return null;
        }
        const above = if (scan == view.top_line) view.top_row else 0;
        if (placed.row < above) return null;
        return .{ .row = row + placed.row - above, .column = placed.column };
    }

    /// The screen column of a byte offset within a line.
    fn columnOf(e: *Self, view: *BufferView, line: u32, byte: u32) !u32 {
        e.raw.clearRetainingCapacity();
        try view.tree.lineContent(line, &e.raw);
        return text.columnOf(e.raw.items, byte, app.config.tab_width);
    }

    // ------------------------------------------------------------ drawing

    fn drawText(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        pen.drawRectangleRec(l.text, theme.current.background);
        pen.beginScissorMode(
            @intFromFloat(l.text.x),
            @intFromFloat(l.text.y),
            @intFromFloat(l.text.width),
            @intFromFloat(l.text.height),
        );
        defer pen.endScissorMode();

        const rows = l.rows(cell);
        const total = view.tree.lineCount();
        const active = view.cursorLine();
        const selection = view.cursor.selection();
        const tab = app.config.tab_width;
        const wrapping = app.config.wrap_lines;
        const span = visibleColumns(l, cell);
        const shift = if (wrapping) 0 else @as(f32, @floatFromInt(view.left_column)) * cell.width;

        e.row_lines.clearRetainingCapacity();

        var widest: u32 = 1;
        var row: u32 = 0;
        var line = view.top_line;
        var skip = if (wrapping) view.top_row else 0;

        while (row < rows and line < total) : (line += 1) {
            e.raw.clearRetainingCapacity();
            try view.tree.lineContent(line, &e.raw);
            const columns = text.width(e.raw.items, tab);
            widest = @max(widest, columns);

            const pieces = if (wrapping) wrap.rowsFor(columns, span) else 1;
            var piece = skip;
            skip = 0;
            while (piece < pieces and row < rows) : ({
                piece += 1;
                row += 1;
            }) {
                try e.row_lines.append(app.gpa, if (piece == 0) line else null);

                const y = l.text.y + @as(f32, @floatFromInt(row)) * cell.height;
                const from = if (wrapping) wrap.rowStart(piece, span) else 0;
                const to = if (wrapping) @min(from + span, columns) else columns;

                if (line == active and selection == null) {
                    pen.drawRectangleRec(
                        .{ .x = l.text.x, .y = y, .width = l.text.width, .height = cell.height },
                        theme.current.current_line,
                    );
                }
                if (selection) |range| {
                    e.drawSelection(view, l, cell, line, y, range, columns, from, to);
                }
                if (e.raw.items.len == 0) continue;

                // Only the slice of the line this row shows.
                const first = text.offsetOf(e.raw.items, from, tab);
                const last = text.offsetOf(e.raw.items, to, tab);
                e.shown.clearRetainingCapacity();
                try text.expand(e.raw.items[first..last], &e.shown, app.gpa, tab);
                app.font.draw(
                    try terminate(&e.shown),
                    l.text.x + layout.padding - shift,
                    y,
                    theme.current.text,
                );
            }
        }
        view.content_columns = widest;

        try e.drawCaret(view, l, cell);
    }

    fn drawSelection(
        e: *Self,
        view: *BufferView,
        l: Layout,
        cell: Metrics,
        line: u32,
        y: f32,
        range: @import("cursor.zig").Range,
        columns: u32,
        from_column: u32,
        to_column: u32,
    ) void {
        const start = view.tree.lineStart(line);
        // Reach one column past the text so a selection spanning several lines
        // looks continuous rather than ragged.
        const stop = view.tree.lineEnd(line) + @intFromBool(line + 1 < view.tree.lineCount());
        if (range.end <= start or range.start > stop) return;

        const tab = app.config.tab_width;
        const from_byte = @max(range.start, start) - start;
        const to_byte = @min(range.end, stop) - start;

        const selected_from = text.columnOf(e.raw.items, from_byte, tab);
        const selected_to = if (to_byte > e.raw.items.len)
            columns + 1
        else
            text.columnOf(e.raw.items, to_byte, tab);

        // Clip to the slice of the line this row is showing.
        const from = @max(selected_from, from_column);
        const to = @min(selected_to, if (to_column > from_column) to_column + 1 else to_column);
        if (to <= from) return;

        const origin = if (app.config.wrap_lines) from_column else view.left_column;
        if (to <= origin) return;
        const first = @max(from, origin) - origin;
        const last = to - origin;
        pen.drawRectangleRec(.{
            .x = l.text.x + layout.padding + @as(f32, @floatFromInt(first)) * cell.width,
            .y = y,
            .width = @max(@as(f32, @floatFromInt(last - first)) * cell.width, 2),
            .height = cell.height,
        }, theme.current.selection);
    }

    fn drawCaret(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        const at = view.cursor.position(&view.tree);
        const column = try e.columnOf(view, at.line, at.column);

        const placed = try e.screenRowOf(view, l, cell, at.line, column) orelse return;
        if (placed.row >= l.rows(cell)) return;
        if (placed.column < view.left_column) return;

        const x = l.text.x + layout.padding +
            @as(f32, @floatFromInt(placed.column - view.left_column)) * cell.width;
        const y = l.text.y + @as(f32, @floatFromInt(placed.row)) * cell.height;

        const shape: pen.Rectangle = switch (app.config.caret_style) {
            .line => .{ .x = x, .y = y, .width = @max(cell.width * 0.12, 1), .height = cell.height },
            .block => .{ .x = x, .y = y, .width = cell.width, .height = cell.height },
            .underline => .{
                .x = x,
                .y = y + cell.height - @max(cell.height * 0.1, 2),
                .width = cell.width,
                .height = @max(cell.height * 0.1, 2),
            },
        };

        var colour = theme.current.caret;
        // A block would otherwise hide the character underneath it.
        if (app.config.caret_style == .block) colour.a = 140;
        pen.drawRectangleRec(shape, colour);
    }

    /// Numbers only the rows that begin a line, so a folded line is numbered
    /// once rather than once per row.
    fn drawGutter(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        pen.drawRectangleRec(l.gutter, theme.current.background);
        const active = view.cursorLine();

        var label_buf: [16]u8 = undefined;
        for (e.row_lines.items, 0..) |maybe_line, row| {
            const line = maybe_line orelse continue;
            // Line numbers are 1-based for display; the tree is 0-based.
            const label = std.fmt.bufPrintZ(&label_buf, "{d}", .{line + 1}) catch continue;
            app.font.draw(
                label,
                layout.rightAlign(l.gutter, app.font.widthOf(label)),
                l.gutter.y + @as(f32, @floatFromInt(row)) * cell.height,
                if (line == active) theme.current.gutter_text_active else theme.current.gutter_text,
            );
        }
    }

    fn drawScrollbars(view: *BufferView, l: Layout, cell: Metrics) void {
        const pointer = pen.getMousePosition();

        pen.drawRectangleRec(l.scrollbar, theme.current.background);
        if (layout.thumb(l.scrollbar, view.top_line, l.rows(cell), view.tree.lineCount())) |bar| {
            pen.drawRectangleRounded(bar, 0.6, 4, if (pen.checkCollisionPointRec(pointer, l.scrollbar))
                theme.current.scrollbar_hover
            else
                theme.current.scrollbar);
        }

        const track = layout.horizontalTrack(l);
        const visible = visibleColumns(l, cell);
        if (layout.horizontalThumb(track, view.left_column, visible, view.content_columns)) |bar| {
            pen.drawRectangleRounded(bar, 0.6, 4, if (pen.checkCollisionPointRec(pointer, track))
                theme.current.scrollbar_hover
            else
                theme.current.scrollbar);
        }
    }

    fn drawTabs(l: Layout) void {
        if (l.tabs.height <= 0) return;
        pen.drawRectangleRec(l.tabs, theme.current.tab_background);
        pen.beginScissorMode(
            @intFromFloat(l.tabs.x),
            @intFromFloat(l.tabs.y),
            @intFromFloat(l.tabs.width),
            @intFromFloat(l.tabs.height),
        );
        defer pen.endScissorMode();

        const point = pen.getMousePosition();
        for (app.buffer.views.items, 0..) |view, i| {
            const rect = tabRect(i, l) orelse continue;
            const is_active = i == app.buffer.active;
            if (is_active) pen.drawRectangleRec(rect, theme.current.tab_active);

            var label_buf: [160]u8 = undefined;
            app.font.draw(
                tabLabel(&label_buf, view),
                rect.x + layout.padding,
                rect.y + (rect.height - app.font.metrics.height) / 2,
                if (is_active) theme.current.tab_text_active else theme.current.tab_text,
            );

            if (tabCloseRect(i, l)) |close| {
                const hot = pen.checkCollisionPointRec(point, close);
                if (hot) pen.drawRectangleRounded(close, 0.4, 4, theme.current.selection);
                drawCross(close, if (hot or is_active)
                    theme.current.tab_text_active
                else
                    theme.current.tab_text);
            }
        }
    }

    fn drawStatus(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        pen.drawRectangleRec(l.status, theme.current.status_background);
        const y = l.status.y + (l.status.height - cell.height) / 2;

        // The position readout is measured first so the file name knows how
        // much room is left, and is clipped rather than running under it.
        var label_buf: [96]u8 = undefined;
        // Reported as screen columns, so it agrees with where the caret is
        // drawn on a line holding tabs or multi-byte characters.
        const where = view.cursor.position(&view.tree);
        const at = .{
            .line = where.line + 1,
            .column = (try e.columnOf(view, where.line, where.column)) + 1,
        };
        const label = if (view.cursor.selection()) |sel|
            std.fmt.bufPrintZ(&label_buf, "{d} selected    Ln {d}, Col {d}", .{ sel.len(), at.line, at.column }) catch return
        else
            std.fmt.bufPrintZ(&label_buf, "Ln {d}, Col {d}", .{ at.line, at.column }) catch return;

        const right_x = layout.rightAlign(l.status, app.font.widthOf(label));

        e.status.clearRetainingCapacity();
        try e.status.print(app.gpa, "{s}{s}", .{
            view.path orelse view.name,
            if (view.edited()) " *" else "",
        });
        pen.beginScissorMode(
            @intFromFloat(l.status.x),
            @intFromFloat(l.status.y),
            @intFromFloat(@max(right_x - l.status.x - layout.padding, 0)),
            @intFromFloat(l.status.height),
        );
        app.font.draw(
            try terminate(&e.status),
            l.status.x + layout.padding,
            y,
            theme.current.status_text,
        );
        pen.endScissorMode();

        app.font.draw(label, right_x, y, theme.current.status_text);
    }

    /// The Find / Open panel, with its suggestion list.
    fn drawPrompt(e: *Self, l: Layout, cell: Metrics) !void {
        if (!app.prompt.active) return;

        const shown = @min(app.prompt.matches.items.len, max_suggestions);
        const panel = layout.promptPanel(l, cell, shown);

        pen.drawRectangleRec(panel, theme.current.tab_background);
        pen.drawRectangleLinesEx(panel, 1, theme.current.scrollbar);

        // Label and what has been typed, with a block for the caret.
        e.status.clearRetainingCapacity();
        if (app.prompt.kind == .browse or app.prompt.kind == .save_into) {
            const verb = if (app.prompt.kind == .save_into) "Save into " else "";
            try e.status.print(app.gpa, "{s}{s}/ {s}", .{ verb, app.browser.dir, app.prompt.text() });
        } else {
            try e.status.print(app.gpa, "{s}{s}", .{ app.prompt.label(), app.prompt.text() });
        }
        const typed = try terminate(&e.status);
        app.font.draw(typed, panel.x + layout.padding, panel.y + layout.padding, theme.current.text);
        pen.drawRectangleRec(.{
            .x = panel.x + layout.padding + app.font.widthOf(typed),
            .y = panel.y + layout.padding,
            .width = @max(cell.width * 0.12, 1),
            .height = cell.height,
        }, theme.current.caret);

        if (app.prompt.options.len == 0) return;
        if (app.prompt.matches.items.len == 0) {
            app.font.draw(
                "no matches",
                panel.x + layout.padding,
                panel.y + cell.height + layout.padding * 2,
                theme.current.hint,
            );
            return;
        }

        const point = pen.getMousePosition();
        for (app.prompt.matches.items[0..shown], 0..) |option, row| {
            const rect = layout.promptRow(panel, cell, row);
            const hot = row == app.prompt.option or pen.checkCollisionPointRec(point, rect);
            if (hot) pen.drawRectangleRec(rect, theme.current.selection);

            e.status.clearRetainingCapacity();
            try e.status.appendSlice(app.gpa, app.prompt.options[option]);
            app.font.draw(
                try terminate(&e.status),
                rect.x + layout.padding,
                rect.y + (rect.height - cell.height) / 2,
                if (hot) theme.current.tab_text_active else theme.current.status_text,
            );
        }
    }

    fn drawHint(l: Layout, cell: Metrics) !void {
        pen.drawRectangleRec(l.text, theme.current.background);
        pen.drawRectangleRec(l.gutter, theme.current.background);
        pen.drawRectangleRec(l.status, theme.current.status_background);

        const message = "Drop a file here, or press Ctrl+N";
        app.font.draw(
            message,
            l.text.x + @max((l.text.width - app.font.widthOf(message)) / 2, layout.padding),
            l.text.y + (l.text.height - cell.height) / 2,
            theme.current.hint,
        );
    }
};

fn drawMenu(l: Layout, cell: Metrics) void {
    pen.drawRectangleRec(l.menu, theme.current.status_background);
    const point = pen.getMousePosition();

    for (menu.bar, 0..) |group, i| {
        const rect = menu.titleRect(i, l, app.font);
        const active = app.menu.open == i;
        if (active or pen.checkCollisionPointRec(point, rect)) {
            pen.drawRectangleRec(rect, theme.current.tab_active);
        }
        app.font.draw(
            group.title,
            rect.x + layout.padding,
            rect.y + (rect.height - cell.height) / 2,
            if (active) theme.current.tab_text_active else theme.current.tab_text,
        );
    }

    if (app.menu.open) |index| drawDropdown(index, l, cell, point);
    if (app.menu.showing_about) drawAbout(l, cell);
}

fn drawDropdown(index: usize, l: Layout, cell: Metrics, point: pen.Vector2) void {
    const panel = menu.dropdownRect(index, l, app.font);
    pen.drawRectangleRec(panel, theme.current.tab_background);
    pen.drawRectangleLinesEx(panel, 1, theme.current.scrollbar);

    for (menu.bar[index].entries, 0..) |entry, row| {
        const rect = menu.entryRect(index, row, l, app.font);
        const hot = pen.checkCollisionPointRec(point, rect);
        if (hot) pen.drawRectangleRec(rect, theme.current.selection);

        const y = rect.y + (rect.height - cell.height) / 2;
        app.font.draw(
            entry.label,
            rect.x + layout.padding,
            y,
            if (hot) theme.current.tab_text_active else theme.current.text,
        );
        if (entry.shortcut.len > 0) {
            app.font.draw(
                entry.shortcut,
                layout.rightAlign(rect, app.font.widthOf(entry.shortcut)),
                y,
                theme.current.gutter_text,
            );
        }
    }
}

var about_storage: [8][160]u8 = undefined;

fn drawAbout(l: Layout, cell: Metrics) void {
    const builtin = @import("builtin");
    var lines: [8][:0]const u8 = undefined;
    var count: usize = 0;

    const add = struct {
        fn go(out: *[8][:0]const u8, n: *usize, comptime fmt: []const u8, args: anytype) void {
            out[n.*] = std.fmt.bufPrintZ(&about_storage[n.*], fmt, args) catch "";
            n.* += 1;
        }
    }.go;

    add(&lines, &count, "Zimacs {s}", .{app.version});
    add(&lines, &count, "", .{});
    add(&lines, &count, "A text editor written in Zig.", .{});
    add(&lines, &count, "Zig {f} on {s}-{s}", .{
        builtin.zig_version,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
    add(&lines, &count, "", .{});
    add(&lines, &count, "Settings: {s}", .{app.config_path orelse "(none)"});
    add(&lines, &count, "", .{});
    add(&lines, &count, "Click anywhere to close.", .{});

    var widest: f32 = 0;
    for (lines[0..count]) |line| widest = @max(widest, app.font.widthOf(line));

    const width = widest + layout.padding * 4;
    const panel = pen.Rectangle{
        .x = l.text.x + @max((l.text.width - width) / 2, 0),
        .y = l.text.y + l.text.height / 5,
        .width = width,
        .height = @as(f32, @floatFromInt(count)) * cell.height + layout.padding * 4,
    };

    // Dim what is behind so the panel reads as being on top.
    pen.drawRectangleRec(
        .{ .x = 0, .y = 0, .width = l.status.width, .height = l.status.y + l.status.height },
        .{ .r = 0, .g = 0, .b = 0, .a = 160 },
    );
    pen.drawRectangleRec(panel, theme.current.tab_background);
    pen.drawRectangleLinesEx(panel, 1, theme.current.scrollbar);

    for (lines[0..count], 0..) |line, i| {
        app.font.draw(
            line,
            panel.x + layout.padding * 2,
            panel.y + layout.padding * 2 + @as(f32, @floatFromInt(i)) * cell.height,
            if (i == 0) theme.current.tab_text_active else theme.current.status_text,
        );
    }
}

/// How many suggestions the prompt shows at once.
pub const max_suggestions: usize = 8;

/// Which suggestion row is under `point`, if the prompt is open.
pub fn promptRowAt(point: pen.Vector2, l: Layout, cell: Metrics) ?usize {
    if (!app.prompt.active) return null;
    const shown = @min(app.prompt.matches.items.len, max_suggestions);
    const panel = layout.promptPanel(l, cell, shown);
    var row: usize = 0;
    while (row < shown) : (row += 1) {
        if (pen.checkCollisionPointRec(point, layout.promptRow(panel, cell, row))) return row;
    }
    return null;
}

/// The layout for this frame, sized to the buffer that is showing.
pub fn currentLayout() Layout {
    const lines = if (app.buffer.current()) |v| v.tree.lineCount() else 1;
    return Layout.compute(app.font.metrics, lines, app.buffer.views.items.len > 0);
}

/// How many whole columns of text fit across the text area.
pub fn visibleColumns(l: Layout, cell: Metrics) u32 {
    const n = @floor((l.text.width - layout.padding * 2) / cell.width);
    return if (n <= 0) 0 else @intFromFloat(n);
}

/// Where tab `index` sits, or null if it has scrolled off the right edge.
pub fn tabRect(index: usize, l: Layout) ?pen.Rectangle {
    var x = l.tabs.x;
    for (app.buffer.views.items, 0..) |view, i| {
        const width = tabWidth(view);
        if (i == index) {
            if (x >= l.tabs.x + l.tabs.width) return null;
            return .{ .x = x, .y = l.tabs.y, .width = width, .height = l.tabs.height };
        }
        x += width;
    }
    return null;
}

/// Which tab is under `point`, if any.
pub fn tabAt(point: pen.Vector2, l: Layout) ?usize {
    if (!pen.checkCollisionPointRec(point, l.tabs)) return null;
    for (app.buffer.views.items, 0..) |_, i| {
        const rect = tabRect(i, l) orelse continue;
        if (pen.checkCollisionPointRec(point, rect)) return i;
    }
    return null;
}

fn tabWidth(view: *BufferView) f32 {
    var label_buf: [160]u8 = undefined;
    return app.font.widthOf(tabLabel(&label_buf, view)) + layout.padding * 2 + closeSize() + layout.padding;
}

fn closeSize() f32 {
    return app.font.metrics.height * 0.7;
}

/// The little cross at the right of a tab.
pub fn tabCloseRect(index: usize, l: Layout) ?pen.Rectangle {
    const tab = tabRect(index, l) orelse return null;
    const size = closeSize();
    return .{
        .x = tab.x + tab.width - size - layout.padding / 2,
        .y = tab.y + (tab.height - size) / 2,
        .width = size,
        .height = size,
    };
}

/// Which tab's close button is under `point`, if any.
pub fn closeAt(point: pen.Vector2, l: Layout) ?usize {
    if (!pen.checkCollisionPointRec(point, l.tabs)) return null;
    for (app.buffer.views.items, 0..) |_, i| {
        const rect = tabCloseRect(i, l) orelse continue;
        if (pen.checkCollisionPointRec(point, rect)) return i;
    }
    return null;
}

fn drawCross(rect: pen.Rectangle, colour: pen.Color) void {
    const inset = rect.width * 0.3;
    const a = pen.Vector2{ .x = rect.x + inset, .y = rect.y + inset };
    const b = pen.Vector2{ .x = rect.x + rect.width - inset, .y = rect.y + rect.height - inset };
    pen.drawLineEx(a, b, 1.5, colour);
    pen.drawLineEx(
        .{ .x = b.x, .y = a.y },
        .{ .x = a.x, .y = b.y },
        1.5,
        colour,
    );
}

fn tabLabel(buf: []u8, view: *BufferView) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}{s}", .{
        view.name,
        if (view.edited()) " *" else "",
    }) catch "...";
}

/// raylib needs a NUL-terminated string; the buffer keeps its capacity.
fn terminate(buf: *std.ArrayList(u8)) ![:0]const u8 {
    try buf.append(app.gpa, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}
