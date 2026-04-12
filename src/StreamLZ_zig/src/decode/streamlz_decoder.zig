//! Top-level StreamLZ framed decompressor.
//!
//! Port of the framed decompress loop in src/StreamLZ/StreamLZ.cs
//! (`Slz.DecompressFramed`) and the inner dispatcher in
//! src/StreamLZ/Decompression/StreamLzDecoder.cs.
//!
//! Current coverage:
//!   * Frame-level uncompressed block path (phase 3a)
//!   * Fast codec (L1–5) compressed path via fast_lz_decoder (phase 3b)
//!   * High codec (L6–11) not yet wired — returns `HighNotImplemented`

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const constants = @import("../format/streamlz_constants.zig");
const fast = @import("fast_lz_decoder.zig");
const high = @import("high_lz_decoder.zig");

/// Extra bytes the decoder is allowed to write past `dst_len`.
/// Ported from `StreamLZDecoder.SafeSpace` (64 in C#).
pub const safe_space: usize = 64;

pub const DecompressError = error{
    BadFrame,
    Truncated,
    SizeMismatch,
    InvalidBlockHeader,
    InvalidInternalHeader,
    BadChunkHeader,
    BlockDataTruncated,
    OutputTooSmall,
    HighNotImplemented,
} || fast.DecodeError || high.DecodeError;

/// Streams `src` (an SLZ1-framed buffer) into `dst`, returning the number
/// of bytes written to `dst`. `dst.len` must be at least `content_size + safe_space`
/// bytes when the frame declares a content size.
pub fn decompressFramed(src: []const u8, dst: []u8) DecompressError!usize {
    if (src.len == 0) return 0;

    const hdr = frame.parseHeader(src) catch return error.BadFrame;

    if (hdr.content_size) |cs| {
        const needed: usize = @intCast(cs + safe_space);
        if (dst.len < needed) return error.OutputTooSmall;
    }

    var pos: usize = hdr.header_size;
    var dst_off: usize = 0;
    // Scratch buffer for Fast decoder tables and stream storage.
    var scratch: [constants.scratch_size]u8 = undefined;

    while (pos + 4 <= src.len) {
        const first_word = std.mem.readInt(u32, src[pos..][0..4], .little);
        if (first_word == frame.end_mark) break;

        const bh = frame.parseBlockHeader(src[pos..]) catch return error.InvalidBlockHeader;
        if (bh.isEndMark()) break;
        pos += 8;

        if (bh.uncompressed) {
            if (pos + bh.decompressed_size > src.len) return error.BlockDataTruncated;
            if (dst_off + bh.decompressed_size > dst.len) return error.OutputTooSmall;
            @memcpy(
                dst[dst_off..][0..bh.decompressed_size],
                src[pos..][0..bh.decompressed_size],
            );
            dst_off += bh.decompressed_size;
            pos += bh.compressed_size;
            continue;
        }

        // Compressed block — iterate 256 KB chunks inside.
        try decompressCompressedBlock(
            src[pos .. pos + bh.compressed_size],
            dst,
            &dst_off,
            bh.decompressed_size,
            &scratch,
        );
        pos += bh.compressed_size;
    }

    if (hdr.content_size) |cs| {
        if (dst_off != cs) return error.SizeMismatch;
    }
    return dst_off;
}

