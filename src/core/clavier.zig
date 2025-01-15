const stdx = @import("../stdx/stdx.zig");
const std = @import("std");
const z = @import("../zimacs.zig");
const pen = z.pen;

pub const Clavier = struct {
    // Raylib KeyboardKeys map to 'ASCII' values
    const Modifiers = struct {
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        super: bool = false,
    };

    const Key = struct {
        modifiers: Modifiers,
        pressedKey: pen.KeyboardKey,
    };

    const Value = struct {
        out: u8,
    };

    var KeyMap: std.AutoHashMap(
        Key,
        Value,
    ) = std.AutoHashMap(
        Key,
        Value,
    ).init(z.gpa);
    // KeyMap.put(pen.KeyboardKey.a, "a");

    const Self = @This();

    const vTable = z.Artifact.VTable{
        .init = &init,
        .deinit = &deinit,
        .render = &render,
    };

    pub fn artifact(s: *Self) z.Artifact {
        return .{
            .name = "Clavier",
            .artifactType = "core",
            .version = "0.1",
            .ctx = @ptrCast(s),
            .vTable = &vTable,
        };
    }

    pub fn printKey(key: Key, val: Value) !void {
        z.print("CTRL:{} , SHIFT:{} , ALT:{} , SUPER:{} , KEY: {any} , VALUE : {any}\n", .{ key.modifiers.ctrl, key.modifiers.shift, key.modifiers.alt, key.modifiers.super, key.pressedKey, val.out });
    }

    pub fn handleKey(s: *Self, key: Key) !void {
        _ = s; // autofix
        const value = KeyMap.get(key);
        if (value) |v| {
            try printKey(key, v);
        }
    }

    pub fn init(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        _ = e; // autofix

        // Map a-z and A-Z
        for (@intFromEnum(pen.KeyboardKey.a)..@intFromEnum(pen.KeyboardKey.z), 65..90, 97..122) |key, upperChar, lowerChar| {
            try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = @as(pen.KeyboardKey, @enumFromInt(key)) }, Value{ .out = @as(u8, @intCast(upperChar)) });
            try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = @as(pen.KeyboardKey, @enumFromInt(key)) }, Value{ .out = @as(u8, @intCast(lowerChar)) });
        }

        // Map 0-9
        const keyBoardOneToNineShift = [10]u8{ ')', '!', '@', '#', '$', '%', '^', '&', '*', '(' };
        for (@intFromEnum(pen.KeyboardKey.zero)..@intFromEnum(pen.KeyboardKey.nine), 0..9) |key, digit| {
            try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = @as(pen.KeyboardKey, @enumFromInt(key)) }, Value{ .out = @as(u8, @intCast(digit)) });
            try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = @as(pen.KeyboardKey, @enumFromInt(key)) }, Value{ .out = keyBoardOneToNineShift[digit] });
        }

        //Custom
        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.space }, Value{ .out = ' ' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.space }, Value{ .out = ' ' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.backslash }, Value{ .out = '\\' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.backslash }, Value{ .out = '|' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.left_bracket }, Value{ .out = '[' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.left_bracket }, Value{ .out = '{' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.right_bracket }, Value{ .out = ']' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.right_bracket }, Value{ .out = '}' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.semicolon }, Value{ .out = ';' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.semicolon }, Value{ .out = ':' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.apostrophe }, Value{ .out = '\'' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.apostrophe }, Value{ .out = '"' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.comma }, Value{ .out = ',' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.comma }, Value{ .out = '<' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.period }, Value{ .out = '.' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.period }, Value{ .out = '>' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.slash }, Value{ .out = '/' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.slash }, Value{ .out = '?' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.minus }, Value{ .out = '-' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.minus }, Value{ .out = '_' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.equal }, Value{ .out = '=' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.equal }, Value{ .out = '+' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.grave }, Value{ .out = '`' });
        try KeyMap.put(Key{ .modifiers = Modifiers{ .shift = true }, .pressedKey = pen.KeyboardKey.grave }, Value{ .out = '~' });

        try KeyMap.put(Key{ .modifiers = Modifiers{}, .pressedKey = pen.KeyboardKey.space }, Value{ .out = ' ' });

        var KeyMapIt = KeyMap.keyIterator();
        while (KeyMapIt.next()) |k| {
            z.print("{any}\n", .{k});
        }
    }

    pub fn deinit(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        _ = e; // autofix
    }

    pub fn isKeyPressed(key: pen.KeyboardKey) bool {
        return pen.isKeyPressed(key) or pen.isKeyPressedRepeat(key) or pen.isKeyDown(key);
    }

    pub fn getKeyPressed(s: *Self) !?Key {
        _ = s;
        const isShift = isKeyPressed(pen.KeyboardKey.left_shift) or isKeyPressed(pen.KeyboardKey.right_shift);
        const isCtrl = isKeyPressed(pen.KeyboardKey.left_control) or isKeyPressed(pen.KeyboardKey.right_control);
        const isAlt = isKeyPressed(pen.KeyboardKey.left_alt) or isKeyPressed(pen.KeyboardKey.right_alt);
        const isSuper = isKeyPressed(pen.KeyboardKey.left_super) or isKeyPressed(pen.KeyboardKey.right_super);
        var KeyMapIt = KeyMap.keyIterator();
        while (KeyMapIt.next()) |k| {
            if (isKeyPressed(k.pressedKey)) {
                return Key{
                    .modifiers = Modifiers{
                        .ctrl = isCtrl,
                        .alt = isAlt,
                        .super = isSuper,
                        .shift = isShift,
                    },
                    .pressedKey = k.pressedKey,
                };
            }
        }
        return null;
    }

    pub fn getKeyPressedOld(s: *Self) ![]u8 {
        _ = s; // autofix
        var str = std.ArrayList(u8).init(z.gpa);
        defer str.deinit();
        const keyMap = [_]struct {
            key: pen.KeyboardKey,
            value: []const u8,
        }{
            .{ .key = pen.KeyboardKey.grave, .value = "`" },
            .{ .key = pen.KeyboardKey.apostrophe, .value = "'" },
            .{ .key = pen.KeyboardKey.space, .value = "<space>" },
            .{ .key = pen.KeyboardKey.escape, .value = "<esc>" },
            .{ .key = pen.KeyboardKey.enter, .value = "<enter>" },
            .{ .key = pen.KeyboardKey.left_shift, .value = "<shift>" },
            .{ .key = pen.KeyboardKey.right_shift, .value = "<shift>" },
            .{ .key = pen.KeyboardKey.tab, .value = "<tab>" },
            .{ .key = pen.KeyboardKey.backspace, .value = "<backspace>" },
            .{ .key = pen.KeyboardKey.insert, .value = "<insert>" },
            .{ .key = pen.KeyboardKey.delete, .value = "<delete>" },
            .{ .key = pen.KeyboardKey.right, .value = "<right>" },
            .{ .key = pen.KeyboardKey.left, .value = "<left>" },
            .{ .key = pen.KeyboardKey.down, .value = "<down>" },
            .{ .key = pen.KeyboardKey.up, .value = "<up>" },
            .{ .key = pen.KeyboardKey.page_up, .value = "<pageup>" },
            .{ .key = pen.KeyboardKey.page_down, .value = "<pagedown>" },
            .{ .key = pen.KeyboardKey.home, .value = "<home>" },
            .{ .key = pen.KeyboardKey.end, .value = "<end>" },
            .{ .key = pen.KeyboardKey.caps_lock, .value = "<capslock>" },
            .{ .key = pen.KeyboardKey.scroll_lock, .value = "<scrolllock>" },
            .{ .key = pen.KeyboardKey.num_lock, .value = "<numlock>" },
            .{ .key = pen.KeyboardKey.print_screen, .value = "<printscreen>" },
            .{ .key = pen.KeyboardKey.pause, .value = "<pause>" },
            .{ .key = pen.KeyboardKey.f1, .value = "<f1>" },
            .{ .key = pen.KeyboardKey.f2, .value = "<f2>" },
            .{ .key = pen.KeyboardKey.f3, .value = "<f3>" },
            .{ .key = pen.KeyboardKey.f4, .value = "<f4>" },
            .{ .key = pen.KeyboardKey.f5, .value = "<f5>" },
            .{ .key = pen.KeyboardKey.f6, .value = "<f6>" },
            .{ .key = pen.KeyboardKey.f7, .value = "<f7>" },
            .{ .key = pen.KeyboardKey.f8, .value = "<f8>" },
            .{ .key = pen.KeyboardKey.f9, .value = "<f9>" },
            .{ .key = pen.KeyboardKey.f10, .value = "<f10>" },
            .{ .key = pen.KeyboardKey.f11, .value = "<f11>" },
            .{ .key = pen.KeyboardKey.f12, .value = "<f12>" },
            .{ .key = pen.KeyboardKey.left_bracket, .value = "[" },
            .{ .key = pen.KeyboardKey.backslash, .value = "\\" },
            .{ .key = pen.KeyboardKey.right_bracket, .value = "]" },
            .{ .key = pen.KeyboardKey.kp_0, .value = "0" },
            .{ .key = pen.KeyboardKey.kp_1, .value = "1" },
            .{ .key = pen.KeyboardKey.kp_2, .value = "2" },
            .{ .key = pen.KeyboardKey.kp_3, .value = "3" },
            .{ .key = pen.KeyboardKey.kp_4, .value = "4" },
            .{ .key = pen.KeyboardKey.kp_5, .value = "5" },
            .{ .key = pen.KeyboardKey.kp_6, .value = "6" },
            .{ .key = pen.KeyboardKey.kp_7, .value = "7" },
            .{ .key = pen.KeyboardKey.kp_8, .value = "8" },
            .{ .key = pen.KeyboardKey.kp_9, .value = "9" },
            .{ .key = pen.KeyboardKey.kp_decimal, .value = "." },
            .{ .key = pen.KeyboardKey.kp_divide, .value = "/" },
            .{ .key = pen.KeyboardKey.kp_multiply, .value = "*" },
            .{ .key = pen.KeyboardKey.kp_subtract, .value = "-" },
            .{ .key = pen.KeyboardKey.kp_add, .value = "+" },
            .{ .key = pen.KeyboardKey.kp_enter, .value = "<enter>" },
            .{ .key = pen.KeyboardKey.kp_equal, .value = "=" },
            .{ .key = pen.KeyboardKey.comma, .value = "," },
            .{ .key = pen.KeyboardKey.minus, .value = "-" },
            .{ .key = pen.KeyboardKey.period, .value = "." },
            .{ .key = pen.KeyboardKey.slash, .value = "/" },
            .{ .key = pen.KeyboardKey.zero, .value = "0" },
            .{ .key = pen.KeyboardKey.one, .value = "1" },
            .{ .key = pen.KeyboardKey.two, .value = "2" },
            .{ .key = pen.KeyboardKey.three, .value = "3" },
            .{ .key = pen.KeyboardKey.four, .value = "4" },
            .{ .key = pen.KeyboardKey.five, .value = "5" },
            .{ .key = pen.KeyboardKey.six, .value = "6" },
            .{ .key = pen.KeyboardKey.seven, .value = "7" },
            .{ .key = pen.KeyboardKey.eight, .value = "8" },
            .{ .key = pen.KeyboardKey.nine, .value = "9" },
            .{ .key = pen.KeyboardKey.semicolon, .value = ";" },
            .{ .key = pen.KeyboardKey.equal, .value = "=" },
            .{ .key = pen.KeyboardKey.a, .value = "a" },
            .{ .key = pen.KeyboardKey.b, .value = "b" },
            .{ .key = pen.KeyboardKey.c, .value = "c" },
            .{ .key = pen.KeyboardKey.d, .value = "d" },
            .{ .key = pen.KeyboardKey.e, .value = "e" },
            .{ .key = pen.KeyboardKey.f, .value = "f" },
            .{ .key = pen.KeyboardKey.g, .value = "g" },
            .{ .key = pen.KeyboardKey.h, .value = "h" },
            .{ .key = pen.KeyboardKey.i, .value = "i" },
            .{ .key = pen.KeyboardKey.j, .value = "j" },
            .{ .key = pen.KeyboardKey.k, .value = "k" },
            .{ .key = pen.KeyboardKey.l, .value = "l" },
            .{ .key = pen.KeyboardKey.m, .value = "m" },
            .{ .key = pen.KeyboardKey.n, .value = "n" },
            .{ .key = pen.KeyboardKey.o, .value = "o" },
            .{ .key = pen.KeyboardKey.p, .value = "p" },
            .{ .key = pen.KeyboardKey.q, .value = "q" },
            .{ .key = pen.KeyboardKey.r, .value = "r" },
            .{ .key = pen.KeyboardKey.s, .value = "s" },
            .{ .key = pen.KeyboardKey.t, .value = "t" },
            .{ .key = pen.KeyboardKey.u, .value = "u" },
            .{ .key = pen.KeyboardKey.v, .value = "v" },
            .{ .key = pen.KeyboardKey.w, .value = "w" },
            .{ .key = pen.KeyboardKey.x, .value = "x" },
            .{ .key = pen.KeyboardKey.y, .value = "y" },
            .{ .key = pen.KeyboardKey.z, .value = "z" },
        };
        for (keyMap) |entry| {
            if (isKeyPressed(entry.key)) {
                try str.appendSlice(entry.value);
            }
        }
        return str.toOwnedSlice();
        // inline for (std.meta.fields(pen.KeyboardKey)) |key| {
        //     // std.debug.print("{}\n", .{key.value});
        //     // z.print("{any}", .{key});
        //     if (isKeyPressed(key)) {
        //         try str.append(@as(u8, key.value));
        //     }
        // }
        // for (@intFromEnum(pen.KeyboardKey.null)..@intFromEnum(pen.KeyboardKey.volume_down)) |k| {
        //     std.debug.print("-{any}", .{k});
        //     // const key: pen.KeyboardKey = @enumFromInt(k);
        //     // if (isKeyPressed(key)) {
        //     //     try str.append(@as(u8, @intCast(k)));
        //     // }
        // }
    }

    pub fn render(ctx: *anyopaque) z.ZiError!void {
        const e: *Self = @alignCast(@ptrCast(ctx));
        const key = try e.getKeyPressed();
        if (key) |k| try e.handleKey(k);
    }
};
