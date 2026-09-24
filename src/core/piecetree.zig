//! Piece tree text storage, following VS Code's design.
//!
//! Text lives in immutable byte buffers that are never edited or copied:
//! `bufs[0]` is append-only and holds everything you type; `bufs[1..]` hold
//! the original file. An edit only changes which slices of those bytes are
//! visible and in what order. Each slice is a `Piece`.
//!
//! Pieces sit in a red-black tree ordered by document position. Every node
//! caches the byte count and newline count of its left subtree, so finding a
//! line or an offset walks down the tree instead of scanning every piece.
//!
//! Lines and columns are 0-based here. Add 1 when showing them to a user.
//! Offsets are u32, so documents are limited to 4 GiB.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A 0-based line/column pair.
pub const Position = struct {
    line: u32 = 0,
    column: u32 = 0,
};

/// A line/column pair inside one byte buffer.
const Mark = struct {
    line: u32 = 0,
    column: u32 = 0,
};

/// One visible slice of one buffer.
const Piece = struct {
    buf: u32 = 0,
    start: Mark = .{},
    end: Mark = .{},
    len: u32 = 0,
    newlines: u32 = 0,
};

const Node = struct {
    parent: u32 = nil,
    left: u32 = nil,
    right: u32 = nil,
    red: bool = false,
    piece: Piece = .{},
    left_len: u32 = 0,
    left_newlines: u32 = 0,
};

/// Node 0 is a shared empty leaf, so links never need a null check.
const nil: u32 = 0;

const Buf = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Offset where each line of this buffer starts. Never empty.
    starts: std.ArrayList(u32) = .empty,

    fn deinit(b: *Buf, gpa: Allocator) void {
        b.bytes.deinit(gpa);
        b.starts.deinit(gpa);
    }

    fn lineAt(b: *const Buf, offset: u32) u32 {
        const starts = b.starts.items;
        var lo: u32 = 0;
        var hi: u32 = @intCast(starts.len - 1);
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (starts[mid] <= offset) lo = mid else hi = mid - 1;
        }
        return lo;
    }

    fn markAt(b: *const Buf, offset: u32) Mark {
        const line = b.lineAt(offset);
        return .{ .line = line, .column = offset - b.starts.items[line] };
    }

    fn offsetOf(b: *const Buf, m: Mark) u32 {
        return b.starts.items[m.line] + m.column;
    }
};

