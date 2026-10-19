//! tas-gui.exe: a small window for the game folder. It edits tas.txt (mode, file, fps, speed, seed,
//! the switches), loads remielle-tas.dll into the game (the Inject button, as tas-inject.exe does)
//! and shows whether the game is running, whether the TAS is in it, and the end of TAS\tas-log.txt.
//! Plain Win32; the manifest (src/tas-gui.manifest) turns on the current control styles and DPI
//! awareness.
const std = @import("std");
const injector = @import("injector.zig");

const HWND = *anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const BOOL = i32;

fn L(comptime s: []const u8) [*:0]const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// --- Win32 ------------------------------------------------------------------------------------

const WndProc = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WndProc,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, x: i32, y: i32, private: u32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const INITCOMMONCONTROLSEX = extern struct { size: u32 = @sizeOf(INITCOMMONCONTROLSEX), icc: u32 };
const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?*anyopaque = null,
    lpstrFilter: ?[*]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: isize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn IsDialogMessageW(HWND, *MSG) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(HWND, [*]u16, i32) callconv(.winapi) i32;
extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn LoadCursorW(?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn LoadIconW(?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetSysColorBrush(i32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetSysColor(i32) callconv(.winapi) u32;
extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, BOOL, u32) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetTextColor(*anyopaque, u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkMode(*anyopaque, i32) callconv(.winapi) i32;
extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn ReadFile(*anyopaque, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(*anyopaque, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileSizeEx(*anyopaque, *i64) callconv(.winapi) BOOL;
extern "kernel32" fn SetFilePointerEx(*anyopaque, i64, ?*i64, u32) callconv(.winapi) BOOL;

const INVALID_HANDLE: usize = std.math.maxInt(usize);
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const SHARE_READ_WRITE: u32 = 0x1 | 0x2;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;

const WM_CREATE: u32 = 0x0001;
const WM_DESTROY: u32 = 0x0002;
const WM_SETFONT: u32 = 0x0030;
const WM_COMMAND: u32 = 0x0111;
const WM_TIMER: u32 = 0x0113;
const WM_CTLCOLORSTATIC: u32 = 0x0138;
const WM_APP: u32 = 0x8000;
const WM_INJECT_STAGE = WM_APP + 1;
const WM_INJECT_DONE = WM_APP + 2;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_TABSTOP: u32 = 0x00010000;
const WS_GROUP: u32 = 0x00020000;
const WS_VSCROLL: u32 = 0x00200000;
const WS_CAPTION: u32 = 0x00C00000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_EX_CLIENTEDGE: u32 = 0x00000200;
const BS_PUSHBUTTON: u32 = 0x0;
const BS_DEFPUSHBUTTON: u32 = 0x1;
const BS_AUTOCHECKBOX: u32 = 0x3;
const BS_GROUPBOX: u32 = 0x7;
const BM_GETCHECK: u32 = 0x00F0;
const BM_SETCHECK: u32 = 0x00F1;
const ES_MULTILINE: u32 = 0x0004;
const ES_AUTOVSCROLL: u32 = 0x0040;
const ES_AUTOHSCROLL: u32 = 0x0080;
const ES_READONLY: u32 = 0x0800;
const EM_SETSEL: u32 = 0x00B1;
const EM_SCROLLCARET: u32 = 0x00B7;
const EM_SETCUEBANNER: u32 = 0x1501;
const CBS_DROPDOWNLIST: u32 = 0x0003;
const CB_ADDSTRING: u32 = 0x0143;
const CB_GETCURSEL: u32 = 0x0147;
const CB_SETCURSEL: u32 = 0x014E;
const COLOR_WINDOW: i32 = 5;
const IDC_ARROW: usize = 32512;
const IDI_APPLICATION: usize = 32512;
const MB_OK_ERROR: u32 = 0x10;
const OFN_FILEMUSTEXIST: u32 = 0x1000;
const OFN_NOCHANGEDIR: u32 = 0x8;

const window_style = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

// --- controls ---------------------------------------------------------------------------------

const Id = enum(u16) { inject = 100, open_folder, mode, file, browse, fps, speed, seed, save, sync, pin_team, pin_spawn, pin_assets, pin_random };

const Switch = struct { id: Id, key: []const u8, label: []const u8 };
const switches = [_]Switch{
    .{ .id = .sync, .key = "sync", .label = "sync: inputs start at the first AI load" },
    .{ .id = .pin_team, .key = "pin_team", .label = "pin_team: team setup on frame 90" },
    .{ .id = .pin_spawn, .key = "pin_spawn", .label = "pin_spawn: intro on frame 90" },
    .{ .id = .pin_assets, .key = "pin_assets", .label = "pin_assets: fixed load times (boss arrival)" },
    .{ .id = .pin_random, .key = "pin_random", .label = "pin_random: fixed bullet and effect seeds" },
};
const modes = [_][]const u8{ "off", "record", "play" };

var hwnd_main: HWND = undefined;
var h_status: HWND = undefined;
var h_detail: HWND = undefined;
var h_inject: HWND = undefined;
var h_mode: HWND = undefined;
var h_file: HWND = undefined;
var h_fps: HWND = undefined;
var h_speed: HWND = undefined;
var h_seed: HWND = undefined;
var h_saved: HWND = undefined;
var h_log: HWND = undefined;
var h_switch: [switches.len]HWND = undefined;
var font: ?*anyopaque = null;
var font_bold: ?*anyopaque = null;
var font_mono: ?*anyopaque = null;
var dpi: i32 = 96;

const Tone = enum { grey, green, orange, red };
var status_tone: Tone = .grey;
var injecting = false;
var log_size: i64 = -1;

var dir_buffer: [1024]u8 = undefined;
var dir: []const u8 = "";

fn px(v: i32) i32 {
    return @divTrunc(v * dpi, 96);
}

fn control(class: [*:0]const u16, text: [*:0]const u16, style: u32, ex: u32, x: i32, y: i32, width: i32, height: i32, id: u16) HWND {
    const h = CreateWindowExW(ex, class, text, WS_CHILD | WS_VISIBLE | style, px(x), px(y), px(width), px(height), hwnd_main, @ptrFromInt(id), GetModuleHandleW(null), null).?;
    _ = SendMessageW(h, WM_SETFONT, @intFromPtr(font), 1);
    return h;
}

fn label(text: [*:0]const u16, x: i32, y: i32, width: i32) HWND {
    return control(L("STATIC"), text, 0, 0, x, y + 3, width, 20, 0);
}

fn group(text: [*:0]const u16, x: i32, y: i32, width: i32, height: i32) void {
    const h = control(L("BUTTON"), text, BS_GROUPBOX, 0, x, y, width, height, 0);
    _ = SendMessageW(h, WM_SETFONT, @intFromPtr(font_bold), 1);
}

fn button(text: [*:0]const u16, x: i32, y: i32, width: i32, id: Id, default: bool) HWND {
    return control(L("BUTTON"), text, WS_TABSTOP | if (default) BS_DEFPUSHBUTTON else BS_PUSHBUTTON, 0, x, y, width, 28, @intFromEnum(id));
}

fn edit(x: i32, y: i32, width: i32, id: Id, cue: [*:0]const u16) HWND {
    const h = control(L("EDIT"), L(""), WS_TABSTOP | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, x, y, width, 24, @intFromEnum(id));
    _ = SendMessageW(h, EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(cue)));
    return h;
}

fn createControls() void {
    // Game
    group(L("Game"), 12, 8, 536, 84);
    h_status = control(L("STATIC"), L("Checking..."), 0, 0, 26, 32, 380, 22, 0);
    _ = SendMessageW(h_status, WM_SETFONT, @intFromPtr(font_bold), 1);
    h_detail = control(L("STATIC"), L(""), 0, 0, 26, 56, 380, 30, 0);
    h_inject = button(L("Inject"), 424, 28, 110, .inject, false);
    _ = button(L("Open TAS folder"), 424, 58, 110, .open_folder, false);

    // Next battle
    group(L("Next battle (tas.txt)"), 12, 100, 536, 250);
    _ = label(L("Mode"), 26, 126, 60);
    h_mode = control(L("COMBOBOX"), L(""), WS_TABSTOP | WS_GROUP | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 90, 124, 120, 200, @intFromEnum(Id.mode));
    for (modes) |m| {
        var wide: [16]u16 = undefined;
        _ = SendMessageW(h_mode, CB_ADDSTRING, 0, @bitCast(@intFromPtr(toWide(&wide, m))));
    }
    _ = label(L("Seed"), 300, 126, 40);
    h_seed = edit(344, 124, 90, .seed, L("none"));
    _ = label(L("File"), 26, 160, 60);
    h_file = edit(90, 158, 344, .file, L("TAS\\run.inputtrace"));
    _ = button(L("Browse..."), 442, 156, 92, .browse, false);
    _ = label(L("FPS"), 26, 194, 60);
    h_fps = edit(90, 192, 60, .fps, L("60"));
    _ = label(L("Speed"), 170, 194, 50);
    h_speed = edit(222, 192, 60, .speed, L("1"));
    _ = label(L("1 = real time, 0 = as fast as possible"), 292, 194, 250);
    for (switches, 0..) |sw, i| {
        const col: i32 = @intCast(i % 2);
        const row: i32 = @intCast(i / 2);
        var wide: [96]u16 = undefined;
        h_switch[i] = control(L("BUTTON"), toWide(&wide, sw.label), WS_TABSTOP | BS_AUTOCHECKBOX, 0, 26 + col * 262, 228 + row * 24, 258, 22, @intFromEnum(sw.id));
    }
    _ = button(L("Save"), 424, 312, 110, .save, true);
    h_saved = control(L("STATIC"), L("Read at the start of every battle."), 0, 0, 26, 318, 380, 22, 0);

    // Log
    group(L("TAS log"), 12, 358, 536, 170);
    h_log = control(L("EDIT"), L(""), ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL, WS_EX_CLIENTEDGE, 24, 380, 512, 138, 0);
    _ = SendMessageW(h_log, WM_SETFONT, @intFromPtr(font_mono), 1);
}

// --- text helpers -----------------------------------------------------------------------------

fn toWide(buffer: []u16, text: []const u8) [*:0]const u16 {
    const n = @min(text.len, buffer.len - 1);
    for (text[0..n], 0..) |c, i| buffer[i] = c;
    buffer[n] = 0;
    return buffer[0..n :0].ptr;
}

fn setText(h: HWND, text: []const u8) void {
    var wide: [4096]u16 = undefined;
    _ = SetWindowTextW(h, toWide(&wide, text));
}

/// A control's text as ASCII ('?' for anything else), trimmed.
fn getText(h: HWND, out: []u8) []const u8 {
    var wide: [512]u16 = undefined;
    const n: usize = @intCast(@max(0, GetWindowTextW(h, &wide, wide.len)));
    const m = @min(n, out.len);
    for (wide[0..m], 0..) |c, i| out[i] = if (c < 128) @intCast(c) else '?';
    return std.mem.trim(u8, out[0..m], " \t");
}

fn path(buffer: []u8, name: []const u8) [*:0]const u8 {
    return (std.fmt.bufPrintZ(buffer, "{s}{s}", .{ dir, name }) catch return "").ptr;
}

fn readFile(name: []const u8, buffer: []u8) ?[]u8 {
    var path_buffer: [1200]u8 = undefined;
    const handle = CreateFileA(path(&path_buffer, name), GENERIC_READ, SHARE_READ_WRITE, null, OPEN_EXISTING, 0x80, null);
    if (@intFromPtr(handle) == INVALID_HANDLE) return null;
    defer _ = CloseHandle(handle);
    var got: u32 = 0;
    if (ReadFile(handle, buffer.ptr, @intCast(buffer.len), &got, null) == 0) return null;
    return buffer[0..got];
}

/// The last `max` bytes of a file, from the first full line, and the file's size.
fn readTail(name: []const u8, buffer: []u8, size_out: *i64) ?[]u8 {
    var path_buffer: [1200]u8 = undefined;
    const handle = CreateFileA(path(&path_buffer, name), GENERIC_READ, SHARE_READ_WRITE, null, OPEN_EXISTING, 0x80, null);
    if (@intFromPtr(handle) == INVALID_HANDLE) return null;
    defer _ = CloseHandle(handle);
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0) return null;
    size_out.* = size;
    const start: i64 = @max(0, size - @as(i64, @intCast(buffer.len)));
    _ = SetFilePointerEx(handle, start, null, 0);
    var got: u32 = 0;
    if (ReadFile(handle, buffer.ptr, @intCast(buffer.len), &got, null) == 0) return null;
    var text = buffer[0..got];
    if (start > 0) {
        if (std.mem.indexOfScalar(u8, text, '\n')) |i| text = text[i + 1 ..];
    }
    return text;
}

// --- tas.txt ----------------------------------------------------------------------------------

const config_name = "tas.txt";
const Keys = enum { mode, file, fps, speed, seed, sync, pin_team, pin_spawn, pin_assets, pin_random };

fn isOn(value: []const u8) bool {
    for ([_][]const u8{ "on", "true", "yes", "1" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    return false;
}

/// `key = value` of an uncommented line, as the DLL reads it.
fn splitLine(raw: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
    const line = std.mem.trim(u8, no_comment, " \t\r");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trim(u8, line[eq + 1 ..], " \t\"") };
}

fn loadConfig() void {
    var buffer: [16 * 1024]u8 = undefined;
    const text = readFile(config_name, &buffer) orelse "";
    var mode: usize = 0;
    setText(h_fps, "60");
    setText(h_speed, "1");
    setText(h_seed, "42");
    for (h_switch) |h| _ = SendMessageW(h, BM_SETCHECK, 1, 0);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const kv = splitLine(raw) orelse continue;
        const key = std.meta.stringToEnum(Keys, kv.key) orelse continue;
        switch (key) {
            .mode => mode = for (modes, 0..) |m, i| {
                if (std.ascii.eqlIgnoreCase(kv.value, m)) break i;
            } else 0,
            .file => setText(h_file, kv.value),
            .fps => setText(h_fps, kv.value),
            .speed => setText(h_speed, kv.value),
            .seed => setText(h_seed, kv.value),
            else => for (switches, 0..) |sw, i| {
                if (std.mem.eql(u8, sw.key, kv.key)) _ = SendMessageW(h_switch[i], BM_SETCHECK, @intFromBool(isOn(kv.value)), 0);
            },
        }
    }
    _ = SendMessageW(h_mode, CB_SETCURSEL, mode, 0);
}

fn complain(text: [*:0]const u16) void {
    _ = MessageBoxW(hwnd_main, text, L("remielle-tas"), MB_OK_ERROR);
}

/// Rewrites tas.txt with the window's values: each key's line is replaced in place (its trailing
/// comment kept), duplicates are commented out, every other line is kept, and missing keys are
/// added at the end.
fn saveConfig() void {
    var values: [@typeInfo(Keys).@"enum".fields.len][]const u8 = undefined;
    var bufs: [5][300]u8 = undefined;
    const mode_index: usize = @intCast(@max(0, SendMessageW(h_mode, CB_GETCURSEL, 0, 0)));
    values[@intFromEnum(Keys.mode)] = modes[@min(mode_index, modes.len - 1)];
    values[@intFromEnum(Keys.file)] = getText(h_file, &bufs[0]);
    values[@intFromEnum(Keys.fps)] = getText(h_fps, &bufs[1]);
    values[@intFromEnum(Keys.speed)] = getText(h_speed, &bufs[2]);
    values[@intFromEnum(Keys.seed)] = getText(h_seed, &bufs[3]);
    for (switches, 0..) |sw, i| {
        const key = std.meta.stringToEnum(Keys, sw.key).?;
        values[@intFromEnum(key)] = if (SendMessageW(h_switch[i], BM_GETCHECK, 0, 0) == 1) "on" else "off";
    }

    const fps = std.fmt.parseInt(u32, values[@intFromEnum(Keys.fps)], 10) catch 0;
    if (fps < 10 or fps > 1000) return complain(L("FPS must be a whole number from 10 to 1000 (60 is the one that works)."));
    const speed = std.fmt.parseFloat(f32, values[@intFromEnum(Keys.speed)]) catch -1;
    if (speed < 0 or speed > 16) return complain(L("Speed must be a number from 0 to 16 (1 = real time, 0 = as fast as possible)."));
    const seed = values[@intFromEnum(Keys.seed)];
    if (seed.len > 0) _ = std.fmt.parseInt(i32, seed, 0) catch return complain(L("Seed must be a whole number, or empty for none."));
    if (std.mem.eql(u8, values[@intFromEnum(Keys.mode)], "play") and values[@intFromEnum(Keys.file)].len == 0)
        return complain(L("Play needs a recording in File."));

    var original_buffer: [16 * 1024]u8 = undefined;
    const original = readFile(config_name, &original_buffer);
    var out: [20 * 1024]u8 = undefined;
    var len: usize = 0;
    var done = [_]bool{false} ** values.len;
    const write = struct {
        fn f(o: []u8, l: *usize, text: []const u8) void {
            const n = @min(text.len, o.len - l.*);
            @memcpy(o[l.*..][0..n], text[0..n]);
            l.* += n;
        }
    }.f;
    if (original == null) write(&out, &len, "# TAS input record / playback (remielle-tas). Read at the start of every battle.\r\n");
    if (original) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const raw = std.mem.trimEnd(u8, raw_line, "\r");
            if (lines.peek() == null and raw.len == 0) break; // the final newline
            const key = if (splitLine(raw)) |kv| std.meta.stringToEnum(Keys, kv.key) else null;
            if (key) |k| {
                const i = @intFromEnum(k);
                const value = values[i];
                if (done[i] or (k == .seed and value.len == 0)) {
                    write(&out, &len, "# ");
                    write(&out, &len, raw);
                } else {
                    done[i] = true;
                    var line_buffer: [400]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buffer, "{t} = {s}", .{ k, value }) catch "";
                    write(&out, &len, line);
                    if (std.mem.indexOfScalar(u8, raw, '#')) |c| {
                        var pad: usize = line.len;
                        while (pad < 24) : (pad += 1) write(&out, &len, " ");
                        write(&out, &len, raw[c..]);
                    }
                }
            } else write(&out, &len, raw);
            write(&out, &len, "\r\n");
        }
    }
    for (values, 0..) |value, i| {
        if (done[i] or value.len == 0) continue;
        var line_buffer: [400]u8 = undefined;
        write(&out, &len, std.fmt.bufPrint(&line_buffer, "{t} = {s}\r\n", .{ @as(Keys, @enumFromInt(i)), value }) catch "");
    }

    var path_buffer: [1200]u8 = undefined;
    const handle = CreateFileA(path(&path_buffer, config_name), GENERIC_WRITE, 1, null, CREATE_ALWAYS, 0x80, null);
    if (@intFromPtr(handle) == INVALID_HANDLE) return complain(L("Could not write tas.txt."));
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    _ = WriteFile(handle, &out, @intCast(len), &written, null);
    setText(h_saved, "Saved. The next battle uses these settings.");
}

