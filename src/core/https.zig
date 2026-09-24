//! HTTPS GETs for the update check and download. Trusts the system's roots
//! plus the ones GitHub's servers chain to: Windows installs a root only when
//! its own TLS first needs it, and Zig reads the store without asking, so a
//! machine can lack the root a release download needs.

const std = @import("std");

/// github.com and its API chain to USERTrust ECC; release downloads are
/// redirected to a host that chains to ISRG Root X1.
const github_roots = [_][]const u8{
    @embedFile("usertrust_ecc_root"),
    @embedFile("isrg_root_x1"),
};

const attempts = 3;
const retry_delay_ms = 1500;
/// A release download goes through one redirect, to GitHub's asset host.
const max_redirects = 3;
/// Replaces Zig's own rather than adding a second, which some servers refuse.
const user_agent = "zimacs";

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

/// Retries failures to connect or read, which are often momentary. The
/// caller owns `body`.
pub fn get(gpa: std.mem.Allocator, io: std.Io, url: []const u8, headers: []const std.http.Header, limit: usize) !Response {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        return getOnce(gpa, io, url, headers, limit) catch |err| {
            if (attempt == attempts or err == error.TooLarge) return err;
            io.sleep(.fromMilliseconds(retry_delay_ms), .awake) catch return err;
            continue;
        };
    }
}

fn getOnce(gpa: std.mem.Allocator, io: std.Io, url: []const u8, headers: []const std.http.Header, limit: usize) !Response {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    try trust(&client, gpa, io);

    // Rather than `fetch`, which reads a body of any size into memory.
    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .init(max_redirects),
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = headers,
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const window: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(window);
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, window);

    const body = reader.allocRemaining(gpa, .limited(limit)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        error.StreamTooLong => return error.TooLarge,
        else => |e| return e,
    };
    return .{ .status = response.head.status, .body = body };
}

/// Loads the roots up front, which also stops the client rescanning the
/// system store for itself.
fn trust(client: *std.http.Client, gpa: std.mem.Allocator, io: std.Io) !void {
    const now = std.Io.Clock.real.now(io);
    const bundle = &client.ca_bundle;
    // Unreadable system roots still leave GitHub's.
    bundle.rescan(gpa, io, now) catch {};
    for (github_roots) |der| {
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(gpa, der);
        try bundle.parseCert(gpa, start, now.toSeconds());
    }
    client.now = now;
}

test "the embedded roots parse and are in date" {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.testing.allocator);
    const now = std.Io.Clock.real.now(std.testing.io);
    for (github_roots) |der| {
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(std.testing.allocator, der);
        try bundle.parseCert(std.testing.allocator, start, now.toSeconds());
    }
    try std.testing.expectEqual(github_roots.len, bundle.map.count());
}