pub const PieceTree = struct {
    gpa: Allocator,
    bufs: std.ArrayList(Buf) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    free: std.ArrayList(u32) = .empty,
    root: u32 = nil,
    total_len: u32 = 0,
    total_newlines: u32 = 0,

    const Self = @This();

    /// Creates an empty document.
    pub fn init(gpa: Allocator) !Self {
        var t = Self{ .gpa = gpa };
        try t.nodes.append(gpa, .{});
        var added = Buf{};
        try added.starts.append(gpa, 0);
        try t.bufs.append(gpa, added);
        return t;
    }

    /// Creates a document holding a copy of `bytes`.
    pub fn initFromBytes(gpa: Allocator, bytes: []const u8) !Self {
        var t = try Self.init(gpa);
        errdefer t.deinit();
        if (bytes.len == 0) return t;

        var buf = Buf{};
        try buf.starts.append(gpa, 0);
        try buf.bytes.appendSlice(gpa, bytes);
        for (bytes, 0..) |b, i| {
            if (b == '\n') try buf.starts.append(gpa, @intCast(i + 1));
        }

        const index: u32 = @intCast(t.bufs.items.len);
        try t.bufs.append(gpa, buf);

        const end: u32 = @intCast(bytes.len);
        const added = &t.bufs.items[index];
        t.setRoot(try t.newNode(.{
            .buf = index,
            .start = .{},
            .end = added.markAt(end),
            .len = end,
            .newlines = added.lineAt(end),
        }));
        return t;
    }

    pub fn deinit(t: *Self) void {
        for (t.bufs.items) |*b| b.deinit(t.gpa);
        t.bufs.deinit(t.gpa);
        t.nodes.deinit(t.gpa);
        t.free.deinit(t.gpa);
        t.* = undefined;
    }

    /// Total bytes in the document.
    pub fn len(t: *const Self) u32 {
        return t.total_len;
    }

    /// Number of lines. A trailing newline opens an empty last line.
    pub fn lineCount(t: *const Self) u32 {
        return t.total_newlines + 1;
    }

    /// Offset where `line` begins.
    pub fn lineStart(t: *const Self, line: u32) u32 {
        if (line == 0) return 0;
        if (line > t.total_newlines) return t.total_len;

        var node = t.root;
        var left = line - 1;
        var offset: u32 = 0;
        while (node != nil) {
            const n = t.at(node);
            if (n.left_newlines > left) {
                node = n.left;
                continue;
            }
            left -= n.left_newlines;
            offset += n.left_len;
            if (left < n.piece.newlines) return offset + t.newlineOffset(n.piece, left);
            left -= n.piece.newlines;
            offset += n.piece.len;
            node = n.right;
        }
        return t.total_len;
    }

    /// Offset of the newline that ends `line`, or the end of the document.
    pub fn lineEnd(t: *const Self, line: u32) u32 {
        if (line >= t.total_newlines) return t.total_len;
        return t.lineStart(line + 1) - 1;
    }

    /// Length of `line`, not counting its newline.
    pub fn lineLen(t: *const Self, line: u32) u32 {
        return t.lineEnd(line) - t.lineStart(line);
    }

    /// Appends the text of `line` to `out`, without its newline.
    pub fn lineContent(t: *const Self, line: u32, out: *std.ArrayList(u8)) !void {
        const start = t.lineStart(line);
        const end = t.lineEnd(line);
        if (end > start) try t.copy(start, end - start, out);
    }

    /// Converts a byte offset to a line/column.
    pub fn positionAt(t: *const Self, offset: u32) Position {
        const target = @min(offset, t.total_len);
        var node = t.root;
        var left = target;
        var newlines: u32 = 0;

        while (node != nil) {
            const n = t.at(node);
            if (n.left_len > left) {
                node = n.left;
            } else if (n.left_len + n.piece.len > left) {
                left -= n.left_len;
                newlines += n.left_newlines;
                const line = newlines + t.countNewlines(n.piece, left);
                return .{ .line = line, .column = target - t.lineStart(line) };
            } else {
                left -= n.left_len + n.piece.len;
                newlines += n.left_newlines + n.piece.newlines;
                node = n.right;
            }
        }
        return .{ .line = t.total_newlines, .column = target - t.lineStart(t.total_newlines) };
    }

    /// Converts a line/column to a byte offset, clamping to the line's end.
    pub fn offsetAt(t: *const Self, pos: Position) u32 {
        if (pos.line > t.total_newlines) return t.total_len;
        const start = t.lineStart(pos.line);
        return start + @min(pos.column, t.lineEnd(pos.line) - start);
    }

    /// Appends `count` bytes starting at `offset` to `out`.
    pub fn copy(t: *const Self, offset: u32, count: u32, out: *std.ArrayList(u8)) !void {
        var left = @min(count, t.total_len -| offset);
        if (left == 0) return;

        var node = t.root;
        var skip = offset;
        while (node != nil) {
            const n = t.at(node);
            if (n.left_len > skip) {
                node = n.left;
            } else if (n.left_len + n.piece.len > skip) {
                skip -= n.left_len;
                break;
            } else {
                skip -= n.left_len + n.piece.len;
                node = n.right;
            }
        }

        while (node != nil and left > 0) {
            const piece = t.at(node).piece;
            const buf = &t.bufs.items[piece.buf];
            const from = buf.offsetOf(piece.start) + skip;
            const take = @min(piece.len - skip, left);
            try out.appendSlice(t.gpa, buf.bytes.items[from .. from + take]);
            left -= take;
            skip = 0;
            node = t.next(node);
        }
    }

    /// The byte at `offset`, or null past the end.
    pub fn byteAt(t: *const Self, offset: u32) ?u8 {
        if (offset >= t.total_len) return null;
        var node = t.root;
        var left = offset;
        while (node != nil) {
            const n = t.at(node);
            if (n.left_len > left) {
                node = n.left;
            } else if (n.left_len + n.piece.len > left) {
                const buf = &t.bufs.items[n.piece.buf];
                return buf.bytes.items[buf.offsetOf(n.piece.start) + left - n.left_len];
            } else {
                left -= n.left_len + n.piece.len;
                node = n.right;
            }
        }
        return null;
    }

    /// The whole document as a new slice. Caller frees it.
    pub fn allocText(t: *const Self, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try t.copy(0, t.total_len, &out);
        return out.toOwnedSlice(gpa);
    }

    /// Inserts `text` at `offset`.
    pub fn insert(t: *Self, offset: u32, text: []const u8) !void {
        if (text.len == 0) return;
        const at_offset = @min(offset, t.total_len);
        const piece = try t.addText(text);

        if (t.root == nil) {
            t.setRoot(try t.newNode(piece));
            return;
        }

        const before = try t.split(at_offset);
        if (before == nil) {
            _ = try t.insertLeft(t.first(t.root), piece);
        } else {
            _ = try t.insertRight(before, piece);
        }
    }

    /// Deletes `count` bytes starting at `offset`.
    pub fn delete(t: *Self, offset: u32, count: u32) !void {
        if (count == 0 or t.root == nil) return;
        const start = @min(offset, t.total_len);
        const end = @min(start + count, t.total_len);
        if (end <= start) return;

        _ = try t.split(start);
        _ = try t.split(end);

        // Collect before removing: removal rebalances and would invalidate
        // the walk.
        var doomed: std.ArrayList(u32) = .empty;
        defer doomed.deinit(t.gpa);

        var walked: u32 = 0;
        var node = t.first(t.root);
        while (node != nil and walked < end) : (node = t.next(node)) {
            const piece_len = t.at(node).piece.len;
            if (walked >= start) try doomed.append(t.gpa, node);
            walked += piece_len;
        }

        for (doomed.items) |d| t.remove(d);
    }

    // --- buffers ---

    fn at(t: *const Self, i: u32) *Node {
        return &t.nodes.items[i];
    }

    fn addText(t: *Self, text: []const u8) !Piece {
        const buf = &t.bufs.items[0];
        const start: u32 = @intCast(buf.bytes.items.len);
        try buf.bytes.appendSlice(t.gpa, text);
        for (text, 0..) |b, i| {
            if (b == '\n') try buf.starts.append(t.gpa, start + @as(u32, @intCast(i)) + 1);
        }
        const end: u32 = @intCast(buf.bytes.items.len);
        return .{
            .buf = 0,
            .start = buf.markAt(start),
            .end = buf.markAt(end),
            .len = end - start,
            .newlines = buf.lineAt(end) - buf.lineAt(start),
        };
    }

    /// Newlines in the first `count` bytes of `piece`.
    fn countNewlines(t: *const Self, piece: Piece, count: u32) u32 {
        if (count == 0) return 0;
        const buf = &t.bufs.items[piece.buf];
        const start = buf.offsetOf(piece.start);
        return buf.lineAt(start + count) - buf.lineAt(start);
    }

    /// Offset within `piece` just past its `k`-th newline.
    fn newlineOffset(t: *const Self, piece: Piece, k: u32) u32 {
        const buf = &t.bufs.items[piece.buf];
        return buf.starts.items[piece.start.line + k + 1] - buf.offsetOf(piece.start);
    }

    // --- nodes ---

    fn newNode(t: *Self, piece: Piece) !u32 {
        if (t.free.pop()) |i| {
            t.nodes.items[i] = .{ .piece = piece, .red = true };
            return i;
        }
        const i: u32 = @intCast(t.nodes.items.len);
        try t.nodes.append(t.gpa, .{ .piece = piece, .red = true });
        return i;
    }

    fn setRoot(t: *Self, node: u32) void {
        t.root = node;
        t.at(node).red = false;
        t.at(node).parent = nil;
        t.total_len += t.at(node).piece.len;
        t.total_newlines += t.at(node).piece.newlines;
    }

    fn first(t: *const Self, from: u32) u32 {
        var i = from;
        if (i == nil) return nil;
        while (t.at(i).left != nil) i = t.at(i).left;
        return i;
    }

    fn last(t: *const Self, from: u32) u32 {
        var i = from;
        if (i == nil) return nil;
        while (t.at(i).right != nil) i = t.at(i).right;
        return i;
    }

    fn next(t: *const Self, i: u32) u32 {
        if (t.at(i).right != nil) return t.first(t.at(i).right);
        var cur = i;
        while (true) {
            const p = t.at(cur).parent;
            if (p == nil) return nil;
            if (t.at(p).left == cur) return p;
            cur = p;
        }
    }

    fn prev(t: *const Self, i: u32) u32 {
        if (t.at(i).left != nil) return t.last(t.at(i).left);
        var cur = i;
        while (true) {
            const p = t.at(cur).parent;
            if (p == nil) return nil;
            if (t.at(p).right == cur) return p;
            cur = p;
        }
    }

    fn insertRight(t: *Self, node: u32, piece: Piece) !u32 {
        const z = try t.newNode(piece);
        if (t.at(node).right == nil) {
            t.at(node).right = z;
            t.at(z).parent = node;
        } else {
            const target = t.first(t.at(node).right);
            t.at(target).left = z;
            t.at(z).parent = target;
        }
        t.total_len += piece.len;
        t.total_newlines += piece.newlines;
        t.bumpParents(z, piece.len, piece.newlines);
        t.fixInsert(z);
        return z;
    }

    fn insertLeft(t: *Self, node: u32, piece: Piece) !u32 {
        const z = try t.newNode(piece);
        if (t.at(node).left == nil) {
            t.at(node).left = z;
            t.at(z).parent = node;
        } else {
            const target = t.last(t.at(node).left);
            t.at(target).right = z;
            t.at(z).parent = target;
        }
        t.total_len += piece.len;
        t.total_newlines += piece.newlines;
        t.bumpParents(z, piece.len, piece.newlines);
        t.fixInsert(z);
        return z;
    }

    /// Makes sure a node boundary exists at `offset`, splitting a piece if
    /// needed. Returns the node ending at `offset`, or `nil` at offset 0.
    ///
    /// Insert and delete both reduce to "split, then work on whole nodes",
    /// which keeps them short at the cost of a few extra nodes.
    fn split(t: *Self, offset: u32) !u32 {
        if (offset == 0) return nil;
        if (offset >= t.total_len) return t.last(t.root);

        var node = t.root;
        var left = offset;
        while (node != nil) {
            const n = t.at(node);
            if (n.left_len > left) {
                node = n.left;
            } else if (n.left_len + n.piece.len > left) {
                left -= n.left_len;
                break;
            } else {
                left -= n.left_len + n.piece.len;
                node = n.right;
            }
        }
        if (node == nil) return t.last(t.root);
        if (left == 0) return t.prev(node);

        const old = t.at(node).piece;
        const buf = &t.bufs.items[old.buf];
        const mid = buf.markAt(buf.offsetOf(old.start) + left);
        const head_newlines = t.countNewlines(old, left);

        const tail = Piece{
            .buf = old.buf,
            .start = mid,
            .end = old.end,
            .len = old.len - left,
            .newlines = old.newlines - head_newlines,
        };

        t.at(node).piece = .{
            .buf = old.buf,
            .start = old.start,
            .end = mid,
            .len = left,
            .newlines = head_newlines,
        };
        t.bumpParents(node, -@as(i64, tail.len), -@as(i64, tail.newlines));
        t.total_len -= tail.len;
        t.total_newlines -= tail.newlines;

        _ = try t.insertRight(node, tail);
        return node;
    }

    // --- cached subtree totals ---

    fn bumpParents(t: *Self, node: u32, d_len: i64, d_newlines: i64) void {
        if (d_len == 0 and d_newlines == 0) return;
        var cur = node;
        while (cur != t.root and cur != nil) {
            const p = t.at(cur).parent;
            if (p == nil) break;
            if (t.at(p).left == cur) {
                t.at(p).left_len = shift(t.at(p).left_len, d_len);
                t.at(p).left_newlines = shift(t.at(p).left_newlines, d_newlines);
            }
            cur = p;
        }
    }

    fn shift(base: u32, delta: i64) u32 {
        const result = @as(i64, base) + delta;
        std.debug.assert(result >= 0);
        return @intCast(result);
    }

    fn subtreeLen(t: *const Self, i: u32) u32 {
        if (i == nil) return 0;
        const n = t.at(i);
        return n.left_len + n.piece.len + t.subtreeLen(n.right);
    }

    fn subtreeNewlines(t: *const Self, i: u32) u32 {
        if (i == nil) return 0;
        const n = t.at(i);
        return n.left_newlines + n.piece.newlines + t.subtreeNewlines(n.right);
    }

    /// Repairs cached totals after the tree changed shape at `node`.
    ///
    /// `node` may be `nil` here: `remove` gives the nil node a temporary
    /// parent so a deletion with no child left behind can still walk up.
    /// Returning early on nil would leave the caches stale.
    fn fixParents(t: *Self, node: u32) void {
        var x = node;
        if (x == t.root) return;

        while (x != t.root) {
            const p = t.at(x).parent;
            if (p == nil) return;
            if (t.at(p).right != x) break;
            x = p;
        }
        if (x == t.root) return;

        const p = t.at(x).parent;
        if (p == nil) return;

        const new_len = t.subtreeLen(t.at(p).left);
        const new_newlines = t.subtreeNewlines(t.at(p).left);
        const d_len = @as(i64, new_len) - @as(i64, t.at(p).left_len);
        const d_newlines = @as(i64, new_newlines) - @as(i64, t.at(p).left_newlines);
        t.at(p).left_len = new_len;
        t.at(p).left_newlines = new_newlines;
        t.bumpParents(p, d_len, d_newlines);
    }

    // --- red-black balancing ---

    fn rotateLeft(t: *Self, x: u32) void {
        const y = t.at(x).right;
        t.at(y).left_len += t.at(x).left_len + t.at(x).piece.len;
        t.at(y).left_newlines += t.at(x).left_newlines + t.at(x).piece.newlines;

        t.at(x).right = t.at(y).left;
        if (t.at(y).left != nil) t.at(t.at(y).left).parent = x;
        t.at(y).parent = t.at(x).parent;
        if (t.at(x).parent == nil) {
            t.root = y;
        } else if (t.at(t.at(x).parent).left == x) {
            t.at(t.at(x).parent).left = y;
        } else {
            t.at(t.at(x).parent).right = y;
        }
        t.at(y).left = x;
        t.at(x).parent = y;
    }

    fn rotateRight(t: *Self, y: u32) void {
        const x = t.at(y).left;
        t.at(y).left = t.at(x).right;
        if (t.at(x).right != nil) t.at(t.at(x).right).parent = y;
        t.at(x).parent = t.at(y).parent;

        t.at(y).left_len -= t.at(x).left_len + t.at(x).piece.len;
        t.at(y).left_newlines -= t.at(x).left_newlines + t.at(x).piece.newlines;

        if (t.at(y).parent == nil) {
            t.root = x;
        } else if (t.at(t.at(y).parent).right == y) {
            t.at(t.at(y).parent).right = x;
        } else {
            t.at(t.at(y).parent).left = x;
        }
        t.at(x).right = y;
        t.at(y).parent = x;
    }

    fn fixInsert(t: *Self, node: u32) void {
        var z = node;
        t.at(z).red = true;
        while (z != t.root and t.at(t.at(z).parent).red) {
            const p = t.at(z).parent;
            const g = t.at(p).parent;
            if (p == t.at(g).left) {
                const uncle = t.at(g).right;
                if (t.at(uncle).red) {
                    t.at(p).red = false;
                    t.at(uncle).red = false;
                    t.at(g).red = true;
                    z = g;
                } else {
                    if (z == t.at(p).right) {
                        z = p;
                        t.rotateLeft(z);
                    }
                    t.at(t.at(z).parent).red = false;
                    t.at(t.at(t.at(z).parent).parent).red = true;
                    t.rotateRight(t.at(t.at(z).parent).parent);
                }
            } else {
                const uncle = t.at(g).left;
                if (t.at(uncle).red) {
                    t.at(p).red = false;
                    t.at(uncle).red = false;
                    t.at(g).red = true;
                    z = g;
                } else {
                    if (z == t.at(p).left) {
                        z = p;
                        t.rotateRight(z);
                    }
                    t.at(t.at(z).parent).red = false;
                    t.at(t.at(t.at(z).parent).parent).red = true;
                    t.rotateLeft(t.at(t.at(z).parent).parent);
                }
            }
        }
        t.at(t.root).red = false;
    }

    fn remove(t: *Self, z: u32) void {
        const gone_len = t.at(z).piece.len;
        const gone_newlines = t.at(z).piece.newlines;

        var y: u32 = undefined;
        var x: u32 = undefined;
        if (t.at(z).left == nil) {
            y = z;
            x = t.at(y).right;
        } else if (t.at(z).right == nil) {
            y = z;
            x = t.at(y).left;
        } else {
            y = t.first(t.at(z).right);
            x = t.at(y).right;
        }

        if (y == t.root) {
            t.root = x;
            t.at(x).red = false;
            t.at(x).parent = nil;
            t.recycle(z);
            t.nodes.items[nil] = .{};
            t.total_len -= gone_len;
            t.total_newlines -= gone_newlines;
            return;
        }

        const y_was_red = t.at(y).red;
        if (y == t.at(t.at(y).parent).left) {
            t.at(t.at(y).parent).left = x;
        } else {
            t.at(t.at(y).parent).right = x;
        }

        if (y == z) {
            t.at(x).parent = t.at(y).parent;
            t.fixParents(x);
        } else {
            t.at(x).parent = if (t.at(y).parent == z) y else t.at(y).parent;
            t.fixParents(x);

            t.at(y).left = t.at(z).left;
            t.at(y).right = t.at(z).right;
            t.at(y).parent = t.at(z).parent;
            t.at(y).red = t.at(z).red;

            if (z == t.root) {
                t.root = y;
            } else if (z == t.at(t.at(z).parent).left) {
                t.at(t.at(z).parent).left = y;
            } else {
                t.at(t.at(z).parent).right = y;
            }

            if (t.at(y).left != nil) t.at(t.at(y).left).parent = y;
            if (t.at(y).right != nil) t.at(t.at(y).right).parent = y;
            t.at(y).left_len = t.at(z).left_len;
            t.at(y).left_newlines = t.at(z).left_newlines;
            t.fixParents(y);
        }

        t.recycle(z);

        const p = t.at(x).parent;
        if (t.at(p).left == x) {
            const new_len = t.subtreeLen(x);
            const new_newlines = t.subtreeNewlines(x);
            if (new_len != t.at(p).left_len or new_newlines != t.at(p).left_newlines) {
                const d_len = @as(i64, new_len) - @as(i64, t.at(p).left_len);
                const d_newlines = @as(i64, new_newlines) - @as(i64, t.at(p).left_newlines);
                t.at(p).left_len = new_len;
                t.at(p).left_newlines = new_newlines;
                t.bumpParents(p, d_len, d_newlines);
            }
        }
        t.fixParents(x);

        if (!y_was_red) t.fixRemove(x);
        t.nodes.items[nil] = .{};

        t.total_len -= gone_len;
        t.total_newlines -= gone_newlines;
    }

    fn recycle(t: *Self, z: u32) void {
        t.nodes.items[z] = .{};
        t.free.append(t.gpa, z) catch {};
    }

    fn fixRemove(t: *Self, node: u32) void {
        var x = node;
        while (x != t.root and !t.at(x).red) {
            const p = t.at(x).parent;
            if (x == t.at(p).left) {
                var w = t.at(p).right;
                if (t.at(w).red) {
                    t.at(w).red = false;
                    t.at(p).red = true;
                    t.rotateLeft(p);
                    w = t.at(t.at(x).parent).right;
                }
                if (!t.at(t.at(w).left).red and !t.at(t.at(w).right).red) {
                    t.at(w).red = true;
                    x = t.at(x).parent;
                } else {
                    if (!t.at(t.at(w).right).red) {
                        t.at(t.at(w).left).red = false;
                        t.at(w).red = true;
                        t.rotateRight(w);
                        w = t.at(t.at(x).parent).right;
                    }
                    t.at(w).red = t.at(t.at(x).parent).red;
                    t.at(t.at(x).parent).red = false;
                    t.at(t.at(w).right).red = false;
                    t.rotateLeft(t.at(x).parent);
                    x = t.root;
                }
            } else {
                var w = t.at(p).left;
                if (t.at(w).red) {
                    t.at(w).red = false;
                    t.at(p).red = true;
                    t.rotateRight(p);
                    w = t.at(t.at(x).parent).left;
                }
                if (!t.at(t.at(w).left).red and !t.at(t.at(w).right).red) {
                    t.at(w).red = true;
                    x = t.at(x).parent;
                } else {
                    if (!t.at(t.at(w).left).red) {
                        t.at(t.at(w).right).red = false;
                        t.at(w).red = true;
                        t.rotateLeft(w);
                        w = t.at(t.at(x).parent).left;
                    }
                    t.at(w).red = t.at(t.at(x).parent).red;
                    t.at(t.at(x).parent).red = false;
                    t.at(t.at(w).left).red = false;
                    t.rotateRight(t.at(x).parent);
                    x = t.root;
                }
            }
        }
        t.at(x).red = false;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Deliberately naive text buffer used only as a test oracle: it rescans
/// everything, so it is obviously correct and far too slow to ship.
const Ref = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator, bytes: []const u8) !Ref {
        var r = Ref{ .gpa = gpa };
        try r.buf.appendSlice(gpa, bytes);
        return r;
    }

    fn deinit(r: *Ref) void {
        r.buf.deinit(r.gpa);
    }

    fn insert(r: *Ref, offset: u32, text: []const u8) !void {
        try r.buf.insertSlice(r.gpa, offset, text);
    }

    fn delete(r: *Ref, offset: u32, count: u32) !void {
        const end = @min(offset + count, r.buf.items.len);
        try r.buf.replaceRange(r.gpa, offset, end - offset, &.{});
    }

    fn len(r: *const Ref) u32 {
        return @intCast(r.buf.items.len);
    }

    fn lineCount(r: *const Ref) u32 {
        var count: u32 = 1;
        for (r.buf.items) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    fn lineStart(r: *const Ref, line: u32) u32 {
        if (line == 0) return 0;
        var seen: u32 = 0;
        for (r.buf.items, 0..) |c, i| {
            if (c == '\n') {
                seen += 1;
                if (seen == line) return @intCast(i + 1);
            }
        }
        return r.len();
    }

    fn lineEnd(r: *const Ref, line: u32) u32 {
        var i = r.lineStart(line);
        while (i < r.len() and r.buf.items[i] != '\n') i += 1;
        return i;
    }

    fn lineContent(r: *const Ref, line: u32) []const u8 {
        return r.buf.items[r.lineStart(line)..r.lineEnd(line)];
    }

    fn positionAt(r: *const Ref, offset: u32) Position {
        const target = @min(offset, r.len());
        var line: u32 = 0;
        for (r.buf.items[0..target]) |c| {
            if (c == '\n') line += 1;
        }
        return .{ .line = line, .column = target - r.lineStart(line) };
    }
};

fn expectAgrees(tree: *const PieceTree, ref: *const Ref) !void {
    const gpa = testing.allocator;
    try testing.expectEqual(ref.len(), tree.len());
    try testing.expectEqual(ref.lineCount(), tree.lineCount());

    const text = try tree.allocText(gpa);
    defer gpa.free(text);
    try testing.expectEqualSlices(u8, ref.buf.items, text);

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);

    var line: u32 = 0;
    while (line < ref.lineCount()) : (line += 1) {
        try testing.expectEqual(ref.lineStart(line), tree.lineStart(line));
        try testing.expectEqual(ref.lineEnd(line), tree.lineEnd(line));
        line_buf.clearRetainingCapacity();
        try tree.lineContent(line, &line_buf);
        try testing.expectEqualSlices(u8, ref.lineContent(line), line_buf.items);
    }

    var offset: u32 = 0;
    while (offset <= ref.len()) : (offset += 1) {
        const want = ref.positionAt(offset);
        const got = tree.positionAt(offset);
        try testing.expectEqual(want.line, got.line);
        try testing.expectEqual(want.column, got.column);
        try testing.expectEqual(offset, tree.offsetAt(got));
    }
}

