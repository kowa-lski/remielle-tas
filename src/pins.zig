//! CNBetaWin3.4.3 pins used by il2cpp.zig: the API table location and checks, and the runtime-readiness
//! anchors. Re-derived 2026-11-10 from the 3.4.3 il2cpp dump's API table (as the live client holds it), the
//! 3.4.3 GameAssembly.dll and the 3.4.3 thaumiel-logger build; see docs/TAS.md "Client updates". A new client build
//! needs them re-derived.

pub const Method = struct { name: []const u8, params: usize, rva: usize };
pub const Field = struct { name: []const u8, offset: usize };

pub const client = "CNBetaWin3.4.3";
/// The client the hook modules accept. Differs from dumper_size_of_image only in a
/// launch-1 build (`rederive.py prepare`): there the hooks keep the OLD identity so they
/// refuse deterministically while the dumper runs against the new client.
pub const timestamp: u32 = 0x6AED722C;
pub const size_of_image: u32 = 0x22C97000;
pub const dumper_size_of_image: u32 = 0x22C97000;
pub const unity_table_offset: usize = 0x20a88c8;
pub const api_checks = .{
    .{ 63, "\x48\x83\xec\x28\x48\x8b\x05" },
    .{ 65, "\x48\x8b\x0d\xf9\x2f\x06\x05" },
    .{ 73, "\x48\xb8\x30\xf6\x06\x5e\xf7\xc7\xdf\x7b" },
    .{ 75, "\x8b\x41\x18\x25\xff\xff\xff\x00" },
    .{ 115, "\x48\x8b\x51\x38\x48\x85\xd2" },
    .{ 152, "\xe9\x1b\x7f\x08\x00" },
    .{ 167, "\xb8\x59\x46\xc0\xc1\x03\x41\x58" },
};
pub const main_thread_rva: usize = 0x5a00c00;
pub const readiness_anchors = .{
    .{ 0x9fb07e, "\xe8\x2d\xb2\x02\x00\x48\x89\x05\x76\x5b\x00\x05" },
    .{ 0x9fde20, "\x48\x89\xc6\x48\x8b\x8d\x30\x02\x00\x00\x8b\x41\x20\x89\x46\x10\xc7\x46\x14\x00\x00\x00\x00\x48\x89\x71\x10" },
    .{ 0x9fde58, "\x48\x8b\x7f\x10" },
    .{ 0x9fde76, "\x48\x89\x77\x70" },
};

/// API slots the 3.4.3 client overwrites with other functions some time after start-up (seen
/// 2026-11-10: slot 63, il2cpp_domain_get at start-up, later holds a function taking arguments).
/// The DLLs inject later than that, so they accept these values in the live table and call the
/// pinned start-up functions (base + dumper-rvas.zon) instead; the code checks verify those.
pub const api_late_swaps = .{
    .{ 13, 0xef8ab00 },
    .{ 22, 0x130e4250 },
    .{ 31, 0x99d3a0 },
    .{ 35, 0x1278b310 },
    .{ 37, 0x1278b340 },
    .{ 39, 0x1278b470 },
    .{ 40, 0x99d3d0 },
    .{ 51, 0x1278ba70 },
    .{ 63, 0x1278c100 },
    .{ 65, 0x99d630 },
    .{ 73, 0x1278c600 },
    .{ 75, 0x99d6a0 },
    .{ 76, 0x1278c850 },
};
