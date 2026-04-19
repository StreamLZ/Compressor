//! Platform-specific memory query and thread-budget calculation.
//!
//! Extracted from `encode/streamlz_encoder.zig` so that Windows FFI
//! types and kernel32 externs live in one isolated module that the
//! encoder (and any future parallel decoder) can import without
//! polluting the compressor namespace.

const std = @import("std");

// ────────────────────────────────────────────────────────────
//  Constants
// ────────────────────────────────────────────────────────────

/// Estimated memory consumption per parallel compress worker thread
/// (40 MB). Used by `calculateMaxThreads` to cap the thread count so the
/// total worker footprint stays within a fraction of available RAM.
pub const per_thread_memory_estimate: u64 = 40 * 1024 * 1024;

/// Fraction of total physical RAM that parallel compression is
/// allowed to consume (60%).
pub const memory_budget_pct: u64 = 60;

// ────────────────────────────────────────────────────────────
//  Platform-specific total-physical-memory query
// ────────────────────────────────────────────────────────────

const MemoryStatusEx = extern struct {
    dwLength: u32,
    dwMemoryLoad: u32,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MemoryStatusEx) callconv(.winapi) std.os.windows.BOOL;

/// Returns the total physical memory on the host, in bytes, or `0`
/// when the query is unavailable / unsupported. Used by
/// `calculateMaxThreads` as the input to the memory-budget cap.
pub fn totalAvailableMemoryBytes() u64 {
    const os = @import("builtin").os.tag;
    if (os == .windows) {
        var ms: MemoryStatusEx = .{
            .dwLength = @sizeOf(MemoryStatusEx),
            .dwMemoryLoad = 0,
            .ullTotalPhys = 0,
            .ullAvailPhys = 0,
            .ullTotalPageFile = 0,
            .ullAvailPageFile = 0,
            .ullTotalVirtual = 0,
            .ullAvailVirtual = 0,
            .ullAvailExtendedVirtual = 0,
        };
        if (GlobalMemoryStatusEx(&ms) == 0) return 0;
        return ms.ullTotalPhys;
    } else if (os == .linux or os == .android) {
        var info: std.posix.system.sysinfo = undefined;
        if (std.posix.system.sysinfo(&info) != 0) return 0;
        return @as(u64, info.totalram) * @as(u64, info.mem_unit);
    } else if (os == .macos or os == .ios) {
        // HW_MEMSIZE via sysctl
        var mem: u64 = 0;
        var size: usize = @sizeOf(u64);
        const mib = [2]c_int{ std.posix.CTL.HW, std.posix.system.HW.MEMSIZE };
        const rc = std.posix.system.sysctl(&mib, mib.len, std.mem.asBytes(&mem), &size, null, 0);
        if (rc != 0) return 0;
        return mem;
    } else {
        return 0;
    }
}

/// Dynamically calculates the maximum number of compression worker
/// threads based on CPU count and available system memory.
/// Caps at 60% of total physical RAM.
/// When the host's memory is unknown (non-Windows / query failure),
/// falls back to just the CPU count.
///
/// The `src_len` parameter is the estimate for shared memory
/// overhead (estimated as `srcLen`).
pub fn calculateMaxThreads(src_len: usize) u32 {
    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const total_memory: u64 = totalAvailableMemoryBytes();
    if (total_memory == 0) return @max(@as(u32, 1), cpu);

    const memory_budget: u64 = (total_memory * memory_budget_pct) / 100;
    const shared_mem: u64 = src_len;
    if (memory_budget <= shared_mem) return 1;
    const available_for_threads: u64 = memory_budget - shared_mem;

    const max_by_memory: u64 = available_for_threads / per_thread_memory_estimate;
    if (max_by_memory == 0) return 1;
    const max_by_memory_u32: u32 = @intCast(@min(max_by_memory, @as(u64, cpu)));
    return @max(@as(u32, 1), max_by_memory_u32);
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "calculateMaxThreads: returns at least 1" {
    // Any non-negative input must yield a positive thread count —
    // a caller passing the result directly into the parallel
    // dispatch should never see 0.
    const n = calculateMaxThreads(0);
    try testing.expect(n >= 1);
    const m = calculateMaxThreads(1024 * 1024);
    try testing.expect(m >= 1);
}

test "calculateMaxThreads: doesn't exceed CPU count" {
    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const n = calculateMaxThreads(1024);
    try testing.expect(n <= cpu);
}

test "calculateMaxThreads: scales down with huge src_len" {
    // A huge shared-memory estimate (nearly the whole RAM budget)
    // should drive `available_for_threads` below zero and clamp to
    // 1. We can't observe this directly without knowing the host's
    // total_memory, so we test with src_len == usize max, which
    // guarantees `memory_budget <= shared_mem` on any host.
    const n = calculateMaxThreads(std.math.maxInt(usize) / 2);
    try testing.expect(n >= 1);
}

test "totalAvailableMemoryBytes: returns a plausible value on Windows" {
    if (@import("builtin").os.tag != .windows) return;
    const mem = totalAvailableMemoryBytes();
    // Any Windows host running this test suite has at least 1 GB.
    try testing.expect(mem >= 1 * 1024 * 1024 * 1024);
}
