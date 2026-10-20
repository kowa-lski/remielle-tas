//! remielle-speed.dll: plays the game faster or slower. Every frame (MoleMole.GameEngine.Update, the
//! game's per-frame driver in every scene) it sets Unity's frame cap to the FPS target and each
//! frame's game time to speed / FPS (`Time.captureDeltaTime`), so at 60 FPS and speed 2 the game
//! renders 60 frames a second and moves 2/60 s per frame: twice as fast, as smooth as normal. A
//! hotkey switches to a second speed while held, or toggles it. If the computer can't reach the
//! FPS target, the game runs proportionally slower (each frame is still speed / FPS of game time).
//!
//! Settings are in `speed.txt` in the game folder, written by remielle-speed.exe and re-read
//! within half a second of changing. `TAS\speed-state.txt` says what is in effect, for the window.
//! While a remielle-tas recording or playback runs, the TAS owns the timing and this steps aside.
const std = @import("std");
const w = std.os.windows;
const il2cpp = @import("il2cpp.zig");
const detour = @import("detour.zig");
const nt = @import("nt.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.speed);

extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn ReadFile(w.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteFile(w.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetFileAttributesExA([*:0]const u8, u32, *FileData) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetAsyncKeyState(i32) callconv(.winapi) i16;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowThreadProcessId(?*anyopaque, ?*u32) callconv(.winapi) u32;

const FileData = extern struct { attributes: u32, created: u64 align(4), accessed: u64 align(4), written: u64 align(4), size_high: u32, size_low: u32 };

const settings_file = "speed.txt";
const state_file = "TAS\\speed-state.txt";

// --- settings ---------------------------------------------------------------------------------

pub const min_speed: f32 = 0.05;
pub const max_speed: f32 = 10;

pub const Settings = struct {
    enabled: bool = false,
    fps: u32 = 60,
    speed: f32 = 1,
    hotkey: u8 = 0,
    hotkey_speed: f32 = 2,
    /// false: the hotkey speed applies while the key is held; true: each press switches.
    toggle: bool = false,
};

fn onOff(value: []const u8) bool {
    for ([_][]const u8{ "on", "true", "yes", "1" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    return false;
}

fn speedValue(value: []const u8, fallback: f32) f32 {
    const v = std.fmt.parseFloat(f32, value) catch return fallback;
    return std.math.clamp(v, min_speed, max_speed);
}

/// `key = value` lines, `#` comments; anything unreadable keeps its default.
pub fn parse(text: []const u8) Settings {
    var result: Settings = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.ascii.eqlIgnoreCase(key, "enabled")) {
            result.enabled = onOff(value);
        } else if (std.ascii.eqlIgnoreCase(key, "fps")) {
            const fps = std.fmt.parseInt(u32, value, 10) catch 0;
            if (fps >= 10 and fps <= 1000) result.fps = fps;
        } else if (std.ascii.eqlIgnoreCase(key, "speed")) {
            result.speed = speedValue(value, result.speed);
        } else if (std.ascii.eqlIgnoreCase(key, "hotkey")) {
            result.hotkey = if (keys.find(value)) |k| k.vk else 0;
        } else if (std.ascii.eqlIgnoreCase(key, "hotkey_speed")) {
            result.hotkey_speed = speedValue(value, result.hotkey_speed);
        } else if (std.ascii.eqlIgnoreCase(key, "hotkey_mode")) {
            result.toggle = std.ascii.eqlIgnoreCase(value, "toggle");
        }
    }
    return result;
}

// --- Unity calls (made directly: these are static and take the value, then the MethodInfo) -------

const Setter = *const fn (i32, usize) callconv(.c) void;
const Getter = *const fn (usize) callconv(.c) i32;
const FloatSetter = *const fn (f32, usize) callconv(.c) void;

const Call = struct { code: usize = 0, info: usize = 0 };
var set_capture: Call = .{};
var get_fps: Call = .{};
var set_fps: Call = .{};
var get_vsync: Call = .{};
var set_vsync: Call = .{};

fn setFloat(c: Call, v: f32) void {
    @as(FloatSetter, @ptrFromInt(c.code))(v, c.info);
}

fn setInt(c: Call, v: i32) void {
    @as(Setter, @ptrFromInt(c.code))(v, c.info);
}

fn getInt(c: Call) i32 {
    return @as(Getter, @ptrFromInt(c.code))(c.info);
}

fn resolve(ns: []const u8, class: []const u8, name: []const u8, params: usize, rva: usize) !Call {
    const klass = try il2cpp.findClass(ns, class);
    return .{ .code = try il2cpp.findMethodAt(klass, name, params, rva), .info = try il2cpp.findMethodInfoAt(klass, name, params, rva) };
}

// --- per frame --------------------------------------------------------------------------------

var ready = false;
var settings: Settings = .{};
var settings_stamp: u64 = 0;
var frame: u64 = 0;

/// Our values are in effect (frame cap, vsync off, captured frame time).
var applied = false;
/// The frame cap and vsync from before we first applied, restored when switched off.
var saved: ?struct { fps: i32, vsync: i32 } = null;
var hotkey_on = false;
var hotkey_down = false;
var last_state: [128]u8 = undefined;
var last_state_len: usize = 0;

/// remielle-tas.dll's "a recording or playback is running", if that DLL is loaded.
var tas_active: ?*const fn () callconv(.c) bool = null;

fn tasSessionActive() bool {
    if (tas_active == null and frame % 60 == 1) {
        if (GetModuleHandleA("remielle-tas.dll")) |module| {
            if (GetProcAddress(module, "remielle_tas_session_active")) |f| tas_active = @ptrCast(f);
        }
    }
    return if (tas_active) |f| f() else false;
}

fn gameInFront() bool {
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

fn reloadIfChanged() void {
    var data: FileData = undefined;
    if (GetFileAttributesExA(settings_file, 0, &data) == .FALSE) {
        if (settings_stamp != 0) {
            settings_stamp = 0;
            settings = .{};
            log.info("{s} removed: off", .{settings_file});
        }
        return;
    }
    const stamp = data.written ^ (@as(u64, data.size_low) << 32);
    if (stamp == settings_stamp) return;
    settings_stamp = stamp;
    var buffer: [4096]u8 = undefined;
    const handle = CreateFileA(settings_file, 0x80000000, 3, null, 3, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(handle);
    var got: u32 = 0;
    if (ReadFile(handle, &buffer, buffer.len, &got, null) == .FALSE) return;
    const previous = settings;
    settings = parse(buffer[0..got]);
    if (settings.hotkey != previous.hotkey or settings.toggle != previous.toggle) hotkey_on = false;
    log.info("{s}: enabled {any}, fps {d}, speed {d}, hotkey 0x{X:0>2} -> speed {d} ({s})", .{ settings_file, settings.enabled, settings.fps, settings.speed, settings.hotkey, settings.hotkey_speed, if (settings.toggle) "toggle" else "hold" });
}

fn updateHotkey() void {
    if (settings.hotkey == 0) {
        hotkey_on = false;
        hotkey_down = false;
        return;
    }
    const down = gameInFront() and GetAsyncKeyState(settings.hotkey) < 0;
    if (settings.toggle) {
        if (down and !hotkey_down) hotkey_on = !hotkey_on;
    } else hotkey_on = down;
    hotkey_down = down;
}

/// `TAS\speed-state.txt`, rewritten only when the text changes.
fn writeState(comptime fmt: []const u8, args: anytype) void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    if (std.mem.eql(u8, text, last_state[0..last_state_len])) return;
    @memcpy(last_state[0..text.len], text);
    last_state_len = text.len;
    _ = CreateDirectoryA("TAS", null);
    const handle = CreateFileA(state_file, 0x40000000, 3, null, 2, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    _ = WriteFile(handle, text.ptr, @intCast(text.len), &written, null);
}

fn restore() void {
    setFloat(set_capture, 0);
    if (saved) |s| {
        setInt(set_fps, s.fps);
        setInt(set_vsync, s.vsync);
    }
    saved = null;
    applied = false;
    log.info("off: frame cap and vsync restored", .{});
}

fn step() void {
    frame += 1;
    if (frame % 30 == 1) reloadIfChanged();
    if (tasSessionActive()) {
        applied = false; // the TAS sets its own timing and restores ours when it ends
        writeState("paused: a TAS recording or playback is running", .{});
        return;
    }
    if (!settings.enabled) {
        if (applied) restore();
        writeState("off", .{});
        return;
    }
    updateHotkey();
    const speed = if (hotkey_on) settings.hotkey_speed else settings.speed;
    if (saved == null) saved = .{ .fps = getInt(get_fps), .vsync = getInt(get_vsync) };
    const fps: i32 = @intCast(settings.fps);
    setFloat(set_capture, speed / @as(f32, @floatFromInt(fps)));
    if (getInt(get_fps) != fps) setInt(set_fps, fps);
    if (getInt(get_vsync) != 0) setInt(set_vsync, 0);
    if (!applied) log.info("on: {d} fps target", .{fps});
    applied = true;
    writeState("x{d} at {d} fps{s}", .{ speed, fps, if (hotkey_on) " (hotkey)" else "" });
}

// --- install ----------------------------------------------------------------------------------

const engine_update_rva: usize = 0x151A5720;
/// push rbp/rsi/rdi/rbx; sub rsp,0x58; lea rbp,[rsp+0x50] -- position independent.
const engine_update_prologue = [_]u8{ 0x55, 0x56, 0x57, 0x53, 0x48, 0x83, 0xEC, 0x58, 0x48, 0x8D, 0x6C, 0x24, 0x50 };
var engine_update_original: u64 = 0;

const Hook6 = *const fn (u64, u64, u64, u64, u64, u64) callconv(.c) void;

fn engineUpdateHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    if (ready) step();
    @as(Hook6, @ptrFromInt(@as(usize, @intCast(engine_update_original))))(a0, a1, a2, a3, a4, a5);
}

fn install() !void {
    const base = try il2cpp.gameBase();
    try il2cpp.beginLookup();
    defer il2cpp.endLookup();
    set_capture = try resolve("UnityEngine", "Time", "set_captureDeltaTime", 1, 0x1FD6B3E0);
    get_fps = try resolve("UnityEngine", "Application", "get_targetFrameRate", 0, 0x1FD4D850);
    set_fps = try resolve("UnityEngine", "Application", "set_targetFrameRate", 1, 0x1FD4D860);
    get_vsync = try resolve("UnityEngine", "QualitySettings", "get_vSyncCount", 0, 0x1FE240A0);
    set_vsync = try resolve("UnityEngine", "QualitySettings", "set_vSyncCount", 1, 0x1FE240B0);
    const update = try il2cpp.findMethodAt(try il2cpp.findClass("MoleMole", "GameEngine"), "Update", 0, engine_update_rva);
    const spec: detour.Spec = .{ .prologue = &engine_update_prologue, .shape = .plain };
    if (!detour.matches(update, spec)) return error.PrologueMismatch;
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, update, spec, &engine_update_original, engineUpdateHook);
    log.info("hooked MoleMole.GameEngine.Update at RVA 0x{X}; settings from {s}", .{ update - base, settings_file });
}

/// Called once by speed_main.zig's worker thread when the il2cpp runtime is ready.
pub fn installFromWorker() void {
    install() catch |err| {
        log.err("speed control off: {t}", .{err});
        return;
    };
    ready = true;
    log.info("speed control ready", .{});
}

test "speed.txt parsing" {
    const s = parse(
        \\# comment
        \\enabled = on
        \\fps = 144
        \\speed = 2.5   # trailing
        \\hotkey = Mouse5
        \\hotkey_speed = 0.25
        \\hotkey_mode = toggle
    );
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(u32, 144), s.fps);
    try std.testing.expectEqual(@as(f32, 2.5), s.speed);
    try std.testing.expectEqual(@as(u8, 0x06), s.hotkey);
    try std.testing.expectEqual(@as(f32, 0.25), s.hotkey_speed);
    try std.testing.expect(s.toggle);
}

test "speed.txt defaults and limits" {
    const s = parse("fps = 5\nspeed = 100\nhotkey = nothing\nhotkey_speed = abc\n");
    try std.testing.expect(!s.enabled);
    try std.testing.expectEqual(@as(u32, 60), s.fps);
    try std.testing.expectEqual(max_speed, s.speed);
    try std.testing.expectEqual(@as(u8, 0), s.hotkey);
    try std.testing.expectEqual(@as(f32, 2), s.hotkey_speed);
    try std.testing.expect(!s.toggle);
}
