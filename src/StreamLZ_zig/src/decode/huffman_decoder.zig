//! 11-bit LUT, 3-stream parallel canonical Huffman decoder.
//!
//!
//!
//! Data layout (performance notes):
//!   * `HuffRevLut` is a pair of 2048-byte arrays (Bits2Len, Bits2Sym) that together
//!     occupy exactly one 4 KB page. Aligned to 64 bytes so both arrays sit on
//!     cache-line boundaries — the hot decode loop indexes both per symbol.
//!   * `HuffReader` keeps all mutable state in one struct; the fields are ordered so
//!     the three-stream pointers/bits cluster by stream, improving register allocation
//!     in the unrolled 6-symbol-per-iteration loop below.
//!
//! Hot loop design:
//!   * Uses `[*]const u8` / `[*]u8` pointers (not slices) to avoid bounds checks on
//!     the critical path. Bounds are enforced by the outer while-loop conditions.
//!   * OR-clamps each bitpos with 0x18 post-refill to guarantee ≥24 valid bits per
//!     stream before decoding two symbols from it.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const brl = @import("bit_reader_lite.zig");

// Re-export shared types so existing callers (entropy_decoder.zig) that
// reference `huffman.BitReaderState` etc. continue to compile unchanged.
pub const BitReaderState = brl.BitReaderState;
pub const BitReader2 = brl.BitReader2;
pub const HuffRange = brl.HuffRange;
pub const DecodeError = brl.DecodeError;
pub const k_rice_code_bits2_value = brl.k_rice_code_bits2_value;
pub const k_rice_code_bits2_len = brl.k_rice_code_bits2_len;
pub const bitReaderRefill = brl.bitReaderRefill;
pub const bitReaderReadBit = brl.bitReaderReadBit;
pub const bitReaderReadBitNoRefill = brl.bitReaderReadBitNoRefill;
pub const bitReaderReadBitsNoRefill = brl.bitReaderReadBitsNoRefill;
pub const bitReaderReadBitsNoRefillZero = brl.bitReaderReadBitsNoRefillZero;
pub const bitReaderReadFluff = brl.bitReaderReadFluff;
pub const decodeGolombRiceLengths = brl.decodeGolombRiceLengths;
pub const decodeGolombRiceBits = brl.decodeGolombRiceBits;
pub const huffConvertToRanges = brl.huffConvertToRanges;

// ────────────────────────────────────────────────────────────
//  Huffman-specific data structures
// ────────────────────────────────────────────────────────────

/// Reverse-order Huffman lookup table used by the hot decode loop.
/// Both arrays are indexed by the low 11 bits of the forward bit buffer.
/// Aligned to a cache-line boundary.
pub const HuffRevLut = struct {
    bits2_len: [constants.huffman_lut_size]u8 align(64) = @splat(0),
    bits2_sym: [constants.huffman_lut_size]u8 align(64) = @splat(0),
};

/// Forward-order LUT used during construction (before bit-reversal).
/// +16-byte overflow for vectorized fill safety.
pub const NewHuffLut = struct {
    bits2_len: [constants.huffman_lut_size + constants.huffman_lut_overflow]u8 align(64) = @splat(0),
    bits2_sym: [constants.huffman_lut_size + constants.huffman_lut_overflow]u8 align(64) = @splat(0),
};

/// Three-stream reader state for `highDecodeBytesCore`. Field order keeps
/// each stream's {src, bits, bitpos} triple adjacent for register pressure.
pub const HuffReader = struct {
    output: [*]u8,
    output_end: [*]u8,

    src: [*]const u8,
    src_bits: u32,
    src_bitpos: i32,

    src_mid: [*]const u8,
    src_mid_bits: u32,
    src_mid_bitpos: i32,

    src_end: [*]const u8,
    src_end_bits: u32,
    src_end_bitpos: i32,

    src_mid_org: [*]const u8,
};

// ────────────────────────────────────────────────────────────
//  Huffman-specific constants
// ────────────────────────────────────────────────────────────

/// Canonical Huffman code-length prefix sums for lengths 0..11.
pub const code_prefix_org = [_]u32{
    0x0, 0x0, 0x2, 0x6, 0xE, 0x1E, 0x3E, 0x7E, 0xFE, 0x1FE, 0x2FE, 0x3FE,
};

