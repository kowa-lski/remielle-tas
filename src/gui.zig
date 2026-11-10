//! tas-gui.exe: a small window for the game folder. It edits tas.txt (mode, file, fps, speed, seed,
//! the switches), loads remielle-tas.dll into the game (the Inject button, as tas-inject.exe does)
//! and shows whether the game is running, whether the TAS is in it, and the end of TAS\tas-log.txt.
//!
//! Every change is saved to tas.txt by itself: a click at once, typing half a second after the last
//! key. With "Automatic" on, tas.txt says `file = auto`: record names each battle's recording, play
//! uses the newest one (recordings.zig, the rule the DLL applies); Browse picks an older one.
const std = @import("std");
const injector = @import("injector.zig");
const recordings = @import("recordings.zig");
const win = @import("win.zig");
const L = win.L;
const HWND = win.HWND;

const Id = enum(u16) { inject = 100, open_folder, mode, file, browse, fps, speed, seed, auto, sync, pin_team, pin_spawn, pin_assets, pin_random, game_clocks, input_clock };

const Switch = struct { id: Id, key: []const u8, label: []const u8 };
const switches = [_]Switch{
    .{ .id = .sync, .key = "sync", .label = "sync: inputs start at the first AI load" },
    .{ .id = .pin_team, .key = "pin_team", .label = "pin_team: team setup on frame 90" },
    .{ .id = .pin_spawn, .key = "pin_spawn", .label = "pin_spawn: intro on frame 90" },
    .{ .id = .pin_assets, .key = "pin_assets", .label = "pin_assets: fixed load times (boss arrival)" },
    .{ .id = .pin_random, .key = "pin_random", .label = "pin_random: fixed bullet and effect seeds" },
    .{ .id = .game_clocks, .key = "game_clocks", .label = "game_clocks: Unity clocks one frame per frame" },
    .{ .id = .input_clock, .key = "input_clock", .label = "input_clock: record and replay input times" },
};
const modes = [_][]const u8{ "off", "record", "play" };

var h_mode: HWND = undefined;
var h_file: HWND = undefined;
var h_auto: HWND = undefined;
var h_fps: HWND = undefined;
var h_speed: HWND = undefined;
var h_seed: HWND = undefined;
var h_saved: HWND = undefined;
var h_log: HWND = undefined;
var h_switch: [switches.len]HWND = undefined;
var log_size: i64 = -1;

/// The file typed or browsed to, kept while "Automatic" shows its own text in the box.
var manual_file: [300]u8 = undefined;
var manual_len: usize = 0;
/// Set while the window fills its own controls, so their change notifications don't save.
var filling = false;
const save_timer: usize = 2;
var save_pending = false;

fn id(i: Id) u16 {
    return @intFromEnum(i);
}

fn createControls() void {
    win.gameBox(injector.dll_name, "TAS\\tas-dll.log", id(.inject), id(.open_folder), L("Open TAS folder"));

    win.group(L("Next battle (tas.txt, saved as you change it)"), 12, 100, 536, 250);
    _ = win.label(L("Mode"), 26, 126, 60);
    h_mode = win.dropdown(90, 124, 120, id(.mode), &modes);
    _ = win.label(L("Seed"), 300, 126, 40);
    h_seed = win.edit(344, 124, 90, id(.seed), L("none"));
    _ = win.label(L("File"), 26, 160, 60);
    h_file = win.edit(90, 158, 254, id(.file), L("TAS\\run.inputtrace"));
    h_auto = win.checkbox(L("Automatic"), 352, 159, 86, id(.auto));
    _ = win.button(L("Browse..."), 442, 156, 92, id(.browse), false);
    _ = win.label(L("FPS"), 26, 194, 60);
    h_fps = win.edit(90, 192, 60, id(.fps), L("60"));
    _ = win.label(L("Speed"), 170, 194, 50);
    h_speed = win.edit(222, 192, 60, id(.speed), L("1"));
    _ = win.label(L("1 = real time, 0 = as fast as possible"), 292, 194, 250);
    for (switches, 0..) |sw, i| {
        const col: i32 = @intCast(i % 2);
        const row: i32 = @intCast(i / 2);
        var wide: [96]u16 = undefined;
        h_switch[i] = win.checkbox(win.toWide(&wide, sw.label), 26 + col * 262, 228 + row * 24, 258, id(sw.id));
    }
    h_saved = win.control(L("STATIC"), L("Read at the start of every battle."), 0, 0, 26, 326, 508, 22, 0);

    win.group(L("TAS log"), 12, 358, 536, 170);
    h_log = win.control(L("EDIT"), L(""), win.ES_MULTILINE | win.ES_READONLY | win.ES_AUTOVSCROLL | win.WS_VSCROLL, win.WS_EX_CLIENTEDGE, 24, 380, 512, 138, 0);
    win.setFont(h_log, win.font_mono);
}

