//! Keyboard and mouse.
//!
//!   typing                        inserts text, replacing any selection
//!   Shift + any movement          extends the selection
//!   Ctrl+Left / Ctrl+Right        move by word
//!   Home                          first non-blank, then column 0
//!   Ctrl+Home / Ctrl+End          start / end of file
//!   Ctrl+Backspace / Ctrl+Delete  delete a word
//!   Tab / Shift+Tab               indent / outdent
//!   Ctrl+Enter / Ctrl+Shift+Enter open a line below / above
//!   Ctrl+D / Ctrl+Shift+K         duplicate / delete line
//!   Alt+Up / Alt+Down             move the line
//!   Ctrl+A C X V Z Y L            select all, copy, cut, paste, undo, redo, select line
//!   Ctrl+F / F3 / Shift+F3        find, next, previous
//!   Ctrl+G                        go to line
//!   Ctrl+S / Ctrl+Shift+S         save / save as
//!   Ctrl+O / Ctrl+R / Ctrl+,      open, recent, settings
//!   Ctrl+N / Ctrl+W               new tab / close tab
//!   Ctrl+Tab / Ctrl+1..9          switch tab
//!   Ctrl with  +  -  0            zoom in, out, reset
//!   click, drag, double, triple   place caret, select, select word or line
//!   mouse wheel                   scroll, Shift for sideways
//!   title bar                     drag to move, double-click to maximise
//!   window edges                  drag to resize

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const editor = @import("editor.zig");
const Artifact = @import("artifact.zig").Artifact;
const layout_mod = @import("layout.zig");
const text_mod = @import("text.zig");
const wrap_mod = @import("wrap.zig");
const commands = @import("commands.zig");
const menu_mod = @import("menu.zig");
const titlebar = @import("titlebar.zig");

/// Lines scrolled per wheel notch.
const wheel_lines = 3;
/// Two clicks closer together than this count as a double click.
const multi_click_seconds = 0.35;

var last_click_time: f64 = -1;
var click_streak: u8 = 0;
var dragging = false;
var dragging_bar = false;
var dragging_hbar = false;
/// A window button is only pressed if the release lands on it too, the way
/// every desktop's own buttons behave.
var armed_button: ?titlebar.Button = null;
var last_caption_press: f64 = -1;
/// raylib makes a new system cursor each time it is set, so it is only set
/// when the shape actually changes.
var cursor_shape: pen.MouseCursor = .default;

