//! Fast/Turbo LZ decoder (user levels 1–5).
//!
//! Port of src/StreamLZ/Decompression/Fast/LzDecoder.cs. Two-phase design:
//!   1. `readLzTable`  — pulls the entropy-coded literal/command/offset streams
//!      out of the compressed source into the scratch buffer, producing a
//!      `FastLzTable` struct with pointers + lengths.
//!   2. `processLzRuns` — walks the command stream, resolving short tokens,
//!      medium matches, long literal runs, and long matches with 16/32-bit
//!      offsets.
//!
//! Hot-loop design:
//!   * All pointers are `[*]u8` / `[*]const u8` — no slice bounds checks.
//!   * Command stream is unrolled where possible; the ~90%-frequency short
//!     token path uses branchless recent-offset selection (XOR-mask trick).
//!   * Literal copies via `copy64` / `wildCopy16` (scalar today; Phase 7
//!     replaces these with `@Vector(16, u8)`).
//!   * Separate code paths for delta-literal (mode 0) vs raw-literal (mode 1)
//!     via a comptime parameter, so each path is branch-free internally.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const copy = @import("../io/copy_helpers.zig");
const entropy = @import("entropy_decoder.zig");

pub const DecodeError = error{
    BadMode,
    SourceTruncated,
    OutputTruncated,
    CommandStreamMismatch,
    OffsetOutOfBounds,
    MatchOutOfBounds,
    InvalidChunkHeader,
} || entropy.DecodeError;

/// Entropy-decoded LZ table for one chunk. Pointers are into the scratch buffer
/// (or, for Type 0 literal streams, directly into the compressed source).
pub const FastLzTable = struct {
    /// Command / flag byte stream.
    cmd_start: [*]const u8,
    cmd_end: [*]const u8,

    /// Variable-length extended length stream.
    length_stream: [*]const u8,

    /// Raw or delta-coded literal byte stream.
    lit_start: [*]const u8,
    lit_end: [*]const u8,

    /// 16-bit near-offset stream. 1-byte aligned because raw (non-entropy-coded)
    /// off16 data lives in-place in the compressed source at an arbitrary offset.
    off16_start: [*]align(1) const u16,
    off16_end: [*]align(1) const u16,

    /// 32-bit far-offset stream (current sub-chunk slice).
    off32_start: [*]align(1) const u32,
    off32_end: [*]align(1) const u32,

    /// Backing stores for the two 64 KB sub-chunks.
    off32_backing1: [*]align(1) const u32,
    off32_backing2: [*]align(1) const u32,
    off32_count1: u32,
    off32_count2: u32,

    /// Command stream offsets defining the two sub-chunks.
    cmd_stream2_offset: u32,
    cmd_stream2_offset_end: u32,

    /// End of compressed source. Bounds-check reference for long-literal /
    /// long-match paths (the short-token hot loop doesn't read it).
    src_end: [*]const u8,
};

/// Marker value in the off16 count field indicating entropy-coded offsets.
const entropy_coded_off16_marker: u32 = 0xFFFF;

const large_offset_threshold: u32 = constants.fast_large_offset_threshold;
const extended_length_threshold: u32 = 251;

// ────────────────────────────────────────────────────────────
//  Offset stream helpers
// ────────────────────────────────────────────────────────────

/// Decode far (32-bit) offsets into an unaligned output buffer.
pub fn decodeFarOffsetsUnaligned(
    src_in: [*]const u8,
    src_end: [*]const u8,
    out: [*]align(1) u32,
    output_size: u32,
    base_offset: i64,
) DecodeError!usize {
    var out_bytes: [*]u8 = @ptrCast(out);
    var src_cur = src_in;

    if (base_offset < @as(i64, large_offset_threshold) - 1) {
        var i: u32 = 0;
        while (i != output_size) : (i += 1) {
            if (@intFromPtr(src_end) - @intFromPtr(src_cur) < 3) return error.SourceTruncated;
            const off: u32 = @as(u32, src_cur[0]) |
                (@as(u32, src_cur[1]) << 8) |
                (@as(u32, src_cur[2]) << 16);
            src_cur += 3;
            std.mem.writeInt(u32, out_bytes[0..4], off, .little);
            out_bytes += 4;
            if (@as(i64, off) > base_offset) return error.OffsetOutOfBounds;
        }
        return @intFromPtr(src_cur) - @intFromPtr(src_in);
    }

    var i: u32 = 0;
    while (i != output_size) : (i += 1) {
        if (@intFromPtr(src_end) - @intFromPtr(src_cur) < 3) return error.SourceTruncated;
        var off: u32 = @as(u32, src_cur[0]) |
            (@as(u32, src_cur[1]) << 8) |
            (@as(u32, src_cur[2]) << 16);
        src_cur += 3;
        if (off >= large_offset_threshold) {
            if (@intFromPtr(src_cur) == @intFromPtr(src_end)) return error.SourceTruncated;
            off += @as(u32, src_cur[0]) << 22;
            src_cur += 1;
        }
        std.mem.writeInt(u32, out_bytes[0..4], off, .little);
        out_bytes += 4;
        if (@as(i64, off) > base_offset) return error.OffsetOutOfBounds;
    }
    return @intFromPtr(src_cur) - @intFromPtr(src_in);
}

