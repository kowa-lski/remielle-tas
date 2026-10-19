//! TAS input recording and playback for the Remielle ZZZ client (remielle-tas).
//!
//! Records every input event of a battle with the Input System's own `InputEventTrace` (frame
//! markers on, so every event keeps the frame it arrived in) and plays a recording back one
//! recorded frame per game frame (`InputEventTrace.ReplayController.PlayAllFramesOneByOne`).
//! Around both, the battle runs on a fixed timestep (`Time.captureDeltaTime = 1/fps`): every
//! frame is the same amount of game time whatever the real frame rate, so a battle recorded slowly
//! (`speed = 0.25`) plays back at full speed with every input on the same game frame. Unity's
//! shared random generator can be seeded at the same moment (`Random.InitState`).
//!
//! Driven by `tas.txt` in the game folder, re-read at every battle start (see `parseConfig`):
//!
//!   mode    = off | record | play
//!   file    = TAS\run.inputtrace    record: optional (default TAS\battle-<date>-<time>.inputtrace);
//!                                   an existing file is never overwritten (-2, -3, ... is added)
//!   fps     = 60                    game frames per second of game time (play: the recording's)
//!   speed   = 0.25                  real-time speed: target frame rate = fps * speed; 0 = unlimited
//!   seed    = 12345                 Random.InitState at battle start; play: overrides the recording's
//!   devices = same | new            play: replay into the recorded devices, or into new virtual ones
//!
//! A recording is the Input System's own trace file plus `<file>.info.txt` (fps, seed, frames,
//! events). Every run appends one line to `TAS\tas-log.txt`.
//!
//! A session starts at the first MoleMole.BattleStatsSubsystem::OnUpdate of a battle (each later
//! call is the per-frame step) and ends at the AI subsystem's OnDestroy (see "battle lifecycle"),
//! on the game thread; thaumiel keeps its own hooks on OnAwake / OnDestroy. Every managed call goes through `il2cpp_runtime_invoke` (API slot 138), which hands
//! back managed exceptions instead of unwinding through this DLL; objects and strings come from
//! `il2cpp_object_new` (128) and `il2cpp_string_new` (145). The three slots and every method are
//! pinned to CNBetaWin3.3.4 (RVA and, for the slots, code bytes) and checked at install; any
//! mismatch leaves the TAS off and the game untouched.

const std = @import("std");
const w = std.os.windows;

const il2cpp = @import("il2cpp.zig");

const SystemTime = extern struct { year: u16, month: u16, day_of_week: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };

const log = std.log.scoped(.tas);

/// Config warnings; quiet under `zig build test`, whose runner fails a test that logs.
fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) log.warn(fmt, args);
}

extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn ReadFile(w.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteFile(w.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetFileAttributesA([*:0]const u8) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetLocalTime(*SystemTime) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn SwitchToThread() callconv(.winapi) w.BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn RtlCaptureStackBackTrace(u32, u32, [*]usize, ?*u32) callconv(.winapi) u16;
extern "user32" fn GetAsyncKeyState(i32) callconv(.winapi) i16;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowThreadProcessId(?*anyopaque, ?*u32) callconv(.winapi) u32;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_APPEND_DATA: u32 = 0x4;
const OPEN_EXISTING: u32 = 3;
const OPEN_ALWAYS: u32 = 4;
const CREATE_ALWAYS: u32 = 2;
const INVALID_ATTRIBUTES: u32 = 0xFFFFFFFF;

const config_file = "tas.txt";
const tas_dir = "TAS";
const user_log = tas_dir ++ "\\tas-log.txt";

// --- pins (CNBetaWin3.3.4, from an il2cpp metadata dump) -------------------------------

const Slot = struct { index: usize, rva: usize, code: []const u8 };
/// `il2cpp_object_new`: `try { return Object::New(klass); } catch { return null; }`.
const slot_object_new = Slot{ .index = 128, .rva = 0x927A20, .code = &.{ 0x55, 0x48, 0x83, 0xEC, 0x30, 0x48, 0x8D, 0x6C, 0x24, 0x30, 0x48, 0xC7, 0x45, 0xF8, 0xFE, 0xFF } };
/// `il2cpp_runtime_invoke` (docs/client-update-playbook.md).
const slot_runtime_invoke = Slot{ .index = 138, .rva = 0x927B30, .code = &.{ 0x55, 0x41, 0x56, 0x56, 0x57, 0x53, 0x48, 0x83, 0xEC, 0x40, 0x48, 0x8D, 0x6C, 0x24, 0x40, 0x48 } };
/// `il2cpp_string_new` (UTF-8 in): after string_length (143, `mov eax,[rcx+0x10]`) and
/// string_chars (144, `lea rax,[rcx+0x14]`); 148 (string_new_wrapper) is the same code.
const slot_string_new = Slot{ .index = 145, .rva = 0x927CE0, .code = &.{ 0x56, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x89, 0xCE, 0xE8 } };

const Pin = struct { ns: []const u8, class: []const u8, name: []const u8, params: usize, rva: usize };
const trace_ns = "UnityEngine.InputSystem.LowLevel";

const M = enum {
    trace_ctor,
    trace_file_format,
    trace_set_markers,
    trace_enable,
    trace_disable,
    trace_event_count,
    trace_write,
    trace_load,
    trace_replay,
    trace_dispose,
    replay_new_devices,
    replay_frames,
    replay_finished,
    replay_position,
    replay_dispose,
    time_capture,
    time_frame,
    app_get_fps,
    app_set_fps,
    vsync_get,
    vsync_set,
    random_init,
    random_state,
    object_name,
    time_unscaled,
    time_fixed_unscaled,
    time_fixed_dt,
    input_settings,
    settings_update_mode,
    input_reset_device,
    keyboard_current,
    mouse_current,
    gamepad_current,
    handle_new,
    handle_free,
};

const pin_table = std.enums.EnumArray(M, Pin).init(.{
    // ctor(Int64 bufferSizeInBytes, Boolean growBuffer, Int64 maxBufferSizeInBytes, Int64 growIncrementSizeInBytes)
    .trace_ctor = .{ .ns = trace_ns, .class = "InputEventTrace", .name = ".ctor", .params = 4, .rva = 0x1F5AA7C0 },
    // static; called once so runtime_invoke runs the class constructor before object_new + ctor
    .trace_file_format = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "get_kFileFormat", .params = 0, .rva = 0x1F5AB130 },
    .trace_set_markers = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "set_recordFrameMarkers", .params = 1, .rva = 0x1F5AA4E0 },
    .trace_enable = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "Enable", .params = 0, .rva = 0x1F5AC170 },
    .trace_disable = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "Disable", .params = 0, .rva = 0x1F5ABD20 },
    .trace_event_count = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "get_eventCount", .params = 0, .rva = 0x1F5AA5A0 },
    .trace_write = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "WriteTo", .params = 1, .rva = 0x1F5AA810 }, // (String)
    .trace_load = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "LoadFrom", .params = 1, .rva = 0x1F5ABA20 }, // static (String)
    .trace_replay = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "Replay", .params = 0, .rva = 0x1F5ABC80 },
    .trace_dispose = .{ .ns = trace_ns, .class = "InputEventTrace", .name = "Dispose", .params = 0, .rva = 0x1F5AC310 },
    // InputEventTrace.ReplayController (nested: empty namespace in the metadata; unique by name)
    .replay_new_devices = .{ .ns = "", .class = "ReplayController", .name = "WithAllDevicesMappedToNewInstances", .params = 0, .rva = 0x1F5AD150 },
    .replay_frames = .{ .ns = "", .class = "ReplayController", .name = "PlayAllFramesOneByOne", .params = 0, .rva = 0x1F5AD8A0 },
    .replay_finished = .{ .ns = "", .class = "ReplayController", .name = "get_finished", .params = 0, .rva = 0x1F5ACB40 },
    .replay_position = .{ .ns = "", .class = "ReplayController", .name = "get_position", .params = 0, .rva = 0x1F5ACB80 },
    .replay_dispose = .{ .ns = "", .class = "ReplayController", .name = "Dispose", .params = 0, .rva = 0x1F5ACBF0 },
    .time_capture = .{ .ns = "UnityEngine", .class = "Time", .name = "set_captureDeltaTime", .params = 1, .rva = 0x1FD6B3E0 },
    .time_frame = .{ .ns = "UnityEngine", .class = "Time", .name = "get_frameCount", .params = 0, .rva = 0x1FD6B3B0 },
    .app_get_fps = .{ .ns = "UnityEngine", .class = "Application", .name = "get_targetFrameRate", .params = 0, .rva = 0x1FD4D850 },
    .app_set_fps = .{ .ns = "UnityEngine", .class = "Application", .name = "set_targetFrameRate", .params = 1, .rva = 0x1FD4D860 },
    .vsync_get = .{ .ns = "UnityEngine", .class = "QualitySettings", .name = "get_vSyncCount", .params = 0, .rva = 0x1FE240A0 },
    .vsync_set = .{ .ns = "UnityEngine", .class = "QualitySettings", .name = "set_vSyncCount", .params = 1, .rva = 0x1FE240B0 },
    .random_init = .{ .ns = "UnityEngine", .class = "Random", .name = "InitState", .params = 1, .rva = 0x1FDFADC0 },
    // returns UnityEngine.Random.State (four Int32: s0..s3), boxed by runtime_invoke
    .random_state = .{ .ns = "UnityEngine", .class = "Random", .name = "get_state", .params = 0, .rva = 0x1FDFADD0 },
    // tas-trees.tsv: the GameObject a tree belongs to
    .object_name = .{ .ns = "UnityEngine", .class = "Object", .name = "get_name", .params = 0, .rva = 0x1FDBC1F0 },
    // input clock: the fixed-update clock's base, and what the session start line reports
    .time_unscaled = .{ .ns = "UnityEngine", .class = "Time", .name = "get_unscaledTime", .params = 0, .rva = 0x1FD6B2D0 },
    .time_fixed_unscaled = .{ .ns = "UnityEngine", .class = "Time", .name = "get_fixedUnscaledTime", .params = 0, .rva = 0x1FD6B2F0 },
    .time_fixed_dt = .{ .ns = "UnityEngine", .class = "Time", .name = "get_fixedDeltaTime", .params = 0, .rva = 0x1FD6B330 },
    .input_settings = .{ .ns = "UnityEngine.InputSystem", .class = "InputSystem", .name = "get_settings", .params = 0, .rva = 0x1F6B8600 },
    .settings_update_mode = .{ .ns = "UnityEngine.InputSystem", .class = "InputSettings", .name = "get_updateMode", .params = 0, .rva = 0x1F67D620 },
    // stop hotkey: release whatever the replay left pressed on the real devices
    .input_reset_device = .{ .ns = "UnityEngine.InputSystem", .class = "InputSystem", .name = "ResetDevice", .params = 2, .rva = 0x1F6B6CF0 },
    .keyboard_current = .{ .ns = "UnityEngine.InputSystem", .class = "Keyboard", .name = "get_current", .params = 0, .rva = 0x1F6A2AF0 },
    .mouse_current = .{ .ns = "UnityEngine.InputSystem", .class = "Mouse", .name = "get_current", .params = 0, .rva = 0x1F651550 },
    .gamepad_current = .{ .ns = "UnityEngine.InputSystem", .class = "Gamepad", .name = "get_current", .params = 0, .rva = 0x1F65B1C0 },
    // static GetTargetHandle(Object, Int32 handle = 0 -> new, GCHandleType) / FreeHandle(Int32)
    .handle_new = .{ .ns = "System.Runtime.InteropServices", .class = "GCHandle", .name = "GetTargetHandle", .params = 3, .rva = 0x1CBA6DB0 },
    .handle_free = .{ .ns = "System.Runtime.InteropServices", .class = "GCHandle", .name = "FreeHandle", .params = 1, .rva = 0x1CBA6FF0 },
});

/// System.Exception._message and System.String's length / first char (checked at install).
const exception_message_offset: usize = 0x18;
const string_length_offset: usize = 0x10;
const string_chars_offset: usize = 0x14;
const gc_handle_normal: i32 = 2;

// --- resolved at install (install worker) ---------------------------------------------------

var ready = false;
var methods = std.enums.EnumArray(M, usize).initFill(0);
var trace_class: usize = 0;
var object_new: *const fn (usize) callconv(.c) usize = undefined;
var string_new: *const fn ([*:0]const u8) callconv(.c) usize = undefined;
var runtime_invoke: *const fn (usize, usize, ?[*]const usize, *usize) callconv(.c) usize = undefined;

fn checkedSlot(base: usize, slot: Slot) !usize {
    const address = try il2cpp.apiSlot(slot.index);
    if (address != base + slot.rva) {
        log.err("API slot {d} at RVA 0x{X}, expected 0x{X}", .{ slot.index, address -% base, slot.rva });
        return error.SlotMismatch;
    }
    const code: [*]const u8 = @ptrFromInt(address);
    if (!std.mem.eql(u8, code[0..slot.code.len], slot.code)) {
        log.err("API slot {d} code {x} does not match the pin", .{ slot.index, code[0..slot.code.len] });
        return error.SlotCodeMismatch;
    }
    return address;
}