pub const Input = struct {
    const Self = @This();

    const table = Artifact.Table{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(i: *Self) Artifact {
        return .{ .ctx = @ptrCast(i), .table = &table, .name = "Input" };
    }

    pub fn init(ctx: *anyopaque) !void {
        _ = ctx;
    }

    pub fn deinit(ctx: *anyopaque) !void {
        _ = ctx;
    }

    pub fn render(ctx: *anyopaque) !void {
        _ = ctx;
        // Ahead of everything else, so a prompt or the About panel never
        // stops you moving, resizing or closing the window.
        if (handleTitlebar()) return;
        if (app.prompt.active) {
            try runPrompt();
            return;
        }
        if (try handleMenu()) return;
        try shortcuts();
        try repeatSearch();
        moveCursor();
        try typeText();
        try mouse();
        scroll();
    }
};

/// Moves, resizes, maximises and closes the window when Zimacs draws its own
/// title bar. Returns true when it has taken this frame's pointer.
fn handleTitlebar() bool {
    const w = &app.window;
    if (!w.custom_frame) return false;

    const l = editor.currentLayout();
    const point = pen.getMousePosition();

    if (w.drag != null) {
        if (pen.isMouseButtonDown(.left)) w.continueDrag() else w.endDrag();
        return true;
    }

    const maximized = pen.isWindowMaximized();
    const edges = if (maximized) titlebar.Edges{} else titlebar.edgesAt(point, l);
    setCursor(if (edges.any()) edges.cursor() else .default);

    if (pen.isMouseButtonPressed(.left)) {
        if (edges.any()) {
            w.beginResize(edges);
            return true;
        }
        if (titlebar.buttonAt(point, l)) |b| {
            armed_button = b;
            return true;
        }
        // With a menu open, a click in the bar closes it rather than
        // grabbing the window, the same as a click anywhere else would.
        if (!app.menu.capturing() and titlebar.inDragArea(point, l, app.font)) {
            const now = pen.getTime();
            if (now - last_caption_press < multi_click_seconds) {
                last_caption_press = -1;
                w.toggleMaximize();
            } else {
                last_caption_press = now;
                w.beginMove();
            }
            return true;
        }
    }

    if (armed_button) |armed| {
        if (!pen.isMouseButtonReleased(.left)) return true;
        armed_button = null;
        if (titlebar.buttonAt(point, l) == armed) switch (armed) {
            .minimize => w.minimize(),
            .maximize => w.toggleMaximize(),
            .close => w.close_requested = true,
        };
        return true;
    }
    return false;
}

fn setCursor(shape: pen.MouseCursor) void {
    if (shape == cursor_shape) return;
    cursor_shape = shape;
    pen.setMouseCursor(shape);
}

/// Runs the menu bar. Returns true when it has taken this frame's input.
fn handleMenu() !bool {
    const l = editor.currentLayout();
    const point = pen.getMousePosition();
    const clicked = pen.isMouseButtonPressed(.left);

    if (app.menu.showing_about) {
        if (clicked or pressed(.escape)) app.menu.showing_about = false;
        return true;
    }
    if (pressed(.escape)) app.menu.close();

    if (menu_mod.titleAt(point, l, app.font)) |index| {
        if (clicked) {
            app.menu.open = if (app.menu.open == index) null else index;
        } else if (app.menu.open != null) {
            // Sliding across the bar with one menu open opens the next, the
            // way every desktop menu behaves.
            app.menu.open = index;
        }
        return true;
    }

    const index = app.menu.open orelse return false;
    if (menu_mod.entryAt(point, index, l, app.font)) |action| {
        if (clicked) {
            app.menu.close();
            try commands.run(action);
            if (action == .about) app.menu.showing_about = true;
        }
        return true;
    }
    // A click anywhere else just closes the menu.
    if (clicked) app.menu.close();
    return true;
}

/// True on the first press, then on auto-repeat.
///
/// `isKeyDown` is deliberately not used for actions: it is true on every frame
/// a key is held, which at 165 fps would run the action hundreds of times.
fn pressed(key: pen.KeyboardKey) bool {
    return pen.isKeyPressed(key) or pen.isKeyPressedRepeat(key);
}

fn ctrlDown() bool {
    return pen.isKeyDown(.left_control) or pen.isKeyDown(.right_control);
}

fn shiftDown() bool {
    return pen.isKeyDown(.left_shift) or pen.isKeyDown(.right_shift);
}

fn altDown() bool {
    return pen.isKeyDown(.left_alt) or pen.isKeyDown(.right_alt);
}

/// One screen of lines, minus one so you keep your place while reading.
fn pageRows() u32 {
    const rows = editor.currentLayout().rows(app.font.metrics);
    return if (rows > 1) rows - 1 else 1;
}

// ------------------------------------------------------------- movement

fn moveCursor() void {
    const view = app.buffer.current() orelse return;
    const tree = &view.tree;
    const cursor = &view.cursor;
    const ctrl = ctrlDown();
    const extend = shiftDown();

    if (pressed(.left)) if (ctrl) cursor.wordLeft(tree, extend) else cursor.left(tree, extend);
    if (pressed(.right)) if (ctrl) cursor.wordRight(tree, extend) else cursor.right(tree, extend);
    if (pressed(.up)) cursor.up(tree, extend);
    if (pressed(.down)) cursor.down(tree, extend);

    if (pressed(.home)) {
        if (ctrl) cursor.toStart(tree, extend) else cursor.home(tree, extend);
    }
    if (pressed(.end)) {
        if (ctrl) cursor.toEnd(tree, extend) else cursor.end(tree, extend);
    }

    // Ctrl with the page keys switches tab instead of scrolling.
    if (!ctrl) {
        const rows = pageRows();
        if (pressed(.page_up)) cursor.pageUp(tree, rows, extend);
        if (pressed(.page_down)) cursor.pageDown(tree, rows, extend);
    }
}

// ---------------------------------------------------------------- text

fn typeText() !void {
    const view = app.buffer.current() orelse return;
    // Ctrl combinations are shortcuts, not text.
    if (ctrlDown()) return;

    // The OS has already decoded these, so any keyboard layout, shift state
    // or dead key produces the right character without us mapping keys.
    while (true) {
        const code = pen.getCharPressed();
        if (code <= 0 or code > 0x10FFFF) break;
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(code), &utf8) catch continue;
        try view.insert(utf8[0..n]);
    }

    if (pressed(.enter) or pressed(.kp_enter)) try view.insert("\n");
    if (pressed(.tab)) {
        // With a selection, Tab shifts the whole block rather than replacing it.
        if (view.cursor.hasSelection()) {
            try commands.run(if (shiftDown()) .outdent else .indent);
        } else if (shiftDown()) {
            try commands.run(.outdent);
        } else if (app.config.expand_tabs) {
            var spaces: [16]u8 = undefined;
            const width = @min(app.config.tab_width, spaces.len);
            @memset(spaces[0..width], ' ');
            try view.insert(spaces[0..width]);
        } else {
            try view.insert("\t");
        }
    }
    if (pressed(.backspace)) try view.backspace();
    if (pressed(.delete)) try view.deleteForward();
}

