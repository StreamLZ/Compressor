//! Port of src/StreamLZ/Common/CopyHelpers.cs — SIMD via Zig `@Vector`.
//!
//! Design matches the C# reference:
//!   * `copy64Bytes` writes 64 bytes via 4× 16-byte vectors (SSE2-sized);
//!     the C# comment explains that 32-byte AVX2 loads caused frequency
//!     throttling on Arrow Lake and 16-byte is optimal for this workload.
//!   * `wildCopy16` stays on two u64 halves per iteration, sequenced
//!     load-store-load-store so that small-offset LZ match overlaps
//!     propagate correctly. A wider vector load here would break the
//!     read-after-first-write contract; see the overlap test below.
//!   * `copy64Add` adds 8 byte lanes in one vector add.

const std = @import("std");

/// 16-byte unsigned vector (SSE2 lane width).
pub const V16 = @Vector(16, u8);
/// 8-byte unsigned vector (low-half SSE / MMX).
pub const V8 = @Vector(8, u8);

/// Unaligned load of a 16-byte vector.
inline fn loadV16(src: [*]const u8) V16 {
    return @as(*align(1) const V16, @ptrCast(src)).*;
}

/// Unaligned store of a 16-byte vector.
inline fn storeV16(dst: [*]u8, v: V16) void {
    @as(*align(1) V16, @ptrCast(dst)).* = v;
}

/// Unaligned load of an 8-byte vector.
inline fn loadV8(src: [*]const u8) V8 {
    return @as(*align(1) const V8, @ptrCast(src)).*;
}

/// Unaligned store of an 8-byte vector.
inline fn storeV8(dst: [*]u8, v: V8) void {
    @as(*align(1) V8, @ptrCast(dst)).* = v;
}

/// Align a pointer up to `alignment` (power of two).
pub inline fn alignPointer(p: [*]u8, alignment: usize) [*]u8 {
    const addr = @intFromPtr(p);
    const aligned = (addr + (alignment - 1)) & ~@as(usize, alignment - 1);
    return @ptrFromInt(aligned);
}

/// Unaligned 8-byte copy. Maps to a single 64-bit `mov` on x86_64.
pub inline fn copy64(dst: [*]u8, src: [*]const u8) void {
    const v = std.mem.readInt(u64, src[0..8], .little);
    std.mem.writeInt(u64, dst[0..8], v, .little);
}

/// Unaligned 16-byte copy. Maps to a single MOVDQU pair on x86_64.
/// Halves the instruction count vs two `copy64` calls — used by the
/// literal cascade in the High decoder hot loop to keep the inner
/// body small enough to live in the DSB (decoded uop cache).
pub inline fn copy16(dst: [*]u8, src: [*]const u8) void {
    storeV16(dst, loadV16(src));
}

/// Copies 64 bytes via 4× 16-byte vector loads and stores.
pub inline fn copy64Bytes(dst: [*]u8, src: [*]const u8) void {
    const v0 = loadV16(src);
    const v1 = loadV16(src + 16);
    const v2 = loadV16(src + 32);
    const v3 = loadV16(src + 48);
    storeV16(dst, v0);
    storeV16(dst + 16, v1);
    storeV16(dst + 32, v2);
    storeV16(dst + 48, v3);
}

/// Copies in 16-byte steps until `dst` reaches `dst_end`.
/// **Caller responsibility:** may overwrite up to 15 bytes past `dst_end`.
/// Provide a safe-space padding on the output buffer (StreamLZ reserves 64).
///
/// Overlap-safe ordering: when an LZ match copy chains this against
/// `src = dst - N` with `N < 16`, the second half-read needs to pick up
/// the first half-write. We keep the two 8-byte halves as a
/// load-store-load-store sequence — a single 16-byte vector load would
/// read both halves before storing either and miss the write.
pub inline fn wildCopy16(dst_in: [*]u8, src_in: [*]const u8, dst_end: [*]const u8) void {
    var d = dst_in;
    var s = src_in;
    std.debug.assert(@intFromPtr(d) <= @intFromPtr(dst_end));
    while (true) {
        const v0 = std.mem.readInt(u64, s[0..8], .little);
        std.mem.writeInt(u64, d[0..8], v0, .little);
        const v1 = std.mem.readInt(u64, s[8..16], .little);
        std.mem.writeInt(u64, d[8..16], v1, .little);
        d += 16;
        s += 16;
        if (@intFromPtr(d) >= @intFromPtr(dst_end)) break;
    }
}

/// Byte-wise add of 8 bytes from `src` and `delta`, storing to `dst`.
/// Used by the Type-0 literal path (delta-coded literals).
/// Compiles to a single `paddb` + `movq` on x86_64.
pub inline fn copy64Add(dst: [*]u8, src: [*]const u8, delta: [*]const u8) void {
    const vs = loadV8(src);
    const vd = loadV8(delta);
    storeV8(dst, vs +% vd);
}

/// Fills `count` bytes starting at `dst` with `byte`.
pub inline fn memset(dst: [*]u8, byte: u8, count: usize) void {
    @memset(dst[0..count], byte);
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "copy64 performs unaligned 8-byte copy" {
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var dst: [16]u8 = @splat(0);
    copy64(dst[0..].ptr, src[0..].ptr);
    try testing.expectEqualSlices(u8, src[0..8], dst[0..8]);
}

test "copy64Bytes copies 64 bytes" {
    var src: [64]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var dst: [64]u8 = @splat(0);
    copy64Bytes(dst[0..].ptr, src[0..].ptr);
    try testing.expectEqualSlices(u8, &src, &dst);
}

test "wildCopy16 respects dst_end but may overshoot" {
    var src: [48]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var dst: [64]u8 = @splat(0xFF);
    const target_len: usize = 32;
    wildCopy16(dst[0..].ptr, src[0..].ptr, dst[target_len..].ptr);
    try testing.expectEqualSlices(u8, src[0..32], dst[0..32]);
}

test "copy64Add delta-adds 8 bytes" {
    const src = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const delta = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = @splat(0);
    copy64Add(dst[0..].ptr, src[0..].ptr, delta[0..].ptr);
    try testing.expectEqualSlices(u8, &[_]u8{ 11, 22, 33, 44, 55, 66, 77, 88 }, &dst);
}

test "copy64Add wraps on u8 overflow" {
    const src = [_]u8{ 200, 200, 200, 200, 200, 200, 200, 200 };
    const delta = [_]u8{ 100, 100, 100, 100, 100, 100, 100, 100 };
    var dst: [8]u8 = @splat(0);
    copy64Add(dst[0..].ptr, src[0..].ptr, delta[0..].ptr);
    try testing.expectEqualSlices(u8, &[_]u8{ 44, 44, 44, 44, 44, 44, 44, 44 }, &dst);
}

test "wildCopy16 propagates small-offset overlap (LZ match copy)" {
    var buf: [80]u8 = @splat(0);
    @memset(buf[0..8], 'A');
    copy64(buf[8..].ptr, buf[0..].ptr);
    copy64(buf[16..].ptr, buf[8..].ptr);
    wildCopy16(buf[24..].ptr, buf[16..].ptr, buf[70..].ptr);
    for (buf[0..70], 0..) |b, i| {
        if (b != 'A') {
            std.debug.print("byte {d} = 0x{x} (expected 'A' = 0x41)\n", .{ i, b });
            return error.OverlapPropagationFailed;
        }
    }
}
