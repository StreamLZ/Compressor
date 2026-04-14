//! High decoder phase-2: LZ run processor for Type 0 (delta literals)
//! and Type 1 (raw literals). Port of
//! src/StreamLZ/Decompression/High/LzDecoder.ProcessLzRuns.cs.
//!
//! Type 0 is single-pass: walks cmd/offs/len/lit streams inline.
//! Type 1 is two-pass: resolve tokens (carousel + lengths) into a flat
//! array, then execute with match-source prefetching. For the first
//! port I keep both paths simple and correct; the SIMD AVX2 tail
//! optimizations and binary-search dstSafeEnd split land in phase 7.
//!
//! Note: correctness of small-offset match propagation depends on
//! `io.copy_helpers.wildCopy16` doing load-store-load-store (not both
//! loads first); see the comment on that function.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const copy = @import("../io/copy_helpers.zig");
const high = @import("high_lz_decoder.zig");

// Keep this in sync with decode/streamlz_decoder.zig::safe_space.
const safe_space: usize = 64;

pub const DecodeError = high.DecodeError;

pub fn processLzRuns(
    mode: u32,
    dst: [*]u8,
    dst_size: usize,
    base_offset: usize,
    lz: *const high.HighLzTable,
    scratch_free: [*]u8,
    scratch_end: [*]u8,
) DecodeError!void {
    if (dst_size == 0) return error.OutputTruncated;
    const dst_end: [*]u8 = dst + dst_size;
    const dst_start: [*]const u8 = @ptrFromInt(@intFromPtr(dst) - base_offset);
    const dst_run_start: [*]u8 = dst + (if (base_offset == 0) @as(usize, 8) else 0);

    switch (mode) {
        0 => try processLzRunsType0(lz, dst_run_start, dst_end, dst_start),
        1 => try processLzRunsType1(lz, dst_run_start, dst_end, dst_start, scratch_free, scratch_end),
        else => return error.BadMode,
    }
}

/// Fallback allocator for the Type 1 token array when the scratch buffer
/// is exhausted. Uses libc malloc/free via Zig's c_allocator — matches C#'s
/// `NativeMemory.Alloc` and avoids the ~5µs syscall cost of page_allocator
/// (VirtualAlloc/VirtualFree). For a 100 MB L9 decode we hit the fallback
/// ~12,000 times; VTune Hotspots showed page_allocator at 13.8% of CPU.
const fallback_allocator = std.heap.c_allocator;

// ────────────────────────────────────────────────────────────
//  Type 0 — delta-coded literals, single-pass
// ────────────────────────────────────────────────────────────

