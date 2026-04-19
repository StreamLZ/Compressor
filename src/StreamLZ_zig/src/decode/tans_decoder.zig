//! tANS (tabled asymmetric numeral system) decoder — 5-state interleaved.
//!
//!
//!
//! Three phases per block:
//!   1. `decodeTable` — reads the symbol frequency table in either Golomb-
//!      Rice or sparse/explicit form into a `TansData` intermediate.
//!   2. `initLut` — distributes symbols into the L-entry decode LUT using
//!      a 4-way interleaved allocator that keeps consecutive entries on
//!      different decode lanes.
//!   3. `decode` — the 5-state hot loop that alternates between a forward
//!      bit reader (low→high) and a backward reader (high→low), emitting
//!      one symbol per state per round (≈10 symbols / iteration).

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const brl = @import("bit_reader_lite.zig");

pub const DecodeError = error{
    BadTableFormat,
    BadLogTableBits,
    BadTableWeights,
    LutConstructionFailed,
    SourceTruncated,
    DestinationTooSmall,
    StreamMismatch,
    StateOutOfRange,
} || brl.DecodeError;

// ────────────────────────────────────────────────────────────
//  Data structures
// ────────────────────────────────────────────────────────────

/// Intermediate table: A[] holds weight-1 symbols, B[] holds
/// `(symbol << 16) | weight` for weight ≥ 2.
pub const TansData = struct {
    a_used: u32 = 0,
    b_used: u32 = 0,
    a: [256]u8 = @splat(0),
    b: [256]u32 = @splat(0),
};

/// Single LUT entry — 8 bytes, cache-friendly.
pub const TansLutEnt = struct {
    x: u32,
    bits_x: u8,
    symbol: u8,
    w: u16,
};

/// Mutable 5-state decoder parameters.
pub const TansDecoderParams = struct {
    lut: [*]TansLutEnt,
    dst: [*]u8,
    dst_end: [*]u8,
    position_f: [*]const u8,
    position_b: [*]const u8,
    bits_f: u32,
    bits_b: u32,
    bitpos_f: i32,
    bitpos_b: i32,
    state0: u32,
    state1: u32,
    state2: u32,
    state3: u32,
    state4: u32,
    src_start: [*]const u8,
    src_end: [*]const u8,
    lut_mask: u32,
};

// ────────────────────────────────────────────────────────────
//  Table decoding — Golomb-Rice path and sparse/explicit path
// ────────────────────────────────────────────────────────────

