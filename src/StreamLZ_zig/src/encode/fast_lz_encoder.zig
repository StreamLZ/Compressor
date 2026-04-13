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
const match_hasher = @import("match_hasher.zig");
const writer_mod = @import("fast_stream_writer.zig");
const parser = @import("fast_lz_parser.zig");
const token_writer = @import("fast_token_writer.zig");
const entropy_enc = @import("entropy_encoder.zig");
const byte_hist = @import("byte_histogram.zig");

const MatchHasher2x = match_hasher.MatchHasher2x;
const MatchHasher2 = match_hasher.MatchHasher2;

const FastStreamWriter = writer_mod.FastStreamWriter;
const EntropyOptions = entropy_enc.EntropyOptions;

pub const EncodeError = error{
    DestinationTooSmall,
} || std.mem.Allocator.Error || entropy_enc.EncodeError;

pub const EncodeResult = struct {
    /// Total bytes written to `dst` (before the outer 3-byte sub-chunk header).
    bytes_written: usize,
    /// `ChunkType` to emit in the sub-chunk header. Raw mode is always `.raw`.
    chunk_type: fast_constants.ChunkType,
    /// True when compression "failed" — caller should store the source raw
    /// in the sub-chunk instead of using our output.
    bail: bool,
};

/// Per-sub-chunk parser configuration resolved by the outer driver
/// (`streamlz_encoder.resolveParams`). Fields mirror C# `CompressOptions`
/// post-resolution.
pub const ParserConfig = struct {
    /// Active minimum match length after text detection. 4 for binary,
    /// 6 for text at engine levels ≤ 3.
    minimum_match_length: u32,
    /// Effective dictionary size, 1 GB by default.
    dictionary_size: u32,
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
    config: ParserConfig,
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

    var w = try FastStreamWriter.init(allocator, source.ptr, source.len, literal_data_ptr, false);
    defer w.deinit(allocator);

    var mmlt: [32]u32 = undefined;
    fast_constants.buildMinimumMatchLengthTable(&mmlt, config.minimum_match_length, 14);

    const dict_size: u32 = config.dictionary_size;

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
            token_writer.copyTrailingLiterals(&w, block1_cursor, block1_end, recent);
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
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end, recent);
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
//  Entropy-mode sub-chunk encoder (user levels 3, 4, 5)
// ────────────────────────────────────────────────────────────

/// Encode a single Fast sub-chunk in entropy mode (delta-literal + token
/// entropy coding via tANS/memcpy, optional off16 entropy split). Port
/// of the entropy-mode branches in C# `Encoder.AssembleCompressedOutput`.
///
/// The caller runs the parser with `use_delta_literals = true` so BOTH
/// literal streams are available; this function picks the cheaper one
/// by encoded size.
pub fn encodeSubChunkEntropy(
    comptime level: i32,
    allocator: std.mem.Allocator,
    hasher: *FastMatchHasher(u32),
    source: []const u8,
    dst: []u8,
    start_position: usize,
    options: EntropyOptions,
    config: ParserConfig,
) EncodeError!EncodeResult {
    if (source.len <= fast_constants.min_source_length) return .{
        .bytes_written = 0,
        .chunk_type = .raw,
        .bail = true,
    };

    const initial_bytes: usize = if (start_position == 0) fast_constants.initial_copy_bytes else 0;
    const min_dst = initial_bytes + 32 + source.len + 256;
    if (dst.len < min_dst) return error.DestinationTooSmall;

    hasher.reset();

    var dst_cursor: [*]u8 = dst.ptr;
    if (initial_bytes != 0) {
        @memcpy(dst_cursor[0..8], source[0..8]);
        dst_cursor += 8;
    }

    // Entropy mode: both literal streams live in scratch, so the caller
    // doesn't touch the literal data until assembly.
    var w = try FastStreamWriter.init(allocator, source.ptr, source.len, null, true);
    defer w.deinit(allocator);

    var mmlt: [32]u32 = undefined;
    // `long_offset_threshold = 10` for entropy mode (vs 14 for raw).
    fast_constants.buildMinimumMatchLengthTable(&mmlt, config.minimum_match_length, 10);

    const dict_size: u32 = config.dictionary_size;

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
            token_writer.copyTrailingLiterals(&w, block1_cursor, block1_end, recent);
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
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end, recent);
        }
        w.off32_count_block2 = w.off32_count;
    }

    return assembleEntropyOutput(allocator, &w, dst, dst_cursor, source.len, options);
}

