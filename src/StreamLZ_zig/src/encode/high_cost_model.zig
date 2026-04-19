//! High-codec cost model -- statistics, rescaling, histogram-to-cost
//! conversion, and per-token/offset/literal/literal-length cost lookups.
//! Used by: High codec (L6-L11)
//! The `IsMatchLongEnough` predicate lives in `high_matcher.zig`.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const hist_mod = @import("byte_histogram.zig");
const high_types = @import("high_types.zig");
const offset_encoder = @import("offset_encoder.zig");

const ByteHistogram = hist_mod.ByteHistogram;
const Token = high_types.Token;
const Stats = high_types.Stats;
const CostModel = high_types.CostModel;

/// Shift-down-then-add-one rescale of a single histogram.
pub fn rescaleOne(h: *ByteHistogram) void {
    for (0..256) |i| {
        h.count[i] = (h.count[i] >> 4) + 1;
    }
}

/// Rescales every histogram in a running `Stats` block.
pub fn rescaleStats(s: *Stats) void {
    rescaleOne(&s.lit_raw);
    rescaleOne(&s.lit_sub);
    rescaleOne(&s.offs_histo);
    if (s.offs_encode_type > 1) rescaleOne(&s.offs_lo_histo);
    rescaleOne(&s.token_histo);
    rescaleOne(&s.match_len_histo);
}

/// `h := ((h + t) >> 5) + 1`.
pub fn rescaleAddOne(h: *ByteHistogram, t: *const ByteHistogram) void {
    for (0..256) |i| {
        h.count[i] = ((h.count[i] + t.count[i]) >> 5) + 1;
    }
}

/// Merges the per-block `t` statistics into the running `s` and
/// rescales.
pub fn rescaleAddStats(s: *Stats, t: *const Stats, chunk_type_same: bool) void {
    if (chunk_type_same) {
        rescaleAddOne(&s.lit_raw, &t.lit_raw);
        rescaleAddOne(&s.lit_sub, &t.lit_sub);
    } else {
        rescaleOne(&s.lit_raw);
        rescaleOne(&s.lit_sub);
    }
    rescaleAddOne(&s.token_histo, &t.token_histo);
    rescaleAddOne(&s.match_len_histo, &t.match_len_histo);
    if (s.offs_encode_type == t.offs_encode_type) {
        rescaleAddOne(&s.offs_histo, &t.offs_histo);
        if (s.offs_encode_type > 1) rescaleAddOne(&s.offs_lo_histo, &t.offs_lo_histo);
    } else {
        s.offs_histo = t.offs_histo;
        s.offs_lo_histo = t.offs_lo_histo;
        s.offs_encode_type = t.offs_encode_type;
        rescaleOne(&s.offs_histo);
        if (s.offs_encode_type > 1) rescaleOne(&s.offs_lo_histo);
    }
}

