const std = @import("std");

const examples = [_][]const u8{
    "hello",
    "overlay",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});
    const wayland_protocols_dep = b.dependency("wayland-protocols", .{});
    const wlr_protocols_dep = b.dependency("wlr-protocols", .{});

    const generated_mod = blk: {
        const scanner = b.addExecutable(.{
            .name = "wayland-scanner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("scanner/scanner.zig"),
                .target = b.graph.host,
            }),
        });
        const run = b.addRunArtifact(scanner);
        run.addFileArg(wayland_dep.path("protocol/wayland.xml"));
        run.addFileArg(wayland_protocols_dep.path("stable/xdg-shell/xdg-shell.xml"));
        run.addFileArg(wayland_protocols_dep.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"));
        run.addFileArg(wayland_protocols_dep.path("stable/viewporter/viewporter.xml"));
        run.addFileArg(wlr_protocols_dep.path("unstable/wlr-layer-shell-unstable-v1.xml"));
        run.addArg("-o");
        const generated_file = run.addOutputFileArg("generated_wl.zig");
        b.getInstallStep().dependOn(&b.addInstallFile(generated_file, "src/generated_wl.zig").step);
        break :blk b.createModule(.{
            .root_source_file = generated_file,
        });
    };

    // In almost all cases, Zig programs should only use this module, not the
    // library defined below, that's for C programs.
    const wl_mod = b.addModule("wl", .{
        .root_source_file = b.path("src/wl.zig"),
        .imports = &.{
            .{ .name = "generated", .module = generated_mod },
        },
    });

    const test_step = b.step("test", "Run all tests and interactive examples)");

    inline for (examples) |example_name| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ example_name ++ ".zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "wl", .module = wl_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = example_name,
            .root_module = example_mod,
        });

        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        b.step("install-" ++ example_name, "").dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step(example_name, "").dependOn(&run.step);
    }

    const test_non_interactive = b.step("test-non-interactive", "Run unit tests (excluding interactive examples)");
    test_step.dependOn(test_non_interactive);

    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wl.zig"),
                .target = target,
                .imports = &.{
                    .{ .name = "generated", .module = generated_mod },
                },
            }),
        });
        const run = b.addRunArtifact(unit_tests);
        test_non_interactive.dependOn(&run.step);
    }
}
