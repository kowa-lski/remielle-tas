//! CNBetaWin3.3.4 read-only bootstrap gate. See docs/startup-crash-20260920.md.
//! Runtime::Init publishes the attached main thread before building its domain context.
//! Wait for the context store near the end of Init; never call an API to probe readiness.
//!
//! Re-traced 3.3.3 -> 3.3.4 (2026-09-25) by the same structural method, self-checked by first
//! reproducing every 3.3.3 value from the archived 3.3.3 binary:
//!  - Thread::Attach is slot 152's jmp target (0x99b9b0 -> 0x9af460).
//!  - Both builds contain exactly TWO `call Thread::Attach; mov [rip+d],rax` sites, in the same
//!    order; the second is Runtime::Init's, which publishes the main thread. That is anchor 1
//!    (0x97094d -> 0x98442c), and its disp32 gives main_thread_rva (0x5698000 -> 0x56dcbc0).
//!  - Anchors 2-4 sit in one function (0x9736d0 -> 0x987180), located by its core with the rbp
//!    displacement wildcarded (unique in both builds). Anchor 1 did NOT move by anchors 2-4's
//!    delta, which is why it is found through Thread::Attach instead.
//!  - Anchor 2's only byte change is its stack displacement, `mov rcx,[rbp+0x1f0]` ->
//!    `[rbp+0x280]` (back to the 3.3.2 frame layout): same instruction, same semantics.
//!    Anchors 3 and 4 are byte-identical, at the same +0x38/+0x56 offsets from anchor 2.
const std = @import("std");

// From src/pins.zig: `tools/update/rederive.py table` re-traces them by the method above.
const pins = @import("pins.zig");
pub const main_thread_rva: usize = pins.main_thread_rva;
pub const anchors = pins.readiness_anchors;

pub fn validate(comptime read: anytype, base: usize) !void {
    inline for (anchors) |anchor| {
        var bytes: [anchor[1].len]u8 = undefined;
        if (!read(base + anchor[0], &bytes) or !std.mem.eql(u8, &bytes, anchor[1]))
            return error.ReadinessCodeMismatch;
    }
}

fn word(comptime read: anytype, address: usize) ?usize {
    var bytes: [8]u8 = undefined;
    if (!read(address, &bytes)) return null;
    return std.mem.readInt(usize, &bytes, .little);
}

/// A context on the main thread proves thread attachment, domain construction and metadata
/// initialization have run. Later startup work may continue; lookup uses IL2CPP's own locks.
/// All pointer reads use ReadProcessMemory in production, so early/unreadable state just waits.
pub const Snapshot = struct {
    main: ?usize = null,
    internal: ?usize = null,
    context: ?usize = null,
    pub fn isReady(self: Snapshot) bool {
        return if (self.context) |context| context != 0 else false;
    }
};

pub fn snapshot(comptime read: anytype, base: usize) Snapshot {
    var state: Snapshot = .{};
    state.main = word(read, base + main_thread_rva);
    const main = state.main orelse return state;
    if (main == 0) return state;
    state.internal = word(read, main + 0x10);
    const internal = state.internal orelse return state;
    if (internal == 0) return state;
    state.context = word(read, internal + 0x70);
    return state;
}

pub fn ready(comptime read: anytype, base: usize) bool {
    return snapshot(read, base).isReady();
}

const Fixture = struct {
    var main: usize = 0;
    var internal: usize = 0;
    var context: usize = 0;
    var unreadable: bool = false;
    var corrupt_code: bool = false;
    fn read(address: usize, out: []u8) bool {
        if (unreadable) return false;
        inline for (anchors) |anchor| {
            if (address == anchor[0] and out.len == anchor[1].len) {
                @memcpy(out, anchor[1]);
                if (corrupt_code) out[0] ^= 1;
                return true;
            }
        }
        if (out.len != 8) return false;
        const value = switch (address) {
            main_thread_rva => main,
            0x1010 => internal,
            0x2070 => context,
            else => return false,
        };
        std.mem.writeInt(usize, out[0..8], value, .little);
        return true;
    }
};

test "wait through main-thread publication until its context is initialized" {
    Fixture.main = 0;
    Fixture.internal = 0;
    Fixture.context = 0;
    try std.testing.expect(!ready(Fixture.read, 0));
    Fixture.main = 0x1000;
    try std.testing.expect(!ready(Fixture.read, 0));
    Fixture.internal = 0x2000;
    try std.testing.expect(!ready(Fixture.read, 0));
    Fixture.context = 0x3000;
    try std.testing.expect(ready(Fixture.read, 0));
    Fixture.unreadable = true;
    defer Fixture.unreadable = false;
    try std.testing.expect(!ready(Fixture.read, 0));
}

test "client instruction drift disables readiness rather than guessing offsets" {
    try validate(Fixture.read, 0);
    Fixture.corrupt_code = true;
    defer Fixture.corrupt_code = false;
    try std.testing.expectError(error.ReadinessCodeMismatch, validate(Fixture.read, 0));
}