// --- the file box -----------------------------------------------------------------------------

fn currentMode() []const u8 {
    return modes[@min(win.selection(h_mode), modes.len - 1)];
}

/// With "Automatic" on, the box (read only) shows what the next battle will use.
fn showFile() void {
    filling = true;
    defer filling = false;
    const auto = win.isChecked(h_auto);
    _ = win.EnableWindow(h_file, @intFromBool(!auto));
    if (!auto) return win.setText(h_file, manual_file[0..manual_len]);
    var buffer: [300]u8 = undefined;
    const mode = currentMode();
    if (std.mem.eql(u8, mode, "play")) {
        win.setText(h_file, recordings.newest(win.dir, &buffer) orelse "(no recordings in TAS yet)");
    } else if (std.mem.eql(u8, mode, "record")) {
        win.setText(h_file, "TAS\\battle-<date>-<time>.inputtrace");
    } else win.setText(h_file, "");
}

fn keepManualFile() void {
    if (win.isChecked(h_auto)) return;
    var buffer: [300]u8 = undefined;
    const text = win.getText(h_file, &buffer);
    @memcpy(manual_file[0..text.len], text);
    manual_len = text.len;
}

// --- tas.txt ----------------------------------------------------------------------------------

const config_name = "tas.txt";
const Keys = enum { mode, file, fps, speed, seed, sync, pin_team, pin_spawn, pin_assets, pin_random, game_clocks, input_clock };

fn loadConfig() void {
    filling = true;
    defer filling = false;
    var buffer: [16 * 1024]u8 = undefined;
    const text = win.readFile(config_name, &buffer) orelse "";
    var mode: usize = 0;
    var file: []const u8 = "";
    win.setText(h_fps, "60");
    win.setText(h_speed, "1");
    win.setText(h_seed, "42");
    for (h_switch) |h| win.setChecked(h, true);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const kv = win.splitLine(raw) orelse continue;
        const key = std.meta.stringToEnum(Keys, kv.key) orelse continue;
        switch (key) {
            .mode => mode = for (modes, 0..) |m, i| {
                if (std.ascii.eqlIgnoreCase(kv.value, m)) break i;
            } else 0,
            .file => file = kv.value,
            .fps => win.setText(h_fps, kv.value),
            .speed => win.setText(h_speed, kv.value),
            .seed => win.setText(h_seed, kv.value),
            else => for (switches, 0..) |sw, i| {
                if (std.mem.eql(u8, sw.key, kv.key)) win.setChecked(h_switch[i], win.isOn(kv.value));
            },
        }
    }
    win.select(h_mode, mode);
    const auto = recordings.isAuto(file);
    win.setChecked(h_auto, auto);
    manual_len = if (auto) 0 else @min(file.len, manual_file.len);
    @memcpy(manual_file[0..manual_len], file[0..manual_len]);
    filling = false;
    showFile();
}

/// What is wrong with the window's values, or null if tas.txt can take them.
fn problem(values: []const []const u8) ?[]const u8 {
    const fps = std.fmt.parseInt(u32, values[@intFromEnum(Keys.fps)], 10) catch 0;
    if (fps < 10 or fps > 1000) return "FPS must be a whole number from 10 to 1000 (60 is the tested one).";
    const speed = std.fmt.parseFloat(f32, values[@intFromEnum(Keys.speed)]) catch -1;
    if (speed < 0 or speed > 16) return "Speed must be a number from 0 to 16 (1 = real time, 0 = as fast as possible).";
    const seed = values[@intFromEnum(Keys.seed)];
    if (seed.len > 0) _ = std.fmt.parseInt(i32, seed, 0) catch return "Seed must be a whole number, or empty for none.";
    if (std.mem.eql(u8, values[@intFromEnum(Keys.mode)], "play") and values[@intFromEnum(Keys.file)].len == 0)
        return "Play needs a recording: tick Automatic for the newest, or Browse for an older one.";
    return null;
}