pub fn decodeTable(
    br: *brl.BitReaderState,
    log_table_bits: u32,
    tans_data: *TansData,
) DecodeError!void {
    if (log_table_bits < 8 or log_table_bits > 12) return error.BadLogTableBits;

    brl.bitReaderRefill(br);

    if (brl.bitReaderReadBitNoRefill(br) != 0) {
        // Golomb-Rice coded
        const q_raw = brl.bitReaderReadBitsNoRefill(br, 3);
        const q: u5 = @intCast(q_raw);
        const num_symbols = brl.bitReaderReadBitsNoRefill(br, 8) + 1;
        if (num_symbols < 2) return error.BadTableFormat;

        const fluff_init = brl.bitReaderReadFluff(br, num_symbols);
        const total_rice_values: u32 = fluff_init + num_symbols;
        if (total_rice_values > 512) return error.BadTableFormat;

        var rice: [512 + 16]u8 = undefined;

        var br2: brl.BitReader2 = .{
            .p = undefined,
            .p_end = br.p_end,
            .bit_pos = @intCast(@as(u32, @bitCast(@as(i32, @truncate((br.bit_pos - 24) & 7))))),
        };
        const step_back: usize = @intCast((24 - br.bit_pos + 7) >> 3);
        br2.p = br.p - step_back;

        try brl.decodeGolombRiceLengths(&rice, total_rice_values, &br2);
        @memset(rice[total_rice_values..][0..16], 0);

        // Reset the bit reader to br2's position.
        br.bit_pos = 24;
        br.p = br2.p;
        br.bits = 0;
        brl.bitReaderRefill(br);
        const br2_bp: u5 = @intCast(br2.bit_pos);
        br.bits <<= br2_bp;
        br.bit_pos += @intCast(br2.bit_pos);

        if ((fluff_init >> 1) >= 133) return error.BadTableFormat;

        var range_buf: [133]brl.HuffRange = undefined;
        const num_ranges = try brl.huffConvertToRanges(
            &range_buf,
            num_symbols,
            fluff_init,
            rice[num_symbols..].ptr,
            br,
        );
        if (num_ranges == 0) return error.BadTableFormat;

        brl.bitReaderRefill(br);

        const l_val: u32 = @as(u32, 1) << @intCast(log_table_bits);
        var cur_rice_ptr: [*]const u8 = &rice;
        const cur_rice_end: [*]const u8 = rice[total_rice_values..].ptr;
        var average: i32 = 6;
        var somesum: i32 = 0;

        var safe_a: [256]u8 = undefined;
        var safe_b: [256]u32 = undefined;
        var a_count: u32 = 0;
        var b_count: u32 = 0;

        var ri: u32 = 0;
        while (ri < num_ranges) : (ri += 1) {
            var symbol: u32 = range_buf[ri].symbol;
            var num: u32 = range_buf[ri].num;
            if (num == 0 or num > 256) return error.BadTableFormat;

            while (true) {
                brl.bitReaderRefill(br);
                if (@intFromPtr(cur_rice_ptr) >= @intFromPtr(cur_rice_end)) return error.BadTableFormat;
                const rice_byte: u32 = cur_rice_ptr[0];
                cur_rice_ptr += 1;
                const nextra: u32 = q + rice_byte;
                if (nextra > 15) return error.BadTableFormat;

                const nextra_u6: u6 = @intCast(nextra);
                const nextra_u5: u5 = @intCast(nextra);
                const raw = brl.bitReaderReadBitsNoRefillZero(br, nextra_u6);
                var v: i32 = @as(i32, @intCast(raw)) +
                    @as(i32, @intCast(@as(u32, 1) << nextra_u5)) -
                    @as(i32, @intCast(@as(u32, 1) << q));

                const average_div_4: i32 = average >> 2;
                var limit: i32 = 2 * average_div_4;
                if (v <= limit) {
                    // v = averageDiv4 + (-(v & 1) ^ ((int)((uint)v >> 1)))
                    const signed_half: i32 = -(v & 1) ^ @as(i32, @bitCast(@as(u32, @bitCast(v)) >> 1));
                    v = average_div_4 + signed_half;
                }
                if (limit > v) limit = v;
                v += 1;
                average += limit - average_div_4;

                if (v == 1) {
                    if (a_count >= 256) return error.BadTableFormat;
                    safe_a[a_count] = @intCast(symbol);
                    a_count += 1;
                } else {
                    if (b_count >= 256) return error.BadTableFormat;
                    safe_b[b_count] = (@as(u32, @intCast(symbol)) << 16) | @as(u32, @intCast(v));
                    b_count += 1;
                }
                somesum += v;
                if (somesum > @as(i32, @intCast(l_val))) return error.BadTableFormat;
                symbol += 1;
                num -= 1;
                if (num == 0) break;
            }
        }
        if (somesum != @as(i32, @intCast(l_val))) return error.BadTableFormat;

        tans_data.a_used = a_count;
        tans_data.b_used = b_count;
        for (0..a_count) |k| tans_data.a[k] = safe_a[k];
        for (0..b_count) |k| tans_data.b[k] = safe_b[k];
        return;
    }

    // ── Sparse/explicit path ──
    var seen: [256]bool = @splat(false);
    const l_val: u32 = @as(u32, 1) << @intCast(log_table_bits);
    var count = brl.bitReaderReadBitsNoRefill(br, 3) + 1;
    const bits_per_sym_u32 = std.math.log2_int(u32, log_table_bits) + 1;
    const bits_per_sym: u5 = @intCast(bits_per_sym_u32);
    const max_delta_bits = brl.bitReaderReadBitsNoRefill(br, bits_per_sym);
    if (max_delta_bits == 0 or max_delta_bits > log_table_bits) return error.BadTableFormat;

    var a_used: u32 = 0;
    var b_used: u32 = 0;
    var weight: u32 = 0;
    var total_weights: u32 = 0;

    while (count != 0) : (count -= 1) {
        brl.bitReaderRefill(br);
        const sym = brl.bitReaderReadBitsNoRefill(br, 8);
        if (seen[sym]) return error.BadTableFormat;
        const delta_u5: u5 = @intCast(max_delta_bits);
        const delta = brl.bitReaderReadBitsNoRefill(br, delta_u5);
        weight += delta;
        if (weight == 0) return error.BadTableFormat;

        seen[sym] = true;
        if (weight == 1) {
            tans_data.a[a_used] = @intCast(sym);
            a_used += 1;
        } else {
            tans_data.b[b_used] = (sym << 16) | weight;
            b_used += 1;
        }
        total_weights += weight;
    }

    brl.bitReaderRefill(br);
    const last_sym = brl.bitReaderReadBitsNoRefill(br, 8);
    if (seen[last_sym]) return error.BadTableFormat;

    // Valid if totalWeights == L (exact) or L-1 (rounding).
    const diff_signed: i32 = @as(i32, @intCast(l_val)) - @as(i32, @intCast(total_weights));
    if (diff_signed < @as(i32, @intCast(weight)) or diff_signed <= 1) return error.BadTableFormat;

    tans_data.b[b_used] = (last_sym << 16) | @as(u32, @intCast(l_val - total_weights));
    b_used += 1;

    tans_data.a_used = a_used;
    tans_data.b_used = b_used;

    // Sort A[] and B[] ascending (stable for small counts; we use in-place insertion).
    insertionSortBytes(tans_data.a[0..a_used]);
    insertionSortU32(tans_data.b[0..b_used]);
}

