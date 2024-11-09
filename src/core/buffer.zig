const stdx = @import("../stdx/stdx.zig");
const std = @import("std");
const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Buffer = struct {
    //Caching
    currentBufferView: ?*BufferView = null,
    fontCache: std.StringHashMap(pen.Vector2) = std.StringHashMap(pen.Vector2).init(z.gpa),
    bufferViewMap: std.StringHashMap(*BufferView) = std.StringHashMap(*BufferView).init(z.gpa),

    const Self = @This();

    // const BufferErrors = error{
    //     MemoryError,
    // };

    const File = struct {
        content: []u8,
        name: []u8,
        type: []u8,
        path: []u8,
    };

    const BufferLine = struct {
        index: i32,
        length: i32,
        startIndex: i32,
        endIndex: i32,
        actualLineIndex: i32,
    };

    pub const BufferView = struct {
        bufferLines: std.MultiArrayList(BufferLine),
        file: File,
    };
    // maxLine: i32,
    // maxColumn: i32,
    // zeroLocation: pen.Vector2,
    // textZeroLocation: pen.Vector2,

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
        _ = ctx; // autofix
    }

    // pub fn calculateBuffer(b: *Self) !void {
    //     if (b.currentBufferView == null) {
    //         return;
    //     }
    //     const bufferView = b.bufferViewMap.get(b.currentBufferView.?).?;
    //     _ = bufferView; // autofix

    // }

    // pub fn initFile(b: *Self, buffer: []u8) anyerror!*File {
    //     _ = b; // autofix
    //     const file = try z.gpa.create(File);
    //     file.* = .{
    //         .content = buffer,
    //     };
    //     return file;
    // }

    pub fn initBufferView(b: *Self, buffer: []u8) !*BufferView {
        _ = b; // autofix
        const bufferView = try z.gpa.create(BufferView);
        bufferView.* = .{
            .file = .{
                .content = buffer,
            },
            .bufferLines = std.MultiArrayList(BufferLine){},
        };
        return bufferView;
    }

    pub fn readFile(b: *Self, path: [:0]const u8) z.ZiError!void {
        if (b.bufferViewMap.contains(path) or true == true) {
            b.currentBufferView = b.bufferViewMap.get(path).?;
            return;
        }

        // REPLACE CRLF / CR WITH LF
        // if bytes.Index(content, []byte("\r\n")) != -1 {
        // 	content = bytes.Replace(content, []byte("\r"), []byte(""), -1)
        // 	buf.CRLF = true
        // }

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const buffer: []u8 = try file.readToEndAlloc(z.gpa, 1024 * 1024);

        //loop the fokin byte and remove \r cause windows shit

        var parsedBuffer = std.ArrayList(u8).init(z.gpa);

        for (buffer) |byte| {
            switch (byte) {
                '\r' => {},
                else => {
                    try parsedBuffer.append(byte);
                },
            }
        }

        for (parsedBuffer) |buf| {
            if (buf == '\n') {
                std.debug.print("byte => \\n\n", .{});
            } else if (buf == '\r') {
                std.debug.print("byte => \\r\n", .{});
            } else if (buf == ' ') {
                std.debug.print("byte => space\n", .{});
            } else {
                std.debug.print("byte => {c}\n", .{buf});
            }
        }

        // const newBufferView = try stdx.createInit(z.gpa, BufferView, .{
        //     .file = .{
        //         .content = buffer,
        //     },
        //     .bufferLines = std.MultiArrayList(BufferLine).init(z.gpa),
        // });

        const newBufferView = try b.initBufferView(buffer);
        try b.bufferViewMap.put(path, newBufferView);
        b.currentBufferView = newBufferView;

        // Bytes to string
        // var iter = std.mem.split(u8, b.currentBufferView.?.file.content, "\n");
        // while (iter.next()) |line| {
        //     std.log.info("{s}", .{line});
        // }

        return;
    }
};
