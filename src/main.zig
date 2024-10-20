const std = @import("std");
const zimacs = @import("zimacs.zig");
const print = std.debug.print;

pub fn main() !void {
    try zimacs.init();
}