fn install() !void {
    const base = try il2cpp.gameBase();
    object_new = @ptrFromInt(try checkedSlot(base, slot_object_new));
    runtime_invoke = @ptrFromInt(try checkedSlot(base, slot_runtime_invoke));
    string_new = @ptrFromInt(try checkedSlot(base, slot_string_new));

    try il2cpp.beginLookup();
    defer il2cpp.endLookup();
    for (std.enums.values(M)) |key| {
        const pin = pin_table.get(key);
        const klass = il2cpp.findClass(pin.ns, pin.class) catch |err| {
            log.err("lookup class {s}.{s} failed: {t}", .{ pin.ns, pin.class, err });
            return err;
        };
        methods.set(key, il2cpp.findMethodInfoAt(klass, pin.name, pin.params, pin.rva) catch |err| {
            log.err("lookup {s}::{s}/{d} at RVA 0x{X} failed: {t}", .{ pin.class, pin.name, pin.params, pin.rva, err });
            return err;
        });
        if (key == .trace_ctor) trace_class = klass;
    }
    const exception = try il2cpp.findClass("System", "Exception");
    if (try il2cpp.findField(exception, "_message") != exception_message_offset) return error.ExceptionLayoutChanged;
    const string = try il2cpp.findClass("System", "String");
    if (try il2cpp.findField(string, "m_stringLength") != string_length_offset) return error.StringLayoutChanged;
    if (try il2cpp.findField(string, "m_firstChar") != string_chars_offset) return error.StringLayoutChanged;
    installTickHook(base) catch |err| log.err("tree-tick hook not installed ({t}); reseed = tree falls back to frame", .{err});
    installAiStartHooks(base) catch |err| log.err("AI start hooks not installed ({t}); enemy AI may start a frame apart between runs", .{err});
    installInputClock(base) catch |err| log.err("input clock not hooked ({t}); recordings play on the real input clock", .{err});
    installSyncHook(base) catch |err| log.err("sync hook not installed ({t}); inputs count from the battle's awake", .{err});
    installTimeClocks(base) catch |err| log.err("Unity clocks not hooked ({t}); timers on real time may end a frame apart between runs", .{err});
    installTeamSetupHook(base) catch |err| log.err("team-setup hook not installed ({t}); pin_team unavailable", .{err});
    installSpawnTickHook(base) catch |err| log.err("entity-manager hook not installed ({t}); pin_spawn unavailable", .{err});
    try installBattleHooks(base);
    resolveOrderCounter();
}

/// Called once by main.zig's worker thread when the il2cpp runtime is ready.
pub fn installFromWorker() void {
    install() catch |err| {
        log.err("TAS off: {t}", .{err});
        return;
    };
    ready = true;
    log.info("TAS ready: {d} methods and 3 API slots verified; mode is read from {s} at every battle start", .{ methods.values.len, config_file });
}

// --- managed calls -----------------------------------------------------------------------

const CallError = error{ManagedException};

/// `runtime_invoke(method, obj, args, &exc)`. Value-type arguments are passed as pointers to the
/// value, reference-type arguments as the object pointer itself; value-type results come boxed.
fn call(m: M, object: usize, args: []const usize) CallError!usize {
    var exception: usize = 0;
    const result = runtime_invoke(methods.get(m), object, if (args.len == 0) null else args.ptr, &exception);
    if (exception != 0) {
        var class_buffer: [256]u8 = undefined;
        const class = il2cpp.objectClassName(exception, &class_buffer) catch "?";
        var message_buffer: [512]u8 = undefined;
        const message_object = @as(*const usize, @ptrFromInt(exception + exception_message_offset)).*;
        const message = managedString(message_object, &message_buffer);
        log.err("{t} threw {s}: {s}", .{ m, class, message });
        userLog("  {t} threw {s}: {s}", .{ m, class, message });
        return error.ManagedException;
    }
    return result;
}

fn unbox(comptime T: type, boxed: usize) T {
    if (boxed == 0) return std.mem.zeroes(T);
    return @as(*align(1) const T, @ptrFromInt(boxed + 0x10)).*;
}

/// An il2cpp System.String as ASCII ('?' for the rest), for messages.
fn managedString(object: usize, buffer: []u8) []const u8 {
    if (object == 0) return "";
    const length: usize = @intCast(@max(0, @as(*const i32, @ptrFromInt(object + string_length_offset)).*));
    const chars: [*]const u16 = @ptrFromInt(object + string_chars_offset);
    const n = @min(length, buffer.len);
    for (0..n) |i| buffer[i] = if (chars[i] < 128) @intCast(chars[i]) else '?';
    return buffer[0..n];
}

fn int(m: M) CallError!i32 {
    return unbox(i32, try call(m, 0, &.{}));
}

fn setInt(m: M, value: i32) CallError!void {
    var v = value;
    _ = try call(m, 0, &.{@intFromPtr(&v)});
}

/// A strong GC handle, so an object only native code points at is not collected (0 on failure).
fn hold(object: usize) u32 {
    var handle: i32 = 0;
    var kind: i32 = gc_handle_normal;
    const boxed = call(.handle_new, 0, &.{ object, @intFromPtr(&handle), @intFromPtr(&kind) }) catch return 0;
    return @bitCast(unbox(i32, boxed));
}

fn release(handle: u32) void {
    if (handle == 0) return;
    var h: i32 = @bitCast(handle);
    _ = call(.handle_free, 0, &.{@intFromPtr(&h)}) catch {};
}

// --- config ------------------------------------------------------------------------------

const Mode = enum { off, record, play };

const vk_f8: u8 = 0x77;

/// Windows virtual-key code for a `stop_key` name; 0 for `none` / `off`.
fn keyCode(name: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(name, "none") or std.ascii.eqlIgnoreCase(name, "off")) return 0;
    if (name.len >= 2 and (name[0] == 'F' or name[0] == 'f')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        return if (n >= 1 and n <= 24) 0x70 + n - 1 else null;
    }
    if (name.len == 1) {
        const c = std.ascii.toUpper(name[0]);
        if ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return c;
        return null;
    }
    const named = [_]struct { []const u8, u8 }{ .{ "pause", 0x13 }, .{ "end", 0x23 }, .{ "home", 0x24 }, .{ "insert", 0x2D }, .{ "delete", 0x2E }, .{ "backspace", 0x08 } };
    for (named) |entry| if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    return null;
}

/// When the seed is applied. `start`: once, at battle awake. `frame`: also after every game step,
/// to a value derived only from the seed and the level time manager's frame counter. Unity's
/// generator is shared with consumers whose timing follows real time (asset loading, effects:
/// tas-frames.tsv shows the same bursts landing a few frames apart and other bursts differing),
/// so a seed applied once drifts within seconds; reseeding per frame confines such a burst to the
/// frame it lands in.
const Reseed = enum {
    start,
    frame,
    /// `frame`, plus a reseed right before every Behavior Designer tree tick, from the seed, the
    /// tree's identity and the frame: enemy and Bangboo decisions then read only their own numbers,
    /// whatever else drew from the generator earlier in the same frame.
    tree,

    fn parse(text: []const u8) ?Reseed {
        if (std.ascii.eqlIgnoreCase(text, "tree")) return .tree;
        if (std.ascii.eqlIgnoreCase(text, "frame")) return .frame;
        if (std.ascii.eqlIgnoreCase(text, "start")) return .start;
        return null;
    }
};

/// The generator seed for one game frame: the battle seed and the frame counter, mixed (a
/// splitmix-style finaliser) so neighbouring frames get unrelated streams.
fn frameSeed(seed: i32, game_frame: i32) i32 {
    var x: u32 = @as(u32, @bitCast(seed)) ^ (@as(u32, @bitCast(game_frame)) *% 0x9E3779B9);
    x ^= x >> 16;
    x *%= 0x7FEB352D;
    x ^= x >> 15;
    x *%= 0x846CA68B;
    x ^= x >> 16;
    return @bitCast(x);
}
const Path = [260]u8;

const Config = struct {
    mode: Mode = .off,
    file: Path = undefined,
    file_len: usize = 0,
    fps: u32 = 60,
    fps_set: bool = false,
    speed: f32 = 1.0,
    seed: ?i32 = null,
    devices_new: bool = false,
    reseed: ?Reseed = null,
    stop_key: u8 = vk_f8,
    /// Features added after run 11 (the best replay so far), off unless asked for; a recording
    /// keeps the ones it was made with.
    sync: bool = false,
    input_clock: bool = false,
    game_clocks: bool = false,
    pin_team: bool = false,
    pin_spawn: bool = false,

    fn path(self: *const Config) []const u8 {
        return self.file[0..self.file_len];
    }
};

fn onOff(value: []const u8, key: []const u8) bool {
    for ([_][]const u8{ "on", "true", "yes", "1" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    for ([_][]const u8{ "off", "false", "no", "0" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return false;
    warn("{s}: {s} must be on or off, got {s}; off", .{ config_file, key, value });
    return false;
}

/// `key = value` lines; `#` starts a comment; keys and modes are case-insensitive.
fn parseConfig(text: []const u8) Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warn("{s}: ignored line without '=': {s}", .{ config_file, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.ascii.eqlIgnoreCase(key, "mode")) {
            if (std.ascii.eqlIgnoreCase(value, "record")) config.mode = .record else if (std.ascii.eqlIgnoreCase(value, "play")) config.mode = .play else config.mode = .off;
        } else if (std.ascii.eqlIgnoreCase(key, "file")) {
            const n = @min(value.len, config.file.len - 1);
            @memcpy(config.file[0..n], value[0..n]);
            config.file_len = n;
        } else if (std.ascii.eqlIgnoreCase(key, "fps")) {
            const fps = std.fmt.parseInt(u32, value, 10) catch 0;
            if (fps >= 10 and fps <= 1000) {
                config.fps = fps;
                config.fps_set = true;
            } else warn("{s}: fps must be 10..1000, got {s}; using 60", .{ config_file, value });
        } else if (std.ascii.eqlIgnoreCase(key, "speed")) {
            const speed = std.fmt.parseFloat(f32, value) catch -1;
            if (speed >= 0 and speed <= 16) config.speed = speed else warn("{s}: speed must be 0..16, got {s}", .{ config_file, value });
        } else if (std.ascii.eqlIgnoreCase(key, "seed")) {
            config.seed = std.fmt.parseInt(i32, value, 0) catch blk: {
                warn("{s}: seed must be an integer, got {s}; not seeding", .{ config_file, value });
                break :blk null;
            };
        } else if (std.ascii.eqlIgnoreCase(key, "devices")) {
            config.devices_new = std.ascii.eqlIgnoreCase(value, "new");
        } else if (std.ascii.eqlIgnoreCase(key, "stop_key")) {
            config.stop_key = keyCode(value) orelse blk: {
                warn("{s}: stop_key {s} not recognised (F1-F24, A-Z, 0-9, Pause, End, Home, Insert, Delete, Backspace, none); using F8", .{ config_file, value });
                break :blk vk_f8;
            };
        } else if (std.ascii.eqlIgnoreCase(key, "sync")) {
            config.sync = onOff(value, key);
        } else if (std.ascii.eqlIgnoreCase(key, "input_clock")) {
            config.input_clock = onOff(value, key);
        } else if (std.ascii.eqlIgnoreCase(key, "game_clocks")) {
            config.game_clocks = onOff(value, key);
        } else if (std.ascii.eqlIgnoreCase(key, "pin_team")) {
            config.pin_team = onOff(value, key);
        } else if (std.ascii.eqlIgnoreCase(key, "pin_spawn")) {
            config.pin_spawn = onOff(value, key);
        } else if (std.ascii.eqlIgnoreCase(key, "reseed")) {
            config.reseed = Reseed.parse(value) orelse blk: {
                warn("{s}: reseed must be tree, frame or start, got {s}", .{ config_file, value });
                break :blk null;
            };
        } else warn("{s}: unknown key {s}", .{ config_file, key });
    }
    return config;
}

fn readSmallFile(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const handle = CreateFileA(path, GENERIC_READ, 1, null, OPEN_EXISTING, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(handle);
    var got: u32 = 0;
    if (ReadFile(handle, buffer.ptr, @intCast(buffer.len), &got, null) == .FALSE) return null;
    return buffer[0..got];
}

fn writeSmallFile(path: [*:0]const u8, text: []const u8) bool {
    const handle = CreateFileA(path, GENERIC_WRITE, 1, null, CREATE_ALWAYS, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    return WriteFile(handle, text.ptr, @intCast(text.len), &written, null) != .FALSE and written == text.len;
}

fn exists(path: [*:0]const u8) bool {
    return GetFileAttributesA(path) != INVALID_ATTRIBUTES;
}

/// One line appended to TAS\tas-log.txt (local time first), for the player to read.
fn userLog(comptime fmt: []const u8, args: anytype) void {
    _ = CreateDirectoryA(tas_dir, null);
    var now: SystemTime = undefined;
    GetLocalTime(&now);
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}  " ++ fmt ++ "\r\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second } ++ args) catch return;
    const handle = CreateFileA(user_log, FILE_APPEND_DATA, 1, null, OPEN_ALWAYS, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    _ = WriteFile(handle, text.ptr, @intCast(text.len), &written, null);
}

// --- recordings ---------------------------------------------------------------------------

/// `reseed` is absent from recordings made before the option existed; those were seeded at start.
/// `input_clock` is absent from recordings made before it was optional; those had one exactly when
/// they had `sync=` (runs 15 and 16).
const Info = struct { fps: u32 = 0, seed: ?i32 = null, frames: i64 = -1, events: i64 = -1, reseed: Reseed = .start, sync: bool = false, input_clock: ?bool = null, game_clocks: bool = false, pin_team: bool = false, pin_spawn: bool = false };

fn infoPath(buffer: *Path, file: []const u8) ?[*:0]const u8 {
    const s = std.fmt.bufPrintZ(buffer, "{s}.info.txt", .{file}) catch return null;
    return s.ptr;
}

fn readInfo(file: []const u8) ?Info {
    var path: Path = undefined;
    var buffer: [2048]u8 = undefined;
    const text = readSmallFile(infoPath(&path, file) orelse return null, &buffer) orelse return null;
    var info: Info = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "fps")) info.fps = std.fmt.parseInt(u32, value, 10) catch 0;
        if (std.mem.eql(u8, key, "seed")) info.seed = std.fmt.parseInt(i32, value, 10) catch null;
        if (std.mem.eql(u8, key, "frames")) info.frames = std.fmt.parseInt(i64, value, 10) catch -1;
        if (std.mem.eql(u8, key, "events")) info.events = std.fmt.parseInt(i64, value, 10) catch -1;
        if (std.mem.eql(u8, key, "reseed")) info.reseed = Reseed.parse(value) orelse .start;
        if (std.mem.eql(u8, key, "sync")) info.sync = std.mem.eql(u8, value, "bt-load");
        if (std.mem.eql(u8, key, "input_clock")) info.input_clock = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "game_clocks")) info.game_clocks = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "pin_team")) info.pin_team = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "pin_spawn")) info.pin_spawn = std.mem.eql(u8, value, "1");
    }
    return info;
}

