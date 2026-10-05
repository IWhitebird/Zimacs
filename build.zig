const std = @import("std");
const rlz = @import("raylib_zig");
const zon = @import("build.zig.zon");

/// Files with tests at the bottom. `raylib` marks the ones whose types come
/// from the graphics library and so need it linked in.
const test_files = [_]struct { path: []const u8, raylib: bool }{
    .{ .path = "src/core/piecetree.zig", .raylib = false },
    .{ .path = "src/core/text.zig", .raylib = false },
    .{ .path = "src/core/wrap.zig", .raylib = false },
    .{ .path = "src/core/cursor.zig", .raylib = false },
    .{ .path = "src/core/history.zig", .raylib = false },
    .{ .path = "src/core/buffer.zig", .raylib = false },
    .{ .path = "src/core/session.zig", .raylib = false },
    .{ .path = "src/core/search.zig", .raylib = false },
    .{ .path = "src/core/field.zig", .raylib = false },
    .{ .path = "src/core/tabstrip.zig", .raylib = true },
    .{ .path = "src/core/textfile.zig", .raylib = false },
    .{ .path = "src/core/notice.zig", .raylib = false },
    .{ .path = "src/core/config.zig", .raylib = false },
    .{ .path = "src/core/prompt.zig", .raylib = false },
    .{ .path = "src/core/recent.zig", .raylib = false },
    .{ .path = "src/core/browser.zig", .raylib = false },
    .{ .path = "src/core/update.zig", .raylib = false },
    .{ .path = "src/core/selfupdate.zig", .raylib = false },
    .{ .path = "src/core/https.zig", .raylib = false },
    .{ .path = "src/core/cmap.zig", .raylib = false },
    .{ .path = "src/core/updatelog.zig", .raylib = false },
    .{ .path = "src/core/utc.zig", .raylib = false },
    .{ .path = "src/core/crash.zig", .raylib = false },
    .{ .path = "src/core/report.zig", .raylib = false },
    .{ .path = "src/core/brackets.zig", .raylib = false },
    .{ .path = "src/core/regex.zig", .raylib = false },
    .{ .path = "src/core/interval.zig", .raylib = false },
    .{ .path = "src/core/safewrite.zig", .raylib = false },
    .{ .path = "src/core/workspace.zig", .raylib = false },
    .{ .path = "src/core/sidebar.zig", .raylib = false },
    .{ .path = "src/core/fuzzy.zig", .raylib = false },
    .{ .path = "src/core/wikilink.zig", .raylib = false },
    .{ .path = "src/core/notes.zig", .raylib = false },
    .{ .path = "src/core/forcelayout.zig", .raylib = false },
    .{ .path = "src/core/palette.zig", .raylib = false },
    .{ .path = "src/core/notebook.zig", .raylib = false },
    .{ .path = "src/core/mcp.zig", .raylib = false },
    .{ .path = "src/core/foldersearch.zig", .raylib = false },
    .{ .path = "src/core/syntax.zig", .raylib = false },
    .{ .path = "src/core/comment.zig", .raylib = false },
    .{ .path = "src/core/typing.zig", .raylib = false },
    .{ .path = "src/core/language.zig", .raylib = false },
    .{ .path = "src/core/menu.zig", .raylib = true },
    .{ .path = "src/core/titlebar.zig", .raylib = true },
    .{ .path = "src/core/native.zig", .raylib = true },
    .{ .path = "src/core/filedialog.zig", .raylib = true },
    .{ .path = "src/core/find.zig", .raylib = true },
    .{ .path = "src/core/dialog.zig", .raylib = true },
    .{ .path = "src/core/theme.zig", .raylib = true },
    .{ .path = "src/core/layout.zig", .raylib = true },
    .{ .path = "src/core/welcome.zig", .raylib = true },
    .{ .path = "src/core/graph.zig", .raylib = true },
    .{ .path = "src/core/settings.zig", .raylib = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");
    const raygui = raylib_dep.module("raygui");
    const raylib_lib = raylib_dep.artifact("raylib");

    // Version comes from build.zig.zon, so there is only one place to bump it.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);
    // Set only by the release workflow.
    const self_update = b.option(bool, "self-update", "Install signed releases automatically") orelse false;
    build_info.addOption(bool, "self_update", self_update);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = App{
        .raylib = raylib,
        .raygui = raygui,
        .raylib_lib = raylib_lib,
        .build_info = build_info,
        .web = target.result.os.tag == .emscripten,
    };
    app.addTo(b, exe_module);

    // Gives Zimacs.exe its icon in Explorer and the taskbar. Only Windows
    // has the concept, so it is skipped everywhere else.
    if (target.result.os.tag == .windows) {
        exe_module.addWin32ResourceFile(.{ .file = b.path("assets/logo/zimacs.rc") });
    }

    // The web build links through emcc instead of producing a native binary.
    if (target.result.os.tag == .emscripten) {
        const wasm = b.addLibrary(.{ .name = "Zimacs", .root_module = exe_module });
        const web_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc = rlz.emsdk.emccStep(b, raylib_lib, wasm, .{
            .optimize = optimize,
            .flags = rlz.emsdk.emccDefaultFlags(b.allocator, .{
                .optimize = optimize,
                .asyncify = true,
            }),
            .settings = web_settings: {
                var settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });
                // The default fixed 16 MB heap cannot hold large files.
                settings.put("ALLOW_MEMORY_GROWTH", "1") catch @panic("OOM");
                settings.put("INITIAL_MEMORY", "33554432") catch @panic("OOM");
                break :web_settings settings;
            },
            .shell_file_path = b.path("assets/web/shell.html"),
            .install_dir = web_dir,
        });
        b.getInstallStep().dependOn(emcc);

        // `zig build -Dtarget=wasm32-emscripten run` serves it and opens a
        // browser, since a wasm page cannot be opened from the filesystem.
        const serve = rlz.emsdk.emrunStep(b, b.getInstallPath(web_dir, "Zimacs.html"), &.{});
        serve.dependOn(emcc);
        b.step("run", "Serve the web build and open it").dependOn(serve);
        return;
    }

    const exe = b.addExecutable(.{ .name = "Zimacs", .root_module = exe_module });
    // No console window alongside the editor.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the app").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    for (test_files) |file| {
        const module = b.createModule(.{
            .root_source_file = b.path(file.path),
            .target = target,
            .optimize = optimize,
        });
        if (file.raylib) app.addTo(b, module) else {
            addRootCerts(b, module);
            addSyntax(b, module, false);
        }
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// Everything the editor's own code imports.
const App = struct {
    raylib: *std.Build.Module,
    raygui: *std.Build.Module,
    raylib_lib: *std.Build.Step.Compile,
    build_info: *std.Build.Step.Options,
    web: bool,

    fn addTo(app: App, b: *std.Build, module: *std.Build.Module) void {
        module.addImport("raylib", app.raylib);
        module.addImport("raygui", app.raygui);
        module.linkLibrary(app.raylib_lib);
        module.addOptions("build_info", app.build_info);
        // Imports, so @embedFile can reach files outside src/.
        module.addAnonymousImport("font_data", .{ .root_source_file = b.path("assets/font/JetBrainsMono-Medium.ttf") });
        module.addAnonymousImport("emoji_data", .{ .root_source_file = b.path("assets/font/NotoEmoji-Subset.ttf") });
        module.addAnonymousImport("icon_data", .{ .root_source_file = b.path("assets/logo/zimacs-64.png") });
        module.addAnonymousImport("welcome_data", .{ .root_source_file = b.path("assets/web/welcome.txt") });
        addRootCerts(b, module);
        addSyntax(b, module, app.web);
    }
};