/// Walks 256 KB chunks inside a single compressed frame block. Parses the
/// internal 2-byte block header at every 256 KB boundary and the 4-byte
/// chunk header before each chunk's payload, dispatching to the codec.
fn decompressCompressedBlock(
    block_src: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    scratch: []u8,
) DecompressError!void {
    var src_pos: usize = 0;
    var dst_remaining: usize = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;

    while (dst_remaining > 0) {
        const dst_off = dst_off_inout.*;
        const at_chunk_boundary = (dst_off & (constants.chunk_size - 1)) == 0;

        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_src.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_src[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const hdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = dst_remaining;

        // ── Uncompressed chunk (header says so) — raw copy ──
        if (hdr.uncompressed) {
            if (src_pos + dst_this_chunk > block_src.len) return error.Truncated;
            if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
            @memcpy(dst[dst_off..][0..dst_this_chunk], block_src[src_pos..][0..dst_this_chunk]);
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            src_pos += dst_this_chunk;
            continue;
        }

        // ── Parse 4-byte chunk header ──
        const ch = block_header.parseChunkHeader(block_src[src_pos..], hdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
            @memset(dst[dst_off..][0..dst_this_chunk], ch.memset_fill);
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_src.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            // Stored raw within a "compressed" flag block.
            if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
            @memcpy(dst[dst_off..][0..dst_this_chunk], block_src[src_pos..][0..dst_this_chunk]);
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            src_pos += comp_size;
            continue;
        }

        // Dispatch to codec decoder.
        switch (hdr.decoder_type) {
            .fast, .turbo => {
                if (dst_off + dst_this_chunk + safe_space > dst.len) return error.OutputTooSmall;
                const src_slice_start: [*]const u8 = block_src[src_pos..].ptr;
                const src_slice_end: [*]const u8 = src_slice_start + comp_size;
                const dst_ptr: [*]u8 = dst[dst_off..].ptr;
                const dst_end_ptr: [*]u8 = dst_ptr + dst_this_chunk;
                const dst_start_ptr: [*]const u8 = dst.ptr;
                const scratch_ptr: [*]u8 = scratch.ptr;
                const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;

                const n = try fast.decodeChunk(
                    dst_ptr,
                    dst_end_ptr,
                    dst_start_ptr,
                    src_slice_start,
                    src_slice_end,
                    scratch_ptr,
                    scratch_end_ptr,
                );
                if (n != comp_size) return error.SizeMismatch;
            },
            .high => {
                if (dst_off + dst_this_chunk + safe_space > dst.len) return error.OutputTooSmall;
                const src_slice_start: [*]const u8 = block_src[src_pos..].ptr;
                const src_slice_end: [*]const u8 = src_slice_start + comp_size;
                const dst_ptr: [*]u8 = dst[dst_off..].ptr;
                const dst_end_ptr: [*]u8 = dst_ptr + dst_this_chunk;
                const dst_start_ptr: [*]const u8 = dst.ptr;
                const scratch_ptr: [*]u8 = scratch.ptr;
                const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;

                const n = try high.decodeChunk(
                    dst_ptr,
                    dst_end_ptr,
                    dst_start_ptr,
                    src_slice_start,
                    src_slice_end,
                    scratch_ptr,
                    scratch_end_ptr,
                );
                if (n != comp_size) return error.SizeMismatch;
            },
            else => return error.InvalidInternalHeader,
        }

        dst_off_inout.* += dst_this_chunk;
        dst_remaining -= dst_this_chunk;
        src_pos += comp_size;
    }

    // Any trailing source bytes in the frame block are a corruption signal.
    if (src_pos != block_src.len) return error.SizeMismatch;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decompressFramed roundtrips a tiny uncompressed L1 fixture (synthesized)" {
    const payload = "Hello, world\n";
    const content_size: u64 = payload.len;

    var buf: [256]u8 = undefined;
    const hdr_len = try frame.writeHeader(&buf, .{
        .codec = .fast,
        .level = 1,
        .content_size = content_size,
    });

    frame.writeBlockHeader(buf[hdr_len..], .{
        .compressed_size = payload.len,
        .decompressed_size = payload.len,
        .uncompressed = true,
    });
    @memcpy(buf[hdr_len + 8 ..][0..payload.len], payload);
    frame.writeEndMark(buf[hdr_len + 8 + payload.len ..]);
    const total_len = hdr_len + 8 + payload.len + 4;

    var out: [256]u8 = @splat(0);
    const written = try decompressFramed(buf[0..total_len], out[0..]);
    try testing.expectEqual(@as(usize, payload.len), written);
    try testing.expectEqualSlices(u8, payload, out[0..written]);
}

test "decompressFramed rejects bad magic" {
    const junk = [_]u8{ 'N', 'O', 'P', 'E', 1, 0, 0, 1, 2, 0 };
    var out: [32]u8 = undefined;
    try testing.expectError(error.BadFrame, decompressFramed(&junk, &out));
}
