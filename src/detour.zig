//! Shared detour installer: relocate a method's prologue into an executable stub and patch
//! its entry with `Interception.replace` (12 bytes: mov rax,imm64; push rax; ret).
//!
//! Three prologue shapes are supported:
//!
//!   .plain    the first `prologue.len` bytes are position independent (pushes, `sub rsp`,
//!             `movaps [rsp+..]`, `mov reg,reg`) and are copied verbatim (hitlog.installOne).
//!   .cmp_rip  the same, followed by `80 3D disp32 00` (`cmp byte ptr [rip+disp32], 0` -- the
//!             il2cpp "class initialised" check that opens most methods). The compare is
//!             re-encoded through rax (`mov rax, imm64; cmp byte ptr [rax], 0`) so the flags
//!             the following `je`/`jne` reads are identical; rax is scratch at method entry
//!             and every such method overwrites it before reading it (capture.installAwake).
//!   .jcc8     the same as .plain, followed by a short conditional jump (`7x rel8`, e.g.
//!             System.Random.InternalSample's null check). The jump is re-encoded as a jcc over
//!             two absolute jumps: fall-through, then the original target.
//!
//! The stub ends with `jmp [rip+0]` + the absolute address of the first byte not relocated.
//! `prologue.len` must be >= 12 for `.plain` (the patch overwrites 12 bytes), >= 10 for `.jcc8`
//! (the jump adds 2) and any length for `.cmp_rip` (the compare adds 7). A byte mismatch
//! installs nothing and returns an error, so a client build with a different prologue is left
//! untouched.

const std = @import("std");
const nt = @import("nt.zig");
const Interception = @import("Interception.zig");

extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) callconv(.winapi) ?*anyopaque;
const MEM_COMMIT_RESERVE: u32 = 0x1000 | 0x2000;
const PAGE_EXECUTE_READWRITE: u32 = 0x40;

/// Bytes `Interception.replace` overwrites (mov rax,imm64; push rax; ret).
const patch_len: usize = 12;

pub const Shape = enum { plain, cmp_rip, jcc8 };

pub const Spec = struct {
    /// Bytes that must be at the target, copied verbatim into the stub.
    prologue: []const u8,
    shape: Shape,
};

pub const Error = error{ PrologueMismatch, StubAllocFailed, PrologueTooShort } || nt.Protection.SwapError;

fn jmpAbs(bytes: [*]u8, at: usize, target: usize) void {
    bytes[at + 0] = 0xff; // jmp [rip+0]
    bytes[at + 1] = 0x25;
    bytes[at + 2] = 0x00;
    bytes[at + 3] = 0x00;
    bytes[at + 4] = 0x00;
    bytes[at + 5] = 0x00;
    std.mem.writeInt(u64, bytes[at + 6 ..][0..8], target, .little);
}

/// True when the bytes at `target` are exactly what `spec` expects (including the `cmp` shape).
pub fn matches(target: usize, spec: Spec) bool {
    const actual: [*]const u8 = @ptrFromInt(target);
    if (!std.mem.eql(u8, actual[0..spec.prologue.len], spec.prologue)) return false;
    if (spec.shape == .cmp_rip) {
        const n = spec.prologue.len;
        if (actual[n] != 0x80 or actual[n + 1] != 0x3D or actual[n + 6] != 0x00) return false;
    }
    if (spec.shape == .jcc8) {
        const op = actual[spec.prologue.len];
        if (op < 0x70 or op > 0x7F) return false;
    }
    return true;
}

/// Build the stub for `target`, store its address in `original_slot`, then patch the entry to
/// `replacement`. Returns the stub address.
pub fn install(syscall: *nt.Syscall, target: usize, spec: Spec, original_slot: *u64, comptime replacement: anytype) Error!usize {
    if (spec.shape == .plain and spec.prologue.len < patch_len) return error.PrologueTooShort;
    if (!matches(target, spec)) return error.PrologueMismatch;
    const actual: [*]const u8 = @ptrFromInt(target);
    const n = spec.prologue.len;
    const relocated: usize = switch (spec.shape) {
        .plain => n,
        .cmp_rip => n + 7,
        .jcc8 => n + 2,
    };
    if (relocated < patch_len) return error.PrologueTooShort;
    const stub_len: usize = n + 13 + 14 + 14;
    const stub = VirtualAlloc(null, stub_len, MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE) orelse return error.StubAllocFailed;
    const bytes: [*]u8 = @ptrCast(stub);
    @memcpy(bytes[0..n], actual[0..n]);
    var at = n;
    if (spec.shape == .cmp_rip) {
        const disp = std.mem.readInt(i32, actual[n + 2 ..][0..4], .little);
        const operand: u64 = @intCast(@as(i64, @intCast(target + relocated)) + disp);
        bytes[at] = 0x48; // mov rax, imm64
        bytes[at + 1] = 0xB8;
        std.mem.writeInt(u64, bytes[at + 2 ..][0..8], operand, .little);
        at += 10;
        bytes[at] = 0x80; // cmp byte ptr [rax], 0
        bytes[at + 1] = 0x38;
        bytes[at + 2] = 0x00;
        at += 3;
    }
    if (spec.shape == .jcc8) {
        const rel: i8 = @bitCast(actual[n + 1]);
        const taken: usize = @intCast(@as(i64, @intCast(target + relocated)) + rel);
        bytes[at] = actual[n]; // same condition, over the fall-through jump
        bytes[at + 1] = 14;
        jmpAbs(bytes, at + 2, target + relocated);
        jmpAbs(bytes, at + 16, taken);
        original_slot.* = @intFromPtr(stub);
        _ = try Interception.replace(syscall, target, replacement);
        return @intFromPtr(stub);
    }
    jmpAbs(bytes, at, target + relocated);
    original_slot.* = @intFromPtr(stub);
    _ = try Interception.replace(syscall, target, replacement);
    return @intFromPtr(stub);
}