// ────────────────────────────────────────────────────────────
//  Code-length table reading — "new" Golomb-Rice path
// ────────────────────────────────────────────────────────────

pub fn huffReadCodeLengthsNew(
    br: *BitReaderState,
    syms: [*]u8,
    code_prefix: [*]u32,
) DecodeError!u32 {
    const forced_bits = bitReaderReadBitsNoRefill(br, 2);
    const num_symbols = bitReaderReadBitsNoRefill(br, 8) + 1;
    const fluff = bitReaderReadFluff(br, num_symbols);

    if (num_symbols + fluff > 512) return error.BadCodeLengthFormat;

    var code_len: [512 + 16]u8 = undefined;

    var br2: BitReader2 = .{
        .p = undefined,
        .p_end = br.p_end,
        .bit_pos = @bitCast(@as(i32, @truncate((br.bit_pos - 24) & 7))),
    };
    // p = bits.P - ((24 - bits.Bitpos + 7) >> 3)
    const step_back: usize = @intCast((24 - br.bit_pos + 7) >> 3);
    br2.p = br.p - step_back;

    try decodeGolombRiceLengths(&code_len, num_symbols + fluff, &br2);

    // Zero the 16-byte tail so DecodeGolombRiceBits's bak save is safe.
    @memset(code_len[num_symbols + fluff ..][0..16], 0);

    try decodeGolombRiceBits(&code_len, num_symbols, forced_bits, &br2);

    // Reset the bit reader to br2's position.
    br.bit_pos = 24;
    br.p = br2.p;
    br.bits = 0;
    bitReaderRefill(br);
    const br2_bp: u5 = @intCast(br2.bit_pos);
    br.bits <<= br2_bp;
    br.bit_pos += @intCast(br2.bit_pos);

    // Delta-decode + sign-demap: v = -(v&1) ^ (v>>1); running sum offset.
    var running_sum: i32 = 0x1e;
    for (0..num_symbols) |i| {
        const raw: i32 = code_len[i];
        const v_signed: i32 = -(raw & 1) ^ (raw >> 1);
        const cl_signed: i32 = v_signed + (running_sum >> 2) + 1;
        if (cl_signed < 1 or cl_signed > 11) return error.InvalidCodeLength;
        code_len[i] = @intCast(cl_signed);
        running_sum += v_signed;
    }

    var range_buf: [128]HuffRange = undefined;
    const ranges_count = try huffConvertToRanges(
        &range_buf,
        num_symbols,
        fluff,
        code_len[num_symbols..].ptr,
        br,
    );
    if (ranges_count == 0) return error.InvalidRanges;

    var cp: [*]const u8 = &code_len;
    for (0..ranges_count) |i| {
        var sym: u32 = range_buf[i].symbol;
        var n: u32 = range_buf[i].num;
        while (n != 0) : (n -= 1) {
            const cl = cp[0];
            cp += 1;
            syms[code_prefix[cl]] = @intCast(sym);
            code_prefix[cl] += 1;
            sym += 1;
        }
    }

    return num_symbols;
}

// ────────────────────────────────────────────────────────────
//  Code-length table reading — "old" gamma-coded path
// ────────────────────────────────────────────────────────────

