//! Entropy-stream dispatcher. Port of src/StreamLZ/Decompression/Entropy/EntropyDecoder.cs.
//!
//! Dispatches an entropy block by reading its 2-5 byte header (chunk type in
//! `src[0][6:4]`) and routing to:
//!   * Type 0 — memcopy / raw bytes
//!   * Type 1 — tANS
//!   * Type 2 — Huffman 2-way split
//!   * Type 3 — RLE
//!   * Type 4 — Huffman 4-way split
//!   * Type 5 — Recursive multi-block (simple N-split path supported;
//!     the multi-array bit-7-set variant lands in a follow-up)
//!
//! The decoder writes into `dst_buf` (or, for Type 0 with `force_memmove=false`,
//! hands back a pointer directly into `src`, enabling zero-copy literal streams
//! that the Fast decoder takes advantage of).

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const huffman = @import("huffman_decoder.zig");
const tans = @import("tans_decoder.zig");

pub const DecodeError = error{
    SourceTruncated,
    OutputTooSmall,
    BadChunkHeader,
    UnsupportedChunkType,
    SubDecoderMismatch,
    RleStreamMismatch,
    RecursiveDepthExceeded,
    MultiArrayNotSupported,
} || huffman.DecodeError || tans.DecodeError;

/// Result of an entropy-block decode. `out_ptr` is where the decoded bytes
/// actually live — for Type 0 zero-copy mode it points into the source buffer;
/// otherwise it equals `dst_buf`.
pub const DecodeResult = struct {
    /// Pointer to the first decoded byte (may equal `dst_buf` or point into `src`).
    out_ptr: [*]const u8,
    /// Number of decoded (output) bytes.
    decoded_size: usize,
    /// Number of source bytes consumed (including the block header).
    bytes_consumed: usize,
};

/// Decode an entropy block starting at `src[0]`.
/// `dst_buf` is the caller's output target; the decoder writes at most
/// `output_capacity` bytes there. When `force_memmove=true`, Type 0 copies
/// into `dst_buf`; otherwise the returned `out_ptr` may point into `src`.
/// `scratch` / `scratch_end` is the workspace for sub-decoders (tANS LUT,
/// RLE command expansion, recursive sub-block intermediate buffers).
/// When `dst_buf` aliases `scratch`, the internal code advances scratch
/// past `dst_size` before handing it to sub-decoders — matching the C#
/// `dst == scratch` alias check in `EntropyDecoder.High_DecodeBytesInternal`.
pub fn highDecodeBytes(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
    scratch: [*]u8,
    scratch_end: [*]u8,
) DecodeError!DecodeResult {
    return highDecodeBytesInternal(dst_buf, output_capacity, src_buf, force_memmove, scratch, scratch_end, 16);
}