/// `file`, or `stem-2.ext`, `stem-3.ext`, ... if it exists; never overwrites a recording.
fn freshRecordPath(out: *Path, file: []const u8) ![]const u8 {
    const z = try std.fmt.bufPrintZ(out, "{s}", .{file});
    if (!exists(z.ptr)) return z;
    const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;
    var k: u32 = 2;
    while (k < 1000) : (k += 1) {
        const candidate = try std.fmt.bufPrintZ(out, "{s}-{d}{s}", .{ file[0..dot], k, file[dot..] });
        if (!exists(candidate.ptr)) return candidate;
    }
    return error.TooManyRecordings;
}

fn defaultRecordPath(out: *Path) ![]const u8 {
    var now: SystemTime = undefined;
    GetLocalTime(&now);
    var name: Path = undefined;
    const file = try std.fmt.bufPrint(&name, tas_dir ++ "\\battle-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.inputtrace", .{ now.year, now.month, now.day, now.hour, now.minute, now.second });
    return freshRecordPath(out, file);
}

// --- session ------------------------------------------------------------------------------

const Session = struct {
    mode: Mode = .off,
    file: Path = undefined,
    file_len: usize = 0,
    fps: u32 = 60,
    speed: f32 = 1.0,
    seed: ?i32 = null,
    reseed: Reseed = .frame,
    devices_new: bool = false,
    stop_key: u8 = 0,
    stop_key_down: bool = true, // a key already held at battle start does not count as a press
    stopped: bool = false,
    stopped_frame: i32 = 0,
    stopped_position: i32 = 0,
    trace: usize = 0,
    trace_handle: u32 = 0,
    controller: usize = 0,
    controller_handle: u32 = 0,
    frame0: i32 = 0,
    previous_target_fps: i32 = -1,
    previous_vsync: i32 = 1,
    timing_set: bool = false,
    recorded_frames: i64 = -1,
    recorded_events: i64 = -1,
    /// Inputs, input clock and reseeds count from the first behaviour-tree load request (the sync
    /// point) instead of from the battle's awake; see the sync section.
    sync: bool = false,
    sync_unity: ?i32 = null,
    inputs_started: bool = false,
    game_clocks: bool = false,
    pin_team: bool = false,
    pin_spawn: bool = false,
    spawn_held: bool = false,
    spawn_resumed: bool = false,

    fn path(self: *const Session) []const u8 {
        return self.file[0..self.file_len];
    }
    fn pathZ(self: *Session) [*:0]const u8 {
        self.file[self.file_len] = 0;
        return @ptrCast(self.file[0..self.file_len :0]);
    }
};

var session: Session = .{};

/// Fixed timestep, frame cap and seed for the battle. Previous frame cap and vsync are kept for
/// restoreTiming(); Time.captureDeltaTime has no getter in this build, and 0 is Unity's default.
fn applyTiming() CallError!void {
    session.frame0 = try int(.time_frame);
    session.previous_target_fps = try int(.app_get_fps);
    session.previous_vsync = try int(.vsync_get);
    var dt: f32 = 1.0 / @as(f32, @floatFromInt(session.fps));
    _ = try call(.time_capture, 0, &.{@intFromPtr(&dt)});
    session.timing_set = true;
    try setInt(.vsync_set, 0); // vsync would override the frame cap
    const target: i32 = if (session.speed > 0)
        @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(session.fps)) * session.speed))))
    else
        -1;
    try setInt(.app_set_fps, target);
    if (session.seed) |seed| try setInt(.random_init, seed);
}

fn restoreTiming() void {
    if (!session.timing_set) return;
    var dt: f32 = 0;
    _ = call(.time_capture, 0, &.{@intFromPtr(&dt)}) catch {};
    setInt(.app_set_fps, session.previous_target_fps) catch {};
    setInt(.vsync_set, session.previous_vsync) catch {};
    session.timing_set = false;
}

fn beginRecord(config: *const Config) !void {
    var path: Path = undefined;
    _ = CreateDirectoryA(tas_dir, null);
    const file = if (config.file_len > 0) try freshRecordPath(&path, config.path()) else try defaultRecordPath(&path);
    @memcpy(session.file[0..file.len], file);
    session.file_len = file.len;
    session.fps = config.fps;
    session.seed = config.seed;
    session.reseed = config.reseed orelse .tree;
    if (session.reseed == .tree and !tick_hooked) {
        warn("reseed = tree needs the tree-tick hook, which is not installed; recording with reseed = frame", .{});
        session.reseed = .frame;
    }

    try applyTiming();
    if (config.input_clock) {
        clockStartRecord();
        if (clock_mode != .record) warn("input_clock = on, but the input clock is not hooked; recording without it", .{});
    }
    session.game_clocks = config.game_clocks and time_hooked;
    if (config.game_clocks and !time_hooked) warn("game_clocks = on, but the Unity clocks are not hooked; recording without it", .{});
    _ = try call(.trace_file_format, 0, &.{}); // class constructor first
    const trace = object_new(trace_class);
    if (trace == 0) return error.ObjectNewFailed;
    session.trace_handle = hold(trace);
    var size: i64 = 16 << 20;
    var grow: bool = true;
    var max: i64 = 1 << 30;
    var increment: i64 = 16 << 20;
    _ = try call(.trace_ctor, trace, &.{ @intFromPtr(&size), @intFromPtr(&grow), @intFromPtr(&max), @intFromPtr(&increment) });
    var markers: bool = true;
    _ = try call(.trace_set_markers, trace, &.{@intFromPtr(&markers)});
    session.trace = trace;
    session.sync = config.sync and sync_hooked;
    session.pin_team = config.pin_team and session.sync and team_setup_hooked;
    if (config.pin_team and !session.pin_team) warn("pin_team = on needs sync = on and the team-setup hook; recording without it", .{});
    session.pin_spawn = config.pin_spawn and session.sync and spawn_tick_hooked;
    if (config.pin_spawn and !session.pin_spawn) warn("pin_spawn = on needs sync = on and the entity-manager hook; recording without it", .{});
    if (config.sync and !sync_hooked) warn("sync = on, but the behaviour-tree load hook is not installed; recording from the awake", .{});
    if (!session.sync) try startInputs();
}

fn beginPlay(config: *const Config) !void {
    if (config.file_len == 0) {
        userLog("play: no file= in {s}", .{config_file});
        return error.NoFile;
    }
    @memcpy(session.file[0..config.file_len], config.path());
    session.file_len = config.file_len;
    if (!exists(session.pathZ())) {
        userLog("play: {s} not found", .{session.path()});
        return error.RecordingNotFound;
    }
    const info = readInfo(session.path()) orelse Info{};
    session.fps = if (info.fps != 0) info.fps else config.fps;
    if (info.fps != 0 and config.fps_set and config.fps != info.fps)
        warn("fps = {d} in {s} ignored: the recording ran at {d}", .{ config.fps, config_file, info.fps });
    session.seed = config.seed orelse info.seed;
    session.reseed = config.reseed orelse info.reseed;
    if (session.reseed == .tree and !tick_hooked) {
        warn("the recording used reseed = tree but the tree-tick hook is not installed; it will not replay exactly", .{});
        session.reseed = .frame;
    }
    if (config.reseed != null and config.reseed.? != info.reseed)
        warn("reseed = {t} overrides the recording's {t}: the replay will not match it", .{ config.reseed.?, info.reseed });
    session.recorded_frames = info.frames;
    session.recorded_events = info.events;
    session.sync = info.sync;
    if (session.sync and !sync_hooked) {
        userLog("play: {s} starts at the first behaviour-tree load, but that hook is not installed", .{session.path()});
        return error.SyncHookMissing;
    }
    session.devices_new = config.devices_new;
    session.stop_key = config.stop_key;

    try applyTiming();
    if (info.input_clock orelse info.sync) {
        if (!clockStartPlay(session.path()))
            warn("{s} was recorded with the input clock, but {s}.clock is missing or unreadable (or the clock is not hooked): it plays on the real input clock", .{ session.path(), session.path() });
    }
    session.game_clocks = info.game_clocks;
    session.pin_team = info.pin_team;
    session.pin_spawn = info.pin_spawn;
    if (session.pin_spawn and !(session.sync and spawn_tick_hooked)) {
        userLog("play: {s} was recorded with pin_spawn, but the entity-manager hook is not installed (or sync is off)", .{session.path()});
        return error.SpawnHookMissing;
    }
    if (session.pin_team and !(session.sync and team_setup_hooked)) {
        userLog("play: {s} was recorded with pin_team, but the team-setup hook is not installed (or sync is off)", .{session.path()});
        return error.TeamHookMissing;
    }
    if (session.game_clocks and !time_hooked) {
        userLog("play: {s} was recorded with game_clocks, but the Unity clocks are not hooked", .{session.path()});
        return error.ClockHookMissing;
    }
    const path_string = string_new(session.pathZ());
    if (path_string == 0) return error.StringNewFailed;
    const trace = try call(.trace_load, 0, &.{path_string});
    if (trace == 0) return error.LoadFailed;
    session.trace = trace;
    session.trace_handle = hold(trace);
    var controller = try call(.trace_replay, trace, &.{});
    if (controller == 0) return error.ReplayFailed;
    if (session.devices_new) controller = try call(.replay_new_devices, controller, &.{});
    session.controller = controller;
    session.controller_handle = hold(controller);
    if (!session.sync) try startInputs();
}

// --- per-frame log: <battle folder>\tas-frames.tsv ------------------------------------------
//
// One row per game frame while a session runs, written from the level time manager's per-frame
// step (the battle-update hook calls frame() every battle frame):
//
//   unity_frame  Time.frameCount - the session's start frame
//   game_frame   the level time manager's own frame counter (timescale.tsv `frame`)
//   elapsed_ms   wall clock since the session started
//   world_s      the time manager's accumulated world time
//   order        a value of the process-wide row counter (damage-result / state.tsv `order`): rows
//                with an order between two frames' values happened in the later frame's step
//   rng0..rng3   UnityEngine.Random.state after the step (xorshift128 words, hex)
//
// Comparing recording and playback row by row gives the exact frame where the random stream or
// the world clock first differs, and an exact frame for every damage/state row.

// --- per-session log folder: TAS\logs\<date>-<time>-<mode>\ --------------------------------------

const PathBuf = [260]u8;
var session_dir: PathBuf = undefined;
var session_dir_len: usize = 0;
var session_t0: u64 = 0;

fn openSessionDir(mode: Mode) void {
    var now: SystemTime = undefined;
    GetLocalTime(&now);
    _ = CreateDirectoryA(tas_dir, null);
    _ = CreateDirectoryA(tas_dir ++ "\\logs", null);
    const dir = std.fmt.bufPrintZ(&session_dir, tas_dir ++ "\\logs\\{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{t}", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, mode }) catch return;
    _ = CreateDirectoryA(dir.ptr, null);
    session_dir_len = dir.len;
    session_t0 = GetTickCount64();
}

/// `<session folder>\<name>`.
fn battlePath(buf: *PathBuf, name: []const u8) [*:0]const u8 {
    const z = std.fmt.bufPrintZ(buf, "{s}\\{s}", .{ session_dir[0..session_dir_len], name }) catch return "tas-unnamed.tsv";
    return z.ptr;
}

/// thaumiel's process-wide row counter, when the installed thaumiel exports it (the combat-logger
/// fork does): tas-frames.tsv then carries a value of it per frame, so its damage/state rows can be
/// placed on exact frames. 0 otherwise.
var next_order: ?*const fn () callconv(.c) u64 = null;

fn resolveOrderCounter() void {
    const module = GetModuleHandleA("thaumiel.dll") orelse return;
    if (GetProcAddress(module, "thaumiel_log_next_order")) |f| next_order = @ptrCast(f);
}

fn orderNow() u64 {
    return if (next_order) |f| f() else 0;
}

/// A buffered TSV file in the battle folder, open while a session runs.
const Tsv = struct {
    name: []const u8,
    header: []const u8,
    file: ?w.HANDLE = null,
    buffer: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn open(self: *Tsv) void {
        var path: PathBuf = undefined;
        const handle = CreateFileA(battlePath(&path, self.name), GENERIC_WRITE, 1, null, CREATE_ALWAYS, 0x80, null);
        if (handle == w.INVALID_HANDLE_VALUE) {
            log.err("could not create {s}", .{self.name});
            return;
        }
        self.file = handle;
        self.len = 0;
        self.emit("{s}", .{self.header});
    }

    fn flush(self: *Tsv) void {
        const handle = self.file orelse return;
        var written: u32 = 0;
        if (self.len > 0) _ = WriteFile(handle, &self.buffer, @intCast(self.len), &written, null);
        self.len = 0;
    }

    fn emit(self: *Tsv, comptime fmt: []const u8, args: anytype) void {
        if (self.len + 512 > self.buffer.len) self.flush();
        const text = std.fmt.bufPrint(self.buffer[self.len..], fmt, args) catch return;
        self.len += text.len;
    }

    fn close(self: *Tsv) void {
        self.flush();
        if (self.file) |handle| _ = CloseHandle(handle);
        self.file = null;
    }
};

var frames_log: Tsv = .{ .name = "tas-frames.tsv", .header = "unity_frame\tgame_frame\telapsed_ms\tworld_s\torder\trng0\trng1\trng2\trng3\ttas_frame\tfixed_phase\n" };

