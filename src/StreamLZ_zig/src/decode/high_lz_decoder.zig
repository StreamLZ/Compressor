//! High codec LZ decoder — types, ReadLzTable, UnpackOffsets, DecodeChunk.
//!
//! ProcessLzRuns_Type0 / Type1 live in `high_lz_token_executor.zig`.
//!
//! Two-phase decode per sub-chunk:
//!   1. `readLzTable` — decodes the 4 sub-streams (lit, cmd, packed offs,
//!      packed len) via the entropy dispatcher, then unpacks offsets and
//!      lengths into 32-bit int arrays using a bidirectional bit reader.
//!   2. `processLzRuns` — walks the command stream, emitting literal runs
//!      and match copies into the output buffer.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const copy = @import("../io/copy_helpers.zig");
const BitReader = @import("../io/BitReader.zig").BitReader;
const entropy = @import("entropy_decoder.zig");
const runs = @import("high_lz_token_executor.zig");

pub const DecodeError = error{
    BadMode,
    SourceTruncated,
    OutputTruncated,
    InvalidChunkHeader,
    ExcessFlagNotSupported,
    OffsetOutOfRange,
    StreamMismatch,
    LenStreamOverflow,
} || entropy.DecodeError;

/// Populated by `readLzTable`, consumed by `processLzRuns`.
pub const HighLzTable = struct {
    cmd_stream: [*]const u8,
    cmd_stream_size: u32,

    offs_stream: [*]align(1) const i32,
    offs_stream_size: u32,

    lit_stream: [*]const u8,
    lit_stream_size: u32,

    len_stream: [*]align(1) const i32,
    len_stream_size: u32,
};

// ────────────────────────────────────────────────────────────
//  CombineScaledOffsetArrays helper
// ────────────────────────────────────────────────────────────

fn combineScaledOffsetArrays(offs: [*]align(1) i32, size: usize, scale: i32, low_bits: [*]const u8) void {
    for (0..size) |i| {
        const cur: i32 = offs[i];
        offs[i] = scale * cur - @as(i32, low_bits[i]);
    }
}

// ────────────────────────────────────────────────────────────
//  UnpackOffsets — bidirectional bit-stream offset/length unpacking
// ────────────────────────────────────────────────────────────