fn processLzRunsType0(
    lz: *const high.HighLzTable,
    dst_in: [*]u8,
    dst_end: [*]u8,
    dst_start: [*]const u8,
) DecodeError!void {
    var cmd_stream = lz.cmd_stream;
    const cmd_stream_end = lz.cmd_stream + lz.cmd_stream_size;
    var len_stream: [*]align(1) const i32 = lz.len_stream;
    const len_stream_end: [*]align(1) const i32 = lz.len_stream + lz.len_stream_size;
    var lit_stream = lz.lit_stream;
    const lit_stream_end = lz.lit_stream + lz.lit_stream_size;
    var offs_stream: [*]align(1) const i32 = lz.offs_stream;
    const offs_stream_end: [*]align(1) const i32 = lz.offs_stream + lz.offs_stream_size;

    var dst = dst_in;
    const dst_safe_end: [*]u8 = if (@intFromPtr(dst_end) >= @intFromPtr(dst) + safe_space)
        dst_end - safe_space
    else
        dst_in;

    // Recent offsets carousel. Slots 3-5 are active; 0-2 are scratch for rotation.
    var recent_offsets: [7]i32 = @splat(0);
    const init_recent: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
    recent_offsets[3] = init_recent;
    recent_offsets[4] = init_recent;
    recent_offsets[5] = init_recent;
    var last_offset: i32 = init_recent;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const command_byte: u32 = cmd_stream[0];
        cmd_stream += 1;

        var literal_length: u32 = command_byte & 0x3;
        const offset_index: u32 = command_byte >> 6;
        const match_length: u32 = (command_byte >> 2) & 0xF;

        // Branchless long-literal decode.
        const speculative_long: u32 = @bitCast(len_stream[0]);
        if (literal_length == 3) {
            literal_length = speculative_long;
            len_stream += 1;
        }

        // Speculative offs read.
        recent_offsets[6] = offs_stream[0];

        const lit_delta_offset: i32 = last_offset;

        const picked: i32 = recent_offsets[offset_index + 3];
        recent_offsets[offset_index + 3] = recent_offsets[offset_index + 2];
        recent_offsets[offset_index + 2] = recent_offsets[offset_index + 1];
        recent_offsets[offset_index + 1] = recent_offsets[offset_index + 0];
        recent_offsets[3] = picked;
        last_offset = picked;

        if (offset_index == 3) offs_stream += 1;

        const actual_match_len: u32 = blk: {
            if (match_length != 15) break :blk match_length + 2;
            const extra: u32 = @bitCast(len_stream[0]);
            len_stream += 1;
            break :blk 14 + extra;
        };

        const lit_len_i: usize = @intCast(literal_length);
        const match_len_i: usize = @intCast(actual_match_len);
        const off_i: i32 = picked;
        const lit_off_i: i32 = lit_delta_offset;

        // Prefetch the match source for THIS iteration — the literal copy
        // that follows gives ~10-100 cycles for the line to arrive in L1.
        // C# does the same; see High.LzDecoder.ProcessLzRuns_Type0.
        {
            const pre_addr: usize = @intFromPtr(dst) + lit_len_i +% @as(usize, @bitCast(@as(isize, off_i)));
            @prefetch(@as([*]const u8, @ptrFromInt(pre_addr)), .{ .rw = .read, .locality = 3, .cache = .data });
        }

        if (@intFromPtr(dst + lit_len_i + match_len_i) >= @intFromPtr(dst_safe_end)) {
            // Slow exact-copy tail.
            if (@intFromPtr(dst + lit_len_i + match_len_i) > @intFromPtr(dst_end)) return error.OutputTruncated;

            copyLiteralAddExact(dst, lit_stream, lit_off_i, lit_len_i);
            dst += lit_len_i;
            lit_stream += lit_len_i;

            const match_addr: usize = @intFromPtr(dst) +% @as(usize, @bitCast(@as(isize, off_i)));
            if (match_addr < @intFromPtr(dst_start)) return error.OutputTruncated;
            const match_ptr: [*]const u8 = @ptrFromInt(match_addr);
            copyMatchExact(dst, match_ptr, match_len_i);
            dst += match_len_i;
        } else {
            // Fast path — wide copies.
            const match_src_post_lit: usize = @intFromPtr(dst + lit_len_i) +% @as(usize, @bitCast(@as(isize, off_i)));
            if (match_src_post_lit < @intFromPtr(dst_start)) return error.OutputTruncated;

            // Cascading delta-literal copy: the 80% case has ≤ 2 literals,
            // so the first copy64Add handles it with zero branches taken.
            // 8- and 16-byte literals fall through to the nested `if`s. Only
            // literals > 24 bytes enter the 8-byte-stride loop — much rarer
            // than the short-token case, and then still wide rather than
            // byte-wise.
            const lit_src_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% @as(usize, @bitCast(@as(isize, lit_off_i))));
            copy.copy64Add(dst, lit_stream, lit_src_ptr);
            if (literal_length > 8) {
                copy.copy64Add(dst + 8, lit_stream + 8, lit_src_ptr + 8);
                if (literal_length > 16) {
                    copy.copy64Add(dst + 16, lit_stream + 16, lit_src_ptr + 16);
                    if (literal_length > 24) {
                        var remaining: usize = lit_len_i;
                        var dd = dst;
                        var ss = lit_stream;
                        var ee = lit_src_ptr;
                        while (remaining > 24) {
                            copy.copy64Add(dd + 24, ss + 24, ee + 24);
                            remaining -= 8;
                            dd += 8;
                            ss += 8;
                            ee += 8;
                        }
                    }
                }
            }
            dst += lit_len_i;
            lit_stream += lit_len_i;

            // Match copy.
            const match_addr: usize = @intFromPtr(dst) +% @as(usize, @bitCast(@as(isize, off_i)));
            const match_ptr: [*]const u8 = @ptrFromInt(match_addr);
            copy.copy64(dst, match_ptr);
            copy.copy64(dst + 8, match_ptr + 8);
            if (match_length == 15 and match_len_i > 16) {
                copy.wildCopy16(dst + 16, match_ptr + 16, dst + match_len_i);
            }
            dst += match_len_i;
        }
    }

    if (@intFromPtr(offs_stream) != @intFromPtr(offs_stream_end) or
        @intFromPtr(len_stream) != @intFromPtr(len_stream_end))
    {
        return error.StreamMismatch;
    }

    var trailing: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
    if (trailing != @intFromPtr(lit_stream_end) - @intFromPtr(lit_stream)) return error.StreamMismatch;

    // Trailing literal copy with delta-add (exact).
    const off_usize: usize = @bitCast(@as(isize, last_offset));
    while (trailing >= 8) {
        const lit_src: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
        copy.copy64Add(dst, lit_stream, lit_src);
        dst += 8;
        lit_stream += 8;
        trailing -= 8;
    }
    while (trailing > 0) : (trailing -= 1) {
        const delta_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
        dst[0] = lit_stream[0] +% delta_ptr[0];
        dst += 1;
        lit_stream += 1;
    }
}

