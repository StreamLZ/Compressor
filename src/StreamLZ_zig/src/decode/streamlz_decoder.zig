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

/// Decompresses a raw StreamLZ block (no SLZ1 frame wrapper) into `dst[0..decompressed_size]`.
///
/// Port of C# `StreamLZDecoder.Decompress(src, srcLen, dst, dstLen)` at
/// `StreamLzDecoder.cs:376-379`. `src` is a raw compressed block — a
/// sequence of internal 2-byte block headers + 4-byte chunk headers +
/// chunk payloads (no frame header, no end mark). `dst.len` must be at
/// least `decompressed_size + safe_space`.
///
/// Returns the number of bytes decompressed (equal to `decompressed_size`
/// on success).
pub fn decompressBlock(
    src: []const u8,
    dst: []u8,
    decompressed_size: usize,
) DecompressError!usize {
    return decompressBlockWithDict(src, dst, 0, decompressed_size);
}

/// Decompresses a raw StreamLZ block into `dst[dst_offset..dst_offset + decompressed_size]`,
/// with `dst[0..dst_offset]` treated as a pre-populated dictionary window.
///
/// Port of C# `StreamLZDecoder.Decompress(src, srcLen, dst, dstLen, dstOffset)`
/// at `StreamLzDecoder.cs:392-417` and `SerialDecodeLoopWithOffset` at
/// `StreamLzDecoder.cs:438-469`. LZ back-references in the compressed
/// stream can reach into the dictionary bytes at `dst[0..dst_offset]`.
///
/// `dst.len` must be at least `dst_offset + decompressed_size + safe_space`.
/// Returns the number of bytes decompressed (NOT including the dictionary).
pub fn decompressBlockWithDict(
    src: []const u8,
    dst: []u8,
    dst_offset: usize,
    decompressed_size: usize,
) DecompressError!usize {
    if (decompressed_size == 0) return 0;
    if (dst_offset + decompressed_size + safe_space > dst.len) return error.OutputTooSmall;

    var scratch: [constants.scratch_size]u8 = undefined;
    var dst_off: usize = dst_offset;
    try decompressCompressedBlock(src, dst, &dst_off, decompressed_size, &scratch);
    return dst_off - dst_offset;
}

/// Walks 256 KB chunks inside a single compressed frame block. Parses the
/// internal 2-byte block header at every 256 KB boundary and the 4-byte
/// chunk header before each chunk's payload, dispatching to the codec.
///
/// **Self-contained (L6–L8) handling:** when the first internal block
/// header has `self_contained` set, the encoder stores `(num_chunks-1)*8`
/// "delta prefix" bytes at the very end of the block payload. After the
/// main decode, the first 8 bytes of every chunk except chunk 0 are
/// overwritten with those tail bytes. C# parallelizes SC decode and
/// forms per-group dst_start boundaries; our serial equivalent just
/// decodes sequentially with a buffer-wide dst_start (which is safe
/// because a well-formed encoder emits no cross-group references
/// beyond what the tail-prefix restoration then overwrites).
fn decompressCompressedBlock(
    block_src_in: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    scratch: []u8,
) DecompressError!void {
    // Peek the first 2-byte internal block header to detect SC mode up-front.
    const is_sc = blk: {
        if (block_src_in.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src_in) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src_in.len) return error.Truncated;
    const block_src: []const u8 = block_src_in[0 .. block_src_in.len - prefix_size];
    const sc_start_dst_off: usize = dst_off_inout.*;
    // Index of the chunk within this frame block (0-based). Used to compute
    // the group-local dst_start for SC mode so each group's first chunk
    // decodes with base_offset == 0 and fires the initial 8-byte Copy64.
    var chunk_idx_in_block: usize = 0;

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
                // For SC mode, dst_start must be the FIRST chunk of the
                // current SC group (not the whole output) so that the
                // encoder's per-group `base_offset == 0` assumption holds
                // and the initial 8-byte Copy64 fires at each group start.
                // For non-SC, use the whole-buffer start (sliding window).
                const dst_start_ptr: [*]const u8 = if (is_sc) blk: {
                    const group_start_chunk = (chunk_idx_in_block / constants.sc_group_size) * constants.sc_group_size;
                    const group_start_offset = sc_start_dst_off + group_start_chunk * constants.chunk_size;
                    break :blk dst[group_start_offset..].ptr;
                } else dst.ptr;
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
        chunk_idx_in_block += 1;
    }

    // Any trailing source bytes in the frame block are a corruption signal.
    if (src_pos != block_src.len) return error.SizeMismatch;

    // SC: restore the first 8 bytes of each chunk (except chunk 0) from the
    // tail prefix table that we excluded from `block_src` above.
    if (prefix_size != 0) {
        const prefix_base: [*]const u8 = block_src_in[block_src_in.len - prefix_size ..].ptr;
        var i: usize = 0;
        while (i + 1 < num_chunks) : (i += 1) {
            const chunk_dst_off: usize = sc_start_dst_off + (i + 1) * constants.chunk_size;
            var copy_size: usize = 8;
            const remaining_in_chunk: usize = decompressed_size - (i + 1) * constants.chunk_size;
            if (copy_size > remaining_in_chunk) copy_size = remaining_in_chunk;
            @memcpy(
                dst[chunk_dst_off..][0..copy_size],
                prefix_base[i * 8 ..][0..copy_size],
            );
        }
    }
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