pub fn unpackOffsets(
    src_in: [*]const u8,
    src_end: [*]const u8,
    packed_offs_stream: [*]const u8,
    packed_offs_stream_extra: ?[*]const u8,
    packed_offs_stream_size: u32,
    multi_dist_scale: i32,
    packed_litlen_stream: [*]const u8,
    packed_litlen_stream_size: u32,
    offs_stream: [*]align(1) i32,
    len_stream: [*]align(1) i32,
    excess_flag: bool,
    excess_bytes: u32,
) DecodeError!void {
    _ = excess_bytes;
    const src_len: usize = @intFromPtr(src_end) - @intFromPtr(src_in);
    if (src_len == 0) return error.SourceTruncated;

    const src_slice = src_in[0..src_len];
    var bits_a = BitReader.initForward(src_slice);
    bits_a.refill();
    var bits_b = BitReader.initBackward(src_slice);
    bits_b.refillBackwards();

    var u32_len_stream_size: u32 = 0;
    if (!excess_flag) {
        if (bits_b.bits < 0x2000) return error.StreamMismatch;
        const n: u32 = @clz(bits_b.bits);
        const n_u5: u5 = @intCast(n);
        bits_b.bit_pos += @intCast(n);
        bits_b.bits <<= n_u5;
        bits_b.refillBackwards();
        const n1: u32 = n + 1;
        const n1_u5: u5 = @intCast(n1);
        const shift: u5 = @intCast(32 - n1);
        const val = (bits_b.bits >> shift) - 1;
        u32_len_stream_size = val;
        bits_b.bit_pos += @intCast(n1);
        bits_b.bits <<= n1_u5;
        bits_b.refillBackwards();
    }

    // ── Offsets ──
    if (multi_dist_scale == 0) {
        var p = packed_offs_stream;
        const p_end = packed_offs_stream + packed_offs_stream_size;
        var out_idx: usize = 0;
        while (@intFromPtr(p) != @intFromPtr(p_end)) {
            const d_a: u32 = bits_a.readDistance(p[0]);
            p += 1;
            offs_stream[out_idx] = -@as(i32, @intCast(d_a));
            out_idx += 1;
            if (@intFromPtr(p) == @intFromPtr(p_end)) break;
            const d_b: u32 = bits_b.readDistanceBackward(p[0]);
            p += 1;
            offs_stream[out_idx] = -@as(i32, @intCast(d_b));
            out_idx += 1;
        }
    } else {
        var p = packed_offs_stream;
        const p_end = packed_offs_stream + packed_offs_stream_size;
        var out_idx: usize = 0;
        while (@intFromPtr(p) != @intFromPtr(p_end)) {
            // Forward side.
            const cmd_a: u32 = p[0];
            p += 1;
            const nb_a: u32 = cmd_a >> 3;
            if (nb_a > 26) return error.OffsetOutOfRange;
            const nb_a_u5: u5 = @intCast(nb_a);
            var offs_a: u32 = (8 + (cmd_a & 7)) << nb_a_u5;
            if (nb_a > 0) offs_a |= bits_a.readMoreThan24Bits(@intCast(nb_a));
            offs_stream[out_idx] = 8 - @as(i32, @intCast(offs_a));
            out_idx += 1;

            if (@intFromPtr(p) == @intFromPtr(p_end)) break;

            const cmd_b: u32 = p[0];
            p += 1;
            const nb_b: u32 = cmd_b >> 3;
            if (nb_b > 26) return error.OffsetOutOfRange;
            const nb_b_u5: u5 = @intCast(nb_b);
            var offs_b: u32 = (8 + (cmd_b & 7)) << nb_b_u5;
            if (nb_b > 0) offs_b |= bits_b.readMoreThan24BitsBackward(@intCast(nb_b));
            offs_stream[out_idx] = 8 - @as(i32, @intCast(offs_b));
            out_idx += 1;
        }
        if (multi_dist_scale != 1) {
            combineScaledOffsetArrays(offs_stream, packed_offs_stream_size, multi_dist_scale, packed_offs_stream_extra.?);
        }
    }

    // ── u32 length-stream (alternating forward/backward) ──
    const max_len_entries: usize = 512;
    if (u32_len_stream_size > max_len_entries) return error.LenStreamOverflow;

    var u32_len_buf: [max_len_entries]u32 = undefined;
    var i: u32 = 0;
    while (i + 1 < u32_len_stream_size) : (i += 2) {
        var v: u32 = 0;
        if (!bits_a.readLength(&v)) return error.StreamMismatch;
        u32_len_buf[i] = v;
        var v2: u32 = 0;
        if (!bits_b.readLengthBackward(&v2)) return error.StreamMismatch;
        u32_len_buf[i + 1] = v2;
    }
    if (i < u32_len_stream_size) {
        var v: u32 = 0;
        if (!bits_a.readLength(&v)) return error.StreamMismatch;
        u32_len_buf[i] = v;
    }

    // Rewind readers to the next unread byte before comparing pointers.
    const a_back: usize = @intCast(@divTrunc(24 - bits_a.bit_pos, 8));
    const b_fwd: usize = @intCast(@divTrunc(24 - bits_b.bit_pos, 8));
    bits_a.p -= a_back;
    bits_b.p += b_fwd;
    if (@intFromPtr(bits_a.p) != @intFromPtr(bits_b.p)) return error.StreamMismatch;

    // ── Unpack litlen stream ──
    var u32_idx: usize = 0;
    for (0..packed_litlen_stream_size) |k| {
        var v: u32 = packed_litlen_stream[k];
        if (v == 255) {
            if (u32_idx >= u32_len_stream_size) return error.LenStreamOverflow;
            v = u32_len_buf[u32_idx] + 255;
            u32_idx += 1;
        }
        len_stream[k] = @intCast(v + 3);
    }
    if (u32_idx != u32_len_stream_size) return error.StreamMismatch;
}