/// Aligned-output variant used by the unit tests.
pub fn decodeFarOffsets(
    src_in: [*]const u8,
    src_end: [*]const u8,
    out: [*]u32,
    output_size: u32,
    base_offset: i64,
) DecodeError!usize {
    var src_cur = src_in;

    // Fast path: no offset in this chunk can possibly need a 4th byte.
    if (base_offset < @as(i64, large_offset_threshold) - 1) {
        var i: u32 = 0;
        while (i != output_size) : (i += 1) {
            if (@intFromPtr(src_end) - @intFromPtr(src_cur) < 3) return error.SourceTruncated;
            const off: u32 = @as(u32, src_cur[0]) |
                (@as(u32, src_cur[1]) << 8) |
                (@as(u32, src_cur[2]) << 16);
            src_cur += 3;
            out[i] = off;
            if (@as(i64, off) > base_offset) return error.OffsetOutOfBounds;
        }
        return @intFromPtr(src_cur) - @intFromPtr(src_in);
    }

    var i: u32 = 0;
    while (i != output_size) : (i += 1) {
        if (@intFromPtr(src_end) - @intFromPtr(src_cur) < 3) return error.SourceTruncated;
        var off: u32 = @as(u32, src_cur[0]) |
            (@as(u32, src_cur[1]) << 8) |
            (@as(u32, src_cur[2]) << 16);
        src_cur += 3;

        if (off >= large_offset_threshold) {
            if (@intFromPtr(src_cur) == @intFromPtr(src_end)) return error.SourceTruncated;
            off += @as(u32, src_cur[0]) << 22;
            src_cur += 1;
        }
        out[i] = off;
        if (@as(i64, off) > base_offset) return error.OffsetOutOfBounds;
    }
    return @intFromPtr(src_cur) - @intFromPtr(src_in);
}

/// Combines two 8-bit streams (lo + hi) into a single u16 stream.
pub fn combineOffs16(dst: [*]u16, size: usize, lo: [*]const u8, hi: [*]const u8) void {
    for (0..size) |i| {
        dst[i] = @as(u16, lo[i]) + (@as(u16, hi[i]) * 256);
    }
}

/// Same as `combineOffs16` but writes into a 1-byte-aligned u16 buffer.
pub fn combineOffs16Unaligned(dst: [*]align(1) u16, size: usize, lo: [*]const u8, hi: [*]const u8) void {
    for (0..size) |i| {
        dst[i] = @as(u16, lo[i]) + (@as(u16, hi[i]) * 256);
    }
}

// ────────────────────────────────────────────────────────────
//  ReadLzTable
// ────────────────────────────────────────────────────────────

