//! Keyboard and mouse. Each frame's input goes to the first of these that
//! wants it: the title bar, a dialog, the find bar, the prompt, the menus,
//! and then the text itself. The shortcuts are listed in `menu.zig`, next
//! to the entries they belong to.

const std = @import("std");
const pen = @import("raylib");
const app = @import("../zimacs.zig");
const editor = @import("editor.zig");
const Artifact = @import("artifact.zig").Artifact;
const layout_mod = @import("layout.zig");
const text_mod = @import("text.zig");
const commands = @import("commands.zig");
const menu_mod = @import("menu.zig");
const titlebar = @import("titlebar.zig");
const find_mod = @import("find.zig");
const dialog_mod = @import("dialog.zig");
const TextField = @import("field.zig").TextField;
const BufferView = @import("buffer.zig").BufferView;
const typing = @import("typing.zig");
const wrap = @import("wrap.zig");
const language = @import("language.zig");
const browser_mod = @import("browser.zig");
const config_mod = @import("config.zig");
const welcome = @import("welcome.zig");
const wikilink = @import("wikilink.zig");

/// Lines scrolled per wheel notch.
const wheel_lines = 3;
/// Character widths the tab bar moves per wheel notch.
const tab_wheel_columns = 8;
/// Two clicks closer together than this count as a double click.
const multi_click_seconds = 0.35;

var last_click_time: f64 = -1;
var click_streak: u8 = 0;
/// What the held left button is doing.
const Drag = union(enum) {
    none,
    /// Selecting from where the press landed. It only starts once the
    /// pointer leaves that point, or holding the button after a double
    /// click would shrink the word selection back to the pointer.
    text: struct { from: pen.Vector2, moved: bool = false },
    vertical_bar,
    horizontal_bar,
};
var drag: Drag = .none;
var caption = Caption{};

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

    pub fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }

    pub fn render(ctx: *anyopaque) !void {
        _ = ctx;
        // First, so prompts and panels never block moving or closing.
        if (caption.handle()) return;
        if (try DialogInput.handle()) return;
        if (try FindBar.handle()) return;
        if (app.prompt.active) {
            try runPrompt();
            return;
        }
        if (try handleMenu()) return;
        if (app.graph.shown) return graphInput();
        try shortcuts();
        try repeatSearch();
        moveCursor();
        try typeText();
        try mouse();
        scroll();
    }
};

/// Pointer handling for the custom title bar and window edges.
const Caption = struct {
    /// A button fires only if released over the button it was pressed on.
    armed: ?titlebar.Button = null,
    last_press: f64 = -1,
    /// raylib creates a new system cursor on every set, so only set changes.
    cursor: pen.MouseCursor = .default,

    /// True when it has taken this frame's pointer.
    fn handle(c: *Caption) bool {
        const w = &app.window;
        if (!w.custom_frame) return false;

        if (w.drag != null) {
            if (pen.isMouseButtonDown(.left)) w.continueDrag() else w.endDrag();
            return true;
        }

        const l = editor.currentLayout();
        const point = pen.getMousePosition();
        const edges = if (pen.isWindowMaximized()) titlebar.Edges{} else titlebar.edgesAt(point, l);
        c.setCursor(if (edges.any()) edges.cursor() else .default);

        if (pen.isMouseButtonPressed(.left)) return c.press(point, l, edges);
        if (c.armed) |armed| {
            if (!pen.isMouseButtonReleased(.left)) return true;
            c.armed = null;
            if (titlebar.buttonAt(point, l) == armed) switch (armed) {
                .minimize => w.minimize(),
                .maximize => w.toggleMaximize(),
                .close => w.close_requested = true,
            };
            return true;
        }
        return false;
    }

    fn press(c: *Caption, point: pen.Vector2, l: layout_mod.Layout, edges: titlebar.Edges) bool {
        const w = &app.window;
        if (edges.any()) {
            w.beginResize(edges);
            return true;
        }
        if (titlebar.buttonAt(point, l)) |b| {
            c.armed = b;
            return true;
        }
        // An open menu takes the click, to close itself.
        if (app.menu.capturing() or !titlebar.inDragArea(point, l, app.font)) return false;

        const now = pen.getTime();
        if (now - c.last_press < multi_click_seconds) {
            c.last_press = -1;
            w.toggleMaximize();
        } else {
            c.last_press = now;
            w.beginMove();
        }
        return true;
    }

    fn setCursor(c: *Caption, shape: pen.MouseCursor) void {
        if (shape == c.cursor) return;
        c.cursor = shape;
        pen.setMouseCursor(shape);
    }
};

