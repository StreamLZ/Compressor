//! Entropy-stream dispatcher. Port of src/StreamLZ/Decompression/Entropy/EntropyDecoder.cs.
//!
//! Dispatches an entropy block by reading its 2-5 byte header (chunk type in
//! `src[0][6:4]`) and routing to:
//!   * Type 0 — memcopy / raw bytes
//!   * Type 1 — tANS
//!   * Type 2 — Huffman 2-way split
//!   * Type 3 — RLE
//!   * Type 4 — Huffman 4-way split
//!   * Type 5 — Recursive multi-block (simple N-split path supported;
//!     the multi-array bit-7-set variant lands in a follow-up)
//!
//! The decoder writes into `dst_buf` (or, for Type 0 with `force_memmove=false`,
//! hands back a pointer directly into `src`, enabling zero-copy literal streams
//! that the Fast decoder takes advantage of).

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const huffman = @import("huffman_decoder.zig");
const tans = @import("tans_decoder.zig");

pub const DecodeError = error{
    SourceTruncated,
    OutputTooSmall,
    BadChunkHeader,
    UnsupportedChunkType,
    SubDecoderMismatch,
    RleStreamMismatch,
    RecursiveDepthExceeded,
    MultiArrayNotSupported,
} || huffman.DecodeError || tans.DecodeError;

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
/// `dst_buf` is the caller's output target; the decoder writes at most
/// `output_capacity` bytes there. When `force_memmove=true`, Type 0 copies
/// into `dst_buf`; otherwise the returned `out_ptr` may point into `src`.
/// `scratch` / `scratch_end` is the workspace for sub-decoders (tANS LUT,
/// RLE command expansion, recursive sub-block intermediate buffers).
/// When `dst_buf` aliases `scratch`, the internal code advances scratch
/// past `dst_size` before handing it to sub-decoders — matching the C#
/// `dst == scratch` alias check in `EntropyDecoder.High_DecodeBytesInternal`.
pub fn highDecodeBytes(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
    scratch: [*]u8,
    scratch_end: [*]u8,
) DecodeError!DecodeResult {
    return highDecodeBytesInternal(dst_buf, output_capacity, src_buf, force_memmove, scratch, scratch_end, 16);
}