// ────────────────────────────────────────────────────────────
//  ReadLzTable
// ────────────────────────────────────────────────────────────

/// Helper: align a scratch pointer up to `alignment`.
inline fn alignUp(p: [*]u8, alignment: usize) [*]u8 {
    const addr = @intFromPtr(p);
    const aligned = (addr + (alignment - 1)) & ~@as(usize, alignment - 1);
    return @ptrFromInt(aligned);
}

pub fn readLzTable(
    mode: u32,
    src_in: [*]const u8,
    src_end: [*]const u8,
    dst_in: [*]u8,
    dst_size_in: i64,
    base_offset: i64,
    scratch_in: [*]u8,
    scratch_end: [*]u8,
    lz: *HighLzTable,
) DecodeError!void {
    if (mode > 1) return error.BadMode;
    if (dst_size_in <= 0 or @intFromPtr(src_end) <= @intFromPtr(src_in)) return error.BadMode;
    if (@intFromPtr(src_end) - @intFromPtr(src_in) < 13) return error.SourceTruncated;

    var src = src_in;
    var dst = dst_in;
    const dst_size = dst_size_in;
    var scratch = scratch_in;

    if (base_offset == 0) {
        copy.copy64(dst, src);
        dst += 8;
        src += 8;
    }

    if ((src[0] & 0x80) != 0) {
        const flag = src[0];
        if ((flag & 0xc0) != 0x80) return error.InvalidChunkHeader;
        return error.ExcessFlagNotSupported;
    }

    // Literal stream — bounded by dstSize.
    {
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size));
        const res = try entropy.highDecodeBytes(scratch, cap, src[0..src_left], false, scratch, scratch_end);
        src += res.bytes_consumed;
        lz.lit_stream = res.out_ptr;
        lz.lit_stream_size = @intCast(res.decoded_size);
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) scratch += res.decoded_size;
    }

    // Command stream.
    {
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size));
        const res = try entropy.highDecodeBytes(scratch, cap, src[0..src_left], false, scratch, scratch_end);
        src += res.bytes_consumed;
        lz.cmd_stream = res.out_ptr;
        lz.cmd_stream_size = @intCast(res.decoded_size);
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) scratch += res.decoded_size;
    }

    if (@intFromPtr(src_end) - @intFromPtr(src) < 3) return error.SourceTruncated;

    var offs_scaling: i32 = 0;
    var packed_offs_stream_extra: ?[*]const u8 = null;
    var packed_offs_stream: [*]const u8 = undefined;
    var packed_offs_stream_size: u32 = 0;

    if ((src[0] & 0x80) != 0) {
        offs_scaling = @as(i32, src[0]) - 127;
        src += 1;

        const offs_slot: [*]u8 = scratch;
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_o: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), @as(i64, lz.cmd_stream_size)));
        const res = try entropy.highDecodeBytes(offs_slot, cap_o, src[0..src_left], false, scratch, scratch_end);
        src += res.bytes_consumed;
        packed_offs_stream = res.out_ptr;
        packed_offs_stream_size = @intCast(res.decoded_size);
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) scratch += res.decoded_size;

        if (offs_scaling != 1) {
            const src_left2: usize = @intFromPtr(src_end) - @intFromPtr(src);
            const cap_e: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), @as(i64, packed_offs_stream_size)));
            const res2 = try entropy.highDecodeBytes(scratch, cap_e, src[0..src_left2], false, scratch, scratch_end);
            if (res2.decoded_size != packed_offs_stream_size) return error.StreamMismatch;
            src += res2.bytes_consumed;
            packed_offs_stream_extra = res2.out_ptr;
            if (@intFromPtr(res2.out_ptr) == @intFromPtr(scratch)) scratch += res2.decoded_size;
        }
    } else {
        const offs_slot: [*]u8 = scratch;
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap_o: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), @as(i64, lz.cmd_stream_size)));
        const res = try entropy.highDecodeBytes(offs_slot, cap_o, src[0..src_left], false, scratch, scratch_end);
        src += res.bytes_consumed;
        packed_offs_stream = res.out_ptr;
        packed_offs_stream_size = @intCast(res.decoded_size);
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) scratch += res.decoded_size;
    }

    // Packed length stream, bounded by dst_size >> 2.
    var packed_len_stream: [*]const u8 = undefined;
    var packed_len_stream_size: u32 = 0;
    {
        const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
        const cap: usize = @intCast(@min(@as(i64, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch))), dst_size >> 2));
        const res = try entropy.highDecodeBytes(scratch, cap, src[0..src_left], false, scratch, scratch_end);
        src += res.bytes_consumed;
        packed_len_stream = res.out_ptr;
        packed_len_stream_size = @intCast(res.decoded_size);
        if (@intFromPtr(res.out_ptr) == @intFromPtr(scratch)) scratch += res.decoded_size;
    }

    // Reserve memory for final dist stream (16-byte aligned for SIMD).
    scratch = alignUp(scratch, 16);
    const offs_final: [*]align(1) i32 = @ptrCast(@alignCast(scratch));
    const offs_bytes: usize = @as(usize, packed_offs_stream_size) * 4;
    const len_bytes: usize = @as(usize, packed_len_stream_size) * 4;
    if (offs_bytes > @intFromPtr(scratch_end) - @intFromPtr(scratch)) return error.SourceTruncated;
    scratch += offs_bytes;

    scratch = alignUp(scratch, 16);
    const len_final: [*]align(1) i32 = @ptrCast(@alignCast(scratch));
    if (len_bytes > @intFromPtr(scratch_end) - @intFromPtr(scratch)) return error.SourceTruncated;
    scratch += len_bytes;

    if (@intFromPtr(scratch) + 64 > @intFromPtr(scratch_end)) return error.SourceTruncated;

    lz.offs_stream = offs_final;
    lz.offs_stream_size = packed_offs_stream_size;
    lz.len_stream = len_final;
    lz.len_stream_size = packed_len_stream_size;

    try unpackOffsets(
        src,
        src_end,
        packed_offs_stream,
        packed_offs_stream_extra,
        packed_offs_stream_size,
        offs_scaling,
        packed_len_stream,
        packed_len_stream_size,
        offs_final,
        len_final,
        false,
        0,
    );
}