fn expectText(tree: *const PieceTree, want: []const u8) !void {
    const got = try tree.allocText(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

fn fuzz(seed: u64, ops: u32) !void {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var tree = try PieceTree.initFromBytes(gpa, "initial\ntext\nhere\n");
    defer tree.deinit();
    var ref = try Ref.init(gpa, "initial\ntext\nhere\n");
    defer ref.deinit();

    const alphabet = "aab\ncd\nef\n";
    var scratch: [12]u8 = undefined;

    var op: u32 = 0;
    while (op < ops) : (op += 1) {
        const size = ref.len();
        // Biased toward inserts so the document does not collapse to empty.
        if (size == 0 or rand.uintLessThan(u8, 100) < 60) {
            const offset = if (size == 0) 0 else rand.uintAtMost(u32, size);
            const n = rand.intRangeAtMost(usize, 1, scratch.len);
            for (scratch[0..n]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
            try tree.insert(offset, scratch[0..n]);
            try ref.insert(offset, scratch[0..n]);
        } else {
            const offset = rand.uintLessThan(u32, size);
            const count = rand.uintAtMost(u32, size - offset);
            try tree.delete(offset, count);
            try ref.delete(offset, count);
        }
        try testing.expectEqual(ref.len(), tree.len());
        try testing.expectEqual(ref.lineCount(), tree.lineCount());
    }
    try expectAgrees(&tree, &ref);
}

test "empty document has one line" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 0), tree.len());
    try testing.expectEqual(@as(u32, 1), tree.lineCount());
    try testing.expectEqual(@as(u32, 0), tree.lineLen(0));
}

