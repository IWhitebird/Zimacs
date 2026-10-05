//! A Model Context Protocol server, which AI agents start as
//! `Zimacs mcp [folder]` and talk to over standard input and output, one
//! JSON-RPC message per line. Its tools keep notes in a folder of Markdown
//! files linked with [[name]], so an agent's memory is notes the user can
//! read, edit, and see as a graph.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const notebook = @import("notebook.zig");
const Notebook = notebook.Notebook;
const paths = @import("paths.zig");

/// The folder in Zimacs's data folder that holds the notes when no other
/// is named.
pub const memory_folder = "memory";
/// Room for messages read and written at once; longer ones still pass.
const stdio_buffer = 64 * 1024;

/// The protocol versions spoken, newest first.
const versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

/// JSON-RPC's error codes.
const Code = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
};

const instructions =
    \\These tools keep notes in {s}: Markdown files, one per note, shared with the person you work with, who can read and edit them in the Zimacs editor and see them as a graph. Use them as a memory that lasts between conversations.
    \\Before relying on what you remember about the person or their work, look in the notes with list_notes, search_notes or read_note. When you learn something worth keeping, write it down with write_note or append_to_note.
    \\Keep one topic per note, give notes plain names, and link related notes by writing [[note name]], so related_notes can follow them.
;

const Tool = struct {
    name: Name,
    description: []const u8,
    /// The JSON Schema of its arguments.
    schema: []const u8,
    read_only: bool = false,
    destructive: bool = false,

    const Name = enum { list_notes, read_note, write_note, append_to_note, search_notes, related_notes, delete_note };

    pub fn jsonStringify(t: Tool, s: anytype) !void {
        try s.beginObject();
        try s.objectField("name");
        try s.write(@tagName(t.name));
        try s.objectField("description");
        try s.write(t.description);
        try s.objectField("inputSchema");
        try s.beginWriteRaw();
        try s.writer.writeAll(t.schema);
        s.endWriteRaw();
        try s.objectField("annotations");
        try s.write(.{ .readOnlyHint = t.read_only, .destructiveHint = t.destructive, .openWorldHint = false });
        try s.endObject();
    }
};

const name_property =
    \\"name":{"type":"string","description":"The note's name, as a [[link]] would write it, or its path in the folder."}
;
const limit_property =
    \\"limit":{"type":"integer","minimum":1,"description":"The most lines to give back. Default 100."}
;

const tools = [_]Tool{
    .{
        .name = .list_notes,
        .description = "List the notes, with how many links go in and out of each, then the names linked to that have no note yet. Start here to see what is remembered.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Only notes whose path holds this text, ignoring case."},
        ++ limit_property ++ "}}",
        .read_only = true,
    },
    .{
        .name = .read_note,
        .description = "Read a note, followed by the notes it links to and the notes that link to it.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ name_property ++ "},\"required\":[\"name\"]}",
        .read_only = true,
    },
    .{
        .name = .write_note,
        .description = "Create a note, or replace the whole text of the note with this name. Link related notes by writing [[note name]] in the text. A link to a note that does not exist yet is fine: it marks something worth writing later.",
        .schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"The note's name, such as \"Ada Lovelace\". A folder in front, as in \"people/Ada Lovelace\", puts a new note in that folder."},"content":{"type":"string","description":"The whole text of the note, in Markdown."}},"required":["name","content"]}
        ,
        .destructive = true,
    },
    .{
        .name = .append_to_note,
        .description = "Add text to the end of a note, creating the note if none has this name.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ name_property ++
            \\,"content":{"type":"string","description":"The text to add, in Markdown."}},"required":["name","content"]}
        ,
    },
    .{
        .name = .search_notes,
        .description = "Find the lines of any note that hold some text, ignoring case. Each comes back as path:line: text.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"The text to look for."},
        ++ limit_property ++ "},\"required\":[\"query\"]}",
        .read_only = true,
    },
    .{
        .name = .related_notes,
        .description = "List the notes linked to a note, following links either way, nearest first. Use it to gather what is known around a topic.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ name_property ++
            \\,"depth":{"type":"integer","minimum":1,"maximum":3,"description":"How many links away to go. Default 1."}},"required":["name"]}
        ,
        .read_only = true,
    },
    .{
        .name = .delete_note,
        .description = "Delete a note. Notes linking to it keep their links, which then name a note not written yet.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ name_property ++ "},\"required\":[\"name\"]}",
        .destructive = true,
    },
};

/// Written as `{}`, where an empty tuple would be `[]`.
const Empty = struct {};

