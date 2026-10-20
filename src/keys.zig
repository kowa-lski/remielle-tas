//! Hotkey names shared by remielle-speed.dll (reads them from speed.txt) and remielle-speed.exe
//! (lists them): a name and its Windows virtual-key code.
const std = @import("std");

pub const Key = struct { name: []const u8, vk: u8 };

pub const keys = blk: {
    var list: [1 + 12 + 2 + 7 + 26]Key = undefined;
    var n: usize = 0;
    list[n] = .{ .name = "none", .vk = 0 };
    n += 1;
    for (1..13) |i| {
        list[n] = .{ .name = std.fmt.comptimePrint("F{d}", .{i}), .vk = 0x70 + i - 1 };
        n += 1;
    }
    for ([_]Key{
        .{ .name = "Mouse4", .vk = 0x05 },
        .{ .name = "Mouse5", .vk = 0x06 },
        .{ .name = "CapsLock", .vk = 0x14 },
        .{ .name = "Tab", .vk = 0x09 },
        .{ .name = "Shift", .vk = 0x10 },
        .{ .name = "Ctrl", .vk = 0x11 },
        .{ .name = "Alt", .vk = 0x12 },
        .{ .name = "Space", .vk = 0x20 },
        .{ .name = "Backquote", .vk = 0xC0 },
    }) |k| {
        list[n] = k;
        n += 1;
    }
    for ('A'..'Z' + 1) |c| {
        list[n] = .{ .name = &[_]u8{c}, .vk = c };
        n += 1;
    }
    break :blk list[0..n].*;
};

/// The key with this name (case-insensitive).
pub fn find(name: []const u8) ?Key {
    for (keys) |k| if (std.ascii.eqlIgnoreCase(k.name, name)) return k;
    return null;
}

pub fn index(name: []const u8) ?usize {
    for (keys, 0..) |k, i| if (std.ascii.eqlIgnoreCase(k.name, name)) return i;
    return null;
}

test "key names" {
    try std.testing.expectEqual(@as(u8, 0x74), find("f5").?.vk);
    try std.testing.expectEqual(@as(u8, 0x06), find("Mouse5").?.vk);
    try std.testing.expectEqual(@as(u8, 'Q'), find("q").?.vk);
    try std.testing.expectEqual(@as(u8, 0), find("none").?.vk);
    try std.testing.expect(find("F13") == null);
}