/// Increments histogram counts for each symbol a token sequence would
/// encode.
pub fn updateStats(
    h: *Stats,
    src: [*]const u8,
    pos_in: usize,
    tokens: []const Token,
) void {
    const increment: u32 = 2;
    var pos = pos_in;

    for (tokens) |*t| {
        const litlen: usize = @intCast(t.lit_len);
        const recent: usize = @intCast(t.recent_offset0);

        // Per-literal histogram updates (raw + sub).
        // When `pos + j < recent` the subtraction wraps below the source
        // buffer. We use wrapping subtraction so Zig doesn't panic on
        // usize underflow — the resulting delta byte goes into the
        // histogram regardless.
        var j: usize = 0;
        while (j < litlen) : (j += 1) {
            const b: u8 = src[pos + j];
            h.lit_raw.count[b] += increment;
            const back_addr: usize = @intFromPtr(src + pos + j) -% recent;
            const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
            const prev_byte: u8 = back_ptr[0];
            const delta: u8 = b -% prev_byte;
            h.lit_sub.count[delta] += increment;
        }

        pos += litlen + @as(usize, @intCast(t.match_len));

        var length_field: i32 = @intCast(litlen);
        if (litlen >= 3) {
            const bucket: usize = @min(litlen - 3, @as(usize, 255));
            h.match_len_histo.count[bucket] += increment;
            length_field = 3;
        }

        // Guard: match_len must be >= 2. Token stream assumes this.
        if (t.match_len < 2) continue;

        const offset_i32: i32 = t.offset;
        var recent_field: i32 = undefined;
        if (t.offset <= 0) {
            recent_field = -t.offset;
        } else {
            recent_field = 3;
            const offset: u32 = @intCast(offset_i32);
            if (h.offs_encode_type == 0) {
                if (offset >= lz_constants.high_offset_threshold) {
                    const low_limit: u32 = @intCast(lz_constants.low_offset_encoding_limit);
                    const log_part: u32 = std.math.log2_int(u32, offset - low_limit);
                    const high_marker: u32 = @intCast(lz_constants.high_offset_marker);
                    const tv: u32 = log_part | high_marker;
                    h.offs_histo.count[tv] += increment;
                } else {
                    const bias: u32 = @intCast(lz_constants.offset_bias_constant);
                    const top_bits: u32 = std.math.log2_int(u32, offset + bias) - 9;
                    const tv: u32 = ((offset - 8) & 0xF) + 16 * top_bits;
                    h.offs_histo.count[tv] += increment;
                }
            } else if (h.offs_encode_type == 1) {
                const shifted: u32 = offset + 8;
                const tv: u32 = std.math.log2_int(u32, shifted) - 3;
                const u: u32 = 8 * tv | ((shifted >> @intCast(tv)) ^ 8);
                h.offs_histo.count[u] += increment;
            } else {
                const divisor: u32 = @intCast(h.offs_encode_type);
                const offset_high: u32 = offset / divisor;
                const offset_low: u32 = offset % divisor;
                const shifted_h: u32 = offset_high + 8;
                const tv: u32 = std.math.log2_int(u32, shifted_h) - 3;
                const u: u32 = 8 * tv | ((shifted_h >> @intCast(tv)) ^ 8);
                h.offs_histo.count[u] += increment;
                h.offs_lo_histo.count[offset_low] += increment;
            }
        }

        var matchlen_field: i32 = t.match_len - 2;
        if (t.match_len - 17 >= 0) {
            const bucket: usize = @min(@as(usize, @intCast(t.match_len - 17)), @as(usize, 255));
            h.match_len_histo.count[bucket] += increment;
            matchlen_field = 15;
        }

        const token_value: usize = @intCast(
            (matchlen_field << 2) + (recent_field << 6) + length_field,
        );
        h.token_histo.count[token_value] += increment;
    }
}

/// Builds a `CostModel` from the given `Stats` block by converting every
/// histogram to a per-symbol cost table.
pub fn makeCostModel(h: *const Stats, cost_model: *CostModel) void {
    offset_encoder.convertHistoToCost(&h.offs_histo, &cost_model.offs_cost, 36, 255);

    if (h.offs_encode_type > 1) {
        offset_encoder.convertHistoToCost(&h.offs_lo_histo, &cost_model.offs_lo_cost, 0, 255);
    }

    offset_encoder.convertHistoToCost(&h.token_histo, &cost_model.token_cost, 18, 255);
    offset_encoder.convertHistoToCost(&h.match_len_histo, &cost_model.match_len_cost, 12, 255);

    if (cost_model.chunk_type == 1) {
        offset_encoder.convertHistoToCost(&h.lit_raw, &cost_model.lit_cost, 0, 255);
    } else {
        offset_encoder.convertHistoToCost(&h.lit_sub, &cost_model.lit_cost, 0, 255);
    }
}

/// Cost in 32nds-of-a-bit for a literal run of the given length.
pub inline fn bitsForLiteralLength(cost_model: *const CostModel, cur_litlen: i32) u32 {
    if (cur_litlen < 3) return 0;
    if (cur_litlen - 3 >= 255) {
        const arg: u32 = @intCast(((cur_litlen - 3 - 255) >> 6) + 1);
        const v: u32 = std.math.log2_int(u32, @max(arg, 1));
        return cost_model.match_len_cost[255] + 32 * (2 * v + 7);
    }
    return cost_model.match_len_cost[@intCast(cur_litlen - 3)];
}

