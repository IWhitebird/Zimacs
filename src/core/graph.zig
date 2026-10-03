//! The graph view: the open folder's notes as dots and their links as lines,
//! which can be panned, zoomed and dragged about. Clicking a dot opens its
//! note. While it shows, the folder is read again every so often, so notes
//! other programs write, such as an AI agent's memory, appear as they come.

const std = @import("std");
const pen = @import("raylib");
const Allocator = std.mem.Allocator;
const notes = @import("notes.zig");
const wikilink = @import("wikilink.zig");
const forcelayout = @import("forcelayout.zig");
const Interval = @import("interval.zig").Interval;
const Vec = forcelayout.Vec;
const Layout = forcelayout.Layout;

pub const min_zoom = 0.1;
pub const max_zoom = 4;
/// Room kept around the graph when it is fitted to the view, in pixels.
const fit_margin = 60;
/// Each notch of the wheel zooms by this much.
const zoom_step = 1.15;
/// Names show once the view is zoomed in this far.
pub const label_zoom = 0.75;
/// A dot's radius at zoom 1, and what each of its links adds, square-rooted.
const dot_radius = 4;
const radius_per_link = 1.6;
/// Dots are never drawn smaller than this.
const min_radius = 2;
/// A click this close to a dot's edge still hits it.
const hit_slack = 3;
/// How far a press moves before it counts as a drag rather than a click.
const drag_threshold = 4;
/// Layout steps run each frame.
const steps_per_frame = 2;
/// Heat a change to the notes, or dragging a dot, wakes the layout with.
const change_heat = 0.5;
const drag_heat = 0.3;
/// Starts the key of a note no file has yet, setting it apart from paths.
const missing_mark = 0;

pub const Node = struct {
    /// Its path in the folder, or for a note no file has yet, `missing_mark`
    /// and its name. Owned.
    key: []u8,
    links: u32 = 0,

    pub fn missing(n: Node) bool {
        return n.key[0] == missing_mark;
    }

    pub fn path(n: Node) ?[]const u8 {
        return if (n.missing()) null else n.key;
    }

    pub fn name(n: Node) []const u8 {
        return if (n.missing()) n.key[1..] else wikilink.key(std.fs.path.basenamePosix(n.key));
    }
};

const Gesture = union(enum) {
    none,
    /// The view is being dragged; the point it was last at.
    pan: pen.Vector2,
    dot: struct { index: u32, from: pen.Vector2, moved: bool = false },
};