// ----------------------------------------------------------- shortcuts

fn shortcuts() !void {
    // Alt is only used for moving lines about.
    if (altDown() and !ctrlDown()) {
        if (pressed(.up)) try commands.run(.move_line_up);
        if (pressed(.down)) try commands.run(.move_line_down);
        return;
    }
    if (!ctrlDown()) return;
    const shift = shiftDown();

    if (pressed(.equal) or pressed(.kp_add)) try commands.run(.zoom_in);
    if (pressed(.minus) or pressed(.kp_subtract)) try commands.run(.zoom_out);
    if (pressed(.zero) or pressed(.kp_0)) try commands.run(.zoom_reset);

    if (pressed(.tab) or pressed(.page_down)) {
        if (shift) app.buffer.previous() else app.buffer.next();
    }
    if (pressed(.page_up)) app.buffer.previous();
    selectTabByNumber();

    if (pressed(.n)) try commands.run(.new_tab);
    if (pressed(.w)) try commands.run(.close_tab);
    if (pressed(.o)) try commands.run(.open_file);
    if (pressed(.r)) try commands.run(.open_recent);
    if (pressed(.f)) try commands.run(.find);
    if (pressed(.g)) try commands.run(.goto_line);
    if (pressed(.a)) try commands.run(.select_all);
    if (pressed(.l)) if (app.buffer.current()) |v| v.cursor.selectLine(&v.tree);
    if (pressed(.c)) try commands.run(.copy);
    if (pressed(.x)) try commands.run(.cut);
    if (pressed(.v)) try commands.run(.paste);
    if (pressed(.y)) try commands.run(.redo);
    if (pressed(.z)) try commands.run(if (shift) .redo else .undo);
    if (pressed(.s)) try commands.run(if (shift) .save_as else .save);
    if (pressed(.comma)) try commands.run(.open_config);

    if (pressed(.d)) try commands.run(.duplicate_line);
    if (shift and pressed(.k)) try commands.run(.delete_line);
    if (pressed(.enter) or pressed(.kp_enter)) {
        try commands.run(if (shift) .open_line_above else .open_line_below);
    }

    // Word-wise deletion. These live here because they need Ctrl held.
    if (pressed(.backspace)) if (app.buffer.current()) |v| try v.deleteWordBefore();
    if (pressed(.delete)) if (app.buffer.current()) |v| try v.deleteWordAfter();
}

/// Ctrl+1 to Ctrl+9 jump straight to a tab, Ctrl+9 meaning the last one.
fn selectTabByNumber() void {
    const digits = [_]pen.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight };
    for (digits, 0..) |key, index| {
        if (pressed(key)) app.buffer.select(index);
    }
    if (pressed(.nine) and app.buffer.views.items.len > 0) {
        app.buffer.select(app.buffer.views.items.len - 1);
    }
}

/// F3 and Shift+F3 repeat the last search without reopening the prompt.
fn repeatSearch() !void {
    if (!commands.hasQuery()) return;
    if (pressed(.f3)) try commands.search(if (shiftDown()) .backward else .forward);
}

// --------------------------------------------------------------- mouse

