//! Checks GitHub for a newer release on a background thread and, in
//! official builds, hands it to `selfupdate.zig` to install. Builds made
//! without `-Dself-update` only report that it exists.

const std = @import("std");
const builtin = @import("builtin");
const selfupdate = @import("selfupdate.zig");
const https = @import("https.zig");
const Log = @import("updatelog.zig").Log;

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
    available,
    downloading,
    /// Verified and in place; runs next start.
    installed,
    failed,
};

pub const Options = struct {
    install: bool = false,
    /// Report "up to date" and failures too.
    announce: bool = true,
};

pub const Update = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// Written by the worker before it publishes `state`.
    latest: Version = .{},
    /// Why the last check or install failed, for the About box. Written
    /// before the state that publishes it.
    problem: ?[:0]const u8 = null,
    announce: bool = true,
    log: Log = .{},

    const Self = @This();

    pub fn status(u: *const Self) State {
        return u.state.load(.acquire);
    }

    /// No-op on the web, or while one is running or installed.
    pub fn start(u: *Self, gpa: std.mem.Allocator, io: std.Io, current: Version, options: Options) void {
        if (builtin.os.tag == .emscripten) return;
        switch (u.state.load(.acquire)) {
            .checking, .downloading, .installed => return,
            else => {},
        }

        u.announce = options.announce;
        u.problem = null;
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
            if (err == error.NoReleases) {
                u.state.store(.up_to_date, .release);
                return;
            }
            u.log.write(gpa, io, "check failed: {s}", .{@errorName(err)});
            u.problem = @errorName(err);
            u.state.store(.failed, .release);
            return;
        };
        // Written before the state that publishes it.
        u.latest = latest;
        if (!current.isOlderThan(latest)) {
            u.log.write(gpa, io, "up to date: {d}.{d}.{d}", .{ current.major, current.minor, current.patch });
            u.state.store(.up_to_date, .release);
            return;
        }
        if (!options.install) {
            u.state.store(.available, .release);
            return;
        }

        u.state.store(.downloading, .release);
        selfupdate.fetchAndInstall(gpa, io, latest) catch |err| {
            u.log.write(gpa, io, "install {d}.{d}.{d} over {d}.{d}.{d} failed: {s}", .{
                latest.major, latest.minor, latest.patch, current.major, current.minor, current.patch, @errorName(err),
            });
            // Still worth telling the user it exists.
            u.problem = @errorName(err);
            u.state.store(.available, .release);
            return;
        };
        u.log.write(gpa, io, "installed {d}.{d}.{d} over {d}.{d}.{d}", .{
            latest.major, latest.minor, latest.patch, current.major, current.minor, current.patch,
        });
        u.state.store(.installed, .release);
    }

    /// Whether the last check or install went wrong.
    pub fn failed(u: *const Self) bool {
        return switch (u.status()) {
            .failed => true,
            .available => u.problem != null,
            else => false,
        };
    }
};

/// When the background check runs: at startup, again soon after a failure
/// and less often each time, and every few hours while Zimacs stays open.
pub const Schedule = struct {
    next: f64 = 0,
    failures: usize = 0,
    /// A check it started has not been seen to finish.
    started: bool = false,

    const retry_seconds = [_]f64{ 60, 5 * 60, 15 * 60, 60 * 60 };
    const recheck_seconds = 6 * 60 * 60;

    /// True when a check should start now.
    pub fn due(s: *Schedule, now: f64, u: *const Update) bool {
        switch (u.status()) {
            .checking, .downloading, .installed => return false,
            else => {},
        }
        if (s.started) {
            s.started = false;
            if (u.failed()) {
                s.next = now + retry_seconds[@min(s.failures, retry_seconds.len - 1)];
                s.failures += 1;
            } else {
                s.next = now + recheck_seconds;
                s.failures = 0;
            }
        }
        if (now < s.next) return false;
        s.started = true;
        return true;
    }
};

fn fetchLatest(gpa: std.mem.Allocator, io: std.Io) !Version {
    const response = try https.get(gpa, io, api_url, &.{
        .{ .name = "accept", .value = "application/vnd.github+json" },
        .{ .name = "user-agent", .value = "zimacs" },
    }, max_response);
    defer gpa.free(response.body);

    if (response.status == .not_found) return error.NoReleases;
    if (response.status != .ok) return error.GitHubRefused;
    return tagFromJson(gpa, response.body) orelse error.UnreadableRelease;
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

test "the schedule checks at once, retries sooner after failures, and rechecks later" {
    var u = Update{};
    var s = Schedule{};
    // Each check that is due starts at once, as `updateInBackground` does.
    try testing.expect(s.due(0, &u));
    u.state.store(.checking, .release);
    try testing.expect(!s.due(10, &u));

    u.state.store(.failed, .release);
    try testing.expect(!s.due(10, &u));
    try testing.expect(s.due(10 + 60, &u));
    u.state.store(.checking, .release);

    u.state.store(.failed, .release);
    try testing.expect(!s.due(100, &u));
    try testing.expect(!s.due(100 + 60, &u));
    try testing.expect(s.due(100 + 5 * 60, &u));
    u.state.store(.checking, .release);

    u.state.store(.up_to_date, .release);
    try testing.expect(!s.due(1000, &u));
    try testing.expect(!s.due(1000 + 60 * 60, &u));
    try testing.expect(s.due(1000 + 6 * 60 * 60, &u));
}

test "an update that did not install counts as a failure, one that did stops the schedule" {
    var u = Update{};
    var s = Schedule{};
    try testing.expect(s.due(0, &u));
    u.problem = "ReadFailed";
    u.state.store(.available, .release);
    try testing.expect(!s.due(1, &u));
    try testing.expect(s.due(1 + 60, &u));

    u.problem = null;
    u.state.store(.installed, .release);
    try testing.expect(!s.due(1_000_000, &u));
}