pub const GraphView = struct {
    gpa: Allocator,
    shown: bool = false,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(forcelayout.Edge) = .empty,
    layout: Layout,
    /// The graph point drawn in the middle of the view.
    centre: Vec = .{},
    zoom: f32 = 1,
    hovered: ?u32 = null,
    /// The hovered dot and its neighbours, which are drawn picked out.
    lit: std.ArrayList(bool) = .empty,
    gesture: Gesture = .none,
    /// How often the folder is read again while the view shows.
    rescan: Interval = .{ .seconds = 2 },
    /// A reading has been asked for and has not come yet.
    awaiting: bool = false,
    /// Of the notes and links last taken in, to tell when they change.
    signature: u64 = 0,

    const Self = @This();

    pub fn init(gpa: Allocator) Self {
        return .{ .gpa = gpa, .layout = .{ .gpa = gpa } };
    }

    pub fn deinit(v: *Self) void {
        v.freeNodes();
        v.nodes.deinit(v.gpa);
        v.edges.deinit(v.gpa);
        v.lit.deinit(v.gpa);
        v.layout.deinit();
    }

    fn freeNodes(v: *Self) void {
        for (v.nodes.items) |n| v.gpa.free(n.key);
        v.nodes.clearRetainingCapacity();
    }

    /// Shows the view, mostly settled and zoomed out to fit `area`, centred
    /// on the note at `path` if it has one.
    pub fn show(v: *Self, path: ?[]const u8, area: pen.Rectangle) !void {
        try v.layout.warm(v.edges.items);
        v.shown = true;
        v.fit(area);
        if (path) |p| if (v.find(p)) |i| {
            v.centre = v.layout.points.items[i];
        };
    }

    /// Centres the whole graph in `area`, never zooming in past 1.
    fn fit(v: *Self, area: pen.Rectangle) void {
        v.zoom = 1;
        v.centre = .{};
        const points = v.layout.points.items;
        if (points.len == 0) return;
        var low = points[0];
        var high = points[0];
        for (points) |p| {
            low = .{ .x = @min(low.x, p.x), .y = @min(low.y, p.y) };
            high = .{ .x = @max(high.x, p.x), .y = @max(high.y, p.y) };
        }
        v.centre = low.add(high).scale(0.5);
        const span = high.sub(low);
        const across = (area.width - fit_margin * 2) / @max(span.x, 1);
        const down = (area.height - fit_margin * 2) / @max(span.y, 1);
        v.zoom = std.math.clamp(@min(across, down), min_zoom, 1);
    }

    pub fn hide(v: *Self) void {
        v.shown = false;
        _ = v.release();
    }

    /// Whether the folder should be read again now, to catch new notes.
    pub fn wantsRescan(v: *Self, now: f64) bool {
        if (!v.shown or v.awaiting or !v.rescan.due(now)) return false;
        v.awaiting = true;
        return true;
    }

    /// Takes in a new reading of the notes. A dot still there stays where it
    /// was, a new one starts beside a neighbour, and the layout only wakes
    /// when the notes or links have changed.
    pub fn sync(v: *Self, g: notes.Graph) !void {
        v.awaiting = false;
        var old: std.StringHashMapUnmanaged(u32) = .empty;
        defer old.deinit(v.gpa);
        for (v.nodes.items, 0..) |n, i| try old.put(v.gpa, n.key, @intCast(i));

        var nodes: std.ArrayList(Node) = .empty;
        defer {
            for (nodes.items) |n| v.gpa.free(n.key);
            nodes.deinit(v.gpa);
        }
        var points: std.ArrayList(Vec) = .empty;
        defer points.deinit(v.gpa);
        var velocities: std.ArrayList(Vec) = .empty;
        defer velocities.deinit(v.gpa);
        var fresh: std.ArrayList(bool) = .empty;
        defer fresh.deinit(v.gpa);

        var hash = std.hash.Wyhash.init(0);
        for (g.notes, 0..) |n, i| {
            const key = if (n.path) |p| try v.gpa.dupe(u8, p) else try std.fmt.allocPrint(v.gpa, "{c}{s}", .{ missing_mark, n.name });
            nodes.append(v.gpa, .{ .key = key }) catch |err| {
                v.gpa.free(key);
                return err;
            };
            hash.update(key);
            hash.update(&.{0});
            const before = old.get(key);
            try points.append(v.gpa, if (before) |o| v.layout.points.items[o] else Layout.spiral(i));
            try velocities.append(v.gpa, if (before) |o| v.layout.velocities.items[o] else .{});
            try fresh.append(v.gpa, before == null);
        }
        for (g.edges) |e| {
            hash.update(std.mem.asBytes(&e));
            nodes.items[e.from].links += 1;
            nodes.items[e.to].links += 1;
            // A new note starts out beside one that was already placed.
            if (fresh.items[e.to] and !fresh.items[e.from]) points.items[e.to] = points.items[e.from].add(Layout.spiral(e.to).scale(0.3));
            if (fresh.items[e.from] and !fresh.items[e.to]) points.items[e.from] = points.items[e.to].add(Layout.spiral(e.from).scale(0.3));
        }

        std.mem.swap(std.ArrayList(Node), &v.nodes, &nodes);
        std.mem.swap(std.ArrayList(Vec), &v.layout.points, &points);
        std.mem.swap(std.ArrayList(Vec), &v.layout.velocities, &velocities);
        v.edges.clearRetainingCapacity();
        for (g.edges) |e| try v.edges.append(v.gpa, .{ .from = e.from, .to = e.to });
        try v.lit.resize(v.gpa, v.nodes.items.len);
        v.light(null);
        // The dot being dragged may be another note now.
        _ = v.release();

        const signature = hash.final();
        if (signature != v.signature) v.layout.reheat(change_heat);
        v.signature = signature;
    }

    /// Moves the layout on, once a frame while the view shows.
    pub fn tick(v: *Self) !void {
        if (!v.shown) return;
        for (0..steps_per_frame) |_| try v.layout.step(v.edges.items);
    }

    /// Whether frames should keep coming: the layout is still moving or a
    /// dot or the view is being dragged.
    pub fn moving(v: Self) bool {
        return v.shown and (v.layout.moving() or v.gesture != .none);
    }

    /// The dot of the note at `path`, relative to the folder.
    pub fn find(v: Self, path: []const u8) ?u32 {
        for (v.nodes.items, 0..) |n, i| if (std.mem.eql(u8, n.key, path)) return @intCast(i);
        return null;
    }

    pub fn toScreen(v: Self, p: Vec, area: pen.Rectangle) pen.Vector2 {
        return .{
            .x = area.x + area.width / 2 + (p.x - v.centre.x) * v.zoom,
            .y = area.y + area.height / 2 + (p.y - v.centre.y) * v.zoom,
        };
    }

    pub fn toGraph(v: Self, s: pen.Vector2, area: pen.Rectangle) Vec {
        return .{
            .x = v.centre.x + (s.x - area.x - area.width / 2) / v.zoom,
            .y = v.centre.y + (s.y - area.y - area.height / 2) / v.zoom,
        };
    }

    /// Where dot `i` is drawn.
    pub fn dot(v: Self, i: u32, area: pen.Rectangle) pen.Vector2 {
        return v.toScreen(v.layout.points.items[i], area);
    }

    pub fn radius(v: Self, i: u32) f32 {
        const links: f32 = @floatFromInt(v.nodes.items[i].links);
        return @max((dot_radius + @sqrt(links) * radius_per_link) * v.zoom, min_radius);
    }

    pub fn labelled(v: Self, i: u32) bool {
        return v.zoom >= label_zoom or v.lit.items[i];
    }

    /// The dot under a screen point, the nearest if several.
    pub fn dotAt(v: Self, point: pen.Vector2, area: pen.Rectangle) ?u32 {
        var best: ?u32 = null;
        var best_d2: f32 = std.math.inf(f32);
        for (0..v.nodes.items.len) |i| {
            const d = v.dot(@intCast(i), area);
            const dx = d.x - point.x;
            const dy = d.y - point.y;
            const d2 = dx * dx + dy * dy;
            const reach = v.radius(@intCast(i)) + hit_slack;
            if (d2 <= reach * reach and d2 < best_d2) {
                best = @intCast(i);
                best_d2 = d2;
            }
        }
        return best;
    }

    /// Follows the pointer, picking out the dot under it and its neighbours.
    pub fn hover(v: *Self, point: pen.Vector2, area: pen.Rectangle) void {
        if (v.gesture == .dot) return;
        const over = v.dotAt(point, area);
        if (over != v.hovered) v.light(over);
    }

    fn light(v: *Self, over: ?u32) void {
        v.hovered = over;
        @memset(v.lit.items, false);
        const i = over orelse return;
        v.lit.items[i] = true;
        for (v.edges.items) |e| {
            if (e.from == i) v.lit.items[e.to] = true;
            if (e.to == i) v.lit.items[e.from] = true;
        }
    }

    /// A press starts dragging the dot under it, or else the whole view.
    pub fn press(v: *Self, point: pen.Vector2, area: pen.Rectangle) void {
        if (v.dotAt(point, area)) |i| {
            v.gesture = .{ .dot = .{ .index = i, .from = point } };
            v.layout.pinned = i;
        } else {
            v.gesture = .{ .pan = point };
        }
    }

    pub fn drag(v: *Self, point: pen.Vector2, area: pen.Rectangle) void {
        switch (v.gesture) {
            .none => {},
            .pan => |*last| {
                v.centre.x -= (point.x - last.x) / v.zoom;
                v.centre.y -= (point.y - last.y) / v.zoom;
                last.* = point;
            },
            .dot => |*d| {
                if (!d.moved and @abs(point.x - d.from.x) + @abs(point.y - d.from.y) < drag_threshold) return;
                d.moved = true;
                v.layout.points.items[d.index] = v.toGraph(point, area);
                v.layout.reheat(drag_heat);
            },
        }
    }

    /// Ends a press: the dot clicked without being moved, whose note opens.
    pub fn release(v: *Self) ?u32 {
        defer {
            v.gesture = .none;
            v.layout.pinned = null;
        }
        return switch (v.gesture) {
            .dot => |d| if (d.moved) null else d.index,
            else => null,
        };
    }

    /// Zooms by wheel notches, keeping the graph point under `point` still.
    pub fn zoomAt(v: *Self, point: pen.Vector2, area: pen.Rectangle, notches: f32) void {
        const before = v.toGraph(point, area);
        v.zoom = std.math.clamp(v.zoom * std.math.pow(f32, zoom_step, notches), min_zoom, max_zoom);
        v.centre = v.centre.add(before.sub(v.toGraph(point, area)));
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn sample(a: Allocator, extra: bool) !notes.Graph {
    const files: []const []const u8 = if (extra) &.{ "a.md", "b.md", "c.md" } else &.{ "a.md", "b.md" };
    const Texts = struct {
        pub fn text(_: @This(), path: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, path, "a.md")) "[[b]] [[idea]]" else "[[a]]";
        }
    };
    return notes.Graph.build(a, files, Texts{});
}