/// Keyboard and pointer while a dialog is up. It is modal, so it takes all
/// input until it is answered.
const DialogInput = struct {
    fn handle() !bool {
        const d = &app.dialog;
        const q = d.question orelse return false;
        while (pen.getCharPressed() > 0) {}

        if (pressed(.left) or (pressed(.tab) and shiftDown())) {
            d.move(-1);
        } else if (pressed(.right) or pressed(.tab)) {
            d.move(1);
        }
        if (pressed(.escape)) {
            try commands.answer(q.dismissal());
        } else if (pressed(.enter) or pressed(.kp_enter)) {
            if (d.focused()) |a| try commands.answer(a);
        } else if (pen.isMouseButtonPressed(.left)) {
            const g = dialog_mod.geometry(editor.currentLayout(), app.font, q);
            if (dialog_mod.buttonAt(pen.getMousePosition(), g)) |i| try commands.answer(q.answers()[i]);
        }
        return true;
    }
};

/// Keyboard and pointer for the find and replace bar.
const FindBar = struct {
    /// True when it has taken this frame's input.
    fn handle() !bool {
        const f = &app.find;
        if (!f.open) return false;
        if (app.prompt.active or app.menu.capturing()) {
            f.focus = null;
            return false;
        }
        const view = app.buffer.current() orelse {
            f.close();
            return false;
        };

        if (pen.isMouseButtonPressed(.left)) {
            const g = find_mod.geometry(editor.currentLayout(), app.font, f.replacing);
            const point = pen.getMousePosition();
            if (find_mod.controlAt(point, g, f.replacing)) |c| {
                try press(c, view, g, point);
                return true;
            }
            if (find_mod.inPanel(point, g)) return true;
            // The document takes the keyboard back; the bar stays open.
            f.focus = null;
            return false;
        }
        if (pressed(.escape)) {
            f.close();
            return true;
        }
        const field = f.focused() orelse return false;
        try edit(field, view);
        try windowShortcuts();
        try repeatSearch();
        return true;
    }

    fn press(c: find_mod.Control, view: *BufferView, g: find_mod.Geometry, point: pen.Vector2) !void {
        const f = &app.find;
        switch (c) {
            .find_field, .replace_field => {
                const which: find_mod.Field = if (c == .find_field) .find else .replace;
                f.focus = which;
                placeCaret(f.field(which), g.rect(c), point);
            },
            .match_case, .whole_word => {
                f.toggle(c);
                try f.searchFromOrigin(view);
            },
            .expand => f.toggle(.expand),
            .previous => try f.step(view, .backward),
            .next => try f.step(view, .forward),
            .close => f.close(),
            .replace_one => try f.replaceOne(view),
            .replace_all => _ = try f.replaceAll(view),
        }
    }

    fn edit(field: *TextField, view: *BufferView) !void {
        const f = &app.find;
        const gpa = app.gpa;
        const ctrl = ctrlDown();
        const shift = shiftDown();
        const alt = altDown();
        const before = std.hash.Wyhash.hash(0, f.query.value());

        var utf8: [4]u8 = undefined;
        while (nextTyped(&utf8)) |typed| {
            if (!shortcutHeld()) try field.insert(gpa, typed);
        }

        if (pressed(.backspace)) if (ctrl) field.deleteWordBefore() else field.backspace();
        if (pressed(.delete)) if (ctrl) field.deleteWordAfter() else field.delete();
        if (pressed(.left)) if (ctrl) field.wordLeft(shift) else field.left(shift);
        if (pressed(.right)) if (ctrl) field.wordRight(shift) else field.right(shift);
        if (pressed(.home)) field.home(shift);
        if (pressed(.end)) field.end(shift);

        if (ctrl and pressed(.a)) field.selectAll();
        if (ctrl and (pressed(.c) or pressed(.x))) if (field.selection()) |sel| {
            const copied = try gpa.dupeZ(u8, field.value()[sel.start..sel.end]);
            defer gpa.free(copied);
            pen.setClipboardText(copied);
            if (pressed(.x)) field.backspace();
        };
        if (ctrl and pressed(.v)) try field.insert(gpa, pen.getClipboardText());

        if (alt and pressed(.c)) f.toggle(.match_case);
        if (alt and pressed(.w)) f.toggle(.whole_word);
        if (alt and (pressed(.c) or pressed(.w))) try f.searchFromOrigin(view);

        if (pressed(.tab) and !ctrl and f.replacing) {
            f.focus = if (f.focus == .find) .replace else .find;
        }
        if (pressed(.enter) or pressed(.kp_enter)) {
            if (ctrl and alt) {
                _ = try f.replaceAll(view);
            } else if (f.focus == .replace) {
                try f.replaceOne(view);
            } else {
                try f.step(view, if (shift) .backward else .forward);
            }
        }

        if (std.hash.Wyhash.hash(0, f.query.value()) != before) try f.searchFromOrigin(view);
    }

    fn placeCaret(field: *TextField, rect: pen.Rectangle, point: pen.Vector2) void {
        const value = field.value();
        const visible = find_mod.fieldColumns(rect, app.font);
        const first = find_mod.fieldScroll(text_mod.columnOf(value, field.caret, 1), visible);
        const offset = (point.x - rect.x - layout_mod.padding) / app.font.metrics.width;
        const column: u32 = @intCast(first + @as(usize, @intFromFloat(@max(@round(offset), 0))));
        field.anchor = null;
        field.caret = text_mod.offsetOf(value, column, 1);
    }
};

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
            app.menu.tab_menu_at = null;
            app.menu.open = if (app.menu.open == index) null else index;
        } else if (app.menu.open != null) {
            // Sliding across the bar with one menu open opens the next, the
            // way every desktop menu behaves.
            app.menu.open = index;
        } else {
            // Only hovering: the keyboard still belongs to the text.
            return false;
        }
        return true;
    }

    const panel = app.menu.panel(l, app.font) orelse return false;
    if (panel.entryAt(point, app.font)) |entry| {
        if (clicked and commands.enabled(entry.action)) {
            app.menu.close();
            try commands.run(entry.action);
        }
        return true;
    }
    // A click anywhere else just closes the menu.
    if (clicked or pen.isMouseButtonPressed(.right)) app.menu.close();
    return true;
}