test "decompressBlock roundtrips a raw compressed block (no frame wrapper)" {
    // Build a compressible payload large enough to clear min_source_length (128).
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 37) & 0xFF);
    // Inject a repeated region so the LZ parser has something to find.
    @memcpy(payload[100..164], payload[0..64]);
    @memcpy(payload[300..364], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    // Compress via the framed API, then strip the SLZ1 frame header + 8-byte
    // outer block header to get the raw inner compressed block that
    // `decompressBlock` expects.
    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    const hdr = try frame.parseHeader(framed[0..framed_len]);
    const bh = try frame.parseBlockHeader(framed[hdr.header_size..]);
    // Only validate the roundtrip when the encoder chose the compressed path.
    // For very short inputs the frame block may come back uncompressed.
    if (bh.uncompressed) return;
    const inner_start = hdr.header_size + 8;
    const inner = framed[inner_start .. inner_start + bh.compressed_size];

    var out: [1024]u8 = @splat(0);
    const written = try decompressBlock(inner, &out, payload.len);
    try testing.expectEqual(payload.len, written);
    try testing.expectEqualSlices(u8, &payload, out[0..payload.len]);
}

test "decompressBlockWithDict writes output at dst_offset for an uncompressed block" {
    // Hand-craft a minimal uncompressed internal block:
    //   byte 0: magic 0x5 | uncompressed flag 0x80
    //   byte 1: decoder type 0x01 (fast)
    //   bytes 2..N: raw payload
    // No SLZ1 frame wrapper, no outer 8-byte block header — exactly what
    // `decompressBlock` expects as input.
    //
    // The uncompressed path doesn't depend on `base_offset == 0` for an
    // initial Copy64, so it exercises the dst_offset plumbing cleanly. The
    // compressed path needs encoder-side dictionary support (D11) to test
    // end-to-end with dst_offset != 0.
    const payload_len: usize = 64;
    var block: [2 + payload_len]u8 = undefined;
    block[0] = 0x05 | 0x80; // magic nibble + uncompressed flag
    block[1] = 0x01; // decoder = fast
    for (block[2..], 0..) |*b, i| b.* = @intCast(i);

    const dict_len: usize = 100;
    var out: [256]u8 = @splat(0xAA);
    const written = try decompressBlockWithDict(&block, &out, dict_len, payload_len);
    try testing.expectEqual(payload_len, written);
    // Dictionary prefix untouched.
    for (out[0..dict_len]) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    // Decoded bytes land at dst[dict_len..dict_len + payload_len].
    for (out[dict_len .. dict_len + payload_len], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), b);
    }
    // Post-output trailing bytes untouched (except safe_space slack).
    for (out[dict_len + payload_len + safe_space ..]) |b| {
        try testing.expectEqual(@as(u8, 0xAA), b);
    }
}

test "decompressBlockWithDict matches decompressBlock when dst_offset == 0" {
    // Equivalence check: `decompressBlockWithDict(..., 0, ...)` must produce
    // identical output to `decompressBlock(..., ...)` on the same input.
    var payload: [384]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 17) & 0xFF);
    @memcpy(payload[128..192], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    const hdr = try frame.parseHeader(framed[0..framed_len]);
    const bh = try frame.parseBlockHeader(framed[hdr.header_size..]);
    if (bh.uncompressed) return;
    const inner_start = hdr.header_size + 8;
    const inner = framed[inner_start .. inner_start + bh.compressed_size];

    var out_a: [1024]u8 = @splat(0);
    var out_b: [1024]u8 = @splat(0);
    const n_a = try decompressBlock(inner, &out_a, payload.len);
    const n_b = try decompressBlockWithDict(inner, &out_b, 0, payload.len);
    try testing.expectEqual(n_a, n_b);
    try testing.expectEqualSlices(u8, out_a[0..n_a], out_b[0..n_b]);
    try testing.expectEqualSlices(u8, &payload, out_a[0..payload.len]);
}

test "decompressBlock rejects undersized output buffer" {
    const dummy_src = [_]u8{ 0x05, 0x01, 0x00, 0x00, 0x00, 0x00 };
    var out: [16]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, decompressBlock(&dummy_src, &out, 1024));
}
