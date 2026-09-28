//! The link Help > Report a Problem opens: a new GitHub issue filled in with
//! what helps to find a fault. Nothing is sent until the user submits it.

const std = @import("std");

const new_issue_url = "https://github.com/IWhitebird/Zimacs/issues/new";
/// Browsers and GitHub cope with URLs well past this, but not unboundedly.
const max_url_bytes = 7000;
/// Enough of a crash to show its message and the frames that matter.
const max_crash_bytes = 2400;
/// The update log's most recent lines.
const update_log_lines = 12;

pub const Details = struct {
    version: []const u8,
    platform: []const u8,
    crash: ?[]const u8 = null,
    update_log: ?[]const u8 = null,
};

/// The issue link, percent-encoded. Caller frees.
pub fn issueUrl(gpa: std.mem.Allocator, d: Details) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.print(gpa, "**Version:** {s} on {s}\n\n**What happened?**\n\n\n", .{ d.version, d.platform });
    if (d.crash) |crash| {
        try body.print(gpa, "**Last crash**\n```\n{s}\n```\n", .{head(crash, max_crash_bytes)});
    }
    if (d.update_log) |log| {
        try body.print(gpa, "**Update log**\n```\n{s}\n```\n", .{std.mem.trimEnd(u8, tailLines(log, update_log_lines), "\n")});
    }

    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(gpa);
    try url.appendSlice(gpa, new_issue_url ++ "?body=");
    for (body.items) |byte| {
        if (url.items.len + 3 > max_url_bytes) break;
        try appendEncoded(gpa, &url, byte);
    }
    return url.toOwnedSlice(gpa);
}

fn appendEncoded(gpa: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
        try out.append(gpa, byte);
    } else {
        try out.print(gpa, "%{X:0>2}", .{byte});
    }
}

/// The start of `text`, cut at a line.
fn head(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return std.mem.trimEnd(u8, text, "\n");
    const cut = std.mem.findScalarLast(u8, text[0..max], '\n') orelse max;
    return text[0..cut];
}

/// The last `count` lines of `text`.
fn tailLines(text: []const u8, count: usize) []const u8 {
    var seen: usize = 0;
    var i = std.mem.trimEnd(u8, text, "\n").len;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            seen += 1;
            if (seen == count) return text[i..];
        }
    }
    return text;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn decoded(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const query = url[std.mem.find(u8, url, "?body=").? + "?body=".len ..];
    const copy = try gpa.dupe(u8, query);
    defer gpa.free(copy);
    return gpa.dupe(u8, std.Uri.percentDecodeInPlace(copy));
}

test "the issue carries the version, the crash and the latest update lines" {
    const url = try issueUrl(testing.allocator, .{
        .version = "0.1.10",
        .platform = "x86_64-linux",
        .crash = "panic: boom\nframe one\n",
        .update_log = "one\ntwo\nthree\n",
    });
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, new_issue_url ++ "?body="));
    for (url["https://".len..]) |c| try testing.expect(c != ' ' and c != '\n' and c != '#');

    const body = try decoded(testing.allocator, url);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.find(u8, body, "0.1.10 on x86_64-linux") != null);
    try testing.expect(std.mem.find(u8, body, "panic: boom\nframe one\n```") != null);
    try testing.expect(std.mem.find(u8, body, "one\ntwo\nthree\n```") != null);
}

test "a long crash and log are cut to keep the link a usable length" {
    const crash = "frame\n" ** 5000;
    const log = "line\n" ** 500;
    const url = try issueUrl(testing.allocator, .{ .version = "1", .platform = "p", .crash = crash, .update_log = log });
    defer testing.allocator.free(url);
    try testing.expect(url.len <= max_url_bytes);
    try testing.expectEqual(@as(usize, update_log_lines), std.mem.count(u8, tailLines(log, update_log_lines), "\n"));
}

test "no crash and no log still gives a form to fill in" {
    const url = try issueUrl(testing.allocator, .{ .version = "1", .platform = "p" });
    defer testing.allocator.free(url);
    const body = try decoded(testing.allocator, url);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.find(u8, body, "What happened?") != null);
    try testing.expect(std.mem.find(u8, body, "Last crash") == null);
}
