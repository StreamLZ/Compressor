//! Fast LZ sub-chunk encoder — raw-literal mode (user levels 1 & 2).
//!
//! One `encodeSubChunkRaw` call:
//!   1. Initializes a `FastStreamWriter` with literals pointing in-place into
//!      `dst` (past the 3-byte literal-count header slot + initial 8 bytes if
//!      `start_position == 0`).
//!   2. Runs `runGreedyParser` over block1 (first 64 KB) then block2 (next
//!      64 KB). Between blocks it updates the token-stream-2 offset.
//!   3. Assembles the output: backfills the 3-byte literal count header,
//!      then appends the memcpy-framed token stream, off16 raw, off32 raw,
//!      and length stream.
//!
//! On success returns the number of bytes written to `dst`. If the
//! compressed output would be ≥ `source_length`, returns `bail = true` so
//! the outer chunk writer can fall back to an uncompressed chunk.
//!
//! Port of FastParser.CompressGreedy + Encoder.AssembleCompressedOutput
//! (raw-mode branches only). Entropy-mode assembly lands in Phase 10.

const std = @import("std");
const fast_constants = @import("fast_constants.zig");
const FastMatchHasher = @import("fast_match_hasher.zig").FastMatchHasher;
const writer_mod = @import("fast_stream_writer.zig");
const parser = @import("fast_lz_parser.zig");
const token_writer = @import("fast_token_writer.zig");

const FastStreamWriter = writer_mod.FastStreamWriter;

pub const EncodeError = error{
    DestinationTooSmall,
} || std.mem.Allocator.Error;

pub const EncodeResult = struct {
    /// Total bytes written to `dst` (before the outer 3-byte sub-chunk header).
    bytes_written: usize,
    /// `ChunkType` to emit in the sub-chunk header. Raw mode is always `.raw`.
    chunk_type: fast_constants.ChunkType,
    /// True when compression "failed" — caller should store the source raw
    /// in the sub-chunk instead of using our output.
    bail: bool,
};

