//! High-codec encoder: HighStreamWriter init, per-token stream writers,
//! and the top-level `assembleCompressedOutput` that entropy-encodes the
//! 5 sub-streams into the final chunk payload.
//! Used by: High codec (L6-L11)
//!
//! The `HighStreamWriter` holds pointers into a single backing allocation
//! carved into 7 regions (literals, delta-literals, tokens, near-offsets,
//! far-offsets, literal run lengths, overflow lengths). The decoder reads
//! each stream sequentially so interleaving would destroy cache behaviour.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const hist_mod = @import("ByteHistogram.zig");
const entropy_enc = @import("entropy_encoder.zig");
const offset_enc = @import("offset_encoder.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const high_types = @import("high_types.zig");
const ptr_math = @import("../io/ptr_math.zig");

const ByteHistogram = hist_mod.ByteHistogram;
const HighStreamWriter = high_types.HighStreamWriter;
const HighRecentOffs = high_types.HighRecentOffs;
const Stats = high_types.Stats;
const Token = high_types.Token;

/// Cross-block statistics state carried between High-codec compress
/// calls within a single stream. The
/// optimal parser saves its final `Stats` block after each call so the
/// next block can seed its cost model via `rescaleAddStats` instead of
/// the cold-start `rescaleStats`. `last_chunk_type = -1` signals "no
/// prior block".
pub const HighCrossBlockState = struct {
    prev_stats: Stats = .{},
    last_chunk_type: i32 = -1,
    has_prev: bool = false,
};

/// Runtime encoder context passed through `assembleCompressedOutput`.
pub const HighEncoderContext = struct {
    allocator: std.mem.Allocator,
    compression_level: i32,
    speed_tradeoff: f32,
    entropy_options: entropy_enc.EntropyOptions,
    encode_flags: u32,
    sub_or_copy_mask: i32 = 0,
    /// Self-contained mode flag. Read by the optimal
    /// parser (and the fast parser) to enable per-position SC max-back
    /// enforcement and the LAO pre-filter pass.
    self_contained: bool = false,
    /// Optional cross-block state. When present, the optimal parser
    /// reads `prev_stats` to seed the cost model and writes back the
    /// final stats for the next block. `null` = independent blocks.
    cross_block: ?*HighCrossBlockState = null,
};

/// Owns the backing scratch allocation for a `HighStreamWriter`.
/// Call `deinit` when done.
pub const HighWriterStorage = struct {
    backing: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HighWriterStorage) void {
        self.allocator.free(self.backing);
        self.* = undefined;
    }
};

/// Initializes a `HighStreamWriter` with a freshly allocated scratch
/// buffer carved into the 7 output streams.
///
/// The caller must keep `storage` alive for the lifetime of `writer`
/// and call `storage.deinit()` when done.
pub fn initializeStreamWriter(
    writer: *HighStreamWriter,
    storage: *HighWriterStorage,
    allocator: std.mem.Allocator,
    source_length: i32,
    src_base: [*]const u8,
    encode_flags: i32,
) !void {
    writer.src_ptr = src_base;
    writer.src_len = source_length;

    const source_len_usize: usize = @intCast(source_length);
    const literal_capacity: usize = source_len_usize + 8;
    const token_capacity: usize = source_len_usize / 2 + 8;
    const u8_offset_capacity: usize = source_len_usize / 3;
    const u32_offset_capacity: usize = source_len_usize / 3;
    const run_length8_capacity: usize = source_len_usize / 5;
    const run_length32_capacity: usize = source_len_usize / 256;

    const total_alloc: usize = literal_capacity * 2 +
        token_capacity +
        u8_offset_capacity +
        u32_offset_capacity * 4 +
        run_length8_capacity +
        run_length32_capacity * 4 +
        256;

    const buf = try allocator.alloc(u8, total_alloc);
    storage.* = .{ .backing = buf, .allocator = allocator };

    var p: [*]u8 = buf.ptr;
    writer.literals_start = p;
    writer.literals = p;
    p += literal_capacity;

    writer.delta_literals_start = p;
    writer.delta_literals = p;
    p += literal_capacity;

    writer.tokens_start = p;
    writer.tokens = p;
    p += token_capacity;

    writer.near_offsets_start = p;
    writer.near_offsets = p;
    p += u8_offset_capacity;

    // 4-byte align for the u32 streams — required because
    // `HighStreamWriter` stores them as `[*]u32` (default align=4).
    p = alignUpPtr(p, 4);
    const far_offsets_ptr: [*]u32 = @ptrCast(@alignCast(p));
    writer.far_offsets_start = far_offsets_ptr;
    writer.far_offsets = far_offsets_ptr;
    p += u32_offset_capacity * 4;

    writer.literal_run_lengths_start = p;
    writer.literal_run_lengths = p;
    p += run_length8_capacity;

    p = alignUpPtr(p, 4);
    const overflow_lengths_ptr: [*]u32 = @ptrCast(@alignCast(p));
    writer.overflow_lengths_start = overflow_lengths_ptr;
    writer.overflow_lengths = overflow_lengths_ptr;

    writer.recent0 = @intCast(lz_constants.initial_recent_offset);
    writer.encode_flags = encode_flags;
}

