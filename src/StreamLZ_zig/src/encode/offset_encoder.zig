//! Offset encoder + delta-literal subtraction helpers. Port of
//! src/StreamLZ/Compression/Entropy/OffsetEncoder.cs.
//!
//! Three distinct responsibilities live here:
//!   1. `subtractBytes{,Unsafe}` — the delta-literal subtract used by the
//!      Fast encoder's entropy path (`literal[i] - byte_at_recent_offset[i]`).
//!   2. Cost helpers — `getLog2Interpolate`, `convertHistoToCost`, and
//!      histogram-cost wrappers used by the High cost model.
//!   3. `encodeLzOffsets` / `writeLzOffsetBits` / `getBestOffsetEncoding*`
//!      / `encodeNewOffsets` — the full LZ offset encoding pipeline the
//!      High codec uses. Fast doesn't exercise this path (it emits raw
//!      off16 / off32 directly in `fast_lz_encoder.assembleEntropyOutput`)
//!      so these are Zig-port infrastructure for future High parity.

const std = @import("std");
const hist_mod = @import("byte_histogram.zig");
const entropy_enc = @import("entropy_encoder.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const bw_mod = @import("../io/bit_writer_64.zig");
const lz_constants = @import("../format/streamlz_constants.zig");

const ByteHistogram = hist_mod.ByteHistogram;
const BitWriter64Forward = bw_mod.BitWriter64Forward;
const BitWriter64Backward = bw_mod.BitWriter64Backward;

/// `dst[i] = src[i] - src[i + neg_offset]` for `len` bytes. `neg_offset`
/// is negative when the match source is before `src`. The function may
/// read one 16-byte vector past the end of `src` (the caller must ensure
/// at least 16 bytes of readable memory after `src + len`).
pub fn subtractBytesUnsafe(dst: [*]u8, src: [*]const u8, len: usize, neg_offset: isize) void {
    const V16 = @Vector(16, u8);
    var d = dst;
    var s = src;
    var remaining = len;
    while (remaining > 16) : (remaining -= 16) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        d[0..16].* = out;
        d += 16;
        s += 16;
    }
    // Tail: finish with one last vector subtract (may overshoot but that's
    // OK — caller guarantees 16 bytes of slack).
    if (remaining > 0) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        @memcpy(d[0..remaining], (@as([*]const u8, @ptrCast(&out)))[0..remaining]);
    }
}

