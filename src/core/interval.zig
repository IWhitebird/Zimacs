//! Something done every so many seconds, checked from the main loop.

pub const Interval = struct {
    seconds: f64,
    last: f64 = 0,

    /// True once a period has passed since it last was, which starts the
    /// next one.
    pub fn due(i: *Interval, now: f64) bool {
        if (now - i.last < i.seconds) return false;
        i.last = now;
        return true;
    }
};

// ---------------------------------------------------------------- tests

const testing = @import("std").testing;

test "comes due once a period has passed, then waits for the next" {
    var i = Interval{ .seconds = 2 };
    try testing.expect(!i.due(1));
    try testing.expect(i.due(2));
    try testing.expect(!i.due(3.5));
    try testing.expect(i.due(4));
}