/// One row per Behavior Designer tree tick (see the per-tree section below).
var trees_log: Tsv = .{ .name = "tas-trees.tsv", .header = "game_frame\ttree\tid\ttick\tseed\trng0\trng1\trng2\trng3\tvia\tname\n" };

/// One row per enemy AI start (see the deterministic AI start section below).
var loads_log: Tsv = .{ .name = "tas-loads.tsv", .header = "game_frame\tevent\trequest\tfinished\tstart\n" };

/// One row per behaviour-tree load request (diagnostic, see tryLoadHook).
var btloads_log: Tsv = .{ .name = "tas-bt-loads.tsv", .header = "tas_frame\towner\texternal\trng0\trng1\trng2\trng3\tstack\n" };

fn openFrames() void {
    frames_log.open();
    if (tick_hooked) trees_log.open();
    if (ai_start_hooked) loads_log.open();
    if (sync_hooked) btloads_log.open();
}

fn closeFrames() void {
    frames_log.close();
    trees_log.close();
    loads_log.close();
    btloads_log.close();
    dropDeferred();
}

/// Called by the battle-update hook every frame of a battle, on the game thread.
/// Logs the frame (the random state is the one the frame's draws left behind), then, with
/// `reseed = frame`, seeds the generator for the next frame from the seed and this frame number.
pub fn frame(elapsed_ms: u64, game_frame: i32, world: f32) void {
    if (!ready or session.mode == .off) return;
    if (session.sync and !session.inputs_started and !session.stopped) {
        if (session.sync_unity == null and game_frame >= sync_wait_limit) {
            session.sync_unity = session.frame0 + game_frame;
            log.err("no behaviour-tree load by game frame {d}; inputs start now", .{game_frame});
            userLog("{t}   no behaviour-tree load by game frame {d}: inputs start there (this battle may not replay)", .{ session.mode, game_frame });
        }
        if (session.sync_unity != null) startInputs() catch |err| log.err("starting inputs failed: {t}", .{err});
    }
    const rel = game_frame - (baseFrame() - session.frame0);
    current_frame = rel;
    if (clock_mode == .play and session.inputs_started and rel >= 0 and @as(usize, @intCast(rel)) >= clock_frames) {
        clockEndReplay();
        log.info("input clock replay ended at frame {d} (end of the recording)", .{rel});
    }
    if (frames_log.file != null) {
        const order = orderNow();
        const unity = (int(.time_frame) catch session.frame0) - session.frame0;
        var state = [4]u32{ 0, 0, 0, 0 };
        if (call(.random_state, 0, &.{})) |boxed| {
            if (boxed != 0) state = @as(*align(1) const [4]u32, @ptrFromInt(boxed + 0x10)).*;
        } else |_| {}
        frames_log.emit("{d}\t{d}\t{d}\t{d}\t{d}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{d}\t{d:.6}\n", .{ unity, game_frame, elapsed_ms, world, order, state[0], state[1], state[2], state[3], rel, timeDirect(.time_unscaled) - timeDirect(.time_fixed_unscaled) });
    }
    if (ai_start_hooked) releaseDeferred();
    if (team_setup_pending > 0) releaseTeamSetup(rel);
    if (session.reseed == .frame or session.reseed == .tree) {
        if (session.seed) |seed| setInt(.random_init, frameSeed(seed, rel)) catch {};
    }
    if (session.mode == .play and !session.stopped and session.stop_key != 0) {
        const down = GetAsyncKeyState(session.stop_key) < 0; // high bit: held now
        if (down and !session.stop_key_down and gameInFront()) stopPlayback(game_frame);
        session.stop_key_down = down;
    }
}

/// The hotkey only counts while the game window has focus.
fn gameInFront() bool {
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

/// Stop hotkey: end the replay here and hand the controls back. Disposing the controller stops it
/// injecting and removes the devices it created (`devices = new`); the real keyboard, mouse and
/// gamepad are reset so nothing the recording was holding stays pressed. Timing and seeding stay
/// as they were until the battle ends.
fn stopPlayback(game_frame: i32) void {
    session.stopped_position = unbox(i32, call(.replay_position, session.controller, &.{}) catch 0);
    _ = call(.replay_dispose, session.controller, &.{}) catch {};
    clockEndReplay();
    for ([_]M{ .keyboard_current, .mouse_current, .gamepad_current }) |m| {
        const device = call(m, 0, &.{}) catch continue;
        if (device == 0) continue;
        var also_dont_reset: bool = false;
        _ = call(.input_reset_device, 0, &.{ device, @intFromPtr(&also_dont_reset) }) catch {};
    }
    session.stopped = true;
    session.stopped_frame = game_frame;
    log.info("play stopped by hotkey at game frame {d}, event {d} of {d}", .{ game_frame, session.stopped_position, session.recorded_events });
    userLog("play   STOPPED by hotkey at game frame {d}, event {d} of {d}", .{ game_frame, session.stopped_position, session.recorded_events });
}

// --- per-tree reseed: BehaviorDesigner.Runtime.BehaviorManager::Tick(BehaviorTree) ------------
//
// Every Behavior Designer tree tick goes through this method: the game's AI subsystem
// (IOMGMDHDGON::KKNEBIJDOPO -> Tick(Behavior) -> here), its index-based tick
// (IOMGMDHDGON::PBHLPEFMFNA) and BehaviorManager's own Tick(). Before the original runs, the
// generator is seeded from the battle seed, the tree's identity, the frame and the number of
// ticks the tree already had this frame. A tree's identity is the FNV-1a hash of its
// BehaviorSource.behaviorName and its task count, plus an occurrence index for identical trees
// in first-seen order, so it is the same in every run whatever the pointers and the load order.

const detour = @import("detour.zig");
const nt = @import("nt.zig");

const tick_rva: usize = 0x6913EB0;
/// push r15/r14/r13/r12/rsi/rdi/rbp/rbx; sub rsp,0x48 -- position independent.
const tick_prologue = [_]u8{ 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x56, 0x57, 0x55, 0x53, 0x48, 0x83, 0xEC, 0x48 };
var tick_original: u64 = 0;
var tick_hooked = false;

/// Field offsets the identity is read through (checked at install).
const off_tree_behavior: usize = 0x58; // BehaviorManager.BehaviorTree.behavior
const off_tree_tasks: usize = 0x98; // BehaviorManager.BehaviorTree.taskList
const off_behavior_source: usize = 0x70; // Behavior.mBehaviorSource
const off_source_name: usize = 0x10; // BehaviorSource.behaviorName
const off_list_size: usize = 0x18; // List<T>._size

const TreeSlot = struct { tree: usize, id: u32, frame: i32, ticks: u32, named: bool = false };
var trees: [128]TreeSlot = undefined;
var trees_len: usize = 0;
var current_frame: i32 = 0;

fn readUsize(address: usize) usize {
    return if (address < 0x10000) 0 else @as(*align(1) const usize, @ptrFromInt(address)).*;
}

fn treeBaseId(tree: usize) u32 {
    var h: u32 = 0x811C9DC5;
    const source = readUsize(readUsize(tree + off_tree_behavior) + off_behavior_source);
    const name = readUsize(source + off_source_name);
    if (name != 0) {
        const len: usize = @intCast(@max(0, @min(512, @as(*align(1) const i32, @ptrFromInt(name + string_length_offset)).*)));
        const chars: [*]align(1) const u16 = @ptrFromInt(name + string_chars_offset);
        for (0..len) |i| h = (h ^ chars[i]) *% 0x01000193;
    }
    const tasks = readUsize(tree + off_tree_tasks);
    const count: u32 = if (tasks != 0) @bitCast(@as(*align(1) const i32, @ptrFromInt(tasks + off_list_size)).*) else 0;
    return (h ^ count) *% 0x01000193;
}

fn treeSlot(tree: usize) ?*TreeSlot {
    for (trees[0..trees_len]) |*slot| if (slot.tree == tree) return slot;
    if (trees_len == trees.len) return null;
    const base = treeBaseId(tree);
    var occurrence: u32 = 0;
    // identical trees are numbered in first-seen order; slots are kept in that order
    for (trees[0..trees_len]) |slot| {
        if (slot.id == base +% occurrence *% 0x9E3779B9) occurrence += 1;
    }
    trees[trees_len] = .{ .tree = tree, .id = base +% occurrence *% 0x9E3779B9, .frame = -1, .ticks = 0 };
    trees_len += 1;
    return &trees[trees_len - 1];
}

const TickNote = struct { slot: *TreeSlot, tick: u32, value: ?i32, via: [3]usize };

fn treeTickSeed(seed: i32, slot: *const TreeSlot) i32 {
    const tree_seed = frameSeed(@bitCast(@as(u32, @bitCast(seed)) ^ slot.id), current_frame);
    return frameSeed(tree_seed, @bitCast(slot.ticks));
}

fn beforeTreeTick(tree: usize) ?TickNote {
    if (!ready or session.mode == .off or tree == 0) return null;
    const slot = treeSlot(tree) orelse return null;
    if (slot.frame != current_frame) {
        slot.frame = current_frame;
        slot.ticks = 0;
    }
    var note: TickNote = .{ .slot = slot, .tick = slot.ticks, .value = null, .via = .{ 0, 0, 0 } };
    if (session.reseed == .tree) {
        if (session.seed) |seed| note.value = treeTickSeed(seed, slot);
    }
    slot.ticks += 1;
    if (note.value) |value| setInt(.random_init, value) catch {};
    return note;
}

/// UnityEngine.Random.state, read through the pinned get_state's code directly (no boxing): the
/// 16-byte struct comes back through a hidden pointer in rcx, the MethodInfo* goes in rdx.
fn randomState() [4]u32 {
    var state = [4]u32{ 0, 0, 0, 0 };
    const info = methods.get(.random_state);
    if (info == 0) return state;
    const code: *const fn (*[4]u32, usize) callconv(.c) *[4]u32 = @ptrFromInt(@as(*const usize, @ptrFromInt(info)).*);
    _ = code(&state, info);
    return state;
}

/// After the tick: the generator state it left (with the seed, the number of draws it made) and,
/// on a tree's first row, its behaviour name.
fn afterTreeTick(note: TickNote) void {
    if (trees_log.file == null) return;
    const slot = note.slot;
    const index = (@intFromPtr(slot) - @intFromPtr(&trees[0])) / @sizeOf(TreeSlot);
    const state = randomState();
    var seed_text: [16]u8 = undefined;
    const seed = if (note.value) |v| std.fmt.bufPrint(&seed_text, "{d}", .{v}) catch "?" else "-";
    var name_text: [160]u8 = undefined;
    var name: []const u8 = "";
    if (!slot.named) {
        slot.named = true;
        name = ownerName(slot.tree, &name_text);
    }
    trees_log.emit("{d}\t{d}\t{x:0>8}\t{d}\t{s}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{x}:{x}:{x}\t{s}\n", .{ current_frame, index, slot.id, note.tick, seed, state[0], state[1], state[2], state[3], note.via[0], note.via[1], note.via[2], name });
}

/// "<GameObject name> / <BehaviorSource.behaviorName>". The GameObject name needs a Unity call, so
/// it is only asked for on the game thread.
fn ownerName(tree: usize, buffer: []u8) []const u8 {
    const behavior = readUsize(tree + off_tree_behavior);
    var len: usize = 0;
    if (behavior != 0 and GetCurrentThreadId() == main_thread) {
        if (call(.object_name, behavior, &.{})) |object| {
            len = managedString(object, buffer[0 .. buffer.len / 2]).len;
        } else |_| {}
    }
    const tail = std.fmt.bufPrint(buffer[len..], " / ", .{}) catch return buffer[0..len];
    len += tail.len;
    const source_name = readUsize(readUsize(behavior + off_behavior_source) + off_source_name);
    if (source_name != 0) len += managedString(source_name, buffer[len..]).len;
    for (buffer[0..len]) |*c| if (c.* < 0x20) {
        c.* = '?';
    };
    return buffer[0..len];
}

/// The three GameAssembly return addresses above the hook (RVAs; 0 outside GameAssembly), to tell
/// a scheduled tick from one an event forced.
fn callerRvas() [3]usize {
    var frames = [_]usize{0} ** 4;
    const n = RtlCaptureStackBackTrace(1, 4, &frames, null);
    var out = [3]usize{ 0, 0, 0 };
    const base = il2cpp.gameBase() catch return out;
    var k: usize = 0;
    for (frames[0..n]) |address| {
        if (k == out.len) break;
        if (address > base and address - base < 0x30000000) {
            out[k] = address - base;
            k += 1;
        }
    }
    return out;
}

/// `void Tick(this BehaviorManager, BehaviorTree tree, MethodInfo*)`, taken as six slots and passed
/// straight through (same shape as battle_hook.c).
fn tickHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    var note = beforeTreeTick(@intCast(a1));
    if (note != null and trees_log.file != null) note.?.via = callerRvas();
    const original: *const fn (u64, u64, u64, u64, u64, u64) callconv(.c) void = @ptrFromInt(@as(usize, @intCast(tick_original)));
    original(a0, a1, a2, a3, a4, a5);
    if (note) |n| afterTreeTick(n);
}

fn installTickHook(base: usize) !void {
    const manager = try il2cpp.findClass("BehaviorDesigner.Runtime", "BehaviorManager");
    const target = try il2cpp.findMethodAt(manager, "Tick", 1, tick_rva);
    const tree_class = try il2cpp.findClass("", "BehaviorTree");
    if (try il2cpp.findField(tree_class, "behavior") != off_tree_behavior) return error.TreeLayoutChanged;
    if (try il2cpp.findField(tree_class, "taskList") != off_tree_tasks) return error.TreeLayoutChanged;
    if (try il2cpp.findField(try il2cpp.findClass("BehaviorDesigner.Runtime", "Behavior"), "mBehaviorSource") != off_behavior_source) return error.BehaviorLayoutChanged;
    if (try il2cpp.findField(try il2cpp.findClass("BehaviorDesigner.Runtime", "BehaviorSource"), "behaviorName") != off_source_name) return error.SourceLayoutChanged;
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, target, .{ .prologue = &tick_prologue, .shape = .plain }, &tick_original, tickHook);
    tick_hooked = true;
    log.info("hooked BehaviorManager::Tick(BehaviorTree) at RVA 0x{X} for reseed = tree", .{target - base});
}