/// Encode a single Fast sub-chunk in raw-literal mode (no entropy).
///
/// `source`:    source bytes for this sub-chunk (≤ 128 KB).
/// `dst`:       destination slice. The caller already wrote the 3-byte
///              sub-chunk header at `dst[-3..0]`; we write the payload.
/// `start_position`: offset of `source` within the outer 256 KB block (used
///              to decide whether to copy the initial 8 bytes).
/// `hasher`:    caller-supplied hash table (reset between sub-chunks).
pub fn encodeSubChunkRaw(
    comptime level: i32,
    allocator: std.mem.Allocator,
    hasher: *FastMatchHasher(u32),
    source: []const u8,
    dst: []u8,
    start_position: usize,
) EncodeError!EncodeResult {
    if (source.len <= fast_constants.min_source_length) return .{
        .bytes_written = 0,
        .chunk_type = .raw,
        .bail = true,
    };

    const initial_bytes: usize = if (start_position == 0) fast_constants.initial_copy_bytes else 0;
    const min_dst = initial_bytes + 3 + source.len + 256;
    if (dst.len < min_dst) return error.DestinationTooSmall;

    hasher.reset();

    // Initial 8 bytes of the very first sub-chunk are copied verbatim.
    var dst_cursor: [*]u8 = dst.ptr;
    if (initial_bytes != 0) {
        @memcpy(dst_cursor[0..8], source[0..8]);
        dst_cursor += 8;
    }

    // Reserve the 3-byte literal-count header (backfilled later).
    const literal_count_header: [*]u8 = dst_cursor;
    const literal_data_ptr: [*]u8 = dst_cursor + 3;

    var w = try FastStreamWriter.init(allocator, source.ptr, source.len, literal_data_ptr);
    defer w.deinit(allocator);

    var mmlt: [32]u32 = undefined;
    fast_constants.buildMinimumMatchLengthTable(&mmlt, 4, 14);

    const dict_size: u32 = @intCast(fast_constants.block1_max_size * 2);

    var recent: isize = -8;
    const source_end_ptr: [*]const u8 = source.ptr + source.len;
    const safe_end: [*]const u8 = if (source.len >= 16) source_end_ptr - 16 else source.ptr;

    // ── Block 1 ─────────────────────────────────────────────────────────
    {
        const block1_cursor: [*]const u8 = source.ptr + initial_bytes;
        const block1_end: [*]const u8 = source.ptr + w.block1_size;
        const safe_for_block1: [*]const u8 = if (@intFromPtr(block1_end) < @intFromPtr(safe_end))
            block1_end
        else
            safe_end;
        w.block2_start_offset = 0;
        w.off32_count = 0;
        if (@intFromPtr(block1_cursor) < @intFromPtr(safe_for_block1)) {
            parser.runGreedyParser(
                level,
                u32,
                &w,
                hasher,
                block1_cursor,
                safe_for_block1,
                block1_end,
                &recent,
                dict_size,
                &mmlt,
                source.ptr,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block1_cursor, block1_end);
        }
        w.off32_count_block1 = w.off32_count;
    }

    // ── Block 2 ─────────────────────────────────────────────────────────
    if (w.block2_size > 0) {
        w.token_stream2_offset = @intCast(w.tokenCount());
        w.block2_start_offset = @intCast(w.block1_size);
        w.off32_count = 0;

        const block2_cursor: [*]const u8 = source.ptr + w.block1_size;
        const block2_end: [*]const u8 = block2_cursor + w.block2_size;
        const safe_for_block2: [*]const u8 = if (@intFromPtr(block2_end) < @intFromPtr(safe_end))
            block2_end
        else
            safe_end;

        if (@intFromPtr(block2_cursor) < @intFromPtr(safe_for_block2)) {
            parser.runGreedyParser(
                level,
                u32,
                &w,
                hasher,
                block2_cursor,
                safe_for_block2,
                block2_end,
                &recent,
                dict_size,
                &mmlt,
                source.ptr,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end);
        }
        w.off32_count_block2 = w.off32_count;
    }

    // ── Assemble ────────────────────────────────────────────────────────
    const literal_count: usize = w.literalCount();

    // Backfill 3-byte big-endian literal count at the reserved slot.
    literal_count_header[0] = @intCast((literal_count >> 16) & 0xFF);
    literal_count_header[1] = @intCast((literal_count >> 8) & 0xFF);
    literal_count_header[2] = @intCast(literal_count & 0xFF);

    var out_cursor: [*]u8 = literal_data_ptr + literal_count;
    const dst_end: [*]u8 = dst.ptr + dst.len;

    const bail_result: EncodeResult = .{ .bytes_written = 0, .chunk_type = .raw, .bail = true };

    if (@intFromPtr(out_cursor) + 16 > @intFromPtr(dst_end)) return bail_result;

    // ── Token stream (memcpy-framed Type 0 entropy block) ──────────────
    const token_count: usize = w.tokenCount();
    if (@intFromPtr(out_cursor) + token_count + 3 > @intFromPtr(dst_end)) return bail_result;
    out_cursor[0] = @intCast((token_count >> 16) & 0xFF);
    out_cursor[1] = @intCast((token_count >> 8) & 0xFF);
    out_cursor[2] = @intCast(token_count & 0xFF);
    out_cursor += 3;
    if (token_count != 0) {
        @memcpy(out_cursor[0..token_count], w.token_start[0..token_count]);
        out_cursor += token_count;
    }

    // ── Optional TokenStream2Offset (only if source > 64 KB) ───────────
    if (source.len > fast_constants.block1_max_size) {
        if (@intFromPtr(out_cursor) + 2 > @intFromPtr(dst_end)) return bail_result;
        std.mem.writeInt(u16, out_cursor[0..2], @intCast(w.token_stream2_offset), .little);
        out_cursor += 2;
    }

    // ── Off16 stream (raw) ──────────────────────────────────────────────
    const off16_count: usize = w.off16Count();
    const off16_bytes: usize = off16_count * 2;
    if (@intFromPtr(out_cursor) + off16_bytes + 2 > @intFromPtr(dst_end)) return bail_result;
    std.mem.writeInt(u16, out_cursor[0..2], @intCast(off16_count), .little);
    out_cursor += 2;
    if (off16_bytes != 0) {
        const off16_src: [*]const u8 = @ptrCast(w.off16_start);
        @memcpy(out_cursor[0..off16_bytes], off16_src[0..off16_bytes]);
        out_cursor += off16_bytes;
    }

    // ── Off32 stream header + data ──────────────────────────────────────
    const off32_bytes: usize = w.off32ByteCount();

    if (@intFromPtr(out_cursor) + 3 > @intFromPtr(dst_end)) return bail_result;
    const c1: u32 = @min(w.off32_count_block1, 4095);
    const c2: u32 = @min(w.off32_count_block2, 4095);
    const packed_counts: u32 = (c1 << 12) | c2;
    out_cursor[0] = @intCast(packed_counts & 0xFF);
    out_cursor[1] = @intCast((packed_counts >> 8) & 0xFF);
    out_cursor[2] = @intCast((packed_counts >> 16) & 0xFF);
    out_cursor += 3;
    if (w.off32_count_block1 >= 4095) {
        if (@intFromPtr(out_cursor) + 2 > @intFromPtr(dst_end)) return bail_result;
        std.mem.writeInt(u16, out_cursor[0..2], @intCast(w.off32_count_block1), .little);
        out_cursor += 2;
    }
    if (w.off32_count_block2 >= 4095) {
        if (@intFromPtr(out_cursor) + 2 > @intFromPtr(dst_end)) return bail_result;
        std.mem.writeInt(u16, out_cursor[0..2], @intCast(w.off32_count_block2), .little);
        out_cursor += 2;
    }
    if (off32_bytes != 0) {
        if (@intFromPtr(out_cursor) + off32_bytes > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..off32_bytes], w.off32_start[0..off32_bytes]);
        out_cursor += off32_bytes;
    }

    // ── Length stream (raw, variable-length) ────────────────────────────
    const length_bytes: usize = w.lengthCount();
    if (length_bytes != 0) {
        if (@intFromPtr(out_cursor) + length_bytes > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..length_bytes], w.length_start[0..length_bytes]);
        out_cursor += length_bytes;
    }

    const total: usize = @intFromPtr(out_cursor) - @intFromPtr(dst.ptr);
    if (total >= source.len) return bail_result;

    return .{ .bytes_written = total, .chunk_type = .raw, .bail = false };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;