fn highDecodeBytesInternal(
    dst_buf: [*]u8,
    output_capacity: usize,
    src_buf: []const u8,
    force_memmove: bool,
    scratch_in: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!DecodeResult {
    if (max_depth == 0) return error.RecursiveDepthExceeded;

    if (src_buf.len < 2) return error.SourceTruncated;

    const src_start: [*]const u8 = src_buf.ptr;
    const src_end_total: [*]const u8 = src_buf.ptr + src_buf.len;

    const chunk_type: u32 = @intCast((src_buf[0] >> 4) & 0x7);

    // ── Type 0: memcopy / uncompressed ──
    if (chunk_type == 0) {
        var src = src_start;
        var src_size: usize = undefined;

        if (src_buf[0] >= 0x80) {
            // Short-mode 12-bit length header.
            src_size = @intCast(((@as(u32, src_buf[0]) << 8) | src_buf[1]) & constants.block_size_mask_12);
            src += 2;
        } else {
            if (src_buf.len < 3) return error.SourceTruncated;
            const raw: u32 = (@as(u32, src_buf[0]) << 16) | (@as(u32, src_buf[1]) << 8) | @as(u32, src_buf[2]);
            if ((raw & ~@as(u32, 0x3ffff)) != 0) return error.BadChunkHeader;
            src_size = @intCast(raw);
            src += 3;
        }

        if (src_size > output_capacity) return error.OutputTooSmall;
        if (@intFromPtr(src) + src_size > @intFromPtr(src_end_total)) return error.SourceTruncated;

        var out_ptr: [*]const u8 = src;
        if (force_memmove) {
            @memcpy(dst_buf[0..src_size], src[0..src_size]);
            out_ptr = dst_buf;
        }
        return .{
            .out_ptr = out_ptr,
            .decoded_size = src_size,
            .bytes_consumed = @intFromPtr(src) + src_size - @intFromPtr(src_start),
        };
    }

    // ── Types 1–5: compressed block with 3- or 5-byte header ──
    var src_ptr = src_start;
    var src_size: u32 = undefined;
    var dst_size: u32 = undefined;

    if (src_buf[0] >= 0x80) {
        if (src_buf.len < 3) return error.SourceTruncated;
        const bits: u32 = (@as(u32, src_buf[0]) << 16) | (@as(u32, src_buf[1]) << 8) | @as(u32, src_buf[2]);
        src_size = bits & constants.block_size_mask_10;
        dst_size = src_size + ((bits >> 10) & constants.block_size_mask_10) + 1;
        src_ptr += 3;
    } else {
        if (src_buf.len < 5) return error.SourceTruncated;
        const bits: u32 = (@as(u32, src_buf[1]) << 24) |
            (@as(u32, src_buf[2]) << 16) |
            (@as(u32, src_buf[3]) << 8) |
            @as(u32, src_buf[4]);
        src_size = bits & 0x3ffff;
        dst_size = (((bits >> 18) | (@as(u32, src_buf[0]) << 14)) & 0x3FFFF) + 1;
        if (src_size >= dst_size) return error.BadChunkHeader;
        src_ptr += 5;
    }

    if (@intFromPtr(src_ptr) + src_size > @intFromPtr(src_end_total)) return error.SourceTruncated;
    if (dst_size > output_capacity) return error.OutputTooSmall;

    const payload = src_ptr[0..src_size];
    var src_used: usize = undefined;

    // dst == scratch alias handling: caller may have passed the same
    // pointer for both, in which case sub-decoder workspace must start
    // past the decoded output. Port of the C# check at
    // `EntropyDecoder.High_DecodeBytesInternal` lines 770-778.
    var scratch_ptr: [*]u8 = scratch_in;
    if (@intFromPtr(dst_buf) == @intFromPtr(scratch_in)) {
        if (@intFromPtr(scratch_in) + dst_size > @intFromPtr(scratch_end)) return error.OutputTooSmall;
        scratch_ptr = scratch_in + dst_size;
    }

    switch (chunk_type) {
        2 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 1),
        4 => src_used = try huffman.highDecodeBytesType12(payload, dst_buf, dst_size, 2),
        1 => src_used = try tans.highDecodeTans(
            payload.ptr,
            payload.len,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
        ),
        3 => src_used = try decodeRle(
            payload,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
            max_depth,
        ),
        5 => src_used = try decodeRecursive(
            payload,
            dst_buf,
            dst_size,
            scratch_ptr,
            scratch_end,
            max_depth,
        ),
        else => return error.BadChunkHeader,
    }

    if (src_used != src_size) return error.SubDecoderMismatch;
    return .{
        .out_ptr = dst_buf,
        .decoded_size = dst_size,
        .bytes_consumed = @intFromPtr(src_ptr) + src_size - @intFromPtr(src_start),
    };
}

// ────────────────────────────────────────────────────────────
//  Type 3 — RLE decoder
// ────────────────────────────────────────────────────────────

