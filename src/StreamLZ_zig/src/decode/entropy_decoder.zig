//! Entropy-stream dispatcher. Port of src/StreamLZ/Decompression/Entropy/EntropyDecoder.cs.
//!
//! Dispatches an entropy block by reading its 2-5 byte header (chunk type in
//! `src[0][6:4]`) and routing to:
//!   * Type 0 — memcopy / raw bytes
//!   * Type 1 — tANS (phase 6, not yet)
//!   * Type 2 — Huffman 2-way split
//!   * Type 3 — RLE  (phase 4b, not yet)
//!   * Type 4 — Huffman 4-way split
//!   * Type 5 — Recursive multi-block (phase 4b, not yet)
//!
//! The decoder writes into `dst_buf` (or, for Type 0 with `force_memmove=false`,
//! hands back a pointer directly into `src`, enabling zero-copy literal streams
//! that the Fast decoder takes advantage of).

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const huffman = @import("huffman_decoder.zig");

pub const DecodeError = error{
    SourceTruncated,
    OutputTooSmall,
    BadChunkHeader,
    UnsupportedChunkType,
    SubDecoderMismatch,
} || huffman.DecodeError;

/// Result of an entropy-block decode. `out_ptr` is where the decoded bytes
/// actually live — for Type 0 zero-copy mode it points into the source buffer;
/// otherwise it equals `dst_buf`.
pub const DecodeResult = struct {
    /// Pointer to the first decoded byte (may equal `dst_buf` or point into `src`).
    out_ptr: [*]const u8,
    /// Number of decoded (output) bytes.
    decoded_size: usize,
    /// Number of source bytes consumed (including the block header).
    bytes_consumed: usize,
};

/// Decode an entropy block starting at `src[0]`.
/// `dst_buf` is the caller's scratch target; the decoder writes at most
/// `output_capacity` bytes there. When `force_memmove=true`, Type 0 copies
/// into `dst_buf`; otherwise the returned `out_ptr` may point into `src`.
pub fn highDecodeBytes(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
) DecodeError!DecodeResult {
    return highDecodeBytesInternal(dst_buf, output_capacity, src_buf, force_memmove, 16);
}

fn highDecodeBytesInternal(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
    max_depth: u32,
) DecodeError!DecodeResult {
    _ = max_depth; // reserved for Type 5 recursive path (phase 4b)

    if (src_buf.len < 2) return error.SourceTruncated;

    const src_start: [*]const u8 = src_buf.ptr;
    const src_end_total: [*]const u8 = src_buf.ptr + src_buf.len;

    const chunk_type: u32 = @intCast((src_buf[0] >> 4) & 0x7);

    // ── Type 0: memcopy / uncompressed ──
    if (chunk_type == 0) {
        var src = src_start;
        var src_size: usize = undefined;

        if (src_buf[0] >= 0x80) {
            // Short-mode 12-bit length header.
            src_size = @intCast(((@as(u32, src_buf[0]) << 8) | src_buf[1]) & constants.block_size_mask_12);
            src += 2;
        } else {
            if (src_buf.len < 3) return error.SourceTruncated;
            const raw: u32 = (@as(u32, src_buf[0]) << 16) | (@as(u32, src_buf[1]) << 8) | @as(u32, src_buf[2]);
            if ((raw & ~@as(u32, 0x3ffff)) != 0) return error.BadChunkHeader;
            src_size = @intCast(raw);
            src += 3;
        }

        if (src_size > output_capacity) return error.OutputTooSmall;
        if (@intFromPtr(src) + src_size > @intFromPtr(src_end_total)) return error.SourceTruncated;

        var out_ptr: [*]const u8 = src;
        if (force_memmove) {
            @memcpy(dst_buf[0..src_size], src[0..src_size]);
            out_ptr = dst_buf;
        }
        return .{
            .out_ptr = out_ptr,
            .decoded_size = src_size,
            .bytes_consumed = @intFromPtr(src) + src_size - @intFromPtr(src_start),
        };
    }

    // ── Types 1–5: compressed block with 3- or 5-byte header ──
    var src_ptr = src_start;
    var src_size: u32 = undefined;
    var dst_size: u32 = undefined;

    if (src_buf[0] >= 0x80) {
        if (src_buf.len < 3) return error.SourceTruncated;
        const bits: u32 = (@as(u32, src_buf[0]) << 16) | (@as(u32, src_buf[1]) << 8) | @as(u32, src_buf[2]);
        src_size = bits & constants.block_size_mask_10;
        dst_size = src_size + ((bits >> 10) & constants.block_size_mask_10) + 1;
        src_ptr += 3;
    } else {
        if (src_buf.len < 5) return error.SourceTruncated;
        const bits: u32 = (@as(u32, src_buf[1]) << 24) |
            (@as(u32, src_buf[2]) << 16) |
            (@as(u32, src_buf[3]) << 8) |
            @as(u32, src_buf[4]);
        src_size = bits & 0x3ffff;
        dst_size = (((bits >> 18) | (@as(u32, src_buf[0]) << 14)) & 0x3FFFF) + 1;
        if (src_size >= dst_size) return error.BadChunkHeader;
        src_ptr += 5;
    }

    if (@intFromPtr(src_ptr) + src_size > @intFromPtr(src_end_total)) return error.SourceTruncated;
    if (dst_size > output_capacity) return error.OutputTooSmall;

    const payload = src_ptr[0..src_size];
    var src_used: usize = undefined;

    switch (chunk_type) {
        2 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 1),
        4 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 2),
        1, 3, 5 => return error.UnsupportedChunkType,
        else => return error.BadChunkHeader,
    }

    if (src_used != src_size) return error.SubDecoderMismatch;
    return .{
        .out_ptr = dst_buf,
        .decoded_size = dst_size,
        .bytes_consumed = @intFromPtr(src_ptr) + src_size - @intFromPtr(src_start),
    };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Type 0 short-mode memcopy zero-copy path" {
    // Header byte: 0x80 | 5 (length 5), next byte = 0, then 5 payload bytes.
    var src: [8]u8 = .{ 0x80, 5, 'a', 'b', 'c', 'd', 'e', 0xFF };
    var dst: [32]u8 = @splat(0);
    const r = try highDecodeBytes(&dst, dst.len, src[0..7], false);
    try testing.expectEqual(@as(usize, 5), r.decoded_size);
    try testing.expectEqual(@as(usize, 7), r.bytes_consumed);
    // Zero-copy: out_ptr points into src at offset 2.
    try testing.expectEqual(@intFromPtr(&src[2]), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "abcde", r.out_ptr[0..r.decoded_size]);
}

test "Type 0 memcopy with force_memmove copies into dst_buf" {
    var src: [7]u8 = .{ 0x80, 5, 'h', 'e', 'l', 'l', 'o' };
    var dst: [16]u8 = @splat(0);
    const r = try highDecodeBytes(&dst, dst.len, &src, true);
    try testing.expectEqual(@intFromPtr(&dst), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "hello", dst[0..5]);
}

test "unsupported chunk types return error" {
    // Type 3 (RLE) with short-mode header: 0x80 | (3<<4) = 0xB0
    var src: [3]u8 = .{ 0xB0, 0, 0 };
    var dst: [16]u8 = undefined;
    try testing.expectError(error.UnsupportedChunkType, highDecodeBytes(&dst, dst.len, &src, false));
}

test "truncated source returns SourceTruncated" {
    const src = [_]u8{0x80};
    var dst: [16]u8 = undefined;
    try testing.expectError(error.SourceTruncated, highDecodeBytes(&dst, dst.len, &src, false));
}
