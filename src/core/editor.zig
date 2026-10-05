//! Draws everything: the tab bar, line numbers, the text with its selection
//! and caret, the scrollbars and the status bar.
//!
//! Only the lines currently on screen are touched and the scratch buffers are
//! reused, so a steady frame allocates nothing however large the file.

const std = @import("std");
const builtin = @import("builtin");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const theme = @import("theme.zig");
const layout = @import("layout.zig");
const text = @import("text.zig");
const menu = @import("menu.zig");
const titlebar = @import("titlebar.zig");
const find_mod = @import("find.zig");
const search = @import("search.zig");
const commands = @import("commands.zig");
const TextField = @import("field.zig").TextField;
const TabStrip = @import("tabstrip.zig").TabStrip;
const dialog_mod = @import("dialog.zig");
const wrap = @import("wrap.zig");
const update_mod = @import("update.zig");
const Artifact = @import("artifact.zig").Artifact;
const BufferView = @import("buffer.zig").BufferView;
const Metrics = @import("font.zig").Metrics;
const Layout = layout.Layout;
const Range = @import("cursor.zig").Range;
const brackets = @import("brackets.zig");
const syntax = @import("syntax.zig");
const widgets = @import("widgets.zig");
const welcome = @import("welcome.zig");

pub const Editor = struct {
    /// One line as stored, then the same line with tabs expanded.
    raw: std.ArrayList(u8) = .empty,
    shown: std.ArrayList(u8) = .empty,
    status: std.ArrayList(u8) = .empty,
    /// For each screen row, the document line it starts, or null when it is
    /// the continuation of a folded line. Filled while drawing the text and
    /// read by the gutter, so the two cannot disagree.
    row_lines: std.ArrayList(?u32) = .empty,
    /// Search matches on screen this frame.
    matches: std.ArrayList(search.Match) = .empty,
    /// Where the rows of the line being drawn start, while lines are folded:
    /// as screen columns, and as byte offsets into the line.
    starts: std.ArrayList(u32) = .empty,
    row_bytes: std.ArrayList(u32) = .empty,
    /// What each byte of the row being drawn is, for its colour.
    kinds: std.ArrayList(syntax.Kind) = .empty,
    /// The brackets marked around the caret, looked for again only when the
    /// caret or the text changes.
    bracket_pair: ?brackets.Pair = null,
    bracket_key: ?CaretKey = null,
    /// The caret's screen column, kept the same way: finding it reads the
    /// whole line, which may be megabytes long.
    caret_column: u32 = 0,
    caret_column_key: ?CaretKey = null,
    tabs: TabStrip = .{},

    const Self = @This();

    /// What results worked out from the caret's place depend on.
    const CaretKey = struct { view: u64, version: u64, caret: u32 };

    fn caretKey(view: *const BufferView) CaretKey {
        return .{ .view = view.id, .version = view.version, .caret = view.cursor.offset };
    }

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

    pub fn deinit(ctx: *anyopaque) void {
        const e: *Self = @ptrCast(@alignCast(ctx));
        e.raw.deinit(app.gpa);
        e.shown.deinit(app.gpa);
        e.status.deinit(app.gpa);
        e.row_lines.deinit(app.gpa);
        e.matches.deinit(app.gpa);
        e.starts.deinit(app.gpa);
        e.row_bytes.deinit(app.gpa);
        e.kinds.deinit(app.gpa);
        e.tabs.deinit(app.gpa);
    }

    pub fn render(ctx: *anyopaque) !void {
        const e: *Self = @ptrCast(@alignCast(ctx));
        const cell = app.font.metrics;
        const l = currentLayout();

        drawSidebar(l, cell);
        const view = app.buffer.current();
        if (app.graph.shown) {
            drawGraph(l);
            if (view != null) try e.drawTabs(l);
        } else if (view) |v| {
            try e.follow(v, l, cell);
            try e.drawText(v, l, cell);
            try e.drawGutter(v, l, cell);
            drawScrollbars(v, l, cell);
            try e.drawTabs(l);
        } else drawWelcome(l, cell);
        try e.drawStatus(if (app.graph.shown) null else view, l, cell);
        try e.drawPrompt(l, cell);
        try drawFindBar(l, cell);
        // Last, so the dropdown and the About panel sit over everything else.
        drawMenu(l, cell);
        drawDialog(l, cell);
        drawFrame(l);
    }

    /// Scrolls vertically without moving the caret, by rows: lines, or
    /// screen rows while lines are folded.
    pub fn scroll(e: *Self, rows: i32) void {
        _ = e;
        const view = app.buffer.current() orelse return;
        const l = currentLayout();
        const cell = app.font.metrics;
        const next = @as(i64, scrollExtent(view, l, cell).top) + rows;
        scrollToRow(view, l, cell, if (next <= 0) 0 else @intCast(next));
    }

    pub fn scrollSideways(e: *Self, columns: i32) void {
        _ = e;
        const view = app.buffer.current() orelse return;
        const visible = currentLayout().columns(app.font.metrics);
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
        // The text may have shrunk under the view.
        defer scrollToRow(view, l, cell, scrollExtent(view, l, cell).top);

        if (view.followed) |seen| if (seen == view.cursor.offset) return;
        view.followed = view.cursor.offset;

        const at = view.cursor.position(&view.tree);
        const column = try e.caretColumn(view);
        const caret_row = if (app.config.wrap_lines) blk: {
            const fold = foldFor(l, cell);
            const placed = wrap.place(view.rows.breaksOf(&view.tree, fold, at.line), column);
            break :blk view.rows.above(&view.tree, fold, at.line) + placed.row;
        } else at.line;
        const top = scrollExtent(view, l, cell).top;
        if (caret_row < top) {
            scrollToRow(view, l, cell, caret_row);
        } else if (caret_row >= top + rows) {
            scrollToRow(view, l, cell, caret_row - rows + 1);
        }

        if (app.config.wrap_lines) {
            // Sideways scrolling has no meaning while lines are folded.
            view.left_column = 0;
            return;
        }

        const visible = l.columns(cell);
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
        _ = e;
        if (line < view.top_line) return null;
        if (!app.config.wrap_lines) {
            return .{ .row = line - view.top_line, .column = column };
        }

        const fold = foldFor(l, cell);
        const placed = wrap.place(view.rows.breaksOf(&view.tree, fold, line), column);
        const top = view.rows.above(&view.tree, fold, view.top_line) + view.top_row;
        const row = view.rows.above(&view.tree, fold, line) + placed.row;
        if (row < top) return null;
        return .{ .row = row - top, .column = placed.column };
    }

    /// The screen column of a byte offset within a line.
    fn caretColumn(e: *Self, view: *BufferView) !u32 {
        const key = caretKey(view);
        if (e.caret_column_key == null or !std.meta.eql(e.caret_column_key.?, key)) {
            const at = view.cursor.position(&view.tree);
            e.raw.clearRetainingCapacity();
            try view.tree.lineContent(at.line, &e.raw);
            e.caret_column = text.columnOf(e.raw.items, at.column, app.config.tab_width);
            e.caret_column_key = key;
        }
        return e.caret_column;
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
        const fold = foldFor(l, cell);

        e.row_lines.clearRetainingCapacity();
        try e.collectMatches(view, rows);
        const pair = if (selection == null) e.bracketsAround(view) else null;
        // Another slice of parsing, if the tree is behind the text.
        if (view.syntax) |s| s.step(&view.tree);
        const visible = l.columns(cell);

        var widest: u32 = 1;
        var row: u32 = 0;
        var line = view.top_line;
        var skip = if (wrapping) view.top_row else 0;

        while (row < rows and line < total) : (line += 1) {
            e.raw.clearRetainingCapacity();
            try view.tree.lineContent(line, &e.raw);
            // What the rows need of the line, in one pass over it rather
            // than one per row: a line can be megabytes long.
            var unfolded: text.Window = undefined;
            const columns = if (wrapping) blk: {
                try wrap.breaks(app.gpa, e.raw.items, fold, &e.starts);
                break :blk try text.offsetsAt(app.gpa, e.raw.items, e.starts.items, tab, &e.row_bytes);
            } else blk: {
                unfolded = text.window(e.raw.items, view.left_column, view.left_column + visible + 1, tab);
                break :blk unfolded.width;
            };
            widest = @max(widest, columns);

            const pieces: u32 = if (wrapping) @intCast(e.starts.items.len) else 1;
            var piece = skip;
            skip = 0;
            while (piece < pieces and row < rows) : ({
                piece += 1;
                row += 1;
            }) {
                try e.row_lines.append(app.gpa, if (piece == 0) line else null);

                const y = l.text.y + @as(f32, @floatFromInt(row)) * cell.height;
                const from = if (wrapping) e.starts.items[piece] else 0;
                const to = if (wrapping and piece + 1 < pieces) e.starts.items[piece + 1] else columns;
                const shown = ShownRow{ .line = line, .y = y, .columns = columns, .from = from, .to = to, .last = piece + 1 == pieces };

                if (line == active and selection == null) {
                    pen.drawRectangleRec(
                        .{ .x = l.text.x, .y = y, .width = l.text.width, .height = cell.height },
                        theme.current.current_line,
                    );
                }
                for (e.matches.items) |m| {
                    const range = Range{ .start = @intCast(m.start), .end = @intCast(m.end) };
                    e.drawSpan(view, l, cell, shown, range, theme.current.find_match);
                }
                if (selection) |range| {
                    e.drawSpan(view, l, cell, shown, range, theme.current.selection);
                }
                if (pair) |p| for ([_]u32{ p.open, p.close }) |at| {
                    const range = Range{ .start = at, .end = at + 1 };
                    e.drawSpan(view, l, cell, shown, range, theme.current.bracket_match);
                };
                if (e.raw.items.len == 0) continue;

                // Only the part of the line this row shows. Unfolded, that
                // is the columns scrolled into view.
                const origin = if (wrapping) from else view.left_column;
                const first: u32, const first_column: u32, const last: u32 = if (wrapping) .{
                    e.row_bytes.items[piece],
                    from,
                    if (piece + 1 < pieces) e.row_bytes.items[piece + 1] else @intCast(e.raw.items.len),
                } else .{ unfolded.first, unfolded.first_column, unfolded.last };
                try e.drawRowText(view, line, first, last, first_column, origin, l.text.x + layout.padding, y, cell);
            }
        }
        // Folded lines never scroll sideways.
        view.content_columns = if (wrapping) visible else widest;
        if (wrapping) view.left_column = 0;

        try e.drawCaret(view, l, cell);
    }

    /// Draws bytes `first` to `last` of `line`, held in `e.raw`, which start
    /// at screen column `column`, coloured by the view's highlighting.
    /// `origin` is the column that sits at `x`.
    fn drawRowText(
        e: *Self,
        view: *BufferView,
        line: u32,
        first: u32,
        last: u32,
        column: u32,
        origin: u32,
        x: f32,
        y: f32,
        cell: Metrics,
    ) !void {
        const len = last - first;
        e.kinds.clearRetainingCapacity();
        try e.kinds.appendNTimes(app.gpa, .none, len);
        const row_start = view.tree.lineStart(line) + first;
        const row_end = row_start + len;
        const spans = if (view.syntax) |s| s.highlights(&view.tree, row_start, row_end) else &.{};
        for (spans) |sp| {
            if (sp.start >= row_end) break;
            if (sp.end <= row_start) continue;
            @memset(e.kinds.items[@max(sp.start, row_start) - row_start .. @min(sp.end, row_end) - row_start], sp.kind);
        }

        var at: u32 = 0;
        var col = column;
        while (at < len) {
            const kind = e.kinds.items[at];
            var end = at + 1;
            while (end < len and e.kinds.items[end] == kind) end += 1;
            e.shown.clearRetainingCapacity();
            const next = try text.expandFrom(e.raw.items[first + at .. first + end], col, &e.shown, app.gpa, app.config.tab_width);
            const left = x + (@as(f32, @floatFromInt(col)) - @as(f32, @floatFromInt(origin))) * cell.width;
            app.font.draw(try terminate(&e.shown), left, y, syntaxColour(kind));
            col = next;
            at = end;
        }
    }

    fn bracketsAround(e: *Self, view: *const BufferView) ?brackets.Pair {
        const key = caretKey(view);
        if (e.bracket_key == null or !std.meta.eql(e.bracket_key.?, key)) {
            e.bracket_key = key;
            e.bracket_pair = brackets.match(&view.tree, key.caret);
        }
        return e.bracket_pair;
    }

    fn collectMatches(e: *Self, view: *BufferView, rows: u32) !void {
        e.matches.clearRetainingCapacity();
        const f = &app.find;
        if (!f.open or f.query.value().len == 0) return;
        try f.sync(view);
        const last = @min(view.top_line + rows, view.tree.lineCount() - 1);
        try f.matchesIn(view.tree.lineStart(view.top_line), view.tree.lineEnd(last), &e.matches);
    }

    /// Paints the part of a byte range that falls on one screen row.
    /// One screen row of a line: which columns of it the row shows.
    const ShownRow = struct {
        line: u32,
        y: f32,
        /// The whole line's width.
        columns: u32,
        from: u32,
        to: u32,
        /// The line's last row, which ends where the line does.
        last: bool,
    };

    fn drawSpan(e: *Self, view: *BufferView, l: Layout, cell: Metrics, row: ShownRow, range: Range, colour: pen.Color) void {
        const line = row.line;
        const start = view.tree.lineStart(line);
        // Reach one column past the text so a selection spanning several lines
        // looks continuous rather than ragged.
        const stop = view.tree.lineEnd(line) + @intFromBool(line + 1 < view.tree.lineCount());
        // Starting on the next line means not this line's line break.
        if (range.end <= start or range.start >= stop) return;

        const tab = app.config.tab_width;
        const from_byte = @max(range.start, start) - start;
        const to_byte = @min(range.end, stop) - start;

        const selected_from = text.columnOf(e.raw.items, from_byte, tab);
        const selected_to = if (to_byte > e.raw.items.len)
            row.columns + 1
        else
            text.columnOf(e.raw.items, to_byte, tab);

        // Clip to the slice of the line this row is showing; only its last
        // row reaches past the text.
        const from = @max(selected_from, row.from);
        const to = @min(selected_to, row.to + @intFromBool(row.last));
        if (to <= from) return;

        const origin = if (app.config.wrap_lines) row.from else view.left_column;
        if (to <= origin) return;
        const first = @max(from, origin) - origin;
        const last = to - origin;
        pen.drawRectangleRec(.{
            .x = l.text.x + layout.padding + @as(f32, @floatFromInt(first)) * cell.width,
            .y = row.y,
            .width = @max(@as(f32, @floatFromInt(last - first)) * cell.width, 2),
            .height = cell.height,
        }, colour);
    }

    fn drawCaret(e: *Self, view: *BufferView, l: Layout, cell: Metrics) !void {
        const at = view.cursor.position(&view.tree);
        const column = try e.caretColumn(view);

        const placed = try e.screenRowOf(view, l, cell, at.line, column) orelse return;
        if (placed.row >= l.rows(cell)) return;
        if (placed.column < view.left_column) return;

        const x = l.text.x + layout.padding +
            @as(f32, @floatFromInt(placed.column - view.left_column)) * cell.width;
        const y = l.text.y + @as(f32, @floatFromInt(placed.row)) * cell.height;

        const shape: pen.Rectangle = switch (app.config.caret_style) {
            .line => .{ .x = x, .y = y, .width = lineCaretWidth(cell), .height = cell.height },
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
        const extent = scrollExtent(view, l, cell);
        if (layout.thumb(l.scrollbar, extent.top, l.rows(cell), extent.total)) |bar| {
            pen.drawRectangleRounded(bar, thumb_roundness, round_segments, if (pen.checkCollisionPointRec(pointer, l.scrollbar))
                theme.current.scrollbar_hover
            else
                theme.current.scrollbar);
        }

        const track = layout.horizontalTrack(l);
        const visible = l.columns(cell);
        if (layout.horizontalThumb(track, view.left_column, visible, view.content_columns)) |bar| {
            pen.drawRectangleRounded(bar, thumb_roundness, round_segments, if (pen.checkCollisionPointRec(pointer, track))
                theme.current.scrollbar_hover
            else
                theme.current.scrollbar);
        }
    }

    /// How the folder search is going, at the right of its query.
    fn drawSearchCount(panel: pen.Rectangle) void {
        const s = &app.folder_search;
        var buf: [max_row_label]u8 = undefined;
        const count: [:0]const u8 = if (s.running.load(.acquire))
            "searching..."
        else if (s.query.items.len == 0)
            ""
        else if (s.hits().len == 0)
            "no matches"
        else
            std.fmt.bufPrintZ(&buf, "{d}{s} found", .{ s.hits().len, if (s.cutShort()) "+" else "" }) catch "";
        const x = panel.x + panel.width - layout.padding - app.font.widthOf(count);
        app.font.draw(count, x, panel.y + layout.padding, theme.current.hint);
    }

    /// The folder tree: a row naming the folder, then what is in it, with
    /// the file in front marked.
    fn drawSidebar(l: Layout, cell: Metrics) void {
        if (l.sidebar.width <= 0) return;
        const t = theme.current;
        pen.drawRectangleRec(l.sidebar, t.tab_background);
        pen.beginScissorMode(
            @intFromFloat(l.sidebar.x),
            @intFromFloat(l.sidebar.y),
            @intFromFloat(l.sidebar.width),
            @intFromFloat(l.sidebar.height),
        );
        defer pen.endScissorMode();

        const row_height = layout.listRowHeight(cell);
        const inset = (row_height - cell.height) / 2;
        var label_buf: [max_row_label]u8 = undefined;
        const heading = std.fmt.bufPrintZ(&label_buf, "{s}", .{app.workspace.name()}) catch "";
        app.font.draw(heading, l.sidebar.x + layout.padding, l.sidebar.y + inset, t.hint);

        const active = if (app.buffer.current()) |v| if (v.path) |p| app.workspace.relativeOf(p) else null else null;
        const point = pen.getMousePosition();
        const indent = cell.width * sidebar_indent_columns;
        var y = layout.sidebarRowsTop(l, cell);
        for (app.sidebar.rows.items[app.sidebar.top..]) |row| {
            if (y >= l.sidebar.y + l.sidebar.height) break;
            defer y += row_height;
            const rect = pen.Rectangle{ .x = l.sidebar.x, .y = y, .width = l.sidebar.width, .height = row_height };
            const is_active = !row.folder and active != null and std.mem.eql(u8, row.path, active.?);
            if (is_active) {
                pen.drawRectangleRec(rect, t.tab_active);
            } else if (pen.checkCollisionPointRec(point, rect)) {
                pen.drawRectangleRec(rect, t.current_line);
            }
            const x = l.sidebar.x + layout.padding + @as(f32, @floatFromInt(row.depth)) * indent;
            if (row.folder) {
                widgets.drawChevron(.{ .x = x, .y = y, .width = row_height, .height = row_height }, if (row.open) .down else .right, t.tab_text);
            }
            const name = std.fmt.bufPrintZ(&label_buf, "{s}", .{row.name}) catch continue;
            app.font.draw(name, x + row_height, y + inset, if (is_active) t.tab_text_active else t.tab_text);
        }
        // The edge against the tabs and text.
        pen.drawRectangleRec(.{ .x = l.sidebar.x + l.sidebar.width - 1, .y = l.sidebar.y, .width = 1, .height = l.sidebar.height }, t.current_line);
    }

    fn drawTabs(e: *Self, l: Layout) !void {
        if (l.tabs.height <= 0) return;
        e.tabs.widths.clearRetainingCapacity();
        for (app.buffer.views.items) |view| try e.tabs.widths.append(app.gpa, tabWidth(view));
        e.tabs.close_size = closeSize();
        e.tabs.new_size = app.font.metrics.height * new_tab_share;
        e.tabs.update(l.tabs.width, app.buffer.active);

        pen.drawRectangleRec(l.tabs, theme.current.tab_background);
        const point = pen.getMousePosition();
        const new_tab = e.tabs.newRect(l.tabs);
        const new_hot = pen.checkCollisionPointRec(point, new_tab);
        if (new_hot) pen.drawRectangleRounded(new_tab, close_roundness, round_segments, theme.current.selection);
        widgets.drawPlus(new_tab, if (new_hot) theme.current.tab_text_active else theme.current.tab_text);

        const area = e.tabs.tabArea(l.tabs);
        pen.beginScissorMode(
            @intFromFloat(area.x),
            @intFromFloat(area.y),
            @intFromFloat(area.width),
            @intFromFloat(area.height),
        );
        defer pen.endScissorMode();

        for (app.buffer.views.items, 0..) |view, i| {
            const rect = e.tabs.rect(l.tabs, i) orelse continue;
            const is_active = i == app.buffer.active;
            if (is_active) pen.drawRectangleRec(rect, theme.current.tab_active);

            var label_buf: [160]u8 = undefined;
            app.font.draw(
                tabLabel(&label_buf, view),
                rect.x + layout.padding,
                rect.y + (rect.height - app.font.metrics.height) / 2,
                if (is_active) theme.current.tab_text_active else theme.current.tab_text,
            );

            if (e.tabs.closeRect(l.tabs, i)) |close| {
                const hot = pen.checkCollisionPointRec(point, close);
                if (hot) pen.drawRectangleRounded(close, close_roundness, round_segments, theme.current.selection);
                widgets.drawCross(close, if (hot or is_active)
                    theme.current.tab_text_active
                else
                    theme.current.tab_text);
            }
        }
        drawOverflowFades(area, e.tabs);
    }

    fn drawStatus(e: *Self, view: ?*BufferView, l: Layout, cell: Metrics) !void {
        pen.drawRectangleRec(l.status, theme.current.status_background);
        const y = l.status.y + (l.status.height - cell.height) / 2;

        // The position readout is measured first so the file name knows how
        // much room is left, and is clipped rather than running under it.
        var label_buf: [96]u8 = undefined;
        const label: ?[:0]const u8 = if (view) |v| label: {
            // Reported as screen columns, so it agrees with where the caret
            // is drawn on a line holding tabs or multi-byte characters.
            const at = .{
                .line = v.cursor.position(&v.tree).line + 1,
                .column = (try e.caretColumn(v)) + 1,
            };
            break :label if (v.cursor.selection()) |sel|
                std.fmt.bufPrintZ(&label_buf, "{d} selected    Ln {d}, Col {d}", .{ sel.len(), at.line, at.column }) catch return
            else
                std.fmt.bufPrintZ(&label_buf, "Ln {d}, Col {d}", .{ at.line, at.column }) catch return;
        } else null;

        // Right to left: position, language and file format, update state,
        // then a notice.
        var format_buf: [64]u8 = undefined;
        const format: ?[:0]const u8 = if (view) |v| std.fmt.bufPrintZ(&format_buf, "{s}  {s}  {s}", .{
            v.language.name, v.format.encoding.label(), v.format.line_ending.label(),
        }) catch "" else null;
        const t = theme.current;
        const segments = [_]?Segment{
            if (label) |s| Segment{ .text = s, .colour = t.status_text } else null,
            if (format) |s| Segment{ .text = s, .colour = t.status_text } else null,
            if (updateNotice()) |n| Segment{ .text = n, .colour = if (app.update.status() == .available) t.caret else t.hint } else null,
            if (app.notice.text(pen.getTime())) |n| Segment{ .text = n, .colour = if (app.notice.kind == .problem) t.warning else t.status_text } else null,
        };
        var right_x = l.status.x + l.status.width - layout.padding;
        for (segments) |maybe| {
            const seg = maybe orelse continue;
            right_x -= app.font.widthOf(seg.text);
            app.font.draw(seg.text, right_x, y, seg.colour);
            right_x -= layout.padding * 3;
        }

        e.status.clearRetainingCapacity();
        if (app.graph.shown) {
            try e.status.print(app.gpa, "{d} notes, {d} links", .{ app.graph.nodes.items.len, app.graph.edges.items.len });
        } else {
            const v = view orelse return;
            try e.status.print(app.gpa, "{s}{s}", .{ v.path orelse v.name, if (v.edited()) " *" else "" });
        }
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
    }

    /// The prompt, for opening, saving, going to a line and browsing, with
    /// its suggestion list.
    fn drawPrompt(e: *Self, l: Layout, cell: Metrics) !void {
        if (!app.prompt.active) return;

        const shown = app.prompt.shown();
        const panel = layout.promptPanel(l, cell, shown);

        pen.drawRectangleRec(panel, theme.current.tab_background);
        pen.drawRectangleLinesEx(panel, 1, theme.current.scrollbar);

        // Label and what has been typed, with a block for the caret. What
        // follows the label is cut from the start to fit, so the end of what
        // is being typed always shows.
        const browsing = app.prompt.kind == .browse or app.prompt.kind == .save_into;
        const label = if (app.prompt.kind == .save_into) "Save into " else app.prompt.label();
        e.status.clearRetainingCapacity();
        if (browsing) {
            try e.status.print(app.gpa, "{s}/ {s}", .{ app.browser.dir, app.prompt.text() });
        } else {
            try e.status.appendSlice(app.gpa, app.prompt.text());
        }
        const columns: u32 = @intFromFloat(@max((panel.width - layout.padding * 2) / cell.width, 0));
        var fitted_buf: [prompt_line_capacity]u8 = undefined;
        // One column is left for the caret.
        const fitted = text.fitStart(&fitted_buf, e.status.items, columns -| 1 -| @as(u32, @intCast(label.len)));
        e.status.clearRetainingCapacity();
        try e.status.print(app.gpa, "{s}{s}", .{ label, fitted });
        const typed = try terminate(&e.status);
        app.font.draw(typed, panel.x + layout.padding, panel.y + layout.padding, theme.current.text);
        pen.drawRectangleRec(.{
            .x = panel.x + layout.padding + app.font.widthOf(typed),
            .y = panel.y + layout.padding,
            .width = lineCaretWidth(cell),
            .height = cell.height,
        }, theme.current.caret);

        if (app.prompt.kind == .search_folder) drawSearchCount(panel);
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
        for (app.prompt.visible(), 0..) |option, row| {
            const rect = layout.promptRow(panel, cell, row);
            const hot = app.prompt.first + row == app.prompt.highlighted() or pen.checkCollisionPointRec(point, rect);
            if (hot) pen.drawRectangleRec(rect, theme.current.selection);

            // Paths lose their start, so the name shows; a search hit keeps
            // its path and loses the end of its line.
            const whole = app.prompt.options[option];
            const shown_part = if (app.prompt.kind == .search_folder)
                whole[0..text.offsetOf(whole, columns, 1)]
            else
                text.fitStart(&fitted_buf, whole, columns);
            e.status.clearRetainingCapacity();
            try e.status.appendSlice(app.gpa, shown_part);
            app.font.draw(
                try terminate(&e.status),
                rect.x + layout.padding,
                rect.y + (rect.height - cell.height) / 2,
                if (hot) theme.current.tab_text_active else theme.current.status_text,
            );
        }
    }

    /// The folder's notes as dots and their links as lines. The note in
    /// front, and the dot under the pointer with its neighbours, stand out.
    fn drawGraph(l: Layout) void {
        const g = &app.graph;
        const t = theme.current;
        const area = l.body();
        pen.drawRectangleRec(area, t.background);
        pen.beginScissorMode(@intFromFloat(area.x), @intFromFloat(area.y), @intFromFloat(area.width), @intFromFloat(area.height));
        defer pen.endScissorMode();

        if (g.nodes.items.len == 0) {
            const width = app.font.widthOf(no_notes);
            app.font.draw(no_notes, area.x + (area.width - width) / 2, area.y + (area.height - app.font.metrics.height) / 2, t.hint);
            return;
        }
        const current = currentNote();
        for (g.edges.items) |edge| {
            const lit = g.hovered != null and (g.hovered == edge.from or g.hovered == edge.to);
            pen.drawLineEx(g.dot(edge.from, area), g.dot(edge.to, area), if (lit) graph_lit_line else graph_line, if (lit) t.syntax_tag else t.scrollbar);
        }
        for (g.nodes.items, 0..) |node, n| {
            const i: u32 = @intCast(n);
            const at = g.dot(i, area);
            const r = g.radius(i);
            if (!pen.checkCollisionPointRec(at, grown(area, r))) continue;
            const colour = if (current == i) t.caret else if (g.lit.items[i]) t.syntax_tag else if (node.missing()) t.gutter_text else t.gutter_text_active;
            pen.drawCircleV(at, r, colour);
        }
        var buf: [graph_label_bytes]u8 = undefined;
        for (g.nodes.items, 0..) |node, n| {
            const i: u32 = @intCast(n);
            if (!g.labelled(i)) continue;
            const at = g.dot(i, area);
            if (!pen.checkCollisionPointRec(at, area)) continue;
            const label = std.fmt.bufPrintZ(&buf, "{s}", .{node.name()}) catch continue;
            const x = at.x - app.font.widthOf(label) / 2;
            app.font.draw(label, x, at.y + g.radius(i) + layout.padding / 2, if (g.lit.items[i]) t.text else t.gutter_text);
        }
    }

    /// The graph's dot for the note in front, if it is one.
    fn currentNote() ?u32 {
        const view = app.buffer.current() orelse return null;
        return app.graph.find(app.workspace.relativeOf(view.path orelse return null) orelse return null);
    }

    /// With no tab open: buttons to start, and what was opened lately.
    fn drawWelcome(l: Layout, cell: Metrics) void {
        const t = theme.current;
        pen.drawRectangleRec(l.text, t.background);
        pen.drawRectangleRec(l.gutter, t.background);

        var rows_buf: [welcome.max_rows]welcome.Row = undefined;
        const rows = welcome.rows(app.recent_folders.items(), app.recent.items(), &rows_buf);
        const g = welcome.geometry(l, cell, rows.len);
        const point = pen.getMousePosition();
        const inset = (g.buttons[0].height - cell.height) / 2;
        for (welcome.actions, g.buttons) |action, rect| {
            const entry = menu.entryFor(action) orelse continue;
            widgets.drawIconButton(rect, point);
            pen.drawRectangleLinesEx(rect, 1, t.scrollbar);
            app.font.draw(entry.label, rect.x + layout.padding, rect.y + inset, widgets.hoverInk(rect, point));
            const keys_x = rect.x + rect.width - layout.padding - app.font.widthOf(entry.shortcut);
            app.font.draw(entry.shortcut, keys_x, rect.y + inset, t.hint);
        }
        if (rows.len == 0) return;

        const row_inset = (g.first_row.height - cell.height) / 2;
        app.font.draw("Recent", g.first_row.x, g.heading_y + row_inset, t.hint);
        var label_buf: [max_row_label]u8 = undefined;
        for (rows, 0..) |row, i| {
            const rect = g.row(i);
            if (pen.checkCollisionPointRec(point, rect)) pen.drawRectangleRec(rect, t.current_line);
            const name = std.fmt.bufPrintZ(&label_buf, "{s}{s}", .{ std.fs.path.basename(row.path), if (row.folder) "/" else "" }) catch continue;
            const x = rect.x + layout.padding;
            const y = rect.y + row_inset;
            app.font.draw(name, x, y, t.text);
            // Where it is, cut from the start to fit what room is left.
            const after = x + app.font.widthOf(name) + cell.width * 2;
            const room: u32 = @intFromFloat(@max((rect.x + rect.width - layout.padding - after) / cell.width, 0));
            const where = text.fitStart(&label_buf, std.fs.path.dirname(row.path) orelse "", room);
            app.font.draw(where, after, y, t.hint);
        }
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

    if (app.window.custom_frame) drawTitlebar(l, cell, point);
    if (app.menu.panel(l, app.font)) |panel| drawPanel(panel, cell, point);
    if (app.menu.showing_about) drawAbout(l, cell);
}

fn drawTitlebar(l: Layout, cell: Metrics, point: pen.Vector2) void {
    var buf: [256]u8 = undefined;
    const folder = app.workspace.name();
    const title: [:0]const u8 = if (app.buffer.current()) |v|
        (if (folder.len > 0)
            std.fmt.bufPrintZ(&buf, "{s} - {s} - Zimacs", .{ v.name, folder })
        else
            std.fmt.bufPrintZ(&buf, "{s} - Zimacs", .{v.name})) catch "Zimacs"
    else
        "Zimacs";
    if (titlebar.titleRect(app.font.widthOf(title), l, app.font)) |rect| {
        app.font.draw(title, rect.x, rect.y + (rect.height - cell.height) / 2, theme.current.tab_text);
    }

    for (titlebar.buttons) |b| {
        const rect = titlebar.buttonRect(b, l);
        const hovered = pen.checkCollisionPointRec(point, rect);
        if (hovered) pen.drawRectangleRec(rect, if (b == .close) theme.current.close_hover else theme.current.tab_active);
        const ink = if (hovered and b == .close)
            theme.current.close_hover_text
        else if (hovered)
            theme.current.tab_text_active
        else
            theme.current.tab_text;
        widgets.drawCaptionGlyph(b, rect, ink);
    }
}

// --------------------------------------------------------------- dialog

/// How much the window behind a dialog is dimmed.
const dim_alpha = 0.55;

/// Dims the whole window, so a panel drawn next reads as being on top.
fn dimBehind(l: Layout) void {
    const window = pen.Rectangle{ .x = 0, .y = 0, .width = l.menu.width, .height = l.status.y + l.status.height };
    pen.drawRectangleRec(window, pen.fade(theme.current.tab_background, dim_alpha));
}

fn drawDialog(l: Layout, cell: Metrics) void {
    const q = app.dialog.question orelse return;
    const t = theme.current;
    dimBehind(l);

    const g = dialog_mod.geometry(l, app.font, q);
    pen.drawRectangleRec(g.panel, t.tab_background);
    pen.drawRectangleLinesEx(g.panel, 1, t.scrollbar);

    var title_buf: [dialog_mod.title_capacity]u8 = undefined;
    const x = g.panel.x + layout.padding * 3;
    const top = g.panel.y + layout.padding * 3;
    app.font.draw(dialog_mod.title(&title_buf, q), x, top, t.tab_text_active);
    app.font.draw(dialog_mod.detail(q), x, top + cell.height + layout.padding / 2, t.hint);

    const point = pen.getMousePosition();
    for (g.buttons[0..g.count], q.answers(), 0..) |r, a, i| {
        const focused = i == app.dialog.focus;
        const hot = pen.checkCollisionPointRec(point, r);
        pen.drawRectangleRec(r, if (focused) t.selection else if (hot) t.tab_active else t.background);
        pen.drawRectangleLinesEx(r, 1, if (focused) t.caret else t.scrollbar);
        const text_label = dialog_mod.label(a);
        const tx = r.x + (r.width - app.font.widthOf(text_label)) / 2;
        app.font.draw(text_label, tx, r.y + (r.height - cell.height) / 2, if (focused or hot) t.tab_text_active else t.text);
    }
}

// ------------------------------------------------------------- find bar

fn drawFindBar(l: Layout, cell: Metrics) !void {
    const f = &app.find;
    if (!f.open) return;
    const view = app.buffer.current() orelse return;
    try f.sync(view);

    const g = find_mod.geometry(l, app.font, f.replacing);
    const point = pen.getMousePosition();
    const t = theme.current;

    pen.drawRectangleRec(g.panel, t.tab_background);
    pen.drawRectangleLinesEx(g.panel, 1, t.scrollbar);

    widgets.drawChevron(g.expand, if (f.replacing) .down else .right, widgets.hoverInk(g.expand, point));
    widgets.drawField(&f.query, g.find_field, f.focus == .find, "Find", cell);
    if (f.replacing) widgets.drawField(&f.replacement, g.replace_field, f.focus == .replace, "Replace", cell);

    widgets.drawToggle(g.match_case, "Aa", f.options.match_case, point, cell);
    widgets.drawToggle(g.whole_word, "ab", f.options.whole_word, point, cell);
    // Whole word is conventionally "ab" underlined.
    const word = g.whole_word;
    pen.drawRectangleRec(.{ .x = word.x + layout.padding / 2 + cell.width * 0.5, .y = word.y + (word.height + cell.height) / 2, .width = cell.width * 2, .height = 1 }, t.tab_text);

    var count_buf: [32]u8 = undefined;
    const count: [:0]const u8 = if (f.query.value().len == 0)
        ""
    else if (f.total == 0)
        "No results"
    else if (f.current(view)) |n|
        std.fmt.bufPrintZ(&count_buf, "{d} of {d}", .{ n, f.total }) catch ""
    else
        std.fmt.bufPrintZ(&count_buf, "{d} found", .{f.total}) catch "";
    app.font.draw(count, g.count.x + layout.padding / 2, g.count.y + (g.count.height - cell.height) / 2, t.hint);

    widgets.drawIconButton(g.previous, point);
    widgets.drawChevron(g.previous, .up, widgets.hoverInk(g.previous, point));
    widgets.drawIconButton(g.next, point);
    widgets.drawChevron(g.next, .down, widgets.hoverInk(g.next, point));
    widgets.drawIconButton(g.close, point);
    widgets.drawCross(widgets.squareIn(g.close), widgets.hoverInk(g.close, point));

    if (f.replacing) {
        widgets.drawTextButton(g.replace_one, find_mod.replace_one_label, point, cell);
        widgets.drawTextButton(g.replace_all, find_mod.replace_all_label, point, cell);
    }
}

/// Outline for a frameless window; skipped when maximised.
fn drawFrame(l: Layout) void {
    if (!app.window.custom_frame or pen.isWindowMaximized()) return;
    const bounds = pen.Rectangle{
        .x = 0,
        .y = 0,
        .width = l.menu.width,
        .height = l.status.y + l.status.height,
    };
    pen.drawRectangleLinesEx(bounds, 1, theme.current.scrollbar);
}

/// An open menu. Entries that cannot do anything now are greyed out.
fn drawPanel(panel: menu.Panel, cell: Metrics, point: pen.Vector2) void {
    const box = panel.rect(app.font);
    pen.drawRectangleRec(box, theme.current.tab_background);
    pen.drawRectangleLinesEx(box, 1, theme.current.scrollbar);
    const check = panel.checkWidth(app.font);

    for (panel.entries, 0..) |entry, row| {
        const rect = panel.entryRect(row, app.font);
        const usable = commands.enabled(entry.action);
        const hot = usable and pen.checkCollisionPointRec(point, rect);
        if (hot) pen.drawRectangleRec(rect, theme.current.selection);

        const y = rect.y + (rect.height - cell.height) / 2;
        const ink = if (!usable) theme.current.gutter_text else if (hot) theme.current.tab_text_active else theme.current.text;
        if (entry.checkable and commands.checked(entry.action)) {
            widgets.drawTick(.{ .x = rect.x + layout.padding, .y = y, .width = check, .height = cell.height }, ink);
        }
        app.font.draw(entry.label, rect.x + layout.padding + check, y, ink);
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

const about_capacity = 12;
var about_storage: [about_capacity][160]u8 = undefined;

/// Room for the prompt's line once fitted to the panel.
const prompt_line_capacity = 2048;
/// Graph lines, and the ones of the dot under the pointer, in pixels.
const graph_line = 1;
const graph_lit_line = 1.5;
/// Longer note names are not labelled.
const graph_label_bytes = 256;
const no_notes = "No Markdown notes in this folder yet";

/// `r` larger all round, so a dot just past an edge still draws its part.
fn grown(r: pen.Rectangle, by: f32) pen.Rectangle {
    return .{ .x = r.x - by, .y = r.y - by, .width = r.width + by * 2, .height = r.height + by * 2 };
}

fn drawAbout(l: Layout, cell: Metrics) void {
    var lines: [about_capacity][:0]const u8 = undefined;
    var count: usize = 0;

    const window_width = l.menu.width;
    const window_bottom = l.status.y + l.status.height;
    const inner = layout.padding * 4;
    const columns: u32 = @intFromFloat(@max((window_width - layout.padding * 2 - inner) / cell.width, 8));

    const add = struct {
        fn go(out: *[about_capacity][:0]const u8, n: *usize, fit: u32, comptime fmt: []const u8, args: anytype) void {
            if (n.* == out.len) return;
            var raw: [about_storage[0].len]u8 = undefined;
            const line = std.fmt.bufPrint(&raw, fmt, args) catch "";
            out[n.*] = text.fitStart(&about_storage[n.*], line, fit);
            n.* += 1;
        }
    }.go;

    add(&lines, &count, columns, "Zimacs {s}", .{app.version});
    add(&lines, &count, columns, "", .{});
    add(&lines, &count, columns, "A text editor written in Zig.", .{});
    add(&lines, &count, columns, "Zig {f} on {s}-{s}", .{
        builtin.zig_version,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
    add(&lines, &count, columns, "", .{});
    const settings_label = "Settings: ";
    var path_buf: [about_storage[0].len]u8 = undefined;
    const path = text.fitStart(&path_buf, app.config_path orelse "(none)", columns -| @as(u32, settings_label.len));
    add(&lines, &count, columns, settings_label ++ "{s}", .{path});
    add(&lines, &count, columns, "", .{});
    add(&lines, &count, columns, "{s}", .{aboutUpdateLine()});
    add(&lines, &count, columns, "", .{});
    add(&lines, &count, columns, "Click anywhere to close.", .{});

    var widest: f32 = 0;
    for (lines[0..count]) |line| widest = @max(widest, app.font.widthOf(line));

    const width = widest + inner;
    const height = @as(f32, @floatFromInt(count)) * cell.height + inner;
    const panel = pen.Rectangle{
        .x = @round(@max((window_width - width) / 2, 0)),
        .y = @round(@max(@min(l.text.y + l.text.height / 5, window_bottom - height), 0)),
        .width = width,
        .height = height,
    };

    dimBehind(l);
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

/// A short word on the update check, for the status bar. Null while idle.
/// Background checks show nothing unless there is news.
fn updateNotice() ?[:0]const u8 {
    const u = app.update.snapshot();
    const loud = app.update.announce;
    return switch (u.state) {
        .idle => null,
        .checking => if (loud) "checking for updates..." else null,
        .up_to_date => if (loud) "up to date" else null,
        .failed => if (loud) "update check failed" else null,
        .available => if (u.problem != null)
            std.fmt.bufPrintZ(&notice_buf, "v{f} available, could not install it", .{u.latest}) catch
                "update available, could not install it"
        else
            std.fmt.bufPrintZ(&notice_buf, "v{f} available", .{u.latest}) catch "update available",
        .downloading => std.fmt.bufPrintZ(&notice_buf, "updating to v{f}...", .{u.latest}) catch "updating...",
        .installed => std.fmt.bufPrintZ(&notice_buf, "v{f} installed, restart to use it", .{u.latest}) catch
            "update installed, restart to use it",
    };
}

var notice_buf: [64]u8 = undefined;
var about_update_buf: [128]u8 = undefined;

fn aboutUpdateLine() [:0]const u8 {
    const u = app.update.snapshot();
    return switch (u.state) {
        .idle => "Help > Check for Updates",
        .checking => "Checking for updates...",
        .up_to_date => "This is the latest release.",
        .failed => std.fmt.bufPrintZ(&about_update_buf, "Could not reach GitHub ({s}).", .{
            u.problem orelse "unknown",
        }) catch "Could not reach GitHub.",
        .available => if (u.problem) |why|
            std.fmt.bufPrintZ(&about_update_buf, "v{f} is out but did not install ({s}).", .{ u.latest, why }) catch
                "A newer version is out but did not install."
        else
            std.fmt.bufPrintZ(&about_update_buf, "v{f} is out: {s}", .{ u.latest, update_mod.releases_url }) catch
                "A newer version is available.",
        .downloading => std.fmt.bufPrintZ(&about_update_buf, "Downloading v{f}...", .{u.latest}) catch
            "Downloading the update...",
        .installed => std.fmt.bufPrintZ(&about_update_buf, "v{f} is installed. Restart Zimacs to use it.", .{u.latest}) catch
            "Update installed. Restart Zimacs to use it.",
    };
}

/// The layout for this frame, sized to the buffer that is showing.
pub fn currentLayout() Layout {
    const lines = if (app.buffer.current()) |v| v.tree.lineCount() else 1;
    return Layout.compute(app.font.metrics, .{
        .line_count = lines,
        .tabs = app.buffer.views.items.len > 0,
        .titlebar = app.window.custom_frame,
        .sidebar_columns = if (sidebarShowing()) app.config.sidebar_columns else 0,
    });
}

fn syntaxColour(kind: syntax.Kind) pen.Color {
    return switch (kind) {
        .none => theme.current.text,
        inline else => |k| @field(theme.current, "syntax_" ++ @tagName(k)),
    };
}

/// How lines fold in this layout.
pub fn foldFor(l: Layout, cell: Metrics) wrap.Fold {
    return .{ .width = l.columns(cell), .tab = app.config.tab_width };
}

/// Where the view is scrolled to and how far it can go, in rows: document
/// lines, or screen rows while lines are folded.
pub fn scrollExtent(view: *BufferView, l: Layout, cell: Metrics) struct { top: u32, total: u32 } {
    if (!app.config.wrap_lines) return .{ .top = view.top_line, .total = view.tree.lineCount() };
    const fold = foldFor(l, cell);
    return .{
        .top = view.rows.above(&view.tree, fold, view.top_line) + view.top_row,
        .total = view.rows.total(&view.tree, fold),
    };
}

/// Puts row `row` at the top, stopping where the last row reaches the bottom.
pub fn scrollToRow(view: *BufferView, l: Layout, cell: Metrics, row: u32) void {
    const top = @min(row, scrollExtent(view, l, cell).total -| l.rows(cell));
    if (!app.config.wrap_lines) {
        view.top_line = top;
        view.top_row = 0;
        return;
    }
    const at = view.rows.lineAt(&view.tree, foldFor(l, cell), top);
    view.top_line = at.line;
    view.top_row = at.row;
}

const Segment = struct { text: [:0]const u8, colour: pen.Color };

/// Room for one name in the folder tree.
const max_row_label = 512;
/// How far each level of the folder tree is set in, in columns.
const sidebar_indent_columns = 1.5;

/// Whether the folder tree takes room at the side.
pub fn sidebarShowing() bool {
    return app.sidebar.shown and app.workspace.root != null;
}

/// How round scrollbar thumbs and a tab's hovered close button are, and in
/// how many segments raylib draws a rounded corner.
const thumb_roundness = 0.6;
const close_roundness = 0.4;
const round_segments = 4;
/// A tab's close button, as a share of the line height.
const close_share = 0.7;
/// The new-tab button's side, as a share of the text height.
const new_tab_share = 1.0;

/// The line caret: thin, but never under a pixel.
fn lineCaretWidth(cell: Metrics) f32 {
    return @max(cell.width * 0.12, 1);
}

/// Width of the fade that marks tabs hidden past an edge.
const fade_width = 24;

fn drawOverflowFades(strip: pen.Rectangle, tabs: TabStrip) void {
    const solid = theme.current.tab_background;
    const clear = pen.Color{ .r = solid.r, .g = solid.g, .b = solid.b, .a = 0 };
    const h: i32 = @intFromFloat(strip.height);
    const y: i32 = @intFromFloat(strip.y);
    if (tabs.hiddenLeft()) {
        pen.drawRectangleGradientH(@intFromFloat(strip.x), y, fade_width, h, solid, clear);
    }
    if (tabs.hiddenRight()) {
        pen.drawRectangleGradientH(@intFromFloat(strip.x + strip.width - fade_width), y, fade_width, h, clear, solid);
    }
}

fn tabWidth(view: *BufferView) f32 {
    var label_buf: [160]u8 = undefined;
    return app.font.widthOf(tabLabel(&label_buf, view)) + layout.padding * 2 + closeSize() + layout.padding;
}

fn closeSize() f32 {
    return app.font.metrics.height * close_share;
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
