//Some stupid functions that I use in every project
const std = @import("std");

pub fn printType(myType: anytype) void {
    const type_name = @typeName(@TypeOf(myType));
    std.debug.print("Type: {s}\n", .{type_name});
}

pub fn createInit(alloc: std.mem.Allocator, comptime T: type, props: anytype) !*T {
    const new = try alloc.create(T);
    new.* = props;
    return new;
}

pub fn u8ToCstr(str: anytype, allocator: std.mem.Allocator) anyerror![*:0]const u8 {
    const line_alloc = try std.fmt.allocPrint(allocator, "{s}", .{str});
    const line_with_null: [*:0]const u8 = @ptrCast(line_alloc);
    return line_with_null;
}