/// Run-length decoder. Commands walk backward from the end of the block,
/// literals forward from `src[1]`. The first byte flags whether the
/// command stream is entropy-coded (via a nested `highDecodeBytes` call).
fn decodeRle(
    src: []const u8,
    dst_buf: [*]u8,
    dst_size: usize,
    scratch: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!usize {
    if (src.len <= 1) {
        if (src.len != 1) return error.SourceTruncated;
        @memset(dst_buf[0..dst_size], src[0]);
        return 1;
    }

    var dst = dst_buf;
    const dst_end: [*]u8 = dst_buf + dst_size;

    const src_start: [*]const u8 = src.ptr;
    var cmd_ptr: [*]const u8 = src_start + 1;
    var cmd_ptr_end: [*]const u8 = src_start + src.len;

    // Optional entropy-coded command prefix.
    var scratch_ptr: [*]u8 = scratch;
    if (src[0] != 0) {
        const remaining: []const u8 = src_start[0..src.len];
        // Nested entropy decode: pass the advanced scratch cursor as
        // both dst AND scratch. `highDecodeBytesInternal` will detect
        // the alias and shift scratch past the decoded output before
        // routing to sub-decoders.
        const res = try highDecodeBytesInternal(
            scratch_ptr,
            @intFromPtr(scratch_end) - @intFromPtr(scratch_ptr),
            remaining,
            true,
            scratch_ptr,
            scratch_end,
            max_depth - 1,
        );
        const n = res.bytes_consumed;
        const dec_size = res.decoded_size;
        const tail_size: usize = src.len - n;
        const cmd_len: usize = tail_size + dec_size;
        if (cmd_len > @intFromPtr(scratch_end) - @intFromPtr(scratch_ptr)) return error.OutputTooSmall;

        // Append the un-decoded tail bytes after the decoded prefix.
        const dst_slot: [*]u8 = scratch_ptr;
        @memcpy(dst_slot[dec_size .. dec_size + tail_size], src_start[n .. n + tail_size]);

        cmd_ptr = dst_slot;
        cmd_ptr_end = dst_slot + cmd_len;
        scratch_ptr += cmd_len;
    }

    var rle_byte: u8 = 0;

    while (@intFromPtr(cmd_ptr) < @intFromPtr(cmd_ptr_end)) {
        const cmd: u32 = (cmd_ptr_end - 1)[0];

        if ((cmd -% 1) >= constants.rle_short_command_threshold) {
            cmd_ptr_end -= 1;
            const bytes_to_copy: usize = @intCast((~cmd) & 0xF);
            const bytes_to_rle: usize = @intCast(cmd >> 4);
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy + bytes_to_rle) return error.RleStreamMismatch;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            cmd_ptr += bytes_to_copy;
            dst += bytes_to_copy;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else if (cmd >= 0x10) {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const data: u32 = word -% 4096;
            cmd_ptr_end -= 2;
            const bytes_to_copy: usize = @intCast(data & 0x3F);
            const bytes_to_rle: usize = @intCast(data >> 6);
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy + bytes_to_rle) return error.RleStreamMismatch;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            cmd_ptr += bytes_to_copy;
            dst += bytes_to_copy;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else if (cmd == 1) {
            rle_byte = cmd_ptr[0];
            cmd_ptr += 1;
            cmd_ptr_end -= 1;
        } else if (cmd >= 9) {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const bytes_to_rle: usize = @intCast((word -% 0x8ff) * 128);
            cmd_ptr_end -= 2;
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_rle) return error.RleStreamMismatch;
            @memset(dst[0..bytes_to_rle], rle_byte);
            dst += bytes_to_rle;
        } else {
            const pair_ptr: [*]const u8 = cmd_ptr_end - 2;
            const word: u32 = @as(u32, pair_ptr[0]) | (@as(u32, pair_ptr[1]) << 8);
            const bytes_to_copy: usize = @intCast((word -% 511) * 64);
            cmd_ptr_end -= 2;
            if (@intFromPtr(cmd_ptr_end) - @intFromPtr(cmd_ptr) < bytes_to_copy) return error.RleStreamMismatch;
            if (@intFromPtr(dst_end) - @intFromPtr(dst) < bytes_to_copy) return error.RleStreamMismatch;
            @memcpy(dst[0..bytes_to_copy], cmd_ptr[0..bytes_to_copy]);
            dst += bytes_to_copy;
            cmd_ptr += bytes_to_copy;
        }
    }

    if (@intFromPtr(cmd_ptr_end) != @intFromPtr(cmd_ptr)) return error.RleStreamMismatch;
    if (@intFromPtr(dst) != @intFromPtr(dst_end)) return error.RleStreamMismatch;
    return src.len;
}

// ────────────────────────────────────────────────────────────
//  Type 5 — Multi-array interleaved decoder (bit-7 variant)
// ────────────────────────────────────────────────────────────

/// Result of a multi-array decode: total bytes consumed from `src`, and
/// total bytes emitted into `dst` across all output arrays.
pub const DecodeMultiArrayResult = struct {
    bytes_consumed: usize,
    total_size: usize,
};