/// Parse the compressed Fast LZ table out of `src`. Populates `lz` with
/// stream pointers into scratch memory. On return, `scratch_end_out` is the
/// new scratch watermark (caller ignores it; we use local `scratch` advance).
pub fn readLzTable(
    mode: u32,
    src_in: [*]const u8,
    src_end: [*]const u8,
    dst: *[*]u8, // in/out — may advance by 8 on offset==0
    dst_size: i64,
    base_offset: i64,
    scratch_in: [*]u8,
    scratch_end: [*]u8,
    lz: *FastLzTable,
) DecodeError!void {
    if (mode > 1) return error.BadMode;
    if (dst_size <= 0 or @intFromPtr(src_end) <= @intFromPtr(src_in)) return error.BadMode;
    if (@intFromPtr(src_end) - @intFromPtr(src_in) < 10) return error.SourceTruncated;

    var src = src_in;
    var scratch = scratch_in;

    // When offset == 0, the first 8 bytes are raw literals copied verbatim.
    if (base_offset == 0) {
        copy.copy64(dst.*, src);
        dst.* += 8;
        src += 8;
    }

    // ── Literal stream ──
    {
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_limit: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size));
        const res = try entropy.highDecodeBytes(scratch, cap_limit, src[0..src_left], false);
        src += res.bytes_consumed;
        lz.lit_start = res.out_ptr;
        lz.lit_end = res.out_ptr + res.decoded_size;
        // If the literal stream was written into scratch (not zero-copy), advance the watermark.
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) {
            scratch += res.decoded_size;
        }
    }

    // ── Command / flag stream ──
    var cmd_decoded_count: usize = 0;
    {
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_limit: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size));
        const res = try entropy.highDecodeBytes(scratch, cap_limit, src[0..src_left], false);
        src += res.bytes_consumed;
        lz.cmd_start = res.out_ptr;
        lz.cmd_end = res.out_ptr + res.decoded_size;
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) {
            scratch += res.decoded_size;
        }
        cmd_decoded_count = res.decoded_size;
    }

    lz.cmd_stream2_offset_end = @intCast(cmd_decoded_count);
    if (dst_size <= 0x10000) {
        lz.cmd_stream2_offset = @intCast(cmd_decoded_count);
    } else {
        if (@intFromPtr(src_end) - @intFromPtr(src) < 2) return error.SourceTruncated;
        lz.cmd_stream2_offset = std.mem.readInt(u16, src[0..2], .little);
        src += 2;
        if (lz.cmd_stream2_offset > lz.cmd_stream2_offset_end) return error.InvalidChunkHeader;
    }

    // ── Off16 stream ──
    if (@intFromPtr(src_end) - @intFromPtr(src) < 2) return error.SourceTruncated;
    const off16_count: u32 = std.mem.readInt(u16, src[0..2], .little);

    if (off16_count == entropy_coded_off16_marker) {
        // Entropy-coded: decode hi and lo halves separately, then combine.
        src += 2;

        const src_left_hi: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_hi: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size >> 1));
        const res_hi = try entropy.highDecodeBytes(scratch, cap_hi, src[0..src_left_hi], false);
        src += res_hi.bytes_consumed;
        const hi_ptr: [*]const u8 = res_hi.out_ptr;
        const count = res_hi.decoded_size;
        if (@intFromPtr(res_hi.out_ptr) == @intFromPtr(scratch)) {
            scratch += res_hi.decoded_size;
        }

        const src_left_lo: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_lo: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size >> 1));
        const res_lo = try entropy.highDecodeBytes(scratch, cap_lo, src[0..src_left_lo], false);
        src += res_lo.bytes_consumed;
        const lo_ptr: [*]const u8 = res_lo.out_ptr;
        if (@intFromPtr(res_lo.out_ptr) == @intFromPtr(scratch)) {
            scratch += res_lo.decoded_size;
        }

        if (res_lo.decoded_size != count) return error.CommandStreamMismatch;

        if (@intFromPtr(scratch) + count * 2 > @intFromPtr(scratch_end)) return error.SourceTruncated;
        const off16_dst: [*]align(1) u16 = @ptrCast(scratch);
        combineOffs16Unaligned(off16_dst, count, lo_ptr, hi_ptr);
        lz.off16_start = off16_dst;
        lz.off16_end = off16_dst + count;
        scratch += count * 2;
    } else {
        if (@intFromPtr(src_end) - @intFromPtr(src) < 2 + off16_count * 2) return error.SourceTruncated;
        const off16_ptr: [*]align(1) const u16 = @ptrCast(src + 2);
        lz.off16_start = off16_ptr;
        src += 2 + off16_count * 2;
        lz.off16_end = @ptrCast(src);
    }

    // ── Off32 stream sizes ──
    if (@intFromPtr(src_end) - @intFromPtr(src) < 3) return error.SourceTruncated;
    const tmp: u32 = @as(u32, src[0]) | (@as(u32, src[1]) << 8) | (@as(u32, src[2]) << 16);
    src += 3;

    if (tmp != 0) {
        var off32_size1: u32 = tmp >> 12;
        var off32_size2: u32 = tmp & 0xFFF;
        if (off32_size1 == 4095) {
            if (@intFromPtr(src_end) - @intFromPtr(src) < 2) return error.SourceTruncated;
            off32_size1 = std.mem.readInt(u16, src[0..2], .little);
            src += 2;
        }
        if (off32_size2 == 4095) {
            if (@intFromPtr(src_end) - @intFromPtr(src) < 2) return error.SourceTruncated;
            off32_size2 = std.mem.readInt(u16, src[0..2], .little);
            src += 2;
        }
        lz.off32_count1 = off32_size1;
        lz.off32_count2 = off32_size2;

        const total_bytes: usize = 4 * (off32_size1 + off32_size2) + 64;
        if (@intFromPtr(scratch) + total_bytes > @intFromPtr(scratch_end)) return error.SourceTruncated;

        const back1: [*]align(1) u32 = @ptrCast(scratch);
        lz.off32_backing1 = back1;
        scratch += off32_size1 * 4;
        // Dummy bytes for prefetcher safety.
        @memset(scratch[0..32], 0);
        scratch += 32;

        const back2: [*]align(1) u32 = @ptrCast(scratch);
        lz.off32_backing2 = back2;
        scratch += off32_size2 * 4;
        @memset(scratch[0..32], 0);
        scratch += 32;

        const n1 = try decodeFarOffsetsUnaligned(src, src_end, back1, off32_size1, base_offset);
        src += n1;

        const n2 = try decodeFarOffsetsUnaligned(src, src_end, back2, off32_size2, base_offset + 0x10000);
        src += n2;
    } else {
        if (@intFromPtr(scratch_end) - @intFromPtr(scratch) < 32) return error.SourceTruncated;
        lz.off32_count1 = 0;
        lz.off32_count2 = 0;
        const back: [*]align(1) u32 = @ptrCast(scratch);
        lz.off32_backing1 = back;
        lz.off32_backing2 = back;
        @memset(scratch[0..32], 0);
    }

    lz.length_stream = src;
    lz.src_end = src_end;
}

