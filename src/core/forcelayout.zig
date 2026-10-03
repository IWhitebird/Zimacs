//! Spreads a graph out on a plane: every point pushes the others away, every
//! link pulls its two ends together, a weak pull holds everything near the
//! middle, and the motion cools step by step until it settles.
//!
//! Pushing is worked out with a Barnes-Hut tree, which treats a far group of
//! points as one, so a step costs about n log n rather than n squared.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Vec, s: f32) Vec {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn lengthSquared(a: Vec) f32 {
        return a.x * a.x + a.y * a.y;
    }
};

pub const Edge = struct { from: u32, to: u32 };

/// The length a link settles at.
pub const link_length = 70;
/// How hard points push each other away.
const repulsion = 300;
/// How hard a link pulls towards its length.
const spring = 0.1;
/// How hard everything is pulled towards the middle.
const gravity = 0.04;
/// The share of its speed a point keeps from one step to the next.
const friction = 0.6;
/// No point moves further than this in one step.
const max_speed = 40;
/// A far group is taken as one point when its size over its distance is
/// below this.
const theta = 0.9;
/// Each step keeps this share of the heat, which scales every force.
const cooling = 0.985;
/// Below this heat the layout counts as settled and stops stepping.
const settled = 0.02;
/// Point-steps of settling done at once when a layout is first shown, so it
/// opens near its final shape.
const warm_work = 400_000;
/// The tree stops dividing here, so points on top of each other share a cell.
const max_depth = 24;
/// The angle between points placed one after another on a spiral, which
/// never lines them up.
const golden_angle = 2.39996323;

pub const Layout = struct {
    gpa: Allocator,
    points: std.ArrayList(Vec) = .empty,
    velocities: std.ArrayList(Vec) = .empty,
    forces: std.ArrayList(Vec) = .empty,
    tree: Tree = .{},
    /// How much the layout still moves, from 1 down to `settled`.
    heat: f32 = 1,
    /// A point being dragged, which stays where it is put.
    pinned: ?u32 = null,

    const Self = @This();

    pub fn deinit(l: *Self) void {
        l.points.deinit(l.gpa);
        l.velocities.deinit(l.gpa);
        l.forces.deinit(l.gpa);
        l.tree.quads.deinit(l.gpa);
    }

    pub fn moving(l: Self) bool {
        return l.heat >= settled;
    }

    /// Wakes the layout, as when points or links have been added.
    pub fn reheat(l: *Self, heat: f32) void {
        l.heat = @max(l.heat, heat);
    }

    /// Where the `index`th of many new points goes, before the layout moves
    /// it: on a spiral, so no two start on top of each other.
    pub fn spiral(index: usize) Vec {
        const i: f32 = @floatFromInt(index);
        const r = link_length * 0.5 * @sqrt(i + 1);
        return .{ .x = r * @cos(i * golden_angle), .y = r * @sin(i * golden_angle) };
    }

    /// Settles as far as `warm_work` allows, all at once.
    pub fn warm(l: *Self, edges: []const Edge) !void {
        var steps = warm_work / @max(l.points.items.len, 1);
        while (l.moving() and steps > 0) : (steps -= 1) try l.step(edges);
    }

    /// Moves every point one step, if the layout has not settled.
    pub fn step(l: *Self, edges: []const Edge) !void {
        if (!l.moving()) return;
        const n = l.points.items.len;
        try l.forces.resize(l.gpa, n);
        @memset(l.forces.items, .{});
        if (n == 0) return;

        try l.tree.build(l.gpa, l.points.items);
        for (l.points.items, l.forces.items, 0..) |p, *f, i| {
            f.* = l.tree.push(0, @intCast(i), p).sub(p.scale(gravity));
        }
        for (edges) |e| {
            const d = l.points.items[e.to].sub(l.points.items[e.from]);
            const dist = @max(@sqrt(d.lengthSquared()), 0.01);
            const pull = d.scale(spring * (dist - link_length) / dist);
            l.forces.items[e.from] = l.forces.items[e.from].add(pull);
            l.forces.items[e.to] = l.forces.items[e.to].sub(pull);
        }
        for (l.points.items, l.velocities.items, l.forces.items, 0..) |*p, *v, f, i| {
            if (l.pinned == @as(u32, @intCast(i))) {
                v.* = .{};
                continue;
            }
            v.* = v.add(f.scale(l.heat)).scale(friction);
            const speed = v.lengthSquared();
            if (speed > max_speed * max_speed) v.* = v.scale(max_speed / @sqrt(speed));
            p.* = p.add(v.*);
        }
        l.heat *= cooling;
    }
};