const view_area = pen.Rectangle{ .x = 100, .y = 50, .width = 800, .height = 600 };

test "a new reading keeps dots where they were and wakes the layout only on change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = GraphView.init(testing.allocator);
    defer v.deinit();

    try v.sync(try sample(arena.allocator(), false));
    try testing.expectEqual(@as(usize, 3), v.nodes.items.len);
    try testing.expect(v.nodes.items[2].missing());
    try testing.expectEqualStrings("idea", v.nodes.items[2].name());
    try testing.expectEqual(@as(u32, 3), v.nodes.items[0].links);

    v.layout.points.items[1] = .{ .x = 500, .y = 500 };
    v.layout.heat = 0;
    try v.sync(try sample(arena.allocator(), false));
    try testing.expectEqual(@as(f32, 500), v.layout.points.items[v.find("b.md").?].x);
    try testing.expect(!v.layout.moving());

    try v.sync(try sample(arena.allocator(), true));
    try testing.expect(v.layout.moving());
    try testing.expectEqual(@as(f32, 500), v.layout.points.items[v.find("b.md").?].x);
}

test "showing fits a large graph in the view, and centres on the note in front" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = GraphView.init(testing.allocator);
    defer v.deinit();
    try v.sync(try sample(arena.allocator(), true));
    v.layout.points.items[0] = .{ .x = -2000, .y = 0 };
    v.layout.points.items[1] = .{ .x = 2000, .y = 0 };
    v.layout.heat = 0;
    try v.show(null, view_area);
    try testing.expect(v.zoom < 0.25);
    try testing.expect(pen.checkCollisionPointRec(v.dot(0, view_area), view_area));
    try testing.expect(pen.checkCollisionPointRec(v.dot(1, view_area), view_area));

    try v.show("c.md", view_area);
    try testing.expectEqual(v.layout.points.items[v.find("c.md").?], v.centre);
}