/// Exact-length variant. Does not read past `src + len`.
pub fn subtractBytes(dst: [*]u8, src: [*]const u8, len: usize, neg_offset: isize) void {
    const V16 = @Vector(16, u8);
    var d = dst;
    var s = src;
    var remaining = len;
    while (remaining >= 16) : (remaining -= 16) {
        const a: V16 = s[0..16].*;
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: V16 = back_ptr[0..16].*;
        const out: V16 = a -% b;
        d[0..16].* = out;
        d += 16;
        s += 16;
    }
    var i: usize = 0;
    while (i < remaining) : (i += 1) {
        const back_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(neg_offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        d[i] = s[i] -% back_ptr[i];
    }
}

// ────────────────────────────────────────────────────────────
//  Cost helpers
// ────────────────────────────────────────────────────────────

/// Interpolated log2 approximation used by the offset-cost model.
/// Port of C# `OffsetEncoder.GetLog2Interpolate` (`OffsetEncoder.cs:112-132`).
/// Matches the C# lookup table EXACTLY — this is a pure bit-level
/// computation with no floating-point, so the Zig output must be
/// byte-identical to C# for cost-model parity.
pub const log2_interp_lookup = [65]u16{
    0,    183,  364,  541,  716,  889,  1059, 1227, 1392, 1555, 1716, 1874,
    2031, 2186, 2338, 2489, 2637, 2784, 2929, 3072, 3214, 3354, 3492,
    3629, 3764, 3897, 4029, 4160, 4289, 4417, 4543, 4668, 4792, 4914,
    5036, 5156, 5274, 5392, 5509, 5624, 5738, 5851, 5963, 6074, 6184,
    6293, 6401, 6508, 6614, 6719, 6823, 6926, 7029, 7130, 7231, 7330,
    7429, 7527, 7625, 7721, 7817, 7912, 8006, 8099, 8192,
};

pub fn getLog2Interpolate(x: u32) i32 {
    const idx: usize = @intCast(x >> 26);
    const lo: i32 = @intCast(log2_interp_lookup[idx]);
    const hi: i32 = @intCast(log2_interp_lookup[idx + 1]);
    const frac: u32 = (x >> 10) & 0xFFFF;
    const interp: u32 = (frac *% @as(u32, @intCast(hi - lo)) +% 0x8000) >> 16;
    return lo + @as(i32, @intCast(interp));
}

/// Converts a histogram to per-symbol approximate cost. Port of C#
/// `OffsetEncoder.ConvertHistoToCost` (`OffsetEncoder.cs:137-166`).
pub fn convertHistoToCost(
    src: *const ByteHistogram,
    dst: *[256]u32,
    extra: i32,
    max_symbol_count: u32,
) void {
    var histo_sum: u32 = 0;
    for (src.count) |c| histo_sum += c;

    const total_count: u32 = 256 + 4 * histo_sum;
    const log2_total: u5 = @intCast(std.math.log2_int(u32, total_count));
    var bits: i32 = 32 - @as(i32, log2_total);
    const base_cost: i32 =
        (bits << 13) -
        getLog2Interpolate(total_count << @intCast(bits));

    var sum_of_bits: i64 = 0;
    for (0..256) |i| {
        const count: u32 = src.count[i] * 4 + 1;
        const log2_cnt: u5 = @intCast(std.math.log2_int(u32, count));
        bits = 32 - @as(i32, log2_cnt);
        const shift_amt: u5 = @intCast(bits);
        const bp: i32 = @divTrunc(
            32 * ((bits << 13) - getLog2Interpolate(count << shift_amt) - base_cost),
            1 << 13,
        );
        sum_of_bits += @as(i64, count) * @as(i64, bp);
        dst[i] = @as(u32, @intCast(bp + extra));
    }

    // If the cost exceeds an incompressible threshold, fall back to 8 bits/sym.
    if (sum_of_bits > @as(i64, max_symbol_count) * @as(i64, total_count)) {
        for (0..256) |i| {
            dst[i] = @intCast(8 * 32 + extra);
        }
    }
}

/// Thin wrapper around `byte_histogram.getCostApproxCore` matching the C#
/// `OffsetEncoder.GetHistoCostApprox` signature. The Zig `getCostApproxCore`
/// takes a slice; here we accept a pointer + array size for ergonomic
/// parity with the C# overload used by `GetCostModularOffsets`.
pub fn getHistoCostApprox(histo: []const u32, histo_sum: i32) u32 {
    return hist_mod.getCostApproxCore(histo, histo_sum);
}

inline fn bitsUp(bits: u32) f32 {
    // Port of C# `BitsUp` (`CompressUtils`): fixed-point shift to bytes.
    // bits fixed-point is 1/8192 of a bit; divide by 8 and round up.
    return @as(f32, @floatFromInt((bits + 7) >> 3));
}

// ────────────────────────────────────────────────────────────
//  Cost estimate for a given offset-modulo encoding divisor
// ────────────────────────────────────────────────────────────

/// Port of C# `OffsetEncoder.GetCostModularOffsets` (`OffsetEncoder.cs:216-253`).
/// Computes the approximate bit cost of encoding the offset stream with
/// the given `offs_encode_type` divisor (1 = no-modulo / legacy).
pub fn getCostModularOffsets(
    offs_encode_type: u32,
    u32_offs: [*]const u32,
    offs_count: usize,
    speed_tradeoff: f32,
) f32 {
    var low_histo: [128]u32 = @splat(0);
    var high_histo: ByteHistogram = .{};

    var bits_for_data: u32 = 0;
    for (0..offs_count) |i| {
        const offset: u32 = u32_offs[i];
        const ohi: u32 = offset / offs_encode_type;
        const olo: u32 = offset % offs_encode_type;
        const shifted: u32 = ohi + 8;
        const log2_shift: u5 = @intCast(std.math.log2_int(u32, shifted));
        const extra_bit_count: u32 = log2_shift - 3;
        const high_symbol: u32 = 8 * extra_bit_count | ((shifted >> @intCast(extra_bit_count)) ^ 8);
        bits_for_data += extra_bit_count;
        high_histo.count[high_symbol] += 1;
        low_histo[@intCast(olo)] += 1;
    }

    var high_histo_sum: u32 = 0;
    for (high_histo.count) |c| high_histo_sum += c;

    var cost: f32 = bitsUp(getHistoCostApprox(&high_histo.count, @intCast(high_histo_sum))) + bitsUp(bits_for_data);

    if (offs_encode_type > 1) {
        const offs_count_f: f32 = @floatFromInt(offs_count);
        cost += (offs_count_f * cost_coeffs.offset_modular_per_item + cost_coeffs.offset_modular_base) * speed_tradeoff;
        cost += bitsUp(getHistoCostApprox(&low_histo, @intCast(offs_count)));
        cost += (cost_coeffs.single_huffman_base +
            offs_count_f * cost_coeffs.single_huffman_per_item +
            128 * cost_coeffs.single_huffman_per_symbol) * speed_tradeoff;
    }

    return cost;
}

// ────────────────────────────────────────────────────────────
//  Pick the best modulo divisor
// ────────────────────────────────────────────────────────────

/// Port of C# `OffsetEncoder.GetBestOffsetEncodingFast` (`OffsetEncoder.cs:263-302`).
/// Tracks the four most common small offsets and tries each one as the
/// modulo divisor. Returns the best-scoring divisor (1 = no modulo).
pub fn getBestOffsetEncodingFast(
    u32_offs: [*]const u32,
    offs_count: usize,
    speed_tradeoff: f32,
) u32 {
    // Initialize array with i in low byte so the sort-descending tiebreak
    // picks the smallest divisor when counts are equal — matches C#.
    var arr: [129]u32 = undefined;
    for (0..129) |i| arr[i] = @intCast(i);

    // Bump count for each offset that fits in [0..128].
    for (0..offs_count) |i| {
        if (u32_offs[i] <= 128) {
            arr[@intCast(u32_offs[i])] += 256;
        }
    }

    // Sort descending: C# `arr.Sort((a, b) => b.CompareTo(a))`.
    std.sort.pdq(u32, &arr, {}, struct {
        fn lessThan(_: void, a: u32, b: u32) bool {
            return a > b;
        }
    }.lessThan);

    var best_cost: f32 = getCostModularOffsets(1, u32_offs, offs_count, speed_tradeoff);
    var best: u32 = 1;

    for (0..4) |i| {
        const offs_encode_type: u32 = arr[i] & 0xFF;
        if (offs_encode_type > 1) {
            const cost: f32 = getCostModularOffsets(offs_encode_type, u32_offs, offs_count, speed_tradeoff);
            if (cost < best_cost) {
                best = offs_encode_type;
                best_cost = cost;
            }
        }
    }

    return best;
}

/// Port of C# `OffsetEncoder.GetBestOffsetEncodingSlow` (`OffsetEncoder.cs:307-329`).
/// Exhaustively tries every divisor in 1..128 and picks the cheapest.
pub fn getBestOffsetEncodingSlow(
    u32_offs: [*]const u32,
    offs_count: usize,
    speed_tradeoff: f32,
) u32 {
    if (offs_count < 32) return 1;

    var best: u32 = 0;
    var best_cost: f32 = std.math.inf(f32);
    var offs_encode_type: u32 = 1;
    while (offs_encode_type <= 128) : (offs_encode_type += 1) {
        const cost: f32 = getCostModularOffsets(offs_encode_type, u32_offs, offs_count, speed_tradeoff);
        if (cost < best_cost) {
            best = offs_encode_type;
            best_cost = cost;
        }
    }
    return best;
}

// ────────────────────────────────────────────────────────────
//  Split offsets into hi/lo streams given a modulo divisor
// ────────────────────────────────────────────────────────────

/// Output of `encodeNewOffsets`: separate bit-count totals for the two
/// encoding types so callers can pick the cheaper one.
pub const EncodeNewOffsetsResult = struct {
    bits_type0: i32,
    bits_type1: i32,
};

/// Constants used by the legacy (type-0) offset encoder. Pulled from
/// `streamlz_constants` so the encoder and decoder always agree —
/// previously a stale copy here used `high_offset_marker = 176` and
/// `offset_bias_constant = 8` (both wrong), which desynced the legacy
/// offset bit stream from the decoder's `readDistance`.
const high_offset_marker: u32 = lz_constants.high_offset_marker;
const high_offset_cost_adjust: u32 = high_offset_marker - 16;
const offset_bias_constant: u32 = lz_constants.offset_bias_constant;
const low_offset_encoding_limit: u32 = lz_constants.low_offset_encoding_limit;

/// Port of C# `OffsetEncoder.EncodeNewOffsets` (`OffsetEncoder.cs:339-381`).
/// Splits each 32-bit offset into `hi = off / divisor` + `lo = off % divisor`
/// and encodes the hi-part as a variable-length byte. Writes `u8_offs_hi`
/// and (when divisor > 1) `u8_offs_lo`; returns per-type bit-count totals.
pub fn encodeNewOffsets(
    u32_offs: [*]const u32,
    offs_count: usize,
    u8_offs_hi: [*]u8,
    u8_offs_lo: [*]u8,
    offs_encode_type: u32,
    u8_offs: [*]const u8,
) EncodeNewOffsetsResult {
    var bits_type0: i32 = 0;
    var bits_type1: i32 = 0;

    if (offs_encode_type == 1) {
        for (0..offs_count) |i| {
            bits_type0 += if (u8_offs[i] >= high_offset_marker)
                @as(i32, u8_offs[i]) - @as(i32, @intCast(high_offset_cost_adjust))
            else
                @as(i32, u8_offs[i] >> 4) + 5;

            const hi: u32 = u32_offs[i];
            const shifted: u32 = hi + 8;
            const extra_bit_count: u5 = @intCast(std.math.log2_int(u32, shifted) - 3);
            u8_offs_hi[i] = @intCast(8 * @as(u32, extra_bit_count) | ((shifted >> extra_bit_count) ^ 8));
            bits_type1 += @as(i32, extra_bit_count);
        }
    } else {
        for (0..offs_count) |i| {
            bits_type0 += if (u8_offs[i] >= high_offset_marker)
                @as(i32, u8_offs[i]) - @as(i32, @intCast(high_offset_cost_adjust))
            else
                @as(i32, u8_offs[i] >> 4) + 5;

            const offs: u32 = u32_offs[i];
            const lo: u32 = offs % offs_encode_type;
            const hi: u32 = offs / offs_encode_type;
            const shifted: u32 = hi + 8;
            const extra_bit_count: u5 = @intCast(std.math.log2_int(u32, shifted) - 3);
            u8_offs_hi[i] = @intCast(8 * @as(u32, extra_bit_count) | ((shifted >> extra_bit_count) ^ 8));
            u8_offs_lo[i] = @intCast(lo);
            bits_type1 += @as(i32, extra_bit_count);
        }
    }

    return .{ .bits_type0 = bits_type0, .bits_type1 = bits_type1 };
}

// ────────────────────────────────────────────────────────────
//  Dual-ended bit-stream write (forward + backward)
// ────────────────────────────────────────────────────────────

/// Port of C# `OffsetEncoder.WriteLzOffsetBits` (`OffsetEncoder.cs:402-528`).
/// Writes the variable-length offset bit fields into a dual-ended
/// bit-stream — forward writer at `dst`, backward writer at `dst_end` —
/// then moves the backward portion adjacent to the forward portion.
/// Returns the total byte count written, or `error.DestinationTooSmall`
/// on overflow.
pub fn writeLzOffsetBits(
    dst: [*]u8,
    dst_end: [*]u8,
    u8_offs: [*]const u8,
    u32_offs: [*]const u32,
    offs_count: usize,
    offs_encode_type: u32,
    u32_len: [*]const u32,
    u32_len_count: usize,
    flag_ignore_u32_length: bool,
) error{DestinationTooSmall}!usize {
    if (@intFromPtr(dst_end) - @intFromPtr(dst) <= 16) return error.DestinationTooSmall;

    var f = BitWriter64Forward.init(dst);
    var b = BitWriter64Backward.init(dst_end);

    // ── Length-count header (backward) ───────────────────────────────
    if (!flag_ignore_u32_length) {
        const cnt_plus_1: u32 = @as(u32, @intCast(u32_len_count)) + 1;
        const nb: u5 = @intCast(std.math.log2_int(u32, cnt_plus_1));
        b.write(1, @as(u5, nb) + 1);
        if (nb != 0) {
            b.write(cnt_plus_1 - (@as(u32, 1) << nb), nb);
        }
    }

    // ── Offset bits ───────────────────────────────────────────────────
    if (offs_encode_type != 0) {
        for (0..offs_count) |i| {
            if (@intFromPtr(b.position) -| @intFromPtr(f.position) <= 8) return error.DestinationTooSmall;

            const nb_raw: u8 = u8_offs[i] >> 3;
            const nb: u5 = @intCast(nb_raw);
            const mask: u32 = if (nb == 0) 0 else (@as(u32, 1) << nb) - 1;
            const bits: u32 = mask & (u32_offs[i] / offs_encode_type + 8);
            if ((i & 1) != 0) {
                b.write(bits, nb);
            } else {
                f.write(bits, nb);
            }
        }
    } else {
        for (0..offs_count) |i| {
            if (@intFromPtr(b.position) -| @intFromPtr(f.position) <= 8) return error.DestinationTooSmall;

            var nb: u5 = undefined;
            var bits: u32 = u32_offs[i];
            if (u8_offs[i] < high_offset_marker) {
                nb = @intCast((u8_offs[i] >> 4) + 5);
                bits = ((bits +% offset_bias_constant) >> 4) -% (@as(u32, 1) << nb);
            } else {
                nb = @intCast(u8_offs[i] - high_offset_cost_adjust);
                bits = bits -% (@as(u32, 1) << nb) -% low_offset_encoding_limit;
            }

            if ((i & 1) != 0) {
                b.write(bits, nb);
            } else {
                f.write(bits, nb);
            }
        }
    }

    // ── Extended match lengths ────────────────────────────────────────
    if (!flag_ignore_u32_length) {
        for (0..u32_len_count) |i| {
            if (@intFromPtr(b.position) -| @intFromPtr(f.position) <= 8) return error.DestinationTooSmall;

            const len: u32 = u32_len[i];
            const hi_plus_1: u32 = (len >> 6) + 1;
            const nb: u5 = @intCast(std.math.log2_int(u32, hi_plus_1));

            if ((i & 1) != 0) {
                b.write(1, @as(u5, nb) + 1);
                if (nb != 0) {
                    b.write(hi_plus_1 - (@as(u32, 1) << nb), nb);
                }
                b.write(len & 0x3F, 6);
            } else {
                f.write(1, @as(u5, nb) + 1);
                if (nb != 0) {
                    f.write(hi_plus_1 - (@as(u32, 1) << nb), nb);
                }
                f.write(len & 0x3F, 6);
            }
        }
    }

    f.flush();
    b.flush();

    const fp = f.getFinalPtr();
    const bp = b.getFinalPtr();

    if (@intFromPtr(bp) -| @intFromPtr(fp) <= 8) return error.DestinationTooSmall;

    // Move the backward portion forward, adjacent to the forward portion.
    const forward_bytes: usize = @intFromPtr(fp) - @intFromPtr(dst);
    const backward_bytes: usize = @intFromPtr(dst_end) - @intFromPtr(bp);
    std.mem.copyForwards(u8, dst[forward_bytes .. forward_bytes + backward_bytes], bp[0..backward_bytes]);
    return forward_bytes + backward_bytes;
}

// ────────────────────────────────────────────────────────────
//  Top-level EncodeLzOffsets
// ────────────────────────────────────────────────────────────

/// Result of `encodeLzOffsets`: encoded byte count + chosen encoding type.
pub const EncodeLzOffsetsResult = struct {
    bytes_written: usize,
    offs_encode_type: u32,
    cost: f32,
};

/// Port of C# `OffsetEncoder.EncodeLzOffsets` (`OffsetEncoder.cs:554-679`).
/// Chooses between legacy (type-0) and modulo-coded (type-1) offset
/// encoding, writes the result into `dst`, and returns the byte count +
/// chosen encoding type + cost.
///
/// Notes:
///   * When `min_match_len == 8`, the encoder takes a fast path using
///     `encodeArrayU8` on the 1-byte offset descriptor stream directly
///     without any modulo encoding. This is the path used by the High
///     codec for its most common offset-byte stream.
///   * When `use_offset_modulo_coding == true`, the encoder tries
///     modulo-1 (no modulo) and picks a best divisor via
///     `getBestOffsetEncoding{Fast,Slow}` based on `level`.
///   * The returned cost reflects both the encoded bytes AND the
///     decode-time overhead from the coefficient model.
pub fn encodeLzOffsets(
    allocator: std.mem.Allocator,
    dst: []u8,
    u8_offs: []u8,
    u32_offs: [*]const u32,
    offs_count: usize,
    opts: entropy_enc.EntropyOptions,
    speed_tradeoff: f32,
    min_match_len: u32,
    use_offset_modulo_coding: bool,
    level: u32,
    histo_out: ?*ByteHistogram,
    histo_lo_out: ?*ByteHistogram,
) (entropy_enc.EncodeError || error{NotBeneficial})!EncodeLzOffsetsResult {
    std.debug.assert(u8_offs.len >= offs_count);

    var n: usize = std.math.maxInt(usize);
    var cost: f32 = std.math.inf(f32);
    var offs_encode_type: u32 = 0;

    // Fast path for min_match_len == 8: encode the 1-byte descriptors
    // directly with no modulo coding.
    if (min_match_len == 8) {
        n = try entropy_enc.encodeArrayU8(
            allocator,
            dst,
            u8_offs[0..offs_count],
            opts,
            speed_tradeoff,
            &cost,
            level,
            histo_out,
        );
        cost += (@as(f32, @floatFromInt(offs_count)) * cost_coeffs.offset_type0_per_item + cost_coeffs.offset_type0_base) * speed_tradeoff;
    }

    if (!use_offset_modulo_coding) {
        return .{ .bytes_written = n, .offs_encode_type = offs_encode_type, .cost = cost };
    }

    // Allocate temporary scratch for the hi/lo streams + a trial output buffer.
    const temp_size: usize = offs_count * 4 + 16;
    const temp = try allocator.alloc(u8, temp_size);
    defer allocator.free(temp);

    offs_encode_type = 1;
    if (level >= 8) {
        offs_encode_type = getBestOffsetEncodingSlow(u32_offs, offs_count, speed_tradeoff);
    } else if (level >= 4) {
        offs_encode_type = getBestOffsetEncodingFast(u32_offs, offs_count, speed_tradeoff);
    }

    const u8_offs_hi: [*]u8 = temp.ptr;
    const u8_offs_lo: [*]u8 = temp.ptr + offs_count;
    const tmp_dst_start: [*]u8 = temp.ptr + offs_count * 2;
    const tmp_dst_end: [*]u8 = temp.ptr + temp_size;

    const split = encodeNewOffsets(u32_offs, offs_count, u8_offs_hi, u8_offs_lo, offs_encode_type, u8_offs.ptr);

    // Write the divisor byte, then the compressed hi stream and (if needed)
    // the compressed lo stream into the trial buffer.
    var tmp_dst: [*]u8 = tmp_dst_start;
    tmp_dst[0] = @intCast(offs_encode_type + 127);
    tmp_dst += 1;

    var histo_buf: ByteHistogram = .{};
    var cost_trial: f32 = std.math.inf(f32);
    const tmp_dst_slice_1: []u8 = tmp_dst[0 .. @intFromPtr(tmp_dst_end) - @intFromPtr(tmp_dst)];
    const n1 = try entropy_enc.encodeArrayU8CompactHeader(
        allocator,
        tmp_dst_slice_1,
        u8_offs_hi[0..offs_count],
        opts,
        speed_tradeoff,
        &cost_trial,
        level,
        if (histo_out != null) &histo_buf else null,
    );
    tmp_dst += n1;

    var cost_lo: f32 = 0;
    if (offs_encode_type > 1) {
        cost_lo = std.math.inf(f32);
        const tmp_dst_slice_2: []u8 = tmp_dst[0 .. @intFromPtr(tmp_dst_end) - @intFromPtr(tmp_dst)];
        const n2 = try entropy_enc.encodeArrayU8CompactHeader(
            allocator,
            tmp_dst_slice_2,
            u8_offs_lo[0..offs_count],
            opts,
            speed_tradeoff,
            &cost_lo,
            level,
            histo_lo_out,
        );
        tmp_dst += n2;
    }

    // Decoding-time component.
    var ultra_offset_time: f32 = undefined;
    const offs_count_f: f32 = @floatFromInt(offs_count);
    if (offs_encode_type == 1) {
        ultra_offset_time = offs_count_f * cost_coeffs.offset_type0_per_item + cost_coeffs.offset_type0_base;
    } else {
        ultra_offset_time = offs_count_f * cost_coeffs.offset_type1_per_item + cost_coeffs.offset_type1_base;
        if (offs_encode_type > 1) {
            ultra_offset_time += offs_count_f * cost_coeffs.offset_modular_per_item + cost_coeffs.offset_modular_base;
        }
    }
    cost_trial = cost_trial + 1.0 + cost_lo + ultra_offset_time * speed_tradeoff;

    // Pick the cheaper of type 0 and the trial modular encoding.
    if (bitsUp(@intCast(split.bits_type0)) + cost <= bitsUp(@intCast(split.bits_type1)) + cost_trial) {
        offs_encode_type = 0; // keep the min_match_len==8 fast-path output
    } else {
        cost = cost_trial;
        const trial_bytes: usize = @intFromPtr(tmp_dst) - @intFromPtr(tmp_dst_start);
        if (trial_bytes > dst.len) return error.DestinationTooSmall;
        @memcpy(dst[0..trial_bytes], tmp_dst_start[0..trial_bytes]);
        // Overwrite u8_offs with the new hi-stream (C# does this so callers
        // see the re-encoded descriptor bytes).
        @memcpy(u8_offs[0..offs_count], u8_offs_hi[0..offs_count]);
        if (histo_out) |h| h.* = histo_buf;
        n = trial_bytes;
    }

    return .{ .bytes_written = n, .offs_encode_type = offs_encode_type, .cost = cost };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "subtractBytes matches scalar computation" {
    var src_buf: [64]u8 = undefined;
    for (&src_buf, 0..) |*b, i| b.* = @intCast((i * 7) & 0xFF);
    var dst: [32]u8 = @splat(0);
    const src_offset: usize = 20;
    const src_cursor: [*]const u8 = src_buf[src_offset..].ptr;
    // neg_offset = -8: subtract src[i-8] from src[i]
    subtractBytes(&dst, src_cursor, 16, -8);

    var expected: [16]u8 = undefined;
    for (0..16) |i| expected[i] = src_buf[src_offset + i] -% src_buf[src_offset + i - 8];
    try testing.expectEqualSlices(u8, &expected, dst[0..16]);
}

test "subtractBytes handles non-multiple-of-16 lengths" {
    var src_buf: [64]u8 = undefined;
    for (&src_buf, 0..) |*b, i| b.* = @intCast(i);
    var dst: [16]u8 = @splat(0);
    const src_offset: usize = 16;
    const src_cursor: [*]const u8 = src_buf[src_offset..].ptr;
    subtractBytes(&dst, src_cursor, 11, -8);

    var expected: [11]u8 = undefined;
    for (0..11) |i| expected[i] = src_buf[src_offset + i] -% src_buf[src_offset + i - 8];
    try testing.expectEqualSlices(u8, &expected, dst[0..11]);
    // Bytes past the written range should still be zero.
    for (11..16) |i| try testing.expectEqual(@as(u8, 0), dst[i]);
}

test "getLog2Interpolate table endpoints" {
    // x = 0 → idx 0 → lo 0, hi 183, frac 0 → result 0.
    try testing.expectEqual(@as(i32, 0), getLog2Interpolate(0));
    // x = 0xFFFFFFFF → idx 63 → lo = 8099, hi = 8192, result close to 8192.
    try testing.expect(getLog2Interpolate(0xFFFFFFFF) >= 8099);
    try testing.expect(getLog2Interpolate(0xFFFFFFFF) <= 8192);
}

test "getLog2Interpolate sub-range interpolation" {
    // Within a single sub-range the interpolation is monotonic. Check
    // a handful of points within the first sub-range [0, 0x04000000].
    var prev: i32 = -1;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const x: u32 = i * (0x04000000 / 16);
        const v = getLog2Interpolate(x);
        try testing.expect(v >= prev);
        prev = v;
    }
}

test "getCostModularOffsets divisor 1 vs divisor 16" {
    // Build a trivial offset stream: 8 copies of offset 16. Divisor 16
    // reduces every offset's high part to 1 (no-op) and spends 0 extra
    // bits per low, so it should be cheaper than divisor 1 which needs
    // the full log2(16+8)-3 = 1 extra bit per item.
    var offs: [8]u32 = @splat(16);
    const cost_1 = getCostModularOffsets(1, &offs, 8, 0.05);
    const cost_16 = getCostModularOffsets(16, &offs, 8, 0.05);
    // Both are finite and positive.
    try testing.expect(cost_1 > 0);
    try testing.expect(cost_16 > 0);
}

test "getBestOffsetEncodingFast picks best divisor among top-4" {
    // Offsets that are all even: divisor 2 should be picked (or stay at 1
    // if the modulo overhead outweighs the savings for this tiny sample).
    var offs: [64]u32 = undefined;
    for (&offs, 0..) |*o, i| o.* = @intCast((i % 32) * 2 + 2);
    const best = getBestOffsetEncodingFast(&offs, offs.len, 0.05);
    try testing.expect(best >= 1 and best <= 128);
}

test "getBestOffsetEncodingSlow short input returns 1" {
    var offs: [16]u32 = @splat(10);
    try testing.expectEqual(@as(u32, 1), getBestOffsetEncodingSlow(&offs, offs.len, 0.05));
}

test "encodeNewOffsets splits offset=16 into hi=0, lo=16 when divisor=1" {
    var u32_offs: [1]u32 = .{16};
    var u8_offs: [1]u8 = .{0};
    var hi: [1]u8 = undefined;
    var lo: [1]u8 = undefined;
    const res = encodeNewOffsets(&u32_offs, 1, &hi, &lo, 1, &u8_offs);
    // Divisor 1: hi = (16+8)>>extra_bit_count with extra_bit_count = log2(24)-3 = 1.
    //   hi value: 8*1 | ((24>>1) ^ 8) = 8 | (12 ^ 8) = 8 | 4 = 12
    try testing.expectEqual(@as(u8, 12), hi[0]);
    try testing.expectEqual(@as(i32, 1), res.bits_type1); // 1 extra bit per offset
}

test "writeLzOffsetBits round-trips empty offset list" {
    var dst: [64]u8 = @splat(0);
    const u8_offs: [0]u8 = .{};
    const u32_offs: [0]u32 = .{};
    const u32_len: [0]u32 = .{};
    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        0,
        0,
        &u32_len,
        0,
        false,
    );
    // Empty: just the length-count header (backward), minimal bits.
    try testing.expect(n >= 1 and n <= 16);
}