// ────────────────────────────────────────────────────────────
//  Two-phase decode support — Phase 1 (entropy decode only)
// ────────────────────────────────────────────────────────────

/// Per-sub-chunk result recorded by `phase1ProcessChunk`. Phase 2
/// (the caller's serial ProcessLzRuns loop) consumes this to replay
/// the match stream into the output buffer.
pub const SubChunkPhase1Result = struct {
    mode: u32,
    dst_offset: usize,
    dst_size: usize,
    is_lz: bool,
    /// Pointer to the `HighLzTable` that `readLzTable` populated for
    /// this sub-chunk. Only valid when `is_lz` is true. The table
    /// itself lives inside the per-sub-chunk scratch region — the
    /// caller must keep that scratch alive until phase 2 runs.
    lz_table: ?*HighLzTable = null,
    /// Scratch bounds for this sub-chunk so phase 2 can pass them to
    /// `processLzRuns` with the correct free-region pointer.
    scratch_free: [*]u8 = undefined,
    scratch_end: [*]u8 = undefined,
};

/// Per-chunk result for two-phase decode. Sub-chunks are numbered
/// 0 and 1 (a 256 KB chunk contains up to two 128 KB sub-chunks).
pub const ChunkPhase1Result = struct {
    sub0: SubChunkPhase1Result = .{ .mode = 0, .dst_offset = 0, .dst_size = 0, .is_lz = false },
    sub1: SubChunkPhase1Result = .{ .mode = 0, .dst_offset = 0, .dst_size = 0, .is_lz = false },
    sub_chunk_count: u32 = 0,
    /// Set for uncompressed / memset / whole-match chunks whose output
    /// is fully written by phase 1 (no phase 2 work needed).
    is_special: bool = false,
    is_whole_match: bool = false,
    whole_match_distance: u32 = 0,
};

