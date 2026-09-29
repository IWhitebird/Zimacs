//! Syntax highlighting. A file whose language has a built-in grammar keeps
//! a Tree-sitter parse tree, which its edits keep in step and which is
//! reparsed a slice at a time between frames, so even a very large file
//! never stalls the editor. The text on screen is coloured from the
//! grammar's highlight query.

const std = @import("std");
const web = @import("web.zig");
const ts = @import("treesitter.zig");
const regex = @import("regex.zig");
const PieceTree = @import("piecetree.zig").PieceTree;
const Language = @import("language.zig").Language;
const built_in = @import("grammars");

/// What a stretch of code is, for choosing its colour.
pub const Kind = enum(u8) { none, keyword, string, escape, comment, number, constant, function, type, property, tag, builtin };

/// A run of one kind, as byte offsets into the document.
pub const Span = struct { start: u32, end: u32, kind: Kind };

/// Larger files are shown plain: the tree takes around fifteen times the
/// text's size in memory.
pub const max_bytes = 16 * 1024 * 1024;

/// How much one `step` parses before handing back to the editor, in
/// Tree-sitter's progress checks, which come after a fixed amount of work
/// rather than of text: about 10 ms, or 100 KB of fresh C, here. Counting
/// bytes instead let a cheap edit, whose reparse skips ahead over reused
/// text, take many frames.
const checks_per_step = 500;
/// Captures longer than this are never compared against a predicate.
const max_predicate_text = 256;

const Grammar = struct {
    name: []const u8,
    language: *const fn () callconv(.c) *const ts.Language,
    highlights: []const u8,
    /// Where several patterns capture one node, the last wins, not the first.
    overrides: bool,
    /// The highlight query, compiled the first time a file needs it.
    compiled: ?Compiled = null,
};

var grammars = blk: {
    var list: [built_in.names.len]Grammar = undefined;
    for (built_in.names, 0..) |name, i| list[i] = .{
        .name = name,
        .language = @extern(*const fn () callconv(.c) *const ts.Language, .{ .name = "tree_sitter_" ++ name }),
        .highlights = joinedQuery(name, built_in.query_files[i]),
        .overrides = built_in.overrides[i],
    };
    break :blk list;
};

/// A grammar's highlight query, joined from the files the build embedded.
fn joinedQuery(comptime name: []const u8, comptime files: u32) []const u8 {
    var text: []const u8 = "";
    for (0..files) |i| text = text ++ @embedFile(std.fmt.comptimePrint("highlights_{s}_{d}", .{ name, i })) ++ "\n";
    return text;
}

const Compiled = struct {
    query: *ts.Query,
    overrides: bool,
    /// By capture id.
    kinds: []Kind,
    /// By pattern index.
    predicates: []const []const Predicate,
};

const Predicate = struct {
    test_: Test,
    capture: u32,
    /// Strings to compare with, or the other capture for `eq`.
    values: []const []const u8,
    other: ?u32 = null,

    const Test = enum { eq, not_eq, match, not_match, any_of, not_any_of };

    const tests = std.StaticStringMap(Test).initComptime(.{
        .{ "eq?", .eq },
        .{ "not-eq?", .not_eq },
        .{ "match?", .match },
        .{ "lua-match?", .match },
        .{ "not-match?", .not_match },
        .{ "any-of?", .any_of },
        .{ "not-any-of?", .not_any_of },
    });
};

/// Compiled queries last as long as the program, so they share one arena.
/// The web build's allocator is libc's, since emscripten owns its heap.
var compiled_arena = std.heap.ArenaAllocator.init(if (web.on_web) std.heap.c_allocator else std.heap.page_allocator);

fn grammarIndex(lang: *const Language) ?usize {
    const wanted = lang.grammar orelse return null;
    for (grammars, 0..) |g, i| if (std.mem.eql(u8, g.name, wanted)) return i;
    return null;
}