test "single line without trailing newline" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "hello");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "hello");
    defer ref.deinit();
    try testing.expectEqual(@as(u32, 1), tree.lineCount());
    try expectAgrees(&tree, &ref);
}

test "trailing newline opens an empty last line" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "a\n");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "a\n");
    defer ref.deinit();
    try testing.expectEqual(@as(u32, 2), tree.lineCount());
    try testing.expectEqual(@as(u32, 0), tree.lineLen(1));
    try expectAgrees(&tree, &ref);
}

test "consecutive newlines" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "a\n\n\nb");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "a\n\n\nb");
    defer ref.deinit();
    try testing.expectEqual(@as(u32, 4), tree.lineCount());
    try expectAgrees(&tree, &ref);
}

test "line content and line start" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "first\nsecond\nthird");
    defer tree.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try tree.lineContent(1, &buf);
    try testing.expectEqualSlices(u8, "second", buf.items);

    try testing.expectEqual(@as(u32, 6), tree.lineStart(1));
    try testing.expectEqual(@as(u32, 13), tree.lineStart(2));
}

test "insert into empty tree" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "");
    defer tree.deinit();
    try tree.insert(0, "hello");
    try expectText(&tree, "hello");
}

test "insert at start, middle and end" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "BD");
    defer tree.deinit();
    try tree.insert(0, "A");
    try expectText(&tree, "ABD");
    try tree.insert(2, "C");
    try expectText(&tree, "ABCD");
    try tree.insert(4, "E");
    try expectText(&tree, "ABCDE");
}