fn highDecodeBytesInternal(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
    scratch_in: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!DecodeResult {
    if (max_depth == 0) return error.RecursiveDepthExceeded;

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

    // dst == scratch alias handling: caller may have passed the same
    // pointer for both, in which case sub-decoder workspace must start
    // past the decoded output. Port of the C# check at
    // `EntropyDecoder.High_DecodeBytesInternal` lines 770-778.
    var scratch_ptr: [*]u8 = scratch_in;
    if (@intFromPtr(dst_buf) == @intFromPtr(scratch_in)) {
        if (@intFromPtr(scratch_in) + dst_size > @intFromPtr(scratch_end)) return error.OutputTooSmall;
        scratch_ptr = scratch_in + dst_size;
    }

    switch (chunk_type) {
        2 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 1),
        4 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 2),
        1 => src_used = try tans.highDecodeTans(
            payload.ptr,
            payload.len,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
        ),
        3 => src_used = try decodeRle(
            payload,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
            max_depth,
        ),
        5 => src_used = try decodeRecursive(
            payload,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
            max_depth,
        ),
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
//  Type 3 — RLE decoder
// ────────────────────────────────────────────────────────────

/// Run-length decoder. Commands walk backward from the end of the block,
/// literals forward from `src[1]`. The first byte flags whether the
/// command stream is entropy-coded (via a nested `highDecodeBytes` call).
fn decodeRle(
    src: []const u8,
    dst_buf: [*]u8,
    dst_size: usize,
    scratch: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!usize {
    if (src.len <= 1) {
        if (src.len != 1) return error.SourceTruncated;
        @memset(dst_buf[0..dst_size], src[0]);
        return 1;
    }

    var dst = dst_buf;
    const dst_end: [*]u8 = dst_buf + dst_size;

    const src_start: [*]const u8 = src.ptr;
    var cmd_ptr: [*]const u8 = src_start + 1;
    var cmd_ptr_end: [*]const u8 = src_start + src.len;

    // Optional entropy-coded command prefix.
    var scratch_ptr: [*]u8 = scratch;
    if (src[0] != 0) {
        const remaining: []const u8 = src_start[0..src.len];
        // Nested entropy decode: pass the advanced scratch cursor as
        // both dst AND scratch. `highDecodeBytesInternal` will detect
        // the alias and shift scratch past the decoded output before
        // routing to sub-decoders.
        const res = try highDecodeBytesInternal(
            scratch_ptr,
            @intFromPtr(scratch_end) - @intFromPtr(scratch_ptr),
            remaining,
            true,
            scratch_ptr,
            scratch_end,
            max_depth - 1,
        );
        const n = res.bytes_consumed;
        const dec_size = res.decoded_size;
        const tail_size: usize = src.len - n;
        const cmd_len: usize = tail_size + dec_size;
        if (cmd_len > @intFromPtr(scratch_end) - @intFromPtr(scratch_ptr)) return error.OutputTooSmall;

        // Append the un-decoded tail bytes after the decoded prefix.
        const dst_slot: [*]u8 = scratch_ptr;
        @memcpy(dst_slot[dec_size .. dec_size + tail_size], src_start[n .. n + tail_size]);

        cmd_ptr = dst_slot;
        cmd_ptr_end = dst_slot + cmd_len;
        scratch_ptr += cmd_len;
    }

    var rle_byte: u8 = 0;

    while (@intFromPtr(cmd_ptr) < @intFromPtr(cmd_ptr_end)) {
        const cmd: u32 = (cmd_ptr_end - 1)[0];

        if ((cmd -% 1) >= constants.rle_short_command_threshold) {
            cmd_ptr_end -= 1;
            const bytes_to_copy: usize = @intCast((~cmd) & 0xF);
            const bytes_to_rle: usize = @intCast(cmd >> 4);
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy + bytes_to_rle) return error.RleStreamMismatch;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            cmd_ptr += bytes_to_copy;
            dst += bytes_to_copy;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else if (cmd >= 0x10) {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const data: u32 = word -% 4096;
            cmd_ptr_end -= 2;
            const bytes_to_copy: usize = @intCast(data & 0x3F);
            const bytes_to_rle: usize = @intCast(data >> 6);
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy + bytes_to_rle) return error.RleStreamMismatch;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            cmd_ptr += bytes_to_copy;
            dst += bytes_to_copy;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else if (cmd == 1) {
            rle_byte = cmd_ptr[0];
            cmd_ptr += 1;
            cmd_ptr_end -= 1;
        } else if (cmd >= 9) {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const bytes_to_rle: usize = @intCast((word -% 0x8ff) * 128);
            cmd_ptr_end -= 2;
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_rle) return error.RleStreamMismatch;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const bytes_to_copy: usize = @intCast((word -% 511) * 64);
            cmd_ptr_end -= 2;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            dst += bytes_to_copy;
            cmd_ptr += bytes_to_copy;
        }
    }

    if (@intFromPtr(cmd_ptr_end) != @intFromPtr(cmd_ptr)) return error.RleStreamMismatch;
    if (@intFromPtr(dst) != @intFromPtr(dst_end)) return error.RleStreamMismatch;
    return src.len;
}

// ────────────────────────────────────────────────────────────
//  Type 5 — Recursive multi-block decoder (simple N-split path)
// ────────────────────────────────────────────────────────────

fn decodeRecursive(
    src: []const u8,
    dst_buf: [*]u8,
    dst_size: usize,
    scratch: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!usize {
    if (src.len < 6) return error.SourceTruncated;

    const n0: u8 = src[0] & 0x7F;
    if (n0 < 2) return error.BadChunkHeader;

    // Multi-array variant (bit 7 set) — the intricate interleaved-stream path
    // in C#'s `High_DecodeMultiArrayInternal`. Not yet ported.
    if ((src[0] & 0x80) != 0) return error.MultiArrayNotSupported;

    // Simple path: N sub-blocks, each decoded via highDecodeBytesInternal with
    // `force_memmove=true` so they concatenate into dst_buf. The caller's
    // scratch is reused across every sub-block — each call sees the full
    // workspace because previous sub-block workspace is released at return.
    var remaining_src: []const u8 = src[1..];
    var dst_cursor: [*]u8 = dst_buf;
    var dst_remaining: usize = dst_size;
    var n: u32 = n0;

    while (n != 0) : (n -= 1) {
        const res = try highDecodeBytesInternal(
            dst_cursor,
            dst_remaining,
            remaining_src,
            true,
            scratch,
            scratch_end,
            max_depth - 1,
        );
        dst_cursor += res.decoded_size;
        dst_remaining -= res.decoded_size;
        remaining_src = remaining_src[res.bytes_consumed..];
    }

    if (dst_remaining != 0) return error.SubDecoderMismatch;
    // Return total bytes consumed from the original `src`.
    return src.len - remaining_src.len;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Type 0 short-mode memcopy zero-copy path" {
    // Header byte: 0x80 | 5 (length 5), next byte = 0, then 5 payload bytes.
    var src: [8]u8 = .{ 0x80, 5, 'a', 'b', 'c', 'd', 'e', 0xFF };
    var dst: [32]u8 = @splat(0);
    var scratch: [256]u8 = undefined;
    const r = try highDecodeBytes(&dst, dst.len, src[0..7], false, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(@as(usize, 5), r.decoded_size);
    try testing.expectEqual(@as(usize, 7), r.bytes_consumed);
    // Zero-copy: out_ptr points into src at offset 2.
    try testing.expectEqual(@intFromPtr(&src[2]), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "abcde", r.out_ptr[0..r.decoded_size]);
}

test "Type 0 memcopy with force_memmove copies into dst_buf" {
    var src: [7]u8 = .{ 0x80, 5, 'h', 'e', 'l', 'l', 'o' };
    var dst: [16]u8 = @splat(0);
    var scratch: [256]u8 = undefined;
    const r = try highDecodeBytes(&dst, dst.len, &src, true, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(@intFromPtr(&dst), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "hello", dst[0..5]);
}

// The previous "unsupported chunk types return error" placeholder test was
// removed in phase 4b — Types 3 and 5 are now wired. End-to-end fixtures
// are the real validation for RLE / Recursive.

test "truncated source returns SourceTruncated" {
    const src = [_]u8{0x80};
    var dst: [16]u8 = undefined;
    var scratch: [256]u8 = undefined;
    try testing.expectError(error.SourceTruncated, highDecodeBytes(&dst, dst.len, &src, false, &scratch, scratch[scratch.len..].ptr));
}