inline fn alignUpPtr(p: [*]u8, comptime alignment: usize) [*]u8 {
    const addr: usize = @intFromPtr(p);
    const aligned: usize = (addr + (alignment - 1)) & ~@as(usize, alignment - 1);
    return @ptrFromInt(aligned);
}

// ────────────────────────────────────────────────────────────
//  Per-token stream writers
// ────────────────────────────────────────────────────────────

/// Writes the match length into the run-length / overflow streams and
/// returns the 4-bit `matchLen` token contribution pre-shifted to bits
/// 5:2.
/// Not `inline` — Zig's comptime evaluator would fold comptime-known
/// match_length values through the unreachable overflow branches and
/// fail type checks.
fn writeMatchLength(writer: *HighStreamWriter, match_length: i32) i32 {
    var ml_token: i32 = match_length - 2;
    if (ml_token >= 15) {
        ml_token = 15;
        if (match_length >= 255 + 17) {
            writer.literal_run_lengths[0] = 255;
            writer.literal_run_lengths += 1;
            // match_length - 255 - 17 is guaranteed >= 0 by the outer
            // guard; cast via u32 to dodge Zig's signed-range check.
            writer.overflow_lengths[0] = @as(u32, @bitCast(match_length - 255 - 17));
            writer.overflow_lengths += 1;
        } else {
            // match_length ∈ [17, 271] here → diff ∈ [0, 254]. Wrap
            // through u32 first so Zig doesn't reject the signed cast.
            writer.literal_run_lengths[0] = @truncate(@as(u32, @bitCast(match_length - 17)));
            writer.literal_run_lengths += 1;
        }
    }
    return ml_token << 2;
}

/// Long-literal path: copies `len` literal bytes + delta bytes.
fn writeLiteralsLong(writer: *HighStreamWriter, src: [*]const u8, len: usize, do_subtract: bool) void {
    if (do_subtract) {
        // delta[i] = src[i] - src[i - recent0] (dst uses negative offset).
        const neg: isize = -@as(isize, writer.recent0);
        offset_enc.subtractBytesUnsafe(writer.delta_literals, src, len, neg);
        writer.delta_literals += len;
    }

    // 4-byte unaligned copy loop. OK to overshoot; the literal buffer has
    // 8 bytes of headroom past the capacity estimate.
    var d: [*]u8 = writer.literals;
    const d_end: [*]u8 = d + len;
    var s: [*]const u8 = src;
    while (@intFromPtr(d) < @intFromPtr(d_end)) {
        const w = std.mem.readInt(u32, s[0..4], .little);
        std.mem.writeInt(u32, d[0..4], w, .little);
        d += 4;
        s += 4;
    }
    writer.literals = d_end;

    if (len >= 258) {
        writer.literal_run_lengths[0] = 255;
        writer.literal_run_lengths += 1;
        writer.overflow_lengths[0] = @intCast(len - 258);
        writer.overflow_lengths += 1;
    } else {
        writer.literal_run_lengths[0] = @intCast(len - 3);
        writer.literal_run_lengths += 1;
    }
}

