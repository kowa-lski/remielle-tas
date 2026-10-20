//! Shared Win32 plumbing for the two launchers (tas-gui.exe, remielle-speed.exe): the API
//! declarations, DPI-scaled control helpers, small file helpers relative to the program's folder,
//! and the game status / Inject button (the injection runs on a worker thread and reports back
//! with posted messages). Plain Win32; each exe's manifest turns on the current control styles and
//! DPI awareness.
const std = @import("std");
const injector = @import("injector.zig");

pub const HWND = *anyopaque;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const BOOL = i32;

pub fn L(comptime s: []const u8) [*:0]const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// --- Win32 ------------------------------------------------------------------------------------

pub const WndProc = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
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
pub const OPENFILENAMEW = extern struct {
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
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn IsDialogMessageW(HWND, *MSG) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(HWND, [*]u16, i32) callconv(.winapi) i32;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn LoadIconW(?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetSysColorBrush(i32) callconv(.winapi) ?*anyopaque;
extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, BOOL, u32) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetTextColor(*anyopaque, u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkMode(*anyopaque, i32) callconv(.winapi) i32;
extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) BOOL;
extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn CreateDirectoryA([*:0]const u8, ?*anyopaque) callconv(.winapi) BOOL;
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

pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
const WM_SETFONT: u32 = 0x0030;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_VSCROLL: u32 = 0x0115;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
const WM_APP: u32 = 0x8000;
const WM_INJECT_STAGE = WM_APP + 1;
const WM_INJECT_DONE = WM_APP + 2;

pub const WS_TABSTOP: u32 = 0x00010000;
pub const WS_GROUP: u32 = 0x00020000;
pub const WS_VSCROLL: u32 = 0x00200000;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CAPTION: u32 = 0x00C00000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
pub const WS_EX_CLIENTEDGE: u32 = 0x00000200;
const BS_PUSHBUTTON: u32 = 0x0;
const BS_DEFPUSHBUTTON: u32 = 0x1;
const BS_AUTOCHECKBOX: u32 = 0x3;
const BS_AUTORADIOBUTTON: u32 = 0x9;
const BS_GROUPBOX: u32 = 0x7;
pub const BM_GETCHECK: u32 = 0x00F0;
pub const BM_SETCHECK: u32 = 0x00F1;
pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_AUTOVSCROLL: u32 = 0x0040;
const ES_AUTOHSCROLL: u32 = 0x0080;
pub const ES_READONLY: u32 = 0x0800;
const EM_SETCUEBANNER: u32 = 0x1501;
pub const CBS_DROPDOWNLIST: u32 = 0x0003;
pub const CB_ADDSTRING: u32 = 0x0143;
pub const CB_GETCURSEL: u32 = 0x0147;
pub const CB_SETCURSEL: u32 = 0x014E;
pub const SB_BOTTOM: usize = 7;
const COLOR_WINDOW: i32 = 5;
const IDC_ARROW: usize = 32512;
const IDI_APPLICATION: usize = 32512;
const MB_OK_ERROR: u32 = 0x10;

const window_style = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;

// --- window and controls ----------------------------------------------------------------------

pub var hwnd_main: HWND = undefined;
pub var font: ?*anyopaque = null;
pub var font_bold: ?*anyopaque = null;
pub var font_mono: ?*anyopaque = null;
var dpi: i32 = 96;
var app_title: [*:0]const u16 = L("");

/// The program's folder, with a trailing backslash.
pub var dir: []const u8 = "";
var dir_buffer: [1024]u8 = undefined;

pub fn px(v: i32) i32 {
    return @divTrunc(v * dpi, 96);
}

pub fn control(class: [*:0]const u16, text: [*:0]const u16, style: u32, ex: u32, x: i32, y: i32, width: i32, height: i32, id: u16) HWND {
    const h = CreateWindowExW(ex, class, text, WS_CHILD | WS_VISIBLE | style, px(x), px(y), px(width), px(height), hwnd_main, @ptrFromInt(id), GetModuleHandleW(null), null).?;
    setFont(h, font);
    return h;
}

pub fn setFont(h: HWND, f: ?*anyopaque) void {
    _ = SendMessageW(h, WM_SETFONT, @intFromPtr(f), 1);
}

pub fn label(text: [*:0]const u16, x: i32, y: i32, width: i32) HWND {
    return control(L("STATIC"), text, 0, 0, x, y + 3, width, 20, 0);
}

pub fn group(text: [*:0]const u16, x: i32, y: i32, width: i32, height: i32) void {
    setFont(control(L("BUTTON"), text, BS_GROUPBOX, 0, x, y, width, height, 0), font_bold);
}

pub fn button(text: [*:0]const u16, x: i32, y: i32, width: i32, id: u16, default: bool) HWND {
    return control(L("BUTTON"), text, WS_TABSTOP | if (default) BS_DEFPUSHBUTTON else BS_PUSHBUTTON, 0, x, y, width, 28, id);
}

pub fn checkbox(text: [*:0]const u16, x: i32, y: i32, width: i32, id: u16) HWND {
    return control(L("BUTTON"), text, WS_TABSTOP | BS_AUTOCHECKBOX, 0, x, y, width, 22, id);
}

/// `first` starts a new group of radio buttons.
pub fn radio(text: [*:0]const u16, x: i32, y: i32, width: i32, id: u16, first: bool) HWND {
    return control(L("BUTTON"), text, BS_AUTORADIOBUTTON | if (first) WS_GROUP | WS_TABSTOP else 0, 0, x, y, width, 22, id);
}

pub fn edit(x: i32, y: i32, width: i32, id: u16, cue: [*:0]const u16) HWND {
    const h = control(L("EDIT"), L(""), WS_TABSTOP | ES_AUTOHSCROLL, WS_EX_CLIENTEDGE, x, y, width, 24, id);
    _ = SendMessageW(h, EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(cue)));
    return h;
}

