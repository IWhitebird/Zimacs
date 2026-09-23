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

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .extra_headers = headers,
    });
    if (body.written().len > limit) return error.TooLarge;
    return .{ .status = result.status, .body = try body.toOwnedSlice() };
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
