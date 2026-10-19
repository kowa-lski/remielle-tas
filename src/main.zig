//! remielle-tas.dll: loaded into the running game by tas-inject.exe (next to thaumiel.dll, which it
//! leaves alone). A worker thread waits for the il2cpp runtime, then tas.zig resolves and verifies
//! everything it uses and installs its hooks. Log: TAS\tas-dll.log in the game folder.
const std = @import("std");
const w = std.os.windows;
const il2cpp = @import("il2cpp.zig");
const tas = @import("tas.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

const log = std.log.scoped(.main);

extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn WriteFile(w.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetLocalTime(*SystemTime) callconv(.winapi) void;
extern "kernel32" fn AcquireSRWLockExclusive(*usize) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*usize) callconv(.winapi) void;

const SystemTime = extern struct { year: u16, month: u16, day_of_week: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };

/// The runtime is normally up long before the injector runs; this only bounds a game that never
/// gets there (wrong client build).
const ready_timeout_ms: u64 = 600_000;

pub export fn DllMain(_: w.HINSTANCE, reason: w.DWORD, _: w.LPVOID) callconv(.winapi) w.BOOL {
    if (reason == 1) { // DLL_PROCESS_ATTACH: no il2cpp calls under the loader lock
        if (CreateThread(null, 0, worker, null, 0, null)) |handle| _ = CloseHandle(handle);
    }
    return .TRUE;
}

fn worker(_: ?*anyopaque) callconv(.winapi) u32 {
    log.info("remielle-tas loaded; waiting for the il2cpp runtime", .{});
    il2cpp.waitReady(ready_timeout_ms) catch |err| {
        log.err("TAS off: il2cpp runtime check failed ({t})", .{err});
        return 1;
    };
    tas.installFromWorker();
    return 0;
}

var log_lock: usize = 0;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var now: SystemTime = undefined;
    GetLocalTime(&now);
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}({s}): " ++ format ++ "\r\n", .{ now.hour, now.minute, now.second, now.ms, level.asText(), @tagName(scope) } ++ args) catch return;
    AcquireSRWLockExclusive(&log_lock);
    defer ReleaseSRWLockExclusive(&log_lock);
    _ = CreateDirectoryA("TAS", null);
    const handle = CreateFileA("TAS\\tas-dll.log", 0x4, 1, null, 4, 0x80, null); // FILE_APPEND_DATA, OPEN_ALWAYS
    if (handle == w.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    _ = WriteFile(handle, text.ptr, @intCast(text.len), &written, null);
}

test {
    _ = tas;
}