// ────────────────────────────────────────────────────────────
//  ProcessMode hot loop
// ────────────────────────────────────────────────────────────

const LiteralMode = enum { raw, delta };

/// Hot-loop Fast LZ token processor. `mode` is a comptime parameter so each
/// variant generates specialized code without branching on `isDelta` inside.
fn processModeImpl(
    comptime mode: LiteralMode,
    dst_in: [*]u8,
    dst_size: usize,
    dst_ptr_end: [*]u8,
    dst_start: [*]const u8,
    lz: *FastLzTable,
    saved_dist: *i32,
    start_off: usize,
) DecodeError![*]const u8 {
    _ = dst_ptr_end; // informational; bounds enforced via dst_end
    const is_delta = comptime (mode == .delta);

    var dst = dst_in;
    const dst_end = dst_in + dst_size;
    const safe_space: usize = 64; // must match streamlz_decoder.safe_space
    const dst_safe_end: [*]u8 = if (dst_size >= safe_space) dst_end - safe_space else dst_in;

    var cmd_stream = lz.cmd_start;
    const cmd_stream_end = lz.cmd_end;
    var length_stream = lz.length_stream;
    var lit_stream = lz.lit_start;
    const lit_stream_end = lz.lit_end;
    var off16_stream: [*]align(1) const u16 = lz.off16_start;
    const off16_stream_end: [*]align(1) const u16 = lz.off16_end;
    var off32_stream: [*]align(1) const u32 = lz.off32_start;
    const off32_stream_end: [*]align(1) const u32 = lz.off32_end;
    var recent_offs: i64 = saved_dist.*;
    const dst_begin = dst_in;

    dst += start_off;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        if (cmd >= 24) {
            // ── Short token (~90% of commands) ──
            if (@intFromPtr(dst) >= @intFromPtr(dst_safe_end)) {
                if (@intFromPtr(dst) >= @intFromPtr(dst_end)) return error.OutputTruncated;
            }
            const new_dist: i64 = off16_stream[0];
            const use_distance: u32 = (cmd >> 7) -% 1;
            const literal_length: usize = cmd & 7;

            if (is_delta) {
                const delta_src_addr: usize = @intFromPtr(dst) +% @as(usize, @bitCast(@as(isize, @intCast(recent_offs))));
                const delta_src: [*]const u8 = @ptrFromInt(delta_src_addr);
                copy.copy64Add(dst, lit_stream, delta_src);
            } else {
                copy.copy64(dst, lit_stream);
            }
            dst += literal_length;
            lit_stream += literal_length;

            // Branchless recent-offset swap: XOR with (use_distance & (recent_offs ^ -new_dist))
            const swap_mask: i64 = @as(i64, @bitCast(@as(u64, use_distance))) & (recent_offs ^ (-new_dist));
            recent_offs ^= swap_mask;

            // Advance off16 stream by (use_distance & 2) bytes (0 or 2).
            off16_stream = @ptrFromInt(@intFromPtr(off16_stream) + (use_distance & 2));

            // Bounds: match source must be within dst_start.
            const match_addr_usize: usize = @intFromPtr(dst) +% @as(usize, @bitCast(@as(isize, @intCast(recent_offs))));
            if (match_addr_usize < @intFromPtr(dst_start)) return error.MatchOutOfBounds;
            const match_ptr: [*]const u8 = @ptrFromInt(match_addr_usize);
            copy.copy64(dst, match_ptr);
            copy.copy64(dst + 8, match_ptr + 8);
            dst += (cmd >> 3) & 0xF;
        } else if (cmd > 2) {
            // ── Medium match: 32-bit far offset, length = cmd + 5 ──
            const length: usize = cmd + 5;
            if (@intFromPtr(off32_stream) == @intFromPtr(off32_stream_end)) return error.OutputTruncated;
            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const match_ptr: [*]const u8 = dst_begin - far;
            recent_offs = @as(i64, @intCast(@intFromPtr(match_ptr))) - @as(i64, @intCast(@intFromPtr(dst)));
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < length) return error.OutputTruncated;
            copy.copy64(dst, match_ptr);
            copy.copy64(dst + 8, match_ptr + 8);
            copy.copy64(dst + 16, match_ptr + 16);
            copy.copy64(dst + 24, match_ptr + 24);
            dst += length;
            // (Prefetch hint skipped — safe without it for correctness.)
        } else if (cmd == 0) {
            // ── Long literal run ──
            if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) == 0) return error.SourceTruncated;
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) < 3) return error.SourceTruncated;
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 64;

            if (@intFromPtr(dst_end) - @intFromPtr(dst) < length or
                @intFromPtr(lit_stream_end) - @intFromPtr(lit_stream) < length)
            {
                return error.OutputTruncated;
            }

            var remaining: isize = @intCast(length);
            if (is_delta) {
                while (remaining > 0) {
                    const off_usize: usize = @bitCast(@as(isize, @intCast(recent_offs)));
                    const delta_src: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
                    copy.copy64Add(dst, lit_stream, delta_src);
                    const delta_src2: [*]const u8 = @ptrFromInt(@intFromPtr(dst + 8) +% off_usize);
                    copy.copy64Add(dst + 8, lit_stream + 8, delta_src2);
                    dst += 16;
                    lit_stream += 16;
                    remaining -= 16;
                }
            } else {
                while (remaining > 0) {
                    copy.copy64(dst, lit_stream);
                    copy.copy64(dst + 8, lit_stream + 8);
                    dst += 16;
                    lit_stream += 16;
                    remaining -= 16;
                }
            }
            // Overshoot correction: remaining is ≤ 0, so subtract back to exact length.
            dst = @ptrFromInt(@intFromPtr(dst) +% @as(usize, @bitCast(remaining)));
            lit_stream = @ptrFromInt(@intFromPtr(lit_stream) +% @as(usize, @bitCast(remaining)));
        } else if (cmd == 1) {
            // ── Long match with 16-bit offset ──
            if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) == 0) return error.SourceTruncated;
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) < 3) return error.SourceTruncated;
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 91;

            if (@intFromPtr(off16_stream) == @intFromPtr(off16_stream_end)) return error.OutputTruncated;
            const off16: u16 = off16_stream[0];
            off16_stream += 1;
            const match_ptr: [*]const u8 = dst - off16;
            if (@intFromPtr(match_ptr) < @intFromPtr(dst_start)) return error.MatchOutOfBounds;
            recent_offs = @as(i64, @intCast(@intFromPtr(match_ptr))) - @as(i64, @intCast(@intFromPtr(dst)));
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < length) return error.OutputTruncated;

            var m = match_ptr;
            var d = dst;
            var remaining: isize = @intCast(length);
            while (remaining > 0) {
                copy.copy64(d, m);
                copy.copy64(d + 8, m + 8);
                d += 16;
                m += 16;
                remaining -= 16;
            }
            dst += length;
        } else {
            // ── cmd == 2: Long match with 32-bit offset ──
            if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) == 0) return error.SourceTruncated;
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                if (@intFromPtr(lz.src_end) - @intFromPtr(length_stream) < 3) return error.SourceTruncated;
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 29;
            if (@intFromPtr(off32_stream) == @intFromPtr(off32_stream_end)) return error.OutputTruncated;
            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const match_ptr: [*]const u8 = dst_begin - far;
            recent_offs = @as(i64, @intCast(@intFromPtr(match_ptr))) - @as(i64, @intCast(@intFromPtr(dst)));
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < length) return error.OutputTruncated;

            var m = match_ptr;
            var d = dst;
            var remaining: isize = @intCast(length);
            while (remaining > 0) {
                copy.copy64(d, m);
                copy.copy64(d + 8, m + 8);
                d += 16;
                m += 16;
                remaining -= 16;
            }
            dst += length;
        }
    }

    // ── Trailing literals (dstEnd - dst) ──
    var length: isize = @as(isize, @intCast(@intFromPtr(dst_end))) - @as(isize, @intCast(@intFromPtr(dst)));
    if (is_delta) {
        const off_usize: usize = @bitCast(@as(isize, @intCast(recent_offs)));
        while (length >= 8) {
            const delta_src: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
            copy.copy64Add(dst, lit_stream, delta_src);
            dst += 8;
            lit_stream += 8;
            length -= 8;
        }
        while (length > 0) : (length -= 1) {
            const delta_byte_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
            dst[0] = lit_stream[0] +% delta_byte_ptr[0];
            lit_stream += 1;
            dst += 1;
        }
    } else {
        while (length >= 8) {
            copy.copy64(dst, lit_stream);
            dst += 8;
            lit_stream += 8;
            length -= 8;
        }
        while (length > 0) : (length -= 1) {
            dst[0] = lit_stream[0];
            dst += 1;
            lit_stream += 1;
        }
    }

    saved_dist.* = @intCast(recent_offs);
    lz.length_stream = length_stream;
    lz.off16_start = off16_stream;
    lz.lit_start = lit_stream;
    return length_stream;
}

