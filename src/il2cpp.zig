//! il2cpp metadata lookups for the TAS DLL, reduced from thaumiel's dumper (v7; AGPL-3.0, see
//! README.md): the client hides il2cpp's exports, so the API is read from the table Unity has
//! already populated (UnityPlayer.dll + pins.unity_table_offset), validated against pinned RVAs and
//! code bytes, and used only after the runtime reports ready. No dump is written.
const std = @import("std");
const w = std.os.windows;
const log = std.log.scoped(.il2cpp);
const pins = @import("pins.zig");
const expected = @import("dumper-rvas.zon");
const readiness = @import("runtime_readiness.zig");

extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn ReadProcessMemory(w.HANDLE, ?*const anyopaque, [*]u8, usize, *usize) callconv(.winapi) w.BOOL;

var table: [194]usize = undefined;
var table_valid = false;
var game: usize = 0;
var game_size: usize = 0;

fn peek(address: usize, out: []u8) bool {
    if (address == 0) return false;
    var got: usize = 0;
    return ReadProcessMemory(GetCurrentProcess(), @ptrFromInt(address), out.ptr, out.len, &got) != .FALSE and got == out.len;
}

fn word(address: usize) !usize {
    var bytes: [8]u8 = undefined;
    if (!peek(address, &bytes)) return error.UnreadablePointer;
    return std.mem.readInt(usize, &bytes, .little);
}

fn api(comptime T: type, index: usize) T {
    return @ptrFromInt(table[index]);
}
const F0 = *const fn () callconv(.c) usize;
const F1 = *const fn (usize) callconv(.c) usize;
const F2 = *const fn (usize, usize) callconv(.c) usize;
const Iter = *const fn (usize, *usize) callconv(.c) usize;

/// A NUL-terminated name read only through ReadProcessMemory (never std.mem.span on a game pointer).
fn name(address: usize, buffer: []u8) ![]const u8 {
    if (address == 0) return error.NullName;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = @min(@min(64, buffer.len - offset), 4096 - ((address + offset) & 4095));
        if (!peek(address + offset, buffer[offset .. offset + count])) return error.UnreadableName;
        for (buffer[offset .. offset + count], 0..) |ch, i| {
            if (ch == 0) return buffer[0 .. offset + i];
            if (ch < 32) return error.InvalidName;
        }
        offset += count;
    }
    return error.NameTooLong;
}

/// Read Unity's API table and check it against the pins (pointers and known code bytes).
fn validateTable() !void {
    if (table_valid) return;
    const g = GetModuleHandleA("GameAssembly.dll") orelse return error.NoGameAssembly;
    const unity = GetModuleHandleA("UnityPlayer.dll") orelse return error.NoUnityPlayer;
    game = @intFromPtr(g);
    var header: [4096]u8 = undefined;
    if (!peek(game, &header)) return error.UnreadableHeader;
    const pe = std.mem.readInt(u32, header[60..64], .little);
    if (pe > header.len - 0x90) return error.InvalidPE;
    game_size = std.mem.readInt(u32, header[pe + 0x50 ..][0..4], .little);
    if (game_size != pins.dumper_size_of_image) return error.UnsupportedClient;
    if (!peek(@intFromPtr(unity) + pins.unity_table_offset, std.mem.asBytes(&table))) return error.TableUnreadable;
    var mismatches: usize = 0;
    inline for (expected, 0..) |rva, i| {
        if (rva == 0) {
            if (table[i] < game or table[i] >= game + game_size) mismatches += 1;
        } else if (table[i] != game + rva) {
            log.err("API[{d}] expected RVA 0x{X}, actual 0x{X}", .{ i, rva, table[i] -% game });
            mismatches += 1;
        }
    }
    if (mismatches != 0) return error.TableMismatch;
    inline for (pins.api_checks) |check| {
        var bytes: [check[1].len]u8 = undefined;
        if (!peek(table[check[0]], &bytes) or !std.mem.eql(u8, &bytes, check[1])) return error.CodeMismatch;
    }
    table_valid = true;
    log.info("validated " ++ pins.client ++ ": GameAssembly=0x{X}", .{game});
}

const Readiness = enum { waiting, ready, failed };
var readiness_validated = false;

fn runtimeReady() Readiness {
    if (!table_valid) {
        const g = GetModuleHandleA("GameAssembly.dll") orelse return .waiting;
        const unity = GetModuleHandleA("UnityPlayer.dll") orelse return .waiting;
        const first = word(@intFromPtr(unity) + pins.unity_table_offset + 63 * @sizeOf(usize)) catch return .waiting;
        if (first != @intFromPtr(g) + expected[63]) return .waiting;
        validateTable() catch |err| {
            log.err("API table check failed: {t} (is this client " ++ pins.client ++ "?)", .{err});
            return .failed;
        };
    }
    if (!readiness_validated) {
        readiness.validate(peek, game) catch |err| {
            log.err("readiness anchors failed: {t}", .{err});
            return .failed;
        };
        readiness_validated = true;
    }
    return if (readiness.ready(peek, game)) .ready else .waiting;
}

/// Blocks (polling every 50 ms, up to `timeout_ms`) until the il2cpp runtime is initialised.
pub fn waitReady(timeout_ms: u64) !void {
    const t0 = GetTickCount64();
    while (true) {
        switch (runtimeReady()) {
            .ready => return,
            .failed => return error.RuntimeCheckFailed,
            .waiting => {},
        }
        if (GetTickCount64() - t0 > timeout_ms) return error.RuntimeNotReady;
        Sleep(50);
    }
}

