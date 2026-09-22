//! Checking whether a newer Zimacs has been released, and in official builds
//! installing it.
//!
//! This asks GitHub what the latest tag is and compares it with the version
//! built into this binary. Release builds then hand over to `selfupdate.zig`,
//! which will only install a binary whose signature checks out. Anything
//! else, including a build you made yourself, just says a new version exists:
//! replacing your own `zig build` output with a release would be no help.
//!
//! The work runs on its own thread, so a slow network never stalls the
//! editor. The result is handed back through one atomic state.

const std = @import("std");
const builtin = @import("builtin");
const selfupdate = @import("selfupdate.zig");

pub const releases_url = "https://github.com/IWhitebird/Zimacs/releases";
const api_url = "https://api.github.com/repos/IWhitebird/Zimacs/releases/latest";
const max_response = 256 * 1024;

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    /// Parses "1.2.3", tolerating a leading "v" and trailing suffixes such as
    /// "-rc1", which are treated as part of the patch release.
    pub fn parse(raw: []const u8) ?Version {
        var text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len > 0 and (text[0] == 'v' or text[0] == 'V')) text = text[1..];
        if (text.len == 0) return null;

        var parts = std.mem.splitScalar(u8, text, '.');
        var out = Version{};
        out.major = parseNumber(parts.next() orelse return null) orelse return null;
        out.minor = parseNumber(parts.next() orelse "0") orelse 0;
        out.patch = parseNumber(parts.next() orelse "0") orelse 0;
        return out;
    }

    /// True when `other` is a later release than `self`.
    pub fn isOlderThan(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }
};

/// Stops at the first non-digit, so "3-rc1" reads as 3.
fn parseNumber(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, text[0..end], 10) catch null;
}

/// Pulls the tag out of GitHub's release JSON.
pub fn tagFromJson(gpa: std.mem.Allocator, body: []const u8) ?Version {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const tag = object.get("tag_name") orelse return null;
    return switch (tag) {
        .string => |s| Version.parse(s),
        else => null,
    };
}

/// Backed by an integer so it can live in an atomic.
pub const State = enum(u8) {
    idle,
    checking,
    up_to_date,
    /// Newer, but this build does not install it; see the file comment.
    available,
    downloading,
    /// On disk and verified. It runs next time Zimacs starts.
    installed,
    failed,
};

/// What a check should do about a newer release.
pub const Options = struct {
    /// Download and install it, rather than only saying it exists.
    install: bool = false,
    /// Report "up to date" and failures. Off for the check made at startup,
    /// which should say nothing unless there is something worth saying.
    announce: bool = true,
};

pub const Update = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// Only read once `state` has moved past `.checking`, which the worker
    /// sets after writing it.
    latest: Version = .{},
    /// Set before the worker starts and only read after.
    announce: bool = true,

    const Self = @This();

    pub fn status(u: *const Self) State {
        return u.state.load(.acquire);
    }

    /// Starts a check in the background. Does nothing if one is already
    /// under way, or on the web, which has neither threads nor a way out to
    /// another origin.
    pub fn start(u: *Self, gpa: std.mem.Allocator, io: std.Io, current: Version, options: Options) void {
        if (builtin.os.tag == .emscripten) return;
        switch (u.state.load(.acquire)) {
            // Running already, or done: an installed update just waits for a
            // restart, and checking again would only download it twice.
            .checking, .downloading, .installed => return,
            else => {},
        }

        u.announce = options.announce;
        u.state.store(.checking, .release);
        const thread = std.Thread.spawn(.{}, work, .{ u, gpa, io, current, options }) catch {
            u.state.store(.failed, .release);
            return;
        };
        thread.detach();
    }

    fn work(u: *Self, gpa: std.mem.Allocator, io: std.Io, current: Version, options: Options) void {
        const latest = fetchLatest(gpa, io) catch |err| {
            // Nothing published yet means there is nothing to be behind.
            u.state.store(if (err == error.NoReleases) .up_to_date else .failed, .release);
            return;
        };
        // Written before the state that publishes it.
        u.latest = latest;
        if (!current.isOlderThan(latest)) {
            u.state.store(.up_to_date, .release);
            return;
        }
        if (!options.install) {
            u.state.store(.available, .release);
            return;
        }

        u.state.store(.downloading, .release);
        selfupdate.fetchAndInstall(gpa, io, latest) catch {
            // Could not install it, for whatever reason: a folder it cannot
            // write to, a signature that did not check out. Say it exists
            // instead, so it can still be fetched by hand.
            u.state.store(.available, .release);
            return;
        };
        u.state.store(.installed, .release);
    }
};

const FetchError = error{ NoReleases, Unavailable };

fn fetchLatest(gpa: std.mem.Allocator, io: std.Io) FetchError!Version {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = api_url },
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "zimacs" },
        },
    }) catch return error.Unavailable;

    if (result.status == .not_found) return error.NoReleases;
    if (result.status != .ok) return error.Unavailable;
    if (body.written().len > max_response) return error.Unavailable;
    return tagFromJson(gpa, body.written()) orelse error.Unavailable;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parses plain versions" {
    const v = Version.parse("1.2.3").?;
    try testing.expectEqual(@as(u32, 1), v.major);
    try testing.expectEqual(@as(u32, 2), v.minor);
    try testing.expectEqual(@as(u32, 3), v.patch);
}

test "parses a leading v and missing parts" {
    try testing.expectEqual(@as(u32, 2), Version.parse("v2.1.0").?.major);
    try testing.expectEqual(@as(u32, 0), Version.parse("v2").?.minor);
    try testing.expectEqual(@as(u32, 5), Version.parse("0.5").?.minor);
    try testing.expectEqual(@as(u32, 0), Version.parse("0.5").?.patch);
}

test "a pre-release suffix does not break the parse" {
    const v = Version.parse("v1.4.2-rc1").?;
    try testing.expectEqual(@as(u32, 4), v.minor);
    try testing.expectEqual(@as(u32, 2), v.patch);
}

test "rubbish is rejected rather than guessed at" {
    try testing.expect(Version.parse("") == null);
    try testing.expect(Version.parse("v") == null);
    try testing.expect(Version.parse("latest") == null);
}

test "ordering" {
    const v = Version.parse;
    try testing.expect(v("0.1.0").?.isOlderThan(v("0.2.0").?));
    try testing.expect(v("0.1.0").?.isOlderThan(v("1.0.0").?));
    try testing.expect(v("0.1.0").?.isOlderThan(v("0.1.1").?));
    try testing.expect(!v("0.2.0").?.isOlderThan(v("0.1.9").?));
    // The same version is not an update.
    try testing.expect(!v("1.2.3").?.isOlderThan(v("1.2.3").?));
    // Numeric, not lexicographic: 10 comes after 9.
    try testing.expect(v("0.9.0").?.isOlderThan(v("0.10.0").?));
}

test "reads the tag out of GitHub's json" {
    const body =
        \\{"tag_name":"v0.3.1","name":"Zimacs 0.3.1","draft":false}
    ;
    const v = tagFromJson(testing.allocator, body).?;
    try testing.expectEqual(@as(u32, 0), v.major);
    try testing.expectEqual(@as(u32, 3), v.minor);
    try testing.expectEqual(@as(u32, 1), v.patch);
}

test "malformed json does not crash the check" {
    try testing.expect(tagFromJson(testing.allocator, "not json") == null);
    try testing.expect(tagFromJson(testing.allocator, "{}") == null);
    try testing.expect(tagFromJson(testing.allocator, "{\"tag_name\":42}") == null);
    try testing.expect(tagFromJson(testing.allocator, "[1,2,3]") == null);
}