pub fn processLzRuns(
    mode: u32,
    src_ptr: [*]const u8,
    src_end: [*]const u8,
    dst_in: [*]u8,
    dst_size_in: usize,
    base_offset: u64,
    dst_end_total: [*]u8,
    lz: *FastLzTable,
) DecodeError!void {
    _ = src_ptr;
    if (dst_size_in == 0 or mode > 1) return error.BadMode;

    const dst_start: [*]const u8 = @ptrFromInt(@intFromPtr(dst_in) - base_offset);
    var saved_dist: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
    var src_cur: ?[*]const u8 = null;

    var dst = dst_in;
    var dst_size = dst_size_in;

    var iteration: u32 = 0;
    while (iteration != 2) : (iteration += 1) {
        var dst_size_cur: usize = dst_size;
        if (dst_size_cur > 0x10000) dst_size_cur = 0x10000;

        if (iteration == 0) {
            lz.off32_start = lz.off32_backing1;
            lz.off32_end = lz.off32_backing1 + lz.off32_count1;
            lz.cmd_end = lz.cmd_start + lz.cmd_stream2_offset;
        } else {
            lz.off32_start = lz.off32_backing2;
            lz.off32_end = lz.off32_backing2 + lz.off32_count2;
            lz.cmd_end = lz.cmd_start + lz.cmd_stream2_offset_end;
            lz.cmd_start += lz.cmd_stream2_offset;
        }

        const s_off: usize = if (base_offset == 0 and iteration == 0) 8 else 0;
        lz.src_end = src_end;

        src_cur = if (mode == 0)
            try processModeImpl(.delta, dst, dst_size_cur, dst_end_total, dst_start, lz, &saved_dist, s_off)
        else
            try processModeImpl(.raw, dst, dst_size_cur, dst_end_total, dst_start, lz, &saved_dist, s_off);

        dst += dst_size_cur;
        dst_size -= dst_size_cur;
        if (dst_size == 0) break;
    }

    if (src_cur) |sc| {
        if (@intFromPtr(sc) != @intFromPtr(src_end)) return error.CommandStreamMismatch;
    }
}