/// Rewrites tas.txt with the window's values: each key's line is replaced in place (its trailing
/// comment kept), duplicates are commented out, every other line is kept, and missing keys are
/// added at the end. A value tas.txt can't take is reported in the status line and not written.
fn saveConfig() void {
    save_pending = false;
    _ = win.KillTimer(win.hwnd_main, save_timer);
    var values: [@typeInfo(Keys).@"enum".fields.len][]const u8 = undefined;
    var bufs: [3][300]u8 = undefined;
    values[@intFromEnum(Keys.mode)] = currentMode();
    values[@intFromEnum(Keys.file)] = if (win.isChecked(h_auto)) recordings.auto else manual_file[0..manual_len];
    values[@intFromEnum(Keys.fps)] = win.getText(h_fps, &bufs[0]);
    values[@intFromEnum(Keys.speed)] = win.getText(h_speed, &bufs[1]);
    values[@intFromEnum(Keys.seed)] = win.getText(h_seed, &bufs[2]);
    for (switches, 0..) |sw, i| {
        const key = std.meta.stringToEnum(Keys, sw.key).?;
        values[@intFromEnum(key)] = if (win.isChecked(h_switch[i])) "on" else "off";
    }

    var message: [200]u8 = undefined;
    if (problem(&values)) |text| {
        return win.setText(h_saved, std.fmt.bufPrint(&message, "Not saved: {s}", .{text}) catch text);
    }
    var original_buffer: [16 * 1024]u8 = undefined;
    var out: [20 * 1024]u8 = undefined;
    const text = rewriteConfig(win.readFile(config_name, &original_buffer), &values, &out);
    if (!win.writeFile(config_name, text)) return win.setText(h_saved, "Not saved: could not write tas.txt.");
    var now: SystemTime = undefined;
    GetLocalTime(&now);
    win.setText(h_saved, std.fmt.bufPrint(&message, "Saved {d:0>2}:{d:0>2}:{d:0>2}. The next battle uses these settings.", .{ now.hour, now.minute, now.second }) catch "Saved.");
}

const SystemTime = extern struct { year: u16, month: u16, day_of_week: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };
extern "kernel32" fn GetLocalTime(*SystemTime) callconv(.winapi) void;

/// Typing saves once the keys stop, so a half-typed number is not reported.
fn saveSoon() void {
    save_pending = true;
    _ = win.SetTimer(win.hwnd_main, save_timer, 500, null);
}

fn rewriteConfig(original: ?[]const u8, values: []const []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var done = [_]bool{false} ** @typeInfo(Keys).@"enum".fields.len;
    const write = struct {
        fn f(o: []u8, l: *usize, text: []const u8) void {
            const n = @min(text.len, o.len - l.*);
            @memcpy(o[l.*..][0..n], text[0..n]);
            l.* += n;
        }
    }.f;
    if (original == null) write(out, &len, "# TAS input record / playback (remielle-tas). Read at the start of every battle.\r\n");
    if (original) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const raw = std.mem.trimEnd(u8, raw_line, "\r");
            if (lines.peek() == null and raw.len == 0) break; // the final newline
            const key = if (win.splitLine(raw)) |kv| std.meta.stringToEnum(Keys, kv.key) else null;
            if (key) |k| {
                const i = @intFromEnum(k);
                const value = values[i];
                if (done[i] or (k == .seed and value.len == 0)) {
                    write(out, &len, "# ");
                    write(out, &len, raw);
                } else {
                    done[i] = true;
                    var line_buffer: [400]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buffer, "{t} = {s}", .{ k, value }) catch "";
                    write(out, &len, line);
                    if (std.mem.indexOfScalar(u8, raw, '#')) |c| {
                        var pad: usize = line.len;
                        while (pad < 24) : (pad += 1) write(out, &len, " ");
                        write(out, &len, raw[c..]);
                    }
                }
            } else write(out, &len, raw);
            write(out, &len, "\r\n");
        }
    }
    for (values, 0..) |value, i| {
        if (done[i] or value.len == 0) continue;
        var line_buffer: [400]u8 = undefined;
        write(out, &len, std.fmt.bufPrint(&line_buffer, "{t} = {s}\r\n", .{ @as(Keys, @enumFromInt(i)), value }) catch "");
    }
    return out[0..len];
}

