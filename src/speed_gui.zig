//! remielle-speed.exe: the window for remielle-speed.dll. It loads the DLL into the game (Inject)
//! and edits speed.txt: on/off, the FPS target, the speed, and a hotkey that switches to a second
//! speed while held or as a toggle. The DLL re-reads speed.txt within half a second, so Apply works
//! mid-game; the "Now" line shows what the DLL has in effect.
const std = @import("std");
const injector = @import("injector.zig");
const keys = @import("keys.zig");
const speed = @import("speed.zig");
const win = @import("win.zig");
const L = win.L;
const HWND = win.HWND;

const Id = enum(u16) { inject = 100, open_folder, enabled, fps, speed, hotkey, hotkey_speed, hold, toggle, apply, preset_half, preset_1, preset_2, preset_4 };

const settings_name = "speed.txt";
const state_name = "TAS\\speed-state.txt";
const presets = [_]struct { id: Id, text: []const u8, value: []const u8 }{
    .{ .id = .preset_half, .text = "x0.5", .value = "0.5" },
    .{ .id = .preset_1, .text = "x1", .value = "1" },
    .{ .id = .preset_2, .text = "x2", .value = "2" },
    .{ .id = .preset_4, .text = "x4", .value = "4" },
};

var h_enabled: HWND = undefined;
var h_fps: HWND = undefined;
var h_speed: HWND = undefined;
var h_hotkey: HWND = undefined;
var h_hotkey_speed: HWND = undefined;
var h_hold: HWND = undefined;
var h_toggle: HWND = undefined;
var h_saved: HWND = undefined;
var h_now: HWND = undefined;

fn id(i: Id) u16 {
    return @intFromEnum(i);
}

fn createControls() void {
    win.gameBox(injector.speed_dll_name, "TAS\\speed-dll.log", id(.inject), id(.open_folder), L("Open game folder"));

    win.group(L("Speed (speed.txt)"), 12, 100, 536, 244);
    h_enabled = win.checkbox(L("Enabled"), 26, 124, 200, id(.enabled));
    _ = win.label(L("FPS target"), 26, 158, 100);
    h_fps = win.edit(140, 156, 70, id(.fps), L("60"));
    _ = win.label(L("frames the game renders per second"), 222, 158, 300);
    _ = win.label(L("Speed"), 26, 192, 100);
    h_speed = win.edit(140, 190, 70, id(.speed), L("1"));
    for (presets, 0..) |p, i| {
        var wide: [8]u16 = undefined;
        _ = win.button(win.toWide(&wide, p.text), 222 + @as(i32, @intCast(i)) * 58, 188, 52, id(p.id), false);
    }
    _ = win.label(L("Hotkey"), 26, 230, 100);
    var names: [keys.keys.len][]const u8 = undefined;
    for (keys.keys, 0..) |k, i| names[i] = k.name;
    h_hotkey = win.dropdown(140, 228, 110, id(.hotkey), &names);
    _ = win.label(L("switches to speed"), 262, 230, 110);
    h_hotkey_speed = win.edit(374, 228, 70, id(.hotkey_speed), L("2"));
    h_hold = win.radio(L("while held"), 140, 262, 110, id(.hold), true);
    h_toggle = win.radio(L("toggle on each press"), 262, 262, 180, id(.toggle), false);
    _ = win.button(L("Apply"), 424, 302, 110, id(.apply), true);
    h_saved = win.control(L("STATIC"), L("Applies within a second while the game runs."), 0, 0, 26, 308, 380, 22, 0);

    win.group(L("Now"), 12, 352, 536, 60);
    h_now = win.control(L("STATIC"), L("-"), 0, 0, 26, 376, 500, 22, 0);
    win.setFont(h_now, win.font_bold);
}