/// Serialize the parallel streams in `w` into `dst` starting at `dst_cursor`.
/// Shared between greedy-entropy (L5) and lazy-entropy (L3) paths.
fn assembleEntropyOutput(
    allocator: std.mem.Allocator,
    w: *const FastStreamWriter,
    dst: []u8,
    dst_cursor_in: [*]u8,
    source_len: usize,
    options: EntropyOptions,
) EncodeError!EncodeResult {
    const literal_count: usize = w.literalCount();
    const token_count: usize = w.tokenCount();
    const off16_count: usize = w.off16Count();

    var out_cursor: [*]u8 = dst_cursor_in;
    const dst_end: [*]u8 = dst.ptr + dst.len;
    const bail_result: EncodeResult = .{ .bytes_written = 0, .chunk_type = .raw, .bail = true };

    const enc_scratch = try allocator.alloc(u8, @max(literal_count, token_count) + 512);
    defer allocator.free(enc_scratch);

    // ── Encode literal stream (try delta and raw, pick cheaper) ────────
    var chunk_type: fast_constants.ChunkType = .raw;
    if (literal_count >= 32) {
        const raw_n = try entropy_enc.encodeArrayU8(
            allocator,
            enc_scratch,
            w.literal_start[0..literal_count],
            options,
            null,
        );
        const delta_scratch = try allocator.alloc(u8, literal_count + 512);
        defer allocator.free(delta_scratch);
        const delta_n = try entropy_enc.encodeArrayU8(
            allocator,
            delta_scratch,
            w.delta_literal_start.?[0..literal_count],
            options,
            null,
        );
        if (delta_n < raw_n) {
            if (@intFromPtr(out_cursor) + delta_n > @intFromPtr(dst_end)) return bail_result;
            @memcpy(out_cursor[0..delta_n], delta_scratch[0..delta_n]);
            out_cursor += delta_n;
            chunk_type = .delta;
        } else {
            if (@intFromPtr(out_cursor) + raw_n > @intFromPtr(dst_end)) return bail_result;
            @memcpy(out_cursor[0..raw_n], enc_scratch[0..raw_n]);
            out_cursor += raw_n;
            chunk_type = .raw;
        }
    } else {
        const raw_n = try entropy_enc.encodeArrayU8Memcpy(enc_scratch, w.literal_start[0..literal_count]);
        if (@intFromPtr(out_cursor) + raw_n > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..raw_n], enc_scratch[0..raw_n]);
        out_cursor += raw_n;
        chunk_type = .raw;
    }

    // ── Encode token stream (entropy) ──────────────────────────────────
    {
        const token_n = try entropy_enc.encodeArrayU8(
            allocator,
            enc_scratch,
            w.token_start[0..token_count],
            options,
            null,
        );
        if (@intFromPtr(out_cursor) + token_n > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..token_n], enc_scratch[0..token_n]);
        out_cursor += token_n;
    }

    // ── Optional TokenStream2Offset ────────────────────────────────────
    if (source_len > fast_constants.block1_max_size) {
        if (@intFromPtr(out_cursor) + 2 > @intFromPtr(dst_end)) return bail_result;
        std.mem.writeInt(u16, out_cursor[0..2], @intCast(w.token_stream2_offset), .little);
        out_cursor += 2;
    }

    // ── Off16 stream: try entropy split, fall back to raw ─────────────
    var used_entropy_off16 = false;
    if (options.allow_tans and off16_count >= 32) {
        const off16_bytes_total: usize = off16_count * 2;
        const split_buf = try allocator.alloc(u8, off16_count * 2);
        defer allocator.free(split_buf);
        const lo_bytes = split_buf[0..off16_count];
        const hi_bytes = split_buf[off16_count .. off16_count * 2];
        for (0..off16_count) |i| {
            const v: u16 = w.off16_start[i];
            lo_bytes[i] = @intCast(v & 0xFF);
            hi_bytes[i] = @intCast((v >> 8) & 0xFF);
        }
        const split_enc = try allocator.alloc(u8, off16_bytes_total + 512);
        defer allocator.free(split_enc);
        const hi_n = try entropy_enc.encodeArrayU8(allocator, split_enc, hi_bytes, options, null);
        const lo_n = try entropy_enc.encodeArrayU8(allocator, split_enc[hi_n..], lo_bytes, options, null);
        const split_total = hi_n + lo_n;
        if (split_total + 2 < off16_bytes_total + 2) {
            used_entropy_off16 = true;
            if (@intFromPtr(out_cursor) + 2 + split_total > @intFromPtr(dst_end)) return bail_result;
            std.mem.writeInt(u16, out_cursor[0..2], fast_constants.entropy_coded_16_marker, .little);
            out_cursor += 2;
            @memcpy(out_cursor[0..split_total], split_enc[0..split_total]);
            out_cursor += split_total;
        }
    }
    if (!used_entropy_off16) {
        const off16_bytes: usize = off16_count * 2;
        if (@intFromPtr(out_cursor) + off16_bytes + 2 > @intFromPtr(dst_end)) return bail_result;
        std.mem.writeInt(u16, out_cursor[0..2], @intCast(off16_count), .little);
        out_cursor += 2;
        if (off16_bytes != 0) {
            const off16_src: [*]const u8 = @ptrCast(w.off16_start);
            @memcpy(out_cursor[0..off16_bytes], off16_src[0..off16_bytes]);
            out_cursor += off16_bytes;
        }
    }

    // ── Off32 stream header + data ─────────────────────────────────────
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

    // ── Length stream (raw) ───────────────────────────────────────────
    const length_bytes: usize = w.lengthCount();
    if (length_bytes != 0) {
        if (@intFromPtr(out_cursor) + length_bytes > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..length_bytes], w.length_start[0..length_bytes]);
        out_cursor += length_bytes;
    }

    const total: usize = @intFromPtr(out_cursor) - @intFromPtr(dst.ptr);
    if (total >= source_len) return bail_result;

    return .{ .bytes_written = total, .chunk_type = chunk_type, .bail = false };
}