fn insertionSortBytes(slice: []u8) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        const v = slice[i];
        var j: usize = i;
        while (j > 0 and slice[j - 1] > v) : (j -= 1) slice[j] = slice[j - 1];
        slice[j] = v;
    }
}

fn insertionSortU32(slice: []u32) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        const v = slice[i];
        var j: usize = i;
        while (j > 0 and slice[j - 1] > v) : (j -= 1) slice[j] = slice[j - 1];
        slice[j] = v;
    }
}

// ────────────────────────────────────────────────────────────
//  LUT initialization (4-way interleaved)
// ────────────────────────────────────────────────────────────

pub fn initLut(
    tans_data: *const TansData,
    log_table_bits: u32,
    lut: [*]TansLutEnt,
) DecodeError!void {
    const l_int: i32 = @as(i32, 1) << @intCast(log_table_bits);
    const l_usize: usize = @intCast(l_int);
    const a_used: i32 = @intCast(tans_data.a_used);
    if (a_used > l_int) return error.LutConstructionFailed;

    const slots_left_to_alloc: u32 = @intCast(l_int - a_used);
    const sa: u32 = slots_left_to_alloc >> 2;

    var pointers: [4]usize = undefined;
    pointers[0] = 0;
    var sb: u32 = sa + (if ((slots_left_to_alloc & 3) > 0) @as(u32, 1) else 0);
    pointers[1] = sb;
    sb += sa + (if ((slots_left_to_alloc & 3) > 1) @as(u32, 1) else 0);
    pointers[2] = sb;
    sb += sa + (if ((slots_left_to_alloc & 3) > 2) @as(u32, 1) else 0);
    pointers[3] = sb;

    // Single-weight entries live at the end.
    {
        const singles_start: usize = slots_left_to_alloc;
        const bits_x: u8 = @intCast(log_table_bits);
        const x: u32 = (@as(u32, 1) << @intCast(log_table_bits)) - 1;
        const le = TansLutEnt{ .x = x, .bits_x = bits_x, .symbol = 0, .w = 0 };

        var i: i32 = 0;
        while (i < a_used) : (i += 1) {
            const idx: usize = singles_start + @as(usize, @intCast(i));
            if (idx >= l_usize) return error.LutConstructionFailed;
            var entry = le;
            entry.symbol = tans_data.a[@intCast(i)];
            lut[idx] = entry;
        }
    }

    // Weight ≥ 2 entries.
    var weights_sum: i32 = 0;
    for (0..tans_data.b_used) |bi| {
        const val = tans_data.b[bi];
        const weight: i32 = @intCast(val & 0xFFFF);
        if (weight < 1) return error.LutConstructionFailed;
        const symbol: i32 = @intCast(val >> 16);

        if (weight > 4) {
            const sym_bits: u32 = std.math.log2_int(u32, @intCast(weight));
            var bits_per_symbol: i32 = @as(i32, @intCast(log_table_bits)) - @as(i32, @intCast(sym_bits));
            if (bits_per_symbol < 0) return error.LutConstructionFailed;

            const shift: u5 = @intCast(bits_per_symbol);
            var le = TansLutEnt{
                .symbol = @intCast(symbol),
                .bits_x = @intCast(bits_per_symbol),
                .x = (@as(u32, 1) << shift) - 1,
                .w = @intCast((l_int - 1) & (weight << shift)),
            };
            var what_to_add: i32 = @as(i32, 1) << shift;
            var upper_slot_count: i32 = (@as(i32, 1) << @intCast(sym_bits + 1)) - weight;
            if (upper_slot_count < 0) return error.LutConstructionFailed;

            for (0..4) |j| {
                var dst_idx: usize = pointers[j];
                const quarter_weight: i32 = (weight + ((weights_sum - @as(i32, @intCast(j)) - 1) & 3)) >> 2;

                if (upper_slot_count >= quarter_weight) {
                    var n = quarter_weight;
                    while (n != 0) : (n -= 1) {
                        if (dst_idx >= l_usize) return error.LutConstructionFailed;
                        lut[dst_idx] = le;
                        dst_idx += 1;
                        le.w +%= @intCast(what_to_add);
                    }
                    upper_slot_count -= quarter_weight;
                } else {
                    var n = upper_slot_count;
                    while (n != 0) : (n -= 1) {
                        if (dst_idx >= l_usize) return error.LutConstructionFailed;
                        lut[dst_idx] = le;
                        dst_idx += 1;
                        le.w +%= @intCast(what_to_add);
                    }
                    bits_per_symbol -= 1;
                    what_to_add >>= 1;
                    le.bits_x = @intCast(bits_per_symbol);
                    le.w = 0;
                    le.x >>= 1;
                    n = quarter_weight - upper_slot_count;
                    while (n != 0) : (n -= 1) {
                        if (dst_idx >= l_usize) return error.LutConstructionFailed;
                        lut[dst_idx] = le;
                        dst_idx += 1;
                        le.w +%= @intCast(what_to_add);
                    }
                    upper_slot_count = weight;
                }

                pointers[j] = dst_idx;
            }
        } else {
            // weight ≤ 4 — distribute via trailing-zero-count
            var bits_val: u32 = (@as(u32, (@as(u32, 1) << @intCast(weight)) - 1)) << @intCast(@as(u32, @intCast(weights_sum)) & 3);
            bits_val |= bits_val >> 4;
            var n: i32 = weight;
            var ww: i32 = weight;
            while (n != 0) : (n -= 1) {
                const idx: u32 = @ctz(bits_val);
                if (idx > 3) return error.LutConstructionFailed;
                bits_val &= bits_val - 1;
                const dst_idx = pointers[idx];
                if (dst_idx >= l_usize) return error.LutConstructionFailed;
                const weight_bits: u32 = std.math.log2_int(u32, @intCast(ww));
                const bits_per_symbol_inner: u5 = @intCast(@as(i32, @intCast(log_table_bits)) - @as(i32, @intCast(weight_bits)));
                lut[dst_idx] = .{
                    .symbol = @intCast(symbol),
                    .bits_x = @intCast(bits_per_symbol_inner),
                    .x = (@as(u32, 1) << bits_per_symbol_inner) - 1,
                    .w = @intCast((l_int - 1) & (ww << bits_per_symbol_inner)),
                };
                ww += 1;
                pointers[idx] = dst_idx + 1;
            }
        }
        weights_sum += weight;
    }
}

