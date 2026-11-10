//! `file = auto` in tas.txt: record names each battle's recording itself (TAS\battle-<date>-<time>),
//! play uses the newest recording in TAS\ (by last write time; a recording is written when its
//! battle ends). Shared by the DLL, which resolves it at battle start, and tas-gui, which shows it.
const std = @import("std");

pub const auto = "auto";
pub const extension = ".inputtrace";

pub fn isAuto(file: []const u8) bool {
    return file.len == 0 or std.ascii.eqlIgnoreCase(file, auto);
}

const FILETIME = extern struct { low: u32, high: u32 };
const WIN32_FIND_DATAA = extern struct {
    attributes: u32,
    created: FILETIME,
    accessed: FILETIME,
    written: FILETIME,
    size_high: u32,
    size_low: u32,
    reserved0: u32,
    reserved1: u32,
    name: [260]u8,
    alternate: [14]u8,
};
extern "kernel32" fn FindFirstFileA([*:0]const u8, *WIN32_FIND_DATAA) callconv(.winapi) isize;
extern "kernel32" fn FindNextFileA(isize, *WIN32_FIND_DATAA) callconv(.winapi) i32;
extern "kernel32" fn FindClose(isize) callconv(.winapi) i32;

/// `TAS\<newest>.inputtrace` (relative to the game folder) in `out`, or null if TAS\ has none.
/// `base` is the game folder with a trailing backslash, or "" for the current directory.
pub fn newest(base: []const u8, out: []u8) ?[]const u8 {
    var pattern: [1200]u8 = undefined;
    const z = std.fmt.bufPrintZ(&pattern, "{s}TAS\\*{s}", .{ base, extension }) catch return null;
    var data: WIN32_FIND_DATAA = undefined;
    const handle = FindFirstFileA(z.ptr, &data);
    if (handle == -1) return null;
    defer _ = FindClose(handle);
    var best_time: u64 = 0;
    var best: ?[]const u8 = null;
    while (true) {
        const name = std.mem.sliceTo(&data.name, 0);
        const time = @as(u64, data.written.high) << 32 | data.written.low;
        const is_file = data.attributes & 0x10 == 0; // not FILE_ATTRIBUTE_DIRECTORY
        if (is_file and isRecordingName(name) and (best == null or time > best_time)) {
            best_time = time;
            best = std.fmt.bufPrint(out, "TAS\\{s}", .{name}) catch null;
        }
        if (FindNextFileA(handle, &data) == 0) break;
    }
    return best;
}

/// `x.inputtrace`, not `x.inputtrace.info.txt` / `.clock` (FindFirstFile patterns are loose).
fn isRecordingName(name: []const u8) bool {
    return name.len > extension.len and std.ascii.endsWithIgnoreCase(name, extension);
}

test "auto and recording names" {
    try std.testing.expect(isAuto(""));
    try std.testing.expect(isAuto("AUTO"));
    try std.testing.expect(!isAuto("TAS\\run.inputtrace"));
    try std.testing.expect(isRecordingName("battle-20261110-210000.inputtrace"));
    try std.testing.expect(!isRecordingName("battle.inputtrace.info.txt"));
    try std.testing.expect(!isRecordingName(".inputtrace"));
}