/// Encode a sub-chunk in entropy mode using the L3 lazy parser with a
/// `MatchHasher2x` (2-entry bucket). Mirrors `encodeSubChunkEntropy` but
/// runs `runLazyParser` instead of the greedy path.
pub fn encodeSubChunkEntropyLazy(
    comptime engine_level: i32,
    allocator: std.mem.Allocator,
    hasher: *MatchHasher2x,
    source: []const u8,
    dst: []u8,
    start_position: usize,
    options: EntropyOptions,
    config: ParserConfig,
) EncodeError!EncodeResult {
    if (source.len <= fast_constants.min_source_length) return .{
        .bytes_written = 0,
        .chunk_type = .raw,
        .bail = true,
    };

    const initial_bytes: usize = if (start_position == 0) fast_constants.initial_copy_bytes else 0;
    const min_dst = initial_bytes + 32 + source.len + 256;
    if (dst.len < min_dst) return error.DestinationTooSmall;

    hasher.reset();
    hasher.setSrcBase(source.ptr);
    hasher.setBaseWithoutPreload(0);

    var dst_cursor: [*]u8 = dst.ptr;
    if (initial_bytes != 0) {
        @memcpy(dst_cursor[0..8], source[0..8]);
        dst_cursor += 8;
    }

    var w = try FastStreamWriter.init(allocator, source.ptr, source.len, null, true);
    defer w.deinit(allocator);

    var mmlt: [32]u32 = undefined;
    fast_constants.buildMinimumMatchLengthTable(&mmlt, config.minimum_match_length, 10);

    const dict_size: u32 = config.dictionary_size;

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
            parser.runLazyParser(
                engine_level,
                2,
                &w,
                hasher,
                block1_cursor,
                safe_for_block1,
                block1_end,
                &recent,
                dict_size,
                &mmlt,
                config.minimum_match_length,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block1_cursor, block1_end, recent);
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
            parser.runLazyParser(
                engine_level,
                2,
                &w,
                hasher,
                block2_cursor,
                safe_for_block2,
                block2_end,
                &recent,
                dict_size,
                &mmlt,
                config.minimum_match_length,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end, recent);
        }
        w.off32_count_block2 = w.off32_count;
    }

    return assembleEntropyOutput(allocator, &w, dst, dst_cursor, source.len, options);
}