pub const Syntax = struct {
    gpa: std.mem.Allocator,
    query: *const Compiled,
    parser: *ts.Parser,
    cursor: *ts.QueryCursor,
    tree: ?*ts.Tree = null,
    /// The text has changed since the tree last matched it.
    stale: bool = true,
    /// A parse stopped partway and the next `step` carries it on.
    resuming: bool = false,
    spans: std.ArrayList(Span) = .empty,
    /// The nodes one `highlights` call has coloured, by start and end, to
    /// their place in `spans`.
    seen: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    /// Null for a language no built-in grammar covers.
    pub fn create(gpa: std.mem.Allocator, lang: *const Language) ?*Syntax {
        const index = grammarIndex(lang) orelse return null;
        const q = query(index) orelse return null;
        const parser = ts.ts_parser_new() orelse return null;
        if (!ts.ts_parser_set_language(parser, grammars[index].language())) {
            ts.ts_parser_delete(parser);
            return null;
        }
        const cursor = ts.ts_query_cursor_new() orelse {
            ts.ts_parser_delete(parser);
            return null;
        };
        const s = gpa.create(Syntax) catch {
            ts.ts_query_cursor_delete(cursor);
            ts.ts_parser_delete(parser);
            return null;
        };
        s.* = .{ .gpa = gpa, .query = q, .parser = parser, .cursor = cursor };
        return s;
    }

    pub fn destroy(s: *Syntax) void {
        if (s.tree) |t| ts.ts_tree_delete(t);
        ts.ts_query_cursor_delete(s.cursor);
        ts.ts_parser_delete(s.parser);
        s.spans.deinit(s.gpa);
        s.seen.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// Tells the tree about an edit, so the next parse can reuse the rest.
    pub fn edited(s: *Syntax, edit: ts.InputEdit) void {
        if (s.tree) |t| ts.ts_tree_edit(t, &edit);
        // A paused parse was of the old text.
        if (s.resuming) ts.ts_parser_reset(s.parser);
        s.resuming = false;
        s.stale = true;
    }

    /// Parses up to a slice of the text; `stale` stays set while there is
    /// more to do.
    pub fn step(s: *Syntax, text: *const PieceTree) void {
        if (!s.stale) return;
        var progress = Progress{};
        const input = ts.Input{ .payload = @ptrCast(@constCast(text)), .read = read };
        const options = ts.ParseOptions{ .payload = &progress, .progress_callback = Progress.check };
        const parsed = ts.ts_parser_parse_with_options(s.parser, s.tree, input, options) orelse {
            s.resuming = true;
            return;
        };
        if (s.tree) |old| ts.ts_tree_delete(old);
        s.tree = parsed;
        s.stale = false;
        s.resuming = false;
    }

    /// The coloured spans between two byte offsets, in document order: a
    /// span inside another comes after it, so drawing them in turn leaves
    /// the innermost on top. Valid until the next call.
    pub fn highlights(s: *Syntax, text: *const PieceTree, start: u32, end: u32) []const Span {
        s.spans.clearRetainingCapacity();
        s.seen.clearRetainingCapacity();
        const tree = s.tree orelse return s.spans.items;
        const q = s.query;

        _ = ts.ts_query_cursor_set_byte_range(s.cursor, start, end);
        ts.ts_query_cursor_exec(s.cursor, q.query, ts.ts_tree_root_node(tree));
        var match: ts.QueryMatch = undefined;
        var index: u32 = 0;
        while (ts.ts_query_cursor_next_capture(s.cursor, &match, &index)) {
            const capture = match.captures[index];
            const kind = q.kinds[capture.index];
            if (kind == .none) continue;
            const from = ts.ts_node_start_byte(capture.node);
            const to = ts.ts_node_end_byte(capture.node);
            const node_key = (@as(u64, from) << 32) | to;
            const earlier = s.seen.get(node_key);
            // Where several patterns name the same node, the grammar says
            // whether the first or the last one wins.
            if (earlier != null and !q.overrides) continue;
            if (!holds(q.predicates[match.pattern_index], match, text)) continue;
            if (earlier) |i| {
                s.spans.items[i].kind = kind;
                continue;
            }
            s.seen.put(s.gpa, node_key, @intCast(s.spans.items.len)) catch continue;
            s.spans.append(s.gpa, .{ .start = from, .end = to, .kind = kind }) catch break;
        }
        // Captures come by start, then by pattern, so a node that starts
        // where its parent does can come first; outer ones go first.
        std.mem.sort(Span, s.spans.items, {}, outerFirst);
        return s.spans.items;
    }
};

fn outerFirst(_: void, a: Span, b: Span) bool {
    return a.start < b.start or (a.start == b.start and a.end > b.end);
}

/// Stops a parse once it has done a slice of work.
const Progress = struct {
    checks: u32 = 0,

    fn check(state: *ts.ParseState) callconv(.c) bool {
        const p: *Progress = @ptrCast(@alignCast(state.payload.?));
        p.checks += 1;
        return p.checks >= checks_per_step;
    }
};

fn read(payload: ?*anyopaque, byte_index: u32, _: ts.Point, bytes_read: *u32) callconv(.c) ?[*]const u8 {
    const text: *const PieceTree = @ptrCast(@alignCast(payload.?));
    const chunk = text.chunkAt(byte_index);
    bytes_read.* = @intCast(chunk.len);
    return chunk.ptr;
}

fn query(index: usize) ?*const Compiled {
    const g = &grammars[index];
    if (g.compiled == null) g.compiled = compile(compiled_arena.allocator(), g) catch return null;
    return &g.compiled.?;
}

fn compile(gpa: std.mem.Allocator, g: *const Grammar) !Compiled {
    var error_offset: u32 = 0;
    var error_type: ts.QueryError = .none;
    const q = ts.ts_query_new(g.language(), g.highlights.ptr, @intCast(g.highlights.len), &error_offset, &error_type) orelse
        return error.BadQuery;
    errdefer ts.ts_query_delete(q);

    const kinds = try gpa.alloc(Kind, ts.ts_query_capture_count(q));
    for (kinds, 0..) |*k, id| k.* = kindOf(stringFor(q, @intCast(id), .capture));

    const patterns = try gpa.alloc([]const Predicate, ts.ts_query_pattern_count(q));
    for (patterns, 0..) |*p, pattern| p.* = try predicatesOf(gpa, q, @intCast(pattern));
    return .{ .query = q, .overrides = g.overrides, .kinds = kinds, .predicates = patterns };
}

fn stringFor(q: *const ts.Query, id: u32, what: enum { capture, string }) []const u8 {
    var len: u32 = 0;
    const ptr = switch (what) {
        .capture => ts.ts_query_capture_name_for_id(q, id, &len),
        .string => ts.ts_query_string_value_for_id(q, id, &len),
    };
    return ptr[0..len];
}

/// The predicates Zimacs checks. Others, such as #set! or #is-not?, place
/// no condition and are skipped.
fn predicatesOf(gpa: std.mem.Allocator, q: *const ts.Query, pattern: u32) ![]const Predicate {
    var count: u32 = 0;
    const found = ts.ts_query_predicates_for_pattern(q, pattern, &count) orelse return &.{};
    const steps = found[0..count];
    var list: std.ArrayList(Predicate) = .empty;
    errdefer list.deinit(gpa);

    var i: usize = 0;
    while (i < steps.len) {
        var end = i;
        while (end < steps.len and steps[end].type != .done) end += 1;
        const args = steps[i..end];
        i = end + 1;
        if (args.len < 2 or args[0].type != .string or args[1].type != .capture) continue;

        const test_ = Predicate.tests.get(stringFor(q, args[0].value_id, .string)) orelse continue;

        var values: std.ArrayList([]const u8) = .empty;
        var other: ?u32 = null;
        for (args[2..]) |arg| switch (arg.type) {
            .string => try values.append(gpa, stringFor(q, arg.value_id, .string)),
            .capture => other = arg.value_id,
            .done => {},
        };
        try list.append(gpa, .{ .test_ = test_, .capture = args[1].value_id, .values = try values.toOwnedSlice(gpa), .other = other });
    }
    return list.toOwnedSlice(gpa);
}

fn holds(predicates: []const Predicate, match: ts.QueryMatch, text: *const PieceTree) bool {
    for (predicates) |p| {
        var buf: [max_predicate_text]u8 = undefined;
        const subject = captureText(match, p.capture, text, &buf) orelse return false;
        const ok = switch (p.test_) {
            .eq, .not_eq => blk: {
                var other_buf: [max_predicate_text]u8 = undefined;
                const want = if (p.other) |o| captureText(match, o, text, &other_buf) orelse return false else if (p.values.len > 0) p.values[0] else return false;
                break :blk eql(subject, want) == (p.test_ == .eq);
            },
            .match, .not_match => (p.values.len > 0 and regex.matches(p.values[0], subject)) == (p.test_ == .match),
            .any_of, .not_any_of => blk: {
                var found = false;
                for (p.values) |v| found = found or eql(subject, v);
                break :blk found == (p.test_ == .any_of);
            },
        };
        if (!ok) return false;
    }
    return true;
}

fn captureText(match: ts.QueryMatch, capture: u32, text: *const PieceTree, buf: *[max_predicate_text]u8) ?[]const u8 {
    for (match.captures[0..match.capture_count]) |c| {
        if (c.index != capture) continue;
        const from = ts.ts_node_start_byte(c.node);
        const to = ts.ts_node_end_byte(c.node);
        if (to - from > buf.len) return null;
        // Usually inside one piece, so readable in place.
        const chunk = text.chunkAt(from);
        if (chunk.len >= to - from) return chunk[0 .. to - from];
        var i: u32 = from;
        while (i < to) : (i += 1) buf[i - from] = text.byteAt(i) orelse return null;
        return buf[0 .. to - from];
    }
    return null;
}

/// From a capture name such as `keyword.return` or `string.escape`.
fn kindOf(name: []const u8) Kind {
    const table = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "comment", .kind = .comment },
        .{ .prefix = "string.escape", .kind = .escape },
        .{ .prefix = "string.special", .kind = .escape },
        .{ .prefix = "escape", .kind = .escape },
        .{ .prefix = "string", .kind = .string },
        .{ .prefix = "character", .kind = .string },
        .{ .prefix = "number", .kind = .number },
        .{ .prefix = "float", .kind = .number },
        .{ .prefix = "boolean", .kind = .constant },
        .{ .prefix = "constant.builtin", .kind = .builtin },
        .{ .prefix = "constant", .kind = .constant },
        .{ .prefix = "label", .kind = .constant },
        .{ .prefix = "keyword", .kind = .keyword },
        .{ .prefix = "conditional", .kind = .keyword },
        .{ .prefix = "repeat", .kind = .keyword },
        .{ .prefix = "include", .kind = .keyword },
        .{ .prefix = "exception", .kind = .keyword },
        .{ .prefix = "function.builtin", .kind = .builtin },
        .{ .prefix = "function", .kind = .function },
        .{ .prefix = "method", .kind = .function },
        .{ .prefix = "constructor", .kind = .type },
        .{ .prefix = "type.builtin", .kind = .builtin },
        .{ .prefix = "type", .kind = .type },
        .{ .prefix = "module", .kind = .type },
        .{ .prefix = "namespace", .kind = .type },
        .{ .prefix = "variable.builtin", .kind = .builtin },
        .{ .prefix = "variable.member", .kind = .property },
        .{ .prefix = "property", .kind = .property },
        .{ .prefix = "attribute", .kind = .property },
        .{ .prefix = "field", .kind = .property },
        .{ .prefix = "tag", .kind = .tag },
    };
    for (table) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix) and
            (name.len == entry.prefix.len or name[entry.prefix.len] == '.')) return entry.kind;
    }
    return .none;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const language = @import("language.zig");