pub fn huffReadCodeLengthsOld(
    br: *BitReaderState,
    syms: [*]u8,
    code_prefix: [*]u32,
) DecodeError!u32 {
    if (bitReaderReadBitNoRefill(br) != 0) {
        var sym: u32 = 0;
        var num_symbols: u32 = 0;
        var avg_bits_x4: u32 = 32;
        const forced_bits_raw = bitReaderReadBitsNoRefill(br, 2);
        const forced_bits: u5 = @intCast(forced_bits_raw);

        const shift_amount: u32 = @as(u32, 20) >> forced_bits;
        const tfvgb_shift: u5 = @intCast(31 - shift_amount);
        const thres_for_valid_gamma_bits: u32 = @as(u32, 1) << tfvgb_shift;

        var skip_zeros: bool = bitReaderReadBit(br) != 0;

        outer: while (true) {
            if (!skip_zeros) {
                if ((br.bits & 0xff000000) == 0) return error.BadCodeLengthFormat;
                const lz: u32 = @clz(br.bits);
                const n_bits: u5 = @intCast(2 * (lz + 1));
                sym += bitReaderReadBitsNoRefill(br, n_bits) - 2 + 1;
                if (sym >= 256) break :outer;
            }
            skip_zeros = false;

            bitReaderRefill(br);

            if ((br.bits & 0xff000000) == 0) return error.BadCodeLengthFormat;
            const lz_n: u32 = @clz(br.bits);
            const n_bits2: u5 = @intCast(2 * (lz_n + 1));
            var n: u32 = bitReaderReadBitsNoRefill(br, n_bits2) - 2 + 1;

            if (sym + n > 256) return error.BadCodeLengthFormat;
            bitReaderRefill(br);
            num_symbols += n;

            while (true) {
                if (br.bits < thres_for_valid_gamma_bits) return error.BadCodeLengthFormat;

                const lz3: u32 = @clz(br.bits);
                const read_bits: u5 = @intCast(lz3 + forced_bits + 1);
                const part_a = bitReaderReadBitsNoRefill(br, read_bits);
                const part_b = (lz3 - 1) << forced_bits;
                const v = part_a + part_b;
                const codelen_signed: i32 = -@as(i32, @intCast(v & 1)) ^ @as(i32, @intCast(v >> 1));
                const codelen = codelen_signed + @as(i32, @intCast((avg_bits_x4 + 2) >> 2));
                if (codelen < 1 or codelen > 11) return error.InvalidCodeLength;
                const cl: u32 = @intCast(codelen);
                avg_bits_x4 = cl + ((3 * avg_bits_x4 + 2) >> 2);
                bitReaderRefill(br);
                syms[code_prefix[cl]] = @intCast(sym);
                code_prefix[cl] += 1;
                sym += 1;
                n -= 1;
                if (n == 0) break;
            }
            if (sym == 256) break :outer;
        }

        if (sym != 256 or num_symbols < 2) return error.BadCodeLengthFormat;
        return num_symbols;
    }

    // Sparse encoding
    const num_symbols = bitReaderReadBitsNoRefill(br, 8);
    if (num_symbols == 0) return error.BadCodeLengthFormat;
    if (num_symbols == 1) {
        syms[0] = @intCast(bitReaderReadBitsNoRefill(br, 8));
    } else {
        const codelen_bits = bitReaderReadBitsNoRefill(br, 3);
        if (codelen_bits > 4) return error.BadCodeLengthFormat;
        const cl_bits_u6: u6 = @intCast(codelen_bits);
        var i: u32 = 0;
        while (i < num_symbols) : (i += 1) {
            bitReaderRefill(br);
            const s = bitReaderReadBitsNoRefill(br, 8);
            const cl_raw = bitReaderReadBitsNoRefillZero(br, cl_bits_u6) + 1;
            if (cl_raw > 11) return error.InvalidCodeLength;
            syms[code_prefix[cl_raw]] = @intCast(s);
            code_prefix[cl_raw] += 1;
        }
    }
    return num_symbols;
}

// ────────────────────────────────────────────────────────────
//  LUT construction
// ────────────────────────────────────────────────────────────

pub fn huffMakeLut(
    prefix_org: [*]const u32,
    prefix_cur: [*]const u32,
    hufflut: *NewHuffLut,
    syms: [*]const u8,
) bool {
    var cur_slot: u32 = 0;
    var i: u32 = 1;
    while (i < 11) : (i += 1) {
        const start = prefix_org[i];
        const count = prefix_cur[i] - start;
        if (count != 0) {
            const step_u5: u5 = @intCast(11 - i);
            const step_size: u32 = @as(u32, 1) << step_u5;
            const num_to_set = count << step_u5;
            if (cur_slot + num_to_set > constants.huffman_lut_size) return false;

            // Fill Bits2Len[cur_slot..cur_slot+num_to_set] with byte `i`.
            @memset(hufflut.bits2_len[cur_slot..][0..num_to_set], @intCast(i));

            // Fill Bits2Sym with the mapped symbol, block-by-block.
            var j: u32 = 0;
            var p: usize = cur_slot;
            while (j != count) : (j += 1) {
                @memset(hufflut.bits2_sym[p..][0..step_size], syms[start + j]);
                p += step_size;
            }

            cur_slot += num_to_set;
        }
    }

    const count11 = prefix_cur[11] - prefix_org[11];
    if (count11 != 0) {
        if (cur_slot + count11 > constants.huffman_lut_size) return false;
        @memset(hufflut.bits2_len[cur_slot..][0..count11], 11);
        const src_ptr = syms + prefix_org[11];
        @memcpy(hufflut.bits2_sym[cur_slot..][0..count11], src_ptr[0..count11]);
        cur_slot += count11;
    }

    return cur_slot == constants.huffman_lut_size;
}