/// Writes a literal run and returns the 2-bit `litLen` token field
/// (bits 1:0 of the command byte).
inline fn writeLiterals(writer: *HighStreamWriter, src: [*]const u8, len: usize, do_subtract: bool) i32 {
    if (len == 0) return 0;

    if (len > 8) {
        writeLiteralsLong(writer, src, len, do_subtract);
        return 3;
    }

    // Branchless run-length write: always store `len - 3`, only advance
    // the pointer when `len >= 3`. Relies on `(byte)(len - 3)` wrapping
    // when `len < 3`; Zig's `@intCast` would panic on the negative value,
    // so compute the wrap explicitly via `-%` + `@truncate`.
    const lrl8: [*]u8 = writer.literal_run_lengths;
    lrl8[0] = @truncate(len -% @as(usize, 3));
    writer.literal_run_lengths = if (len >= 3) lrl8 + 1 else lrl8;

    // 8-byte unaligned copy (safe due to headroom).
    const ll: [*]u8 = writer.literals;
    const w: u64 = std.mem.readInt(u64, src[0..8], .little);
    std.mem.writeInt(u64, ll[0..8], w, .little);
    writer.literals = ll + len;

    if (do_subtract) {
        const sl: [*]u8 = writer.delta_literals;
        const neg: isize = -@as(isize, writer.recent0);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const back_ptr: [*]const u8 = ptr_math.offsetPtr([*]const u8, src + i, neg);
            sl[i] = src[i] -% back_ptr[0];
        }
        writer.delta_literals = sl + len;
    }
    return @intCast(@min(len, @as(usize, 3)));
}

/// Writes a far offset (>= `high_offset_threshold`).
inline fn writeFarOffset(writer: *HighStreamWriter, offset: u32) void {
    const low_limit: u32 = @intCast(lz_constants.low_offset_encoding_limit);
    const bsr: u32 = std.math.log2_int(u32, offset - low_limit);
    const marker: u32 = @intCast(lz_constants.high_offset_marker);
    writer.near_offsets[0] = @intCast(bsr | marker);
    writer.near_offsets += 1;
    writer.far_offsets[0] = offset;
    writer.far_offsets += 1;
}

/// Writes a near offset (< `high_offset_threshold`).
inline fn writeNearOffset(writer: *HighStreamWriter, offset: u32) void {
    const bias: u32 = @intCast(lz_constants.offset_bias_constant);
    const bsr: u32 = std.math.log2_int(u32, offset + bias);
    const u8_val: u32 = ((offset - 8) & 0xF) | (16 * (bsr - 9));
    writer.near_offsets[0] = @intCast(u8_val);
    writer.near_offsets += 1;
    writer.far_offsets[0] = offset;
    writer.far_offsets += 1;
}

/// Writes an offset, dispatching near vs far.
inline fn writeOffset(writer: *HighStreamWriter, offset: u32) void {
    if (offset >= lz_constants.high_offset_threshold) {
        writeFarOffset(writer, offset);
    } else {
        writeNearOffset(writer, offset);
    }
}

/// Emits one token (literal run + match length + offset field) into
/// the writer's streams.
///
/// `offs_or_recent > 0` means "new offset"; `offs_or_recent <= 0` means
/// "reuse recent-offset slot `-offs_or_recent`" (0, 1, or 2).
pub fn addToken(
    writer: *HighStreamWriter,
    recent: *HighRecentOffs,
    lit_start: [*]const u8,
    lit_len: usize,
    match_len: i32,
    offs_or_recent: i32,
    do_recent: bool,
    do_subtract: bool,
) void {
    var token: i32 = writeLiterals(writer, lit_start, lit_len, do_subtract);
    token += writeMatchLength(writer, match_len);

    if (offs_or_recent > 0) {
        token += 3 << 6;
        if (do_recent) {
            recent.offs[6] = recent.offs[5];
            recent.offs[5] = recent.offs[4];
            recent.offs[4] = offs_or_recent;
        }
        writer.recent0 = offs_or_recent;
        writeOffset(writer, @intCast(offs_or_recent));
    } else {
        if (do_recent) {
            const idx: i32 = -offs_or_recent;
            std.debug.assert(idx >= 0 and idx <= 2);
            token += idx << 6;
            const idx_usize: usize = @intCast(idx);
            const v = recent.offs[idx_usize + 4];
            // Shift the ring: slots [3..(3+idx)] ← [4..(4+idx)], then put v at slot 4.
            recent.offs[idx_usize + 4] = recent.offs[idx_usize + 3];
            recent.offs[idx_usize + 3] = recent.offs[idx_usize + 2];
            recent.offs[4] = v;
            writer.recent0 = v;
        }
    }
    writer.tokens[0] = @intCast(token & 0xFF);
    writer.tokens += 1;
}

