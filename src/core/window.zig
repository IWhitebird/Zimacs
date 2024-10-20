const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Window = struct {
    mainScreen: Screen = Screen{ .title = "Zimacs", .width = 800, .height = 450 },

    const Self = @This();

    const vTable = z.Artifact.VTable{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(s: *Self) z.Artifact {
        return .{
            .name = "Window",
            .artifactType = "core",
            .version = "0.1",
            .ctx = @ptrCast(s),
            .vTable = &vTable,
        };
    }

    pub const Screen = struct {
        title: [*:0]const u8 = "Zimacs",
        width: i32 = 800,
        height: i32 = 450,
    };

    pub fn init(ctx: *anyopaque) z.ZiError!void {
        const w: *Self = @alignCast(@ptrCast(ctx));
        z.print("Initializing Window\n", .{});
        pen.initWindow(w.mainScreen.width, w.mainScreen.height, w.mainScreen.title);
    }

    pub fn render(ctx: *anyopaque) z.ZiError!void {
        const w: *Self = @alignCast(@ptrCast(ctx));
        if (pen.isWindowResized() or pen.isWindowMaximized()) {
            const newWidth = pen.getRenderWidth();
            const newHeight = pen.getRenderHeight();
            w.mainScreen.width = newWidth;
            w.mainScreen.height = newHeight;
            z.print("new : {} , hw : {} , w : {} , h : {} , \n", .{ newWidth, newHeight, w.mainScreen.width, w.mainScreen.height });
        }
    }

    pub fn deinit(ctx: *anyopaque) z.ZiError!void {
        _ = ctx; // autofix
        pen.closeWindow();
        z.print("Deiniting Window\n", .{});
    }
};