/// Decodes a multi-array interleaved entropy block into `dst[0..dst_size]`,
/// splitting the output across `array_data.len` target arrays. Each output
/// array receives a contiguous slice of `dst`; `array_data[i]` is set to
/// the start of array `i` and `array_lens[i]` to its byte count.
///
/// Port of C# `EntropyDecoder.High_DecodeMultiArrayInternal` at
/// `EntropyDecoder.cs:344-638`. The on-wire format is:
///   1. Marker byte (bit 7 set) + 6-bit `num_arrays_in_file` (1..32).
///   2. `num_arrays_in_file` nested entropy blocks decoded into scratch.
///   3. 2-byte Q value (interpretation depends on bit 15).
///   4. Block header describing `num_indexes` — one byte per interval.
///   5. Interval-index + interval-lenlog2 streams (packed if Q & 0x8000,
///      separate otherwise).
///   6. `varbits_complen = Q & 0x3FFF` bytes of bidirectional varbit stream
///      encoding the per-interval lengths (rotate-left scheme).
///   7. Assembly: for each output array, walk intervals until a zero
///      terminator in `interval_indexes`, copying `curLen` bytes from the
///      source array named by `interval_indexes[i]`.
pub fn decodeMultiArray(
    src: []const u8,
    dst_buf: [*]u8,
    dst_size: usize,
    array_data: [][*]u8,
    array_lens: []u32,
    scratch: [*]u8,
    scratch_end: [*]u8,
) DecodeError!DecodeMultiArrayResult {
    return decodeMultiArrayInternal(
        src,
        dst_buf,
        dst_size,
        array_data,
        array_lens,
        scratch,
        scratch_end,
        16,
    );
}