/// Emits the trailing literals past the last match.
pub fn addFinalLiterals(
    writer: *HighStreamWriter,
    src: [*]const u8,
    src_end: [*]const u8,
    do_subtract: bool,
) void {
    const len: usize = @intFromPtr(src_end) - @intFromPtr(src);
    if (len == 0) return;
    @memcpy(writer.literals[0..len], src[0..len]);
    writer.literals += len;
    if (do_subtract) {
        const neg: isize = -@as(isize, writer.recent0);
        offset_enc.subtractBytes(writer.delta_literals, src, len, neg);
        writer.delta_literals += len;
    }
}

// ────────────────────────────────────────────────────────────
//  Top-level AssembleCompressedOutput
// ────────────────────────────────────────────────────────────

/// Entropy-encodes the 5 sub-streams and concatenates them into the
/// final compressed output. Decides between raw (chunk type 1) and
/// delta-coded (chunk type 0) literals based on estimated entropy
/// cost. Returns the number of compressed bytes written, or the
/// source length on bail-out (caller treats as uncompressed).
///
///
pub fn assembleCompressedOutput(
    ctx: *const HighEncoderContext,
    writer: *const HighStreamWriter,
    stats: ?*Stats,
    dst_in: [*]u8,
    dst_end: [*]u8,
    start_pos: i32,
    cost_out: *f32,
    chunk_type_out: *i32,
) !usize {
    const dst_start: [*]u8 = dst_in;
    var dst: [*]u8 = dst_in;

    if (stats) |s| s.* = .{};

    const source: [*]const u8 = writer.src_ptr;
    const source_length: usize = @intCast(writer.src_len);

    const initial_bytes: usize = if (start_pos == 0) 8 else 0;
    {
        var i: usize = 0;
        while (i < initial_bytes) : (i += 1) {
            dst[0] = source[i];
            dst += 1;
        }
    }

    const level = ctx.compression_level;
    const flag_ignore_u32_length: bool = false; // always 0 here.
    std.debug.assert((ctx.encode_flags & 1) == 0);

    const num_lits: usize = @intFromPtr(writer.literals) - @intFromPtr(writer.literals_start);
    var lit_cost: f32 = std.math.inf(f32);
    const memcpy_cost: f32 = @floatFromInt(num_lits + 3);

    if (num_lits < 32 or level <= -4) {
        chunk_type_out.* = 1;
        const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        const dst_slice: []u8 = dst[0..dst_remaining];
        const src_slice: []const u8 = writer.literals_start[0..num_lits];
        const n = entropy_enc.encodeArrayU8Memcpy(dst_slice, src_slice) catch return source_length;
        dst += n;
        lit_cost = memcpy_cost;
    } else {
        var lits_histo: ByteHistogram = .{};
        lits_histo.countBytes(writer.literals_start[0..num_lits]);

        const has_litsub: bool = @intFromPtr(writer.delta_literals) != @intFromPtr(writer.delta_literals_start);
        var litsub_histo: ByteHistogram = .{};
        if (has_litsub) {
            litsub_histo.countBytes(writer.delta_literals_start[0..num_lits]);
        }

        if (stats) |s| {
            s.lit_raw = lits_histo;
            if (has_litsub) s.lit_sub = litsub_histo;
        }

        var lit_n: isize = -1;
        var skip_normal_lit: bool = false;

        if (has_litsub) {
            const litsub_extra_cost: f32 = @as(f32, @floatFromInt(num_lits)) *
                cost_coeffs.high_lit_sub_extra_cost_per_lit *
                ctx.speed_tradeoff;

            const lits_approx_f: f32 = @floatFromInt(offset_enc.getHistoCostApprox(&lits_histo.count, @intCast(num_lits)));
            const litsub_approx_f: f32 = @floatFromInt(offset_enc.getHistoCostApprox(&litsub_histo.count, @intCast(num_lits)));
            const skip_litsub: bool = level < 6 and
                lits_approx_f * cost_coeffs.cost_to_bits_factor <=
                litsub_approx_f * cost_coeffs.cost_to_bits_factor + litsub_extra_cost;

            if (!skip_litsub) {
                chunk_type_out.* = 0;
                var litsub_cost: f32 = std.math.inf(f32);
                const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
                const dst_slice: []u8 = dst[0..dst_remaining];
                const src_slice: []const u8 = writer.delta_literals_start[0..num_lits];
                const n = entropy_enc.encodeArrayU8WithHisto(
                    ctx.allocator,
                    dst_slice,
                    src_slice,
                    litsub_histo,
                    ctx.entropy_options,
                    ctx.speed_tradeoff,
                    &litsub_cost,
                    @intCast(@max(level, 0)),
                ) catch return source_length;
                litsub_cost += litsub_extra_cost;
                if (n > 0 and n < num_lits and litsub_cost <= memcpy_cost) {
                    lit_cost = litsub_cost;
                    lit_n = @intCast(n);
                    if (level < 6) skip_normal_lit = true;
                }
            }
        }

        if (!skip_normal_lit) {
            var raw_cost: f32 = std.math.inf(f32);
            const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
            const dst_slice: []u8 = dst[0..dst_remaining];
            const src_slice: []const u8 = writer.literals_start[0..num_lits];
            const n = entropy_enc.encodeArrayU8WithHisto(
                ctx.allocator,
                dst_slice,
                src_slice,
                lits_histo,
                ctx.entropy_options,
                ctx.speed_tradeoff,
                &raw_cost,
                @intCast(@max(level, 0)),
            ) catch return source_length;
            if (n > 0) {
                lit_n = @intCast(n);
                lit_cost = raw_cost;
                chunk_type_out.* = 1;
            }
        }

        if (lit_n < 0) return source_length;
        dst += @as(usize, @intCast(lit_n));
    }

    // ── Token stream ──
    var token_cost: f32 = std.math.inf(f32);
    const tok_len: usize = @intFromPtr(writer.tokens) - @intFromPtr(writer.tokens_start);
    {
        const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        const dst_slice: []u8 = dst[0..dst_remaining];
        const src_slice: []const u8 = writer.tokens_start[0..tok_len];
        const histo_out: ?*ByteHistogram = if (stats) |s| &s.token_histo else null;
        const tok_n = entropy_enc.encodeArrayU8(
            ctx.allocator,
            dst_slice,
            src_slice,
            ctx.entropy_options,
            ctx.speed_tradeoff,
            &token_cost,
            @intCast(@max(level, 0)),
            histo_out,
        ) catch return source_length;
        dst += tok_n;
    }

    // ── Offset streams ──
    var offs_cost: f32 = std.math.inf(f32);
    const num_off: usize = @intFromPtr(writer.near_offsets) - @intFromPtr(writer.near_offsets_start);
    const offs_result = blk: {
        const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        const dst_slice: []u8 = dst[0..dst_remaining];
        const u8_offs_slice: []u8 = writer.near_offsets_start[0..num_off];
        // `encodeLzOffsets` can write a new u8_offs stream back into the
        // caller's buffer when the modulo encoding wins; it expects a
        // mutable slice.
        const use_modulo: bool = (ctx.encode_flags & 4) != 0;
        const histo_out: ?*ByteHistogram = if (stats) |s| &s.offs_histo else null;
        const histo_lo_out: ?*ByteHistogram = if (stats) |s| &s.offs_lo_histo else null;
        const res = offset_enc.encodeLzOffsets(
            ctx.allocator,
            dst_slice,
            u8_offs_slice,
            writer.far_offsets_start,
            num_off,
            ctx.entropy_options,
            ctx.speed_tradeoff,
            8, // min_match_len == 8: takes the fast path at line 567
            use_modulo,
            @intCast(@max(level, 0)),
            histo_out,
            histo_lo_out,
        ) catch return source_length;
        break :blk res;
    };
    dst += offs_result.bytes_written;
    offs_cost = offs_result.cost;
    const offs_encode_type: i32 = @intCast(offs_result.offs_encode_type);
    if (stats) |s| s.offs_encode_type = offs_encode_type;

    // ── Literal run-length stream (u8) ──
    var lrl8_cost: f32 = std.math.inf(f32);
    const lrl8_len: usize = @intFromPtr(writer.literal_run_lengths) - @intFromPtr(writer.literal_run_lengths_start);
    {
        const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        const dst_slice: []u8 = dst[0..dst_remaining];
        const src_slice: []const u8 = writer.literal_run_lengths_start[0..lrl8_len];
        const histo_out: ?*ByteHistogram = if (stats) |s| &s.match_len_histo else null;
        const lrl8_n = entropy_enc.encodeArrayU8(
            ctx.allocator,
            dst_slice,
            src_slice,
            ctx.entropy_options,
            ctx.speed_tradeoff,
            &lrl8_cost,
            @intCast(@max(level, 0)),
            histo_out,
        ) catch return source_length;
        dst += lrl8_n;
    }

    // ── Offset extra bits (dual-ended bit stream) ──
    const bits_n = blk: {
        const dst_remaining: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        // `overflow_lengths` / `overflow_lengths_start` are both `[*]u32`, so
        // the pointer-byte diff must be divided by `@sizeOf(u32)` to recover
        // the element count expected by `writeLzOffsetBits`.
        const u32_len_count: usize =
            (@intFromPtr(writer.overflow_lengths) - @intFromPtr(writer.overflow_lengths_start)) / @sizeOf(u32);
        const res = offset_enc.writeLzOffsetBits(
            dst,
            dst + dst_remaining,
            writer.near_offsets_start,
            writer.far_offsets_start,
            num_off,
            @intCast(offs_encode_type),
            writer.overflow_lengths_start,
            u32_len_count,
            flag_ignore_u32_length,
        ) catch return source_length;
        break :blk res;
    };
    dst += bits_n;

    const total_written: usize = @intFromPtr(dst) - @intFromPtr(dst_start);
    if (total_written >= source_length) return source_length;

    // ── Cost computation ──
    const tok_num_f: f32 = @floatFromInt(tok_len);
    const lrl_num_f: f32 = @floatFromInt(lrl8_len);
    const src_len_f: f32 = @floatFromInt(source_length);

    const write_bits_cost: f32 =
        (cost_coeffs.high_write_bits_base +
        src_len_f * cost_coeffs.high_write_bits_per_src_byte +
        tok_num_f * cost_coeffs.high_write_bits_per_token +
        lrl_num_f * cost_coeffs.high_write_bits_per_lrl) *
        ctx.speed_tradeoff +
        @as(f32, @floatFromInt(initial_bytes + bits_n));

    const cost: f32 = token_cost + lit_cost + offs_cost + lrl8_cost + write_bits_cost;

    const overflow_count: usize = @intFromPtr(writer.overflow_lengths) - @intFromPtr(writer.overflow_lengths_start);
    const overflow_count_f: f32 = @floatFromInt(overflow_count / 4); // u32 entries
    cost_out.* = (cost_coeffs.length_base +
        lrl_num_f * cost_coeffs.length_u8_per_item +
        overflow_count_f * cost_coeffs.length_u32_per_item) *
        ctx.speed_tradeoff + cost;

    return total_written;
}

