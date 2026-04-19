//! High optimal parser (L5+): DP-based minimum-cost parse over the
//! full source block, emitting a sequence of (literal-run, match)
//! tokens that minimizes total bit cost.
//! Used by: High codec (L6-L11)
//!
//! The parser operates in three phases per chunk:
//!
//!   1. Collect statistics — a greedy pass over the match table to
//!      seed a baseline `Stats` histogram set.
//!   2. Forward DP — for each position `pos`, evaluate every literal-
//!      run length + match candidate and propagate the minimum-cost
//!      state to the target positions.
//!   3. Backward extraction — walk the state chain back from the
//!      best final position to recover the optimal token sequence.
//!
//! Outer loop re-runs 1-3 up to twice (for L8+) picking the cheaper
//! output each time.
//!
//! The parser is NOT byte-exact validated yet — the full High codec
//! end-to-end round-trip validation lives in the wiring step (D9 /
//! step 34). This port ensures the code compiles and runs on its
//! own; fixture-based byte-exact checks come next.

const std = @import("std");
const lz_constants = @import("../../format/streamlz_constants.zig");
const match_eval = @import("../match_eval.zig");
const mls_mod = @import("managed_match_len_storage.zig");
const high_types = @import("high_types.zig");
const high_matcher = @import("high_matcher.zig");
const high_cost_model = @import("high_cost_model.zig");
const high_encoder = @import("high_encoder.zig");
const hist_mod = @import("../entropy/ByteHistogram.zig");

const LengthAndOffset = mls_mod.LengthAndOffset;
const ManagedMatchLenStorage = mls_mod.ManagedMatchLenStorage;
const State = high_types.State;
const Stats = high_types.Stats;
const CostModel = high_types.CostModel;
const Token = high_types.Token;
const TokenArray = high_types.TokenArray;
const HighRecentOffs = high_types.HighRecentOffs;
const HighStreamWriter = high_types.HighStreamWriter;
const HighEncoderContext = high_encoder.HighEncoderContext;
const HighWriterStorage = high_encoder.HighWriterStorage;

pub const min_bytes_per_round: usize = high_types.min_bytes_per_round;
pub const max_bytes_per_round: usize = high_types.max_bytes_per_round;
pub const recent_offset_count: usize = high_types.recent_offset_count;

pub const OptimalParserOptions = struct {
    dictionary_size: u32 = 0,
    min_match_length: u32 = 0,
    self_contained: bool = false,
    decode_cost_per_token: i32 = 0,
    decode_cost_small_offset: i32 = 0,
    decode_cost_short_match: i32 = 0,
};

/// Try to improve `states[state_idx]` with a new path. `is_recent`
/// selects between "recent-offset slot" and "raw offset" semantics.
///
inline fn updateState(
    state_idx: usize,
    bits: i32,
    literal_run_length: i32,
    match_length: i32,
    recent: i32,
    prev_state: usize,
    qrm: i32,
    states: [*]State,
    is_recent: bool,
) bool {
    const st = &states[state_idx];
    if (bits >= st.best_bit_count) return false;

    st.best_bit_count = bits;
    st.lit_len = literal_run_length;
    st.match_len = match_length;

    const r0 = states[prev_state].recent_offs0;
    const r1 = states[prev_state].recent_offs1;
    const r2 = states[prev_state].recent_offs2;

    if (is_recent) {
        std.debug.assert(recent >= 0 and recent <= 2);
        if (recent == 0) {
            st.recent_offs0 = r0;
            st.recent_offs1 = r1;
            st.recent_offs2 = r2;
        } else if (recent == 1) {
            st.recent_offs0 = r1;
            st.recent_offs1 = r0;
            st.recent_offs2 = r2;
        } else {
            st.recent_offs0 = r2;
            st.recent_offs1 = r0;
            st.recent_offs2 = r1;
        }
    } else {
        st.recent_offs0 = recent;
        st.recent_offs1 = r0;
        st.recent_offs2 = r1;
    }
    st.quick_recent_match_len_lit_len = qrm;
    st.prev_state = @intCast(prev_state);
    return true;
}

/// Update the stateWidth-wide band (multi-state DP).
fn updateStatesZ(
    pos: usize,
    bits_in: i32,
    literal_run_length: i32,
    match_length: i32,
    recent: i32,
    prev_state: usize,
    states: [*]State,
    source: [*]const u8,
    offset: i32,
    state_width: usize,
    cost_model: *const CostModel,
    lit_indexes: ?[*]i32,
    is_recent: bool,
) void {
    const after_match: usize = pos + @as(usize, @intCast(match_length));
    _ = updateState(after_match * state_width, bits_in, literal_run_length, match_length, recent, prev_state, 0, states, is_recent);

    var bits = bits_in;
    var jj: usize = 1;
    while (jj < state_width) : (jj += 1) {
        bits += @intCast(high_cost_model.bitsForLiteral(source, after_match + jj - 1, offset, cost_model));
        const updated = updateState(
            (after_match + jj) * state_width + jj,
            bits,
            literal_run_length,
            match_length,
            recent,
            prev_state,
            0,
            states,
            is_recent,
        );
        if (updated and jj == state_width - 1) {
            if (lit_indexes) |li| li[after_match + jj] = @intCast(jj);
        }
    }
}

