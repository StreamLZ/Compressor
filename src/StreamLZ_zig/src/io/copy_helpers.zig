//! Port of src/StreamLZ/Common/CopyHelpers.cs — scalar implementations only.
//! Phase 7 will add @Vector-backed SIMD variants behind the same API.

const std = @import("std");

/// Align a pointer up to `alignment` (power of two).
pub inline fn alignPointer(p: [*]u8, alignment: usize) [*]u8 {
    const addr = @intFromPtr(p);
    const aligned = (addr + (alignment - 1)) & ~@as(usize, alignment - 1);
    return @ptrFromInt(aligned);
}

/// Unaligned 8-byte copy. Equivalent to `*(u64*)dst = *(u64*)src`.
pub inline fn copy64(dst: [*]u8, src: [*]const u8) void {
    const v = std.mem.readInt(u64, src[0..8], .little);
    std.mem.writeInt(u64, dst[0..8], v, .little);
}

/// Copies 64 bytes via eight unaligned u64 copies.
pub inline fn copy64Bytes(dst: [*]u8, src: [*]const u8) void {
    inline for (0..8) |i| {
        const off = i * 8;
        const v = std.mem.readInt(u64, src[off..][0..8], .little);
        std.mem.writeInt(u64, dst[off..][0..8], v, .little);
    }
}

/// Copies in 16-byte steps until `dst` reaches `dst_end`.
/// **Caller responsibility:** may overwrite up to 15 bytes past `dst_end`.
/// Provide a safe-space padding on the output buffer (StreamLZ reserves 64).
pub inline fn wildCopy16(dst_in: [*]u8, src_in: [*]const u8, dst_end: [*]const u8) void {
    var d = dst_in;
    var s = src_in;
    std.debug.assert(@intFromPtr(d) <= @intFromPtr(dst_end));
    while (true) {
        const v0 = std.mem.readInt(u64, s[0..8], .little);
        const v1 = std.mem.readInt(u64, s[8..16], .little);
        std.mem.writeInt(u64, d[0..8], v0, .little);
        std.mem.writeInt(u64, d[8..16], v1, .little);
        d += 16;
        s += 16;
        if (@intFromPtr(d) >= @intFromPtr(dst_end)) break;
    }
}

/// Byte-wise add of 8 bytes from `src` and `delta`, storing to `dst`.
/// Used by the Type-0 literal path (delta-coded literals).
pub inline fn copy64Add(dst: [*]u8, src: [*]const u8, delta: [*]const u8) void {
    inline for (0..8) |i| {
        dst[i] = src[i] +% delta[i];
    }
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
    // Copy 32 bytes' worth — wildCopy16 will do 2 iterations of 16 bytes each.
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