// ────────────────────────────────────────────────────────────
//  Hot decode loop (5-state interleaved, forward + backward)
// ────────────────────────────────────────────────────────────

pub fn decode(p: *TansDecoderParams) DecodeError!void {
    var lut = p.lut;
    var dst = p.dst;
    const dst_end = p.dst_end;
    var ptr_f = p.position_f;
    var ptr_b = p.position_b;
    var bits_f = p.bits_f;
    var bits_b = p.bits_b;
    var bitpos_f = p.bitpos_f;
    var bitpos_b = p.bitpos_b;
    var state0 = p.state0;
    var state1 = p.state1;
    var state2 = p.state2;
    var state3 = p.state3;
    var state4 = p.state4;

    const src_start = p.src_start;
    const src_end = p.src_end;
    const lut_mask = p.lut_mask;

    if (@intFromPtr(ptr_f) > @intFromPtr(ptr_b)) return error.StreamMismatch;

    if (@intFromPtr(dst) < @intFromPtr(dst_end)) {
        outer: while (true) {
            // ── TANS_FORWARD_BITS + round state0, state1 ──
            if (@intFromPtr(ptr_f) > @intFromPtr(src_end)) return error.SourceTruncated;
            const fw1: u32 = std.mem.readInt(u32, ptr_f[0..4], .little);
            bits_f |= fw1 << @intCast(bitpos_f);
            ptr_f += @as(usize, @intCast((31 - bitpos_f) >> 3));
            bitpos_f |= 24;

            {
                const e0 = &lut[state0];
                dst[0] = e0.symbol;
                dst += 1;
                bitpos_f -= @intCast(e0.bits_x);
                state0 = ((bits_f & e0.x) + e0.w) & lut_mask;
                bits_f >>= @intCast(e0.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }
            {
                const e1 = &lut[state1];
                dst[0] = e1.symbol;
                dst += 1;
                bitpos_f -= @intCast(e1.bits_x);
                state1 = ((bits_f & e1.x) + e1.w) & lut_mask;
                bits_f >>= @intCast(e1.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }

            if (@intFromPtr(ptr_f) > @intFromPtr(src_end)) return error.SourceTruncated;
            const fw2: u32 = std.mem.readInt(u32, ptr_f[0..4], .little);
            bits_f |= fw2 << @intCast(bitpos_f);
            ptr_f += @as(usize, @intCast((31 - bitpos_f) >> 3));
            bitpos_f |= 24;

            {
                const e2 = &lut[state2];
                dst[0] = e2.symbol;
                dst += 1;
                bitpos_f -= @intCast(e2.bits_x);
                state2 = ((bits_f & e2.x) + e2.w) & lut_mask;
                bits_f >>= @intCast(e2.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;

                const e3 = &lut[state3];
                dst[0] = e3.symbol;
                dst += 1;
                bitpos_f -= @intCast(e3.bits_x);
                state3 = ((bits_f & e3.x) + e3.w) & lut_mask;
                bits_f >>= @intCast(e3.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }

            if (@intFromPtr(ptr_f) > @intFromPtr(src_end)) return error.SourceTruncated;
            const fw3: u32 = std.mem.readInt(u32, ptr_f[0..4], .little);
            bits_f |= fw3 << @intCast(bitpos_f);
            ptr_f += @as(usize, @intCast((31 - bitpos_f) >> 3));
            bitpos_f |= 24;

            {
                const e4 = &lut[state4];
                dst[0] = e4.symbol;
                dst += 1;
                bitpos_f -= @intCast(e4.bits_x);
                state4 = ((bits_f & e4.x) + e4.w) & lut_mask;
                bits_f >>= @intCast(e4.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }

            // ── TANS_BACKWARD_BITS + round state0 ──
            if (@intFromPtr(ptr_b) < @intFromPtr(src_start)) return error.SourceTruncated;
            {
                const back_word_le: u32 = std.mem.readInt(u32, (ptr_b - 4)[0..4], .little);
                bits_b |= @byteSwap(back_word_le) << @intCast(bitpos_b);
                ptr_b -= @as(usize, @intCast((31 - bitpos_b) >> 3));
                bitpos_b |= 24;
            }

            {
                const e0 = &lut[state0];
                dst[0] = e0.symbol;
                dst += 1;
                bitpos_b -= @intCast(e0.bits_x);
                state0 = ((bits_b & e0.x) + e0.w) & lut_mask;
                bits_b >>= @intCast(e0.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;

                const e1 = &lut[state1];
                dst[0] = e1.symbol;
                dst += 1;
                bitpos_b -= @intCast(e1.bits_x);
                state1 = ((bits_b & e1.x) + e1.w) & lut_mask;
                bits_b >>= @intCast(e1.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }

            if (@intFromPtr(ptr_b) < @intFromPtr(src_start)) return error.SourceTruncated;
            {
                const back_word_le: u32 = std.mem.readInt(u32, (ptr_b - 4)[0..4], .little);
                bits_b |= @byteSwap(back_word_le) << @intCast(bitpos_b);
                ptr_b -= @as(usize, @intCast((31 - bitpos_b) >> 3));
                bitpos_b |= 24;
            }

            {
                const e2 = &lut[state2];
                dst[0] = e2.symbol;
                dst += 1;
                bitpos_b -= @intCast(e2.bits_x);
                state2 = ((bits_b & e2.x) + e2.w) & lut_mask;
                bits_b >>= @intCast(e2.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;

                const e3 = &lut[state3];
                dst[0] = e3.symbol;
                dst += 1;
                bitpos_b -= @intCast(e3.bits_x);
                state3 = ((bits_b & e3.x) + e3.w) & lut_mask;
                bits_b >>= @intCast(e3.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }

            if (@intFromPtr(ptr_b) < @intFromPtr(src_start)) return error.SourceTruncated;
            {
                const back_word_le: u32 = std.mem.readInt(u32, (ptr_b - 4)[0..4], .little);
                bits_b |= @byteSwap(back_word_le) << @intCast(bitpos_b);
                ptr_b -= @as(usize, @intCast((31 - bitpos_b) >> 3));
                bitpos_b |= 24;
            }

            {
                const e4 = &lut[state4];
                dst[0] = e4.symbol;
                dst += 1;
                bitpos_b -= @intCast(e4.bits_x);
                state4 = ((bits_b & e4.x) + e4.w) & lut_mask;
                bits_b >>= @intCast(e4.bits_x);
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break :outer;
            }
        }
    }

    // Pointer convergence check.
    const ptr_diff: isize = @as(isize, @intCast(@intFromPtr(ptr_b))) - @as(isize, @intCast(@intFromPtr(ptr_f)));
    const adjust: isize = @as(isize, bitpos_f >> 3) + @as(isize, bitpos_b >> 3);
    if (ptr_diff + adjust != 0) return error.StreamMismatch;

    const states_or: u32 = state0 | state1 | state2 | state3 | state4;
    if ((states_or & ~@as(u32, 0xFF)) != 0) return error.StateOutOfRange;

    // Dump final states.
    dst_end[0] = @intCast(state0);
    dst_end[1] = @intCast(state1);
    dst_end[2] = @intCast(state2);
    dst_end[3] = @intCast(state3);
    dst_end[4] = @intCast(state4);

}

// ────────────────────────────────────────────────────────────
//  Top-level entry
// ────────────────────────────────────────────────────────────

pub fn highDecodeTans(
    src_in: [*]const u8,
    src_size: usize,
    dst: [*]u8,
    dst_size: usize,
    scratch: [*]u8,
    scratch_end: [*]u8,
) DecodeError!usize {
    if (src_size < 8 or dst_size < 5) return error.SourceTruncated;

    const src_end_orig: [*]const u8 = src_in + src_size;
    var src_end: [*]const u8 = src_end_orig;

    var br: brl.BitReaderState = .{
        .p = src_in,
        .p_end = src_end,
        .bits = 0,
        .bit_pos = 24,
    };
    brl.bitReaderRefill(&br);

    // Reserved bit must be 0.
    if (brl.bitReaderReadBitNoRefill(&br) != 0) return error.BadTableFormat;

    const log_table_bits: u32 = brl.bitReaderReadBitsNoRefill(&br, 2) + 8;

    var tans_data: TansData = .{};
    try decodeTable(&br, log_table_bits, &tans_data);

    var src: [*]const u8 = br.p - @as(usize, @intCast(@divTrunc(24 - br.bit_pos, 8)));
    // Capture src_start BEFORE state-init modifies src. The decode hot
    // loop's backward-reader bound is this post-table position, not the
    // post-state-init position.
    const src_start_post_table: [*]const u8 = src;
    if (@intFromPtr(src) >= @intFromPtr(src_end) or @intFromPtr(src_end) - @intFromPtr(src) < 8) {
        return error.SourceTruncated;
    }

    const l_int: i32 = @as(i32, 1) << @intCast(log_table_bits);

    // Validate table before LUT construction.
    const a_used: i32 = @intCast(tans_data.a_used);
    const b_used: i32 = @intCast(tans_data.b_used);
    if (a_used < 0 or a_used > l_int or b_used < 0 or b_used > 256) return error.BadTableWeights;
    var weight_sum: i32 = a_used;
    for (0..tans_data.b_used) |i| {
        const w: i32 = @intCast(tans_data.b[i] & 0xFFFF);
        if (w < 2 or w > l_int) return error.BadTableWeights;
        weight_sum += w;
    }
    if (weight_sum != l_int) return error.BadTableWeights;

    // LUT allocation in scratch, 16-byte aligned.
    const lut_required: usize = @as(usize, @intCast(l_int)) * @sizeOf(TansLutEnt);
    const scratch_addr = @intFromPtr(scratch);
    const aligned_addr = (scratch_addr + 15) & ~@as(usize, 15);
    if (aligned_addr + lut_required > @intFromPtr(scratch_end)) return error.SourceTruncated;
    const aligned_lut: [*]TansLutEnt = @ptrFromInt(aligned_addr);

    try initLut(&tans_data, log_table_bits, aligned_lut);

    // Initial state readout from forward + backward ends of the bit stream.
    var bits_f: u32 = std.mem.readInt(u32, src[0..4], .little);
    src += 4;
    var bits_b: u32 = @byteSwap(std.mem.readInt(u32, (src_end - 4)[0..4], .little));
    src_end -= 4;
    var bitpos_f: i32 = 32;
    var bitpos_b: i32 = 32;

    const l_mask: u32 = (@as(u32, 1) << @intCast(log_table_bits)) - 1;
    const ltb_u5: u5 = @intCast(log_table_bits);

    const state0: u32 = bits_f & l_mask;
    const state1: u32 = bits_b & l_mask;
    bits_f >>= ltb_u5;
    bitpos_f -= @intCast(log_table_bits);
    bits_b >>= ltb_u5;
    bitpos_b -= @intCast(log_table_bits);

    const state2: u32 = bits_f & l_mask;
    const state3: u32 = bits_b & l_mask;
    bits_f >>= ltb_u5;
    bitpos_f -= @intCast(log_table_bits);
    bits_b >>= ltb_u5;
    bitpos_b -= @intCast(log_table_bits);

    // Refill forward side for the final state.
    bits_f |= std.mem.readInt(u32, src[0..4], .little) << @intCast(bitpos_f);
    src += @as(usize, @intCast((31 - bitpos_f) >> 3));
    bitpos_f |= 24;

    const state4: u32 = bits_f & l_mask;
    bits_f >>= ltb_u5;
    bitpos_f -= @intCast(log_table_bits);

    var params: TansDecoderParams = .{
        .lut = aligned_lut,
        .dst = dst,
        .dst_end = dst + dst_size - 5,
        .position_f = src - @as(usize, @intCast(bitpos_f >> 3)),
        .bitpos_f = bitpos_f & 7,
        .bits_f = bits_f,
        .position_b = src_end + @as(usize, @intCast(bitpos_b >> 3)),
        .bitpos_b = bitpos_b & 7,
        .bits_b = bits_b,
        .state0 = state0,
        .state1 = state1,
        .state2 = state2,
        .state3 = state3,
        .state4 = state4,
        // src_start / src_end here are the
        // post-table src position (BEFORE state-init advances src) and the
        // ORIGINAL src_end (before the backward-init decrement). The decode
        // hot loop's pointer bounds-check relies on this "outer" range, and
        // its forward/backward reads legitimately step into the overlap
        // region formed by the state-init bytes at both ends.
        .src_start = src_start_post_table,
        .src_end = src_end_orig,
        .lut_mask = l_mask,
    };

    try decode(&params);
    return src_size;
}