pub fn dropdown(x: i32, y: i32, width: i32, id: u16, items: []const []const u8) HWND {
    const h = control(L("COMBOBOX"), L(""), WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL, 0, x, y, width, 300, id);
    for (items) |item| {
        var wide: [32]u16 = undefined;
        _ = SendMessageW(h, CB_ADDSTRING, 0, @bitCast(@intFromPtr(toWide(&wide, item))));
    }
    return h;
}

pub fn isChecked(h: HWND) bool {
    return SendMessageW(h, BM_GETCHECK, 0, 0) == 1;
}

pub fn setChecked(h: HWND, on: bool) void {
    _ = SendMessageW(h, BM_SETCHECK, @intFromBool(on), 0);
}

pub fn selection(h: HWND) usize {
    return @intCast(@max(0, SendMessageW(h, CB_GETCURSEL, 0, 0)));
}

pub fn select(h: HWND, index: usize) void {
    _ = SendMessageW(h, CB_SETCURSEL, index, 0);
}

pub fn complain(text: [*:0]const u16) void {
    _ = MessageBoxW(hwnd_main, text, app_title, MB_OK_ERROR);
}

/// Registers the class, creates the window with `client_width` x `client_height` (96-dpi units)
/// and runs the message loop; `wnd_proc` creates the controls on WM_CREATE and passes everything
/// it does not handle to `defaultProc`.
pub fn run(class_name: [*:0]const u16, title: [*:0]const u16, client_width: i32, client_height: i32, wnd_proc: WndProc) void {
    app_title = title;
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
        .lpfnWndProc = wnd_proc,
        .hInstance = instance,
        .hIcon = LoadIconW(null, IDI_APPLICATION),
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = GetSysColorBrush(COLOR_WINDOW),
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&class) == 0) return;
    var rect = RECT{ .left = 0, .top = 0, .right = px(client_width), .bottom = px(client_height) };
    _ = AdjustWindowRectEx(&rect, window_style, 0, 0);
    const cw_usedefault: i32 = std.math.minInt(i32);
    const hwnd = CreateWindowExW(0, class_name, title, window_style, cw_usedefault, cw_usedefault, rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null) orelse return;
    _ = ShowWindow(hwnd, 5);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        if (IsDialogMessageW(hwnd, &msg) != 0) continue;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

