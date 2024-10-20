const zimacs = @import("../zimacs.zig");

pub const GfxType = enum { Raylib, SDL2 };

var CurrentType = GfxType.Raylib;

pub fn getGfxType() GfxType {
    return CurrentType;
}

pub fn changeType(newType: GfxType) void {
    CurrentType = newType;
}