/// An argument a tool was called without, or of the wrong type. What was
/// wrong has been written to the tool's answer.
const BadArguments = error{BadArguments};

pub const Server = struct {
    gpa: Allocator,
    notebook: Notebook,
    /// Zimacs's own, for the client to show.
    version: []const u8,

    const Self = @This();

    /// Answers messages from `in` on `out` until `in` ends.
    pub fn serve(s: *Self, in: *std.Io.Reader, out: *Writer) !void {
        var line: std.Io.Writer.Allocating = .init(s.gpa);
        defer line.deinit();
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        while (true) {
            line.clearRetainingCapacity();
            const ended = if (in.streamDelimiter(&line.writer, '\n')) |_| false else |err| switch (err) {
                error.EndOfStream => true,
                else => |e| return e,
            };
            if (!ended) in.toss(1);
            const message = std.mem.trim(u8, line.written(), " \t\r");
            if (message.len > 0) {
                _ = arena.reset(.retain_capacity);
                try s.handle(arena.allocator(), message, out);
                try out.flush();
            }
            if (ended) return;
        }
    }

    /// Answers one message, unless it is a notification, which wants none.
    pub fn handle(s: *Self, arena: Allocator, line: []const u8, out: *Writer) !void {
        const message = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch
            return fail(out, .null, .parse_error, "Not JSON");
        if (message != .object) return fail(out, .null, .invalid_request, "Not a JSON-RPC message");
        // A reply to a request of ours, which are never sent.
        const method = message.object.get("method") orelse return;
        const id = message.object.get("id") orelse return;
        if (method != .string) return fail(out, id, .invalid_request, "The method is not a string");
        const params = message.object.get("params");
        const name = method.string;

        if (eql(name, "initialize")) return s.initialize(arena, out, id, params);
        if (eql(name, "ping")) return respond(out, id, Empty{});
        if (eql(name, "tools/list")) return respond(out, id, .{ .tools = tools });
        if (eql(name, "tools/call")) return s.call(arena, out, id, params);
        return fail(out, id, .method_not_found, "No such method");
    }

    fn initialize(s: *Self, arena: Allocator, out: *Writer, id: Value, params: ?Value) !void {
        // The client's version if it is one spoken here, else the newest.
        var version = versions[0];
        if (objectOf(params)) |p| if (p.get("protocolVersion")) |v| if (v == .string) {
            for (versions) |known| if (eql(known, v.string)) {
                version = known;
            };
        };
        return respond(out, id, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "zimacs", .title = "Zimacs notes (beta)", .version = s.version },
            .instructions = try std.fmt.allocPrint(arena, instructions, .{s.notebook.root}),
        });
    }

    fn call(s: *Self, arena: Allocator, out: *Writer, id: Value, params: ?Value) !void {
        const p = objectOf(params) orelse return fail(out, id, .invalid_params, "tools/call needs params");
        const name = p.get("name") orelse return fail(out, id, .invalid_params, "tools/call needs a tool name");
        if (name != .string) return fail(out, id, .invalid_params, "The tool name is not a string");
        const tool = std.meta.stringToEnum(Tool.Name, name.string) orelse return fail(out, id, .invalid_params, "No such tool");
        const args = objectOf(p.get("arguments")) orelse ObjectMap.empty;

        var answer: std.Io.Writer.Allocating = .init(arena);
        var failed = false;
        s.run(tool, args, &answer.writer) catch |err| {
            failed = true;
            if (err != error.BadArguments) {
                answer.clearRetainingCapacity();
                try answer.writer.writeAll(switch (err) {
                    error.NoSuchNote => "No note has that name. list_notes shows the notes there are.",
                    error.BadName => "A note's name must keep it inside the folder and be linkable: no leading / or ., no .. or empty parts, and none of \\ : * ? \" < > | [ ] # ^",
                    else => @errorName(err),
                });
            }
        };
        const text = answer.written();
        // Notes may hold text that is not valid UTF-8, which JSON cannot.
        const valid = if (std.unicode.utf8ValidateSlice(text)) text else try std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(text)});
        return respond(out, id, .{ .content = .{.{ .type = "text", .text = valid }}, .isError = failed });
    }

    fn run(s: *Self, tool: Tool.Name, args: ObjectMap, out: *Writer) !void {
        const nb = s.notebook;
        switch (tool) {
            .list_notes => try nb.list(out, try optionalString(args, "query", out) orelse "", try count(args, "limit", notebook.default_limit, out)),
            .read_note => try nb.read(out, try string(args, "name", out)),
            .write_note => try nb.write(out, try string(args, "name", out), try string(args, "content", out), .replace),
            .append_to_note => try nb.write(out, try string(args, "name", out), try string(args, "content", out), .append),
            .search_notes => {
                const query = try string(args, "query", out);
                if (query.len == 0) {
                    try out.writeAll("Give some text to look for.");
                    return error.BadArguments;
                }
                try nb.search(out, query, try count(args, "limit", notebook.default_limit, out));
            },
            .related_notes => try nb.related(out, try string(args, "name", out), @min(try count(args, "depth", 1, out), notebook.max_depth)),
            .delete_note => try nb.delete(out, try string(args, "name", out)),
        }
    }
};