// --- deterministic AI start: deferred tree-load callbacks ---------------------------------------
//
// Behavior Designer deserialises trees on worker tasks and hands them back on the game thread in
// BehaviorAsyncLoadManager::ForegroundTick, which notifies whatever the workers have finished by
// then (_NotifyOneLoadItem). An enemy's AI starts in its load's callback
// (BKOBIBDGHFD::BCLGCCJAAEB -> FOKKPJGFCPC::LHMHPECIHPN sets its state to 5, the state its AI
// ticks in), so a load finishing a frame early or late moves that enemy's whole 4-frame AI
// cadence. Making the game thread wait for the workers does not work: some loads need the game
// thread to finish.
//
// Instead, during a session the AI-start callback is held back until `ai_start_delay` frames after
// the load was requested (BehaviorAsyncLoadItem.StartFrame, the Time.frameCount of the request,
// read in the _NotifyOneLoadItem hook that is on the stack when the callback runs), and released
// from frame() once that frame has come (ForegroundTick itself only runs while the loader is
// busy, so it cannot be the release point). A load that has not
// finished by then starts its AI late as usual and is logged as `late` (raise the delay).
// tas-loads.tsv logs every AI start.

const ai_start_delay: i32 = 20;

const notify_rva: usize = 0x6948590;
/// push rbp/rsi/rdi; sub rsp,0x50; lea rbp,[rsp+0x50] -- position independent.
const notify_prologue = [_]u8{ 0x55, 0x56, 0x57, 0x48, 0x83, 0xEC, 0x50, 0x48, 0x8D, 0x6C, 0x24, 0x50 };
const ai_start_rva: usize = 0x13DE0FE0;
/// push rsi/rdi; sub rsp,0x48; mov rsi,rcx; then the class-initialised `cmp byte [rip+x],0`.
const ai_start_prologue = [_]u8{ 0x56, 0x57, 0x48, 0x83, 0xEC, 0x48, 0x48, 0x89, 0xCE };
const off_item_start_frame: usize = 0xA0; // BehaviorAsyncLoadItem.StartFrame

var notify_original: u64 = 0;
var ai_start_original: u64 = 0;
var ai_start_hooked = false;
var main_thread: u32 = 0;

/// StartFrame of the load item being notified (null outside _NotifyOneLoadItem).
var notifying_request: ?i32 = null;

const Deferred = struct { closure: usize, tree: usize, closure_handle: u32, tree_handle: u32, request: i32, natural: i32, target: i32 };
var deferred: [64]Deferred = undefined;
var deferred_len: usize = 0;

const Hook6 = *const fn (u64, u64, u64, u64, u64, u64) callconv(.c) void;

fn unityFrame() i32 {
    return int(.time_frame) catch 0;
}

fn sessionFrame(unity: i32) i32 {
    return unity - baseFrame();
}

fn loadsRow(event: []const u8, request: i32, natural: i32, target: i32) void {
    loads_log.emit("{d}\t{s}\t{d}\t{d}\t{d}\n", .{ sessionFrame(unityFrame()), event, sessionFrame(request), sessionFrame(natural), sessionFrame(target) });
}

fn notifyHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(notify_original)));
    if (!ready or session.mode == .off or a1 == 0) return original(a0, a1, a2, a3, a4, a5);
    const previous = notifying_request;
    notifying_request = @as(*align(1) const i32, @ptrFromInt(@as(usize, @intCast(a1)) + off_item_start_frame)).*;
    original(a0, a1, a2, a3, a4, a5);
    notifying_request = previous;
}

fn aiStartHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(ai_start_original)));
    if (!ready or session.mode == .off or a0 == 0) return original(a0, a1, a2, a3, a4, a5);
    const now = unityFrame();
    const request = notifying_request orelse {
        loadsRow("direct", now, now, now); // not from a load notification (a cached tree): already deterministic
        return original(a0, a1, a2, a3, a4, a5);
    };
    // Requests keep their frame relative to the sync point (the first one is the sync point).
    const target = request + ai_start_delay;
    if (now >= target or deferred_len == deferred.len) {
        loadsRow("late", request, now, target);
        userLog("ai     load requested at game frame {d} finished at {d}, after the {d}-frame AI start delay; this AI may start on a different frame between runs", .{ sessionFrame(request), sessionFrame(now), ai_start_delay });
        return original(a0, a1, a2, a3, a4, a5);
    }
    const closure: usize = @intCast(a0);
    const tree: usize = @intCast(a1);
    deferred[deferred_len] = .{ .closure = closure, .tree = tree, .closure_handle = hold(closure), .tree_handle = if (tree != 0) hold(tree) else 0, .request = request, .natural = now, .target = target };
    deferred_len += 1;
}

/// AI starts whose frame has come, in the order their loads finished.
fn releaseDeferred() void {
    if (deferred_len == 0) return;
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(ai_start_original)));
    const now = unityFrame();
    var kept: usize = 0;
    for (deferred[0..deferred_len]) |entry| {
        if (entry.target > now) {
            deferred[kept] = entry;
            kept += 1;
            continue;
        }
        loadsRow("start", entry.request, entry.natural, entry.target);
        original(entry.closure, entry.tree, 0, 0, 0, 0);
        release(entry.closure_handle);
        if (entry.tree_handle != 0) release(entry.tree_handle);
    }
    deferred_len = kept;
}

/// Battle over: AI starts still held are dropped (their battle is gone).
fn dropDeferred() void {
    for (deferred[0..deferred_len]) |entry| {
        release(entry.closure_handle);
        if (entry.tree_handle != 0) release(entry.tree_handle);
    }
    deferred_len = 0;
    notifying_request = null;
}

fn installAiStartHooks(base: usize) !void {
    const manager = try il2cpp.findClass("", "BehaviorAsyncLoadManager");
    const notify = try il2cpp.findMethodAt(manager, "_NotifyOneLoadItem", 1, notify_rva);
    if (try il2cpp.findField(try il2cpp.findClass("", "BehaviorAsyncLoadItem"), "StartFrame") != off_item_start_frame) return error.LoaderLayoutChanged;
    const ai_start = try il2cpp.findMethodAt(try il2cpp.findClass("", "BKOBIBDGHFD"), "BCLGCCJAAEB", 1, ai_start_rva);
    // check both before patching either
    if (!detour.matches(notify, .{ .prologue = &notify_prologue, .shape = .plain })) return error.PrologueMismatch;
    if (!detour.matches(ai_start, .{ .prologue = &ai_start_prologue, .shape = .cmp_rip })) return error.PrologueMismatch;
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, ai_start, .{ .prologue = &ai_start_prologue, .shape = .cmp_rip }, &ai_start_original, aiStartHook);
    _ = try detour.install(&syscall, notify, .{ .prologue = &notify_prologue, .shape = .plain }, &notify_original, notifyHook);
    ai_start_hooked = true;
    log.info("hooked tree-load notify (RVA 0x{X}) and AI start (RVA 0x{X}): enemy AI starts {d} frames after its tree load is requested", .{ notify - base, ai_start - base, ai_start_delay });
}

// --- input clock replay: <recording>.clock ------------------------------------------------------
//
// The Input System reads its clock from two native calls: NativeInputSystem.currentTime (real time)
// and currentTimeOffsetToRealtimeSinceStartup (added to Time.fixedUnscaledTime for fixed updates).
// Event timestamps are compared against them (which update an event is due in, hold and tap
// timing), and ReplayController.QueueEvent re-stamps replayed events as
// `replay start + (event time - first event time)`, in the playback's real time. So the playback's
// input system saw different times than the recording's, and the first move of run 12 landed a
// frame later.
//
// During a session both clocks are frozen per frame (the value of the frame's first read). When
// recording, the frozen values are saved per frame to `<recording>.clock`; when playing, the saved
// values are returned instead, and QueueEvent re-stamps every replayed event with its recorded
// timestamp. Both are moved by one constant (`clock_shift`) so the replayed times sit just after
// the real time the playback starts at: the Input System drops state events older than their
// device's last update, and a recording's times are from earlier in real time, so unshifted they
// dropped the replayed keys (run 13). Differences between times, all the input system acts on
// apart from that check, are exactly the recording's, at any playback speed. When the replay
// stops or the recording's clock runs out, the real clock comes back and the devices' last update
// times are cleared, so the player's own keys work at once. Recordings without a .clock file play
// on the real clock.
//
// The fixed-update clock is Time.fixedUnscaledTime + the offset, and fixedUnscaledTime counts from
// the game's start, so it differs between the recording's and the playback's game session (run 15:
// an AI started 3 frames apart with everything else identical). Version 2 of the file also keeps
// fixedUnscaledTime at each frame's first offset read, and the replayed offset absorbs the
// difference, so the fixed-update clock reads what the recording's did as well.
//
// The two calls are swapped at their icall slots (the `jmp [rip+disp32]` in
// NativeInputRuntime.get_currentTime and get_currentTimeOffsetToRealtimeSinceStartup), so no code
// is patched for them.

extern "kernel32" fn VirtualProtect(*anyopaque, usize, u32, *u32) callconv(.winapi) w.BOOL;

const clock_time_getter_rva: usize = 0x1F63C9C0; // NativeInputRuntime.get_currentTime
const clock_offset_getter_rva: usize = 0x1F63CA90; // NativeInputRuntime.get_currentTimeOffsetToRealtimeSinceStartup
const clock_jmp_at: usize = 0x21; // `48 FF 25 disp32` in both getters
const clock_time_jmp2_at: usize = 0x53; // get_currentTime's second (class-init) path, same slot
const queue_event_rva: usize = 0x1F5AD580;
/// push rbp/rsi/rdi/rbx; sub rsp,0x78; lea rbp,[rsp+0x70] -- position independent.
const queue_event_prologue = [_]u8{ 0x55, 0x56, 0x57, 0x53, 0x48, 0x83, 0xEC, 0x78, 0x48, 0x8D, 0x6C, 0x24, 0x70 };
const off_replay_first_event_time: usize = 0x70; // ReplayController.m_StartTimeAsPerFirstEvent
const off_replay_runtime_time: usize = 0x80; // ReplayController.m_StartTimeAsPerRuntime
const off_device_last_update: usize = 0x148; // InputDevice.m_LastUpdateTimeInternal
/// Replayed times start this far after the real time at the sync point.
const clock_shift_margin: f64 = 1.0;
const clock_capacity: usize = 1 << 20; // frames (4.8 h at 60 fps)
const clock_magic = "TASCLK2\n"; // + frames x f64 fixedUnscaledTime
const clock_magic_v1 = "TASCLK1\n";

const ClockFn = *const fn () callconv(.c) f64;

const Clock = struct {
    slot: *usize = undefined,
    real: ClockFn = undefined,
    /// true for currentTime (extrapolated past the recording), false for the offset (held)
    advances: bool,
    frame: i32 = -1,
    value: f64 = 0,
    last_frame: i32 = -1,
    last_value: f64 = 0,
    values: []f64 = &.{},
};

var clock_time: Clock = .{ .advances = true };
var clock_offset: Clock = .{ .advances = false };
var clock_hooked = false;
var queue_event_original: u64 = 0;
var clock_mode: enum { off, record, play } = .off;
var clock_frames: usize = 0; // record: frames written; play: frames loaded
var clock_misses: u32 = 0; // play: frames inside the recording with no saved value
var clock_shift: f64 = 0; // play: added to every replayed time
/// Time.fixedUnscaledTime at each frame's first offset read (record), or as recorded (play; NaN
/// for a version 1 file, which then gets no correction).
var clock_fixed: []f64 = &.{};

fn timeDirect(m: M) f64 {
    const info = methods.get(m);
    const code: *const fn (usize) callconv(.c) f32 = @ptrFromInt(@as(*const usize, @ptrFromInt(info)).*);
    return code(info);
}

fn frameCountDirect() i32 {
    const info = methods.get(.time_frame);
    const code: *const fn (usize) callconv(.c) i32 = @ptrFromInt(@as(*const usize, @ptrFromInt(info)).*);
    return code(info);
}

fn clockRead(c: *Clock) f64 {
    if (clock_mode == .off or GetCurrentThreadId() != main_thread) return c.real();
    if (session.sync and session.sync_unity == null) return c.real();
    const f = frameCountDirect() - baseFrame();
    if (f < 0) return c.real();
    if (f == c.frame) return c.value;
    c.frame = f;
    const index: usize = @intCast(f);
    var v: f64 = 0;
    switch (clock_mode) {
        .record => {
            v = c.real();
            if (index < c.values.len) {
                c.values[index] = v;
                if (c == &clock_offset and index < clock_fixed.len) clock_fixed[index] = timeDirect(.time_fixed_unscaled);
                clock_frames = @max(clock_frames, index + 1);
            }
        },
        .play => {
            if (index < clock_frames and index < c.values.len and !std.math.isNan(c.values[index])) {
                v = c.values[index] + clock_shift;
                if (c == &clock_offset and index < clock_fixed.len and !std.math.isNan(clock_fixed[index]))
                    v += clock_fixed[index] - timeDirect(.time_fixed_unscaled);
            } else {
                if (index < clock_frames) clock_misses += 1;
                v = if (c.last_frame < 0) c.real() else if (c.advances)
                    c.last_value + @as(f64, @floatFromInt(f - c.last_frame)) / @as(f64, @floatFromInt(session.fps))
                else
                    c.last_value;
            }
        },
        .off => unreachable,
    }
    c.last_frame = f;
    c.last_value = v;
    c.value = v;
    return v;
}

fn clockTimeHook() callconv(.c) f64 {
    return clockRead(&clock_time);
}