fn mouse() !void {
    const point = pen.getMousePosition();
    const l = editor.currentLayout();

    if (pen.isMouseButtonPressed(.left)) {
        if (editor.closeAt(point, l)) |index| {
            try app.buffer.close(index);
            return;
        }
        if (editor.tabAt(point, l)) |index| {
            app.buffer.select(index);
            return;
        }
        // A scrollbar only takes the press when it actually has a thumb.
        // Otherwise its track is an invisible strip that swallows clicks
        // meant for the text underneath it.
        if (onScrollbar(point, l, .vertical)) {
            dragging_bar = true;
            scrollTo(point, l);
            return;
        }
        if (onScrollbar(point, l, .horizontal)) {
            dragging_hbar = true;
            scrollSidewaysTo(point, l);
            return;
        }
        // The gutter counts as part of the line: clicking it selects that
        // line, which is what every other editor does.
        if (pen.checkCollisionPointRec(point, l.gutter)) {
            beginGutterClick(point, l);
            return;
        }
        if (pen.checkCollisionPointRec(point, l.text)) {
            beginClick(point, l);
            return;
        }
    }

    if (pen.isMouseButtonReleased(.left)) {
        dragging = false;
        dragging_bar = false;
        dragging_hbar = false;
    }

    if (dragging_bar and pen.isMouseButtonDown(.left)) {
        scrollTo(point, l);
        return;
    }
    if (dragging_hbar and pen.isMouseButtonDown(.left)) {
        scrollSidewaysTo(point, l);
        return;
    }

    if (dragging and pen.isMouseButtonDown(.left)) {
        const view = app.buffer.current() orelse return;
        view.cursor.moveTo(&view.tree, offsetAt(view, point, l), true);
        // Drag past the top or bottom edge to keep scrolling.
        if (point.y < l.text.y) app.editor.scroll(-1);
        if (point.y > l.text.y + l.text.height) app.editor.scroll(1);
    }
}

const Bar = enum { vertical, horizontal };

/// True only when that scrollbar actually has a thumb to grab.
///
/// Without this check its track is an invisible strip that swallows presses
/// meant for the text underneath it.
fn onScrollbar(point: pen.Vector2, l: layout_mod.Layout, which: Bar) bool {
    const view = app.buffer.current() orelse return false;
    const cell = app.font.metrics;
    return switch (which) {
        .vertical => pen.checkCollisionPointRec(point, l.scrollbar) and
            layout_mod.thumb(l.scrollbar, view.top_line, l.rows(cell), view.tree.lineCount()) != null,
        .horizontal => blk: {
            const track = layout_mod.horizontalTrack(l);
            const visible = editor.visibleColumns(l, cell);
            break :blk pen.checkCollisionPointRec(point, track) and
                layout_mod.horizontalThumb(track, view.left_column, visible, view.content_columns) != null;
        },
    };
}

/// Clicking a line number selects that line, and dragging from there keeps
/// extending - which is what every other editor does with its gutter.
fn beginGutterClick(point: pen.Vector2, l: layout_mod.Layout) void {
    const view = app.buffer.current() orelse return;
    view.cursor.moveTo(&view.tree, offsetAt(view, point, l), shiftDown());
    view.cursor.selectLine(&view.tree);
    dragging = true;
}

fn beginClick(point: pen.Vector2, l: @import("layout.zig").Layout) void {
    const view = app.buffer.current() orelse return;

    const now = pen.getTime();
    click_streak = if (now - last_click_time < multi_click_seconds) click_streak + 1 else 1;
    last_click_time = now;

    const offset = offsetAt(view, point, l);
    switch (click_streak) {
        1 => {
            view.cursor.moveTo(&view.tree, offset, shiftDown());
            dragging = true;
        },
        2 => {
            view.cursor.moveTo(&view.tree, offset, false);
            view.cursor.selectWord(&view.tree);
            // Keep dragging live, so holding after a double click carries on
            // extending the selection.
            dragging = true;
        },
        else => {
            view.cursor.moveTo(&view.tree, offset, false);
            view.cursor.selectLine(&view.tree);
            dragging = true;
            click_streak = 0;
        },
    }
}

/// Turns a screen point into a byte offset. Screen columns and byte offsets
/// differ wherever a line holds tabs or multi-byte characters, so the line has
/// to be read to map between them.
fn offsetAt(
    view: *@import("buffer.zig").BufferView,
    point: pen.Vector2,
    l: layout_mod.Layout,
) u32 {
    const cell = app.font.metrics;
    const at = l.hit(cell, point, 0);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(app.gpa);

    var line = view.top_line;
    var column = at.column + view.left_column;

    if (app.config.wrap_lines) {
        // Walk down the folded rows until the clicked one is reached.
        const span = editor.visibleColumns(l, cell);
        var row = at.row;
        var skip = view.top_row;
        while (line + 1 < view.tree.lineCount()) {
            raw.clearRetainingCapacity();
            view.tree.lineContent(line, &raw) catch break;
            const pieces = wrap_mod.rowsFor(text_mod.width(raw.items, app.config.tab_width), span) - skip;
            if (row < pieces) break;
            row -= pieces;
            skip = 0;
            line += 1;
        }
        column = wrap_mod.rowStart(row + skip, span) + at.column;
    } else {
        line = @min(view.top_line + at.row, view.tree.lineCount() - 1);
    }

    raw.clearRetainingCapacity();
    view.tree.lineContent(line, &raw) catch
        return view.tree.offsetAt(.{ .line = line, .column = column });

    const byte = text_mod.offsetOf(raw.items, column, app.config.tab_width);
    return view.tree.lineStart(line) + byte;
}