// Lookups need the calling thread attached to the il2cpp domain; begin/end bracket them.
threadlocal var lookup_attached: usize = 0;

pub fn beginLookup() !void {
    if (!table_valid) return error.TableNotValidated;
    if (lookup_attached != 0) return error.LookupAlreadyAttached;
    const domain = api(F0, 63)();
    if (domain == 0) return error.NoDomain;
    lookup_attached = api(F1, 152)(domain);
    if (lookup_attached == 0) return error.AttachFailed;
}

pub fn endLookup() void {
    if (lookup_attached == 0) return;
    const release: *const fn (usize) callconv(.c) void = @ptrFromInt(table[153]);
    release(lookup_attached);
    lookup_attached = 0;
}

fn requireLookup() !void {
    if (!table_valid) return error.TableNotValidated;
    if (lookup_attached == 0) return error.LookupNotAttached;
}

/// Exact namespace and name across all images (nested classes have an empty namespace).
pub fn findClass(namespace: []const u8, class_name: []const u8) !usize {
    try requireLookup();
    const domain = api(F0, 63)();
    if (domain == 0) return error.NoDomain;
    var count: usize = 0;
    const assemblies = api(Iter, 65)(domain, &count);
    if (assemblies == 0 or count == 0 or count > 4096) return error.InvalidAssemblies;
    var found: ?usize = null;
    for (0..count) |a| {
        const assembly = try word(assemblies + a * @sizeOf(usize));
        if (assembly == 0) return error.NullAssembly;
        const img = api(F1, 22)(assembly);
        if (img == 0) return error.NullImage;
        const count_classes = api(F1, 167)(img);
        if (count_classes > 1000000) return error.InvalidClassCount;
        for (0..count_classes) |i| {
            const klass = api(F2, 168)(img, i);
            if (klass == 0) return error.NullClass;
            var cn: [2048]u8 = undefined;
            var ns: [2048]u8 = undefined;
            if (!std.mem.eql(u8, try name(api(F1, 37)(klass), &cn), class_name)) continue;
            if (!std.mem.eql(u8, try name(api(F1, 39)(klass), &ns), namespace)) continue;
            if (found != null) return error.AmbiguousClass;
            found = klass;
        }
    }
    return found orelse error.ClassNotFound;
}

fn methodAt(klass: usize, method_name: []const u8, param_count: usize, expected_rva: usize, want_info: bool) !usize {
    try requireLookup();
    if (klass == 0) return error.NullClass;
    var iter: usize = 0;
    var n: usize = 0;
    var candidates: usize = 0;
    while (true) {
        const method = api(Iter, 35)(klass, &iter);
        if (method == 0) break;
        n += 1;
        if (n > 65536) return error.MethodIterationLimit;
        var buffer: [2048]u8 = undefined;
        if (!std.mem.eql(u8, try name(api(F1, 115)(method), &buffer), method_name)) continue;
        if (api(F1, 121)(method) != param_count) continue;
        candidates += 1;
        const native = try word(method);
        if (native < game or native - game >= game_size or native == 0) continue;
        if (native - game == expected_rva) return if (want_info) method else native;
    }
    return if (candidates == 0) error.MethodNotFound else error.RvaMismatch;
}

/// Code address of the method with that name and parameter count whose code is at `expected_rva`.
pub fn findMethodAt(klass: usize, method_name: []const u8, param_count: usize, expected_rva: usize) !usize {
    return methodAt(klass, method_name, param_count, expected_rva, false);
}

/// The MethodInfo* (what runtime_invoke takes) of that method.
pub fn findMethodInfoAt(klass: usize, method_name: []const u8, param_count: usize, expected_rva: usize) !usize {
    return methodAt(klass, method_name, param_count, expected_rva, true);
}

/// Field offset, searching the parent chain; a duplicate name is an error.
pub fn findField(klass: usize, field_name: []const u8) !usize {
    try requireLookup();
    if (klass == 0) return error.NullClass;
    var found: ?usize = null;
    var current = klass;
    var depth: usize = 0;
    while (current != 0) : (current = api(F1, 40)(current)) {
        depth += 1;
        if (depth > 256) return error.ParentIterationLimit;
        var iter: usize = 0;
        var n: usize = 0;
        while (true) {
            const field = api(Iter, 31)(current, &iter);
            if (field == 0) break;
            n += 1;
            if (n > 65536) return error.FieldIterationLimit;
            var buffer: [2048]u8 = undefined;
            if (!std.mem.eql(u8, try name(api(F1, 73)(field), &buffer), field_name)) continue;
            if (found != null) return error.AmbiguousField;
            found = api(F1, 75)(field);
        }
    }
    return found orelse error.FieldNotFound;
}

/// Absolute address in the validated API table.
pub fn apiSlot(index: usize) !usize {
    if (!table_valid) return error.TableNotValidated;
    if (index >= table.len) return error.SlotOutOfRange;
    return table[index];
}

/// GameAssembly.dll base.
pub fn gameBase() !usize {
    if (!table_valid) return error.TableNotValidated;
    return game;
}

/// Class name of an object (`[obj+0]`), for messages.
pub fn objectClassName(object: usize, buffer: []u8) ![]const u8 {
    if (!table_valid) return error.TableNotValidated;
    return name(api(F1, 37)(try word(object)), buffer);
}