/// The next character typed this frame, as UTF-8 in `buf`. The system has
/// already decoded it, so any keyboard layout, shift state or dead key
/// comes out right without mapping keys here.
fn nextTyped(buf: *[4]u8) ?[]const u8 {
    while (true) {
        const code = pen.getCharPressed();
        if (code <= 0 or code > max_codepoint) return null;
        const n = std.unicode.utf8Encode(@intCast(code), buf) catch continue;
        return buf[0..n];
    }
}

const max_codepoint = 0x10FFFF;

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

/// Only the left Alt: the right one is AltGr on many layouts, where it types
/// characters such as @, { and ż rather than starting a shortcut.
fn altDown() bool {
    return pen.isKeyDown(.left_alt);
}

/// Whether typed characters belong to a shortcut instead. The browser passes
/// Alt+letter on as the letter.
fn shortcutHeld() bool {
    return ctrlDown() or altDown();
}

/// One screen of lines, minus one so you keep your place while reading.
fn pageRows() u32 {
    const rows = editor.currentLayout().rows(app.font.metrics);
    return if (rows > 1) rows - 1 else 1;
}

// ------------------------------------------------------------- movement

/// The screen column along the row that Up and Down aim for, kept while the
/// caret is where the last such move left it.
var row_goal: ?struct { offset: u32, column: u32 } = null;