fn browse() void {
    var file: [1024]u16 = undefined;
    file[0] = 0;
    var initial_buffer: [1200]u8 = undefined;
    var initial_wide: [1200]u16 = undefined;
    const initial = std.fmt.bufPrint(&initial_buffer, "{s}TAS", .{dir}) catch "";
    var dialog: OPENFILENAMEW = .{
        .hwndOwner = hwnd_main,
        .lpstrFilter = L("Recordings (*.inputtrace)\x00*.inputtrace\x00All files\x00*.*\x00"),
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrInitialDir = toWide(&initial_wide, initial),
        .Flags = OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR,
    };
    if (GetOpenFileNameW(&dialog) == 0) return;
    var ascii: [1024]u8 = undefined;
    var n: usize = 0;
    while (n < file.len and file[n] != 0) : (n += 1) ascii[n] = if (file[n] < 128) @intCast(file[n]) else '?';
    var chosen: []const u8 = ascii[0..n];
    if (chosen.len > dir.len and std.ascii.eqlIgnoreCase(chosen[0..dir.len], dir)) chosen = chosen[dir.len..];
    setText(h_file, chosen);
}

fn openFolder() void {
    var buffer: [1200]u8 = undefined;
    var wide: [1200]u16 = undefined;
    const folder = std.fmt.bufPrint(&buffer, "{s}TAS", .{dir}) catch return;
    _ = ShellExecuteW(hwnd_main, L("open"), toWide(&wide, folder), null, null, 5);
}

