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

    const gui = b.addExecutable(.{
        .name = "tas-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("src/app.manifest"),
    });
    gui.subsystem = .windows;
    b.installArtifact(gui);

    // The speed tool: a DLL that scales game speed to an FPS target, and its window.
    const speed_dll = b.addLibrary(.{
        .name = "remielle-speed",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/speed_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(speed_dll);

    const speed_gui = b.addExecutable(.{
        .name = "remielle-speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/speed_gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("src/app.manifest"),
    });
    speed_gui.subsystem = .windows;
    b.installArtifact(speed_gui);

    const test_step = b.step("test", "Run the unit tests (tas.txt and speed.txt parsing, seeds, key names)");
    for ([_][]const u8{ "src/tas.zig", "src/speed.zig", "src/keys.zig" }) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
