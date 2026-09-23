//! Installs a newer release in place of the running binary, once its
//! Ed25519 signature checks out against the key compiled in below. The
//! signed message is the binary plus its version and platform, so an old
//! build cannot pose as a new one.

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const Version = @import("update.zig").Version;
const https = @import("https.zig");

/// `scripts/sign-update.sh` refuses to sign with any other key's partner.
pub const public_key_hex = "868c456d25be5c40a6a0307dc7b53d1e49e17f37d85baafeb2a15a32b63fb570";

const public_key: [32]u8 = blk: {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, public_key_hex) catch unreachable;
    break :blk out;
};

const release_base = "https://github.com/IWhitebird/Zimacs/releases/download";

const max_binary = 64 * 1024 * 1024;
const max_signature = 1024;

/// As release assets name it; null where no builds are published.
pub const platform: ?[]const u8 = if (builtin.cpu.arch != .x86_64)
    null
else switch (builtin.os.tag) {
    .linux => "linux-x86_64",
    .windows => "windows-x86_64",
    else => null,
};

pub const Error = error{ Unsupported, Unavailable, BadSignature, NoSpace };

/// The running copy is untouched; the new one starts next time.
pub fn fetchAndInstall(gpa: std.mem.Allocator, io: std.Io, version: Version) !void {
    const plat = platform orelse return error.Unsupported;

    var name_buf: [64]u8 = undefined;
    const asset = try assetName(&name_buf, plat);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v{d}.{d}.{d}/{s}", .{
        release_base, version.major, version.minor, version.patch, asset,
    }) catch return error.NoSpace;
    var sig_url_buf: [260]u8 = undefined;
    const sig_url = std.fmt.bufPrint(&sig_url_buf, "{s}.sig", .{url}) catch return error.NoSpace;

    const binary = try download(gpa, io, url, max_binary);
    defer gpa.free(binary);
    const signature = try download(gpa, io, sig_url, max_signature);
    defer gpa.free(signature);

    try verify(binary, signature, version, plat, public_key);

    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    try install(io, exe, binary);
}

/// Deletes the `.old` binary a Windows update left.
pub fn removeLeftovers(gpa: std.mem.Allocator, io: std.Io) void {
    const exe = std.process.executablePathAlloc(io, gpa) catch return;
    defer gpa.free(exe);
    const dir_path = std.fs.path.dirname(exe) orelse return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    var buf: [256]u8 = undefined;
    const old = siblingName(&buf, std.fs.path.basename(exe), ".old") catch return;
    dir.deleteFile(io, old) catch {};
}

// ------------------------------------------------------------ the parts

pub fn assetName(buf: []u8, plat: []const u8) ![]const u8 {
    const ext = if (std.mem.startsWith(u8, plat, "windows")) ".exe" else "";
    return std.fmt.bufPrint(buf, "zimacs-{s}{s}", .{ plat, ext }) catch error.NoSpace;
}

/// Must match what `scripts/sign-update.sh` appends.
pub fn signedSuffix(buf: []u8, version: Version, plat: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\nzimacs-update:{d}.{d}.{d}:{s}", .{
        version.major, version.minor, version.patch, plat,
    }) catch error.NoSpace;
}

pub fn verify(binary: []const u8, signature: []const u8, version: Version, plat: []const u8, key: [32]u8) Error!void {
    if (signature.len != Ed25519.Signature.encoded_length) return error.BadSignature;
    const public = Ed25519.PublicKey.fromBytes(key) catch return error.BadSignature;
    const sig = Ed25519.Signature.fromBytes(signature[0..Ed25519.Signature.encoded_length].*);

    var suffix_buf: [128]u8 = undefined;
    const suffix = try signedSuffix(&suffix_buf, version, plat);

    var verifier = sig.verifier(public) catch return error.BadSignature;
    verifier.update(binary);
    verifier.update(suffix);
    verifier.verify() catch return error.BadSignature;
}

pub fn install(io: std.Io, exe_path: []const u8, binary: []const u8) !void {
    const dir_path = std.fs.path.dirname(exe_path) orelse return error.Unavailable;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    try swap(io, dir, std.fs.path.basename(exe_path), binary, if (builtin.os.tag == .windows) .step_aside else .replace);
}

pub const Strategy = enum {
    /// Rename over the old file; the running process keeps its copy.
    replace,
    /// Windows can rename a running executable but not replace it, so the
    /// old one moves to `.old` first.
    step_aside,
};

/// Written alongside first, so a failure leaves a working binary.
pub fn swap(io: std.Io, dir: std.Io.Dir, name: []const u8, binary: []const u8, strategy: Strategy) !void {
    var staged_buf: [256]u8 = undefined;
    const staged = try siblingName(&staged_buf, name, ".update");
    try dir.writeFile(io, .{
        .sub_path = staged,
        .data = binary,
        .flags = .{ .permissions = .executable_file },
    });
    errdefer dir.deleteFile(io, staged) catch {};

    switch (strategy) {
        .replace => try dir.rename(staged, dir, name, io),
        .step_aside => {
            var old_buf: [256]u8 = undefined;
            const old = try siblingName(&old_buf, name, ".old");
            dir.deleteFile(io, old) catch {};
            try dir.rename(name, dir, old, io);
            dir.rename(staged, dir, name, io) catch |err| {
                dir.rename(old, dir, name, io) catch {};
                return err;
            };
        },
    }
}

