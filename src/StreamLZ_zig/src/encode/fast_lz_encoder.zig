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
const cost_model = @import("cost_model.zig");

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
    /// Rate-distortion cost matching C# `Fast.Encoder.AssembleCompressedOutput`'s
    /// cost output. Used by the dispatcher to compare against `memsetCost`
    /// and potentially store the sub-chunk raw.
    cost: f32 = std.math.floatMax(f32) / 2,
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
    /// `coder.SpeedTradeoff` — multiplier applied to decode-time cost terms
    /// when comparing LZ output against memset/raw storage cost.
    speed_tradeoff: f32,
};

/// Encode a single Fast sub-chunk in raw-literal mode (no entropy).
///
/// Port of C# `Fast.FastParser.CompressGreedy` for raw mode. Matches the
/// C# parser's coordinate split:
///   * bounds on accepted match offsets are measured against the SUB-CHUNK
///     start (`source.ptr`) so matches can't reach before the current
///     sub-chunk
///   * hash table positions are stored in WHOLE-INPUT coordinates
///     (`window_base`) so the persistent hash state from prior sub-chunks
///     produces stale entries with huge offsets that get filtered out by
///     the bound check, rather than folding to sub-chunk-local positions
///     and producing false-positive matches
///
/// The caller is responsible for resetting the hasher once at the top
/// of `compressFramed`; we do NOT reset per sub-chunk.
pub fn encodeSubChunkRaw(
    comptime level: i32,
    comptime T: type,
    allocator: std.mem.Allocator,
    hasher: *FastMatchHasher(T),
    source: []const u8,
    window_base: [*]const u8,
    dst: []u8,
    start_position: usize,
    config: ParserConfig,
) EncodeError!EncodeResult {
    comptime {
        if (T != u16 and T != u32) @compileError("encodeSubChunkRaw: T must be u16 or u32");
    }
    if (source.len <= fast_constants.min_source_length) return .{
        .bytes_written = 0,
        .chunk_type = .raw,
        .bail = true,
    };

    const initial_bytes: usize = if (start_position == 0) fast_constants.initial_copy_bytes else 0;
    const min_dst = initial_bytes + 3 + source.len + 256;
    if (dst.len < min_dst) return error.DestinationTooSmall;

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
                T,
                &w,
                hasher,
                block1_cursor,
                safe_for_block1,
                block1_end,
                &recent,
                dict_size,
                &mmlt,
                source.ptr,
                window_base,
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
                T,
                &w,
                hasher,
                block2_cursor,
                safe_for_block2,
                block2_end,
                &recent,
                dict_size,
                &mmlt,
                source.ptr,
                window_base,
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

    // ── Cost (matches C# Fast.Encoder.AssembleCompressedOutput, raw path) ──
    // tokenCost = tokenCount + 3         (memcpy-framed token stream)
    // literalCost = literalCount + 3     (raw literal stream header + data)
    // offset16Cost = off16Count * 2      (data portion only)
    // extraBytes = bytes_after_token_stream - offset16Bytes
    // cost = offset32Time + tokenCost + literalCost + decodingTime*speedTradeoff
    //      + extraBytes + offset16Cost + initialBytes
    const complex_token_count: i32 = @intCast(w.complex_token_count);
    const off32_total_count: i32 = @intCast(w.off32_count_block1 + w.off32_count_block2);
    const off32_time = cost_model.getDecodingTimeOffset32(0, off32_total_count) * config.speed_tradeoff;
    const decoding_time_raw = cost_model.getDecodingTimeRawCoded(
        0,
        @intCast(source.len),
        @intCast(token_count),
        complex_token_count,
        @intCast(literal_count),
    );
    const token_cost: f32 = @floatFromInt(token_count + 3);
    const literal_cost: f32 = @floatFromInt(literal_count + 3);
    const off16_cost: f32 = @floatFromInt(off16_count * 2);
    const dest_after_tokens: usize = initial_bytes + 3 + literal_count + 3 + token_count;
    const bytes_after_tokens: usize = total - dest_after_tokens;
    const extra_bytes: f32 = @floatFromInt(bytes_after_tokens - off16_count * 2);
    const initial_bytes_f: f32 = @floatFromInt(initial_bytes);
    const cost: f32 = off32_time + token_cost + literal_cost +
        decoding_time_raw * config.speed_tradeoff +
        extra_bytes + off16_cost + initial_bytes_f;

    if (std.process.hasEnvVarConstant("SLZ_COST_TRACE")) {
        std.debug.print(
            "[cost] srcLen={} tokens={} complex={} lits={} off16={} off32={} " ++
                "tokCost={d} litCost={d} off16Cost={d} off32Time={d} " ++
                "decTime={d} extraBytes={d} initBytes={d} speedTradeoff={d} " ++
                "TOTAL_COST={d} totalWritten={}\n",
            .{
                source.len,        token_count,        w.complex_token_count, literal_count,
                off16_count,       off32_total_count,  token_cost,            literal_cost,
                off16_cost,        off32_time,         decoding_time_raw,     extra_bytes,
                initial_bytes_f,   config.speed_tradeoff, cost,               total,
            },
        );
    }

    return .{ .bytes_written = total, .chunk_type = .raw, .bail = false, .cost = cost };
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
    window_base: [*]const u8,
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
                window_base,
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
                window_base,
            );
        } else {
            token_writer.copyTrailingLiterals(&w, block2_cursor, block2_end, recent);
        }
        w.off32_count_block2 = w.off32_count;
    }

    return assembleEntropyOutput(allocator, &w, dst, dst_cursor, source.len, options, initial_bytes, config);
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
    initial_bytes: usize,
    config: ParserConfig,
) EncodeError!EncodeResult {
    const literal_count: usize = w.literalCount();
    const token_count: usize = w.tokenCount();
    const off16_count: usize = w.off16Count();

    var out_cursor: [*]u8 = dst_cursor_in;
    const dst_end: [*]u8 = dst.ptr + dst.len;
    const bail_result: EncodeResult = .{ .bytes_written = 0, .chunk_type = .raw, .bail = true };

    const enc_scratch = try allocator.alloc(u8, @max(literal_count, token_count) + 512);
    defer allocator.free(enc_scratch);

    // C# has a `literalCount == 0 && deltaLiteralCount > 0` branch (Encoder.cs
    // lines 495-506) ahead of the main split below. It's unreachable with our
    // parsers — every literal write advances BOTH cursors in lockstep via
    // `writeOffset` / `writeOffsetWithLiteral1` / `copyTrailingLiterals`, so
    // the two counts are always equal. Kept as a comment for audit parity.

    // ── Encode literal stream — direct port of C# Fast.Encoder.AssembleCompressedOutput ──
    //
    // C# uses a histogram-cost-based comparison to decide whether to emit
    // delta literals (encode the residual after subtracting the recent match)
    // or raw literals. Identical decision is required for byte parity.
    //
    // raw_literal_cost = literalCount + 3      (memcpy framing header)
    // delta is preferred iff
    //     literalHisto.cost * 0.125 > deltaLiteralHisto.cost * 0.125 + deltaLiteralTimeCost
    var chunk_type: fast_constants.ChunkType = .raw;
    var literal_cost: f32 = std.math.inf(f32);
    const raw_literal_cost: f32 = @floatFromInt(literal_count + 3);
    if (literal_count >= 32) {
        var lit_histo: [256]u32 = undefined;
        byte_hist.countBytesHistogram(&lit_histo, w.literal_start[0..literal_count]);

        var encoded_literal_bytes: i32 = -1;
        if (w.delta_literal_start) |dls| {
            var delta_histo: [256]u32 = undefined;
            byte_hist.countBytesHistogram(&delta_histo, dls[0..literal_count]);
            const delta_literal_time_cost: f32 = cost_model.combinePlatformCostsScaled(
                0,
                @floatFromInt(literal_count),
                0.324,
                0.433,
                0.550,
                0.289,
            ) * config.speed_tradeoff;
            const lit_cost_approx: f32 = @floatFromInt(byte_hist.getCostApproxCore(&lit_histo, @intCast(literal_count)));
            const delta_cost_approx: f32 = @floatFromInt(byte_hist.getCostApproxCore(&delta_histo, @intCast(literal_count)));
            // C#: `level >= 6 || ...`. Our Fast levels are < 6, so the level
            // shortcut never fires in this code path.
            if (lit_cost_approx * 0.125 > delta_cost_approx * 0.125 + delta_literal_time_cost) {
                chunk_type = .delta;
                const delta_scratch = try allocator.alloc(u8, literal_count + 512);
                defer allocator.free(delta_scratch);
                const delta_n = try entropy_enc.encodeArrayU8(
                    allocator,
                    delta_scratch,
                    dls[0..literal_count],
                    options,
                    config.speed_tradeoff,
                    null, // Fast computes its own cost via histogram cost approx
                    0,
                    null,
                );
                literal_cost = @as(f32, @floatFromInt(delta_n)) + delta_literal_time_cost;
                if (delta_n <= 0 or delta_n >= literal_count or literal_cost > raw_literal_cost) {
                    literal_cost = std.math.inf(f32);
                    encoded_literal_bytes = -1;
                } else {
                    encoded_literal_bytes = @intCast(delta_n);
                    if (@intFromPtr(out_cursor) + delta_n > @intFromPtr(dst_end)) return bail_result;
                    @memcpy(out_cursor[0..delta_n], delta_scratch[0..delta_n]);
                    out_cursor += delta_n;
                }
            }
        }

        if (encoded_literal_bytes < 0) {
            // Raw literal path (memcpy-framed). C# treats this as `chunk_type = 1` (raw).
            chunk_type = .raw;
            literal_cost = raw_literal_cost;
            const raw_n = try entropy_enc.encodeArrayU8Memcpy(enc_scratch, w.literal_start[0..literal_count]);
            if (@intFromPtr(out_cursor) + raw_n > @intFromPtr(dst_end)) return bail_result;
            @memcpy(out_cursor[0..raw_n], enc_scratch[0..raw_n]);
            out_cursor += raw_n;
        }
    } else {
        chunk_type = .raw;
        literal_cost = raw_literal_cost;
        const raw_n = try entropy_enc.encodeArrayU8Memcpy(enc_scratch, w.literal_start[0..literal_count]);
        if (@intFromPtr(out_cursor) + raw_n > @intFromPtr(dst_end)) return bail_result;
        @memcpy(out_cursor[0..raw_n], enc_scratch[0..raw_n]);
        out_cursor += raw_n;
    }

    // ── Encode token stream (entropy) ──────────────────────────────────
    {
        const token_n = try entropy_enc.encodeArrayU8(
            allocator,
            enc_scratch,
            w.token_start[0..token_count],
            options,
            config.speed_tradeoff,
            null,
            0,
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
    //
    // Port of C# Fast.Encoder.AssembleCompressedOutput off16 section. Decision
    // is cost-based, not size-based:
    //     cost = costHigh + costLow + GetDecodingTimeOffset16 * speedTradeoff
    //     entropy used iff cost < offset16Count*2 AND enough room
    //
    // Only reached from `assembleEntropyOutput`, so `useLiteralEntropyCoding`
    // is implicit. `offset16_bytes_written` tracks the payload size of the
    // off16 stream (NOT counting the 2-byte header). Used in `extra_bytes`.
    var offset16_cost: f32 = @floatFromInt(off16_count * 2);
    var offset16_bytes_written: usize = off16_count * 2;
    var used_entropy_off16 = false;
    if (off16_count >= 32) {
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
        const hi_n = try entropy_enc.encodeArrayU8(allocator, split_enc, hi_bytes, options, config.speed_tradeoff, null, 0, null);
        const lo_n = try entropy_enc.encodeArrayU8(allocator, split_enc[hi_n..], lo_bytes, options, config.speed_tradeoff, null, 0, null);
        const split_total = hi_n + lo_n;
        // Without Huffman/tANS, encodeArrayU8 falls through to memcpy, which
        // emits `bytes + 3` output. C# sets cost = encoded-byte-count for the
        // memcpy branch, so `hi_n`/`lo_n` double as per-stream cost.
        const cost_hi: f32 = @floatFromInt(hi_n);
        const cost_lo: f32 = @floatFromInt(lo_n);
        const off16_dec_time: f32 = cost_model.getDecodingTimeOffset16(0, @intCast(off16_count)) * config.speed_tradeoff;
        const split_cost: f32 = cost_hi + cost_lo + off16_dec_time;
        const room_ok = @intFromPtr(out_cursor) + 2 + split_total <= @intFromPtr(dst_end);
        if (split_cost < offset16_cost and room_ok) {
            used_entropy_off16 = true;
            offset16_cost = split_cost;
            offset16_bytes_written = split_total;
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
        offset16_bytes_written = off16_bytes;
    }

    // Scratch-usage guard — direct port of C# line 642-648 in
    // Fast.Encoder.AssembleCompressedOutput. Sanity check that the internal
    // scratch accounting fits the statically-allocated budget. If this
    // trips, we bail to the uncompressed path rather than risk corruption.
    {
        const off32_total_count: usize = w.off32_count_block1 + w.off32_count_block2;
        const required_scratch: usize = token_count + literal_count +
            4 * (off32_total_count + off16_count) + 0xd000 + 0x40 + 4;
        const available_scratch: usize = @min(3 * source_len + 32 + 0xd000, 0x6c000);
        if (required_scratch > available_scratch) return bail_result;
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

    // ── Cost (entropy path, tANS disabled → memcpy for all streams) ──
    // In C# Fast.Encoder.AssembleCompressedOutput with useLiteralEntropyCoding=true:
    //   literalCost = literalCount + 3 (memcpy)
    //   tokenCost   = tokenCount + 3   (memcpy)
    //   offset16Cost = offset16Count * 2 (raw path) — no entropy split for tANS-off
    //   decodingTime = GetDecodingTimeEntropyCoded(length, tokenCount, complexTokenCount)
    //   extraBytes   = bytes_after_tokens - offset16Bytes
    //   cost = offset32Time + tokenCost + literalCost + decodingTime*speedTradeoff
    //        + extraBytes + offset16Cost + initialBytes
    const complex_token_count: i32 = @intCast(w.complex_token_count);
    const off32_total_count: i32 = @intCast(w.off32_count_block1 + w.off32_count_block2);
    const off32_time = cost_model.getDecodingTimeOffset32(0, off32_total_count) * config.speed_tradeoff;
    const decoding_time_entropy = cost_model.getDecodingTimeEntropyCoded(
        0,
        @intCast(source_len),
        @intCast(token_count),
        complex_token_count,
    );
    const token_cost: f32 = @floatFromInt(token_count + 3);
    // `literal_cost` and `offset16_cost` were set by the per-stream
    // encoders above (matching C# Fast.Encoder.AssembleCompressedOutput).
    //
    // dest_after_tokens = start of payload AFTER the token stream
    // bytes_after_tokens = everything from token-stream-end to end-of-output,
    //                      which in order is: (optional 2-byte
    //                      token_stream2_offset) + 2-byte off16 header +
    //                      off16 payload + off32 section + length stream.
    // extra_bytes = bytes_after_tokens - off16 payload.
    const dest_after_tokens: usize = initial_bytes + 3 + literal_count + 3 + token_count;
    const bytes_after_tokens: usize = total - dest_after_tokens;
    const extra_bytes: f32 = @floatFromInt(bytes_after_tokens - offset16_bytes_written);
    const initial_bytes_f: f32 = @floatFromInt(initial_bytes);
    const cost: f32 = off32_time + token_cost + literal_cost +
        decoding_time_entropy * config.speed_tradeoff +
        extra_bytes + offset16_cost + initial_bytes_f;

    return .{ .bytes_written = total, .chunk_type = chunk_type, .bail = false, .cost = cost };
}

/// Encode a sub-chunk in entropy mode using the L5 lazy parser with the
/// `MatchHasher2` chain-walking hasher. Port of `FastParser.CompressLazyChainHasher`.
pub fn encodeSubChunkEntropyChain(
    comptime engine_level: i32,
    allocator: std.mem.Allocator,
    hasher: *MatchHasher2,
    source: []const u8,
    window_base: [*]const u8,
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
    _ = window_base; // hasher.src_base is the whole-input base, set once by the driver

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

    return assembleEntropyOutput(allocator, &w, dst, dst_cursor, source.len, options, initial_bytes, config);
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
    hasher.reset();
    const res = try encodeSubChunkRaw(1, u32, testing.allocator, &hasher, &source, source[0..].ptr, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
        .speed_tradeoff = 0.14,
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
    hasher.reset();
    const res = try encodeSubChunkRaw(1, u32, testing.allocator, &hasher, &source, source[0..].ptr, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
        .speed_tradeoff = 0.14,
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
    hasher.reset();
    const res = try encodeSubChunkRaw(1, u32, testing.allocator, &hasher, &source, source[0..].ptr, &dst, 0, .{
        .minimum_match_length = 4,
        .dictionary_size = 0x40000000,
        .speed_tradeoff = 0.14,
    });
    try testing.expect(!res.bail);

    var decoded: [source.len + 64]u8 = @splat(0);
    try wrapAndDecode(dst[0..res.bytes_written], decoded[0..], source.len, 0);
    try testing.expectEqualSlices(u8, source[0..], decoded[0..source.len]);
}