/// Cost in 32nds-of-a-bit for a single literal byte.
///
/// `sub_or_copy_mask` is `0` (copy mode, literals unchanged) or `-1`
/// (subtract mode, delta vs recent0). The original uses `byte & (byte)mask`
/// which truncates the i32 mask to the low 8 bits (0 or 0xFF) and
/// relies on signed int pointer arithmetic that silently wraps on
/// `pos - recent` underflow.
///
/// Zig panics on both the `@intCast(-1 → u8)` cast and the `pos -
/// recent` underflow. We fix both: bitcast the mask byte, and take
/// the copy-mode fast path (no subtract at all) when the mask is 0,
/// which bypasses the potentially-underflowing `pos - recent`.
pub inline fn bitsForLiteral(
    src: [*]const u8,
    pos: usize,
    recent: i32,
    cost_model: *const CostModel,
) u32 {
    if (cost_model.sub_or_copy_mask == 0) {
        // Copy mode: literal is the raw source byte, no delta.
        return cost_model.lit_cost[src[pos]];
    }
    const recent_u: usize = @intCast(recent);
    const byte_cur: u8 = src[pos];
    const byte_prev: u8 = src[pos - recent_u];
    const delta: u8 = byte_cur -% byte_prev;
    return cost_model.lit_cost[delta];
}

/// Aggregate cost for `num` consecutive literals.
pub inline fn bitsForLiterals(
    src: [*]const u8,
    pos: usize,
    num: usize,
    recent: i32,
    cost_model: *const CostModel,
) u32 {
    if (cost_model.sub_or_copy_mask == 0) {
        var sum: u32 = 0;
        var i: usize = 0;
        while (i < num) : (i += 1) {
            sum += cost_model.lit_cost[src[pos + i]];
        }
        return sum;
    }
    const recent_u: usize = @intCast(recent);
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const byte_cur: u8 = src[pos + i];
        const byte_prev: u8 = src[pos + i - recent_u];
        const delta: u8 = byte_cur -% byte_prev;
        sum += cost_model.lit_cost[delta];
    }
    return sum;
}

/// Computes the cost (in 32nds of a bit) of emitting a token with the
/// given `(match_len, cmd_offset, recent_field, length_field)`.
pub fn bitsForToken(
    cost_model: *const CostModel,
    cur_match_len: i32,
    _: i32, // cmd_offset is unused
    recent_field: i32,
    length_field: i32,
) i32 {
    var cost: i32 = undefined;
    if (cur_match_len - 17 >= 0) {
        var bits_for_match_len: i32 = undefined;
        if (cur_match_len - 17 >= 255) {
            const arg: u32 = @intCast(((cur_match_len - 17 - 255) >> 6) + 1);
            const bit_scan: i32 = @intCast(std.math.log2_int(u32, @max(arg, 1)));
            bits_for_match_len = @as(i32, @intCast(cost_model.match_len_cost[255])) + 32 * (2 * bit_scan + 7);
        } else {
            bits_for_match_len = @intCast(cost_model.match_len_cost[@intCast(cur_match_len - 17)]);
        }
        const idx: usize = @intCast((15 << 2) + (recent_field << 6) + length_field);
        cost = @as(i32, @intCast(cost_model.token_cost[idx])) + bits_for_match_len;
    } else {
        const idx: usize = @intCast(((cur_match_len - 2) << 2) + (recent_field << 6) + length_field);
        cost = @intCast(cost_model.token_cost[idx]);
    }

    cost += cost_model.decode_cost_per_token;
    if (cur_match_len <= 3) cost += cost_model.decode_cost_short_match;
    return cost;
}

/// Offset-distance penalty threshold — offsets requiring > 16 bits of
/// encoding space incur a per-bit penalty to bias the parser toward
/// nearby matches.
const offset_distance_penalty_threshold: u32 = 16;
const offset_distance_penalty_mult: u32 = 16;