fn clockOffsetHook() callconv(.c) f64 {
    return clockRead(&clock_offset);
}

/// Replayed events keep their recorded timestamps: QueueEvent computes
/// `time - m_StartTimeAsPerFirstEvent + m_StartTimeAsPerRuntime`, so the two are made equal.
fn queueEventHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(queue_event_original)));
    if (clock_mode == .play and a0 != 0) {
        const controller: usize = @intCast(a0);
        @as(*align(1) f64, @ptrFromInt(controller + off_replay_runtime_time)).* = @as(*align(1) const f64, @ptrFromInt(controller + off_replay_first_event_time)).* + clock_shift;
    }
    original(a0, a1, a2, a3, a4, a5);
}

fn clockReset(c: *Clock) void {
    c.frame = -1;
    c.last_frame = -1;
    if (c.values.len > 0) std.heap.page_allocator.free(c.values);
    c.values = &.{};
}

fn clockStop() void {
    clock_mode = .off;
    clockReset(&clock_time);
    clockReset(&clock_offset);
    if (clock_fixed.len > 0) std.heap.page_allocator.free(clock_fixed);
    clock_fixed = &.{};
    clock_frames = 0;
    clock_misses = 0;
    clock_shift = 0;
}

/// Play: fix the shift from the real clock now and the recording's first clock value.
fn clockBeginReplay() void {
    if (clock_mode != .play) return;
    for (clock_time.values[0..clock_frames]) |v| if (!std.math.isNan(v)) {
        clock_shift = clock_time.real() + clock_shift_margin - v;
        break;
    };
    clock_time.frame = -1;
    clock_offset.frame = -1;
    log.info("input clock replay shifted by {d:.3} s", .{clock_shift});
}

/// Play over (hotkey, end of the recording's clock, end of battle): back to the real clock, and
/// the devices' last update times cleared so real events are not dropped as older than the replay's.
fn clockEndReplay() void {
    if (clock_mode != .play) return;
    clockStop();
    for ([_]M{ .keyboard_current, .mouse_current, .gamepad_current }) |m| {
        const device = call(m, 0, &.{}) catch continue;
        if (device != 0) @as(*align(1) f64, @ptrFromInt(device + off_device_last_update)).* = 0;
    }
}

fn clockAlloc() bool {
    clock_time.values = std.heap.page_allocator.alloc(f64, clock_capacity) catch return false;
    clock_offset.values = std.heap.page_allocator.alloc(f64, clock_capacity) catch {
        clockReset(&clock_time);
        return false;
    };
    clock_fixed = std.heap.page_allocator.alloc(f64, clock_capacity) catch {
        clockReset(&clock_time);
        clockReset(&clock_offset);
        return false;
    };
    @memset(clock_time.values, std.math.nan(f64));
    @memset(clock_offset.values, std.math.nan(f64));
    @memset(clock_fixed, std.math.nan(f64));
    return true;
}

fn clockPath(buffer: *Path, file: []const u8) ?[*:0]const u8 {
    const s = std.fmt.bufPrintZ(buffer, "{s}.clock", .{file}) catch return null;
    return s.ptr;
}

fn clockStartRecord() void {
    clockStop();
    if (!clock_hooked or !clockAlloc()) return;
    clock_mode = .record;
}

/// `<recording>.clock`: magic, u32 frames, u32 0, then frames x f64 currentTime, frames x f64 offset,
/// frames x f64 fixedUnscaledTime (version 2 only).
fn clockSave(file: []const u8) bool {
    if (clock_mode != .record) return false;
    var path: Path = undefined;
    const handle = CreateFileA(clockPath(&path, file) orelse return false, GENERIC_WRITE, 1, null, CREATE_ALWAYS, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(handle);
    var header: [16]u8 = undefined;
    @memcpy(header[0..8], clock_magic);
    std.mem.writeInt(u32, header[8..12], @intCast(clock_frames), .little);
    std.mem.writeInt(u32, header[12..16], 0, .little);
    var written: u32 = 0;
    if (WriteFile(handle, &header, header.len, &written, null) == .FALSE) return false;
    for ([_][]f64{ clock_time.values[0..clock_frames], clock_offset.values[0..clock_frames], clock_fixed[0..clock_frames] }) |block| {
        const bytes = std.mem.sliceAsBytes(block);
        if (bytes.len > 0 and WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) == .FALSE) return false;
    }
    return true;
}

/// Loads `<recording>.clock`; false (real clock) when there is none.
fn clockStartPlay(file: []const u8) bool {
    clockStop();
    if (!clock_hooked) return false;
    var path: Path = undefined;
    const handle = CreateFileA(clockPath(&path, file) orelse return false, GENERIC_READ, 1, null, OPEN_EXISTING, 0x80, null);
    if (handle == w.INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(handle);
    var header: [16]u8 = undefined;
    var got: u32 = 0;
    if (ReadFile(handle, &header, header.len, &got, null) == .FALSE or got != header.len) return false;
    const v2 = std.mem.eql(u8, header[0..8], clock_magic);
    if (!v2 and !std.mem.eql(u8, header[0..8], clock_magic_v1)) return false;
    const frames: usize = std.mem.readInt(u32, header[8..12], .little);
    if (frames > clock_capacity or !clockAlloc()) return false;
    const blocks = [_][]f64{ clock_time.values[0..frames], clock_offset.values[0..frames], clock_fixed[0..frames] };
    for (blocks[0..if (v2) 3 else 2]) |block| {
        const bytes = std.mem.sliceAsBytes(block);
        if (bytes.len > 0 and (ReadFile(handle, bytes.ptr, @intCast(bytes.len), &got, null) == .FALSE or got != bytes.len)) {
            clockStop();
            return false;
        }
    }
    clock_frames = frames;
    clock_mode = .play;
    return true;
}

/// The icall slot a getter jumps through, after checking the `jmp [rip+disp32]` is where expected.
fn icallSlot(getter: usize, at: usize) !*usize {
    const code: [*]const u8 = @ptrFromInt(getter + at);
    if (code[0] != 0x48 or code[1] != 0xFF or code[2] != 0x25) return error.ClockGetterChanged;
    const disp = std.mem.readInt(i32, code[3..7], .little);
    const slot: usize = @intCast(@as(isize, @intCast(getter + at + 7)) + disp);
    return @ptrFromInt(slot);
}

fn swapSlot(slot: *usize, replacement: usize) !usize {
    var old: u32 = 0;
    if (VirtualProtect(slot, 8, 0x04, &old) == .FALSE) return error.SlotProtect; // PAGE_READWRITE
    const previous = @atomicRmw(usize, slot, .Xchg, replacement, .seq_cst);
    var ignored: u32 = 0;
    _ = VirtualProtect(slot, 8, old, &ignored);
    return previous;
}

fn installInputClock(base: usize) !void {
    const runtime = try il2cpp.findClass("UnityEngine.InputSystem.LowLevel", "NativeInputRuntime");
    const time_getter = try il2cpp.findMethodAt(runtime, "get_currentTime", 0, clock_time_getter_rva);
    const offset_getter = try il2cpp.findMethodAt(runtime, "get_currentTimeOffsetToRealtimeSinceStartup", 0, clock_offset_getter_rva);
    const replay = try il2cpp.findClass("", "ReplayController");
    const queue_event = try il2cpp.findMethodAt(replay, "QueueEvent", 1, queue_event_rva);
    if (try il2cpp.findField(replay, "m_StartTimeAsPerFirstEvent") != off_replay_first_event_time) return error.ReplayLayoutChanged;
    if (try il2cpp.findField(replay, "m_StartTimeAsPerRuntime") != off_replay_runtime_time) return error.ReplayLayoutChanged;
    if (try il2cpp.findField(try il2cpp.findClass("UnityEngine.InputSystem", "InputDevice"), "m_LastUpdateTimeInternal") != off_device_last_update) return error.DeviceLayoutChanged;
    const time_slot = try icallSlot(time_getter, clock_jmp_at);
    if (try icallSlot(time_getter, clock_time_jmp2_at) != time_slot) return error.ClockGetterChanged;
    const offset_slot = try icallSlot(offset_getter, clock_jmp_at);
    if (time_slot.* == 0 or offset_slot.* == 0) return error.ClockSlotEmpty;
    if (!detour.matches(queue_event, .{ .prologue = &queue_event_prologue, .shape = .plain })) return error.PrologueMismatch;

    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, queue_event, .{ .prologue = &queue_event_prologue, .shape = .plain }, &queue_event_original, queueEventHook);
    clock_time.slot = time_slot;
    clock_offset.slot = offset_slot;
    clock_time.real = @ptrFromInt(try swapSlot(time_slot, @intFromPtr(&clockTimeHook)));
    clock_offset.real = @ptrFromInt(swapSlot(offset_slot, @intFromPtr(&clockOffsetHook)) catch |err| {
        _ = swapSlot(time_slot, @intFromPtr(clock_time.real)) catch {};
        return err;
    });
    clock_hooked = true;
    log.info("input clock hooked (slots at RVA 0x{X} and 0x{X}, QueueEvent at RVA 0x{X})", .{ @intFromPtr(time_slot) - base, @intFromPtr(offset_slot) - base, queue_event - base });
}

// --- sync point: the first behaviour-tree load request ------------------------------------------
//
// The battle's awake comes before its loading, and how many frames that loading takes follows
// real time: run 13-2's playback finished loading 2 frames sooner than its recording, and every
// later event (intro, battle start, AI loads) came 2 frames sooner too, while the inputs replayed
// on frames counted from the awake. Everything after loading kept the same frame offsets, and the
// first behaviour-tree load request (BehaviorManager.TryLoadBehavior, entities being set up) comes
// at a fixed offset from it. So inputs (the trace's Enable / the replay's PlayAllFramesOneByOne),
// the input clock table and the reseeds count from the frame of that request. Recordings made
// before this have no `sync=` line and still count from the awake.

const try_load_rva: usize = 0x6908680;
/// push r15/r14/r12/rsi/rdi/rbx; sub rsp,0x28; mov r15,r9 -- position independent.
const try_load_prologue = [_]u8{ 0x41, 0x57, 0x41, 0x56, 0x41, 0x54, 0x56, 0x57, 0x53, 0x48, 0x83, 0xEC, 0x28, 0x4D, 0x89, 0xCF };
/// No request by this game frame: start the inputs anyway (logged).
const sync_wait_limit: i32 = 600;
var try_load_original: u64 = 0;
var sync_hooked = false;

/// The Unity frame session frames count from: the sync point once seen, else the awake.
fn baseFrame() i32 {
    return session.sync_unity orelse session.frame0;
}

fn tryLoadHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) u64 {
    const original: *const fn (u64, u64, u64, u64, u64, u64) callconv(.c) u64 = @ptrFromInt(@as(usize, @intCast(try_load_original)));
    if (ready and session.mode != .off and session.sync and session.sync_unity == null and GetCurrentThreadId() == main_thread) {
        session.sync_unity = unityFrame();
        log.info("sync point: first behaviour-tree load at game frame {d}", .{session.sync_unity.? - session.frame0});
    }
    if (ready and session.mode != .off and btloads_log.file != null and GetCurrentThreadId() == main_thread) logTreeLoad(@intCast(a2));
    return original(a0, a1, a2, a3, a4, a5);
}

/// Diagnostic (run 24: an AI started on the same frame with a different tree, owner
/// 4510302941933662727 in the recording and 1911213611541452930 in a playback): which object
/// asked for which tree, the generator state at that moment, and the call stack (GameAssembly
/// RVAs), so a recording and a playback can be compared request by request.
fn logTreeLoad(behavior: usize) void {
    var owner_buf: [96]u8 = undefined;
    var external_buf: [96]u8 = undefined;
    var owner: []const u8 = "";
    var external: []const u8 = "";
    if (behavior != 0) {
        if (call(.object_name, behavior, &.{})) |name| {
            owner = managedString(name, &owner_buf);
        } else |_| {}
        const asset = readUsize(behavior + off_behavior_external);
        if (asset != 0) {
            if (call(.object_name, asset, &.{})) |name| {
                external = managedString(name, &external_buf);
            } else |_| {}
        }
    }
    const state = randomState();
    var stack_buf: [512]u8 = undefined;
    var len: usize = 0;
    var frames = [_]usize{0} ** 24;
    const n = RtlCaptureStackBackTrace(1, frames.len, &frames, null);
    const base = il2cpp.gameBase() catch 0;
    for (frames[0..n]) |address| {
        if (base == 0 or address <= base or address - base >= 0x30000000) continue;
        const piece = std.fmt.bufPrint(stack_buf[len..], "{s}0x{X}", .{ if (len == 0) "" else ";", address - base }) catch break;
        len += piece.len;
    }
    btloads_log.emit("{d}\t{s}\t{s}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{x:0>8}\t{s}\n", .{ current_frame, owner, external, state[0], state[1], state[2], state[3], stack_buf[0..len] });
}

const off_behavior_external: usize = 0x60; // Behavior._externalBehavior

/// Recording: the trace starts taking events; playing: the replay starts feeding frames. Called
/// from frame() at the end of the sync frame, so the first input frame is the one after it.
fn startInputs() !void {
    if (session.inputs_started) return;
    session.inputs_started = true;
    if (session.game_clocks) timeVirtualStart();
    switch (session.mode) {
        .record => _ = try call(.trace_enable, session.trace, &.{}),
        .play => {
            clockBeginReplay();
            _ = try call(.replay_frames, session.controller, &.{});
        },
        .off => {},
    }
}

fn installSyncHook(base: usize) !void {
    const manager = try il2cpp.findClass("BehaviorDesigner.Runtime", "BehaviorManager");
    const target = try il2cpp.findMethodAt(manager, "TryLoadBehavior", 3, try_load_rva);
    if (try il2cpp.findField(try il2cpp.findClass("BehaviorDesigner.Runtime", "Behavior"), "_externalBehavior") != off_behavior_external) return error.BehaviorLayoutChanged;
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, target, .{ .prologue = &try_load_prologue, .shape = .plain }, &try_load_original, tryLoadHook);
    sync_hooked = true;
    log.info("hooked BehaviorManager::TryLoadBehavior at RVA 0x{X}: inputs start at the first behaviour-tree load", .{target - base});
}