fn copyLiteralAddExact(dst_in: [*]u8, src_in: [*]const u8, delta_off: i32, length: usize) void {
    var dst = dst_in;
    var src = src_in;
    var remaining = length;
    const off_usize: usize = @bitCast(@as(isize, delta_off));
    while (remaining >= 8) {
        const delta_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
        copy.copy64Add(dst, src, delta_ptr);
        dst += 8;
        src += 8;
        remaining -= 8;
    }
    while (remaining > 0) : (remaining -= 1) {
        const delta_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dst) +% off_usize);
        dst[0] = src[0] +% delta_ptr[0];
        dst += 1;
        src += 1;
    }
}

fn copyMatchExact(dst_in: [*]u8, src_in: [*]const u8, length: usize) void {
    // Match copies may overlap when offset < length; must copy byte-by-byte
    // once we're past the overlap-safe zone.
    var dst = dst_in;
    var src = src_in;
    var remaining = length;
    while (remaining > 0) : (remaining -= 1) {
        dst[0] = src[0];
        dst += 1;
        src += 1;
    }
}

// ────────────────────────────────────────────────────────────
//  Type 1 — raw literals, two-phase
// ────────────────────────────────────────────────────────────

const LzToken = extern struct {
    dst_pos: i32,
    offset: i32,
    lit_len: i32,
    match_len: i32,
};

fn resolveTokens(
    lz: *const high.HighLzTable,
    tokens: [*]LzToken,
    dst_size: i32,
    offs_final_out: *[*]align(1) const i32,
    len_final_out: *[*]align(1) const i32,
) DecodeError!u32 {
    var cmd_stream = lz.cmd_stream;
    const cmd_stream_end = lz.cmd_stream + lz.cmd_stream_size;
    var len_stream: [*]align(1) const i32 = lz.len_stream;
    var offs_stream: [*]align(1) const i32 = lz.offs_stream;

    // 3-entry recent-offset LIFO held in registers, not memory. The
    // original C# port mirrored a 7-element stack array indexed by
    // `offset_index + N` — but the data-dependent index forced the
    // compiler to keep the array in stack memory, serializing the
    // shuffle through a 5-step load/store dependency chain. VTune
    // Hotspots showed ~65% of resolveTokens stalled on that chain.
    //
    // Truth table for the post-shuffle state given the original
    // semantics (recentOffsets[3..5] are MRU/2nd/3rd, slot 6 is the
    // newly-read offset, oi selects which to promote):
    //   oi=0: pick=ro3, no change         (next: ro3, ro4, ro5)
    //   oi=1: pick=ro4, swap MRU/2nd      (next: ro4, ro3, ro5)
    //   oi=2: pick=ro5, 3-cycle           (next: ro5, ro3, ro4)
    //   oi=3: pick=new, push new          (next: new, ro3, ro4)
    var ro3: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
    var ro4: i32 = ro3;
    var ro5: i32 = ro3;

    var dst_pos: i32 = 0;
    var token_index: u32 = 0;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const command_byte: u32 = cmd_stream[0];
        cmd_stream += 1;
        var literal_length: u32 = command_byte & 0x3;
        const offset_index: u32 = command_byte >> 6;
        const match_length: u32 = (command_byte >> 2) & 0xF;

        // Speculative long-literal decode.
        const speculative_long: u32 = @bitCast(len_stream[0]);
        if (literal_length == 3) {
            literal_length = speculative_long;
            len_stream += 1;
        }

        // Speculative offset load — always read offs_stream[0]; only
        // consume (advance) when oi == 3. Mirrors the C# pattern.
        const new_off: i32 = offs_stream[0];

        const picked: i32 = switch (offset_index) {
            0 => ro3,
            1 => ro4,
            2 => ro5,
            else => new_off,
        };
        // Compute next state without an array store dependency.
        const next_ro4: i32 = if (offset_index == 0) ro4 else ro3;
        const next_ro5: i32 = if (offset_index < 2) ro5 else ro4;
        ro3 = picked;
        ro4 = next_ro4;
        ro5 = next_ro5;

        if (offset_index == 3) offs_stream += 1;

        const actual_match_len: i32 = blk: {
            if (match_length != 15) break :blk @as(i32, @intCast(match_length + 2));
            const extra: i32 = len_stream[0];
            len_stream += 1;
            break :blk 14 + extra;
        };

        tokens[token_index] = .{
            .dst_pos = dst_pos,
            .offset = picked,
            .lit_len = @intCast(literal_length),
            .match_len = actual_match_len,
        };
        token_index += 1;

        dst_pos += @as(i32, @intCast(literal_length)) + actual_match_len;
        if (dst_pos > dst_size) return error.OutputTruncated;
    }

    offs_final_out.* = offs_stream;
    len_final_out.* = len_stream;
    return token_index;
}