/// Greedy-pass statistics collector. Walks the match table with the
/// same lazy-eval logic as `High.FastParser.CompressFast` and emits
/// tokens to a writer; the resulting `Stats` block seeds the optimal
/// parser's initial cost model.
fn collectStatistics(
    ctx: *const HighEncoderContext,
    stats: *Stats,
    min_match_len: i32,
    match_table: []const LengthAndOffset,
    source: [*]const u8,
    source_length: i32,
    start_pos: i32,
    window_base: [*]const u8,
    dict_size: i32,
    dst: [*]u8,
    dst_end: [*]u8,
    cost_out: *f32,
    chunk_type_out: *i32,
) !usize {
    stats.* = .{};

    var recent = HighRecentOffs.create();
    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try high_encoder.initializeStreamWriter(&writer, &storage, ctx.allocator, source_length, source, @intCast(ctx.encode_flags));
    defer storage.deinit();

    const initial_copy_bytes: usize = if (start_pos == 0) 8 else 0;
    var pos: usize = initial_copy_bytes;
    var last_pos: usize = initial_copy_bytes;
    const src_len_usize: usize = @intCast(source_length);
    const src_end_safe: [*]const u8 = source + src_len_usize - 8;

    while (pos < src_len_usize - 16) {
        const lit_since: i32 = @intCast(pos - last_pos);
        var m0 = high_matcher.getBestMatch(
            match_table[4 * pos ..],
            &recent,
            source + pos,
            src_end_safe,
            min_match_len,
            lit_since,
            window_base,
            dict_size,
        );

        if (m0.length == 0) {
            pos += 1;
            continue;
        }

        // Lazy matching: look 1 and 2 positions ahead.
        while (pos + 1 < src_len_usize - 16) {
            const lit_since1: i32 = @intCast(pos + 1 - last_pos);
            const m1 = high_matcher.getBestMatch(
                match_table[4 * (pos + 1) ..],
                &recent,
                source + pos + 1,
                src_end_safe,
                min_match_len,
                lit_since1,
                window_base,
                dict_size,
            );
            if (m1.length != 0 and match_eval.getLazyScore(m1, m0) > 0) {
                pos += 1;
                m0 = m1;
            } else {
                if (pos + 2 >= src_len_usize - 16) break;
                const lit_since2: i32 = @intCast(pos + 2 - last_pos);
                const m2 = high_matcher.getBestMatch(
                    match_table[4 * (pos + 2) ..],
                    &recent,
                    source + pos + 2,
                    src_end_safe,
                    min_match_len,
                    lit_since2,
                    window_base,
                    dict_size,
                );
                if (m2.length != 0 and match_eval.getLazyScore(m2, m0) > 3) {
                    pos += 2;
                    m0 = m2;
                } else break;
            }
        }

        // "Avoid recent0 immediately after a match when recent0 == recent1"
        // dedupe rule.
        if (pos - last_pos == 0 and m0.offset == 0 and recent.offs[4] == recent.offs[5]) {
            m0.offset = -1;
        }

        const lit_run_len: usize = pos - last_pos;
        high_encoder.addToken(
            &writer,
            &recent,
            source + last_pos,
            lit_run_len,
            m0.length,
            m0.offset,
            true,
            true,
        );
        pos += @intCast(m0.length);
        last_pos = pos;
    }

    high_encoder.addFinalLiterals(&writer, source + last_pos, source + src_len_usize, true);

    // Clone the context to clear `AllowMultiArray` + cap level at 4
    // for the statistics encode. In Zig we just pass a temporary context.
    var reduced_ctx = ctx.*;
    reduced_ctx.compression_level = @min(ctx.compression_level, 4);
    var reduced_opts = ctx.entropy_options;
    reduced_opts.allow_multi_array = false;
    reduced_ctx.entropy_options = reduced_opts;

    return try high_encoder.assembleCompressedOutput(
        &reduced_ctx,
        &writer,
        stats,
        dst,
        dst_end,
        start_pos,
        cost_out,
        chunk_type_out,
    );
}

/// Phase 3: Backward token extraction.
///
/// Walks the DP state chain from the best final position back to
/// `chunk_start`, emitting tokens in reverse order, then reverses
/// the token list in place and appends it to `lz_token_array`.
/// Returns the number of tokens written, or `null` when the token
/// array overflows (caller should bail out).
fn backwardExtract(
    states: [*]State,
    max_offset: usize,
    last_state_index: usize,
    chunk_start: usize,
    tokens_begin: []Token,
    lz_token_array: *TokenArray,
    lz_tokens: []Token,
) ?usize {
    var out_offs: usize = max_offset;
    var num_tokens: usize = 0;
    var state_cur_idx: usize = last_state_index;

    while (out_offs != chunk_start) {
        const state_cur = &states[state_cur_idx];
        const qrm: u32 = @bitCast(state_cur.quick_recent_match_len_lit_len);
        if (qrm != 0) {
            const extra_ml: usize = qrm >> 8;
            const extra_lit: usize = qrm & 0xFF;
            out_offs -= extra_ml + extra_lit;
            if (num_tokens < tokens_begin.len) {
                tokens_begin[num_tokens] = .{
                    .recent_offset0 = state_cur.recent_offs0,
                    .offset = 0,
                    .match_len = @intCast(extra_ml),
                    .lit_len = @intCast(extra_lit),
                };
                num_tokens += 1;
            }
        }
        const lit_len_sub: usize = @intCast(state_cur.lit_len);
        const match_len_sub: usize = @intCast(state_cur.match_len);
        if (out_offs < lit_len_sub + match_len_sub) break;
        out_offs -= lit_len_sub + match_len_sub;
        const prev_idx: usize = @intCast(state_cur.prev_state);
        const state_prev = &states[prev_idx];
        const recent0: i32 = state_cur.recent_offs0;
        const recent_index_opt = high_matcher.getRecentOffsetIndex(state_prev, recent0);
        const off_field: i32 = if (recent_index_opt) |ri| -@as(i32, ri) else recent0;
        if (num_tokens < tokens_begin.len) {
            tokens_begin[num_tokens] = .{
                .recent_offset0 = state_prev.recent_offs0,
                .lit_len = state_cur.lit_len,
                .match_len = state_cur.match_len,
                .offset = off_field,
            };
            num_tokens += 1;
        }
        state_cur_idx = prev_idx;
    }

    // Reverse the backward-walked token list in place.
    if (num_tokens > 1) {
        var lo: usize = 0;
        var hi: usize = num_tokens - 1;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) {
            const tmp = tokens_begin[lo];
            tokens_begin[lo] = tokens_begin[hi];
            tokens_begin[hi] = tmp;
        }
    }

    // Append this chunk's tokens to the full lz_token_array.
    if (lz_token_array.size + num_tokens > lz_token_array.capacity) {
        return null;
    }
    @memcpy(
        lz_tokens[lz_token_array.size .. lz_token_array.size + num_tokens],
        tokens_begin[0..num_tokens],
    );
    lz_token_array.size += num_tokens;

    return num_tokens;
}