test "screen and graph points map both ways, and zooming keeps the pointer's spot" {
    var v = GraphView.init(testing.allocator);
    defer v.deinit();
    v.centre = .{ .x = 30, .y = -20 };
    v.zoom = 2;
    const p = Vec{ .x = 75, .y = 10 };
    const back = v.toGraph(v.toScreen(p, view_area), view_area);
    try testing.expectApproxEqAbs(p.x, back.x, 0.001);
    try testing.expectApproxEqAbs(p.y, back.y, 0.001);

    const pointer = pen.Vector2{ .x = 640, .y = 200 };
    const under = v.toGraph(pointer, view_area);
    v.zoomAt(pointer, view_area, 3);
    const still = v.toGraph(pointer, view_area);
    try testing.expectApproxEqAbs(under.x, still.x, 0.01);
    try testing.expectApproxEqAbs(under.y, still.y, 0.01);
}

test "a click opens a dot, a drag moves it instead, and a press elsewhere pans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = GraphView.init(testing.allocator);
    defer v.deinit();
    try v.sync(try sample(arena.allocator(), false));
    const at = v.dot(1, view_area);

    v.press(at, view_area);
    try testing.expectEqual(@as(?u32, 1), v.release());

    v.press(at, view_area);
    v.drag(.{ .x = at.x + 50, .y = at.y }, view_area);
    try testing.expect(v.release() == null);
    try testing.expectApproxEqAbs(at.x + 50, v.dot(1, view_area).x, 0.01);

    const centre = v.centre;
    v.press(.{ .x = view_area.x + 2, .y = view_area.y + 2 }, view_area);
    v.drag(.{ .x = view_area.x + 42, .y = view_area.y + 2 }, view_area);
    _ = v.release();
    try testing.expectApproxEqAbs(centre.x - 40, v.centre.x, 0.01);
}