/// A Tree-sitter grammar built in, by the name `language.zig` gives it.
const Grammar = struct {
    name: []const u8,
    /// Its package in build.zig.zon is `ts_` and this, or else the name.
    package: ?[]const u8 = null,
    /// Where its `src` folder is, in a package holding several grammars.
    dir: []const u8 = "",
    /// Whether it has a hand-written scanner beside its generated parser.
    scanner: bool,
    /// Also built into the web demo, which shows a C file.
    web: bool = false,
    /// Its highlight query is written for Neovim, where a later pattern
    /// overrides an earlier one for the same node rather than the reverse.
    overrides: bool = false,
    /// Its highlight query, joined from these files in order, as its own
    /// tree-sitter.json lists them.
    queries: []const Query = &.{.{}},
};

/// One file of a highlight query.
const Query = struct {
    /// The grammar whose package holds it, when not the grammar's own.
    from: ?[]const u8 = null,
    path: []const u8 = "queries/highlights.scm",
};

const grammars = [_]Grammar{
    .{ .name = "c", .scanner = false, .web = true },
    .{ .name = "cpp", .scanner = true, .queries = &.{ .{ .from = "c" }, .{} } },
    .{ .name = "zig", .scanner = false, .overrides = true },
    .{ .name = "json", .scanner = false },
    .{ .name = "python", .scanner = true },
    .{ .name = "javascript", .scanner = true, .queries = &.{ .{}, .{ .path = "queries/highlights-jsx.scm" }, .{ .path = "queries/highlights-params.scm" } } },
    .{ .name = "typescript", .package = "typescript", .dir = "typescript", .scanner = true, .queries = &.{ .{}, .{ .from = "javascript" } } },
    .{ .name = "tsx", .package = "typescript", .dir = "tsx", .scanner = true, .queries = &.{ .{}, .{ .from = "javascript", .path = "queries/highlights-jsx.scm" }, .{ .from = "javascript" } } },
    .{ .name = "rust", .scanner = true },
    .{ .name = "go", .scanner = false },
    .{ .name = "java", .scanner = false },
    .{ .name = "bash", .scanner = true },
    .{ .name = "html", .scanner = true },
    .{ .name = "css", .scanner = true },
    .{ .name = "toml", .scanner = true, .overrides = true },
    .{ .name = "yaml", .scanner = true, .overrides = true },
    .{ .name = "xml", .dir = "xml", .scanner = true, .queries = &.{.{ .path = "queries/xml/highlights.scm" }} },
    .{ .name = "make", .scanner = false, .overrides = true },
    .{ .name = "dockerfile", .scanner = true },
    .{ .name = "markdown", .dir = "tree-sitter-markdown", .scanner = true, .queries = &.{.{ .path = "tree-sitter-markdown/queries/highlights.scm" }} },
    .{ .name = "markdown_inline", .package = "markdown", .dir = "tree-sitter-markdown-inline", .scanner = true, .queries = &.{.{ .path = "tree-sitter-markdown-inline/queries/highlights.scm" }} },
};