/// Serves the notes in `folder`, or in the data folder's `memory_folder`
/// when none is named, until the client closes standard input.
pub fn run(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, folder: ?[]const u8, version: []const u8) !void {
    const root = try notesFolder(gpa, io, env, folder);
    defer gpa.free(root);
    var in_buf: [stdio_buffer]u8 = undefined;
    var out_buf: [stdio_buffer]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var server = Server{ .gpa = gpa, .notebook = .{ .gpa = gpa, .io = io, .root = root }, .version = version };
    try server.serve(&stdin.interface, &stdout.interface);
}

/// The notes folder, made if it is not there yet, as an absolute path.
/// Caller frees.
pub fn notesFolder(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, folder: ?[]const u8) ![]u8 {
    const chosen = if (folder) |f| try gpa.dupe(u8, f) else blk: {
        const data = (try paths.dataDir(gpa, env)) orelse return error.NoDataFolder;
        defer gpa.free(data);
        break :blk try std.fs.path.join(gpa, &.{ data, memory_folder });
    };
    defer gpa.free(chosen);
    try std.Io.Dir.cwd().createDirPath(io, chosen);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return gpa.dupe(u8, buf[0..try std.Io.Dir.cwd().realPathFile(io, chosen, &buf)]);
}

fn respond(out: *Writer, id: Value, result: anytype) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = result }, .{}, out);
    try out.writeByte('\n');
}

fn fail(out: *Writer, id: Value, code: Code, message: []const u8) !void {
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = @intFromEnum(code), .message = message },
    }, .{}, out);
    try out.writeByte('\n');
}

fn objectOf(v: ?Value) ?ObjectMap {
    const value = v orelse return null;
    return if (value == .object) value.object else null;
}

fn optionalString(args: ObjectMap, key: []const u8, out: *Writer) !?[]const u8 {
    const v = args.get(key) orelse return null;
    if (v == .string) return v.string;
    try out.print("`{s}` should be a string.", .{key});
    return error.BadArguments;
}

fn string(args: ObjectMap, key: []const u8, out: *Writer) ![]const u8 {
    if (try optionalString(args, key, out)) |s| return s;
    try out.print("This tool needs `{s}`, a string.", .{key});
    return error.BadArguments;
}