/// Encode a sub-chunk in entropy mode using the L4 lazy parser with the
/// `MatchHasher2` chain-walking hasher. Mirrors `encodeSubChunkEntropyLazy`
/// but drives `runLazyParserChain`.
pub fn encodeSubChunkEntropyChain(
    comptime engine_level: i32,
    allocator: std.mem.Allocator,
    hasher: *MatchHasher2,
    source: []const u8,
    dst: []u8,
    start_position: usize,
    options: EntropyOptions,
    config: ParserConfig,
) EncodeError!EncodeResult {
    if (source.len <= fast_constants.min_source_length) return .{
        .bytes_written = 0,
        .chunk_type = .raw,
        .bail = true,
    };

    const initial_bytes: usize = if (start_position == 0) fast_constants.initial_copy_bytes else 0;
    const min_dst = initial_bytes + 32 + source.len + 256;
    if (dst.len < min_dst) return error.DestinationTooSmall;

    hasher.reset();
    hasher.setSrcBase(source.ptr);
    hasher.setBaseWithoutPreload(0);

    var dst_cursor: [*]u8 = dst.ptr;
    if (initial_bytes != 0) {
        @memcpy(dst_cursor[0..8], source[0..8]);
        dst_cursor += 8;
    }

    var w = try FastStreamWriter.init(allocator, source.ptr, source.len, null, true);
    defer w.deinit(allocator);

    var mmlt: [32]u32 = undefined;
    fast_constants.buildMinimumMatchLengthTable(&mmlt, config.minimum_match_length, 10);

    const dict_size: u32 = config.dictionary_size;

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
            parser.runLazyParserChain(
                engine_level,
                &w,
                hasher,
                block1_cursor,
                safe_for_block1,
                block1_end,
                &recent,
                dict_size,
                &mmlt,
                config.minimum_match_length,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block1_cursor, block1_end, recent);
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
            parser.runLazyParserChain(
                engine_level,
                &w,
                hasher,
                block2_cursor,
                safe_for_block2,
                block2_end,
                &recent,
                dict_size,
                &mmlt,
                config.minimum_match_length,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end, recent);
        }
        w.off32_count_block2 = w.off32_count;
    }

    return assembleEntropyOutput(allocator, &w, dst, dst_cursor, source.len, options);
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
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
    });
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
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
    });
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
    const res = try encodeSubChunkRaw(1, testing.allocator, &hasher, &source, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
    });
    try testing.expect(!res.bail);

    var decoded: [source.len + 64]u8 = @splat(0);
    try wrapAndDecode(dst[0..res.bytes_written], decoded[0..], source.len, 0);
    try testing.expectEqualSlices(u8, source[0..], decoded[0..source.len]);
}