// ────────────────────────────────────────────────────────────
//  Encode a pre-parsed token array
// ────────────────────────────────────────────────────────────

/// Encodes a pre-parsed token array into `dst`. Walks the tokens in
/// order, calls `addToken` for each (with do_recent = do_subtract =
/// true), then `addFinalLiterals`, then `assembleCompressedOutput`.
///
/// The optimal
/// parser uses this to emit its final token sequence after the DP
/// phases complete.
pub fn encodeTokenArray(
    ctx: *const HighEncoderContext,
    source: [*]const u8,
    source_length: i32,
    dst: [*]u8,
    dst_end: [*]u8,
    start_pos: i32,
    tokens: []const Token,
    stats: ?*Stats,
    cost_out: *f32,
    chunk_type_out: *i32,
) !usize {
    cost_out.* = std.math.inf(f32);
    const src_end: [*]const u8 = source + @as(usize, @intCast(source_length));

    if (tokens.len == 0) return @intCast(source_length);

    var recent = HighRecentOffs.create();
    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try initializeStreamWriter(&writer, &storage, ctx.allocator, source_length, source, @intCast(ctx.encode_flags));
    defer storage.deinit();

    var cur_src: [*]const u8 = source;
    if (start_pos == 0) cur_src += 8;

    for (tokens) |tok| {
        addToken(
            &writer,
            &recent,
            cur_src,
            @intCast(tok.lit_len),
            tok.match_len,
            tok.offset,
            true, // do_recent
            true, // do_subtract
        );
        cur_src += @as(usize, @intCast(tok.lit_len)) + @as(usize, @intCast(tok.match_len));
    }
    addFinalLiterals(&writer, cur_src, src_end, true);

    return try assembleCompressedOutput(
        ctx,
        &writer,
        stats,
        dst,
        dst_end,
        start_pos,
        cost_out,
        chunk_type_out,
    );
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "initializeStreamWriter: carves 7 stream regions" {
    var src: [1024]u8 = @splat(0);
    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try initializeStreamWriter(&writer, &storage, testing.allocator, @intCast(src.len), &src, 0);
    defer storage.deinit();

    // All stream-end pointers should equal their starts (empty streams).
    try testing.expectEqual(@intFromPtr(writer.literals_start), @intFromPtr(writer.literals));
    try testing.expectEqual(@intFromPtr(writer.tokens_start), @intFromPtr(writer.tokens));
    try testing.expectEqual(@intFromPtr(writer.near_offsets_start), @intFromPtr(writer.near_offsets));
    try testing.expectEqual(@intFromPtr(writer.far_offsets_start), @intFromPtr(writer.far_offsets));

    // Recent0 seeded to initial_recent_offset.
    try testing.expectEqual(@as(i32, @intCast(lz_constants.initial_recent_offset)), writer.recent0);
}

test "writeMatchLength: short match (< 17) no overflow" {
    var src: [1024]u8 = @splat(0);
    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try initializeStreamWriter(&writer, &storage, testing.allocator, @intCast(src.len), &src, 0);
    defer storage.deinit();

    const token_bits = writeMatchLength(&writer, 5); // match length 5 → token = 3
    try testing.expectEqual(@as(i32, 3 << 2), token_bits);
    try testing.expectEqual(@intFromPtr(writer.literal_run_lengths_start), @intFromPtr(writer.literal_run_lengths));
}

test "writeMatchLength: match >= 17 writes run-length byte" {
    var src: [1024]u8 = @splat(0);
    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try initializeStreamWriter(&writer, &storage, testing.allocator, @intCast(src.len), &src, 0);
    defer storage.deinit();

    const token_bits = writeMatchLength(&writer, 20); // ml_token saturates at 15
    try testing.expectEqual(@as(i32, 15 << 2), token_bits);
    try testing.expectEqual(
        @as(usize, 1),
        @intFromPtr(writer.literal_run_lengths) - @intFromPtr(writer.literal_run_lengths_start),
    );
    try testing.expectEqual(@as(u8, 20 - 17), writer.literal_run_lengths_start[0]);
}

test "addToken: new offset + short literal run round-trips the streams" {
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);

    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try initializeStreamWriter(&writer, &storage, testing.allocator, @intCast(src.len), &src, 0);
    defer storage.deinit();

    var recent = HighRecentOffs.create();
    // Emit a 4-byte literal run then a match with new offset 100 length 6.
    addToken(&writer, &recent, src[0..].ptr, 4, 6, 100, true, false);

    // Literal stream got 4 bytes.
    try testing.expectEqual(
        @as(usize, 4),
        @intFromPtr(writer.literals) - @intFromPtr(writer.literals_start),
    );
    // Token byte written.
    try testing.expectEqual(
        @as(usize, 1),
        @intFromPtr(writer.tokens) - @intFromPtr(writer.tokens_start),
    );
    // Recent offset ring updated.
    try testing.expectEqual(@as(i32, 100), recent.offs[4]);
    // Near-offset stream has one entry.
    try testing.expectEqual(
        @as(usize, 1),
        @intFromPtr(writer.near_offsets) - @intFromPtr(writer.near_offsets_start),
    );
}