// ────────────────────────────────────────────────────────────
//  11-bit reverse-bit permutation
// ────────────────────────────────────────────────────────────

/// Scalar 11-bit bit-reversal permutation of a 2048-byte array.
/// Runs once per decode block, not in the hot loop. Vectorizing this is a
/// Phase-7 job (`@Vector(16, u8)` + shuffle).
pub fn reverseBitsArray2048(in: [*]const u8, out: [*]u8) void {
    for (0..constants.huffman_lut_size) |i| {
        // Reverse the 11 bits of `i`.
        var rev: usize = 0;
        var val: usize = i;
        for (0..11) |_| {
            rev = (rev << 1) | (val & 1);
            val >>= 1;
        }
        out[rev] = in[i];
    }
}

// ────────────────────────────────────────────────────────────
//  3-stream parallel decode loop (the hot path)
// ────────────────────────────────────────────────────────────

pub fn highDecodeBytesCore(hr: *HuffReader, lut: *const HuffRevLut) DecodeError!void {
    var src = hr.src;
    var src_bits = hr.src_bits;
    var src_bitpos = hr.src_bitpos;

    var src_mid = hr.src_mid;
    var src_mid_bits = hr.src_mid_bits;
    var src_mid_bitpos = hr.src_mid_bitpos;

    var src_end = hr.src_end;
    var src_end_bits = hr.src_end_bits;
    var src_end_bitpos = hr.src_end_bitpos;

    var dst = hr.output;
    var dst_end = hr.output_end;

    if (@intFromPtr(src) > @intFromPtr(src_mid)) return error.StreamMismatch;

    const lut_mask: u32 = constants.huffman_lut_mask;
    const clamp: u32 = constants.huffman_bitpos_clamp_mask;

    if (@intFromPtr(hr.src_end) - @intFromPtr(src_mid) >= 4 and
        @intFromPtr(dst_end) - @intFromPtr(dst) >= 6)
    {
        dst_end -= 5;
        src_end -= 4;

        while (@intFromPtr(dst) < @intFromPtr(dst_end) and
            @intFromPtr(src) <= @intFromPtr(src_mid) and
            @intFromPtr(src_mid) <= @intFromPtr(src_end))
        {
            // Forward stream refill — read 4 bytes, shift into the bit buffer.
            const src_word: u32 = std.mem.readInt(u32, src[0..4], .little);
            src_bits |= src_word << @intCast(src_bitpos);
            src += @intCast((31 - src_bitpos) >> 3);

            // Backward stream refill — big-endian read from src_end.
            const src_end_word_le: u32 = std.mem.readInt(u32, src_end[0..4], .little);
            const src_end_word_be: u32 = @byteSwap(src_end_word_le);
            src_end_bits |= src_end_word_be << @intCast(src_end_bitpos);
            src_end -= @as(usize, @intCast((31 - src_end_bitpos) >> 3));

            // Middle stream refill.
            const src_mid_word: u32 = std.mem.readInt(u32, src_mid[0..4], .little);
            src_mid_bits |= src_mid_word << @intCast(src_mid_bitpos);
            src_mid += @intCast((31 - src_mid_bitpos) >> 3);

            // OR-clamp bit positions to ≥24 valid bits per stream.
            src_bitpos |= @intCast(clamp);
            src_end_bitpos |= @intCast(clamp);
            src_mid_bitpos |= @intCast(clamp);

            // 6 symbols per iteration — 2 from each stream.
            var lut_index: u32 = src_bits & lut_mask;
            var cbl: u32 = lut.bits2_len[lut_index];
            src_bits >>= @intCast(cbl);
            src_bitpos -= @intCast(cbl);
            dst[0] = lut.bits2_sym[lut_index];

            lut_index = src_end_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            src_end_bits >>= @intCast(cbl);
            src_end_bitpos -= @intCast(cbl);
            dst[1] = lut.bits2_sym[lut_index];

            lut_index = src_mid_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            src_mid_bits >>= @intCast(cbl);
            src_mid_bitpos -= @intCast(cbl);
            dst[2] = lut.bits2_sym[lut_index];

            lut_index = src_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            src_bits >>= @intCast(cbl);
            src_bitpos -= @intCast(cbl);
            dst[3] = lut.bits2_sym[lut_index];

            lut_index = src_end_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            src_end_bits >>= @intCast(cbl);
            src_end_bitpos -= @intCast(cbl);
            dst[4] = lut.bits2_sym[lut_index];

            lut_index = src_mid_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            src_mid_bits >>= @intCast(cbl);
            src_mid_bitpos -= @intCast(cbl);
            dst[5] = lut.bits2_sym[lut_index];

            dst += 6;
        }

        dst_end += 5;
        src -= @as(usize, @intCast(@as(u32, @bitCast(src_bitpos)) >> 3));
        src_bitpos &= 7;
        src_end += @as(usize, @intCast(4 + (@as(u32, @bitCast(src_end_bitpos)) >> 3)));
        src_end_bitpos &= 7;
        src_mid -= @as(usize, @intCast(@as(u32, @bitCast(src_mid_bitpos)) >> 3));
        src_mid_bitpos &= 7;
    }

    // Tail loop — one symbol per stream per iteration.
    while (true) {
        if (@intFromPtr(dst) >= @intFromPtr(dst_end)) break;

        // Stream 1 (forward).
        if (@intFromPtr(src_mid) - @intFromPtr(src) <= 1) {
            if (@intFromPtr(src_mid) - @intFromPtr(src) == 1) {
                src_bits |= @as(u32, src[0]) << @intCast(src_bitpos);
            }
        } else {
            const v: u32 = std.mem.readInt(u16, src[0..2], .little);
            src_bits |= v << @intCast(src_bitpos);
        }

        var lut_index: u32 = src_bits & lut_mask;
        var cbl: u32 = lut.bits2_len[lut_index];
        src_bitpos -= @intCast(cbl);
        src_bits >>= @intCast(cbl);
        dst[0] = lut.bits2_sym[lut_index];
        dst += 1;
        src += @as(usize, @intCast((7 - src_bitpos) >> 3));
        src_bitpos &= 7;

        if (@intFromPtr(dst) < @intFromPtr(dst_end)) {
            // Stream 2 (backward) + stream 3 (middle) refill.
            if (@intFromPtr(src_end) - @intFromPtr(src_mid) <= 1) {
                if (@intFromPtr(src_end) - @intFromPtr(src_mid) == 1) {
                    const by: u32 = src_mid[0];
                    src_end_bits |= by << @intCast(src_end_bitpos);
                    src_mid_bits |= by << @intCast(src_mid_bitpos);
                }
            } else {
                const back_ptr = src_end - 2;
                const v: u32 = std.mem.readInt(u16, back_ptr[0..2], .little);
                const v_swap: u32 = ((v >> 8) | (v << 8)) & 0xFFFF;
                src_end_bits |= v_swap << @intCast(src_end_bitpos);
                const fwd: u32 = std.mem.readInt(u16, src_mid[0..2], .little);
                src_mid_bits |= fwd << @intCast(src_mid_bitpos);
            }

            // Stream 2: backward symbol.
            lut_index = src_end_bits & lut_mask;
            cbl = lut.bits2_len[lut_index];
            dst[0] = lut.bits2_sym[lut_index];
            dst += 1;
            src_end_bitpos -= @intCast(cbl);
            src_end_bits >>= @intCast(cbl);
            src_end -= @as(usize, @intCast((7 - src_end_bitpos) >> 3));
            src_end_bitpos &= 7;

            if (@intFromPtr(dst) < @intFromPtr(dst_end)) {
                lut_index = src_mid_bits & lut_mask;
                cbl = lut.bits2_len[lut_index];
                dst[0] = lut.bits2_sym[lut_index];
                dst += 1;
                src_mid_bitpos -= @intCast(cbl);
                src_mid_bits >>= @intCast(cbl);
                src_mid += @as(usize, @intCast((7 - src_mid_bitpos) >> 3));
                src_mid_bitpos &= 7;
            }
        }

        if (@intFromPtr(src) > @intFromPtr(src_mid) or
            @intFromPtr(src_mid) > @intFromPtr(src_end))
        {
            return error.StreamMismatch;
        }
    }

    if (@intFromPtr(src) != @intFromPtr(hr.src_mid_org) or
        @intFromPtr(src_end) != @intFromPtr(src_mid))
    {
        return error.StreamMismatch;
    }
}