/// Tree-sitter and the grammars, compiled into `module`, with each
/// grammar's highlight query embedded and their names in `grammars`.
fn addSyntax(b: *std.Build, module: *std.Build.Module, web: bool) void {
    // Without the undefined-behaviour checks safe builds give C, as
    // upstream builds it: they cost a quarter of the parsing time, and the
    // function-type one traps on the `create()` scanners commonly define,
    // which C types differently from the `create(void)` it is called as.
    const c_flags = [_][]const u8{ "-std=c11", "-fno-sanitize=undefined" };
    // Emscripten supplies libc to the web build itself.
    if (!web) module.link_libc = true;
    const core = b.dependency("tree_sitter", .{});
    module.addIncludePath(core.path("lib/include"));
    module.addIncludePath(core.path("lib/src"));
    module.addCSourceFile(.{
        .file = core.path("lib/src/lib.c"),
        .flags = &(c_flags ++ [_][]const u8{ "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE" }),
    });

    var names: std.ArrayList([]const u8) = .empty;
    var overrides: std.ArrayList(bool) = .empty;
    var query_files: std.ArrayList(u32) = .empty;
    for (grammars) |g| {
        if (web and !g.web) continue;
        const dep = b.dependency(b.fmt("ts_{s}", .{g.package orelse g.name}), .{});
        const src = if (g.dir.len > 0) b.fmt("{s}/src", .{g.dir}) else "src";
        // Code shared between a package's grammars looks for the parser
        // header on the include path rather than beside itself.
        if (g.dir.len > 0) module.addIncludePath(dep.path(src));
        module.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/parser.c", .{src})), .flags = &c_flags });
        if (g.scanner) module.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/scanner.c", .{src})), .flags = &c_flags });
        for (g.queries, 0..) |q, i| {
            const holder = if (q.from) |from| b.dependency(b.fmt("ts_{s}", .{from}), .{}) else dep;
            module.addAnonymousImport(b.fmt("highlights_{s}_{d}", .{ g.name, i }), .{
                .root_source_file = holder.path(q.path),
            });
        }
        names.append(b.allocator, g.name) catch @panic("OOM");
        overrides.append(b.allocator, g.overrides) catch @panic("OOM");
        query_files.append(b.allocator, @intCast(g.queries.len)) catch @panic("OOM");
    }
    const options = b.addOptions();
    options.addOption([]const []const u8, "names", names.items);
    options.addOption([]const bool, "overrides", overrides.items);
    options.addOption([]const u32, "query_files", query_files.items);
    module.addOptions("grammars", options);
}

/// The certificates `src/core/https.zig` trusts on top of the system's.
fn addRootCerts(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("usertrust_ecc_root", .{ .root_source_file = b.path("assets/certs/usertrust-ecc.der") });
    module.addAnonymousImport("isrg_root_x1", .{ .root_source_file = b.path("assets/certs/isrg-root-x1.der") });
}