/// A whole number of at least 1, or `default` when not given.
fn count(args: ObjectMap, key: []const u8, default: usize, out: *Writer) !usize {
    const v = args.get(key) orelse return default;
    const n: ?i64 = switch (v) {
        .integer => |i| i,
        .float => |f| if (f == @trunc(f) and @abs(f) < 1e15) @intFromFloat(f) else null,
        else => null,
    };
    if (n) |whole| if (whole >= 1) return @intCast(whole);
    try out.print("`{s}` should be a whole number of at least 1.", .{key});
    return error.BadArguments;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Session = struct {
    tmp: testing.TmpDir,
    root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    server: Server = undefined,
    arena: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,

    fn init(t: *Session) !void {
        t.tmp = testing.tmpDir(.{});
        t.arena = .init(testing.allocator);
        t.out = .init(testing.allocator);
        const root = t.root_buf[0..try t.tmp.dir.realPath(testing.io, &t.root_buf)];
        t.server = .{ .gpa = testing.allocator, .notebook = .{ .gpa = testing.allocator, .io = testing.io, .root = root }, .version = "1.2.3" };
    }

    fn deinit(t: *Session) void {
        t.out.deinit();
        t.arena.deinit();
        t.tmp.cleanup();
    }

    /// Sends one message and parses the answer, if any.
    fn send(t: *Session, line: []const u8) !?Value {
        t.out.clearRetainingCapacity();
        try t.server.handle(t.arena.allocator(), line, &t.out.writer);
        const answer = t.out.written();
        if (answer.len == 0) return null;
        try testing.expect(answer[answer.len - 1] == '\n');
        try testing.expect(std.mem.countScalar(u8, answer, '\n') == 1);
        return try std.json.parseFromSliceLeaky(Value, t.arena.allocator(), answer, .{});
    }

    /// Calls a tool, giving back its text and whether it failed.
    fn tool(t: *Session, name: []const u8, arguments: []const u8) !struct { text: []const u8, failed: bool } {
        const line = try std.fmt.allocPrint(t.arena.allocator(),
            \\{{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
        , .{ name, arguments });
        const result = (try t.send(line)).?.object.get("result").?.object;
        return .{
            .text = result.get("content").?.array.items[0].object.get("text").?.string,
            .failed = result.get("isError").?.bool,
        };
    }
};

test "the handshake agrees a version, and notifications get no answer" {
    var t = Session{ .tmp = undefined, .arena = undefined, .out = undefined };
    try t.init();
    defer t.deinit();

    const answer = (try t.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
    )).?.object;
    try testing.expectEqual(@as(i64, 1), answer.get("id").?.integer);
    const result = answer.get("result").?.object;
    try testing.expectEqualStrings("2025-06-18", result.get("protocolVersion").?.string);
    try testing.expectEqualStrings("zimacs", result.get("serverInfo").?.object.get("name").?.string);
    try testing.expect(result.get("capabilities").?.object.get("tools") != null);

    const newest = (try t.send(
        \\{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}
    )).?.object;
    try testing.expectEqualStrings("a", newest.get("id").?.string);
    try testing.expectEqualStrings(versions[0], newest.get("result").?.object.get("protocolVersion").?.string);

    try testing.expect(try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == null);
    const pong = (try t.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}")).?.object;
    try testing.expect(pong.get("result").? == .object);
}

test "every tool is listed with a schema that parses" {
    var t = Session{ .tmp = undefined, .arena = undefined, .out = undefined };
    try t.init();
    defer t.deinit();
    const listed = (try t.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}")).?.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(tools.len, listed.len);
    for (listed) |tool| {
        const schema = tool.object.get("inputSchema").?.object;
        try testing.expectEqualStrings("object", schema.get("type").?.string);
        try testing.expect(tool.object.get("annotations").? == .object);
    }
}

test "tools keep notes, and mistakes come back as failed answers or errors" {
    var t = Session{ .tmp = undefined, .arena = undefined, .out = undefined };
    try t.init();
    defer t.deinit();

    const wrote = try t.tool("write_note", "{\"name\":\"Ada\",\"content\":\"Knew [[Babbage]].\"}");
    try testing.expect(!wrote.failed);
    try testing.expect(std.mem.startsWith(u8, wrote.text, "Wrote Ada.md."));
    const read = try t.tool("read_note", "{\"name\":\"ada\"}");
    try testing.expect(std.mem.startsWith(u8, read.text, "Knew [[Babbage]]."));
    const related = try t.tool("related_notes", "{\"name\":\"Ada\",\"depth\":2.0}");
    try testing.expectEqualStrings("1 link away: [[Babbage]] (not written yet)\n", related.text);

    const missing = try t.tool("read_note", "{\"name\":\"Nobody\"}");
    try testing.expect(missing.failed);
    const no_content = try t.tool("write_note", "{\"name\":\"x\"}");
    try testing.expect(no_content.failed);
    try testing.expect(std.mem.find(u8, no_content.text, "`content`") != null);
    const escape = try t.tool("write_note", "{\"name\":\"../x\",\"content\":\"y\"}");
    try testing.expect(escape.failed);
    const bad_limit = try t.tool("list_notes", "{\"limit\":0}");
    try testing.expect(bad_limit.failed);

    const unknown = (try t.send("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"rm_rf\"}}")).?.object;
    try testing.expectEqual(@as(i64, @intFromEnum(Code.invalid_params)), unknown.get("error").?.object.get("code").?.integer);
    const no_method = (try t.send("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/list\"}")).?.object;
    try testing.expectEqual(@as(i64, @intFromEnum(Code.method_not_found)), no_method.get("error").?.object.get("code").?.integer);
    const garbage = (try t.send("{not json")).?.object;
    try testing.expect(garbage.get("id").? == .null);
}

test "messages are read a line at a time until the input ends" {
    var t = Session{ .tmp = undefined, .arena = undefined, .out = undefined };
    try t.init();
    defer t.deinit();
    var in: std.Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        \\
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    try t.server.serve(&in, &t.out.writer);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{}}
        \\
    , t.out.written());
}