fn loadSettings() void {
    var buffer: [4096]u8 = undefined;
    const text = win.readFile(settings_name, &buffer) orelse "";
    const s = speed.parse(text);
    win.setChecked(h_enabled, s.enabled);
    var b: [32]u8 = undefined;
    win.setText(h_fps, std.fmt.bufPrint(&b, "{d}", .{s.fps}) catch "60");
    win.setText(h_speed, std.fmt.bufPrint(&b, "{d}", .{s.speed}) catch "1");
    win.setText(h_hotkey_speed, std.fmt.bufPrint(&b, "{d}", .{s.hotkey_speed}) catch "2");
    var key_index: usize = 0;
    for (keys.keys, 0..) |k, i| {
        if (k.vk == s.hotkey) key_index = i;
    }
    win.select(h_hotkey, key_index);
    win.setChecked(h_hold, !s.toggle);
    win.setChecked(h_toggle, s.toggle);
}

fn speedText(h: HWND, buffer: []u8, what: [*:0]const u16) ?[]const u8 {
    const text = win.getText(h, buffer);
    const v = std.fmt.parseFloat(f32, text) catch {
        win.complain(what);
        return null;
    };
    if (v < speed.min_speed or v > speed.max_speed) {
        win.complain(what);
        return null;
    }
    return text;
}

fn apply() void {
    var fps_buffer: [32]u8 = undefined;
    var speed_buffer: [32]u8 = undefined;
    var hotkey_speed_buffer: [32]u8 = undefined;
    const fps_text = win.getText(h_fps, &fps_buffer);
    const fps = std.fmt.parseInt(u32, fps_text, 10) catch 0;
    if (fps < 10 or fps > 1000) return win.complain(L("FPS target must be a whole number from 10 to 1000."));
    const speed_text = speedText(h_speed, &speed_buffer, L("Speed must be a number from 0.05 to 10.")) orelse return;
    const hotkey_speed_text = speedText(h_hotkey_speed, &hotkey_speed_buffer, L("Hotkey speed must be a number from 0.05 to 10.")) orelse return;
    const key = keys.keys[@min(win.selection(h_hotkey), keys.keys.len - 1)];

    var out: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&out,
        \\# Game speed (remielle-speed). Written by remielle-speed.exe; re-read while the game runs.
        \\enabled = {s}
        \\fps = {d}
        \\speed = {s}
        \\hotkey = {s}
        \\hotkey_speed = {s}
        \\hotkey_mode = {s}
        \\
    , .{ if (win.isChecked(h_enabled)) "on" else "off", fps, speed_text, key.name, hotkey_speed_text, if (win.isChecked(h_toggle)) "toggle" else "hold" }) catch return;
    if (!win.writeFile(settings_name, text)) return win.complain(L("Could not write speed.txt."));
    win.setText(h_saved, "Applied.");
}

fn refreshNow() void {
    var buffer: [256]u8 = undefined;
    const text = win.readFile(state_name, &buffer) orelse "-";
    win.setText(h_now, if (text.len == 0) "-" else text);
}

fn wndProc(hwnd: HWND, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    switch (msg) {
        win.WM_CREATE => {
            win.hwnd_main = hwnd;
            createControls();
            loadSettings();
            win.refreshStatus();
            refreshNow();
            _ = win.SetTimer(hwnd, 1, 500, null);
            return 0;
        },
        win.WM_TIMER => {
            win.refreshStatus();
            refreshNow();
            return 0;
        },
        win.WM_COMMAND => {
            if (wparam >> 16 != 0) return 0; // BN_CLICKED only
            const which = std.enums.fromInt(Id, @as(u16, @truncate(wparam))) orelse return 0;
            switch (which) {
                .inject => win.startInject(),
                .open_folder => win.openFolder(""),
                .apply => apply(),
                .preset_half, .preset_1, .preset_2, .preset_4 => {
                    for (presets) |p| if (p.id == which) win.setText(h_speed, p.value);
                    win.setChecked(h_enabled, true);
                    apply();
                },
                else => {},
            }
            return 0;
        },
        else => return win.defaultProc(hwnd, msg, wparam, lparam),
    }
}

pub fn main() void {
    win.run(L("remielle-speed-gui"), L("remielle-speed"), 560, 424, wndProc);
}