fn siblingName(buf: []u8, name: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ name, suffix }) catch error.NoSpace;
}

fn download(gpa: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize) ![]u8 {
    const response = try https.get(gpa, io, url, &.{.{ .name = "user-agent", .value = "zimacs" }}, limit);
    errdefer gpa.free(response.body);
    if (response.status != .ok) return error.DownloadRefused;
    if (response.body.len == 0) return error.EmptyDownload;
    return response.body;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const test_version = Version{ .major = 1, .minor = 2, .patch = 3 };

fn testKeyPair() !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(7));
}

fn testSign(kp: Ed25519.KeyPair, binary: []const u8, version: Version, plat: []const u8) ![64]u8 {
    var buf: [128]u8 = undefined;
    const suffix = try signedSuffix(&buf, version, plat);
    const message = try std.mem.concat(testing.allocator, u8, &.{ binary, suffix });
    defer testing.allocator.free(message);
    return (try kp.sign(message, null)).toBytes();
}

test "the built-in key is a valid Ed25519 public key" {
    _ = try Ed25519.PublicKey.fromBytes(public_key);
}

test "asset names match what the release workflow uploads" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("zimacs-linux-x86_64", try assetName(&buf, "linux-x86_64"));
    try testing.expectEqualStrings("zimacs-windows-x86_64.exe", try assetName(&buf, "windows-x86_64"));
}

test "the signed suffix is exactly what sign-update.sh appends" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("\nzimacs-update:1.2.3:linux-x86_64", try signedSuffix(&buf, test_version, "linux-x86_64"));
}

test "a genuine binary verifies" {
    const kp = try testKeyPair();
    const binary = "pretend this is an executable";
    const sig = try testSign(kp, binary, test_version, "linux-x86_64");
    try verify(binary, &sig, test_version, "linux-x86_64", kp.public_key.toBytes());
}

test "a single changed byte is refused" {
    const kp = try testKeyPair();
    var binary = "pretend this is an executable".*;
    const sig = try testSign(kp, &binary, test_version, "linux-x86_64");
    binary[3] ^= 1;
    try testing.expectError(error.BadSignature, verify(&binary, &sig, test_version, "linux-x86_64", kp.public_key.toBytes()));
}

test "an old build passed off as a newer version is refused" {
    const kp = try testKeyPair();
    const binary = "the genuine 1.2.3 build";
    const sig = try testSign(kp, binary, test_version, "linux-x86_64");
    const claimed = Version{ .major = 9, .minor = 0, .patch = 0 };
    try testing.expectError(error.BadSignature, verify(binary, &sig, claimed, "linux-x86_64", kp.public_key.toBytes()));
}

test "one platform's build is refused on another" {
    const kp = try testKeyPair();
    const binary = "a linux build";
    const sig = try testSign(kp, binary, test_version, "linux-x86_64");
    try testing.expectError(error.BadSignature, verify(binary, &sig, test_version, "windows-x86_64", kp.public_key.toBytes()));
}

test "a signature from any other key is refused" {
    const kp = try testKeyPair();
    const stranger = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const binary = "pretend this is an executable";
    const sig = try testSign(stranger, binary, test_version, "linux-x86_64");
    try testing.expectError(error.BadSignature, verify(binary, &sig, test_version, "linux-x86_64", kp.public_key.toBytes()));
}

test "a truncated or empty signature is refused, not read out of bounds" {
    const kp = try testKeyPair();
    try testing.expectError(error.BadSignature, verify("x", "", test_version, "linux-x86_64", kp.public_key.toBytes()));
    try testing.expectError(error.BadSignature, verify("x", "short", test_version, "linux-x86_64", kp.public_key.toBytes()));
}

fn readAll(dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1024));
}

test "replace swaps the binary in and leaves nothing behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Zimacs", .data = "old" });

    try swap(testing.io, tmp.dir, "Zimacs", "new", .replace);

    const now = try readAll(tmp.dir, "Zimacs");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("new", now);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "Zimacs.update", .{}));
}

test "step_aside keeps the old binary as .old until it is cleaned up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Zimacs.exe", .data = "old" });

    try swap(testing.io, tmp.dir, "Zimacs.exe", "new", .step_aside);

    const now = try readAll(tmp.dir, "Zimacs.exe");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("new", now);
    const old = try readAll(tmp.dir, "Zimacs.exe.old");
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("old", old);
}

test "step_aside twice in a row copes with the .old left by the first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Zimacs.exe", .data = "one" });

    try swap(testing.io, tmp.dir, "Zimacs.exe", "two", .step_aside);
    try swap(testing.io, tmp.dir, "Zimacs.exe", "three", .step_aside);

    const now = try readAll(tmp.dir, "Zimacs.exe");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("three", now);
}