/// A Barnes-Hut quadtree: each cell knows how many points it holds and their
/// sum, so their centre is at hand without visiting them.
const Tree = struct {
    quads: std.ArrayList(Quad) = .empty,

    const Quad = struct {
        centre: Vec,
        half: f32,
        count: f32 = 0,
        sum: Vec = .{},
        /// The point a cell holding just one has, until it divides.
        point: ?u32 = null,
        /// Indices into `quads`; 0, the root, means none.
        children: [4]u32 = .{ 0, 0, 0, 0 },

        fn isLeaf(q: Quad) bool {
            return std.mem.allEqual(u32, &q.children, 0);
        }
    };

    fn build(t: *Tree, gpa: Allocator, points: []const Vec) !void {
        var low = points[0];
        var high = points[0];
        for (points) |p| {
            low = .{ .x = @min(low.x, p.x), .y = @min(low.y, p.y) };
            high = .{ .x = @max(high.x, p.x), .y = @max(high.y, p.y) };
        }
        const half = @max(high.x - low.x, high.y - low.y, 1) / 2;
        t.quads.clearRetainingCapacity();
        try t.quads.append(gpa, .{ .centre = low.add(high).scale(0.5), .half = half });
        for (points, 0..) |p, i| try t.insert(gpa, 0, @intCast(i), p, points, 0);
    }

    fn insert(t: *Tree, gpa: Allocator, at: u32, index: u32, p: Vec, points: []const Vec, depth: u32) Allocator.Error!void {
        const q = &t.quads.items[at];
        if (q.count == 0) {
            q.* = .{ .centre = q.centre, .half = q.half, .count = 1, .sum = p, .point = index };
            return;
        }
        q.count += 1;
        q.sum = q.sum.add(p);
        if (depth >= max_depth) return;
        // A cell with one point divides, moving that point down first.
        if (q.point) |held| {
            q.point = null;
            try t.insertBelow(gpa, at, held, points[held], points, depth);
        }
        try t.insertBelow(gpa, at, index, p, points, depth);
    }

    fn insertBelow(t: *Tree, gpa: Allocator, at: u32, index: u32, p: Vec, points: []const Vec, depth: u32) Allocator.Error!void {
        const q = t.quads.items[at];
        const east = p.x >= q.centre.x;
        const south = p.y >= q.centre.y;
        const which: usize = @as(usize, @intFromBool(east)) | (@as(usize, @intFromBool(south)) << 1);
        var child = q.children[which];
        if (child == 0) {
            const h = q.half / 2;
            child = @intCast(t.quads.items.len);
            try t.quads.append(gpa, .{
                .centre = .{ .x = q.centre.x + if (east) h else -h, .y = q.centre.y + if (south) h else -h },
                .half = h,
            });
            t.quads.items[at].children[which] = child;
        }
        try t.insert(gpa, child, index, p, points, depth + 1);
    }

    /// The push on point `index`, at `p`, from the points under cell `at`.
    fn push(t: *const Tree, at: u32, index: u32, p: Vec) Vec {
        const q = t.quads.items[at];
        if (q.count == 0 or q.point == index) return .{};
        const d = p.sub(q.sum.scale(1 / q.count));
        const dist2 = d.lengthSquared();
        const size = q.half * 2;
        if (q.isLeaf() or size * size < theta * theta * dist2) {
            // Points on top of each other part along an angle set by index.
            if (dist2 < 0.01) return Layout.spiral(index).scale(0.01);
            return d.scale(repulsion * q.count / dist2);
        }
        var total = Vec{};
        for (q.children) |c| if (c != 0) {
            total = total.add(t.push(c, index, p));
        };
        return total;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn settle(l: *Layout, edges: []const Edge) !usize {
    var steps: usize = 0;
    while (l.moving()) : (steps += 1) try l.step(edges);
    return steps;
}

fn distance(a: Vec, b: Vec) f32 {
    return @sqrt(a.sub(b).lengthSquared());
}

test "linked points settle about a link apart, and the layout comes to rest" {
    var l = Layout{ .gpa = testing.allocator };
    defer l.deinit();
    for (0..2) |i| {
        try l.points.append(testing.allocator, Layout.spiral(i));
        try l.velocities.append(testing.allocator, .{});
    }
    const steps = try settle(&l, &.{.{ .from = 0, .to = 1 }});
    try testing.expect(steps < 1000);
    const d = distance(l.points.items[0], l.points.items[1]);
    try testing.expect(d > link_length * 0.5 and d < link_length * 2.5);
}

test "points that start on top of each other move apart" {
    var l = Layout{ .gpa = testing.allocator };
    defer l.deinit();
    for (0..20) |_| {
        try l.points.append(testing.allocator, .{});
        try l.velocities.append(testing.allocator, .{});
    }
    _ = try settle(&l, &.{});
    var closest: f32 = std.math.inf(f32);
    for (l.points.items, 0..) |a, i| for (l.points.items[i + 1 ..]) |b| {
        closest = @min(closest, distance(a, b));
    };
    try testing.expect(closest > link_length * 0.25);
}

test "a pinned point stays where it is put" {
    var l = Layout{ .gpa = testing.allocator, .pinned = 0 };
    defer l.deinit();
    for (0..5) |i| {
        try l.points.append(testing.allocator, Layout.spiral(i));
        try l.velocities.append(testing.allocator, .{});
    }
    const held = l.points.items[0];
    _ = try settle(&l, &.{ .{ .from = 0, .to = 1 }, .{ .from = 0, .to = 2 } });
    try testing.expectEqual(held, l.points.items[0]);
}
