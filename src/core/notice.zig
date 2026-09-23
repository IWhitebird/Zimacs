//! A short message in the status bar, for things worth knowing but not
//! worth stopping for: a failed save, a file reloaded from disk.

const std = @import("std");

pub const Notice = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,
    until: f64 = 0,
    /// Problems stay up longer than news.
    kind: Kind = .info,

    pub const Kind = enum { info, problem };

    const info_seconds = 4;
    const problem_seconds = 8;

    pub fn show(n: *Notice, now: f64, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrintZ(&n.buf, fmt, args) catch blk: {
            n.buf[n.buf.len - 1] = 0;
            break :blk n.buf[0 .. n.buf.len - 1 :0];
        };
        n.len = written.len;
        n.kind = kind;
        n.until = now + @as(f64, if (kind == .problem) problem_seconds else info_seconds);
    }

    pub fn text(n: *const Notice, now: f64) ?[:0]const u8 {
        if (n.len == 0 or now >= n.until) return null;
        return n.buf[0..n.len :0];
    }
};

test "a notice shows until it expires" {
    var n = Notice{};
    try std.testing.expect(n.text(0) == null);
    n.show(10, .info, "Reloaded {s}", .{"a.txt"});
    try std.testing.expectEqualStrings("Reloaded a.txt", n.text(11).?);
    try std.testing.expect(n.text(10 + Notice.info_seconds) == null);
}

test "a message too long for the buffer is cut, not dropped" {
    var n = Notice{};
    n.show(0, .problem, "{s}", .{"x" ** 400});
    try std.testing.expect(n.text(1).?.len > 0);
}
