//! tas-gui.exe: a small window for the game folder. It edits tas.txt (mode, file, fps, speed, seed,
//! the switches), loads remielle-tas.dll into the game (the Inject button, as tas-inject.exe does)
//! and shows whether the game is running, whether the TAS is in it, and the end of TAS\tas-log.txt.
const std = @import("std");
const injector = @import("injector.zig");
const win = @import("win.zig");
const L = win.L;
const HWND = win.HWND;

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

var h_mode: HWND = undefined;
var h_file: HWND = undefined;
var h_fps: HWND = undefined;
var h_speed: HWND = undefined;
var h_seed: HWND = undefined;
var h_saved: HWND = undefined;
var h_log: HWND = undefined;
var h_switch: [switches.len]HWND = undefined;
var log_size: i64 = -1;

fn id(i: Id) u16 {
    return @intFromEnum(i);
}

fn createControls() void {
    win.gameBox(injector.dll_name, "TAS\\tas-dll.log", id(.inject), id(.open_folder), L("Open TAS folder"));

    win.group(L("Next battle (tas.txt)"), 12, 100, 536, 250);
    _ = win.label(L("Mode"), 26, 126, 60);
    h_mode = win.dropdown(90, 124, 120, id(.mode), &modes);
    _ = win.label(L("Seed"), 300, 126, 40);
    h_seed = win.edit(344, 124, 90, id(.seed), L("none"));
    _ = win.label(L("File"), 26, 160, 60);
    h_file = win.edit(90, 158, 344, id(.file), L("TAS\\run.inputtrace"));
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
    _ = win.button(L("Save"), 424, 312, 110, id(.save), true);
    h_saved = win.control(L("STATIC"), L("Read at the start of every battle."), 0, 0, 26, 318, 380, 22, 0);

    win.group(L("TAS log"), 12, 358, 536, 170);
    h_log = win.control(L("EDIT"), L(""), win.ES_MULTILINE | win.ES_READONLY | win.ES_AUTOVSCROLL | win.WS_VSCROLL, win.WS_EX_CLIENTEDGE, 24, 380, 512, 138, 0);
    win.setFont(h_log, win.font_mono);
}

// --- tas.txt ----------------------------------------------------------------------------------

const config_name = "tas.txt";
const Keys = enum { mode, file, fps, speed, seed, sync, pin_team, pin_spawn, pin_assets, pin_random };

fn loadConfig() void {
    var buffer: [16 * 1024]u8 = undefined;
    const text = win.readFile(config_name, &buffer) orelse "";
    var mode: usize = 0;
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
            .file => win.setText(h_file, kv.value),
            .fps => win.setText(h_fps, kv.value),
            .speed => win.setText(h_speed, kv.value),
            .seed => win.setText(h_seed, kv.value),
            else => for (switches, 0..) |sw, i| {
                if (std.mem.eql(u8, sw.key, kv.key)) win.setChecked(h_switch[i], win.isOn(kv.value));
            },
        }
    }
    win.select(h_mode, mode);
}

/// Rewrites tas.txt with the window's values: each key's line is replaced in place (its trailing
/// comment kept), duplicates are commented out, every other line is kept, and missing keys are
/// added at the end.
fn saveConfig() void {
    var values: [@typeInfo(Keys).@"enum".fields.len][]const u8 = undefined;
    var bufs: [4][300]u8 = undefined;
    values[@intFromEnum(Keys.mode)] = modes[@min(win.selection(h_mode), modes.len - 1)];
    values[@intFromEnum(Keys.file)] = win.getText(h_file, &bufs[0]);
    values[@intFromEnum(Keys.fps)] = win.getText(h_fps, &bufs[1]);
    values[@intFromEnum(Keys.speed)] = win.getText(h_speed, &bufs[2]);
    values[@intFromEnum(Keys.seed)] = win.getText(h_seed, &bufs[3]);
    for (switches, 0..) |sw, i| {
        const key = std.meta.stringToEnum(Keys, sw.key).?;
        values[@intFromEnum(key)] = if (win.isChecked(h_switch[i])) "on" else "off";
    }

    const fps = std.fmt.parseInt(u32, values[@intFromEnum(Keys.fps)], 10) catch 0;
    if (fps < 10 or fps > 1000) return win.complain(L("FPS must be a whole number from 10 to 1000 (60 is the one that works)."));
    const speed = std.fmt.parseFloat(f32, values[@intFromEnum(Keys.speed)]) catch -1;
    if (speed < 0 or speed > 16) return win.complain(L("Speed must be a number from 0 to 16 (1 = real time, 0 = as fast as possible)."));
    const seed = values[@intFromEnum(Keys.seed)];
    if (seed.len > 0) _ = std.fmt.parseInt(i32, seed, 0) catch return win.complain(L("Seed must be a whole number, or empty for none."));
    if (std.mem.eql(u8, values[@intFromEnum(Keys.mode)], "play") and values[@intFromEnum(Keys.file)].len == 0)
        return win.complain(L("Play needs a recording in File."));

    var original_buffer: [16 * 1024]u8 = undefined;
    var out: [20 * 1024]u8 = undefined;
    const text = rewriteConfig(win.readFile(config_name, &original_buffer), &values, &out);
    if (!win.writeFile(config_name, text)) return win.complain(L("Could not write tas.txt."));
    win.setText(h_saved, "Saved. The next battle uses these settings.");
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
    win.setText(h_file, chosen);
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
            win.refreshStatus();
            refreshLog();
            return 0;
        },
        win.WM_COMMAND => {
            if (wparam >> 16 != 0) return 0; // BN_CLICKED only
            const which = std.enums.fromInt(Id, @as(u16, @truncate(wparam))) orelse return 0;
            switch (which) {
                .inject => win.startInject(),
                .open_folder => win.openFolder("TAS"),
                .browse => browse(),
                .save => saveConfig(),
                else => {},
            }
            return 0;
        },
        else => return win.defaultProc(hwnd, msg, wparam, lparam),
    }
}

pub fn main() void {
    win.run(L("remielle-tas-gui"), L("remielle-tas"), 560, 540, wndProc);
}