const decoder = @import("../decode/fast_lz_decoder.zig");
const lz_constants = @import("../format/streamlz_constants.zig");

/// Wrap a raw-encoded sub-chunk in the 3-byte outer header and decode it.
/// Returns the decoded bytes via `out`.
fn wrapAndDecode(
    encoded: []const u8,
    out: []u8,
    source_len: usize,
    start_position: usize,
) !void {
    _ = start_position;
    var wrapped: [300_000]u8 = undefined;
    const hdr: u32 = @as(u32, @intCast(encoded.len)) |
        (@as(u32, 1) << lz_constants.sub_chunk_type_shift) |
        lz_constants.chunk_header_compressed_flag;
    wrapped[0] = @intCast((hdr >> 16) & 0xFF);
    wrapped[1] = @intCast((hdr >> 8) & 0xFF);
    wrapped[2] = @intCast(hdr & 0xFF);
    @memcpy(wrapped[3 .. 3 + encoded.len], encoded);

    var scratch: [lz_constants.scratch_size]u8 = undefined;
    _ = try decoder.decodeChunk(
        out[0..].ptr,
        out[0..].ptr + source_len,
        out[0..].ptr,
        wrapped[0..].ptr,
        wrapped[0..].ptr + 3 + encoded.len,
        scratch[0..].ptr,
        scratch[0..].ptr + scratch.len,
    );
}

test "encodeSubChunkRaw roundtrip: repeating 2 KB pattern" {
    var source: [2048]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast('A' + (i % 16));

    var hasher = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 14, .min_match_length = 4 });
    defer hasher.deinit();

    var dst: [4096]u8 = undefined;
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0);
    try testing.expect(!res.bail);
    try testing.expect(res.bytes_written < source.len);

    var decoded: [source.len + 64]u8 = @splat(0);
    try wrapAndDecode(dst[0..res.bytes_written], decoded[0..], source.len, 0);
    try testing.expectEqualSlices(u8, source[0..], decoded[0..source.len]);
}

test "encodeSubChunkRaw roundtrip: 4 KB binary-ish input" {
    var source: [4096]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (&source) |*b| {
        state = state *% 1103515245 +% 12345;
        b.* = @intCast((state >> 16) & 0xFF);
    }

    var hasher = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 14, .min_match_length = 4 });
    defer hasher.deinit();

    var dst: [source.len + 512]u8 = undefined;
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0);
    if (res.bail) return; // Random data usually bails — acceptable.

    var decoded: [source.len + 64]u8 = @splat(0);
    try wrapAndDecode(dst[0..res.bytes_written], decoded[0..], source.len, 0);
    try testing.expectEqualSlices(u8, source[0..], decoded[0..source.len]);
}

test "encodeSubChunkRaw roundtrip: 16 KB lorem-ipsum-ish" {
    var source: [16 * 1024]u8 = undefined;
    const pattern = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < source.len) : (i += 1) source[i] = pattern[i % pattern.len];

    var hasher = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 15, .min_match_length = 4 });
    defer hasher.deinit();

    var dst: [source.len + 512]u8 = undefined;
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0);
    try testing.expect(!res.bail);

    var decoded: [source.len + 64]u8 = @splat(0);
    try wrapAndDecode(dst[0..res.bytes_written], decoded[0..], source.len, 0);
    try testing.expectEqualSlices(u8, source[0..], decoded[0..source.len]);
}
