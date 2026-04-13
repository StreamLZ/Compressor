//! Delta-literal subtraction helpers used by the Fast encoder's entropy
//! path. Direct port of the byte-subtract intrinsics in
//! src/StreamLZ/Compression/Entropy/OffsetEncoder.cs.
//!
//! The Fast encoder stores literals as `literal[i] - byte_at_recent_offset[i]`
//! (the "delta-literal stream"), which the decoder adds back via
//! `copy64Add`. The subtraction is inner-loop hot so we use a @Vector
//! path; scalar fallback is provided for the tail and short inputs.

const std = @import("std");

/// `dst[i] = src[i] - src[i + neg_offset]` for `len` bytes. `neg_offset`
/// is negative when the match source is before `src`. The function may
/// read one 16-byte vector past the end of `src` (the caller must ensure
/// at least 16 bytes of readable memory after `src + len`).
pub fn subtractBytesUnsafe(dst: [*]u8, src: [*]const u8, len: usize, neg_offset: isize) void {
    const V16 = @Vector(16, u8);
    var d = dst;
    var s = src;
    var remaining = len;
    while (remaining > 16) : (remaining -= 16) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        d[0..16].* = out;
        d += 16;
        s += 16;
    }
    // Tail: finish with one last vector subtract (may overshoot but that's
    // OK — caller guarantees 16 bytes of slack).
    if (remaining > 0) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        @memcpy(d[0..remaining], (@as([*]const u8, @ptrCast(&out)))[0..remaining]);
    }
}

/// Exact-length variant. Does not read past `src + len`.
pub fn subtractBytes(dst: [*]u8, src: [*]const u8, len: usize, neg_offset: isize) void {
    const V16 = @Vector(16, u8);
    var d = dst;
    var s = src;
    var remaining = len;
    while (remaining >= 16) : (remaining -= 16) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        d[0..16].* = out;
        d += 16;
        s += 16;
    }
    var i: usize = 0;
    while (i < remaining) : (i += 1) {
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        d[i] = s[i] -% back_ptr[i];
    }
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "subtractBytes matches scalar computation" {
    var src_buf: [64]u8 = undefined;
    for (&src_buf, 0..) |*b, i| b.* = @intCast((i * 7) & 0xFF);
    var dst: [32]u8 = @splat(0);
    const src_offset: usize = 20;
    const src_cursor: [*]const u8 = src_buf[src_offset..].ptr;
    // neg_offset = -8: subtract src[i-8] from src[i]
    subtractBytes(&dst, src_cursor, 16, -8);

    var expected: [16]u8 = undefined;
    for (0..16) |i| expected[i] = src_buf[src_offset + i] -% src_buf[src_offset + i - 8];
    try testing.expectEqualSlices(u8, &expected, dst[0..16]);
}

test "subtractBytes handles non-multiple-of-16 lengths" {
    var src_buf: [64]u8 = undefined;
    for (&src_buf, 0..) |*b, i| b.* = @intCast(i);
    var dst: [16]u8 = @splat(0);
    const src_offset: usize = 16;
    const src_cursor: [*]const u8 = src_buf[src_offset..].ptr;
    subtractBytes(&dst, src_cursor, 11, -8);

    var expected: [11]u8 = undefined;
    for (0..11) |i| expected[i] = src_buf[src_offset + i] -% src_buf[src_offset + i - 8];
    try testing.expectEqualSlices(u8, &expected, dst[0..11]);
    // Bytes past the written range should still be zero.
    for (11..16) |i| try testing.expectEqual(@as(u8, 0), dst[i]);
}
