//! CNBetaWin3.3.4 pins used by il2cpp.zig, taken from thaumiel's generated src/pins.zig (the API table
//! location and checks, and the runtime-readiness anchors). A new client build needs them re-derived.

pub const Method = struct { name: []const u8, params: usize, rva: usize };
pub const Field = struct { name: []const u8, offset: usize };

pub const client = "CNBetaWin3.3.4";
/// The client the hook modules accept. Differs from dumper_size_of_image only in a
/// launch-1 build (`rederive.py prepare`): there the hooks keep the OLD identity so they
/// refuse deterministically while the dumper runs against the new client.
pub const timestamp: u32 = 0x6AB435F6;
pub const size_of_image: u32 = 0x21714000;
pub const dumper_size_of_image: u32 = 0x21714000;
pub const unity_table_offset: usize = 0x1f9b6c8;
pub const api_checks = .{
    .{ 63, "\x48\x83\xec\x28\x48\x8b\x05" },
    .{ 65, "\x48\x8b\x0d\x89\x54\xdb\x04" },
    .{ 73, "\x48\xb8\xbe\x70\x37\x76\x11\x6e\x5a\x5e" },
    .{ 75, "\x8b\x41\x1c\x25\xff\xff\xff\x00" },
    .{ 115, "\x48\x8b\x51\x38\x48\x85\xd2" },
    .{ 152, "\xe9\x6b\x76\x08\x00" },
    .{ 167, "\xb8\x7e\x66\x04\x94\x03\x41\x3c" },
};
pub const main_thread_rva: usize = 0x56dcbc0;
pub const readiness_anchors = .{
    .{ 0x98442c, "\xe8\x2f\xb0\x02\x00\x48\x89\x05\x88\x87\xd5\x04" },
    .{ 0x987180, "\x48\x89\xc6\x48\x8b\x8d\x80\x02\x00\x00\x8b\x41\x20\x89\x46\x10\xc7\x46\x14\x00\x00\x00\x00\x48\x89\x71\x10" },
    .{ 0x9871b8, "\x48\x8b\x7f\x10" },
    .{ 0x9871d6, "\x48\x89\x77\x70" },
};