/// Result of a single DP + encode pass, returned by `optimalOnePass`.
const OnePassResult = struct {
    /// Encoded byte count from `encodeTokenArray`, or 0 on encode failure.
    encoded_length: usize,
    /// Bit cost reported by the encoder.
    cost: f32,
    /// Chunk type chosen by the encoder.
    chunk_type: i32,
    /// True when `encodeTokenArray` returned an error.
    encode_failed: bool,
    /// True when the token array overflowed during backward extraction.
    token_overflow: bool,
};

/// Inner DP pass: forward DP + backward token extraction + encode.
///
/// Runs one full optimal-parse pass over the source with the
/// pre-configured `cost_model` and `stats`. Returns the encode
/// result without any outer-loop retry logic.
///
/// IMPORTANT: Do NOT modify the forward-DP or backward-extraction
/// loops in this function — they are extremely codegen-sensitive.
fn optimalOnePass(
    ctx: *const HighEncoderContext,
    source: [*]const u8,
    src_size: i32,
    start_pos: i32,
    cost_model: *CostModel,
    stats: *Stats,
    states: []State,
    lz_token_array: *TokenArray,
    lz_tokens: []Token,
    tokens_begin: []Token,
    lit_indexes: ?[*]i32,
    match_table: []const LengthAndOffset,
    tmp_dst_buf: []u8,
    src_len_usize: usize,
    initial_copy_bytes: i32,
    state_width: usize,
    max_literal_run_trials: i32,
    length_long_enough_thres: usize,
    sc: bool,
    sc_pos_in_chunk: i32,
    dict_size: u32,
    window_base: [*]const u8,
    min_match_length: i32,
    src_end_safe: [*]const u8,
) OnePassResult {
    for (0..state_width * src_len_usize + 1) |i| {
        states[i].best_bit_count = std.math.maxInt(i32);
    }

    lz_token_array.size = 0;
    var chunk_start: usize = @intCast(initial_copy_bytes);

    // Initial state.
    states[state_width * chunk_start].init();

    while (chunk_start < src_len_usize - 16) {
        var lit_bits_since_prev: i32 = 0;
        var prev_offset: usize = chunk_start;

        var chunk_end: usize = chunk_start + max_bytes_per_round;
        if (chunk_end >= src_len_usize - 32) chunk_end = src_len_usize - 16;

        var max_offset: usize = chunk_start + min_bytes_per_round;
        if (max_offset >= src_len_usize - 32) max_offset = src_len_usize - 16;

        const bits_for_offset_8: i32 = @intCast(high_cost_model.bitsForOffset(cost_model, 8));

        if (state_width > 1) {
            // Initialize the additional state columns.
            var i: usize = 1;
            while (i < state_width) : (i += 1) {
                var j: usize = 0;
                while (j < state_width) : (j += 1) {
                    states[state_width * (chunk_start + i) + j].best_bit_count = std.math.maxInt(i32);
                }
            }
            var j2: usize = 1;
            while (j2 < state_width) : (j2 += 1) {
                states[state_width * chunk_start + j2].best_bit_count = std.math.maxInt(i32);
            }

            if (max_offset - chunk_start > state_width) {
                var k: usize = 1;
                while (k < state_width) : (k += 1) {
                    states[(chunk_start + k) * state_width + k] = states[(chunk_start + k - 1) * state_width + k - 1];
                    const extra_bits: i32 = @intCast(high_cost_model.bitsForLiteral(
                        source,
                        chunk_start + k - 1,
                        states[chunk_start * state_width].recent_offs0,
                        cost_model,
                    ));
                    states[(chunk_start + k) * state_width + k].best_bit_count += extra_bits;
                }
                if (lit_indexes) |li| li[chunk_start + state_width - 1] = @intCast(state_width - 1);
            } else {
                chunk_start = src_len_usize - 16;
            }
        }

        // ── Phase 1: Forward DP ──
        var pos: usize = chunk_start;
        while (max_offset <= chunk_end) {
            if (pos == src_len_usize - 16) {
                max_offset = pos;
                break;
            }

            const src_cur: [*]const u8 = source + pos;
            const u32_at_cur: u32 = std.mem.readInt(u32, src_cur[0..4], .little);

            if (state_width == 1) {
                if (pos != prev_offset) {
                    const extra_bits: i32 = @intCast(high_cost_model.bitsForLiteral(
                        source,
                        pos - 1,
                        states[prev_offset].recent_offs0,
                        cost_model,
                    ));
                    lit_bits_since_prev += extra_bits;
                    const cur_bits = states[pos].best_bit_count;
                    if (cur_bits != std.math.maxInt(i32)) {
                        const prev_bits = states[prev_offset].best_bit_count + lit_bits_since_prev;
                        const lit_run_len: i32 = @intCast(pos - prev_offset);
                        if (cur_bits < prev_bits + @as(i32, @intCast(high_cost_model.bitsForLiteralLength(cost_model, lit_run_len)))) {
                            prev_offset = pos;
                            lit_bits_since_prev = 0;
                            if (pos >= max_offset) {
                                max_offset = pos;
                                break;
                            }
                        }
                    }
                }
            } else {
                if (pos >= max_offset) {
                    var tmp_cur_offset: usize = 0;
                    var best_bits: i32 = std.math.maxInt(i32);
                    var i: usize = 0;
                    while (i < state_width) : (i += 1) {
                        if (states[state_width * pos + i].best_bit_count < best_bits) {
                            best_bits = states[state_width * pos + i].best_bit_count;
                            const li_val: usize = if (lit_indexes) |li| @intCast(li[pos]) else 0;
                            const sub: usize = if (i != state_width - 1) i else li_val;
                            tmp_cur_offset = pos - sub;
                        }
                    }
                    if (tmp_cur_offset >= max_offset) {
                        max_offset = tmp_cur_offset;
                        break;
                    }
                }
                const cur = &states[state_width * pos + state_width - 1];
                if (cur.best_bit_count != std.math.maxInt(i32)) {
                    const li_val: i32 = if (lit_indexes) |li| li[pos] else 0;
                    const extra_bits: i32 = @intCast(high_cost_model.bitsForLiteral(
                        source,
                        pos,
                        cur.recent_offs0,
                        cost_model,
                    ));
                    const bits2 = cur.best_bit_count + extra_bits;
                    if (bits2 < states[state_width * pos + 2 * state_width - 1].best_bit_count) {
                        states[state_width * pos + 2 * state_width - 1] = cur.*;
                        states[state_width * pos + 2 * state_width - 1].best_bit_count = bits2;
                        if (lit_indexes) |li| li[pos + 1] = li_val + 1;
                    }
                }
            }

            // Extract matches from the match table.
            var match_arr: [8]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });
            var match_found_offset_bits: [8]i32 = @splat(0);
            var num_match: usize = 0;
            const sc_max_back: i64 = if (sc) @intCast(sc_pos_in_chunk + @as(i32, @intCast(pos))) else std.math.maxInt(i64);

            var lao_index: usize = 0;
            while (lao_index < 4) : (lao_index += 1) {
                // The varlen encoding stores large unsigned values in i32 fields,
                // so @bitCast is needed. The extractor now guarantees remaining
                // slots are zeroed, so no garbage reaches this cast.
                var lao_ml: u32 = @bitCast(match_table[4 * pos + lao_index].length);
                var lao_offs: u32 = @bitCast(match_table[4 * pos + lao_index].offset);
                if (lao_ml < @as(u32, @intCast(min_match_length))) break;
                const remaining: usize = @intFromPtr(src_end_safe) - @intFromPtr(src_cur);
                lao_ml = @min(lao_ml, @as(u32, @intCast(remaining)));
                if (lao_offs >= dict_size) continue;
                if (@as(i64, lao_offs) > sc_max_back) continue;

                if (lao_offs < 8) {
                    const tt = lao_offs;
                    while (lao_offs < 8) lao_offs += tt;
                    const back_dist: usize = @intFromPtr(src_cur) - @intFromPtr(window_base);
                    if (lao_offs > @as(u32, @intCast(back_dist))) continue;
                    if (@as(i64, lao_offs) > sc_max_back) continue;
                    const extended = match_eval.getMatchLengthQuickMin4(src_cur, @intCast(lao_offs), src_end_safe, u32_at_cur);
                    lao_ml = @intCast(extended);
                    if (lao_ml < @as(u32, @intCast(min_match_length))) continue;
                }

                if (high_matcher.checkMatchValidLength(lao_ml, lao_offs)) {
                    match_arr[num_match].length = @intCast(lao_ml);
                    match_arr[num_match].offset = @intCast(lao_offs);
                    match_found_offset_bits[num_match] = @intCast(high_cost_model.bitsForOffset(cost_model, lao_offs));
                    num_match += 1;
                }
            }

            // Also check offset 8.
            if (8 <= sc_max_back) {
                const length8 = match_eval.getMatchLengthQuickMin3(src_cur, 8, src_end_safe, u32_at_cur);
                if (@as(i32, @intCast(length8)) >= min_match_length and num_match < 8) {
                    match_arr[num_match].length = @intCast(length8);
                    match_arr[num_match].offset = 8;
                    match_found_offset_bits[num_match] = bits_for_offset_8;
                    num_match += 1;
                }
            }

            // For each literal-run length + match candidate, propagate DP states.
            var best_length_so_far: usize = 0;
            const lits_since_prev: i32 = @intCast(pos - prev_offset);
            var lowest_cost_from_any_lazy_trial: i32 = std.math.maxInt(i32);

            var lazy: i32 = 0;
            while (lazy <= max_literal_run_trials) : (lazy += 1) {
                var literal_run_length: i32 = undefined;
                var total_bits: i32 = undefined;
                var prev_state: usize = undefined;

                if (state_width == 1) {
                    literal_run_length = if (lazy == max_literal_run_trials and lits_since_prev > max_literal_run_trials)
                        lits_since_prev
                    else
                        lazy;
                    if (@as(i64, @intCast(pos)) - @as(i64, literal_run_length) < @as(i64, @intCast(chunk_start))) break;
                    prev_state = pos - @as(usize, @intCast(literal_run_length));
                    total_bits = states[prev_state].best_bit_count;
                    if (total_bits == std.math.maxInt(i32)) continue;
                    if (literal_run_length == lits_since_prev) {
                        total_bits += lit_bits_since_prev;
                    } else {
                        total_bits += @intCast(high_cost_model.bitsForLiterals(
                            source,
                            pos - @as(usize, @intCast(literal_run_length)),
                            @intCast(literal_run_length),
                            states[prev_state].recent_offs0,
                            cost_model,
                        ));
                    }
                } else {
                    if (lazy < state_width) {
                        prev_state = state_width * pos + @as(usize, @intCast(lazy));
                        total_bits = states[prev_state].best_bit_count;
                        if (total_bits == std.math.maxInt(i32)) continue;
                        const li_val: i32 = if (lit_indexes) |li| li[pos] else 0;
                        literal_run_length = if (lazy == @as(i32, @intCast(state_width - 1))) li_val else lazy;
                    } else {
                        literal_run_length = lazy - 1;
                        if (@as(i64, @intCast(pos)) - @as(i64, literal_run_length) < @as(i64, @intCast(chunk_start))) break;
                        prev_state = state_width * (pos - @as(usize, @intCast(literal_run_length)));
                        total_bits = states[prev_state].best_bit_count;
                        if (total_bits == std.math.maxInt(i32)) continue;
                        total_bits += @intCast(high_cost_model.bitsForLiterals(
                            source,
                            pos - @as(usize, @intCast(literal_run_length)),
                            @intCast(literal_run_length),
                            states[prev_state].recent_offs0,
                            cost_model,
                        ));
                    }
                }

                var length_field: i32 = literal_run_length;
                if (literal_run_length >= 3) {
                    length_field = 3;
                    total_bits += @intCast(high_cost_model.bitsForLiteralLength(cost_model, literal_run_length));
                }

                var recent_best_length: i32 = 0;

                // Recent offsets.
                var ridx: u2 = 0;
                while (ridx < recent_offset_count) : (ridx += 1) {
                    const offs = states[prev_state].getRecentOffs(ridx);
                    if (@as(i64, offs) > sc_max_back) continue;
                    const recent_ml_raw = match_eval.getMatchLengthQuick(src_cur, offs, src_end_safe, u32_at_cur);
                    const recent_ml: i32 = @intCast(recent_ml_raw);
                    if (recent_ml <= recent_best_length) continue;
                    recent_best_length = recent_ml;
                    max_offset = @max(max_offset, pos + @as(usize, @intCast(recent_ml)));
                    const full_bits = total_bits + high_cost_model.bitsForToken(
                        cost_model,
                        recent_ml,
                        @intCast(pos - @as(usize, @intCast(literal_run_length))),
                        ridx,
                        length_field,
                    );
                    updateStatesZ(pos, full_bits, literal_run_length, recent_ml, ridx, prev_state, states.ptr, source, offs, state_width, cost_model, lit_indexes, true);

                    if (recent_ml > 2 and recent_ml < @as(i32, @intCast(length_long_enough_thres))) {
                        var trial_ml: i32 = 2;
                        while (trial_ml < recent_ml) : (trial_ml += 1) {
                            const bits_sub = total_bits + high_cost_model.bitsForToken(
                                cost_model,
                                trial_ml,
                                @intCast(pos - @as(usize, @intCast(literal_run_length))),
                                ridx,
                                length_field,
                            );
                            updateStatesZ(pos, bits_sub, literal_run_length, trial_ml, ridx, prev_state, states.ptr, source, offs, state_width, cost_model, lit_indexes, true);
                        }
                    }

                    // Recent0 after 1-2 literals.
                    if (pos + @as(usize, @intCast(recent_ml)) + 4 < src_len_usize - 16) {
                        var num_lazy: i32 = 1;
                        while (num_lazy <= 2) : (num_lazy += 1) {
                            const trial_ptr = src_cur + @as(usize, @intCast(recent_ml + num_lazy));
                            const trial_len_raw = match_eval.getMatchLengthMin2(trial_ptr, offs, src_end_safe);
                            const trial_len: i32 = @intCast(trial_len_raw);
                            if (trial_len != 0) {
                                const cost2 = full_bits +
                                    @as(i32, @intCast(high_cost_model.bitsForLiterals(
                                        source,
                                        pos + @as(usize, @intCast(recent_ml)),
                                        @intCast(num_lazy),
                                        offs,
                                        cost_model,
                                    ))) +
                                    high_cost_model.bitsForToken(cost_model, trial_len, @intCast(pos + @as(usize, @intCast(recent_ml))), 0, num_lazy);
                                max_offset = @max(max_offset, pos + @as(usize, @intCast(recent_ml + trial_len + num_lazy)));
                                _ = updateState(
                                    (pos + @as(usize, @intCast(recent_ml + trial_len + num_lazy))) * state_width,
                                    cost2,
                                    literal_run_length,
                                    recent_ml,
                                    ridx,
                                    prev_state,
                                    num_lazy | (trial_len << 8),
                                    states.ptr,
                                    true,
                                );
                                break;
                            }
                        }
                    }
                }

                best_length_so_far = @max(best_length_so_far, @as(usize, @intCast(recent_best_length)));
                if (best_length_so_far >= length_long_enough_thres) break;

                if (total_bits < lowest_cost_from_any_lazy_trial) {
                    lowest_cost_from_any_lazy_trial = total_bits;

                    // Walk the match candidates.
                    var matchidx: usize = 0;
                    while (matchidx < num_match) : (matchidx += 1) {
                        const max_ml = match_arr[matchidx].length;
                        const moffs = match_arr[matchidx].offset;
                        if (max_ml <= recent_best_length) break;
                        const after_match: usize = pos + @as(usize, @intCast(max_ml));
                        best_length_so_far = @max(best_length_so_far, @as(usize, @intCast(max_ml)));
                        max_offset = @max(max_offset, after_match);
                        const bits_with_off = total_bits + match_found_offset_bits[matchidx];
                        const full_bits = bits_with_off + high_cost_model.bitsForToken(
                            cost_model,
                            max_ml,
                            @intCast(pos - @as(usize, @intCast(literal_run_length))),
                            @intCast(recent_offset_count),
                            length_field,
                        );
                        updateStatesZ(pos, full_bits, literal_run_length, max_ml, moffs, prev_state, states.ptr, source, moffs, state_width, cost_model, lit_indexes, false);

                        if (max_ml > min_match_length and max_ml < @as(i32, @intCast(length_long_enough_thres))) {
                            var trial_ml: i32 = min_match_length;
                            while (trial_ml < max_ml) : (trial_ml += 1) {
                                const bits_sub = bits_with_off + high_cost_model.bitsForToken(
                                    cost_model,
                                    trial_ml,
                                    @intCast(pos - @as(usize, @intCast(literal_run_length))),
                                    @intCast(recent_offset_count),
                                    length_field,
                                );
                                updateStatesZ(pos, bits_sub, literal_run_length, trial_ml, moffs, prev_state, states.ptr, source, moffs, state_width, cost_model, lit_indexes, false);
                            }
                        }

                        // Recent0 after 1-2 literals for new-offset matches too.
                        if (after_match + 4 < src_len_usize - 16) {
                            var num_lazy: i32 = 1;
                            while (num_lazy <= 2) : (num_lazy += 1) {
                                const trial_ptr = src_cur + @as(usize, @intCast(max_ml + num_lazy));
                                const trial_len_raw = match_eval.getMatchLengthMin2(trial_ptr, moffs, src_end_safe);
                                const trial_len: i32 = @intCast(trial_len_raw);
                                if (trial_len != 0) {
                                    const cost2 = full_bits +
                                        @as(i32, @intCast(high_cost_model.bitsForLiterals(
                                            source,
                                            after_match,
                                            @intCast(num_lazy),
                                            moffs,
                                            cost_model,
                                        ))) +
                                        high_cost_model.bitsForToken(cost_model, trial_len, @intCast(after_match), 0, num_lazy);
                                    max_offset = @max(max_offset, after_match + @as(usize, @intCast(trial_len + num_lazy)));
                                    _ = updateState(
                                        (after_match + @as(usize, @intCast(trial_len + num_lazy))) * state_width,
                                        cost2,
                                        literal_run_length,
                                        max_ml,
                                        moffs,
                                        prev_state,
                                        num_lazy | (trial_len << 8),
                                        states.ptr,
                                        false,
                                    );
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Long-match skip.
            if (best_length_so_far >= length_long_enough_thres) {
                const current_end: usize = best_length_so_far + pos;
                if (max_offset == current_end) {
                    max_offset = current_end;
                    prev_offset = current_end;
                    break;
                }
                if (state_width == 1) {
                    lit_bits_since_prev = 0;
                    prev_offset = current_end;
                } else {
                    const recent_offs0_local = states[current_end * state_width].recent_offs0;
                    var i: usize = 1;
                    while (i < state_width) : (i += 1) {
                        states[(current_end + i) * state_width + i] = states[(current_end + i - 1) * state_width + i - 1];
                        const extra_bits: i32 = @intCast(high_cost_model.bitsForLiteral(
                            source,
                            current_end + i - 1,
                            recent_offs0_local,
                            cost_model,
                        ));
                        states[(current_end + i) * state_width + i].best_bit_count += extra_bits;
                    }
                    if (lit_indexes) |li| li[current_end + state_width - 1] = @intCast(state_width - 1);
                }
                pos = current_end - 1;
            }

            pos += 1;
        }

        // ── Best-final selection (reached end of chunk/block) ──
        var last_state_index: usize = state_width * max_offset;
        const reached_end: bool = max_offset >= src_len_usize - 18;
        var final_lz_offset: usize = max_offset;

        if (reached_end) {
            var best_bits: i32 = std.math.maxInt(i32);
            if (state_width == 1) {
                var final_offs: usize = @max(chunk_start, if (prev_offset >= 8) prev_offset - 8 else 0);
                while (final_offs < src_len_usize) : (final_offs += 1) {
                    const bits = states[final_offs].best_bit_count;
                    if (bits == std.math.maxInt(i32)) continue;
                    const extra: i32 = @intCast(high_cost_model.bitsForLiterals(
                        source,
                        final_offs,
                        src_len_usize - final_offs,
                        states[final_offs].recent_offs0,
                        cost_model,
                    ));
                    const total = bits + extra;
                    if (total < best_bits) {
                        best_bits = total;
                        final_lz_offset = final_offs;
                        last_state_index = final_offs;
                    }
                }
            } else {
                var final_offs: usize = @max(chunk_start, if (max_offset >= 8) max_offset - 8 else 0);
                while (final_offs < src_len_usize) : (final_offs += 1) {
                    var idx: usize = 0;
                    while (idx < state_width) : (idx += 1) {
                        const bits = states[state_width * final_offs + idx].best_bit_count;
                        if (bits == std.math.maxInt(i32)) continue;
                        const litidx: usize = if (idx == state_width - 1)
                            (if (lit_indexes) |li| @intCast(li[final_offs]) else 0)
                        else
                            idx;
                        if (final_offs < litidx) continue;
                        const offs: usize = final_offs - litidx;
                        if (offs < chunk_start) continue;
                        const extra: i32 = @intCast(high_cost_model.bitsForLiterals(
                            source,
                            final_offs,
                            src_len_usize - final_offs,
                            states[state_width * final_offs + idx].recent_offs0,
                            cost_model,
                        ));
                        const total = bits + extra;
                        if (total < best_bits) {
                            best_bits = total;
                            final_lz_offset = offs;
                            last_state_index = state_width * final_offs + idx;
                        }
                    }
                }
            }
            max_offset = final_lz_offset;
        }

        // ── Phase 2: Backward token extraction ──
        const num_tokens = backwardExtract(
            states.ptr,
            max_offset,
            last_state_index,
            chunk_start,
            tokens_begin,
            lz_token_array,
            lz_tokens,
        ) orelse return .{
            .encoded_length = 0,
            .cost = std.math.inf(f32),
            .chunk_type = -1,
            .encode_failed = false,
            .token_overflow = true,
        };

        if (reached_end) break;

        // ── Phase 3: Stats update ──
        high_cost_model.updateStats(stats, source, chunk_start, tokens_begin[0..num_tokens]);
        high_cost_model.makeCostModel(stats, cost_model);
        chunk_start = max_offset;
    }

    // ── Encode the full accumulated token array ──
    var cost: f32 = std.math.inf(f32);
    var tmp_ct: i32 = -1;
    const n_enc = high_encoder.encodeTokenArray(
        ctx,
        source,
        src_size,
        tmp_dst_buf.ptr,
        tmp_dst_buf[tmp_dst_buf.len..].ptr,
        start_pos,
        lz_tokens[0..lz_token_array.size],
        stats,
        &cost,
        &tmp_ct,
    ) catch {
        return .{
            .encoded_length = 0,
            .cost = std.math.inf(f32),
            .chunk_type = -1,
            .encode_failed = true,
            .token_overflow = false,
        };
    };

    return .{
        .encoded_length = n_enc,
        .cost = cost,
        .chunk_type = tmp_ct,
        .encode_failed = false,
        .token_overflow = false,
    };
}

/// Optimal parser entry point. Performs the 3-phase DP + backward
/// extraction + outer-loop rematch for L8+.
///
/// The outer loop handles cost-model seeding, cross-block stats
/// carry, and chunk-type mismatch re-runs (up to twice for L8+).
/// The inner DP pass lives in `optimalOnePass`.
///
/// Returns the compressed byte count on success, or `null` when
/// compression isn't beneficial (the caller should emit uncompressed).
pub fn optimal(
    ctx: *const HighEncoderContext,
    opts: OptimalParserOptions,
    mls: ?*const ManagedMatchLenStorage,
    source: [*]const u8,
    src_size: i32,
    dst: [*]u8,
    dst_end: [*]u8,
    start_pos: i32,
    chunk_type_out: *i32,
    cost_out: *f32,
    /// Pre-allocated buffer for the match table. When non-null, must
    /// have at least `4 * src_size` entries. The caller retains
    /// ownership; `optimal` will NOT free it. When null, a fresh
    /// buffer is allocated (and freed) internally — legacy behaviour.
    match_table_buf: ?[]LengthAndOffset,
) !?usize {
    chunk_type_out.* = 0;
    const src_len_usize: usize = @intCast(src_size);
    if (src_size <= 128) return null;

    const state_width: usize = if (ctx.compression_level >= 8) 2 else 1;
    const max_literal_run_trials: i32 = if (ctx.compression_level >= 6) 8 else 4;

    const dict_size: u32 = if (opts.dictionary_size != 0 and opts.dictionary_size <= lz_constants.max_dictionary_size)
        opts.dictionary_size
    else
        lz_constants.max_dictionary_size;

    const sc = opts.self_contained;
    const sc_pos_in_chunk: i32 = start_pos;

    const initial_copy_bytes: i32 = if (start_pos == 0) 8 else 0;
    const src_end_safe: [*]const u8 = source + src_len_usize - 8;
    var min_match_length: i32 = @intCast(@max(opts.min_match_length, 4));
    const length_long_enough_thres: usize = @as(usize, 1) << @intCast(@min(8, ctx.compression_level));

    const window_base: [*]const u8 = source;

    // Match table — extracted from MLS when provided, otherwise zero-filled.
    // When the caller supplies a pre-allocated buffer we slice it to the
    // required length; otherwise fall back to a per-call allocation.
    const mt_len: usize = @intCast(4 * src_size);
    const mt_owned = if (match_table_buf == null) try ctx.allocator.alloc(LengthAndOffset, mt_len) else null;
    defer if (mt_owned) |owned| ctx.allocator.free(owned);
    const match_table: []LengthAndOffset = if (match_table_buf) |buf| buf[0..mt_len] else mt_owned.?;
    @memset(match_table, .{ .length = 0, .offset = 0 });
    if (mls) |m| {
        const mls_start: usize = @intCast(start_pos - m.round_start_pos);
        try mls_mod.extractLaoFromMls(m, mls_start, src_len_usize, match_table, 4);
    }

    // Self-contained filter: drop matches that cross group boundaries.
    if (sc) {
        const pos_in_chunk: i32 = start_pos;
        var pos: usize = 0;
        while (pos < src_len_usize) : (pos += 1) {
            const base_idx: usize = 4 * pos;
            const max_back: i32 = pos_in_chunk + @as(i32, @intCast(pos));
            var dst_i: usize = 0;
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                if (match_table[base_idx + j].length == 0) break;
                if (match_table[base_idx + j].offset <= max_back) {
                    if (dst_i != j) match_table[base_idx + dst_i] = match_table[base_idx + j];
                    dst_i += 1;
                }
            }
            var k: usize = dst_i;
            while (k < 4) : (k += 1) match_table[base_idx + k] = .{ .length = 0, .offset = 0 };
        }
    }

    // Token arrays.
    const lz_token_capacity: usize = src_len_usize / 2 + 8;
    const lz_tokens = try ctx.allocator.alloc(Token, lz_token_capacity);
    defer ctx.allocator.free(lz_tokens);
    var lz_token_array: TokenArray = .{
        .data = lz_tokens.ptr,
        .size = 0,
        .capacity = lz_token_capacity,
    };

    const tokens_capacity: usize = 4096 + 8;
    const tokens_begin = try ctx.allocator.alloc(Token, tokens_capacity);
    defer ctx.allocator.free(tokens_begin);

    const state_count: usize = state_width * (src_len_usize + 1);
    const states = try ctx.allocator.alloc(State, state_count);
    defer ctx.allocator.free(states);

    var lit_indexes_buf: ?[]i32 = null;
    defer if (lit_indexes_buf) |b| ctx.allocator.free(b);
    if (state_width > 1) {
        lit_indexes_buf = try ctx.allocator.alloc(i32, src_len_usize + 1);
        @memset(lit_indexes_buf.?, 0);
    }
    const lit_indexes: ?[*]i32 = if (lit_indexes_buf) |b| b.ptr else null;

    // Scratch for the trial encode buffer.
    // Allocate a separate scratch big enough for a bail-out fallback.
    const tmp_dst_size: usize = @intCast(src_size + 1024);
    const tmp_dst_buf = try ctx.allocator.alloc(u8, tmp_dst_size);
    defer ctx.allocator.free(tmp_dst_buf);

    var cost_model: CostModel = std.mem.zeroes(CostModel);
    var stats: Stats = .{};
    var tmp_stats: Stats = undefined;

    // ── Seed: first pass of CollectStatistics ──
    var cost: f32 = std.math.inf(f32);
    const n_first = try collectStatistics(
        ctx,
        &stats,
        min_match_length,
        match_table,
        source,
        src_size,
        start_pos,
        window_base,
        @intCast(dict_size),
        dst,
        dst_end,
        &cost,
        chunk_type_out,
    );
    if (n_first >= src_len_usize) return null;

    var best_cost: f32 = cost;
    var best_length: usize = n_first;

    // Try min_match_length = 3 for level >= 7.
    if (ctx.compression_level >= 7 and opts.min_match_length <= 3) {
        cost = std.math.inf(f32);
        var tmp_ct: i32 = -1;
        tmp_stats = .{};
        const n = try collectStatistics(
            ctx,
            &tmp_stats,
            3,
            match_table,
            source,
            src_size,
            start_pos,
            window_base,
            @intCast(dict_size),
            tmp_dst_buf.ptr,
            tmp_dst_buf[tmp_dst_buf.len..].ptr,
            &cost,
            &tmp_ct,
        );
        if (cost < best_cost and n < src_len_usize) {
            chunk_type_out.* = tmp_ct;
            @memcpy(dst[0..n], tmp_dst_buf[0..n]);
            best_cost = cost;
            best_length = n;
            min_match_length = 3;
            stats = tmp_stats;
        }
    }

    // Try min_match_length = 8.
    if (opts.min_match_length < 8) {
        cost = std.math.inf(f32);
        var tmp_ct: i32 = -1;
        tmp_stats = .{};
        const n = try collectStatistics(
            ctx,
            &tmp_stats,
            8,
            match_table,
            source,
            src_size,
            start_pos,
            window_base,
            @intCast(dict_size),
            tmp_dst_buf.ptr,
            tmp_dst_buf[tmp_dst_buf.len..].ptr,
            &cost,
            &tmp_ct,
        );
        if (cost < best_cost and n < src_len_usize) {
            chunk_type_out.* = tmp_ct;
            @memcpy(dst[0..n], tmp_dst_buf[0..n]);
            best_cost = cost;
            best_length = n;
            stats = tmp_stats;
        }
    }

    if (ctx.compression_level >= 7) {
        min_match_length = @intCast(@max(opts.min_match_length, 3));
    }

    // ── Cross-block stats carry ──
    // If the caller plumbed a `HighCrossBlockState`, read the previous
    // block's stats as a seed for `rescaleAddStats`. C# stores these in
    // `lzcoder.SymbolStatisticsScratch` + `lzcoder.LastChunkType`; without
    // plumbing this, multi-block streams diverge byte-exact parity.
    var prev_stats: ?Stats = null;
    var last_chunk_type: i32 = -1;
    if (ctx.cross_block) |cb| {
        if (cb.has_prev) {
            prev_stats = cb.prev_stats;
            last_chunk_type = cb.last_chunk_type;
        }
    }

    // ── Outer loop: re-run up to twice for L8+ ──
    var outer_loop_index_mut: u32 = 0;
    while (true) {
        // ── Cost-model seeding ──
        cost_model.chunk_type = chunk_type_out.*;
        cost_model.sub_or_copy_mask = if (chunk_type_out.* != 1) -1 else 0;
        cost_model.decode_cost_per_token = opts.decode_cost_per_token;
        cost_model.decode_cost_small_offset = opts.decode_cost_small_offset;
        cost_model.decode_cost_short_match = opts.decode_cost_short_match;

        if (last_chunk_type < 0) {
            high_cost_model.rescaleStats(&stats);
        } else if (prev_stats) |*h2| {
            high_cost_model.rescaleAddStats(&stats, h2, last_chunk_type == chunk_type_out.*);
        } else {
            high_cost_model.rescaleStats(&stats);
        }

        cost_model.offs_encode_type = stats.offs_encode_type;
        high_cost_model.makeCostModel(&stats, &cost_model);

        // ── Run the inner DP + encode pass ──
        const result = optimalOnePass(
            ctx,
            source,
            src_size,
            start_pos,
            &cost_model,
            &stats,
            states,
            &lz_token_array,
            lz_tokens,
            tokens_begin,
            lit_indexes,
            match_table,
            tmp_dst_buf,
            src_len_usize,
            initial_copy_bytes,
            state_width,
            max_literal_run_trials,
            length_long_enough_thres,
            sc,
            sc_pos_in_chunk,
            dict_size,
            window_base,
            min_match_length,
            src_end_safe,
        );

        // Token overflow → bail out (caller should emit uncompressed).
        if (result.token_overflow) return null;

        // Encode failure → keep whatever best_length we already have.
        if (result.encode_failed) break;

        if (result.cost >= best_cost) break;

        chunk_type_out.* = result.chunk_type;
        best_cost = result.cost;
        best_length = result.encoded_length;
        if (result.encoded_length > tmp_dst_size) return null;
        @memcpy(dst[0..result.encoded_length], tmp_dst_buf[0..result.encoded_length]);

        // Outer loop: for L8+, when the chosen chunk type disagrees with
        // the cost model's expected chunk type, re-run once with fresh
        // stats (last_chunk_type = -1). Otherwise break. Matches
        // `if (lzcoder.CompressionLevel < 8 || outerLoopIndex != 0 ||
        //     costModel.ChunkType == tmpChunkType) { save stats; break; }`.
        if (ctx.compression_level < 8 or outer_loop_index_mut != 0 or cost_model.chunk_type == result.chunk_type) {
            // Persist this block's stats so the next block can seed
            // `rescaleAddStats` instead of cold-starting.
            if (ctx.cross_block) |cb| {
                cb.prev_stats = stats;
                cb.last_chunk_type = result.chunk_type;
                cb.has_prev = true;
            }
            break;
        }

        last_chunk_type = -1;
        outer_loop_index_mut = 1;
    }

    cost_out.* = best_cost;
    return best_length;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "updateState: improves only when bits < current" {
    var states: [4]State = undefined;
    for (&states) |*s| s.init();
    states[0].best_bit_count = 1000;
    states[1].best_bit_count = 500;

    // Attempt to improve state 1 with a worse path — should NOT update.
    const improved1 = updateState(1, 600, 0, 0, 0, 0, 0, &states, true);
    try testing.expect(!improved1);
    try testing.expectEqual(@as(i32, 500), states[1].best_bit_count);

    // Attempt with a better path — SHOULD update.
    const improved2 = updateState(1, 100, 2, 5, 0, 0, 0, &states, true);
    try testing.expect(improved2);
    try testing.expectEqual(@as(i32, 100), states[1].best_bit_count);
    try testing.expectEqual(@as(i32, 2), states[1].lit_len);
    try testing.expectEqual(@as(i32, 5), states[1].match_len);
}

test "optimal: short input returns null" {
    var src: [100]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    const ctx: HighEncoderContext = .{
        .allocator = testing.allocator,
        .compression_level = 5,
        .speed_tradeoff = 0.05,
        .entropy_options = .{},
        .encode_flags = 0,
    };
    var dst_buf: [1024]u8 = undefined;
    var chunk_type: i32 = -1;
    var cost: f32 = 0;
    const result = try optimal(&ctx, .{}, null, &src, @intCast(src.len), &dst_buf, dst_buf[dst_buf.len..].ptr, 0, &chunk_type, &cost, null);
    try testing.expectEqual(@as(?usize, null), result);
}
