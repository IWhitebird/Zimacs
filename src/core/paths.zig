//! Where Zimacs keeps its settings and its saved session.
//!
//! Follows each platform's convention, so the same build behaves natively
//! everywhere:
//!
//!   Linux    ~/.config/zimacs          ~/.local/share/zimacs
//!   macOS    ~/Library/Application Support/zimacs   (both)
//!   Windows  %APPDATA%\zimacs          %LOCALAPPDATA%\zimacs
//!
//! On the web there is no filesystem, so every function returns null and the
//! caller falls back to defaults.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const app_name = "zimacs";

/// True where reading and writing files makes sense at all.
pub const has_filesystem = builtin.os.tag != .emscripten and builtin.os.tag != .wasi;

/// Directory for the config file. Caller frees. Null if it cannot be found.
pub fn configDir(gpa: Allocator, env: *const Env) !?[]u8 {
    if (!has_filesystem) return null;
    return switch (builtin.os.tag) {
        .windows => try under(gpa, env, "APPDATA", &.{app_name}),
        .macos => try under(gpa, env, "HOME", &.{ "Library", "Application Support", app_name }),
        else => if (env.get("XDG_CONFIG_HOME")) |base|
            try std.fs.path.join(gpa, &.{ base, app_name })
        else
            try under(gpa, env, "HOME", &.{ ".config", app_name }),
    };
}

/// Directory for the saved session. Caller frees. Null if it cannot be found.
pub fn dataDir(gpa: Allocator, env: *const Env) !?[]u8 {
    if (!has_filesystem) return null;
    return switch (builtin.os.tag) {
        .windows => try under(gpa, env, "LOCALAPPDATA", &.{app_name}),
        .macos => try under(gpa, env, "HOME", &.{ "Library", "Application Support", app_name }),
        else => if (env.get("XDG_DATA_HOME")) |base|
            try std.fs.path.join(gpa, &.{ base, app_name })
        else
            try under(gpa, env, "HOME", &.{ ".local", "share", app_name }),
    };
}

fn under(gpa: Allocator, env: *const Env, key: []const u8, tail: []const []const u8) !?[]u8 {
    const base = env.get(key) orelse return null;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try parts.append(gpa, base);
    try parts.appendSlice(gpa, tail);
    return try std.fs.path.join(gpa, parts.items);
}