// --- status -----------------------------------------------------------------------------------

fn setStatus(tone: Tone, text: []const u8) void {
    status_tone = tone;
    setText(h_status, text);
}

/// The text after the last "): " of a log line (drops the time and scope prefix).
fn logMessage(line: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, line, "): ")) |i| line[i + 3 ..] else line;
}

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n ");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return std.mem.trim(u8, trimmed[start..], "\r ");
}

fn refreshStatus() void {
    if (!injecting) {
        const pid = injector.findProcess();
        const loaded = if (pid) |p| injector.hasModule(p, injector.dll_name) else false;
        if (pid == null) {
            setStatus(.grey, "Game not running");
            setText(h_detail, "Start it with remielle.exe, then press Inject.");
        } else if (!loaded) {
            setStatus(.orange, "Game running, TAS not injected");
            setText(h_detail, "Press Inject to load remielle-tas.dll.");
        } else {
            setStatus(.green, "TAS injected");
            var buffer: [4096]u8 = undefined;
            var size: i64 = 0;
            const text = readTail("TAS\\tas-dll.log", &buffer, &size) orelse "";
            setText(h_detail, logMessage(lastLine(text)));
        }
        _ = EnableWindow(h_inject, @intFromBool(pid == null or !loaded));
    }

    var buffer: [6000]u8 = undefined;
    var size: i64 = 0;
    const text = readTail("TAS\\tas-log.txt", &buffer, &size) orelse return;
    if (size == log_size) return;
    log_size = size;
    var out: [6000]u8 = undefined;
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
    while (lines.next()) |line| {
        var l = std.mem.trimEnd(u8, line, "\r");
        // "2026-10-19 21:09:34  ..." -> "21:09:34  ...": the date only makes lines wrap
        if (l.len > 11 and l[4] == '-' and l[7] == '-' and l[10] == ' ') l = l[11..];
        if (len + l.len + 2 > out.len) break;
        @memcpy(out[len..][0..l.len], l);
        len += l.len;
        out[len] = '\r';
        out[len + 1] = '\n';
        len += 2;
    }
    setText(h_log, out[0..@max(len, 2) - 2]);
    _ = SendMessageW(h_log, WM_VSCROLL, SB_BOTTOM, 0);
}

