const std = @import("std");

pub fn build(b: *std.Build) void {
    // x86_64 baseline by default: the DLL runs on other people's machines, and a "native" build can
    // use instructions their CPUs lack. `-Dcpu=native` still opts in for a local-only build.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows } });
    const optimize = b.standardOptimizeOption(.{});

    const dll = b.addLibrary(.{
        .name = "remielle-tas",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // RtlCaptureStackBackTrace (the per-tick caller column) unwinds through this DLL too.
            .unwind_tables = .sync,
        }),
    });
    b.installArtifact(dll);

    const inject = b.addExecutable(.{
        .name = "tas-inject",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inject.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(inject);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tas.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the unit tests (tas.txt parsing, seeds, key names)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