/// Phase 1 of two-phase decompression: walks the sub-chunks inside
/// a compressed 256 KB chunk and calls `readLzTable` on each LZ
/// sub-chunk, writing the decoded `HighLzTable` into a per-sub-chunk
/// scratch region.
///
/// Scratch layout: `scratch[0..scratch_end-scratch]` is split in half
/// — the first half holds sub-chunk 0's HighLzTable + streams; the
/// second half holds sub-chunk 1's. The caller must preserve the
/// full region until phase 2 runs.
///
/// Returns the number of compressed bytes consumed from `src_in`.
pub fn phase1ProcessChunk(
    dst_in: [*]u8,
    dst_end: [*]u8,
    dst_start: [*]const u8,
    src_in: [*]const u8,
    src_end: [*]const u8,
    scratch: [*]u8,
    scratch_end: [*]u8,
    result: *ChunkPhase1Result,
) DecodeError!usize {
    var src = src_in;
    var dst = dst_in;
    var sub_idx: u32 = 0;

    const total_scratch: usize = @intFromPtr(scratch_end) - @intFromPtr(scratch);
    const per_sub_scratch: usize = total_scratch / 2;

    while (@intFromPtr(dst_end) - @intFromPtr(dst) != 0) {
        var dst_count: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
        if (dst_count > 0x20000) dst_count = 0x20000;
        if (@intFromPtr(src_end) - @intFromPtr(src) < 4) return error.SourceTruncated;

        // Select per-sub-chunk scratch region.
        const sub_scratch: [*]u8 = scratch + sub_idx * per_sub_scratch;
        const sub_scratch_end: [*]u8 = sub_scratch + per_sub_scratch;

        const chunkhdr: u32 = (@as(u32, src[0]) << 16) | (@as(u32, src[1]) << 8) | @as(u32, src[2]);
        var src_used: usize = undefined;

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            // Entropy-only sub-chunk — decode directly to output. Phase 2
            // has nothing to do for this sub-chunk.
            const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
            const res = try entropy.highDecodeBytes(dst, dst_count, src[0..src_left], false, sub_scratch, sub_scratch_end);
            if (res.decoded_size != dst_count) return error.OutputTruncated;
            if (@intFromPtr(res.out_ptr) != @intFromPtr(dst)) {
                @memcpy(dst[0..dst_count], res.out_ptr[0..dst_count]);
            }
            src_used = res.bytes_consumed;

            const sub_ptr: *SubChunkPhase1Result = if (sub_idx == 0) &result.sub0 else &result.sub1;
            sub_ptr.* = .{
                .mode = 0,
                .dst_offset = @intFromPtr(dst) - @intFromPtr(dst_start),
                .dst_size = dst_count,
                .is_lz = false,
            };
        } else {
            src += 3;
            src_used = chunkhdr & 0x7FFFF;
            const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;
            if (@intFromPtr(src_end) - @intFromPtr(src) < src_used) return error.SourceTruncated;

            if (src_used < dst_count) {
                // LZ sub-chunk — entropy-decode the 4 streams into the
                // HighLzTable that lives at the start of this sub-chunk's
                // scratch region.
                const scratch_usage: usize = @min(
                    constants.calculateScratchSize(dst_count),
                    per_sub_scratch,
                );
                if (scratch_usage < @sizeOf(HighLzTable)) return error.InvalidChunkHeader;

                const lz_ptr: *HighLzTable = @ptrCast(@alignCast(sub_scratch));
                const inner_scratch: [*]u8 = sub_scratch + @sizeOf(HighLzTable);
                const inner_scratch_end: [*]u8 = sub_scratch + scratch_usage;

                try readLzTable(
                    mode,
                    src,
                    src + src_used,
                    dst,
                    @intCast(dst_count),
                    @intCast(@intFromPtr(dst) - @intFromPtr(dst_start)),
                    inner_scratch,
                    inner_scratch_end,
                    lz_ptr,
                );

                const sub_ptr: *SubChunkPhase1Result = if (sub_idx == 0) &result.sub0 else &result.sub1;
                sub_ptr.* = .{
                    .mode = mode,
                    .dst_offset = @intFromPtr(dst) - @intFromPtr(dst_start),
                    .dst_size = dst_count,
                    .is_lz = true,
                    .lz_table = lz_ptr,
                    .scratch_free = sub_scratch + scratch_usage,
                    .scratch_end = sub_scratch_end,
                };
            } else if (src_used > dst_count or mode != 0) {
                return error.InvalidChunkHeader;
            } else {
                // Stored raw within a "compressed" flag block — copy directly.
                @memcpy(dst[0..dst_count], src[0..dst_count]);
                const sub_ptr: *SubChunkPhase1Result = if (sub_idx == 0) &result.sub0 else &result.sub1;
                sub_ptr.* = .{
                    .mode = 0,
                    .dst_offset = @intFromPtr(dst) - @intFromPtr(dst_start),
                    .dst_size = dst_count,
                    .is_lz = false,
                };
            }
        }

        src += src_used;
        dst += dst_count;
        sub_idx += 1;
    }

    result.sub_chunk_count = sub_idx;
    return @intFromPtr(src) - @intFromPtr(src_in);
}