/// What both windows do with the messages they share: status colours, the injection worker's
/// reports, quitting.
pub fn defaultProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) LRESULT {
    switch (msg) {
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
            if (status.h) |h| {
                if (lparam == @as(LPARAM, @bitCast(@intFromPtr(h)))) _ = SetTextColor(hdc, status.tone.color());
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

// --- text and files ---------------------------------------------------------------------------

pub fn toWide(buffer: []u16, text: []const u8) [*:0]const u16 {
    const n = @min(text.len, buffer.len - 1);
    for (text[0..n], 0..) |c, i| buffer[i] = c;
    buffer[n] = 0;
    return buffer[0..n :0].ptr;
}

pub fn setText(h: HWND, text: []const u8) void {
    var wide: [4096]u16 = undefined;
    _ = SetWindowTextW(h, toWide(&wide, text));
}

/// A control's text as ASCII ('?' for anything else), trimmed.
pub fn getText(h: HWND, out: []u8) []const u8 {
    var wide: [512]u16 = undefined;
    const n: usize = @intCast(@max(0, GetWindowTextW(h, &wide, wide.len)));
    const m = @min(n, out.len);
    for (wide[0..m], 0..) |c, i| out[i] = if (c < 128) @intCast(c) else '?';
    return std.mem.trim(u8, out[0..m], " \t");
}

/// `<program folder>\<name>`.
pub fn path(buffer: []u8, name: []const u8) [*:0]const u8 {
    return (std.fmt.bufPrintZ(buffer, "{s}{s}", .{ dir, name }) catch return "").ptr;
}

pub fn readFile(name: []const u8, buffer: []u8) ?[]u8 {
    var path_buffer: [1200]u8 = undefined;
    const handle = CreateFileA(path(&path_buffer, name), GENERIC_READ, SHARE_READ_WRITE, null, OPEN_EXISTING, 0x80, null);
    if (@intFromPtr(handle) == INVALID_HANDLE) return null;
    defer _ = CloseHandle(handle);
    var got: u32 = 0;
    if (ReadFile(handle, buffer.ptr, @intCast(buffer.len), &got, null) == 0) return null;
    return buffer[0..got];
}

pub fn writeFile(name: []const u8, text: []const u8) bool {
    var path_buffer: [1200]u8 = undefined;
    const handle = CreateFileA(path(&path_buffer, name), GENERIC_WRITE, 1, null, CREATE_ALWAYS, 0x80, null);
    if (@intFromPtr(handle) == INVALID_HANDLE) return false;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    return WriteFile(handle, text.ptr, @intCast(text.len), &written, null) != 0 and written == text.len;
}

/// The end of a file (at most `buffer.len` bytes, from the first full line), and its size.
pub fn readTail(name: []const u8, buffer: []u8, size_out: *i64) ?[]u8 {
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

pub fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n ");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return std.mem.trim(u8, trimmed[start..], "\r ");
}

/// The text after the last "): " of a DLL log line (drops the time and scope prefix).
pub fn logMessage(line: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, line, "): ")) |i| line[i + 3 ..] else line;
}

/// `key = value` of an uncommented line, as the DLLs read their settings files.
pub fn splitLine(raw: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
    const line = std.mem.trim(u8, no_comment, " \t\r");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trim(u8, line[eq + 1 ..], " \t\"") };
}