/// Jumps the view to wherever the scrollbar was grabbed.
fn scrollTo(point: pen.Vector2, l: layout_mod.Layout) void {
    const view = app.buffer.current() orelse return;
    const rows = l.rows(app.font.metrics);
    const bar = layout_mod.thumb(l.scrollbar, view.top_line, rows, view.tree.lineCount()) orelse return;
    // Centre the thumb on the pointer so it does not jump on grab.
    view.top_line = layout_mod.lineAtTrack(
        l.scrollbar,
        point.y - bar.height / 2,
        rows,
        view.tree.lineCount(),
    );
}

fn scrollSidewaysTo(point: pen.Vector2, l: layout_mod.Layout) void {
    const view = app.buffer.current() orelse return;
    const track = layout_mod.horizontalTrack(l);
    const visible = editor.visibleColumns(l, app.font.metrics);
    const bar = layout_mod.horizontalThumb(track, view.left_column, visible, view.content_columns) orelse return;
    view.left_column = layout_mod.columnAtTrack(
        track,
        point.x - bar.width / 2,
        visible,
        view.content_columns,
    );
}

fn scroll() void {
    const wheel = pen.getMouseWheelMove();
    if (wheel == 0) return;
    // Wheel up is positive and should move toward the start of the file.
    const steps: i32 = @intFromFloat(@round(wheel * wheel_lines));
    if (shiftDown()) app.editor.scrollSideways(-steps) else app.editor.scroll(-steps);
}

// -------------------------------------------------------------- prompt

fn runPrompt() !void {
    while (true) {
        const code = pen.getCharPressed();
        if (code <= 0 or code > 0x10FFFF) break;
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(code), &utf8) catch continue;
        try app.prompt.append(utf8[0..n]);
    }

    if (pressed(.up)) app.prompt.cycle(-1);
    if (pressed(.down)) app.prompt.cycle(1);
    if (pressed(.backspace)) {
        // With nothing typed, backspace steps up a directory.
        if (app.prompt.kind == .browse and app.prompt.text().len == 0) {
            try commands.chooseInBrowser(@import("browser.zig").parent);
            return;
        }
        app.prompt.backspace();
    }

    // Clicking a suggestion picks it.
    if (pen.isMouseButtonPressed(.left)) {
        const l = editor.currentLayout();
        if (editor.promptRowAt(pen.getMousePosition(), l, app.font.metrics)) |row| {
            app.prompt.option = row;
            try commitPrompt();
            return;
        }
    }
    if (pressed(.escape)) app.prompt.cancel();
    if (pressed(.enter) or pressed(.kp_enter)) try commitPrompt();
}

fn commitPrompt() !void {
    // Copy first: the prompt's text lives in its own buffer, which closing it
    // or stepping into a directory immediately reuses.
    const chosen = try app.prompt.takeResult(app.gpa);
    defer app.gpa.free(chosen);

    const kind = app.prompt.kind;
    if (kind != .browse and kind != .save_into) app.prompt.cancel();
    if (chosen.len == 0) return;

    switch (kind) {
        .browse => try commands.chooseInBrowser(chosen),
        .save_into => try commands.saveInBrowser(chosen),
        .open => app.openFile(chosen) catch |err| report("Could not open", err),
        .save_as => {
            const view = app.buffer.current() orelse return;
            app.buffer.saveAs(view, chosen) catch |err| report("Could not save", err);
        },
        .find => {
            try commands.setQuery(chosen);
            commands.search(.forward) catch |err| report("Search failed", err);
        },
        .goto_line => commands.gotoLine(chosen),
    }
}

fn report(what: []const u8, err: anyerror) void {
    std.debug.print("{s}: {s}\n", .{ what, @errorName(err) });
}