fn processLzRunsType1(
    lz: *const high.HighLzTable,
    dst_in: [*]u8,
    dst_end: [*]u8,
    dst_start: [*]const u8,
    scratch_free: [*]u8,
    scratch_end: [*]u8,
) DecodeError!void {
    var dst = dst_in;
    var lit_stream = lz.lit_stream;
    const lit_stream_end = lz.lit_stream + lz.lit_stream_size;
    const offs_stream_end = lz.offs_stream + lz.offs_stream_size;
    const len_stream_end = lz.len_stream + lz.len_stream_size;

    const token_count = lz.cmd_stream_size;
    var fallback_tokens: ?[]LzToken = null;
    defer if (fallback_tokens) |t| fallback_allocator.free(t);

    if (token_count > 0) {
        const token_bytes: usize = @as(usize, token_count) * @sizeOf(LzToken);
        const tokens: [*]LzToken = blk: {
            if (@intFromPtr(scratch_free) + token_bytes <= @intFromPtr(scratch_end)) {
                // Align scratch_free to 16 bytes.
                const aligned = (@intFromPtr(scratch_free) + 15) & ~@as(usize, 15);
                if (aligned + token_bytes > @intFromPtr(scratch_end)) {
                    // Fall through to allocator path.
                } else {
                    break :blk @ptrFromInt(aligned);
                }
            }
            const slice = fallback_allocator.alignedAlloc(LzToken, .fromByteUnits(16), token_count) catch return error.OutputTruncated;
            fallback_tokens = slice;
            break :blk slice.ptr;
        };

        var offs_final: [*]align(1) const i32 = undefined;
        var len_final: [*]align(1) const i32 = undefined;
        const resolved = try resolveTokens(lz, tokens, @intCast(@intFromPtr(dst_end) - @intFromPtr(dst)), &offs_final, &len_final);

        if (@intFromPtr(offs_final) != @intFromPtr(offs_stream_end) or
            @intFromPtr(len_final) != @intFromPtr(len_stream_end))
        {
            return error.StreamMismatch;
        }

        try executeTokensType1(tokens, resolved, dst, dst_end, dst_start, &lit_stream);

        if (resolved > 0) {
            const last = tokens[resolved - 1];
            const advance: usize = @intCast(last.dst_pos + last.lit_len + last.match_len);
            dst += advance;
        }
    }

    // Trailing literal copy (raw).
    var trailing: usize = @intFromPtr(dst_end) - @intFromPtr(dst);
    if (trailing != @intFromPtr(lit_stream_end) - @intFromPtr(lit_stream)) return error.StreamMismatch;

    while (trailing >= 64) {
        copy.copy64Bytes(dst, lit_stream);
        dst += 64;
        lit_stream += 64;
        trailing -= 64;
    }
    while (trailing >= 8) {
        copy.copy64(dst, lit_stream);
        dst += 8;
        lit_stream += 8;
        trailing -= 8;
    }
    while (trailing > 0) : (trailing -= 1) {
        dst[0] = lit_stream[0];
        dst += 1;
        lit_stream += 1;
    }
}