test "capture names choose their kind by the most specific prefix" {
    try testing.expectEqual(Kind.keyword, kindOf("keyword.return"));
    try testing.expectEqual(Kind.escape, kindOf("string.escape"));
    try testing.expectEqual(Kind.string, kindOf("string"));
    try testing.expectEqual(Kind.builtin, kindOf("function.builtin"));
    try testing.expectEqual(Kind.function, kindOf("function.method.call"));
    try testing.expectEqual(Kind.none, kindOf("punctuation.bracket"));
    try testing.expectEqual(Kind.none, kindOf("typewriter"));
}

test "every built-in grammar's highlight query compiles" {
    for (grammars, 0..) |g, i| {
        const q = query(i) orelse {
            std.debug.print("{s}: highlight query does not compile\n", .{g.name});
            return error.BadQuery;
        };
        try testing.expect(q.kinds.len > 0);
    }
}

fn spanText(src: []const u8, spans: []const Span, kind: Kind, out: *std.ArrayList(u8)) !void {
    for (spans) |sp| if (sp.kind == kind) {
        try out.appendSlice(testing.allocator, src[sp.start..sp.end]);
        try out.append(testing.allocator, '|');
    };
}

test "a C file is coloured, and an edit is picked up by the next parse" {
    const src = "int main(void) {\n    return 42; // done\n}\n";
    var text = try PieceTree.initFromBytes(testing.allocator, src);
    defer text.deinit();
    const s = Syntax.create(testing.allocator, language.detect("x.c")).?;
    defer s.destroy();
    while (s.stale) s.step(&text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const spans = s.highlights(&text, 0, text.len());
    try spanText(src, spans, .keyword, &out);
    try testing.expect(std.mem.find(u8, out.items, "return|") != null);
    out.clearRetainingCapacity();
    try spanText(src, spans, .comment, &out);
    try testing.expectEqualStrings("// done|", out.items);

    // Turn the number into a string literal.
    const at: u32 = @intCast(std.mem.find(u8, src, "42").?);
    try text.delete(at, 2);
    try text.insert(at, "\"s\"");
    s.edited(.{
        .start_byte = at,
        .old_end_byte = at + 2,
        .new_end_byte = at + 3,
        .start_point = .{ .row = 1, .column = 11 },
        .old_end_point = .{ .row = 1, .column = 13 },
        .new_end_point = .{ .row = 1, .column = 14 },
    });
    while (s.stale) s.step(&text);
    const now = try text.allocText(testing.allocator);
    defer testing.allocator.free(now);
    out.clearRetainingCapacity();
    try spanText(now, s.highlights(&text, 0, text.len()), .string, &out);
    try testing.expectEqualStrings("\"s\"|", out.items);
}

/// Several steps' worth of C.
const large_test_file = 1024 * 1024;

test "a large file parses a slice at a time" {
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    while (big.items.len < large_test_file) try big.appendSlice(testing.allocator, "int f(int x) { return x + 1; }\n");
    var text = try PieceTree.initFromBytes(testing.allocator, big.items);
    defer text.deinit();
    const s = Syntax.create(testing.allocator, language.detect("x.c")).?;
    defer s.destroy();
    var steps: usize = 0;
    while (s.stale) : (steps += 1) s.step(&text);
    try testing.expect(steps >= 3);
    try testing.expect(s.tree != null);
}

test "languages without a built-in grammar get no highlighter" {
    try testing.expect(Syntax.create(testing.allocator, &language.plain) == null);
    try testing.expect(Syntax.create(testing.allocator, language.detect("notes.md")) == null);
}

fn kindAt(s: *Syntax, text: *const PieceTree, src: []const u8, word: []const u8) ?Kind {
    const at: u32 = @intCast(std.mem.find(u8, src, word).?);
    var found: ?Kind = null;
    for (s.highlights(text, 0, text.len())) |sp| {
        if (sp.start <= at and at + word.len <= sp.end) found = sp.kind;
    }
    return found;
}

test "a query written for Neovim lets the later, more specific pattern win" {
    const src = "const std = @import(\"std\");\nfn f() void {\n    std.debug.print(\"x\", .{});\n}\n";
    var text = try PieceTree.initFromBytes(testing.allocator, src);
    defer text.deinit();
    const s = Syntax.create(testing.allocator, language.detect("x.zig")).?;
    defer s.destroy();
    while (s.stale) s.step(&text);
    try testing.expectEqual(Kind.function, kindAt(s, &text, src, "print").?);
}

test "a YAML key is not coloured as the string it is written as" {
    const src = "name: CI\non: [push]\n";
    var text = try PieceTree.initFromBytes(testing.allocator, src);
    defer text.deinit();
    const s = Syntax.create(testing.allocator, language.detect("x.yml")).?;
    defer s.destroy();
    while (s.stale) s.step(&text);
    try testing.expect(kindAt(s, &text, src, "name").? != .string);
}

test "spans that start together come outermost first" {
    const src = "int main(void) { return 0; }\n";
    var text = try PieceTree.initFromBytes(testing.allocator, src);
    defer text.deinit();
    const s = Syntax.create(testing.allocator, language.detect("x.c")).?;
    defer s.destroy();
    while (s.stale) s.step(&text);
    const spans = s.highlights(&text, 0, text.len());
    for (spans[1..], spans[0 .. spans.len - 1]) |b, a| {
        try testing.expect(a.start < b.start or (a.start == b.start and a.end >= b.end));
    }
}
