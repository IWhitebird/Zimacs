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
    .{ .path = "src/core/config.zig", .raylib = false },
    .{ .path = "src/core/prompt.zig", .raylib = false },
    .{ .path = "src/core/recent.zig", .raylib = false },
    .{ .path = "src/core/browser.zig", .raylib = false },
    .{ .path = "src/core/update.zig", .raylib = false },
    .{ .path = "src/core/menu.zig", .raylib = true },
    .{ .path = "src/core/theme.zig", .raylib = true },
    .{ .path = "src/core/layout.zig", .raylib = true },
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

    const font_file = b.path("assets/font/JetBrainsMono-Medium.ttf");
    const emoji_file = b.path("assets/font/NotoEmoji-Subset.ttf");
    const icon_file = b.path("assets/logo/zimacs-64.png");

    // Version comes from build.zig.zon, so there is only one place to bump it.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("raylib", raylib);
    exe_module.addImport("raygui", raygui);
    // An import so @embedFile can reach a file outside src/.
    exe_module.addAnonymousImport("font_data", .{ .root_source_file = font_file });
    exe_module.addAnonymousImport("emoji_data", .{ .root_source_file = emoji_file });
    exe_module.addAnonymousImport("icon_data", .{ .root_source_file = icon_file });
    exe_module.addOptions("build_info", build_info);
    exe_module.linkLibrary(raylib_lib);

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
            .settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize }),
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
        if (file.raylib) {
            module.addImport("raylib", raylib);
            module.addImport("raygui", raygui);
            module.addAnonymousImport("font_data", .{ .root_source_file = font_file });
            module.addAnonymousImport("emoji_data", .{ .root_source_file = emoji_file });
            module.addAnonymousImport("icon_data", .{ .root_source_file = icon_file });
            module.addOptions("build_info", build_info);
            module.linkLibrary(raylib_lib);
        }
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