/// Picks a recording, which turns "Automatic" off.
fn browse() void {
    var file: [1024]u16 = undefined;
    file[0] = 0;
    var initial_buffer: [1200]u8 = undefined;
    var initial_wide: [1200]u16 = undefined;
    const initial = std.fmt.bufPrint(&initial_buffer, "{s}TAS", .{win.dir}) catch "";
    var dialog: win.OPENFILENAMEW = .{
        .hwndOwner = win.hwnd_main,
        .lpstrFilter = L("Recordings (*.inputtrace)\x00*.inputtrace\x00All files\x00*.*\x00"),
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrInitialDir = win.toWide(&initial_wide, initial),
        .Flags = 0x1000 | 0x8, // OFN_FILEMUSTEXIST, OFN_NOCHANGEDIR
    };
    if (win.GetOpenFileNameW(&dialog) == 0) return;
    var ascii: [1024]u8 = undefined;
    var n: usize = 0;
    while (n < file.len and file[n] != 0) : (n += 1) ascii[n] = if (file[n] < 128) @intCast(file[n]) else '?';
    var chosen: []const u8 = ascii[0..n];
    if (chosen.len > win.dir.len and std.ascii.eqlIgnoreCase(chosen[0..win.dir.len], win.dir)) chosen = chosen[win.dir.len..];
    manual_len = @min(chosen.len, manual_file.len);
    @memcpy(manual_file[0..manual_len], chosen[0..manual_len]);
    win.setChecked(h_auto, false);
    showFile();
    saveConfig();
}

// --- the log box ------------------------------------------------------------------------------

fn refreshLog() void {
    var buffer: [6000]u8 = undefined;
    var size: i64 = 0;
    const text = win.readTail("TAS\\tas-log.txt", &buffer, &size) orelse return;
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
    win.setText(h_log, out[0..@max(len, 2) - 2]);
    _ = win.SendMessageW(h_log, win.WM_VSCROLL, win.SB_BOTTOM, 0);
}

// --- window -----------------------------------------------------------------------------------

const BN_CLICKED: usize = 0;
const CBN_SELCHANGE: usize = 1;
const EN_CHANGE: usize = 0x0300;

fn wndProc(hwnd: HWND, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    switch (msg) {
        win.WM_CREATE => {
            win.hwnd_main = hwnd;
            createControls();
            loadConfig();
            win.refreshStatus();
            refreshLog();
            _ = win.SetTimer(hwnd, 1, 1000, null);
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == save_timer) {
                saveConfig();
                return 0;
            }
            win.refreshStatus();
            refreshLog();
            // a battle that just ended may have written a newer recording
            if (win.isChecked(h_auto) and std.mem.eql(u8, currentMode(), "play")) showFile();
            return 0;
        },
        win.WM_COMMAND => {
            const code = wparam >> 16;
            const which = std.enums.fromInt(Id, @as(u16, @truncate(wparam))) orelse return 0;
            if (filling) return 0;
            switch (which) {
                .fps, .speed, .seed, .file => if (code == EN_CHANGE) {
                    if (which == .file) keepManualFile();
                    saveSoon();
                },
                .mode => if (code == CBN_SELCHANGE) {
                    showFile();
                    saveConfig();
                },
                else => if (code == BN_CLICKED) switch (which) {
                    .inject => win.startInject(),
                    .open_folder => win.openFolder("TAS"),
                    .browse => browse(),
                    .auto => {
                        showFile();
                        saveConfig();
                    },
                    else => saveConfig(), // the switches
                },
            }
            return 0;
        },
        win.WM_DESTROY => {
            if (save_pending) saveConfig();
            return win.defaultProc(hwnd, msg, wparam, lparam);
        },
        else => return win.defaultProc(hwnd, msg, wparam, lparam),
    }
}

pub fn main() void {
    win.run(L("remielle-tas-gui"), L("remielle-tas"), 560, 540, wndProc);
}
