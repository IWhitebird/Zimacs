const std = @import("std");
const stdx = @import("../stdx/stdx.zig");
const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Editor = struct {
    // bufferView: BufferView = BufferView{},
    postion: EditorPosition = EditorPosition{ .x = 10, .y = 10 },
    size: EditorSize = EditorSize{ .width = 10, .height = 10 },
    fontCache: std.StringHashMap(pen.Vector2) = std.StringHashMap(pen.Vector2).init(z.gpa),
    screenCache: std.StringHashMap(i32) = std.StringHashMap(i32).init(z.gpa),

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
        y: f32 = 50,
    };

    pub const EditorSize = struct {
        width: i32 = 100,
        height: i32 = 200,
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

        // const textXint = 24;
        // const textYint = 24;

        // var rwLock = std.Thread.RwLock{};
        // rwLock.lock();
        // const screenWidth = z.window.mainScreen.width;
        // const screenHeight = z.window.mainScreen.height;
        // rwLock.unlock();

        // const screenInfo = z.window.getScreenInfo();
        // const screenWidth = screenInfo.width;
        // const screenHeight = screenInfo.height;

        // const noOfRows: usize = @intCast(@divFloor(screenWidth, textXint));
        // const noOfColumns: usize = @intCast(@divFloor(screenHeight, textYint));

        // for (0..noOfRows) |i| {
        //     for (0..noOfColumns) |j| {
        //         const intI: i32 = @intCast(i);
        //         const intJ: i32 = @intCast(j);
        //         pen.drawRectangleLines(intI * textXint, intJ * textYint, textXint, textYint, pen.Color.red);
        //     }
        // }
        try e.renderLines();
        try e.buttomBar();
    }

    pub fn renderLines(e: *Self) z.ZiError!void {
        if (z.buffer.currentBufferView) |view| {
            const content = view.*.file.content;
            var splitter = std.mem.split(u8, content, "\n");
            var index: f32 = 18;
            while (splitter.next()) |line| {
                const cstr: [*:0]const u8 = try stdx.u8ToCstr(line, z.gpa);
                // const line_alloc = try std.fmt.allocPrint(z.gpa, "{s}", .{line});
                // const line_with_null: [*:0]const u8 = @ptrCast(line_alloc);
                // _ = line_with_null; // autofix
                pen.drawTextEx(z.settings.font, cstr, pen.Vector2{
                    .x = e.postion.x,
                    .y = e.postion.y + index,
                }, 18, 5, pen.Color.white);
                index += 18;
            }
        }
    }

    pub fn buttomBar(e: *Self) z.ZiError!void {
        _ = e; // autofix
        const screenInfo = z.window.getScreenInfo();

        const barHeight: i32 = 24;
        const barWidth: i32 = screenInfo.width;

        pen.drawRectangle(0, barWidth - barHeight, barHeight, barWidth, pen.Color.black);

        //File name on left
        if (z.buffer.currentBufferView) |buf| {
            const cstr = try stdx.u8ToCstr(buf.file.name, z.gpa);
            pen.drawTextEx(z.settings.font, cstr, pen.Vector2{
                .x = @floatFromInt(10),
                .y = @floatFromInt(screenInfo.height - barHeight),
            }, z.settings.fontSize, z.settings.spacing, pen.Color.white);
        }
        const cursorText = try std.fmt.allocPrint(z.gpa, "Ln: {d} Col: {d}", .{ 10, 10 });
        const cstr: [*:0]const u8 = try stdx.u8ToCstr(cursorText, z.gpa);
        pen.drawTextEx(z.settings.font, cstr, pen.Vector2{
            .x = @floatFromInt(screenInfo.width - 100),
            .y = @floatFromInt(screenInfo.height - barHeight),
        }, z.settings.fontSize, z.settings.spacing, pen.Color.white);

        //Cursor position on right
        // if (z.buffer.currentBufferView) |buf| {
        //     _ = buf; // autofix
        //     // const cursor = buf.cursor;
        // }
    }
};
