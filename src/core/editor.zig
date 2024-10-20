const std = @import("std");
const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Editor = struct {
    // bufferView: BufferView = BufferView{},
    postion: EditorPosition = EditorPosition{ .x = 10, .y = 10 },
    size: EditorSize = EditorSize{ .width = 10, .height = 10 },
    fontCache: std.StringHashMap(pen.Vector2) = std.StringHashMap(pen.Vector2).init(std.heap.page_allocator),

    const Self = @This();

    const vTable = z.Artifact.VTable{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(s: *Self) z.Artifact {
        return .{
            .name = "Editor",
            .artifactType = "core",
            .version = "0.1",
            .ctx = @ptrCast(s),
            .vTable = &vTable,
        };
    }

    pub const EditorPosition = struct {
        x: f32 = 10,
        y: f32 = 10,
    };
    pub const EditorSize = struct {
        width: i32 = 100,
        height: i32 = 200,
    };

    const Buffer = struct {
        File: [*:0]const u8 = "Untitled",
        content: [*:0]const u8 = "This is just a test string buffer i want to print on the screen",
    };

    // const BufferLine = struct {
    //     index: i32,
    //     startIndex: i32,
    //     endIndex: i32,
    //     actualLine: i32,
    //     length: i32,
    // };

    // const BufferView = struct {
    //     buffer: Buffer,
    //     maxLine: i32,
    //     maxColumn: i32,
    //     zeroLocation: pen.Vector2,
    //     textZeroLocation: pen.Vector2,
    //     bufferLines: []BufferLine,
    // };

    // const BufferGrid = struct {
    //     bufferView: BufferView,
    //     buffer: Buffer,
    //     bufferLines: []BufferLine,
    // };

    pub fn init(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        _ = e; // autofix
        // pen.drawRectangle(e.postion.x, e.postion.y, e.size.width, e.size.height, pen.Color.red);
        // e.postion.x += 1;
        // e.postion.y += 1;
        // if (e.postion.x > z.window.mainScreen.width) {
        //     e.postion.x = 10;
        // }
        // if (e.postion.y > z.window.mainScreen.height) {
        //     e.postion.y = 10;
        // }

        //Write on the screen
        // try e.renderBuffer();

        // pen.drawTextEx(z.settings.font, "yo", pen.Vector2{
        //     .x = e.postion.x,
        //     .y = e.postion.y,
        // }, 18, 0, pen.Color.white);
    }

    pub fn deinit(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        e.fontCache.deinit();
        z.print("Deiniting\n", .{});
    }

    pub fn textSize(e: *Self) z.ZiError!pen.Vector2 {
        _ = e; // autofix
        // if (e.fontCache.contains("default")) {
        //     return e.fontCache.get("default").?;
        // }
        const fontSize: i32 = 18;
        const charSize = pen.measureTextEx(z.settings.font, "default", fontSize, 0);
        // try e.fontCache.put("default", charSize);
        return charSize;
    }

    pub fn render(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        _ = e; // autofix
        const textXint = 18;
        const textYint = 18;

        const screenWidth = z.window.mainScreen.width;
        const screenHeight = z.window.mainScreen.height;

        const noOfRows: usize = @intCast(@divFloor(screenWidth, textXint));
        const noOfColumns: usize = @intCast(@divFloor(screenHeight, textYint));

        for (0..noOfRows) |i| {
            for (0..noOfColumns) |j| {
                const intI: i32 = @intCast(i);
                const intJ: i32 = @intCast(j);
                // z.print("x : {} , y : {} , w : {} , h : {} \n", .{ intI * 18, intJ * 18, 18, 18 });
                pen.drawRectangleLines(intI * textXint, intJ * textYint, textXint, textYint, pen.Color.red);
            }
        }
    }
};