// --- deterministic Unity clocks ------------------------------------------------------------------
//
// Game code reads Unity's clocks directly, and three things about them differ between a recording
// and its playback:
//   - Time.realtimeSinceStartup is real time. 638 call sites in 414 methods read it (DOTween's
//     timescale-independent tweens, Foundation.Coroutine.CoroutineManager, budgeted loading), so
//     anything timed by it ends a frame early or late depending on how fast frames ran. The first
//     move after battle start (a 0.75 s unlock) came 45 or 46 frames after it run to run, also in
//     plain recordings.
//   - Time.time, unscaledTime, fixedTime, fixedUnscaledTime are game time, but counted from the
//     game's launch, so their float32 values round differently in another game session (a timer
//     ending exactly on a frame can go either way).
//   - timeSinceLevelLoad counts from the scene load, which comes a varying number of frames before
//     the sync point.
// From the sync point on, realtimeSinceStartup advances exactly one frame per frame (frozen within
// a frame), and every clock is moved to start at a value K on the float grid of the binade
// [16384, 32768) (multiples of 2^-9, that binade's float spacing; K = 16384 unless the clock is
// already past it). Float rounding is then the same in every recording and playback, whatever the
// launch time, and every clock keeps its frame-to-frame progress. The move is always forward. After
// the session realtime goes back to following real time and the game-time clocks keep their offset,
// so nothing jumps back (timeSinceLevelLoad, used only inside a session, returns to the real one).
// Each getter is swapped at its icall slot, like the input clock.

const TimeFamily = enum { scaled, unscaled, level, realtime };
const TimeGetter = struct { name: []const u8, rva: usize, double: bool, family: TimeFamily, source: usize };

/// `source`: the getter whose double value is the clock's true value (itself for the double ones).
const time_getters = [_]TimeGetter{
    .{ .name = "get_time", .rva = 0x1FD6B260, .double = false, .family = .scaled, .source = 1 },
    .{ .name = "get_timeAsDouble", .rva = 0x1FD6B270, .double = true, .family = .scaled, .source = 1 },
    .{ .name = "get_timeSinceLevelLoad", .rva = 0x1FD6B280, .double = false, .family = .level, .source = 1 },
    .{ .name = "get_fixedTime", .rva = 0x1FD6B2B0, .double = false, .family = .scaled, .source = 4 },
    .{ .name = "get_fixedTimeAsDouble", .rva = 0x1FD6B2C0, .double = true, .family = .scaled, .source = 4 },
    .{ .name = "get_unscaledTime", .rva = 0x1FD6B2D0, .double = false, .family = .unscaled, .source = 6 },
    .{ .name = "get_unscaledTimeAsDouble", .rva = 0x1FD6B2E0, .double = true, .family = .unscaled, .source = 6 },
    .{ .name = "get_fixedUnscaledTime", .rva = 0x1FD6B2F0, .double = false, .family = .unscaled, .source = 8 },
    .{ .name = "get_fixedUnscaledTimeAsDouble", .rva = 0x1FD6B320, .double = true, .family = .unscaled, .source = 8 },
    .{ .name = "get_realtimeSinceStartup", .rva = 0x1FD6B3D0, .double = false, .family = .realtime, .source = 9 },
};
const time_binade_low: f64 = 16384.0;
const time_binade_high: f64 = 32768.0;
const time_grid: f64 = 512.0; // 1 / 2^-9
const time_margin: f64 = 1.0;

var time_real = [_]usize{0} ** time_getters.len;
var time_hooked = false;
var time_started = false; // a session has moved the clocks at least once
var time_active = false; // inside a session, after its sync point
var time_offset = std.enums.EnumArray(TimeFamily, f64).initFill(0);
var rt_base: f64 = 0; // realtime at the sync frame
var rt_frame0: i32 = 0;
var rt_last: f64 = 0; // last main-thread realtime value, for other threads

fn timeTrue(i: usize) f64 {
    if (time_getters[i].double) {
        const f: *const fn () callconv(.c) f64 = @ptrFromInt(time_real[i]);
        return f();
    }
    const f: *const fn () callconv(.c) f32 = @ptrFromInt(time_real[i]);
    return f();
}

fn timeValue(comptime i: usize) f64 {
    const g = time_getters[i];
    switch (g.family) {
        .realtime => {
            if (time_active) {
                if (GetCurrentThreadId() != main_thread) return rt_last;
                rt_last = rt_base + @as(f64, @floatFromInt(frameCountDirect() - rt_frame0)) / @as(f64, @floatFromInt(session.fps));
                return rt_last;
            }
            return timeTrue(i) + time_offset.get(.realtime);
        },
        .level => {
            if (!time_active) return timeTrue(i);
            return timeTrue(g.source) + time_offset.get(.level);
        },
        else => {
            if (!time_started) return timeTrue(i);
            return timeTrue(g.source) + time_offset.get(g.family);
        },
    }
}

fn timeHook(comptime i: usize) usize {
    if (time_getters[i].double) return @intFromPtr(&struct {
        fn f() callconv(.c) f64 {
            return timeValue(i);
        }
    }.f);
    return @intFromPtr(&struct {
        fn f() callconv(.c) f32 {
            return @floatCast(timeValue(i));
        }
    }.f);
}

fn timeK(current: f64) f64 {
    return @ceil(@max(current + time_margin, time_binade_low) * time_grid) / time_grid;
}

/// At the sync point: move every clock forward onto the grid.
fn timeVirtualStart() void {
    if (!time_hooked) return;
    const families = [_]struct { TimeFamily, usize }{ .{ .scaled, 1 }, .{ .unscaled, 6 }, .{ .level, 1 } };
    for (families) |entry| {
        const family, const source = entry;
        const true_now = timeTrue(source);
        const visible = if (family == .level) timeTrue(2) else if (time_started) true_now + time_offset.get(family) else true_now;
        time_offset.set(family, timeK(visible) - true_now);
    }
    const rt_visible = timeTrue(9) + (if (time_started) time_offset.get(.realtime) else 0);
    rt_base = timeK(rt_visible);
    rt_frame0 = frameCountDirect();
    rt_last = rt_base;
    time_started = true;
    time_active = true;
    if (rt_base + 4 * 3600.0 > time_binade_high) userLog("{t}   game clocks are past {d:.0} s; recordings made now may round time differently from earlier ones (restart the game)", .{ session.mode, rt_base });
    log.info("game clocks moved: time {d:.3}, unscaled {d:.3}, realtime {d:.3}", .{ timeTrue(1) + time_offset.get(.scaled), timeTrue(6) + time_offset.get(.unscaled), rt_base });
}

/// Session over: realtime follows real time again, continuing from where it is.
fn timeVirtualEnd() void {
    if (!time_active) return;
    const now = rt_base + @as(f64, @floatFromInt(frameCountDirect() - rt_frame0)) / @as(f64, @floatFromInt(session.fps));
    time_offset.set(.realtime, now - timeTrue(9));
    time_active = false;
}

fn installTimeClocks(base: usize) !void {
    const time_class = try il2cpp.findClass("UnityEngine", "Time");
    var slots: [time_getters.len]*usize = undefined;
    inline for (time_getters, 0..) |g, i| {
        const method = try il2cpp.findMethodAt(time_class, g.name, 0, g.rva);
        slots[i] = try icallSlot(method, 0);
        if (slots[i].* == 0) return error.ClockSlotEmpty;
    }
    inline for (time_getters, 0..) |_, i| {
        time_real[i] = swapSlot(slots[i], timeHook(i)) catch |err| {
            inline for (0..i) |k| _ = swapSlot(slots[k], time_real[k]) catch {};
            return err;
        };
    }
    time_hooked = true;
    log.info("Unity clocks hooked ({d} getters, realtimeSinceStartup slot at RVA 0x{X})", .{ time_getters.len, @intFromPtr(slots[9]) - base });
}

// --- pin_team: the team setup on a fixed frame after the sync point ------------------------------
//
// After the sync point the team system (KLHKKPJMGLL) sets the team up in one frame: 96-104 default
// modifiers, the stat slots, team passives and listeners. It runs when the team's entities are
// ready, which waits on real-time asset loading (stack from run 22-2: a coroutine-driven frame
// phase -> an ECS system's handler -> KLHKKPJMGLL::ICCDKMJBFGB -> FBGCHIJBJKC(team list) -> the
// level graph). So its frame varied, 4 to 50 frames after sync, and every agent passive and
// resource timer moved with it against the inputs (run 21-3: 32, 34 and 50 frames). With
// `pin_team = on` the call is held until `team_setup_frame` frames after the sync point and made
// from frame(), as the AI starts are. ICCDKMJBFGB is static with no arguments and reads the team
// lists from the team manager when it runs, so holding it needs no saved state. A setup arriving
// after that frame runs at once and is logged as late.

const team_setup_rva: usize = 0x16118970;
/// push rsi/rdi; sub rsp,0x28; then the class-initialised `cmp byte [rip+x],0`.
const team_setup_prologue = [_]u8{ 0x56, 0x57, 0x48, 0x83, 0xEC, 0x28 };
const team_setup_frame: i32 = 90;
var team_setup_original: u64 = 0;
var team_setup_hooked = false;
var team_setup_pending: u32 = 0;

fn teamSetupHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(team_setup_original)));
    if (!ready or session.mode == .off or !session.pin_team or session.sync_unity == null or GetCurrentThreadId() != main_thread)
        return original(a0, a1, a2, a3, a4, a5);
    const now = unityFrame();
    const rel = now - baseFrame();
    if (rel == team_setup_frame) {
        loadsRow("team-start", now, now, baseFrame() + team_setup_frame); // pin_spawn resumed the manager this frame
        return original(a0, a1, a2, a3, a4, a5);
    }
    if (rel > team_setup_frame) {
        loadsRow("team-late", now, now, baseFrame() + team_setup_frame);
        userLog("team   setup arrived at frame {d} after sync, after the pinned frame {d}; this run's team timers may be off", .{ rel, team_setup_frame });
        return original(a0, a1, a2, a3, a4, a5);
    }
    team_setup_pending += 1;
    loadsRow("team-held", now, now, baseFrame() + team_setup_frame);
}

fn releaseTeamSetup(rel: i32) void {
    if (rel < team_setup_frame) return;
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(team_setup_original)));
    const count = team_setup_pending;
    team_setup_pending = 0;
    if (count > 1) userLog("team   setup was requested {d} times before frame {d}; all are run now", .{ count, team_setup_frame });
    for (0..count) |_| {
        loadsRow("team-start", unityFrame(), unityFrame(), baseFrame() + team_setup_frame);
        original(0, 0, 0, 0, 0, 0);
    }
}

fn installTeamSetupHook(base: usize) !void {
    const target = try il2cpp.findMethodAt(try il2cpp.findClass("", "KLHKKPJMGLL"), "ICCDKMJBFGB", 0, team_setup_rva);
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, target, .{ .prologue = &team_setup_prologue, .shape = .cmp_rip }, &team_setup_original, teamSetupHook);
    team_setup_hooked = true;
    log.info("hooked KLHKKPJMGLL::ICCDKMJBFGB at RVA 0x{X}: pin_team holds the team setup to frame {d} after sync", .{ target - base, team_setup_frame });
}

// --- pin_spawn: pause the entity manager's tick from the sync point to frame 90 ---------------
//
// pin_team (run 23) put the team setup on frame 90, but the intro and its timers still came a
// frame apart: they hang off the same moment, the entity manager (IDBODLAJBDJ::HFOHNJIKEAH, run
// every frame) activating the team's entities once their assets have loaded, which hands an
// entity event to every listener (CGACLGJNHGA::AJGKIGJBCOI -> callback wrapper -> the team
// system, the intro, ...). With `pin_spawn = on` that tick is skipped from the sync point until
// `team_setup_frame` frames after it, so whatever finished loading in between is activated by
// the first tick at that frame, on the same frame in every run. If the tick also starts those
// loads, they start late instead and the team setup arrives after the frame (tas-loads.tsv
// `team-late`, tas-log.txt): then this approach does not work. Experimental.

const spawn_tick_rva: usize = 0x16823E60;
/// push rbp/r15/r14/r12/rsi/rdi/rbx; sub rsp,0xd0 -- position independent (17 bytes).
const spawn_tick_prologue = [_]u8{ 0x55, 0x41, 0x57, 0x41, 0x56, 0x41, 0x54, 0x56, 0x57, 0x53, 0x48, 0x81, 0xEC, 0xD0, 0x00, 0x00, 0x00 };
var spawn_tick_original: u64 = 0;
var spawn_tick_hooked = false;

fn spawnTickHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(spawn_tick_original)));
    if (!ready or session.mode == .off or !session.pin_spawn or session.sync_unity == null or session.spawn_resumed or GetCurrentThreadId() != main_thread)
        return original(a0, a1, a2, a3, a4, a5);
    const now = unityFrame();
    if (now - baseFrame() < team_setup_frame) {
        if (!session.spawn_held) {
            session.spawn_held = true;
            loadsRow("spawn-hold", now, now, baseFrame() + team_setup_frame);
        }
        return;
    }
    session.spawn_resumed = true;
    loadsRow("spawn-resume", now, now, baseFrame() + team_setup_frame);
    original(a0, a1, a2, a3, a4, a5);
}

fn installSpawnTickHook(base: usize) !void {
    const target = try il2cpp.findMethodAt(try il2cpp.findClass("", "IDBODLAJBDJ"), "HFOHNJIKEAH", 0, spawn_tick_rva);
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, target, .{ .prologue = &spawn_tick_prologue, .shape = .plain }, &spawn_tick_original, spawnTickHook);
    spawn_tick_hooked = true;
    log.info("hooked IDBODLAJBDJ::HFOHNJIKEAH at RVA 0x{X}: pin_spawn pauses it from sync to frame {d}", .{ target - base, team_setup_frame });
}