test "insert past end clamps" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "ab");
    defer tree.deinit();
    try tree.insert(999, "c");
    try expectText(&tree, "abc");
}

test "inserting newlines updates line count" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "ac");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "ac");
    defer ref.deinit();
    try tree.insert(1, "\nb\n");
    try ref.insert(1, "\nb\n");
    try testing.expectEqual(@as(u32, 3), tree.lineCount());
    try expectAgrees(&tree, &ref);
}

test "delete within one piece" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "abcdef");
    defer tree.deinit();
    try tree.delete(1, 2);
    try expectText(&tree, "adef");
}

test "delete across several pieces" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "aaa");
    defer tree.deinit();
    try tree.insert(1, "bbb");
    try tree.insert(2, "ccc");
    try expectText(&tree, "abcccbbaa");
    try tree.delete(1, 7);
    try expectText(&tree, "aa");
}

test "delete everything" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "hello\nworld\n");
    defer tree.deinit();
    try tree.delete(0, tree.len());
    try testing.expectEqual(@as(u32, 0), tree.len());
    try testing.expectEqual(@as(u32, 1), tree.lineCount());
}

test "delete past end clamps" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "abc");
    defer tree.deinit();
    try tree.delete(1, 999);
    try expectText(&tree, "a");
}

test "delete removing newlines updates line count" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "a\nb\nc");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "a\nb\nc");
    defer ref.deinit();
    try tree.delete(1, 2);
    try ref.delete(1, 2);
    try testing.expectEqual(@as(u32, 2), tree.lineCount());
    try expectAgrees(&tree, &ref);
}