/// Up and Down: to the screen row above or below, which may be part of the
/// same line while lines are folded. Aiming at a screen column keeps the
/// caret in place across tabs and wide characters.
fn moveRow(view: *BufferView, direction: enum { up, down }, extend: bool) void {
    const unfolded = wrap.Fold{ .width = 0, .tab = app.config.tab_width };
    const fold = if (app.config.wrap_lines) editor.foldFor(editor.currentLayout(), app.font.metrics) else unfolded;
    const tree = &view.tree;
    const at = view.cursor.position(tree);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(app.gpa);
    tree.lineContent(at.line, &raw) catch return;
    const here = wrap.place(view.rows.breaksOf(tree, fold, at.line), text_mod.columnOf(raw.items, at.column, fold.tab));
    const goal = if (row_goal) |g| if (g.offset == view.cursor.offset) g.column else here.column else here.column;

    var line = at.line;
    var row = here.row;
    switch (direction) {
        .up => if (row > 0) {
            row -= 1;
        } else if (line > 0) {
            line -= 1;
            row = view.rows.count(tree, fold, line) - 1;
        } else return view.cursor.moveTo(tree, 0, extend),
        .down => if (row + 1 < view.rows.count(tree, fold, line)) {
            row += 1;
        } else if (line + 1 < tree.lineCount()) {
            line += 1;
            row = 0;
        } else return view.cursor.moveTo(tree, tree.len(), extend),
    }

    raw.clearRetainingCapacity();
    tree.lineContent(line, &raw) catch return;
    const starts = view.rows.breaksOf(tree, fold, line);
    var column = starts[row] + goal;
    if (row + 1 < starts.len) column = @min(column, starts[row + 1] -| 1);
    const byte = text_mod.offsetOf(raw.items, column, fold.tab);
    view.cursor.moveTo(tree, tree.lineStart(line) + byte, extend);
    row_goal = .{ .offset = view.cursor.offset, .column = goal };
}

fn moveCursor() void {
    const view = app.buffer.current() orelse return;
    const tree = &view.tree;
    const cursor = &view.cursor;
    const ctrl = ctrlDown();
    const extend = shiftDown();

    if (pressed(.left)) if (ctrl) cursor.wordLeft(tree, extend) else cursor.left(tree, extend);
    if (pressed(.right)) if (ctrl) cursor.wordRight(tree, extend) else cursor.right(tree, extend);
    // With Alt they move the line instead.
    if (!altDown()) {
        if (pressed(.up)) moveRow(view, .up, extend);
        if (pressed(.down)) moveRow(view, .down, extend);
    }

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
    if (shortcutHeld()) return;

    // Brackets and quotes pair up only in code, and only if wanted.
    const lang = if (app.config.auto_close) view.language else &language.plain;
    var unit_buf: [config_mod.max_indent_unit]u8 = undefined;
    const unit = app.config.indentUnit(&unit_buf);

    var utf8: [4]u8 = undefined;
    var last: u8 = 0;
    while (nextTyped(&utf8)) |typed| {
        try typing.typeText(view, typed, lang);
        last = typed[0];
    }
    // `[[` starts a link to another note.
    if (last == '[' and view.cursor.offset >= 2 and view.tree.byteAt(view.cursor.offset - 2) == '[') try commands.linkNote();

    if (pressed(.enter) or pressed(.kp_enter)) try typing.newline(view, lang, unit);
    if (pressed(.tab)) {
        // With a selection, Tab shifts the whole block rather than replacing it.
        if (view.cursor.hasSelection()) {
            try commands.run(if (shiftDown()) .outdent else .indent);
        } else if (shiftDown()) {
            try commands.run(.outdent);
        } else {
            try view.insert(unit);
        }
    }
    if (pressed(.backspace)) try typing.backspace(view, lang);
    if (pressed(.delete)) try view.deleteForward();
}

// ----------------------------------------------------------- shortcuts

fn shortcuts() !void {
    try windowShortcuts();
    try editingShortcuts();
}

