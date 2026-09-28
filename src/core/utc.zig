//! Seconds since the epoch, written as a UTC date and time.

const std = @import("std");

/// For `{f}`: `2026-09-24 11:08:00`.
pub const Utc = struct {
    seconds: i64,

    pub fn format(u: Utc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(u.seconds, 0)) };
        const day = epoch.getEpochDay().calculateYearDay();
        const month_day = day.calculateMonthDay();
        const time = epoch.getDaySeconds();
        try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            day.year,               month_day.month.numeric(), month_day.day_index + 1,
            time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
        });
    }
};

test "formats as a UTC date and time" {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{Utc{ .seconds = 1790157813 }});
    try std.testing.expectEqualStrings("2026-09-23 10:03:33", text);
}