const WM_VSCROLL: u32 = 0x0115;
const SB_BOTTOM: usize = 7;

// --- injection (worker thread; reports back with posted messages) -----------------------------

const Outcome = enum(usize) { loaded, already, no_game, no_dll, failed, load_failed };
const Stage = enum(usize) { waiting, injecting };

fn injectThread(_: ?*anyopaque) callconv(.winapi) u32 {
    var dll_buffer: [1024]u8 = undefined;
    const dll = injector.dllPath(&dll_buffer) orelse {
        _ = PostMessageW(hwnd_main, WM_INJECT_DONE, @intFromEnum(Outcome.no_dll), 0);
        return 0;
    };
    _ = PostMessageW(hwnd_main, WM_INJECT_STAGE, @intFromEnum(Stage.waiting), 0);
    var pid: u32 = 0;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (injector.findProcess()) |found| {
            pid = found;
            break;
        }
        if (waited >= 600) {
            _ = PostMessageW(hwnd_main, WM_INJECT_DONE, @intFromEnum(Outcome.no_game), 0);
            return 0;
        }
        Sleep(500);
    }
    var tries: u32 = 0;
    while (!injector.hasModule(pid, "GameAssembly.dll") and tries < 600) : (tries += 1) Sleep(500);
    if (injector.hasModule(pid, injector.dll_name)) {
        _ = PostMessageW(hwnd_main, WM_INJECT_DONE, @intFromEnum(Outcome.already), 0);
        return 0;
    }
    _ = PostMessageW(hwnd_main, WM_INJECT_STAGE, @intFromEnum(Stage.injecting), 0);
    injector.inject(pid, dll) catch |err| {
        const outcome: Outcome = if (err == error.LoadLibraryFailed) .load_failed else .failed;
        _ = PostMessageW(hwnd_main, WM_INJECT_DONE, @intFromEnum(outcome), @intCast(injector.last_error));
        return 0;
    };
    _ = PostMessageW(hwnd_main, WM_INJECT_DONE, @intFromEnum(Outcome.loaded), 0);
    return 0;
}

