const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dstrip=false keeps debug info even in ReleaseFast so profilers
    // (VTune, samply, etc.) can attribute samples to source lines.
    const strip = b.option(bool, "strip", "Strip debug symbols (default: optimize-mode default)");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const exe = b.addExecutable(.{
        .name = "streamlz",
        .root_module = root_module,
    });
    // Link libc so std.heap.c_allocator is available — used by the
    // decoder's per-chunk token-array fallback (matches C#'s
    // NativeMemory.Alloc, ~100x faster than page_allocator).
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the streamlz CLI");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