test "offsetAt clamps an over-long column" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "ab\ncdef");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 2), tree.offsetAt(.{ .line = 0, .column = 99 }));
    try testing.expectEqual(@as(u32, 7), tree.offsetAt(.{ .line = 1, .column = 99 }));
    try testing.expectEqual(tree.len(), tree.offsetAt(.{ .line = 99, .column = 0 }));
}

test "byteAt" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "abc");
    defer tree.deinit();
    try tree.insert(1, "XY");

    try testing.expectEqual(@as(?u8, 'a'), tree.byteAt(0));
    try testing.expectEqual(@as(?u8, 'X'), tree.byteAt(1));
    try testing.expectEqual(@as(?u8, 'Y'), tree.byteAt(2));
    try testing.expectEqual(@as(?u8, 'b'), tree.byteAt(3));
    try testing.expectEqual(@as(?u8, 'c'), tree.byteAt(4));
    try testing.expectEqual(@as(?u8, null), tree.byteAt(5));
}

test "many small inserts stay consistent" {
    var tree = try PieceTree.initFromBytes(testing.allocator, "");
    defer tree.deinit();
    var ref = try Ref.init(testing.allocator, "");
    defer ref.deinit();

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const text = if (i % 7 == 0) "\n" else "x";
        try tree.insert(i, text);
        try ref.insert(i, text);
    }
    try expectAgrees(&tree, &ref);
}

test "fuzz against reference" {
    var seed: u64 = 0;
    while (seed < 50) : (seed += 1) {
        fuzz(seed, 60) catch |err| {
            std.debug.print("fuzz failed on seed {d}\n", .{seed});
            return err;
        };
    }
}

test "fuzz with long op sequences" {
    try fuzz(0xC0FFEE, 400);
    try fuzz(0xDEADBEEF, 400);
}