fn startInject() void {
    if (injecting) return;
    injecting = true;
    _ = EnableWindow(h_inject, 0);
    const thread = CreateThread(null, 0, injectThread, null, 0, null) orelse {
        injecting = false;
        _ = EnableWindow(h_inject, 1);
        return complain(L("Could not start the injection thread."));
    };
    _ = CloseHandle(thread);
}

fn injectStage(stage: Stage) void {
    switch (stage) {
        .waiting => {
            setStatus(.orange, "Waiting for the game...");
            setText(h_detail, "Start it with remielle.exe; this waits up to five minutes.");
        },
        .injecting => {
            setStatus(.orange, "Injecting...");
            setText(h_detail, "");
        },
    }
}

fn injectDone(outcome: Outcome, code: usize) void {
    injecting = false;
    var buffer: [160]u8 = undefined;
    switch (outcome) {
        .loaded, .already => {
            setStatus(.green, "TAS injected");
            setText(h_detail, "Loading; TAS\\tas-dll.log says when it is ready.");
        },
        .no_game => {
            setStatus(.red, "Game did not start");
            setText(h_detail, "Nothing found within five minutes. Start the game, then press Inject again.");
        },
        .no_dll => {
            setStatus(.red, "remielle-tas.dll missing");
            setText(h_detail, "It has to be in the same folder as tas-gui.exe.");
        },
        .failed => {
            setStatus(.red, "Injection failed");
            setText(h_detail, std.fmt.bufPrint(&buffer, "Windows error {d}. Try running tas-gui.exe as administrator.", .{code}) catch "");
        },
        .load_failed => {
            setStatus(.red, "The game could not load the DLL");
            setText(h_detail, "Check that remielle-tas.dll is the 64-bit build from this release.");
        },
    }
    _ = EnableWindow(h_inject, @intFromBool(outcome != .loaded and outcome != .already));
}

