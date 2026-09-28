//! What kind of text a file holds, told from its name: how its comments are
//! written and whether typing a bracket or quote should add the closer.

const std = @import("std");

pub const Language = struct {
    name: []const u8,
    /// Lowercase, without the dot.
    extensions: []const []const u8 = &.{},
    /// Whole file names, such as Makefile, that have no telling extension.
    file_names: []const []const u8 = &.{},
    line_comment: ?[]const u8 = null,
    block_comment: ?[2][]const u8 = null,
    /// Code, where brackets and quotes pair up as they are typed. Prose
    /// is left alone.
    code: bool = true,
    /// The quote characters that pair up.
    quotes: []const u8 = "\"'",
    /// The Tree-sitter grammar that highlights it, if one is built in.
    grammar: ?[]const u8 = null,
};

pub const plain = Language{ .name = "Plain Text", .code = false, .quotes = "" };

const c_like = [2][]const u8{ "/*", "*/" };
const markup = [2][]const u8{ "<!--", "-->" };

pub const all = [_]Language{
    .{ .name = "C", .extensions = &.{ "c", "h" }, .line_comment = "//", .block_comment = c_like, .grammar = "c" },
    .{ .name = "C++", .extensions = &.{ "cc", "cpp", "cxx", "hh", "hpp", "hxx", "ino" }, .line_comment = "//", .block_comment = c_like },
    .{ .name = "Zig", .extensions = &.{ "zig", "zon" }, .line_comment = "//", .grammar = "zig" },
    .{ .name = "Rust", .extensions = &.{"rs"}, .line_comment = "//", .block_comment = c_like, .quotes = "\"", .grammar = "rust" },
    .{ .name = "Go", .extensions = &.{"go"}, .line_comment = "//", .block_comment = c_like, .quotes = "\"'`", .grammar = "go" },
    .{ .name = "JavaScript", .extensions = &.{ "js", "mjs", "cjs", "jsx" }, .line_comment = "//", .block_comment = c_like, .quotes = "\"'`", .grammar = "javascript" },
    .{ .name = "TypeScript", .extensions = &.{ "ts", "mts", "cts", "tsx" }, .line_comment = "//", .block_comment = c_like, .quotes = "\"'`" },
    .{ .name = "Java", .extensions = &.{"java"}, .line_comment = "//", .block_comment = c_like, .grammar = "java" },
    .{ .name = "Kotlin", .extensions = &.{ "kt", "kts" }, .line_comment = "//", .block_comment = c_like },
    .{ .name = "C#", .extensions = &.{"cs"}, .line_comment = "//", .block_comment = c_like },
    .{ .name = "Swift", .extensions = &.{"swift"}, .line_comment = "//", .block_comment = c_like },
    .{ .name = "Dart", .extensions = &.{"dart"}, .line_comment = "//", .block_comment = c_like },
    .{ .name = "PHP", .extensions = &.{"php"}, .line_comment = "//", .block_comment = c_like },
    .{ .name = "CSS", .extensions = &.{ "css", "scss", "less" }, .block_comment = c_like, .grammar = "css" },
    .{ .name = "JSON", .extensions = &.{ "json", "jsonc", "json5" }, .line_comment = "//", .quotes = "\"", .grammar = "json" },
    .{ .name = "Python", .extensions = &.{ "py", "pyw", "pyi" }, .line_comment = "#", .grammar = "python" },
    .{ .name = "Ruby", .extensions = &.{"rb"}, .file_names = &.{ "Gemfile", "Rakefile" }, .line_comment = "#" },
    .{ .name = "Perl", .extensions = &.{ "pl", "pm" }, .line_comment = "#" },
    .{
        .name = "Shell",
        .extensions = &.{ "sh", "bash", "zsh", "fish" },
        .file_names = &.{ ".bashrc", ".bash_profile", ".zshrc", ".profile" },
        .line_comment = "#",
        .quotes = "\"'`",
        .grammar = "bash",
    },
    .{ .name = "PowerShell", .extensions = &.{ "ps1", "psm1" }, .line_comment = "#" },
    .{ .name = "YAML", .extensions = &.{ "yml", "yaml" }, .line_comment = "#", .grammar = "yaml" },
    .{ .name = "TOML", .extensions = &.{"toml"}, .line_comment = "#", .grammar = "toml" },
    .{ .name = "INI", .extensions = &.{ "ini", "cfg", "conf" }, .file_names = &.{ ".gitignore", ".gitattributes", ".editorconfig" }, .line_comment = "#" },
    .{ .name = "Makefile", .extensions = &.{"mk"}, .file_names = &.{ "Makefile", "makefile", "GNUmakefile" }, .line_comment = "#" },
    .{ .name = "Dockerfile", .extensions = &.{"dockerfile"}, .file_names = &.{"Dockerfile"}, .line_comment = "#" },
    .{ .name = "CMake", .extensions = &.{"cmake"}, .file_names = &.{"CMakeLists.txt"}, .line_comment = "#" },
    .{ .name = "Nix", .extensions = &.{"nix"}, .line_comment = "#" },
    .{ .name = "R", .extensions = &.{"r"}, .line_comment = "#" },
    .{ .name = "Elixir", .extensions = &.{ "ex", "exs" }, .line_comment = "#" },
    .{ .name = "Lua", .extensions = &.{"lua"}, .line_comment = "--" },
    .{ .name = "SQL", .extensions = &.{"sql"}, .line_comment = "--", .block_comment = c_like },
    .{ .name = "Haskell", .extensions = &.{"hs"}, .line_comment = "--", .quotes = "\"" },
    .{ .name = "Lisp", .extensions = &.{ "lisp", "el", "clj", "cljs", "scm", "rkt" }, .line_comment = ";", .quotes = "\"" },
    .{ .name = "Erlang", .extensions = &.{ "erl", "hrl" }, .line_comment = "%" },
    .{ .name = "LaTeX", .extensions = &.{ "tex", "sty", "cls" }, .line_comment = "%", .quotes = "" },
    .{ .name = "HTML", .extensions = &.{ "html", "htm", "xhtml", "vue", "svelte" }, .block_comment = markup, .grammar = "html" },
    .{ .name = "XML", .extensions = &.{ "xml", "svg", "xsd", "xsl", "plist" }, .block_comment = markup },
    .{ .name = "Markdown", .extensions = &.{ "md", "markdown" }, .block_comment = markup, .code = false, .quotes = "" },
};