/// Computes the cost of emitting an offset (in 32nds of a bit).
pub fn bitsForOffset(cost_model: *const CostModel, offset: u32) u32 {
    var cost: u32 = undefined;
    if (cost_model.offs_encode_type == 0) {
        if (offset >= lz_constants.high_offset_threshold) {
            const low_limit: u32 = @intCast(lz_constants.low_offset_encoding_limit);
            const log_part: u32 = std.math.log2_int(u32, offset - low_limit);
            const high_marker: u32 = @intCast(lz_constants.high_offset_marker);
            const t: u32 = log_part | high_marker;
            const adjust: u32 = @intCast(lz_constants.high_offset_cost_adjust);
            const u: u32 = t - adjust;
            cost = cost_model.offs_cost[t] + 32 * u + 12;
        } else {
            const bias: u32 = @intCast(lz_constants.offset_bias_constant);
            const top: u32 = std.math.log2_int(u32, offset + bias) - 9;
            const t: u32 = ((offset - 8) & 0xF) + 16 * top;
            const u: u32 = (t >> 4) + 5;
            cost = cost_model.offs_cost[t] + 32 * u;
        }
    } else if (cost_model.offs_encode_type == 1) {
        const shifted: u32 = offset + 8;
        const t: u32 = std.math.log2_int(u32, shifted) - 3;
        const u: u32 = 8 * t | ((shifted >> @intCast(t)) ^ 8);
        cost = cost_model.offs_cost[u] + 32 * (u >> 3);
    } else {
        const divisor: u32 = @intCast(cost_model.offs_encode_type);
        const offset_high: u32 = offset / divisor;
        const offset_low: u32 = offset % divisor;
        const shifted_h: u32 = offset_high + 8;
        const t: u32 = std.math.log2_int(u32, shifted_h) - 3;
        const u: u32 = 8 * t | ((shifted_h >> @intCast(t)) ^ 8);
        cost = cost_model.offs_cost[u] + 32 * (u >> 3) + cost_model.offs_lo_cost[offset_low];
    }

    // Distance penalty for far offsets.
    const offset_bits: u32 = std.math.log2_int(u32, offset + 1);
    if (offset_bits > offset_distance_penalty_threshold) {
        cost += (offset_bits - offset_distance_penalty_threshold) * offset_distance_penalty_mult;
    }

    // Decode-cost penalty for small offsets (byte-at-a-time match copy).
    if (offset < 16 and cost_model.decode_cost_small_offset > 0) {
        cost += @intCast(cost_model.decode_cost_small_offset);
    }

    return cost;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "rescaleOne halves then shifts to at-least 1" {
    var h: ByteHistogram = .{};
    h.count[0] = 16;
    h.count[1] = 1;
    h.count[2] = 0;
    rescaleOne(&h);
    try testing.expectEqual(@as(u32, 2), h.count[0]); // (16 >> 4) + 1 = 2
    try testing.expectEqual(@as(u32, 1), h.count[1]); // (1 >> 4) + 1 = 1
    try testing.expectEqual(@as(u32, 1), h.count[2]); // (0 >> 4) + 1 = 1
}

test "rescaleStats covers every stream" {
    var s: Stats = .{};
    s.lit_raw.count[0] = 100;
    s.lit_sub.count[0] = 100;
    s.token_histo.count[0] = 100;
    s.match_len_histo.count[0] = 100;
    s.offs_histo.count[0] = 100;
    s.offs_lo_histo.count[0] = 100;
    s.offs_encode_type = 2;
    rescaleStats(&s);
    try testing.expectEqual(@as(u32, 7), s.lit_raw.count[0]); // (100 >> 4) + 1 = 7
    try testing.expectEqual(@as(u32, 7), s.lit_sub.count[0]);
    try testing.expectEqual(@as(u32, 7), s.token_histo.count[0]);
    try testing.expectEqual(@as(u32, 7), s.match_len_histo.count[0]);
    try testing.expectEqual(@as(u32, 7), s.offs_histo.count[0]);
    try testing.expectEqual(@as(u32, 7), s.offs_lo_histo.count[0]);
}

test "bitsForLiteralLength: litlen < 3 returns 0" {
    var cm: CostModel = std.mem.zeroes(CostModel);
    try testing.expectEqual(@as(u32, 0), bitsForLiteralLength(&cm, 0));
    try testing.expectEqual(@as(u32, 0), bitsForLiteralLength(&cm, 2));
}

test "bitsForLiteralLength: litlen in [3, 257] reads from match_len_cost" {
    var cm: CostModel = std.mem.zeroes(CostModel);
    cm.match_len_cost[0] = 100;
    cm.match_len_cost[5] = 200;
    try testing.expectEqual(@as(u32, 100), bitsForLiteralLength(&cm, 3)); // index 0
    try testing.expectEqual(@as(u32, 200), bitsForLiteralLength(&cm, 8)); // index 5
}

test "rescaleAddOne merges two histograms" {
    var h: ByteHistogram = .{};
    var t: ByteHistogram = .{};
    h.count[0] = 30;
    t.count[0] = 34;
    rescaleAddOne(&h, &t);
    // (30 + 34) >> 5 = 2, + 1 = 3
    try testing.expectEqual(@as(u32, 3), h.count[0]);
}