// ────────────────────────────────────────────────────────────
//  DecodeChunk — top-level High chunk decoder
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

        // 3-byte big-endian sub-chunk header.
        const chunkhdr: u32 = (@as(u32, src[0]) << 16) | (@as(u32, src[1]) << 8) | @as(u32, src[2]);
        var src_used: usize = undefined;

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            // Stored as entropy without LZ.
            const src_left: usize = @intFromPtr(src_end) - @intFromPtr(src);
            const res = try entropy.highDecodeBytes(dst, dst_count, src[0..src_left], false, scratch, scratch_end);
            if (res.decoded_size != dst_count) return error.OutputTruncated;
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
                const scratch_usage: usize = @min(
                    constants.calculateScratchSize(dst_count),
                    @intFromPtr(scratch_end) - @intFromPtr(scratch),
                );
                if (scratch_usage < @sizeOf(HighLzTable)) return error.InvalidChunkHeader;

                const lz_ptr: *HighLzTable = @ptrCast(@alignCast(scratch));
                const inner_scratch: [*]u8 = scratch + @sizeOf(HighLzTable);
                const inner_scratch_end: [*]u8 = scratch + scratch_usage;

                try readLzTable(
                    mode,
                    src,
                    src + src_used,
                    dst,
                    @intCast(dst_count),
                    @intCast(@intFromPtr(dst) - @intFromPtr(dst_start)),
                    inner_scratch,
                    inner_scratch_end,
                    lz_ptr,
                );
                try runs.processLzRuns(
                    mode,
                    dst,
                    dst_count,
                    @intCast(@intFromPtr(dst) - @intFromPtr(dst_start)),
                    lz_ptr,
                    scratch + scratch_usage,
                    scratch_end,
                );
            } else if (src_used > dst_count or mode != 0) {
                return error.InvalidChunkHeader;
            } else {
                @memcpy(dst[0..dst_count], src[0..dst_count]);
            }
        }

        src += src_used;
        dst += dst_count;
    }

    return @intFromPtr(src) - @intFromPtr(src_in);
}