test "writeLzOffsetBits legacy path: direct BitWriter roundtrip" {
    // Ground truth — bypass writeLzOffsetBits and verify the inverse
    // pair (BitWriter64Forward + BitReader.readDistance) works for the
    // legacy offset formula. Passes when the bit-level encode/decode
    // pair is correct.
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const offset: u32 = 200;
    const bsr: u32 = std.math.log2_int(u32, offset + lz_constants.offset_bias_constant);
    try testing.expect(bsr >= 9);
    const u8_desc: u8 = @intCast(((offset - 8) & 0xF) | (16 * (bsr - 9)));

    var buf: [64]u8 = @splat(0);
    var f = BitWriter64Forward.init(&buf);
    const nb: u5 = @intCast(((u8_desc >> 4) & 0xF) + 5);
    const bits: u32 = ((offset +% lz_constants.offset_bias_constant) >> 4) -% (@as(u32, 1) << nb);
    f.write(bits, nb);
    f.flush();
    const n_bytes: usize = @intFromPtr(f.getFinalPtr()) - @intFromPtr(&buf[0]);
    const stream_len: usize = @max(n_bytes, 8);

    var br = bit_reader_mod.BitReader.initForward(buf[0..stream_len]);
    br.refill();
    const decoded = br.readDistance(u8_desc);
    try testing.expectEqual(offset, decoded);
}