// --- battle lifecycle: own hooks, clear of thaumiel's ---------------------------------------------
//
// thaumiel (the logger build) hooks BattleStatsSubsystem.OnAwake / OnDestroy and the level time
// manager's step, so this DLL uses two methods it leaves alone: BattleStatsSubsystem.OnUpdate
// (battle only; its first call starts the session, every call is the per-frame step) and the AI
// subsystem's OnDestroy (IOMGMDHDGON, torn down with the battle) to end it. A battle that ends
// without the latter is still closed when the next one starts.

const battle_update_rva: usize = 0x16A61F70;
/// push rsi; sub rsp,0x20; mov rsi,rcx; then the class-initialised `cmp byte [rip+x],0`.
const battle_update_prologue = [_]u8{ 0x56, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x89, 0xCE };
const ai_destroy_rva: usize = 0x17C51B30;
/// push rsi/rdi; sub rsp,0x28; mov rsi,rcx; then the class-initialised `cmp byte [rip+x],0`.
const ai_destroy_prologue = [_]u8{ 0x56, 0x57, 0x48, 0x83, 0xEC, 0x28, 0x48, 0x89, 0xCE };
var battle_update_original: u64 = 0;
var ai_destroy_original: u64 = 0;
var in_battle = false;

fn battleUpdateHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(battle_update_original)));
    if (ready) {
        if (!in_battle) {
            in_battle = true;
            battleAwake();
        }
        if (session.mode != .off) {
            const unity = frameCountDirect();
            frame(GetTickCount64() - session_t0, unity - session.frame0, 0);
        }
    }
    original(a0, a1, a2, a3, a4, a5);
}

fn aiDestroyHook(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) void {
    const original: Hook6 = @ptrFromInt(@as(usize, @intCast(ai_destroy_original)));
    if (ready and in_battle) {
        in_battle = false;
        battleDestroy();
    }
    original(a0, a1, a2, a3, a4, a5);
}

fn installBattleHooks(base: usize) !void {
    const update = try il2cpp.findMethodAt(try il2cpp.findClass("MoleMole", "BattleStatsSubsystem"), "OnUpdate", 0, battle_update_rva);
    const destroy = try il2cpp.findMethodAt(try il2cpp.findClass("", "IOMGMDHDGON"), "OnDestroy", 0, ai_destroy_rva);
    if (!detour.matches(update, .{ .prologue = &battle_update_prologue, .shape = .cmp_rip })) return error.BattleUpdatePrologue;
    if (!detour.matches(destroy, .{ .prologue = &ai_destroy_prologue, .shape = .cmp_rip })) return error.AiDestroyPrologue;
    var syscall: nt.Syscall = .init;
    _ = try detour.install(&syscall, update, .{ .prologue = &battle_update_prologue, .shape = .cmp_rip }, &battle_update_original, battleUpdateHook);
    _ = try detour.install(&syscall, destroy, .{ .prologue = &ai_destroy_prologue, .shape = .cmp_rip }, &ai_destroy_original, aiDestroyHook);
    log.info("battle hooks: BattleStatsSubsystem.OnUpdate at RVA 0x{X}, IOMGMDHDGON.OnDestroy at RVA 0x{X}", .{ update - base, destroy - base });
}

fn seedText(buffer: []u8, seed: ?i32) []const u8 {
    return if (seed) |s| std.fmt.bufPrint(buffer, "{d}", .{s}) catch "?" else "none";
}

/// First battle-update of a battle, on the game thread.
fn battleAwake() void {
    if (!ready) return;
    if (session.mode != .off) finish("a new battle started first");
    var buffer: [8192]u8 = undefined;
    const text = readSmallFile(config_file, &buffer) orelse return;
    const config = parseConfig(text);
    if (config.mode == .off) return;
    session = .{ .mode = config.mode, .speed = config.speed };
    openSessionDir(config.mode);
    trees_len = 0;
    current_frame = 0;
    main_thread = GetCurrentThreadId();
    dropDeferred();
    team_setup_pending = 0;
    const result = switch (config.mode) {
        .record => beginRecord(&config),
        .play => beginPlay(&config),
        .off => unreachable,
    };
    result catch |err| {
        log.err("{t} not started: {t}", .{ config.mode, err });
        userLog("{t} {s}: NOT STARTED ({t})", .{ config.mode, session.path(), err });
        abort();
        return;
    };
    openFrames();
    var seed_buffer: [16]u8 = undefined;
    const seed = seedText(&seed_buffer, session.seed);
    log.info("{t} {s}: fps {d}, speed {d}, seed {s}, reseed {t}, start frame {d}", .{ session.mode, session.path(), session.fps, session.speed, seed, session.reseed, session.frame0 });
    const clock_note: []const u8 = switch (clock_mode) {
        .record => " clock=recorded",
        .play => " clock=replayed",
        .off => " clock=real",
    };
    userLog("{t} start  {s}  fps={d} speed={d} seed={s} reseed={t}{s}{s}{s}", .{ session.mode, session.path(), session.fps, session.speed, seed, session.reseed, if (session.devices_new) " devices=new" else "", clock_note, if (session.sync) " sync=bt-load" else "" });
    if (session.game_clocks) userLog("{t}   game_clocks on", .{session.mode});
    if (session.pin_team) userLog("{t}   pin_team on: team setup at frame {d} after sync", .{ session.mode, team_setup_frame });
    if (session.pin_spawn) userLog("{t}   pin_spawn on: entity manager paused from sync to frame {d}", .{ session.mode, team_setup_frame });
    const settings = call(.input_settings, 0, &.{}) catch 0;
    const update_mode: i32 = if (settings != 0) unbox(i32, call(.settings_update_mode, settings, &.{}) catch 0) else -1;
    userLog("{t}   input update mode {d} (1 dynamic, 2 fixed, 3 manual), fixed step {d:.4} s", .{ session.mode, update_mode, timeDirect(.time_fixed_dt) });
}

/// Undo whatever began; used when starting fails half way.
fn abort() void {
    if (session.trace != 0) {
        if (session.mode == .record) _ = call(.trace_disable, session.trace, &.{}) catch {};
        if (session.controller != 0) _ = call(.replay_dispose, session.controller, &.{}) catch {};
        _ = call(.trace_dispose, session.trace, &.{}) catch {};
    }
    release(session.controller_handle);
    release(session.trace_handle);
    restoreTiming();
    closeFrames();
    clockStop();
    timeVirtualEnd();
    session = .{};
}

/// The AI subsystem's OnDestroy during a battle, on the game thread.
fn battleDestroy() void {
    if (!ready or session.mode == .off) return;
    finish("battle ended");
}

fn finish(reason: []const u8) void {
    const frames: i64 = @as(i64, int(.time_frame) catch session.frame0) - baseFrame();
    var seed_buffer: [16]u8 = undefined;
    const seed = seedText(&seed_buffer, session.seed);
    switch (session.mode) {
        .record => {
            _ = call(.trace_disable, session.trace, &.{}) catch {};
            const events = unbox(i64, call(.trace_event_count, session.trace, &.{}) catch 0);
            const path_string = string_new(session.pathZ());
            const saved = path_string != 0 and if (call(.trace_write, session.trace, &.{path_string})) |_| true else |_| false;
            _ = call(.trace_dispose, session.trace, &.{}) catch {};
            if (saved) {
                var info_path: Path = undefined;
                var text: [256]u8 = undefined;
                const info = std.fmt.bufPrint(&text, "client=CNBetaWin3.3.4\r\nfps={d}\r\nseed={s}\r\nreseed={t}\r\nframes={d}\r\nevents={d}\r\nspeed={d}\r\n{s}input_clock={d}\r\ngame_clocks={d}\r\npin_team={d}\r\npin_spawn={d}\r\n", .{ session.fps, seed, session.reseed, frames, events, session.speed, if (session.sync) "sync=bt-load\r\n" else "", @intFromBool(clock_mode == .record), @intFromBool(session.game_clocks), @intFromBool(session.pin_team), @intFromBool(session.pin_spawn) }) catch "";
                if (infoPath(&info_path, session.path())) |p| _ = writeSmallFile(p, info);
                if (clock_mode == .record and !clockSave(session.path())) userLog("record {s}: input clock NOT saved; it will play on the real clock", .{session.path()});
            }
            log.info("record {s} ({s}): {d} frames, {d} events, saved {any}", .{ session.path(), reason, frames, events, saved });
            userLog("record {s}  {s}: {d} frames, {d} events ({s})", .{ if (saved) "saved" else "NOT SAVED", session.path(), frames, events, reason });
        },
        .play => {
            clockEndReplay();
            const finished = !session.stopped and unbox(u8, call(.replay_finished, session.controller, &.{}) catch 0) != 0;
            const position = if (session.stopped) session.stopped_position else unbox(i32, call(.replay_position, session.controller, &.{}) catch 0);
            if (!session.stopped) _ = call(.replay_dispose, session.controller, &.{}) catch {};
            _ = call(.trace_dispose, session.trace, &.{}) catch {};
            log.info("play {s} ({s}): {d} frames (recording {d}), replay finished {any} at event {d} of {d}", .{ session.path(), reason, frames, session.recorded_frames, finished, position, session.recorded_events });
            if (clock_misses > 0) userLog("play   {s}: {d} frames inside the recording had no recorded input clock", .{ session.path(), clock_misses });
            userLog("play   end    {s}: {d} frames (recording had {d}), {s} at event {d} of {d}, seed={s} ({s})", .{ session.path(), frames, session.recorded_frames, if (finished) "replay finished" else if (session.stopped) "replay stopped by hotkey" else "replay NOT finished", position, session.recorded_events, seed, reason });
        },
        .off => {},
    }
    release(session.controller_handle);
    release(session.trace_handle);
    restoreTiming();
    closeFrames();
    clockStop();
    timeVirtualEnd();
    session = .{};
}

test "tas.txt parsing" {
    const config = parseConfig(
        \\# comment line
        \\Mode = Record   # trailing comment
        \\file = "TAS\run 1.inputtrace"
        \\fps = 120
        \\speed = 0.25
        \\seed = 0x10
        \\devices = new
        \\bogus line
        \\unknown = 1
    );
    try std.testing.expectEqual(Mode.record, config.mode);
    try std.testing.expectEqualStrings("TAS\\run 1.inputtrace", config.path());
    try std.testing.expectEqual(@as(u32, 120), config.fps);
    try std.testing.expect(config.fps_set);
    try std.testing.expectEqual(@as(f32, 0.25), config.speed);
    try std.testing.expectEqual(@as(?i32, 16), config.seed);
    try std.testing.expect(config.devices_new);
}

test "tas.txt defaults and rejected values" {
    const config = parseConfig("mode = play\nfps = 5\nspeed = -1\nseed = abc\n");
    try std.testing.expectEqual(Mode.play, config.mode);
    try std.testing.expectEqual(@as(u32, 60), config.fps);
    try std.testing.expect(!config.fps_set);
    try std.testing.expectEqual(@as(f32, 1.0), config.speed);
    try std.testing.expectEqual(@as(?i32, null), config.seed);
    try std.testing.expectEqual(Mode.off, parseConfig("mode = nonsense").mode);
    try std.testing.expectEqual(Mode.off, parseConfig("").mode);
}

test "reseed option and per-frame seeds" {
    try std.testing.expectEqual(@as(?Reseed, .frame), parseConfig("reseed = Frame").reseed);
    try std.testing.expectEqual(@as(?Reseed, .tree), parseConfig("reseed = tree").reseed);
    try std.testing.expectEqual(@as(?Reseed, .start), parseConfig("reseed = start").reseed);
    try std.testing.expectEqual(@as(?Reseed, null), parseConfig("reseed = sometimes").reseed);
    try std.testing.expectEqual(@as(?Reseed, null), parseConfig("mode = record").reseed);
    // deterministic, and different for neighbouring frames and seeds
    try std.testing.expectEqual(frameSeed(42, 100), frameSeed(42, 100));
    try std.testing.expect(frameSeed(42, 100) != frameSeed(42, 101));
    try std.testing.expect(frameSeed(42, 100) != frameSeed(43, 100));
}

test "feature switches" {
    const plain = parseConfig("mode = record");
    try std.testing.expect(!plain.sync and !plain.input_clock and !plain.game_clocks);
    const all = parseConfig("sync = on\ninput_clock = TRUE\ngame_clocks = 1");
    try std.testing.expect(all.sync and all.input_clock and all.game_clocks);
    try std.testing.expect(!parseConfig("sync = off").sync);
    try std.testing.expect(parseConfig("pin_team = on").pin_team);
    try std.testing.expect(parseConfig("pin_spawn = on").pin_spawn);
    try std.testing.expect(!parseConfig("mode = record").pin_team);
}

test "stop_key names" {
    try std.testing.expectEqual(@as(?u8, 0x77), keyCode("F8"));
    try std.testing.expectEqual(@as(?u8, 0x70), keyCode("f1"));
    try std.testing.expectEqual(@as(?u8, 0x87), keyCode("F24"));
    try std.testing.expectEqual(@as(?u8, null), keyCode("F25"));
    try std.testing.expectEqual(@as(?u8, 'K'), keyCode("k"));
    try std.testing.expectEqual(@as(?u8, 0x13), keyCode("Pause"));
    try std.testing.expectEqual(@as(?u8, 0), keyCode("none"));
    try std.testing.expectEqual(@as(?u8, null), keyCode("Escape!"));
    try std.testing.expectEqual(@as(u8, 0x77), parseConfig("mode = play").stop_key);
    try std.testing.expectEqual(@as(u8, 0x7B), parseConfig("stop_key = F12").stop_key);
}
