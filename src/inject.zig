//! tas-inject.exe: loads remielle-tas.dll (next to this exe) into the running game, the same way
//! remielle.exe loads thaumiel.dll (LoadLibraryA on a thread in the game process). Start the game
//! with remielle.exe as usual, then run this; it waits up to five minutes for the game to appear.
//! tas-gui.exe does the same from a window.
const std = @import("std");
const injector = @import("injector.zig");

const wait_seconds = 300;

extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("tas-inject: " ++ fmt ++ "\n", args);
    return 1;
}

pub fn main() u8 {
    var dll_buffer: [1024]u8 = undefined;
    const dll = injector.dllPath(&dll_buffer) orelse return fail("{s} not found next to tas-inject.exe", .{injector.dll_name});

    std.debug.print("tas-inject: waiting for {s} (start the game with remielle.exe)...\n", .{injector.exe_name});
    var pid: u32 = 0;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (injector.findProcess()) |found| {
            pid = found;
            break;
        }
        if (waited >= wait_seconds) return fail("{s} did not start within {d} s", .{ injector.exe_name, wait_seconds });
        Sleep(1000);
    }
    // Let the game map its modules first (thaumiel goes in at process start; this can wait).
    var tries: u32 = 0;
    while (!injector.hasModule(pid, "GameAssembly.dll") and tries < wait_seconds) : (tries += 1) Sleep(1000);
    if (injector.hasModule(pid, injector.dll_name)) {
        std.debug.print("tas-inject: {s} is already loaded in process {d}\n", .{ injector.dll_name, pid });
        return 0;
    }
    injector.inject(pid, dll) catch |err| {
        if (err == error.LoadLibraryFailed) return fail("LoadLibraryA failed inside the game (check that {s} is a 64-bit build)", .{injector.dll_name});
        return fail("{t} failed (error {d})", .{ err, injector.last_error });
    };
    std.debug.print("tas-inject: {s} loaded into process {d}; see TAS\\tas-dll.log in the game folder\n", .{ injector.dll_name, pid });
    return 0;
}