test "writeLzOffsetBits legacy path: full function roundtrip" {
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const offset: u32 = 200;
    const bsr: u32 = std.math.log2_int(u32, offset + lz_constants.offset_bias_constant);
    const u8_desc: u8 = @intCast(((offset - 8) & 0xF) | (16 * (bsr - 9)));

    var u8_offs: [1]u8 = .{u8_desc};
    var u32_offs: [1]u32 = .{offset};
    const u32_len: [0]u32 = .{};
    var dst: [256]u8 = @splat(0);

    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        1,
        0, // legacy path
        &u32_len,
        0,
        true, // flag_ignore_u32_length
    );
    try testing.expect(n >= 1);

    var br = bit_reader_mod.BitReader.initForward(dst[0..]);
    br.refill();
    const decoded = br.readDistance(u8_desc);
    try testing.expectEqual(offset, decoded);
}

/// Build a legacy-path `u8_offs` descriptor for a near offset.
fn buildNearU8Desc(off: u32) u8 {
    const bsr: u32 = std.math.log2_int(u32, off + lz_constants.offset_bias_constant);
    return @intCast(((off - 8) & 0xF) | (16 * (bsr - 9)));
}

test "writeLzOffsetBits legacy path: two near offsets (fwd + bwd)" {
    // Two offsets trigger the alternating forward/backward write path.
    // Index 0 goes to forward, index 1 goes to backward. flag_ignore_u32_length
    // is still true so there's no count header competing for bits_b.
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const off0: u32 = 200;
    const off1: u32 = 310;
    var u8_offs: [2]u8 = .{ buildNearU8Desc(off0), buildNearU8Desc(off1) };
    var u32_offs: [2]u32 = .{ off0, off1 };
    const u32_len: [0]u32 = .{};
    var dst: [256]u8 = @splat(0);

    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        2,
        0,
        &u32_len,
        0,
        true,
    );
    try testing.expect(n >= 1);

    // Forward reader at dst[0]; backward reader at dst[n..] (end of stream).
    var bits_a = bit_reader_mod.BitReader.initForward(dst[0..n]);
    bits_a.refill();
    var bits_b = bit_reader_mod.BitReader.initBackward(dst[0..n]);
    bits_b.refillBackwards();

    const d0 = bits_a.readDistance(u8_offs[0]);
    const d1 = bits_b.readDistanceBackward(u8_offs[1]);
    try testing.expectEqual(off0, d0);
    try testing.expectEqual(off1, d1);
}