// ────────────────────────────────────────────────────────────
//  Top-level: Huffman type 1 / type 2 block decoder
// ────────────────────────────────────────────────────────────

/// Decodes a Huffman-coded byte block (type 1 = 2-way split, type 2 = 4-way split).
/// Writes exactly `output_size` bytes starting at `output`. Returns the number of
/// source bytes consumed (== `src.len`).
pub fn highDecodeBytesType12(
    src_in: []const u8,
    output_in: [*]u8,
    output_size: usize,
    type_: u32,
) DecodeError!usize {
    if (src_in.len == 0 or output_size == 0) return error.SourceTruncated;

    const src_start: [*]const u8 = src_in.ptr;
    const src_end: [*]const u8 = src_in.ptr + src_in.len;

    var br: BitReaderState = .{
        .p = src_start,
        .p_end = src_end,
        .bits = 0,
        .bit_pos = 24,
    };
    bitReaderRefill(&br);

    var code_prefix_org_buf: [12]u32 = code_prefix_org;
    var code_prefix_buf: [12]u32 = code_prefix_org;

    var syms_buf: [1280]u8 = undefined;
    const syms: [*]u8 = &syms_buf;

    const num_syms: u32 = blk: {
        if (bitReaderReadBitNoRefill(&br) == 0) {
            break :blk try huffReadCodeLengthsOld(&br, syms, &code_prefix_buf);
        } else if (bitReaderReadBitNoRefill(&br) == 0) {
            break :blk try huffReadCodeLengthsNew(&br, syms, &code_prefix_buf);
        } else {
            return error.BadCodeLengthFormat;
        }
    };

    if (num_syms < 1) return error.BadCodeLengthFormat;

    // Advance src past the code-length table.
    const consumed_offset: usize = @intCast(@divTrunc(24 - br.bit_pos, 8));
    var src_after_table: [*]const u8 = br.p - consumed_offset;

    // Trivial case: single symbol → memset the whole output.
    if (num_syms == 1) {
        @memset(output_in[0..output_size], syms_buf[0]);
        return src_in.len;
    }

    var huff_lut: NewHuffLut = .{};
    if (!huffMakeLut(&code_prefix_org_buf, &code_prefix_buf, &huff_lut, syms)) {
        return error.LutConstructionFailed;
    }

    var rev_lut: HuffRevLut = .{};
    reverseBitsArray2048(&huff_lut.bits2_len, &rev_lut.bits2_len);
    reverseBitsArray2048(&huff_lut.bits2_sym, &rev_lut.bits2_sym);

    if (type_ == 1) {
        if (@intFromPtr(src_after_table) + 3 > @intFromPtr(src_end)) return error.SourceTruncated;
        const split_mid: usize = @intCast(std.mem.readInt(u16, src_after_table[0..2], .little));
        src_after_table += 2;
        if (split_mid > @intFromPtr(src_end) - @intFromPtr(src_after_table)) return error.SourceTruncated;

        var hr: HuffReader = .{
            .output = output_in,
            .output_end = output_in + output_size,
            .src = src_after_table,
            .src_end = src_end,
            .src_mid_org = src_after_table + split_mid,
            .src_mid = src_after_table + split_mid,
            .src_bits = 0,
            .src_bitpos = 0,
            .src_mid_bits = 0,
            .src_mid_bitpos = 0,
            .src_end_bits = 0,
            .src_end_bitpos = 0,
        };
        try highDecodeBytesCore(&hr, &rev_lut);
    } else {
        // type 2: 4-way split
        if (@intFromPtr(src_after_table) + 6 > @intFromPtr(src_end)) return error.SourceTruncated;
        const half_output: usize = (output_size + 1) >> 1;
        const tri: u32 = std.mem.readInt(u32, src_after_table[0..4], .little) & 0xFFFFFF;
        src_after_table += 3;
        const split_mid_outer: usize = @intCast(tri);
        if (split_mid_outer > @intFromPtr(src_end) - @intFromPtr(src_after_table)) return error.SourceTruncated;

        const src_mid_outer: [*]const u8 = src_after_table + split_mid_outer;
        const split_left: usize = @intCast(std.mem.readInt(u16, src_after_table[0..2], .little));
        src_after_table += 2;

        if (@intFromPtr(src_mid_outer) - @intFromPtr(src_after_table) < split_left + 2 or
            @intFromPtr(src_end) - @intFromPtr(src_mid_outer) < 3)
        {
            return error.SourceTruncated;
        }

        const split_right: usize = @intCast(std.mem.readInt(u16, src_mid_outer[0..2], .little));
        if (@intFromPtr(src_end) - @intFromPtr(src_mid_outer + 2) < split_right + 2) return error.SourceTruncated;

        // First half
        var hr_first: HuffReader = .{
            .output = output_in,
            .output_end = output_in + half_output,
            .src = src_after_table,
            .src_end = src_mid_outer,
            .src_mid_org = src_after_table + split_left,
            .src_mid = src_after_table + split_left,
            .src_bits = 0,
            .src_bitpos = 0,
            .src_mid_bits = 0,
            .src_mid_bitpos = 0,
            .src_end_bits = 0,
            .src_end_bitpos = 0,
        };
        try highDecodeBytesCore(&hr_first, &rev_lut);

        // Second half
        const second_src: [*]const u8 = src_mid_outer + 2;
        var hr_second: HuffReader = .{
            .output = output_in + half_output,
            .output_end = output_in + output_size,
            .src = second_src,
            .src_end = src_end,
            .src_mid_org = second_src + split_right,
            .src_mid = second_src + split_right,
            .src_bits = 0,
            .src_bitpos = 0,
            .src_mid_bits = 0,
            .src_mid_bitpos = 0,
            .src_end_bits = 0,
            .src_end_bitpos = 0,
        };
        try highDecodeBytesCore(&hr_second, &rev_lut);
    }

    return src_in.len;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "code_prefix_org values match reference" {
    try testing.expectEqual(@as(u32, 0x0), code_prefix_org[0]);
    try testing.expectEqual(@as(u32, 0x0), code_prefix_org[1]);
    try testing.expectEqual(@as(u32, 0x2), code_prefix_org[2]);
    try testing.expectEqual(@as(u32, 0x3FE), code_prefix_org[11]);
}

test "reverseBitsArray2048 permutes correctly" {
    var in_buf: [constants.huffman_lut_size]u8 align(64) = undefined;
    var out_buf: [constants.huffman_lut_size]u8 align(64) = @splat(0);
    for (&in_buf, 0..) |*b, i| b.* = @truncate(i);

    reverseBitsArray2048(&in_buf, &out_buf);

    // out[rev(i)] == in[i] == (i & 0xFF). Verify a few known reversals.
    // bit-reverse of 0 in 11 bits = 0
    try testing.expectEqual(@as(u8, 0), out_buf[0]);
    // bit-reverse of 1 (0b00000000001) = 0b10000000000 = 1024
    try testing.expectEqual(@as(u8, 1), out_buf[1024]);
    // bit-reverse of 0b00000000010 = 0b01000000000 = 512
    try testing.expectEqual(@as(u8, 2), out_buf[512]);
    // bit-reverse of 0b11111111111 = 0b11111111111 = 2047
    try testing.expectEqual(@as(u8, 2047 & 0xFF), out_buf[2047]);
}

test "HuffRevLut is 64-byte aligned and 4096 bytes" {
    try testing.expectEqual(@as(usize, 4096), @sizeOf(HuffRevLut));
    try testing.expectEqual(@as(usize, 64), @alignOf(HuffRevLut));
}
