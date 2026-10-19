//! tas-inject.exe: loads remielle-tas.dll (next to this exe) into the running game, the same way
//! remielle.exe loads thaumiel.dll (LoadLibraryA on a thread in the game process). Start the game
//! with remielle.exe as usual, then run this; it waits up to five minutes for the game to appear.
const std = @import("std");
const w = std.os.windows;

const exe_name = "ZenlessZoneZeroBeta.exe";
const dll_name = "remielle-tas.dll";
const wait_seconds = 300;

extern "kernel32" fn CreateToolhelp32Snapshot(u32, u32) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Process32FirstW(w.HANDLE, *ProcessEntry) callconv(.winapi) w.BOOL;
extern "kernel32" fn Process32NextW(w.HANDLE, *ProcessEntry) callconv(.winapi) w.BOOL;
extern "kernel32" fn Module32FirstW(w.HANDLE, *ModuleEntry) callconv(.winapi) w.BOOL;
extern "kernel32" fn Module32NextW(w.HANDLE, *ModuleEntry) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn VirtualAllocEx(w.HANDLE, ?*anyopaque, usize, u32, u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFreeEx(w.HANDLE, *anyopaque, usize, u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteProcessMemory(w.HANDLE, *anyopaque, [*]const u8, usize, ?*usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateRemoteThread(w.HANDLE, ?*anyopaque, usize, *anyopaque, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeThread(w.HANDLE, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetModuleFileNameA(?*anyopaque, [*]u8, u32) callconv(.winapi) u32;
extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetFileAttributesA([*:0]const u8) callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const ProcessEntry = extern struct {
    size: u32,
    usage: u32,
    process_id: u32,
    default_heap_id: usize,
    module_id: u32,
    threads: u32,
    parent_process_id: u32,
    priority: i32,
    flags: u32,
    exe_file: [260]u16,
};

const ModuleEntry = extern struct {
    size: u32,
    module_id: u32,
    process_id: u32,
    global_usage: u32,
    process_usage: u32,
    base: ?*u8,
    base_size: u32,
    module: ?*anyopaque,
    module_name: [256]u16,
    exe_path: [260]u16,
};

const TH32CS_SNAPPROCESS: u32 = 0x2;
const TH32CS_SNAPMODULE: u32 = 0x8;
const TH32CS_SNAPMODULE32: u32 = 0x10;
const PROCESS_ACCESS: u32 = 0x0002 | 0x0008 | 0x0010 | 0x0020 | 0x0400; // create thread, vm op/read/write, query info
const MEM_COMMIT_RESERVE: u32 = 0x1000 | 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

fn eqlWide(wide: []const u16, ascii: []const u8) bool {
    var n: usize = 0;
    while (n < wide.len and wide[n] != 0) n += 1;
    if (n != ascii.len) return false;
    for (ascii, 0..) |c, i| if (std.ascii.toLower(@intCast(wide[i] & 0x7F)) != std.ascii.toLower(c) or wide[i] > 0x7F) return false;
    return true;
}

fn findProcess() ?u32 {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == w.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(snapshot);
    var entry: ProcessEntry = undefined;
    entry.size = @sizeOf(ProcessEntry);
    if (Process32FirstW(snapshot, &entry) == .FALSE) return null;
    while (true) {
        if (eqlWide(&entry.exe_file, exe_name)) return entry.process_id;
        if (Process32NextW(snapshot, &entry) == .FALSE) return null;
    }
}

fn hasModule(pid: u32, name: []const u8) bool {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snapshot == w.INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(snapshot);
    var entry: ModuleEntry = undefined;
    entry.size = @sizeOf(ModuleEntry);
    if (Module32FirstW(snapshot, &entry) == .FALSE) return false;
    while (true) {
        if (eqlWide(&entry.module_name, name)) return true;
        if (Module32NextW(snapshot, &entry) == .FALSE) return false;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("tas-inject: " ++ fmt ++ "\n", args);
    return 1;
}

pub fn main() u8 {
    var exe_path: [1024]u8 = undefined;
    const exe_len = GetModuleFileNameA(null, &exe_path, exe_path.len);
    if (exe_len == 0 or exe_len >= exe_path.len) return fail("cannot read this program's path", .{});
    const dir_end = (std.mem.lastIndexOfScalar(u8, exe_path[0..exe_len], '\\') orelse return fail("odd program path", .{})) + 1;
    var dll_path: [1024]u8 = undefined;
    const dll = std.fmt.bufPrintZ(&dll_path, "{s}{s}", .{ exe_path[0..dir_end], dll_name }) catch return fail("path too long", .{});
    if (GetFileAttributesA(dll.ptr) == 0xFFFFFFFF) return fail("{s} not found next to tas-inject.exe", .{dll_name});

    std.debug.print("tas-inject: waiting for {s} (start the game with remielle.exe)...\n", .{exe_name});
    var pid: u32 = 0;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (findProcess()) |found| {
            pid = found;
            break;
        }
        if (waited >= wait_seconds) return fail("{s} did not start within {d} s", .{ exe_name, wait_seconds });
        Sleep(1000);
    }
    // Let the game map its modules first (thaumiel goes in at process start; this can wait).
    var tries: u32 = 0;
    while (!hasModule(pid, "GameAssembly.dll") and tries < wait_seconds) : (tries += 1) Sleep(1000);
    if (hasModule(pid, dll_name)) {
        std.debug.print("tas-inject: {s} is already loaded in process {d}\n", .{ dll_name, pid });
        return 0;
    }

    const process = OpenProcess(PROCESS_ACCESS, .FALSE, pid) orelse return fail("cannot open process {d} (error {d})", .{ pid, GetLastError() });
    defer _ = CloseHandle(process);
    const remote = VirtualAllocEx(process, null, dll.len + 1, MEM_COMMIT_RESERVE, PAGE_READWRITE) orelse return fail("VirtualAllocEx failed (error {d})", .{GetLastError()});
    defer _ = VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    if (WriteProcessMemory(process, remote, dll.ptr, dll.len + 1, null) == .FALSE) return fail("WriteProcessMemory failed (error {d})", .{GetLastError()});
    // kernel32 is mapped at the same address in every process of a session.
    const kernel32 = GetModuleHandleA("kernel32.dll") orelse return fail("no kernel32", .{});
    const load_library = GetProcAddress(kernel32, "LoadLibraryA") orelse return fail("no LoadLibraryA", .{});
    const thread = CreateRemoteThread(process, null, 0, load_library, remote, 0, null) orelse return fail("CreateRemoteThread failed (error {d})", .{GetLastError()});
    defer _ = CloseHandle(thread);
    _ = WaitForSingleObject(thread, 30_000);
    var module: u32 = 0;
    _ = GetExitCodeThread(thread, &module);
    if (module == 0) return fail("LoadLibraryA failed inside the game (check that {s} is a 64-bit build)", .{dll_name});
    std.debug.print("tas-inject: {s} loaded into process {d}; see TAS\\tas-dll.log in the game folder\n", .{ dll_name, pid });
    return 0;
}