test "writeLzOffsetBits legacy path: one offset with length-count header" {
    // Add the backward length-count header (flag_ignore_u32_length = false,
    // u32_len_count = 0). This writes a single-bit `1` marker to bits_b
    // before the offset loop runs. Decoder reads the header first.
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const offset: u32 = 200;
    const u8_desc: u8 = buildNearU8Desc(offset);

    var u8_offs: [1]u8 = .{u8_desc};
    var u32_offs: [1]u32 = .{offset};
    const u32_len: [0]u32 = .{};
    var dst: [256]u8 = @splat(0);

    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        1,
        0,
        &u32_len,
        0,
        false, // flag_ignore_u32_length = false: include count header
    );
    try testing.expect(n >= 1);

    // Simulate the decoder's reads.
    var bits_a = bit_reader_mod.BitReader.initForward(dst[0..n]);
    bits_a.refill();
    var bits_b = bit_reader_mod.BitReader.initBackward(dst[0..n]);
    bits_b.refillBackwards();

    // ── Count header (backward) ──
    // Encoder wrote `cnt_plus_1 = 1` at `nb+1 = 1` bits (just a single 1).
    // Decoder: leading zeros = 0, read 1 bit = 1, val = 1, u32_len_count = 0.
    if (bits_b.bits < 0x2000) return error.BitReaderCountHeaderTooSmall;
    const cz: u32 = @clz(bits_b.bits);
    const cz_u5: u5 = @intCast(cz);
    bits_b.bit_pos += @intCast(cz);
    bits_b.bits <<= cz_u5;
    bits_b.refillBackwards();
    const cnt_total_bits: u32 = cz + 1;
    const cnt_total_u5: u5 = @intCast(cnt_total_bits);
    const cnt_shift: u5 = @intCast(@as(u32, 32) - cnt_total_bits);
    const cnt_val = (bits_b.bits >> cnt_shift) - 1;
    bits_b.bit_pos += @intCast(cnt_total_bits);
    bits_b.bits <<= cnt_total_u5;
    bits_b.refillBackwards();
    try testing.expectEqual(@as(u32, 0), cnt_val);

    // ── Now read the single offset (forward) ──
    const d0 = bits_a.readDistance(u8_offs[0]);
    try testing.expectEqual(offset, d0);
}