// ────────────────────────────────────────────────────────────
//  DecodeChunk — top-level Fast chunk decoder (handles 128 KB chunks)
// ────────────────────────────────────────────────────────────

pub fn decodeChunk(
    dst_in: [*]u8,
    dst_end: [*]u8,
    dst_start: [*]const u8,
    src_in: [*]const u8,
    src_end: [*]const u8,
    scratch: [*]u8,
    scratch_end: [*]u8,
) DecodeError!usize {
    var src = src_in;
    var dst = dst_in;

    while (@intFromPtr(dst_end) - @intFromPtr(dst) != 0) {
        var dst_count: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        if (dst_count > 0x20000) dst_count = 0x20000;
        if (@intFromPtr(src_end) - @intFromPtr(src) < 4) return error.SourceTruncated;

        // 3-byte big-endian sub-chunk header: [23] comp flag | [22:19] mode | [18:0] size
        const chunkhdr: u32 = (@as(u32, src[0]) << 16) | (@as(u32, src[1]) << 8) | @as(u32, src[2]);
        var src_used: usize = undefined;

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            // Stored without LZ: entropy-only decode straight into dst.
            const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
            const res = try entropy.highDecodeBytes(dst, dst_count, src[0..src_left], false);
            if (res.decoded_size != dst_count) return error.OutputTruncated;
            // If entropy handed back a zero-copy pointer, we must memcpy it ourselves.
            if (@intFromPtr(res.out_ptr) != @intFromPtr(dst)) {
                @memcpy(dst[0..dst_count], res.out_ptr[0..dst_count]);
            }
            src_used = res.bytes_consumed;
        } else {
            src += 3;
            src_used = chunkhdr & 0x7FFFF;
            const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;

            if (@intFromPtr(src_end) - @intFromPtr(src) < src_used) return error.SourceTruncated;

            if (src_used < dst_count) {
                var temp_usage: usize = 2 * dst_count + 32;
                if (temp_usage > constants.chunk_size) temp_usage = constants.chunk_size;
                // FastLzTable lives at the start of scratch; its payload lives after.
                const fast_lz_table_size: usize = @sizeOf(FastLzTable);
                const lz_ptr: *FastLzTable = @ptrCast(@alignCast(scratch));
                const inner_scratch: [*]u8 = scratch + fast_lz_table_size;
                const inner_scratch_end: [*]u8 = scratch + temp_usage;

                var dst_slot: [*]u8 = dst;
                try readLzTable(
                    mode,
                    src,
                    src + src_used,
                    &dst_slot,
                    @intCast(dst_count),
                    @intCast(@intFromPtr(dst) - @intFromPtr(dst_start)),
                    inner_scratch,
                    inner_scratch_end,
                    lz_ptr,
                );
                try processLzRuns(
                    mode,
                    src,
                    src + src_used,
                    dst,
                    dst_count,
                    @intCast(@intFromPtr(dst) - @intFromPtr(dst_start)),
                    dst_end,
                    lz_ptr,
                );
            } else if (src_used > dst_count or mode != 0) {
                return error.InvalidChunkHeader;
            } else {
                @memcpy(dst[0..dst_count], src[0..dst_count]);
            }
        }
        _ = scratch_end;

        src += src_used;
        dst += dst_count;
    }

    return @intFromPtr(src) - @intFromPtr(src_in);
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeFarOffsets small-range path reads 3 bytes per offset" {
    // 4 offsets: 0x000001, 0x000102, 0x010203, 0x001000
    const src = [_]u8{
        0x01, 0x00, 0x00,
        0x02, 0x01, 0x00,
        0x03, 0x02, 0x01,
        0x00, 0x10, 0x00,
    };
    var out: [4]u32 = undefined;
    const n = try decodeFarOffsets(src[0..].ptr, src[src.len..].ptr, &out, 4, 0x2000000);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqual(@as(u32, 0x000001), out[0]);
    try testing.expectEqual(@as(u32, 0x000102), out[1]);
    try testing.expectEqual(@as(u32, 0x010203), out[2]);
    try testing.expectEqual(@as(u32, 0x001000), out[3]);
}

test "combineOffs16 interleaves lo + hi streams" {
    const lo = [_]u8{ 0x34, 0x78 };
    const hi = [_]u8{ 0x12, 0x56 };
    var out: [2]u16 = undefined;
    combineOffs16(&out, 2, lo[0..].ptr, hi[0..].ptr);
    try testing.expectEqual(@as(u16, 0x1234), out[0]);
    try testing.expectEqual(@as(u16, 0x5678), out[1]);
}
