//! Loading a DLL into the running game, shared by tas-inject.exe, tas-gui.exe and
//! remielle-speed.exe: the same way remielle.exe loads thaumiel.dll (LoadLibraryA on a thread in
//! the game process).
const std = @import("std");
const w = std.os.windows;

pub const exe_name = "ZenlessZoneZeroBeta.exe";
pub const dll_name = "remielle-tas.dll";
pub const speed_dll_name = "remielle-speed.dll";

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

/// The game's process id, if it is running.
pub fn findProcess() ?u32 {
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

pub fn hasModule(pid: u32, name: []const u8) bool {
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

/// The folder this program is in, with a trailing backslash.
pub fn programDir(buffer: []u8) ?[]const u8 {
    const len = GetModuleFileNameA(null, buffer.ptr, @intCast(buffer.len));
    if (len == 0 or len >= buffer.len) return null;
    const end = (std.mem.lastIndexOfScalar(u8, buffer[0..len], '\\') orelse return null) + 1;
    return buffer[0..end];
}

/// `<program folder>\<name>`, or null if it is not there.
pub fn dllPath(buffer: []u8, name: []const u8) ?[:0]const u8 {
    var dir_buffer: [1024]u8 = undefined;
    const dir = programDir(&dir_buffer) orelse return null;
    const path = std.fmt.bufPrintZ(buffer, "{s}{s}", .{ dir, name }) catch return null;
    if (GetFileAttributesA(path.ptr) == 0xFFFFFFFF) return null;
    return path;
}

pub const Error = error{ OpenProcess, RemoteAlloc, RemoteWrite, RemoteThread, LoadLibraryFailed, NoKernel32 };

/// Windows error code of the last failure, for messages.
pub var last_error: u32 = 0;

/// LoadLibraryA(dll) on a new thread in process `pid`; waits up to 30 s for it.
pub fn inject(pid: u32, dll: [:0]const u8) Error!void {
    const process = OpenProcess(PROCESS_ACCESS, .FALSE, pid) orelse {
        last_error = GetLastError();
        return error.OpenProcess;
    };
    defer _ = CloseHandle(process);
    const remote = VirtualAllocEx(process, null, dll.len + 1, MEM_COMMIT_RESERVE, PAGE_READWRITE) orelse {
        last_error = GetLastError();
        return error.RemoteAlloc;
    };
    defer _ = VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    if (WriteProcessMemory(process, remote, dll.ptr, dll.len + 1, null) == .FALSE) {
        last_error = GetLastError();
        return error.RemoteWrite;
    }
    // kernel32 is mapped at the same address in every process of a session.
    const kernel32 = GetModuleHandleA("kernel32.dll") orelse return error.NoKernel32;
    const load_library = GetProcAddress(kernel32, "LoadLibraryA") orelse return error.NoKernel32;
    const thread = CreateRemoteThread(process, null, 0, load_library, remote, 0, null) orelse {
        last_error = GetLastError();
        return error.RemoteThread;
    };
    defer _ = CloseHandle(thread);
    _ = WaitForSingleObject(thread, 30_000);
    var module: u32 = 0;
    _ = GetExitCodeThread(thread, &module);
    if (module == 0) return error.LoadLibraryFailed;
}