// --- window -----------------------------------------------------------------------------------

fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CREATE => {
            hwnd_main = hwnd;
            createControls();
            loadConfig();
            refreshStatus();
            _ = SetTimer(hwnd, 1, 1000, null);
            return 0;
        },
        WM_TIMER => {
            refreshStatus();
            return 0;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            const code: u16 = @truncate(wparam >> 16);
            if (code != 0) return 0; // BN_CLICKED only
            switch (@as(Id, @enumFromInt(id))) {
                .inject => startInject(),
                .open_folder => openFolder(),
                .browse => browse(),
                .save => saveConfig(),
                else => {},
            }
            return 0;
        },
        WM_INJECT_STAGE => {
            injectStage(@enumFromInt(wparam));
            return 0;
        },
        WM_INJECT_DONE => {
            injectDone(@enumFromInt(wparam), @bitCast(lparam));
            return 0;
        },
        WM_CTLCOLORSTATIC => {
            const hdc: *anyopaque = @ptrFromInt(wparam);
            _ = SetBkMode(hdc, 1); // transparent
            if (lparam == @as(LPARAM, @bitCast(@intFromPtr(h_status)))) {
                _ = SetTextColor(hdc, switch (status_tone) {
                    .grey => 0x00707070,
                    .green => 0x00208A20,
                    .orange => 0x000070D0,
                    .red => 0x002020C0,
                });
            }
            return @bitCast(@intFromPtr(GetSysColorBrush(COLOR_WINDOW)));
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn main() void {
    dir = injector.programDir(&dir_buffer) orelse "";
    dpi = @intCast(GetDpiForSystem());
    if (dpi == 0) dpi = 96;
    _ = InitCommonControlsEx(&.{ .icc = 0x4000 | 0xFF });
    const quality: u32 = 5; // ClearType
    font = CreateFontW(-px(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, quality, 0, L("Segoe UI"));
    font_bold = CreateFontW(-px(12), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, quality, 0, L("Segoe UI"));
    font_mono = CreateFontW(-px(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, quality, 0, L("Consolas"));

    const instance = GetModuleHandleW(null);
    const class = WNDCLASSEXW{
        .lpfnWndProc = wndProc,
        .hInstance = instance,
        .hIcon = LoadIconW(null, IDI_APPLICATION),
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = GetSysColorBrush(COLOR_WINDOW),
        .lpszClassName = L("remielle-tas-gui"),
    };
    if (RegisterClassExW(&class) == 0) return;
    var rect = RECT{ .left = 0, .top = 0, .right = px(560), .bottom = px(540) };
    _ = AdjustWindowRectEx(&rect, window_style, 0, 0);
    const cw_usedefault: i32 = std.math.minInt(i32);
    const hwnd = CreateWindowExW(0, L("remielle-tas-gui"), L("remielle-tas"), window_style, cw_usedefault, cw_usedefault, rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null) orelse return;
    _ = ShowWindow(hwnd, 5);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        if (IsDialogMessageW(hwnd, &msg) != 0) continue;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}
