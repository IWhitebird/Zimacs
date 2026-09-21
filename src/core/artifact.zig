//! A component the app owns: something it sets up, draws each frame, and
//! tears down on exit.
//!
//! Each one hands over a pointer to itself plus a table of three functions,
//! so the main loop can hold them all in one list without knowing their types.

pub const Artifact = struct {
    ctx: *anyopaque,
    table: *const Table,
    name: []const u8,

    pub const Table = struct {
        init: *const fn (ctx: *anyopaque) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) anyerror!void,
        render: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn init(a: Artifact) !void {
        return a.table.init(a.ctx);
    }

    pub fn deinit(a: Artifact) !void {
        return a.table.deinit(a.ctx);
    }

    pub fn render(a: Artifact) !void {
        return a.table.render(a.ctx);
    }
};