test "writeLzOffsetBits legacy path: 10 near offsets + count header" {
    // Scale up to 10 offsets — alternating forward/backward — while
    // still including the backward count header. This is the shape the
    // High codec emits for a realistic sub-chunk.
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const raw_offsets: [10]u32 = .{ 200, 310, 450, 600, 800, 1100, 1500, 2000, 2800, 4000 };
    var u8_offs: [10]u8 = undefined;
    var u32_offs: [10]u32 = undefined;
    for (raw_offsets, 0..) |off, i| {
        u8_offs[i] = buildNearU8Desc(off);
        u32_offs[i] = off;
    }
    const u32_len: [0]u32 = .{};
    var dst: [512]u8 = @splat(0);

    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        raw_offsets.len,
        0,
        &u32_len,
        0,
        false, // include count header
    );
    try testing.expect(n >= 1);

    // Simulate the decoder's reads, starting with the backward count header.
    var bits_a = bit_reader_mod.BitReader.initForward(dst[0..n]);
    bits_a.refill();
    var bits_b = bit_reader_mod.BitReader.initBackward(dst[0..n]);
    bits_b.refillBackwards();

    if (bits_b.bits < 0x2000) return error.BitReaderCountHeaderTooSmall;
    const cz: u32 = @clz(bits_b.bits);
    const cz_u5: u5 = @intCast(cz);
    bits_b.bit_pos += @intCast(cz);
    bits_b.bits <<= cz_u5;
    bits_b.refillBackwards();
    const cnt_total_bits: u32 = cz + 1;
    const cnt_total_u5: u5 = @intCast(cnt_total_bits);
    const cnt_shift: u5 = @intCast(@as(u32, 32) - cnt_total_bits);
    const cnt_val = (bits_b.bits >> cnt_shift) - 1;
    bits_b.bit_pos += @intCast(cnt_total_bits);
    bits_b.bits <<= cnt_total_u5;
    bits_b.refillBackwards();
    try testing.expectEqual(@as(u32, 0), cnt_val);

    // Read offsets alternating forward / backward.
    var i: usize = 0;
    while (i < raw_offsets.len) : (i += 1) {
        if ((i & 1) == 0) {
            const d = bits_a.readDistance(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        } else {
            const d = bits_b.readDistanceBackward(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        }
    }
}

test "writeLzOffsetBits legacy path: 4 offsets + 2 u32_len overflows" {
    // Adds the match-length overflow stream — this is where the full
    // L9/L11 roundtrip desyncs in practice. The decoder reads lengths
    // via `readLengthBackward` (index 1) and `readLength` (index 0)
    // alternating, after the offset stream has been consumed.
    const bit_reader_mod = @import("../io/bit_reader.zig");

    const raw_offsets: [4]u32 = .{ 200, 310, 450, 600 };
    var u8_offs: [4]u8 = undefined;
    var u32_offs: [4]u32 = undefined;
    for (raw_offsets, 0..) |off, i| {
        u8_offs[i] = buildNearU8Desc(off);
        u32_offs[i] = off;
    }
    // Two u32 match-length overflow values. Decoder reads them as
    // `len_value = (raw - 64) + 255` pattern — the encoder writes raw -
    // the `+3` and `+255` adjustments happen downstream in `processLzRuns`.
    const u32_len: [2]u32 = .{ 100, 200 };
    var dst: [512]u8 = @splat(0);

    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        raw_offsets.len,
        0,
        &u32_len,
        u32_len.len,
        false, // include count header
    );
    try testing.expect(n >= 1);

    var bits_a = bit_reader_mod.BitReader.initForward(dst[0..n]);
    bits_a.refill();
    var bits_b = bit_reader_mod.BitReader.initBackward(dst[0..n]);
    bits_b.refillBackwards();

    // ── Count header (backward): u32_len_count = 2 → cnt_plus_1 = 3, nb = 1, marker = `1..`, payload bit = 1. ──
    if (bits_b.bits < 0x2000) return error.BitReaderCountHeaderTooSmall;
    const cz: u32 = @clz(bits_b.bits);
    const cz_u5: u5 = @intCast(cz);
    bits_b.bit_pos += @intCast(cz);
    bits_b.bits <<= cz_u5;
    bits_b.refillBackwards();
    const cnt_total_bits: u32 = cz + 1;
    const cnt_total_u5: u5 = @intCast(cnt_total_bits);
    const cnt_shift: u5 = @intCast(@as(u32, 32) - cnt_total_bits);
    const cnt_val = (bits_b.bits >> cnt_shift) - 1;
    bits_b.bit_pos += @intCast(cnt_total_bits);
    bits_b.bits <<= cnt_total_u5;
    bits_b.refillBackwards();
    try testing.expectEqual(@as(u32, u32_len.len), cnt_val);

    // ── Offsets ──
    var i: usize = 0;
    while (i < raw_offsets.len) : (i += 1) {
        if ((i & 1) == 0) {
            const d = bits_a.readDistance(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        } else {
            const d = bits_b.readDistanceBackward(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        }
    }

    // ── u32 length overflow values ──
    // Encoder writes each value with a gamma prefix for the hi bits
    // plus 6 raw low bits; the decoder's `readLength` consumes all
    // `leading_zeros + 7` value bits and returns the composite value
    // in one call. Alternation matches the offset stream: i=0 →
    // forward (readLength), i=1 → backward (readLengthBackward).
    var v0: u32 = 0;
    try testing.expect(bits_a.readLength(&v0));
    try testing.expectEqual(u32_len[0], v0);

    var v1: u32 = 0;
    try testing.expect(bits_b.readLengthBackward(&v1));
    try testing.expectEqual(u32_len[1], v1);
}

test "writeLzOffsetBits legacy path: 50 offsets + 20 u32_len overflows" {
    // Scale test — mimics the shape of a real L9/L11 compressed sub-chunk.
    // Byte counts here are comparable to what the 4 KB repeating 'A'..'Z'
    // test would emit, which is where the full-pipe roundtrip currently
    // fails. If this passes in isolation, the residual desync is NOT in
    // writeLzOffsetBits' multi-write composition — it's upstream (in
    // assembleCompressedOutput's stream ordering) or downstream (in the
    // decoder's read position after literal/cmd/offs/len streams).
    const bit_reader_mod = @import("../io/bit_reader.zig");

    var raw_offsets: [50]u32 = undefined;
    var u8_offs: [50]u8 = undefined;
    var u32_offs: [50]u32 = undefined;
    for (0..raw_offsets.len) |idx| {
        const base: u32 = 26 * (@as(u32, @intCast(idx)) + 1);
        raw_offsets[idx] = base + 174; // keeps bsr >= 9 for small idx
        u8_offs[idx] = buildNearU8Desc(raw_offsets[idx]);
        u32_offs[idx] = raw_offsets[idx];
    }
    var u32_len: [20]u32 = undefined;
    for (0..u32_len.len) |idx| u32_len[idx] = 100 + @as(u32, @intCast(idx)) * 7;

    var dst: [4096]u8 = @splat(0);
    const n = try writeLzOffsetBits(
        &dst,
        dst[dst.len..].ptr,
        &u8_offs,
        &u32_offs,
        raw_offsets.len,
        0,
        &u32_len,
        u32_len.len,
        false,
    );
    try testing.expect(n >= 1);

    var bits_a = bit_reader_mod.BitReader.initForward(dst[0..n]);
    bits_a.refill();
    var bits_b = bit_reader_mod.BitReader.initBackward(dst[0..n]);
    bits_b.refillBackwards();

    // Count header decode (matching decoder's unpackOffsets).
    if (bits_b.bits < 0x2000) return error.BitReaderCountHeaderTooSmall;
    const cz: u32 = @clz(bits_b.bits);
    const cz_u5: u5 = @intCast(cz);
    bits_b.bit_pos += @intCast(cz);
    bits_b.bits <<= cz_u5;
    bits_b.refillBackwards();
    const cnt_total_bits: u32 = cz + 1;
    const cnt_total_u5: u5 = @intCast(cnt_total_bits);
    const cnt_shift: u5 = @intCast(@as(u32, 32) - cnt_total_bits);
    const cnt_val = (bits_b.bits >> cnt_shift) - 1;
    bits_b.bit_pos += @intCast(cnt_total_bits);
    bits_b.bits <<= cnt_total_u5;
    bits_b.refillBackwards();
    try testing.expectEqual(@as(u32, u32_len.len), cnt_val);

    var i: usize = 0;
    while (i < raw_offsets.len) : (i += 1) {
        if ((i & 1) == 0) {
            const d = bits_a.readDistance(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        } else {
            const d = bits_b.readDistanceBackward(u8_offs[i]);
            try testing.expectEqual(raw_offsets[i], d);
        }
    }

    // Read lengths in the same paired order the decoder uses.
    var k: u32 = 0;
    while (k + 1 < u32_len.len) : (k += 2) {
        var v0: u32 = 0;
        try testing.expect(bits_a.readLength(&v0));
        try testing.expectEqual(u32_len[k], v0);
        var v1_tmp: u32 = 0;
        try testing.expect(bits_b.readLengthBackward(&v1_tmp));
        try testing.expectEqual(u32_len[k + 1], v1_tmp);
    }
}
