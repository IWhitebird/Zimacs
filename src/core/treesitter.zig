//! The parts of Tree-sitter's C API that highlighting uses, declared to
//! match `tree_sitter/api.h`.

pub const Language = opaque {};
pub const Parser = opaque {};
pub const Tree = opaque {};
pub const Query = opaque {};
pub const QueryCursor = opaque {};

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const InputEncoding = enum(c_uint) { utf8, utf16le, utf16be, custom };

pub const Input = extern struct {
    payload: ?*anyopaque,
    read: *const fn (payload: ?*anyopaque, byte_index: u32, position: Point, bytes_read: *u32) callconv(.c) ?[*]const u8,
    encoding: InputEncoding = .utf8,
    decode: ?*const anyopaque = null,
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,
};

pub const QueryCapture = extern struct {
    node: Node,
    index: u32,
};

pub const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const QueryCapture,
};

pub const QueryError = enum(c_uint) { none, syntax, node_type, field, capture, structure, language };

pub const PredicateStepType = enum(c_uint) { done, capture, string };

pub const PredicateStep = extern struct {
    type: PredicateStepType,
    value_id: u32,
};

pub const ParseState = extern struct {
    payload: ?*anyopaque,
    current_byte_offset: u32,
    has_error: bool,
};

pub const ParseOptions = extern struct {
    payload: ?*anyopaque,
    /// Returning true stops the parse; calling parse again resumes it.
    progress_callback: ?*const fn (state: *ParseState) callconv(.c) bool,
};

pub extern fn ts_parser_new() ?*Parser;
pub extern fn ts_parser_delete(parser: *Parser) void;
pub extern fn ts_parser_set_language(parser: *Parser, language: *const Language) bool;
pub extern fn ts_parser_parse_with_options(parser: *Parser, old_tree: ?*const Tree, input: Input, options: ParseOptions) ?*Tree;
pub extern fn ts_parser_reset(parser: *Parser) void;
pub extern fn ts_parser_set_included_ranges(parser: *Parser, ranges: [*]const Range, count: u32) bool;

pub extern fn ts_tree_delete(tree: *Tree) void;
pub extern fn ts_tree_edit(tree: *Tree, edit: *const InputEdit) void;
pub extern fn ts_tree_root_node(tree: *const Tree) Node;

pub extern fn ts_node_start_byte(node: Node) u32;
pub extern fn ts_node_end_byte(node: Node) u32;
pub extern fn ts_node_start_point(node: Node) Point;
pub extern fn ts_node_end_point(node: Node) Point;

pub extern fn ts_query_new(language: *const Language, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *QueryError) ?*Query;
pub extern fn ts_query_delete(query: *Query) void;
pub extern fn ts_query_capture_count(query: *const Query) u32;
pub extern fn ts_query_pattern_count(query: *const Query) u32;
pub extern fn ts_query_capture_name_for_id(query: *const Query, index: u32, length: *u32) [*]const u8;
pub extern fn ts_query_string_value_for_id(query: *const Query, index: u32, length: *u32) [*]const u8;
/// Null for a pattern with no predicates.
pub extern fn ts_query_predicates_for_pattern(query: *const Query, pattern_index: u32, step_count: *u32) ?[*]const PredicateStep;

pub extern fn ts_query_cursor_new() ?*QueryCursor;
pub extern fn ts_query_cursor_delete(cursor: *QueryCursor) void;
pub extern fn ts_query_cursor_exec(cursor: *QueryCursor, query: *const Query, node: Node) void;
pub extern fn ts_query_cursor_set_byte_range(cursor: *QueryCursor, start_byte: u32, end_byte: u32) bool;
pub extern fn ts_query_cursor_next_capture(cursor: *QueryCursor, match: *QueryMatch, capture_index: *u32) bool;