/// Shortcuts that act on the editor as a whole, so they still work while a
/// find field has the keyboard.
fn windowShortcuts() !void {
    if (altDown() and !ctrlDown()) {
        if (pressed(.z)) try commands.run(.toggle_wrap);
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

    if (pressed(.b)) try commands.run(if (shift) .backlinks else .toggle_sidebar);
    if (pressed(.p)) try commands.run(if (shift) .command_palette else .quick_open);
    if (pressed(.n)) try commands.run(.new_tab);
    if (pressed(.t) and shift) try commands.run(.reopen_tab);
    if (pressed(.w)) try commands.run(.close_tab);
    if (pressed(.o)) try commands.run(if (shift) .open_folder else .open_file);
    if (pressed(.r)) try commands.run(.open_recent);
    if (pressed(.f)) try commands.run(if (shift) .search_folder else .find);
    if (pressed(.h)) try commands.run(.replace);
    if (pressed(.g)) try commands.run(if (shift) .graph_view else .goto_line);
    if (pressed(.s)) try commands.run(if (shift) .save_as else .save);
    if (pressed(.comma)) try commands.run(.open_config);
}

/// Shortcuts that edit the document.
fn editingShortcuts() !void {
    if (altDown() and !ctrlDown()) {
        if (pressed(.up)) try commands.run(.move_line_up);
        if (pressed(.down)) try commands.run(.move_line_down);
        return;
    }
    if (!ctrlDown()) return;
    const shift = shiftDown();

    if (pressed(.a)) try commands.run(.select_all);
    if (pressed(.l)) if (app.buffer.current()) |v| v.cursor.selectLine(&v.tree);
    if (pressed(.c)) try commands.run(.copy);
    if (pressed(.x)) try commands.run(.cut);
    if (pressed(.v)) try commands.run(.paste);
    if (pressed(.y)) try commands.run(.redo);
    if (pressed(.z)) try commands.run(if (shift) .redo else .undo);

    if (pressed(.d)) try commands.run(.duplicate_line);
    if (pressed(.slash)) try commands.run(.toggle_comment);
    if (shift and pressed(.k)) try commands.run(.delete_line);
    if (pressed(.enter) or pressed(.kp_enter)) {
        try commands.run(if (shift) .open_line_above else .open_line_below);
    }

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
    if (pressed(.f3)) try commands.findStep(if (shiftDown()) .backward else .forward);
}

// --------------------------------------------------------------- mouse

fn mouse() !void {
    const point = pen.getMousePosition();
    const l = editor.currentLayout();

    // The middle button closes a tab, the right one opens its menu.
    if (app.editor.tabs.tabAt(l.tabs, point)) |index| {
        if (pen.isMouseButtonPressed(.middle)) return commands.requestClose(index);
        if (pen.isMouseButtonPressed(.right)) {
            app.buffer.select(index);
            app.graph.hide();
            app.menu.tab_menu_at = point;
            return;
        }
    }

    if (pen.isMouseButtonPressed(.left)) {
        if (pen.checkCollisionPointRec(point, l.sidebar)) return clickSidebar(point, l);
        if (app.buffer.current() == null) return clickWelcome(point, l);
        if (pen.checkCollisionPointRec(point, app.editor.tabs.newRect(l.tabs))) return commands.run(.new_tab);
        if (app.editor.tabs.closeAt(l.tabs, point)) |index| {
            try commands.requestClose(index);
            return;
        }
        if (app.editor.tabs.tabAt(l.tabs, point)) |index| {
            app.buffer.select(index);
            app.graph.hide();
            return;
        }
        // A scrollbar only takes the press when it actually has a thumb.
        // Otherwise its track is an invisible strip that swallows clicks
        // meant for the text underneath it.
        if (onScrollbar(point, l, .vertical)) {
            drag = .vertical_bar;
            scrollTo(point, l);
            return;
        }
        if (onScrollbar(point, l, .horizontal)) {
            drag = .horizontal_bar;
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
            if (ctrlDown() and followLinkAt(point, l)) return;
            beginClick(point, l);
            return;
        }
    }

    // Also ends a drag whose release something else, such as a dialog, took.
    if (!pen.isMouseButtonDown(.left)) {
        drag = .none;
        return;
    }
    switch (drag) {
        .none => {},
        .vertical_bar => scrollTo(point, l),
        .horizontal_bar => scrollSidewaysTo(point, l),
        .text => |*t| {
            const view = app.buffer.current() orelse return;
            if (!t.moved) {
                const moved = @abs(point.x - t.from.x) + @abs(point.y - t.from.y);
                if (moved < app.font.metrics.width / 2) return;
                t.moved = true;
            }
            view.cursor.moveTo(&view.tree, offsetAt(view, point, l), true);
            // Drag past the top or bottom edge to keep scrolling.
            if (point.y < l.text.y) app.editor.scroll(-1);
            if (point.y > l.text.y + l.text.height) app.editor.scroll(1);
        },
    }
}

/// The graph view takes the pointer over the area under the tabs: hovering
/// picks out a dot, dragging moves a dot or the view, the wheel zooms, and a
/// click opens a note. The tabs and the folder tree work as usual.
fn graphInput() !void {
    try windowShortcuts();
    if (pressed(.escape)) return app.graph.hide();
    const g = &app.graph;
    const area = editor.currentLayout().body();
    const point = pen.getMousePosition();
    g.hover(point, area);
    if (g.gesture != .none) {
        if (pen.isMouseButtonDown(.left)) return g.drag(point, area);
        if (g.release()) |index| commands.openGraphNode(index);
        return;
    }
    if (!pen.checkCollisionPointRec(point, area)) return mouse();
    const wheel = pen.getMouseWheelMove();
    if (wheel != 0) g.zoomAt(point, area, wheel);
    if (pen.isMouseButtonPressed(.left)) g.press(point, area);
}

/// Ctrl+click on a `[[link]]` in a note follows it. True when there was one.
fn followLinkAt(point: pen.Vector2, l: layout_mod.Layout) bool {
    const view = app.buffer.current() orelse return false;
    if (!wikilink.isNote(view.path orelse return false)) return false;
    const at = view.tree.positionAt(offsetAt(view, point, l));
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(app.gpa);
    view.tree.lineContent(at.line, &line) catch return false;
    const link = wikilink.at(line.items, at.column) orelse return false;
    commands.followLink(view, link.target);
    return true;
}

/// A button of the empty screen runs its command; a recent folder or file
/// opens.
fn clickWelcome(point: pen.Vector2, l: layout_mod.Layout) !void {
    var rows_buf: [welcome.max_rows]welcome.Row = undefined;
    const rows = welcome.rows(app.recent_folders.items(), app.recent.items(), &rows_buf);
    const g = welcome.geometry(l, app.font.metrics, rows.len);
    switch (welcome.hit(g, rows.len, point) orelse return) {
        .button => |i| try commands.run(welcome.actions[i]),
        .row => |i| app.openPath(rows[i].path) catch |err| report("Could not open", err),
    }
}

/// A folder in the tree opens or shuts; a file opens in a tab.
fn clickSidebar(point: pen.Vector2, l: layout_mod.Layout) void {
    const root = app.workspace.root orelse return;
    const io = app.io orelse return;
    const cell = app.font.metrics;
    const row = app.sidebar.rowAt(layout_mod.sidebarRowsTop(l, cell), layout_mod.listRowHeight(cell), point.y) orelse return;
    const entry = app.sidebar.rows.items[row];
    if (entry.folder) return app.sidebar.toggle(io, root, row);
    commands.openInFolder(entry.path);
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
        .vertical => blk: {
            const extent = editor.scrollExtent(view, l, cell);
            break :blk pen.checkCollisionPointRec(point, l.scrollbar) and
                layout_mod.thumb(l.scrollbar, extent.top, l.rows(cell), extent.total) != null;
        },
        .horizontal => blk: {
            const track = layout_mod.horizontalTrack(l);
            const visible = l.columns(cell);
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
    drag = .{ .text = .{ .from = point } };
}

fn beginClick(point: pen.Vector2, l: layout_mod.Layout) void {
    const view = app.buffer.current() orelse return;

    const now = pen.getTime();
    // A shift-click extends the selection; it is never half of a double click.
    const extend = shiftDown();
    click_streak = if (!extend and now - last_click_time < multi_click_seconds) click_streak + 1 else 1;
    last_click_time = now;

    const offset = offsetAt(view, point, l);
    // Held after a double or triple click, the drag carries on extending.
    drag = .{ .text = .{ .from = point } };
    switch (click_streak) {
        1 => view.cursor.moveTo(&view.tree, offset, extend),
        2 => {
            view.cursor.moveTo(&view.tree, offset, false);
            view.cursor.selectWord(&view.tree);
        },
        else => {
            view.cursor.moveTo(&view.tree, offset, false);
            view.cursor.selectLine(&view.tree);
            click_streak = 0;
        },
    }
}

/// Turns a screen point into a byte offset. Screen columns and byte offsets
/// differ wherever a line holds tabs or multi-byte characters, so the line has
/// to be read to map between them.
fn offsetAt(
    view: *BufferView,
    point: pen.Vector2,
    l: layout_mod.Layout,
) u32 {
    const cell = app.font.metrics;
    const at = l.hit(cell, point);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(app.gpa);

    var line = view.top_line;
    var column = at.column + view.left_column;

    if (app.config.wrap_lines) {
        // Walk down the folded rows until the clicked one is reached.
        const fold = editor.foldFor(l, cell);
        var row = at.row + view.top_row;
        while (line + 1 < view.tree.lineCount()) : (line += 1) {
            const rows = view.rows.count(&view.tree, fold, line);
            if (row < rows) break;
            row -= rows;
        }
        const starts = view.rows.breaksOf(&view.tree, fold, line);
        const piece = @min(row, starts.len - 1);
        column = starts[piece] + at.column;
        // Past the end of a row is its end, not the start of the next.
        if (piece + 1 < starts.len) column = @min(column, starts[piece + 1] -| 1);
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
    const cell = app.font.metrics;
    const rows = l.rows(cell);
    const extent = editor.scrollExtent(view, l, cell);
    const bar = layout_mod.thumb(l.scrollbar, extent.top, rows, extent.total) orelse return;
    // Centre the thumb on the pointer so it does not jump on grab.
    const row = layout_mod.lineAtTrack(l.scrollbar, point.y - bar.height / 2, rows, extent.total);
    editor.scrollToRow(view, l, cell, row);
}

fn scrollSidewaysTo(point: pen.Vector2, l: layout_mod.Layout) void {
    const view = app.buffer.current() orelse return;
    const track = layout_mod.horizontalTrack(l);
    const visible = l.columns(app.font.metrics);
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
    // Over the tab bar the wheel scrolls the tabs instead, and over the
    // folder tree the tree.
    const l = editor.currentLayout();
    const point = pen.getMousePosition();
    if (pen.checkCollisionPointRec(point, l.tabs)) {
        app.editor.tabs.scrollBy(-wheel * app.font.metrics.width * tab_wheel_columns);
        return;
    }
    const steps: i32 = @intFromFloat(@round(wheel * wheel_lines));
    if (pen.checkCollisionPointRec(point, l.sidebar)) return app.sidebar.scrollBy(-steps);
    if (shiftDown()) app.editor.scrollSideways(-steps) else app.editor.scroll(-steps);
}

// -------------------------------------------------------------- prompt

fn runPrompt() !void {
    var edited = false;
    var utf8: [4]u8 = undefined;
    while (nextTyped(&utf8)) |typed| {
        if (shortcutHeld()) continue;
        try app.prompt.append(typed);
        edited = true;
    }

    if (pressed(.up)) app.prompt.cycle(-1);
    if (pressed(.down)) app.prompt.cycle(1);
    const wheel = pen.getMouseWheelMove();
    if (wheel != 0) app.prompt.scrollBy(@intFromFloat(@round(-wheel * wheel_lines)));
    if (pressed(.backspace)) {
        // With nothing typed, backspace steps up a directory.
        if (app.prompt.kind == .browse and app.prompt.text().len == 0) {
            try commands.chooseInBrowser(browser_mod.parent);
            return;
        }
        app.prompt.backspace();
        edited = true;
    }
    // A folder search runs again as its query changes.
    if (edited and app.prompt.kind == .search_folder) commands.searchQueryEdited();

    // Clicking a suggestion picks it.
    if (pen.isMouseButtonPressed(.left)) {
        const l = editor.currentLayout();
        if (layout_mod.promptRowAt(l, app.font.metrics, app.prompt.shown(), pen.getMousePosition())) |row| {
            app.prompt.pick(row);
            try commitPrompt();
            return;
        }
    }
    if (pressed(.escape)) {
        if (app.prompt.kind == .save_as or app.prompt.kind == .save_into) commands.cancelSave();
        app.prompt.cancel();
    }
    if (pressed(.enter) or pressed(.kp_enter)) try commitPrompt();
}

fn commitPrompt() !void {
    // Copy first: the prompt's text lives in its own buffer, which closing it
    // or stepping into a directory immediately reuses.
    const chosen = try app.prompt.takeResult(app.gpa);
    defer app.gpa.free(chosen);
    const option = app.prompt.chosenOption();

    const kind = app.prompt.kind;
    if (kind != .browse and kind != .save_into) app.prompt.cancel();
    if (chosen.len == 0) return;

    switch (kind) {
        .browse => try commands.chooseInBrowser(chosen),
        .save_into => try commands.saveInBrowser(chosen),
        .open => app.openFile(chosen) catch |err| report("Could not open", err),
        .recent => app.openPath(chosen) catch |err| report("Could not open", err),
        .open_folder => app.openFolder(chosen) catch |err| report("Could not open the folder", err),
        .quick_open, .backlinks => commands.openInFolder(chosen),
        .command => if (option) |i| try commands.runFromPalette(i),
        .link_note => try commands.insertLink(chosen),
        .search_folder => if (option) |hit| commands.openHit(hit),
        .save_as => {
            const view = app.buffer.current() orelse return;
            commands.saveViewAs(view, chosen);
        },
        .goto_line => commands.gotoLine(chosen),
    }
}

const report = commands.report;
