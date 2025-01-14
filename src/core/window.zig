const std = @import("std");
const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Window = struct {
    mainScreen: Screen = Screen{
        .title = "Zimacs",
        .width = 800,
        .height = 450,
    },

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

    pub fn getScreenInfo(s: *Self) Screen {
        return .{
            .title = s.mainScreen.title,
            .width = s.mainScreen.width,
            .height = s.mainScreen.height,
        };
    }

    pub fn init(ctx: *anyopaque) z.ZiError!void {
        const w: *Self = @alignCast(@ptrCast(ctx));
        z.print("Initializing Window\n", .{});
        pen.setConfigFlags(pen.ConfigFlags{
            .window_resizable = true,
            .window_highdpi = true,
        });
        pen.setTargetFPS(165);
        pen.initWindow(w.mainScreen.width, w.mainScreen.height, w.mainScreen.title);
    }

    pub fn render(ctx: *anyopaque) z.ZiError!void {
        const w: *Self = @alignCast(@ptrCast(ctx));

        // _ = z.gui.guiButton(z.pen.Rectangle{
        //     .x = 10.0,
        //     .y = 10.0,
        //     .width = 100.0,
        //     .height = 50.0,
        // }, "yo");

        if (pen.isFileDropped()) {
            const filePaths = pen.loadDroppedFiles();
            for (0..filePaths.count, filePaths.paths) |i, filePath| {
                _ = i; // autofix
                const as_slice: [:0]const u8 = std.mem.span(filePath);
                // z.print("{*}", .{ i, as_slice });
                try z.buffer.readFile(as_slice);
            }
        }

        if (pen.isWindowResized()) {
            var rwLock = std.Thread.RwLock{};
            rwLock.lock();
            const newWidth = pen.getRenderWidth();
            const newHeight = pen.getRenderHeight();
            w.mainScreen.width = newWidth;
            w.mainScreen.height = newHeight;
            z.print("new : {} , hw : {} , w : {} , h : {} , \n", .{ newWidth, newHeight, w.mainScreen.width, w.mainScreen.height });
            rwLock.unlock();
        }
    }

    pub fn deinit(ctx: *anyopaque) z.ZiError!void {
        _ = ctx; // autofix
        pen.closeWindow();
        z.print("Deiniting Window\n", .{});
    }
};