/// Prefetch this far ahead (in tokens) so the match source cache line is
/// resident in L1 by the time we reach it. C# uses 128 based on an Arrow
/// Lake sweep (32→1376, 64→1547, 128→1541, 256→1514 MB/s). We match it.
const prefetch_ahead: u32 = 128;

fn executeTokensType1(
    tokens: [*]const LzToken,
    token_count: u32,
    dst_in: [*]u8,
    dst_end: [*]u8,
    dst_start: [*]const u8,
    lit_stream_inout: *[*]const u8,
) DecodeError!void {
    const dst_base = dst_in;
    var lit_stream = lit_stream_inout.*;

    const dst_safe_end: [*]u8 = if (@intFromPtr(dst_end) >= @intFromPtr(dst_in) + safe_space)
        dst_end - safe_space
    else
        dst_in;

    var i: u32 = 0;
    while (i < token_count) : (i += 1) {
        // Match-source prefetch for a token ~prefetch_ahead steps ahead.
        const prefetch_index: u32 = i + prefetch_ahead;
        if (prefetch_index < token_count) {
            const pt = tokens[prefetch_index];
            const pre_base: usize = @intFromPtr(dst_base) + @as(usize, @intCast(pt.dst_pos)) + @as(usize, @intCast(pt.lit_len));
            const pre_addr: usize = pre_base +% @as(usize, @bitCast(@as(isize, pt.offset)));
            const p0: [*]const u8 = @ptrFromInt(pre_addr);
            @prefetch(p0, .{ .rw = .read, .locality = 3, .cache = .data });
            @prefetch(p0 + 64, .{ .rw = .read, .locality = 3, .cache = .data });
        }

        const t = tokens[i];
        const lit_len: usize = @intCast(t.lit_len);
        const match_len: usize = @intCast(t.match_len);
        const offset: i32 = t.offset;

        const dst_token_start: [*]u8 = dst_base + @as(usize, @intCast(t.dst_pos));
        const dst_after_all: [*]u8 = dst_token_start + lit_len + match_len;

        if (@intFromPtr(dst_after_all) > @intFromPtr(dst_safe_end)) {
            // Slow exact path for trailing tokens.
            if (@intFromPtr(dst_after_all) > @intFromPtr(dst_end)) return error.OutputTruncated;
            var d = dst_token_start;
            var lrem = lit_len;
            while (lrem > 0) : (lrem -= 1) {
                d[0] = lit_stream[0];
                d += 1;
                lit_stream += 1;
            }
            const match_addr: usize = @intFromPtr(d) +% @as(usize, @bitCast(@as(isize, offset)));
            if (match_addr < @intFromPtr(dst_start)) return error.OutputTruncated;
            var s: [*]const u8 = @ptrFromInt(match_addr);
            var mrem = match_len;
            while (mrem > 0) : (mrem -= 1) {
                d[0] = s[0];
                d += 1;
                s += 1;
            }
            continue;
        }

        // Fast path: 16-byte SIMD literal copies. Halves the instruction
        // count vs the original 8-byte cascade — the inner loop body
        // shrinks enough to stay in the DSB (decoded uop cache) which
        // delivers 6 uops/cycle vs the legacy decoder's 5 inst/cycle.
        // Safe-space padding allows the 16-byte overshoot for short
        // literals (we advance d/lit_stream by lit_len, not by 16).
        var d = dst_token_start;
        copy.copy16(d, lit_stream);
        if (lit_len > 16) {
            copy.copy16(d + 16, lit_stream + 16);
            if (lit_len > 32) {
                var remaining = lit_len;
                var dd = d + 32;
                var ss = lit_stream + 32;
                while (remaining > 32) {
                    copy.copy16(dd, ss);
                    remaining -= 16;
                    dd += 16;
                    ss += 16;
                }
            }
        }
        d += lit_len;
        lit_stream += lit_len;

        const match_addr: usize = @intFromPtr(d) +% @as(usize, @bitCast(@as(isize, offset)));
        if (match_addr < @intFromPtr(dst_start)) return error.OutputTruncated;
        const match_ptr: [*]const u8 = @ptrFromInt(match_addr);
        copy.copy64(d, match_ptr);
        copy.copy64(d + 8, match_ptr + 8);
        if (match_len > 16) {
            copy.wildCopy16(d + 16, match_ptr + 16, d + match_len);
        }
    }

    lit_stream_inout.* = lit_stream;
}
