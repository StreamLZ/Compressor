const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Default the x86_64 CPU model to `x86_64_v3` (AVX2 baseline,
    // covering all Intel since Haswell 2013 and all AMD since
    // Excavator 2015). Without this, Zig defaults to `-mcpu=native`
    // which produces a binary that uses host-CPU-specific instructions
    // (BMI2, ADX, AVX-VNNI, etc.) and crashes with STATUS_ILLEGAL_
    // INSTRUCTION (0xc000001d) on older or different-vendor CPUs.
    //
    // Override with `-Dcpu=native` for maximum local perf, or
    // `-Dcpu=baseline` for SSE2-only (most portable).
    const default_query: std.Target.Query = if (builtin.target.cpu.arch == .x86_64) .{
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
    } else .{};
    const target = b.standardTargetOptions(.{ .default_target = default_query });
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