fn decodeMultiArrayInternal(
    src: []const u8,
    dst_buf_ptr: [*]u8,
    dst_size_in: usize,
    array_data: [][*]u8,
    array_lens: []u32,
    scratch_in: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!DecodeMultiArrayResult {
    if (array_data.len == 0 or array_data.len != array_lens.len) return error.BadChunkHeader;
    if (src.len < 4) return error.SourceTruncated;

    const src_start: [*]const u8 = src.ptr;
    var src_ptr: [*]const u8 = src_start;
    const src_total_end: [*]const u8 = src.ptr + src.len;

    // Header byte: bit 7 must be set; low 6 bits = num_arrays_in_file.
    const header_byte: u8 = src_ptr[0];
    src_ptr += 1;
    if ((header_byte & 0x80) == 0) return error.BadChunkHeader;
    const num_arrays_in_file: u32 = header_byte & 0x3f;
    if (num_arrays_in_file > 32) return error.BadChunkHeader;

    const array_count: usize = array_data.len;
    var dst: [*]u8 = dst_buf_ptr;
    const dst_end: [*]u8 = dst_buf_ptr + dst_size_in;

    // Handle the scratch-aliased-with-dst case, mirroring C# lines 376-382.
    var scratch: [*]u8 = scratch_in;
    var dst_end_work: [*]u8 = dst_end;
    if (@intFromPtr(dst) == @intFromPtr(scratch_in)) {
        // Reserve 0xC000 at the tail of scratch for nested entropy-decode
        // workspace; split the remainder in half between dst and scratch
        // workspace, matching C# line 380.
        const remain: isize = @as(isize, @intCast(@intFromPtr(scratch_end) - @intFromPtr(scratch_in))) - 0xC000;
        if (remain <= 0) return error.OutputTooSmall;
        const half: usize = @as(usize, @intCast(remain)) >> 1;
        scratch = scratch_in + half;
        dst_end_work = scratch;
    }

    var total_size: usize = 0;

    // Fast path: no interleaved assembly, just decode `array_count` sub-blocks
    // in order directly into `dst`. Port of C# lines 386-402.
    if (num_arrays_in_file == 0) {
        for (0..array_count) |i| {
            const remaining_src: []const u8 = src_ptr[0 .. @intFromPtr(src_total_end) - @intFromPtr(src_ptr)];
            const cap: usize = @intFromPtr(dst_end_work) - @intFromPtr(dst);
            const res = try highDecodeBytesInternal(
                dst,
                cap,
                remaining_src,
                true, // force_memmove so decoded bytes land in dst
                scratch,
                scratch_end,
                max_depth - 1,
            );
            array_data[i] = dst;
            array_lens[i] = @intCast(res.decoded_size);
            dst += res.decoded_size;
            total_size += res.decoded_size;
            src_ptr += res.bytes_consumed;
        }
        return .{
            .bytes_consumed = @intFromPtr(src_ptr) - @intFromPtr(src_start),
            .total_size = total_size,
        };
    }

    // First loop: decode each of the N source entropy arrays into scratch.
    var entropy_array_data: [32][*]const u8 = undefined;
    var entropy_array_size: [32]u32 = undefined;
    var scratch_cur: [*]u8 = scratch;

    for (0..num_arrays_in_file) |i| {
        const remaining_src: []const u8 = src_ptr[0 .. @intFromPtr(src_total_end) - @intFromPtr(src_ptr)];
        const cap: usize = @intFromPtr(scratch_end) - @intFromPtr(scratch_cur);
        const res = try highDecodeBytesInternal(
            scratch_cur,
            cap,
            remaining_src,
            true,
            scratch_cur,
            scratch_end,
            max_depth - 1,
        );
        entropy_array_data[i] = res.out_ptr;
        entropy_array_size[i] = @intCast(res.decoded_size);
        scratch_cur += res.decoded_size;
        total_size += res.decoded_size;
        src_ptr += res.bytes_consumed;
    }

    // 2-byte Q-value.
    if (@intFromPtr(src_total_end) - @intFromPtr(src_ptr) < 3) return error.SourceTruncated;
    const q: u32 = @as(u32, src_ptr[0]) | (@as(u32, src_ptr[1]) << 8);
    src_ptr += 2;

    // Read the interval-index-count header using the block-size-only parser
    // (same algorithm as highDecodeBytesInternal but destSize-only — C#
    // `High_GetBlockSize`). We inline it here.
    const num_indexes: u32 = try readIndexCount(src_ptr, src_total_end, total_size);
    var num_lens: i32 = @as(i32, @intCast(num_indexes)) - @as(i32, @intCast(array_count));
    if (num_lens < 1) return error.BadChunkHeader;

    // Allocate scratch: interval_lenlog2[num_indexes], interval_indexes[num_indexes]
    if (@intFromPtr(scratch_end) - @intFromPtr(scratch_cur) < num_indexes) return error.OutputTooSmall;
    const interval_lenlog2: [*]u8 = scratch_cur;
    scratch_cur += num_indexes;

    if (@intFromPtr(scratch_end) - @intFromPtr(scratch_cur) < num_indexes) return error.OutputTooSmall;
    var interval_indexes: [*]u8 = scratch_cur;
    scratch_cur += num_indexes;

    if ((q & 0x8000) != 0) {
        // Packed: single byte per interval carrying (lenlog2 << 4) | index.
        const remaining_src: []const u8 = src_ptr[0 .. @intFromPtr(src_total_end) - @intFromPtr(src_ptr)];
        const res = try highDecodeBytesInternal(
            interval_indexes,
            num_indexes,
            remaining_src,
            false,
            scratch_cur,
            scratch_end,
            max_depth - 1,
        );
        if (res.decoded_size != num_indexes) return error.SubDecoderMismatch;
        src_ptr += res.bytes_consumed;
        interval_indexes = @constCast(res.out_ptr);

        for (0..num_indexes) |i| {
            const t = interval_indexes[i];
            interval_lenlog2[i] = t >> 4;
            interval_indexes[i] = t & 0xF;
        }
        num_lens = @intCast(num_indexes);
    } else {
        // Separate: index stream, then lenlog2 stream.
        const lenlog2_chunksize: u32 = num_indexes - @as(u32, @intCast(array_count));

        {
            const remaining_src: []const u8 = src_ptr[0 .. @intFromPtr(src_total_end) - @intFromPtr(src_ptr)];
            const res = try highDecodeBytesInternal(
                interval_indexes,
                num_indexes,
                remaining_src,
                false,
                scratch_cur,
                scratch_end,
                max_depth - 1,
            );
            if (res.decoded_size != num_indexes) return error.SubDecoderMismatch;
            src_ptr += res.bytes_consumed;
            interval_indexes = @constCast(res.out_ptr);
        }

        {
            const remaining_src: []const u8 = src_ptr[0 .. @intFromPtr(src_total_end) - @intFromPtr(src_ptr)];
            const res = try highDecodeBytesInternal(
                interval_lenlog2,
                lenlog2_chunksize,
                remaining_src,
                false,
                scratch_cur,
                scratch_end,
                max_depth - 1,
            );
            if (res.decoded_size != lenlog2_chunksize) return error.SubDecoderMismatch;
            src_ptr += res.bytes_consumed;
            // Note: unlike the packed path, this stream is NOT aliased back
            // into place — the caller reads from `interval_lenlog2` directly
            // where it was allocated in scratch. Copy the zero-copy result
            // into the reserved slot if the decoder handed back a pointer
            // elsewhere (Type 0 memcpy can do that).
            if (@intFromPtr(res.out_ptr) != @intFromPtr(interval_lenlog2)) {
                @memcpy(interval_lenlog2[0..lenlog2_chunksize], res.out_ptr[0..lenlog2_chunksize]);
            }
        }

        // Validate all lenlog2 values are <= 16 (max supported width).
        for (0..lenlog2_chunksize) |i| {
            if (interval_lenlog2[i] > 16) return error.BadChunkHeader;
        }
    }

    // Align scratch to 4 bytes, allocate decoded_intervals[num_lens].
    if (@intFromPtr(scratch_end) - @intFromPtr(scratch_cur) < 4) return error.OutputTooSmall;
    const aligned_addr: usize = (@intFromPtr(scratch_cur) + 3) & ~@as(usize, 3);
    scratch_cur = @ptrFromInt(aligned_addr);
    const num_lens_u: usize = @intCast(num_lens);
    if (@intFromPtr(scratch_end) - @intFromPtr(scratch_cur) < num_lens_u * 4) return error.OutputTooSmall;
    const decoded_intervals: [*]align(1) u32 = @ptrCast(scratch_cur);

    // Bidirectional varbit decode of interval lengths.
    const varbits_complen: u32 = q & 0x3FFF;
    if (@intFromPtr(src_total_end) - @intFromPtr(src_ptr) < varbits_complen) return error.SourceTruncated;

    var f: [*]const u8 = src_ptr;
    var bits_f: u32 = 0;
    var bitpos_f: i32 = 24;

    const src_end_actual: [*]const u8 = src_ptr + varbits_complen;

    var b: [*]const u8 = src_end_actual;
    var bits_b: u32 = 0;
    var bitpos_b: i32 = 24;

    var ii: i32 = 0;
    while (ii + 2 <= num_lens) : (ii += 2) {
        // Forward refill: read a big-endian u32 at f, shift right by (24 - bitpos_f),
        // OR into bits_f, advance f by ceil(bitpos_f/8) bytes.
        const raw_f: u32 = std.mem.readInt(u32, f[0..4], .big);
        bits_f |= raw_f >> @intCast(24 - bitpos_f);
        const adv_f: usize = @intCast((bitpos_f + 7) >> 3);
        f += adv_f;

        // Backward refill: read u32 at (b - 4) little-endian, shift right by (24 - bitpos_b).
        const raw_b: u32 = std.mem.readInt(u32, (b - 4)[0..4], .little);
        bits_b |= raw_b >> @intCast(24 - bitpos_b);
        const adv_b: usize = @intCast((bitpos_b + 7) >> 3);
        b -= adv_b;

        const numbits_f: u5 = @intCast(interval_lenlog2[@intCast(ii + 0)]);
        const numbits_b: u5 = @intCast(interval_lenlog2[@intCast(ii + 1)]);

        // Rotate-left with sentinel bit set (| 1). Port of BitOperations.RotateLeft.
        bits_f = std.math.rotl(u32, bits_f | 1, @as(usize, numbits_f));
        bitpos_f += @as(i32, numbits_f) - 8 * ((bitpos_f + 7) >> 3);

        bits_b = std.math.rotl(u32, bits_b | 1, @as(usize, numbits_b));
        bitpos_b += @as(i32, numbits_b) - 8 * ((bitpos_b + 7) >> 3);

        const mask_f: u32 = if (numbits_f == 0) 0 else (@as(u32, 1) << numbits_f) - 1;
        const mask_b: u32 = if (numbits_b == 0) 0 else (@as(u32, 1) << numbits_b) - 1;

        const value_f: u32 = bits_f & mask_f;
        bits_f &= ~mask_f;

        const value_b: u32 = bits_b & mask_b;
        bits_b &= ~mask_b;

        decoded_intervals[@intCast(ii + 0)] = value_f;
        decoded_intervals[@intCast(ii + 1)] = value_b;
    }

    // Tail: odd `num_lens` reads one more forward value.
    if (ii < num_lens) {
        const raw_f: u32 = std.mem.readInt(u32, f[0..4], .big);
        bits_f |= raw_f >> @intCast(24 - bitpos_f);
        const numbits_ff: u5 = @intCast(interval_lenlog2[@intCast(ii)]);
        bits_f = std.math.rotl(u32, bits_f | 1, @as(usize, numbits_ff));
        const mask_ff: u32 = if (numbits_ff == 0) 0 else (@as(u32, 1) << numbits_ff) - 1;
        decoded_intervals[@intCast(ii)] = bits_f & mask_ff;
    }

    // Terminator check: last interval-index byte must be zero.
    if (interval_indexes[num_indexes - 1] != 0) return error.BadChunkHeader;

    // Assembly loop: fill each output array by walking intervals until a zero
    // index is seen, copying `curLen` bytes from the designated source array.
    var indi: usize = 0;
    var leni: usize = 0;
    const increment_leni: usize = if ((q & 0x8000) != 0) 1 else 0;

    var entropy_sizes_mut = entropy_array_size;
    var entropy_data_mut = entropy_array_data;

    // Reset per-array output tracking. We emit into `dst` starting wherever
    // the caller positioned it.
    var out_cursor: [*]u8 = dst;

    for (0..array_count) |arri| {
        array_data[arri] = out_cursor;
        if (indi >= num_indexes) return error.BadChunkHeader;

        while (true) {
            const source: u32 = interval_indexes[indi];
            indi += 1;
            if (source == 0) break;
            if (indi > num_indexes) return error.BadChunkHeader;
            if (source > num_arrays_in_file) return error.BadChunkHeader;
            if (leni >= num_lens_u) return error.BadChunkHeader;

            const cur_len: u32 = decoded_intervals[leni];
            leni += 1;
            const src_idx: usize = source - 1;
            if (cur_len > entropy_sizes_mut[src_idx]) return error.BadChunkHeader;
            if (cur_len > @intFromPtr(dst_end_work) - @intFromPtr(out_cursor)) return error.OutputTooSmall;

            @memcpy(out_cursor[0..cur_len], entropy_data_mut[src_idx][0..cur_len]);
            entropy_sizes_mut[src_idx] -= cur_len;
            entropy_data_mut[src_idx] += cur_len;
            out_cursor += cur_len;
        }

        leni += increment_leni;
        array_lens[arri] = @intCast(@intFromPtr(out_cursor) - @intFromPtr(array_data[arri]));
    }

    if (indi != num_indexes or leni != num_lens_u) return error.BadChunkHeader;

    // All source arrays must have been fully consumed.
    for (0..num_arrays_in_file) |i| {
        if (entropy_sizes_mut[i] != 0) return error.BadChunkHeader;
    }

    return .{
        .bytes_consumed = @intFromPtr(src_end_actual) - @intFromPtr(src_start),
        .total_size = total_size,
    };
}

/// Helper: parse a block-size-only header (chunk type 0 ignored here — we
/// just want the `dst_size` field). Port of C# `EntropyDecoder.High_GetBlockSize`
/// at `EntropyDecoder.cs:46-127`, entropy branch only.
fn readIndexCount(src_ptr: [*]const u8, src_end: [*]const u8, dest_capacity: usize) DecodeError!u32 {
    if (@intFromPtr(src_end) - @intFromPtr(src_ptr) < 2) return error.SourceTruncated;

    const first: u8 = src_ptr[0];
    const chunk_type: u8 = (first >> 4) & 0x7;
    if (chunk_type >= 6) return error.BadChunkHeader;

    // Chunk type 0 path: src/dst size is the same, no separate dst_size.
    if (chunk_type == 0) {
        if (first >= 0x80) {
            const sz: u32 = ((@as(u32, first) << 8) | src_ptr[1]) & constants.block_size_mask_12;
            if (sz > dest_capacity) return error.OutputTooSmall;
            return sz;
        }
        if (@intFromPtr(src_end) - @intFromPtr(src_ptr) < 3) return error.SourceTruncated;
        const sz: u32 = (@as(u32, first) << 16) | (@as(u32, src_ptr[1]) << 8) | @as(u32, src_ptr[2]);
        if ((sz & ~@as(u32, 0x3ffff)) != 0) return error.BadChunkHeader;
        if (sz > dest_capacity) return error.OutputTooSmall;
        return sz;
    }

    // Entropy branch: short/long 10-bit or 18-bit src+dst pair.
    var dst_size: u32 = 0;
    if (first >= 0x80) {
        if (@intFromPtr(src_end) - @intFromPtr(src_ptr) < 3) return error.SourceTruncated;
        const bits: u32 = (@as(u32, first) << 16) | (@as(u32, src_ptr[1]) << 8) | @as(u32, src_ptr[2]);
        const src_sz: u32 = bits & constants.block_size_mask_10;
        dst_size = src_sz + ((bits >> 10) & constants.block_size_mask_10) + 1;
    } else {
        if (@intFromPtr(src_end) - @intFromPtr(src_ptr) < 5) return error.SourceTruncated;
        const bits: u32 = (@as(u32, src_ptr[1]) << 24) | (@as(u32, src_ptr[2]) << 16) | (@as(u32, src_ptr[3]) << 8) | @as(u32, src_ptr[4]);
        const src_sz: u32 = bits & 0x3ffff;
        dst_size = (((bits >> 18) | (@as(u32, first) << 14)) & 0x3FFFF) + 1;
        if (src_sz >= dst_size) return error.BadChunkHeader;
    }
    if (dst_size > dest_capacity) return error.OutputTooSmall;
    return dst_size;
}

// ────────────────────────────────────────────────────────────
//  Type 5 — Recursive multi-block decoder (simple N-split path)
// ────────────────────────────────────────────────────────────

fn decodeRecursive(
    src: []const u8,
    dst_buf: [*]u8,
    dst_size: usize,
    scratch: [*]u8,
    scratch_end: [*]u8,
    max_depth: u32,
) DecodeError!usize {
    if (src.len < 6) return error.SourceTruncated;

    const n0: u8 = src[0] & 0x7F;

    // Multi-array variant (bit 7 set) — the interleaved-stream path in
    // C#'s `High_DecodeMultiArrayInternal`. Dispatches to `decodeMultiArray`
    // with `array_count = 1` so the entire decoded output fills `dst_buf`.
    if ((src[0] & 0x80) != 0) {
        var arr_data: [1][*]u8 = undefined;
        var arr_lens: [1]u32 = undefined;
        const res = try decodeMultiArrayInternal(
            src,
            dst_buf,
            dst_size,
            arr_data[0..1],
            arr_lens[0..1],
            scratch,
            scratch_end,
            max_depth - 1,
        );
        if (arr_lens[0] != dst_size) return error.SubDecoderMismatch;
        return res.bytes_consumed;
    }

    if (n0 < 2) return error.BadChunkHeader;

    // Simple path: N sub-blocks, each decoded via highDecodeBytesInternal with
    // `force_memmove=true` so they concatenate into dst_buf. The caller's
    // scratch is reused across every sub-block — each call sees the full
    // workspace because previous sub-block workspace is released at return.
    var remaining_src: []const u8 = src[1..];
    var dst_cursor: [*]u8 = dst_buf;
    var dst_remaining: usize = dst_size;
    var n: u32 = n0;

    while (n != 0) : (n -= 1) {
        const res = try highDecodeBytesInternal(
            dst_cursor,
            dst_remaining,
            remaining_src,
            true,
            scratch,
            scratch_end,
            max_depth - 1,
        );
        dst_cursor += res.decoded_size;
        dst_remaining -= res.decoded_size;
        remaining_src = remaining_src[res.bytes_consumed..];
    }

    if (dst_remaining != 0) return error.SubDecoderMismatch;
    // Return total bytes consumed from the original `src`.
    return src.len - remaining_src.len;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Type 0 short-mode memcopy zero-copy path" {
    // Header byte: 0x80 | 5 (length 5), next byte = 0, then 5 payload bytes.
    var src: [8]u8 = .{ 0x80, 5, 'a', 'b', 'c', 'd', 'e', 0xFF };
    var dst: [32]u8 = @splat(0);
    var scratch: [256]u8 = undefined;
    const r = try highDecodeBytes(&dst, dst.len, src[0..7], false, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(@as(usize, 5), r.decoded_size);
    try testing.expectEqual(@as(usize, 7), r.bytes_consumed);
    // Zero-copy: out_ptr points into src at offset 2.
    try testing.expectEqual(@intFromPtr(&src[2]), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "abcde", r.out_ptr[0..r.decoded_size]);
}

test "Type 0 memcopy with force_memmove copies into dst_buf" {
    var src: [7]u8 = .{ 0x80, 5, 'h', 'e', 'l', 'l', 'o' };
    var dst: [16]u8 = @splat(0);
    var scratch: [256]u8 = undefined;
    const r = try highDecodeBytes(&dst, dst.len, &src, true, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(@intFromPtr(&dst), @intFromPtr(r.out_ptr));
    try testing.expectEqualSlices(u8, "hello", dst[0..5]);
}

// The previous "unsupported chunk types return error" placeholder test was
// removed in phase 4b — Types 3 and 5 are now wired. End-to-end fixtures
// are the real validation for RLE / Recursive.

test "truncated source returns SourceTruncated" {
    const src = [_]u8{0x80};
    var dst: [16]u8 = undefined;
    var scratch: [256]u8 = undefined;
    try testing.expectError(error.SourceTruncated, highDecodeBytes(&dst, dst.len, &src, false, &scratch, scratch[scratch.len..].ptr));
}