pub fn isOn(value: []const u8) bool {
    for ([_][]const u8{ "on", "true", "yes", "1" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    return false;
}

pub fn openFolder(name: []const u8) void {
    var buffer: [1200]u8 = undefined;
    var wide: [1200]u16 = undefined;
    const folder = std.fmt.bufPrint(&buffer, "{s}{s}", .{ dir, name }) catch return;
    _ = CreateDirectoryA(path(&buffer, name), null);
    _ = ShellExecuteW(hwnd_main, L("open"), toWide(&wide, folder), null, null, 5);
}

// --- game status and the Inject button --------------------------------------------------------

pub const Tone = enum {
    grey,
    green,
    orange,
    red,

    fn color(tone: Tone) u32 {
        return switch (tone) {
            .grey => 0x00707070,
            .green => 0x00208A20,
            .orange => 0x000070D0,
            .red => 0x002020C0,
        };
    }
};

/// The status line (bold, coloured), the detail line under it and the Inject button, and the DLL
/// they are about.
pub const Status = struct {
    h: ?HWND = null,
    detail: HWND = undefined,
    inject: HWND = undefined,
    tone: Tone = .grey,
    dll: []const u8 = "",
    /// The detail line once the DLL is in: the last line of this log, if set.
    dll_log: ?[]const u8 = null,
    busy: bool = false,
};
pub var status: Status = .{};

/// The "Game" box: status, detail, Inject and a folder button (`folder_id`).
pub fn gameBox(dll: []const u8, dll_log: ?[]const u8, inject_id: u16, folder_id: u16, folder_text: [*:0]const u16) void {
    status.dll = dll;
    status.dll_log = dll_log;
    group(L("Game"), 12, 8, 536, 84);
    status.h = control(L("STATIC"), L("Checking..."), 0, 0, 26, 32, 380, 22, 0);
    setFont(status.h.?, font_bold);
    status.detail = control(L("STATIC"), L(""), 0, 0, 26, 56, 380, 30, 0);
    status.inject = button(L("Inject"), 424, 28, 110, inject_id, false);
    _ = button(folder_text, 424, 58, 110, folder_id, false);
}

pub fn setStatus(tone: Tone, text: []const u8, detail: []const u8) void {
    status.tone = tone;
    setText(status.h.?, text);
    setText(status.detail, detail);
}

/// Called every second: is the game running, is the DLL in it.
pub fn refreshStatus() void {
    if (status.busy) return;
    const pid = injector.findProcess();
    const loaded = if (pid) |p| injector.hasModule(p, status.dll) else false;
    if (pid == null) {
        setStatus(.grey, "Game not running", "Start it with remielle.exe, then press Inject.");
    } else if (!loaded) {
        var buffer: [96]u8 = undefined;
        setStatus(.orange, "Game running, not injected", std.fmt.bufPrint(&buffer, "Press Inject to load {s}.", .{status.dll}) catch "");
    } else {
        var buffer: [4096]u8 = undefined;
        var size: i64 = 0;
        const detail = if (status.dll_log) |name| logMessage(lastLine(readTail(name, &buffer, &size) orelse "")) else "";
        setStatus(.green, "Injected", detail);
    }
    _ = EnableWindow(status.inject, @intFromBool(pid == null or !loaded));
}

const Outcome = enum(usize) { loaded, already, no_game, no_dll, failed, load_failed };
const Stage = enum(usize) { waiting, injecting };

fn post(msg: u32, wparam: usize, lparam: isize) void {
    _ = PostMessageW(hwnd_main, msg, wparam, lparam);
}

fn injectThread(_: ?*anyopaque) callconv(.winapi) u32 {
    var dll_buffer: [1024]u8 = undefined;
    const dll = injector.dllPath(&dll_buffer, status.dll) orelse {
        post(WM_INJECT_DONE, @intFromEnum(Outcome.no_dll), 0);
        return 0;
    };
    post(WM_INJECT_STAGE, @intFromEnum(Stage.waiting), 0);
    var pid: u32 = 0;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (injector.findProcess()) |found| {
            pid = found;
            break;
        }
        if (waited >= 600) {
            post(WM_INJECT_DONE, @intFromEnum(Outcome.no_game), 0);
            return 0;
        }
        Sleep(500);
    }
    var tries: u32 = 0;
    while (!injector.hasModule(pid, "GameAssembly.dll") and tries < 600) : (tries += 1) Sleep(500);
    if (injector.hasModule(pid, status.dll)) {
        post(WM_INJECT_DONE, @intFromEnum(Outcome.already), 0);
        return 0;
    }
    post(WM_INJECT_STAGE, @intFromEnum(Stage.injecting), 0);
    injector.inject(pid, dll) catch |err| {
        const outcome: Outcome = if (err == error.LoadLibraryFailed) .load_failed else .failed;
        post(WM_INJECT_DONE, @intFromEnum(outcome), @intCast(injector.last_error));
        return 0;
    };
    post(WM_INJECT_DONE, @intFromEnum(Outcome.loaded), 0);
    return 0;
}

pub fn startInject() void {
    if (status.busy) return;
    status.busy = true;
    _ = EnableWindow(status.inject, 0);
    const thread = CreateThread(null, 0, injectThread, null, 0, null) orelse {
        status.busy = false;
        _ = EnableWindow(status.inject, 1);
        return complain(L("Could not start the injection thread."));
    };
    _ = CloseHandle(thread);
}

fn injectStage(stage: Stage) void {
    switch (stage) {
        .waiting => setStatus(.orange, "Waiting for the game...", "Start it with remielle.exe; this waits up to five minutes."),
        .injecting => setStatus(.orange, "Injecting...", ""),
    }
}

fn injectDone(outcome: Outcome, code: usize) void {
    status.busy = false;
    var buffer: [160]u8 = undefined;
    switch (outcome) {
        .loaded, .already => setStatus(.green, "Injected", "Loading; the status line shows its log once it is up."),
        .no_game => setStatus(.red, "Game did not start", "Nothing found within five minutes. Start the game, then press Inject again."),
        .no_dll => setStatus(.red, "DLL missing", std.fmt.bufPrint(&buffer, "{s} has to be in the same folder as this program.", .{status.dll}) catch ""),
        .failed => setStatus(.red, "Injection failed", std.fmt.bufPrint(&buffer, "Windows error {d}. Try running this program as administrator.", .{code}) catch ""),
        .load_failed => setStatus(.red, "The game could not load the DLL", "Check that it is the 64-bit build from this release."),
    }
    _ = EnableWindow(status.inject, @intFromBool(outcome != .loaded and outcome != .already));
}