/// The language of a file called `name`, which may be a whole path.
/// The longest extension any language lists.
const max_extension = 16;

pub fn detect(name: []const u8) *const Language {
    const base = std.fs.path.basename(name);
    for (&all) |*lang| {
        for (lang.file_names) |file| if (std.mem.eql(u8, base, file)) return lang;
    }
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return &plain;
    const ext = base[dot + 1 ..];
    var lower: [max_extension]u8 = undefined;
    if (ext.len == 0 or ext.len > lower.len) return &plain;
    const wanted = std.ascii.lowerString(&lower, ext);
    for (&all) |*lang| {
        for (lang.extensions) |known| if (std.mem.eql(u8, wanted, known)) return lang;
    }
    return &plain;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "languages come from the extension, whatever its case, or the whole name" {
    try testing.expectEqualStrings("Zig", detect("/home/me/src/main.zig").name);
    try testing.expectEqualStrings("C", detect("SQLITE3.C").name);
    try testing.expectEqualStrings("Makefile", detect("/src/Makefile").name);
    try testing.expectEqualStrings("Shell", detect("/home/me/.bashrc").name);
    try testing.expectEqualStrings("Plain Text", detect("notes").name);
    try testing.expectEqualStrings("Plain Text", detect("notes.txt").name);
    try testing.expectEqualStrings("Plain Text", detect("archive.").name);
}

test "every extension is lowercase, short enough to match, and one language's" {
    for (all, 0..) |a, i| for (a.extensions) |ext| {
        for (all[i + 1 ..]) |b| for (b.extensions) |other| {
            try testing.expect(!std.mem.eql(u8, ext, other));
        };
        for (ext) |ch| try testing.expect(!std.ascii.isUpper(ch));
        try testing.expect(ext.len <= max_extension);
    };
}
