//! Per-byte cleanness analyzer for Fast (L1-L5) compressed streams.
//!
//! Mirrors `fast_lz_decoder.processLzRuns` / `processModeImpl` but, instead
//! of writing decoded bytes, computes a per-byte taint bitmap for each
//! sub-chunk:
//!   * 0 = clean — byte's transitive dependency tree is contained entirely
//!         within this sub-chunk and grounded in literals
//!   * 1 = tainted — byte was produced by a match whose source range
//!         crossed the sub-chunk boundary, OR transitively derived from
//!         such a byte via intra-chunk match copies
//!
//! Used to estimate the clean fraction `C` for a hypothetical speculative
//! parallel decoder. Walks the same token dispatch as the real decoder
//! but produces stats instead of output bytes.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const fast = @import("fast_lz_decoder.zig");
const high = @import("high_lz_decoder.zig");
const entropy = @import("entropy_decoder.zig");
const FastLzTable = fast.FastLzTable;
const HighLzTable = high.HighLzTable;

pub const SubChunkStats = struct {
    /// Number of output bytes in this sub-chunk.
    total_bytes: u32,
    /// Number of bytes whose dependency tree is fully intra-chunk
    /// (transitively grounded in literals within this sub-chunk).
    clean_bytes: u32,
    /// Position within the sub-chunk of the first byte that was tainted
    /// by a cross-chunk reference (null if none).
    first_cross_chunk_pos: ?u32,
    /// Total number of tokens in this sub-chunk.
    token_count: u32,
    /// Count of tokens whose match source crosses the sub-chunk boundary.
    cross_chunk_token_count: u32,
};

pub const FileStats = struct {
    sub_chunks: std.ArrayList(SubChunkStats),
    total_bytes: u64,
    total_clean: u64,

    /// Token-dependency-DAG stats. For each match token T, T.round =
    /// 1 + max(round of any earlier token whose target overlaps T.source).
    /// Literal bytes contribute round 0 (no dep). Critical path = max
    /// round across all match tokens.
    total_match_tokens: u64,
    /// `round_histogram[r]` = number of match tokens at round r.
    /// Tracks rounds up to 65535 (anything deeper saturates).
    round_histogram: [65536]u64,

    pub fn deinit(self: *FileStats, allocator: std.mem.Allocator) void {
        self.sub_chunks.deinit(allocator);
    }

    pub fn cleanFraction(self: FileStats) f64 {
        if (self.total_bytes == 0) return 0;
        return @as(f64, @floatFromInt(self.total_clean)) / @as(f64, @floatFromInt(self.total_bytes));
    }

    /// Critical path = highest round number that has at least one token.
    pub fn criticalPath(self: FileStats) u32 {
        var i: u32 = @as(u32, self.round_histogram.len) - 1;
        while (true) : (i -%= 1) {
            if (self.round_histogram[i] != 0) return i;
            if (i == 0) return 0;
        }
    }
};

const extended_length_threshold: u32 = 251;
const safe_space: usize = 64;

// ────────────────────────────────────────────────────────────
//  Partition analyzer (earliestLiteral + 2-thread split stats)
//
//  Computes, for every match token, the file position of the earliest
//  literal byte in the token's transitive dependency tree. Uses this to
//  bucket tokens into 4 categories at a chosen partition position X:
//
//    * Pre-X (target_start < X):
//        - prefix_pre: target_end <= X — token entirely below the cut
//        - prefix_straddle: target_start < X < target_end — token spans X
//    * Post-X (target_start >= X):
//        - threadA_post: earliestLiteral < X — depends on something below X
//        - threadB:      earliestLiteral >= X — entirely independent of below-X
//
//  ThreadB tokens can run in parallel with everything because all their
//  dependencies are ≥ X. ThreadA-post tokens must wait for ThreadB to
//  finish before running, because some of their reads might be from
//  ThreadB writes.
// ────────────────────────────────────────────────────────────

pub const PartitionStats = struct {
    total_match_tokens: u64,
    total_match_bytes: u64,
    partition_x: u64,

    prefix_tokens: u64,         // target entirely < X
    prefix_bytes: u64,
    straddle_tokens: u64,       // target spans X
    straddle_bytes: u64,
    threadA_post_tokens: u64,   // target >= X, earliestLiteral < X
    threadA_post_bytes: u64,
    threadB_tokens: u64,        // target >= X, earliestLiteral >= X
    threadB_bytes: u64,

    // Closure / cross-sub-chunk stats.
    //
    // A sub-chunk is a 128 KB decode unit (constants.chunk_size). A match
    // token is "cross-sub-chunk" if its src range starts before the
    // sub-chunk it lives in.  The closure is the transitive set of tokens
    // whose output is read (directly or indirectly) by a cross-sub-chunk
    // seed. See analyzeFilePartition for the walk.
    cross_chunk_seed_tokens: u64,
    closure_tokens: u64,             // size of transitive closure
    closure_depth_max: u32,          // longest BFS hop count from seeds
    low_earliest_tokens: u64,        // tokens with earliest < own sub_chunk_start

    // Phase-1 PoC timings (ns).
    //
    // `phase1_execute_only_ns`: iterate the FULL tokens list, check the
    // closure bit, execute for closure members. Dominated by list
    // iteration overhead (O(N_total) not O(N_closure)).
    //
    // `phase1_execute_compact_ns`: iterate ONLY a compact list of
    // closure tokens (size = N_closure). This is the true minimum cost
    // of executing phase 1 given pre-computed positions. O(N_closure).
    //
    // `phase1_execute_bytes`: total match bytes actually moved.
    phase1_execute_only_ns: u64,
    phase1_execute_compact_ns: u64,
    phase1_execute_bytes: u64,
};

const TokenInfo = struct {
    target_start: u64,
    length: u32,
    earliest: u32,
    // Src-range start in whole-file coordinates. i64 because matches that
    // reach before file position 0 are technically invalid but we clamp
    // rather than error out.
    src_start: i64,
    // Start of the 128 KB sub-chunk containing this token (whole-file
    // coordinate). Used to classify cross-sub-chunk seeds and to bound
    // closure membership to "reads from a prior sub-chunk".
    sub_chunk_start: u64,
};

/// Phase-1 sidecar operation: a closure match that phase 1 executes by
/// copying `length` bytes from `dst[src_start..]` to `dst[target_start..]`.
/// Supports overlapping src/dst ranges (byte-by-byte forward copy).
pub const ClosureMatchOp = struct {
    target_start: u64,
    src_start: i64,
    length: u32,
};

/// Phase-1 sidecar operation: a single literal byte that phase 1 must
/// place at `position` in dst. `byte_value` is captured from the
/// reference decode (a real encoder would compute it at compress time
/// from the literal_stream + cursor snapshots).
pub const ClosureLiteralByte = struct {
    position: u64,
    byte_value: u8,
};

/// Complete phase-1 sidecar for a file. Built by `buildPpocSidecar`.
/// Owns its internal arrays; caller is responsible for calling deinit.
pub const PpocSidecar = struct {
    match_ops: std.ArrayList(ClosureMatchOp),
    literal_bytes: std.ArrayList(ClosureLiteralByte),
    /// Total distinct byte positions phase 1 needs to populate.
    /// = sum of match_lengths + count of literal_bytes (with double-counts
    /// when match outputs overlap, which happens for interior closure
    /// members whose output IS the src of a later closure member).
    total_positions: u64,

    pub fn deinit(self: *PpocSidecar, allocator: std.mem.Allocator) void {
        self.match_ops.deinit(allocator);
        self.literal_bytes.deinit(allocator);
    }
};

/// Compute earliestLiteral for one match token, propagate per-byte
/// `byte_earliest`, stamp the producer map, append the token to the
/// collection. The collected list is bucketed post-hoc by
/// `analyzeFilePartition` once X has been determined.
///
/// `producer_map[p]` is left at u32::MAX for literal-produced bytes and
/// set to the token's index for match-produced bytes. This is the
/// lookup the closure BFS uses when walking backward from cross-chunk
/// seeds.
fn partitionCollectMatch(
    allocator: std.mem.Allocator,
    byte_earliest: []u32,
    producer_map: []u32,
    sub_chunk_start: u64,
    dst_file_pos: u64,
    recent_offs: i64,
    length: usize,
    file_capacity: u64,
    tokens: *std.ArrayList(TokenInfo),
) !void {
    if (length == 0) return;

    const target_start: u64 = dst_file_pos;
    const target_end: u64 = dst_file_pos + length;

    const src_pos_signed: i64 = @as(i64, @intCast(dst_file_pos)) + recent_offs;
    var earliest: u32 = std.math.maxInt(u32);

    if (src_pos_signed < 0) {
        earliest = 0;
    } else {
        const src_start_u: usize = @intCast(src_pos_signed);
        const dist: usize = @intCast(-recent_offs);
        const real_src_len: usize = @min(length, dist);
        const src_end: usize = @min(src_start_u + real_src_len, @as(usize, @intCast(file_capacity)));
        if (src_start_u < @as(usize, @intCast(file_capacity))) {
            var i: usize = src_start_u;
            while (i < src_end) : (i += 1) {
                if (byte_earliest[i] < earliest) earliest = byte_earliest[i];
            }
        }
    }

    const token_index: u32 = @intCast(tokens.items.len);
    const tgt_end_clamped = @min(target_end, file_capacity);
    if (target_start < file_capacity) {
        var i: usize = @intCast(target_start);
        const e: usize = @intCast(tgt_end_clamped);
        while (i < e) : (i += 1) {
            byte_earliest[i] = earliest;
            producer_map[i] = token_index;
        }
    }

    try tokens.append(allocator, .{
        .target_start = target_start,
        .length = @intCast(length),
        .earliest = earliest,
        .src_start = src_pos_signed,
        .sub_chunk_start = sub_chunk_start,
    });
}

// ── Fast walker, partition mode ──────────────────────────────────────

fn partitionFastSubChunk(
    comptime mode: enum { delta, raw },
    allocator: std.mem.Allocator,
    lz: *FastLzTable,
    dst_size: usize,
    saved_dist: *i32,
    start_off: usize,
    file_pos_base: u64,
    sub_chunk_start_abs: u64,
    byte_earliest: []u32,
    producer_map: []u32,
    file_capacity: u64,
    tokens: *std.ArrayList(TokenInfo),
    overcopy_leaves: *std.ArrayList(u64),
) !void {
    _ = mode;
    var dst_off: usize = start_off;
    var recent_offs: i64 = saved_dist.*;

    // Track the maximum dst position any token in this block actually
    // writes to. The Fast decoder uses vectorised `copy64` / `copy16`
    // patterns that write more bytes than the token's logical length
    // (for performance), advancing dst only by the logical length.
    // Within a block, subsequent tokens overwrite the overshoot
    // harmlessly. But at block boundaries — especially the outer
    // chunk boundary where parallel workers split the work — that
    // overshoot can corrupt the next chunk's output if the next
    // chunk's worker has already written there.
    //
    // We track `max_write_end` so that, at the end of the block, we
    // can emit guard leaves for any bytes in [dst_size, max_write_end)
    // that phase 1 will populate from the reference buffer. Phase 1
    // re-run after phase 2 workers complete then restores any
    // overshoot-corrupted bytes to their correct values.
    var max_write_end: usize = start_off;

    var cmd_stream = lz.cmd_start;
    const cmd_stream_end = lz.cmd_end;
    var length_stream = lz.length_stream;
    var off16_stream: [*]align(1) const u16 = lz.off16_start;
    var off32_stream: [*]align(1) const u32 = lz.off32_start;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        if (cmd >= 24) {
            const literal_length: usize = cmd & 7;
            const use_new_dist: bool = (cmd & 0x80) == 0;
            // Literals at file_pos_base+dst_off..+literal_length: each is its
            // own leaf, byte_earliest = own position.
            if (literal_length > 0) {
                var i: usize = 0;
                const base_pos: u64 = file_pos_base + dst_off;
                while (i < literal_length) : (i += 1) {
                    const p = base_pos + i;
                    if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
                }
            }
            // Short-token write extent: the literal copy writes 8
            // bytes at dst_off (dst then advances by lit_len), then
            // the match copy writes 16 bytes at dst_off + lit_len.
            // The match copy dominates since lit_len <= 7.
            const short_write_end = dst_off + literal_length + 16;
            if (short_write_end > max_write_end) max_write_end = short_write_end;
            dst_off += literal_length;

            if (use_new_dist) {
                const new_dist: i64 = off16_stream[0];
                recent_offs = -new_dist;
                off16_stream = @ptrFromInt(@intFromPtr(off16_stream) + 2);
            }
            const match_length: usize = (cmd >> 3) & 0xF;
            try partitionCollectMatch(allocator, byte_earliest, producer_map, sub_chunk_start_abs, file_pos_base + dst_off, recent_offs, match_length, file_capacity, tokens);
            dst_off += match_length;
        } else if (cmd > 2) {
            const length: usize = cmd + 5;
            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            try partitionCollectMatch(allocator, byte_earliest, producer_map, sub_chunk_start_abs, file_pos_base + dst_off, dist_match, length, file_capacity, tokens);
            // Medium match write extent: decoder does two copy16 calls
            // = 32 bytes starting at dst_off.
            const mm_write_end = dst_off + 32;
            if (mm_write_end > max_write_end) max_write_end = mm_write_end;
            dst_off += length;
            // Match the real decoder: recent_offs = match_ptr - dst, which
            // equals dist_match (the computed negative distance). Earlier
            // buggy version set this to -1 which corrupted subsequent
            // reuse-offset tokens.
            recent_offs = dist_match;
        } else if (cmd == 0) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 64;
            // Long literal run — each byte is its own leaf.
            var i: usize = 0;
            const base_pos: u64 = file_pos_base + dst_off;
            while (i < length) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            // Long literal run decoder loop does ceil(length/16) * 16
            // bytes of copy16 writes before the overshoot correction.
            const llr_write_end = dst_off + ((length + 15) / 16) * 16;
            if (llr_write_end > max_write_end) max_write_end = llr_write_end;
            dst_off += length;
        } else if (cmd == 1) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 91;

            const off16: u16 = off16_stream[0];
            off16_stream += 1;
            recent_offs = -@as(i64, off16);
            try partitionCollectMatch(allocator, byte_earliest, producer_map, sub_chunk_start_abs, file_pos_base + dst_off, recent_offs, length, file_capacity, tokens);
            // Long match (cmd==1) decoder uses `while (remaining > 0)
            // { copy64; copy64; d += 16; remaining -= 16; }`, writing
            // ceil(length/16) * 16 bytes before dst advances by length.
            const lm1_write_end = dst_off + ((length + 15) / 16) * 16;
            if (lm1_write_end > max_write_end) max_write_end = lm1_write_end;
            dst_off += length;
        } else {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 29;

            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            try partitionCollectMatch(allocator, byte_earliest, producer_map, sub_chunk_start_abs, file_pos_base + dst_off, dist_match, length, file_capacity, tokens);
            // Long match (cmd==2) decoder same pattern: ceil(length/16) * 16
            // bytes via a copy16 loop.
            const lm2_write_end = dst_off + ((length + 15) / 16) * 16;
            if (lm2_write_end > max_write_end) max_write_end = lm2_write_end;
            dst_off += length;
            // Match the real decoder: recent_offs = match_ptr - dst, which
            // equals dist_match.
            recent_offs = dist_match;
        }
    }

    // Trailing literals: bytes between dst_off and dst_size that come
    // AFTER the last cmd-stream token. The real decoder's trailing-
    // literal loop copies `dst_end - dst` bytes from lit_stream —
    // exactly, no overcopy (the 8-byte copy64 loop has a `>= 8`
    // guard and the byte-by-byte tail is exact). So trailing literals
    // don't contribute to max_write_end.
    if (dst_off < dst_size) {
        const trailing_start: u64 = file_pos_base + dst_off;
        const trailing_end: u64 = file_pos_base + dst_size;
        var p = trailing_start;
        while (p < trailing_end) : (p += 1) {
            if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
        }
    }

    // If the block's write operations extended past dst_size, emit
    // guard positions for [dst_size, max_write_end). Phase 1 will
    // populate them from the reference buffer so that a post-phase-2
    // re-run can restore any overcopy corruption.
    if (max_write_end > dst_size) {
        const overcopy: usize = max_write_end - dst_size;
        var d: usize = 0;
        while (d < overcopy) : (d += 1) {
            const p: u64 = file_pos_base + dst_size + d;
            if (p < file_capacity) {
                try overcopy_leaves.append(allocator, p);
            }
        }
    }

    saved_dist.* = @intCast(recent_offs);
    lz.length_stream = length_stream;
    lz.off16_start = off16_stream;
    lz.off32_start = off32_stream;
}

// Reuse the existing format walkers: copy/paste analyzeFastChunkPayload's
// shape but call partitionFastSubChunk and pass the partition state.
fn partitionFastChunkPayload(
    allocator: std.mem.Allocator,
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    byte_earliest: []u32,
    producer_map: []u32,
    file_capacity: u64,
    tokens: *std.ArrayList(TokenInfo),
    overcopy_leaves: *std.ArrayList(u64),
) !void {
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        // Sub-chunk absolute start (before block1/block2 split). This is
        // the boundary where `recent_offset` resets, so it's what a
        // cross-sub-chunk match is measured against.
        const sub_chunk_start_abs: u64 = running_dst_off + dst_off_in_chunk;
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);
        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            (@as(u32, chunk_src[src_pos + 2]));

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            // entropy-only sub-chunk: every byte is a literal at its own position.
            const base_pos: u64 = running_dst_off + dst_off_in_chunk;
            var i: usize = 0;
            while (i < dst_count) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;
        if (src_pos + src_used > chunk_src.len) return error.Truncated;
        if (src_used >= dst_count) {
            const base_pos: u64 = running_dst_off + dst_off_in_chunk;
            var i: usize = 0;
            while (i < dst_count) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        const fast_lz_table_size: usize = @sizeOf(FastLzTable);
        const lz_ptr: *FastLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + fast_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        var dst_slot: [*]u8 = dummy_dst.ptr;
        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try fast.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            &dst_slot,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        var saved_dist: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
        var dst_size_left: usize = dst_count;
        var iteration: u32 = 0;
        while (iteration != 2) : (iteration += 1) {
            var dst_size_cur: usize = dst_size_left;
            if (dst_size_cur > 0x10000) dst_size_cur = 0x10000;

            if (iteration == 0) {
                lz_ptr.off32_start = lz_ptr.off32_backing1;
                lz_ptr.off32_end = lz_ptr.off32_backing1 + lz_ptr.off32_count1;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset;
            } else {
                lz_ptr.off32_start = lz_ptr.off32_backing2;
                lz_ptr.off32_end = lz_ptr.off32_backing2 + lz_ptr.off32_count2;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset_end;
                lz_ptr.cmd_start += lz_ptr.cmd_stream2_offset;
            }
            // s_off = 8 only for the very first sub-chunk of the whole
            // frame (matches processLzRuns: `base_offset == 0 and iteration == 0`).
            // Previous versions used `iteration == 0` which incorrectly
            // applied an 8-byte skew to every sub-chunk's block1 after
            // the first, causing src_start computations to diverge from
            // the real decoder.
            const s_off: usize = if (sub_chunk_start_abs == 0 and iteration == 0) 8 else 0;
            const sub_chunk_file_pos: u64 = running_dst_off + dst_off_in_chunk + (dst_count - dst_size_left);

            // Initial 8-byte raw region at the very start of the file.
            if (s_off > 0) {
                var i: usize = 0;
                while (i < s_off) : (i += 1) {
                    const p = sub_chunk_file_pos + i;
                    if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
                }
            }

            if (mode == 0) {
                try partitionFastSubChunk(.delta, allocator, lz_ptr, dst_size_cur, &saved_dist, s_off, sub_chunk_file_pos, sub_chunk_start_abs, byte_earliest, producer_map, file_capacity, tokens, overcopy_leaves);
            } else {
                try partitionFastSubChunk(.raw, allocator, lz_ptr, dst_size_cur, &saved_dist, s_off, sub_chunk_file_pos, sub_chunk_start_abs, byte_earliest, producer_map, file_capacity, tokens, overcopy_leaves);
            }
            dst_size_left -= dst_size_cur;
            if (dst_size_left == 0) break;
        }

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

fn partitionFastBlock(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: u64,
    block_file_pos_base: u64,
    byte_earliest: []u32,
    producer_map: []u32,
    file_capacity: u64,
    tokens: *std.ArrayList(TokenInfo),
    overcopy_leaves: *std.ArrayList(u64),
) !void {
    const max_chunk: usize = 0x20000;
    const scratch_bytes: usize = constants.scratch_size;
    const scratch = try allocator.alignedAlloc(u8, .@"64", scratch_bytes);
    defer allocator.free(scratch);
    const dummy_decode_buf = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_decode_buf);
    const dummy_dst = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_dst);

    const is_sc = blk: {
        if (block_src.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src.len) return error.Truncated;
    const block_payload: []const u8 = block_src[0 .. block_src.len - prefix_size];

    var src_pos: usize = 0;
    var dst_remaining: u64 = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;
    var dst_off_running: u64 = 0;

    while (dst_remaining > 0) {
        const at_chunk_boundary = (dst_off_running & (constants.chunk_size - 1)) == 0;
        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_payload.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_payload[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const ihdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = @intCast(dst_remaining);

        if (ihdr.uncompressed) {
            const base_pos: u64 = block_file_pos_base + dst_off_running;
            var i: usize = 0;
            while (i < dst_this_chunk) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            src_pos += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const ch = block_header.parseChunkHeader(block_payload[src_pos..], ihdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            const base_pos: u64 = block_file_pos_base + dst_off_running;
            var i: usize = 0;
            while (i < dst_this_chunk) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_payload.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            const base_pos: u64 = block_file_pos_base + dst_off_running;
            var i: usize = 0;
            while (i < dst_this_chunk) : (i += 1) {
                const p = base_pos + i;
                if (p < file_capacity) byte_earliest[@intCast(p)] = @intCast(p);
            }
            src_pos += comp_size;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        try partitionFastChunkPayload(
            allocator,
            block_payload[src_pos..][0..comp_size],
            dst_this_chunk,
            block_file_pos_base + dst_off_running,
            scratch,
            dummy_decode_buf,
            dummy_dst,
            byte_earliest,
            producer_map,
            file_capacity,
            tokens,
            overcopy_leaves,
        );
        src_pos += comp_size;
        dst_remaining -= dst_this_chunk;
        dst_off_running += dst_this_chunk;
    }
}

/// Top-level: walk file in stream order, compute earliestLiteral per
/// token, bucket into partition stats.
///
/// X policy: the encoder picks X = target position of the (N/2)-th
/// token in stream order (i.e., the median token by stream count).
/// This matches the proposed design where the encoder bakes X into the
/// file once at compress time.
pub fn analyzeFilePartition(
    allocator: std.mem.Allocator,
    src: []const u8,
) !PartitionStats {
    var stats: PartitionStats = .{
        .total_match_tokens = 0,
        .total_match_bytes = 0,
        .partition_x = 0,
        .prefix_tokens = 0,
        .prefix_bytes = 0,
        .straddle_tokens = 0,
        .straddle_bytes = 0,
        .threadA_post_tokens = 0,
        .threadA_post_bytes = 0,
        .threadB_tokens = 0,
        .threadB_bytes = 0,
        .cross_chunk_seed_tokens = 0,
        .closure_tokens = 0,
        .closure_depth_max = 0,
        .low_earliest_tokens = 0,
        .phase1_execute_only_ns = 0,
        .phase1_execute_compact_ns = 0,
        .phase1_execute_bytes = 0,
    };

    const hdr = try frame.parseHeader(src);
    if (hdr.codec != .fast and hdr.codec != .turbo) return stats;
    const total_decomp: u64 = if (hdr.content_size) |cs| cs else 200 * 1024 * 1024;

    // Two-pass: pass 1 collects per-token (target_start, length, earliest,
    // src_start, sub_chunk_start) tuples by walking the file, and stamps
    // a producer_map that records which token produced each byte of the
    // output. Pass 2 picks X = (N/2)-th token's target_start, buckets
    // the tokens, and runs a BFS backward from cross-sub-chunk seeds to
    // compute the closure.
    const byte_earliest = try allocator.alloc(u32, @intCast(total_decomp));
    defer allocator.free(byte_earliest);
    @memset(byte_earliest, 0);

    const producer_map = try allocator.alloc(u32, @intCast(total_decomp));
    defer allocator.free(producer_map);
    @memset(producer_map, std.math.maxInt(u32));

    var tokens: std.ArrayList(TokenInfo) = .{};
    defer tokens.deinit(allocator);

    // Overcopy leaves. The walker appends positions past each block's
    // intended dst_size that the Fast decoder's vectorised copies can
    // overshoot into. `analyzeFilePartition` doesn't use these for
    // its partition stats, but the walker signature requires the
    // ArrayList; we let it grow and deinit it at function exit.
    var overcopy_leaves: std.ArrayList(u64) = .{};
    defer overcopy_leaves.deinit(allocator);

    var file_pos_running: u64 = 0;
    var src_pos: usize = hdr.header_size;
    while (src_pos < src.len) {
        if (src_pos + 4 > src.len) break;
        const first_word = std.mem.readInt(u32, src[src_pos..][0..4], .little);
        if (first_word == frame.end_mark) break;
        const bh = try frame.parseBlockHeader(src[src_pos..]);
        if (bh.isEndMark()) break;
        src_pos += 8;
        // v2: sidecar blocks carry no decompressable data — skip them.
        if (bh.parallel_decode_metadata) {
            src_pos += bh.compressed_size;
            continue;
        }
        if (bh.uncompressed) {
            const base_pos: u64 = file_pos_running;
            var i: u64 = 0;
            while (i < bh.decompressed_size) : (i += 1) {
                const p = base_pos + i;
                if (p < total_decomp) byte_earliest[@intCast(p)] = @intCast(p);
            }
            src_pos += bh.compressed_size;
            file_pos_running += bh.decompressed_size;
            continue;
        }
        const block_payload = src[src_pos..][0..bh.compressed_size];
        try partitionFastBlock(allocator, block_payload, bh.decompressed_size, file_pos_running, byte_earliest, producer_map, total_decomp, &tokens, &overcopy_leaves);
        src_pos += bh.compressed_size;
        file_pos_running += bh.decompressed_size;
    }

    // Pick X = target_start of the median token in stream order.
    const partition_x: u64 = blk: {
        if (tokens.items.len == 0) break :blk total_decomp / 2;
        const median_idx = tokens.items.len / 2;
        break :blk tokens.items[median_idx].target_start;
    };
    stats.partition_x = partition_x;

    // Pass 2a: bucket the tokens + count the cheap proxy (low-earliest).
    // Also identify seeds: tokens whose src_start < their own
    // sub_chunk_start (the match reaches before its sub-chunk's start).
    var seed_queue: std.ArrayList(u32) = .{};
    defer seed_queue.deinit(allocator);
    const in_closure = try allocator.alloc(u8, tokens.items.len);
    defer allocator.free(in_closure);
    @memset(in_closure, 0);
    const depth_of = try allocator.alloc(u32, tokens.items.len);
    defer allocator.free(depth_of);
    @memset(depth_of, 0);

    for (tokens.items, 0..) |t, idx| {
        stats.total_match_tokens += 1;
        stats.total_match_bytes += t.length;
        const target_end = t.target_start + t.length;
        if (target_end <= partition_x) {
            stats.prefix_tokens += 1;
            stats.prefix_bytes += t.length;
        } else if (t.target_start < partition_x) {
            stats.straddle_tokens += 1;
            stats.straddle_bytes += t.length;
        } else if (@as(u64, t.earliest) >= partition_x) {
            stats.threadB_tokens += 1;
            stats.threadB_bytes += t.length;
        } else {
            stats.threadA_post_tokens += 1;
            stats.threadA_post_bytes += t.length;
        }

        // Cheap proxy: token whose transitive dep tree reaches below
        // its own sub-chunk.  Correlated with closure membership but
        // not identical.
        if (@as(u64, t.earliest) < t.sub_chunk_start) {
            stats.low_earliest_tokens += 1;
        }

        // Seed: match with src_start physically before own sub_chunk_start
        // (ignoring src_start < 0 which means "reaches before file").
        const sub_start_signed: i64 = @intCast(t.sub_chunk_start);
        if (t.src_start < sub_start_signed) {
            stats.cross_chunk_seed_tokens += 1;
            if (in_closure[idx] == 0) {
                in_closure[idx] = 1;
                depth_of[idx] = 0;
                try seed_queue.append(allocator, @intCast(idx));
            }
        }
    }

    // Pass 2b: BFS backward from seeds. For each token in the closure,
    // walk its src range and add any producer token (match) we find.
    // Literals (producer_map[p] == MAX) are leaves and don't recurse.
    var head: usize = 0;
    while (head < seed_queue.items.len) : (head += 1) {
        const idx = seed_queue.items[head];
        const t = tokens.items[idx];
        const src_lo_s = t.src_start;
        const src_hi_s = t.src_start + @as(i64, @intCast(t.length));
        if (src_hi_s <= 0) continue;
        const src_lo: u64 = if (src_lo_s < 0) 0 else @intCast(src_lo_s);
        const src_hi: u64 = if (src_hi_s > @as(i64, @intCast(total_decomp)))
            total_decomp
        else
            @intCast(src_hi_s);
        if (src_lo >= src_hi) continue;

        const child_depth: u32 = depth_of[idx] + 1;
        var p: u64 = src_lo;
        while (p < src_hi) : (p += 1) {
            const producer = producer_map[@intCast(p)];
            if (producer == std.math.maxInt(u32)) continue; // literal leaf
            if (in_closure[producer] != 0) continue;
            in_closure[producer] = 1;
            depth_of[producer] = child_depth;
            try seed_queue.append(allocator, producer);
        }
    }

    // Roll up closure stats.
    for (in_closure, 0..) |flag, idx| {
        if (flag != 0) {
            stats.closure_tokens += 1;
            if (depth_of[idx] > stats.closure_depth_max) {
                stats.closure_depth_max = depth_of[idx];
            }
        }
    }

    // ── Phase-1 PoC: execute-only timing ──
    //
    // Iterate closure tokens in cmd_stream order (= dependency order for
    // within-sub-chunk and cross-sub-chunk producer→consumer edges) and
    // do each token's match copy into a scratch dst buffer. This is pure
    // memcpy work using pre-computed (target_start, src_start, length)
    // positions from the collected tokens — no cmd_stream parsing, no
    // cursor math.
    //
    // Run the loop N times (warmup + best-of-K) so we get a steady-state
    // measurement free of first-touch page fault overhead on the 100 MB
    // dst_scratch. First iteration pays the cost of committing pages
    // reached via random access; subsequent iterations find those pages
    // already in L3/DRAM.
    if (stats.closure_tokens > 0) {
        const dst_scratch = try allocator.alloc(u8, @intCast(total_decomp));
        defer allocator.free(dst_scratch);
        @memset(dst_scratch, 0);

        // Warmup pass: touches all src/target cache lines so subsequent
        // timed runs hit steady-state cost.
        var bytes_moved_warmup: u64 = 0;
        for (tokens.items, 0..) |t, idx| {
            if (in_closure[idx] == 0) continue;
            const length: usize = t.length;
            if (length == 0) continue;
            if (t.src_start < 0) continue;
            const src_u: u64 = @intCast(t.src_start);
            const tgt_u: u64 = t.target_start;
            if (src_u + length > total_decomp) continue;
            if (tgt_u + length > total_decomp) continue;
            const src_begin: usize = @intCast(src_u);
            const tgt_begin: usize = @intCast(tgt_u);
            var i: usize = 0;
            while (i < length) : (i += 1) {
                dst_scratch[tgt_begin + i] = dst_scratch[src_begin + i];
            }
            bytes_moved_warmup += length;
        }

        // Timed runs: take the best of 20 iterations. This version iterates
        // the FULL tokens list (all 7-16M entries) and branches on
        // in_closure[idx]. O(N_total).
        var best_ns: u64 = std.math.maxInt(u64);
        var bytes_moved: u64 = 0;
        var iter: u32 = 0;
        while (iter < 20) : (iter += 1) {
            bytes_moved = 0;
            var phase1_timer = try std.time.Timer.start();
            for (tokens.items, 0..) |t, idx| {
                if (in_closure[idx] == 0) continue;
                const length: usize = t.length;
                if (length == 0) continue;
                if (t.src_start < 0) continue;
                const src_u: u64 = @intCast(t.src_start);
                const tgt_u: u64 = t.target_start;
                if (src_u + length > total_decomp) continue;
                if (tgt_u + length > total_decomp) continue;
                const src_begin: usize = @intCast(src_u);
                const tgt_begin: usize = @intCast(tgt_u);
                var i: usize = 0;
                while (i < length) : (i += 1) {
                    dst_scratch[tgt_begin + i] = dst_scratch[src_begin + i];
                }
                bytes_moved += length;
            }
            const elapsed = phase1_timer.read();
            if (elapsed < best_ns) best_ns = elapsed;
        }
        stats.phase1_execute_only_ns = best_ns;
        stats.phase1_execute_bytes = bytes_moved;

        // Compact version: build a dedicated list of closure tokens, then
        // iterate only that list. O(N_closure). This is the true minimum
        // cost of executing phase 1 given pre-computed positions — what
        // you'd pay in a real decoder where the encoder emits the closure
        // as a separate compact stream rather than as a bit flag on a full
        // token list.
        var closure_compact: std.ArrayList(TokenInfo) = .{};
        defer closure_compact.deinit(allocator);
        for (tokens.items, 0..) |t, idx| {
            if (in_closure[idx] != 0) {
                try closure_compact.append(allocator, t);
            }
        }

        var best_compact_ns: u64 = std.math.maxInt(u64);
        iter = 0;
        while (iter < 20) : (iter += 1) {
            var phase1_timer = try std.time.Timer.start();
            for (closure_compact.items) |t| {
                const length: usize = t.length;
                if (length == 0) continue;
                if (t.src_start < 0) continue;
                const src_u: u64 = @intCast(t.src_start);
                const tgt_u: u64 = t.target_start;
                if (src_u + length > total_decomp) continue;
                if (tgt_u + length > total_decomp) continue;
                const src_begin: usize = @intCast(src_u);
                const tgt_begin: usize = @intCast(tgt_u);
                var i: usize = 0;
                while (i < length) : (i += 1) {
                    dst_scratch[tgt_begin + i] = dst_scratch[src_begin + i];
                }
            }
            const elapsed = phase1_timer.read();
            if (elapsed < best_compact_ns) best_compact_ns = elapsed;
        }
        stats.phase1_execute_compact_ns = best_compact_ns;
    }

    return stats;
}

/// Build a complete Phase-1 sidecar for the given compressed file.
///
/// Walks the file to collect match tokens and a producer_map, runs a
/// BFS backward from cross-sub-chunk seeds, and produces:
///   - `match_ops`: every closure match token as (target_start, src_start, length)
///   - `literal_bytes`: every literal byte position that lies within
///     the src range of any closure member, with byte value captured
///     from `dst_ref`
///
/// Callers are expected to have pre-decoded `dst_ref` using the normal
/// decoder (so it contains ground-truth bytes). A real encoder-side
/// implementation would compute literal byte values from `literal_stream`
/// + cursor snapshots at encode time; for the PoC we cheat and read them
/// from the reference dst.
pub fn buildPpocSidecar(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst_ref: []const u8,
) !PpocSidecar {
    var sidecar: PpocSidecar = .{
        .match_ops = .{},
        .literal_bytes = .{},
        .total_positions = 0,
    };
    errdefer sidecar.deinit(allocator);

    const hdr = try frame.parseHeader(src);
    if (hdr.codec != .fast and hdr.codec != .turbo) return sidecar;
    const total_decomp: u64 = if (hdr.content_size) |cs| cs else return sidecar;

    if (dst_ref.len < total_decomp) return error.OutputTooSmall;

    // Forward walk: populate byte_earliest, producer_map, tokens.
    const byte_earliest = try allocator.alloc(u32, @intCast(total_decomp));
    defer allocator.free(byte_earliest);
    @memset(byte_earliest, 0);

    const producer_map = try allocator.alloc(u32, @intCast(total_decomp));
    defer allocator.free(producer_map);
    @memset(producer_map, std.math.maxInt(u32));

    var tokens: std.ArrayList(TokenInfo) = .{};
    defer tokens.deinit(allocator);

    // Overcopy leaves. Each entry is a byte position past some block's
    // intended dst_size that the Fast decoder's `copy64`/`copy16`
    // patterns can touch during phase 2. Drained into the sidecar's
    // literal_bytes after the closure BFS so phase 1's post-phase-2
    // re-run can restore those positions to reference values if a
    // neighbouring worker's overshoot stomped them.
    var overcopy_leaves: std.ArrayList(u64) = .{};
    defer overcopy_leaves.deinit(allocator);

    var file_pos_running: u64 = 0;
    var src_pos: usize = hdr.header_size;
    while (src_pos < src.len) {
        if (src_pos + 4 > src.len) break;
        const first_word = std.mem.readInt(u32, src[src_pos..][0..4], .little);
        if (first_word == frame.end_mark) break;
        const bh = try frame.parseBlockHeader(src[src_pos..]);
        if (bh.isEndMark()) break;
        src_pos += 8;
        // v2: parallel-decode-metadata blocks carry no decompressable
        // bytes — skip them when walking the frame for sidecar building.
        if (bh.parallel_decode_metadata) {
            src_pos += bh.compressed_size;
            continue;
        }
        if (bh.uncompressed) {
            src_pos += bh.compressed_size;
            file_pos_running += bh.decompressed_size;
            continue;
        }
        const block_payload = src[src_pos..][0..bh.compressed_size];
        try partitionFastBlock(allocator, block_payload, bh.decompressed_size, file_pos_running, byte_earliest, producer_map, total_decomp, &tokens, &overcopy_leaves);
        src_pos += bh.compressed_size;
        file_pos_running += bh.decompressed_size;
    }

    // Identify seeds: tokens whose src_start is before their own sub_chunk_start.
    var in_closure = try allocator.alloc(u8, tokens.items.len);
    defer allocator.free(in_closure);
    @memset(in_closure, 0);

    // Literal-leaf tracking: positions already recorded, so we don't
    // emit duplicate ClosureLiteralByte entries when multiple closure
    // members' src ranges overlap the same literal byte.
    const lit_seen = try allocator.alloc(u8, @intCast(total_decomp));
    defer allocator.free(lit_seen);
    @memset(lit_seen, 0);

    var seed_queue: std.ArrayList(u32) = .{};
    defer seed_queue.deinit(allocator);

    for (tokens.items, 0..) |t, idx| {
        const sub_start_signed: i64 = @intCast(t.sub_chunk_start);
        if (t.src_start < sub_start_signed) {
            if (in_closure[idx] == 0) {
                in_closure[idx] = 1;
                try seed_queue.append(allocator, @intCast(idx));
            }
        }
    }

    // BFS backward from seeds. Record literal leaves along the way.
    var head: usize = 0;
    while (head < seed_queue.items.len) : (head += 1) {
        const idx = seed_queue.items[head];
        const t = tokens.items[idx];
        const src_lo_s = t.src_start;
        const src_hi_s = t.src_start + @as(i64, @intCast(t.length));
        if (src_hi_s <= 0) continue;
        const src_lo: u64 = if (src_lo_s < 0) 0 else @intCast(src_lo_s);
        const src_hi: u64 = if (src_hi_s > @as(i64, @intCast(total_decomp)))
            total_decomp
        else
            @intCast(src_hi_s);
        if (src_lo >= src_hi) continue;

        var p: u64 = src_lo;
        while (p < src_hi) : (p += 1) {
            const producer = producer_map[@intCast(p)];
            if (producer == std.math.maxInt(u32)) {
                // Literal leaf — record it (once).
                if (lit_seen[@intCast(p)] == 0) {
                    lit_seen[@intCast(p)] = 1;
                    try sidecar.literal_bytes.append(allocator, .{
                        .position = p,
                        .byte_value = dst_ref[@intCast(p)],
                    });
                }
                continue;
            }
            if (in_closure[producer] != 0) continue;
            in_closure[producer] = 1;
            try seed_queue.append(allocator, producer);
        }
    }

    // Emit match ops for every closure member, in cmd_stream order.
    // cmd_stream order = dependency-correct order for phase 1 execution
    // (producers always precede consumers in file order).
    var total_pos: u64 = @as(u64, sidecar.literal_bytes.items.len);
    for (tokens.items, 0..) |t, idx| {
        if (in_closure[idx] == 0) continue;
        if (t.length == 0) continue;
        if (t.src_start < 0) continue;
        try sidecar.match_ops.append(allocator, .{
            .target_start = t.target_start,
            .src_start = t.src_start,
            .length = t.length,
        });
        total_pos += t.length;
    }

    // Overcopy leaves: the walker recorded every byte position past
    // a block's intended `dst_size` that the Fast decoder's vectorised
    // copy64/copy16 patterns can touch. In serial decode this
    // overshoot is harmlessly overwritten by the next chunk's token
    // writes; in parallel decode at outer-chunk boundaries, a later
    // chunk can finish first and an earlier chunk's overshoot then
    // stomps its correct output. Adding those positions as literal
    // leaves lets phase 1 (re-run AFTER phase 2 workers) restore them
    // to the reference bytes.
    for (overcopy_leaves.items) |p| {
        if (p >= total_decomp) continue;
        if (lit_seen[@intCast(p)] != 0) continue;
        lit_seen[@intCast(p)] = 1;
        try sidecar.literal_bytes.append(allocator, .{
            .position = p,
            .byte_value = dst_ref[@intCast(p)],
        });
    }

    sidecar.total_positions = total_pos;

    return sidecar;
}

/// Execute phase 1 of the PoC into a dst buffer.
///
/// Step 1: write every `ClosureLiteralByte` to its position.
/// Step 2: execute every `ClosureMatchOp` in order as a byte-wise forward
///         copy (which handles overlapping src/dst ranges correctly, the
///         common LZ case).
///
/// After this returns, `dst` contains correct bytes at every position
/// that a cross-sub-chunk match in phase 2 will read.
pub fn runPhase1Ppoc(sidecar: *const PpocSidecar, dst: []u8) void {
    // Literal leaves first so that match ops reading from those positions
    // find the correct bytes.
    for (sidecar.literal_bytes.items) |lit| {
        dst[@intCast(lit.position)] = lit.byte_value;
    }
    // Match copies in cmd_stream order. Byte-wise to handle src/dst overlap.
    for (sidecar.match_ops.items) |op| {
        const length: usize = op.length;
        if (op.src_start < 0) continue;
        const src_begin: usize = @intCast(op.src_start);
        const tgt_begin: usize = @intCast(op.target_start);
        if (src_begin + length > dst.len) continue;
        if (tgt_begin + length > dst.len) continue;
        var i: usize = 0;
        while (i < length) : (i += 1) {
            dst[tgt_begin + i] = dst[src_begin + i];
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Parse-only walker (for skip-cost benchmark)
//
//  Mirrors `fast.processModeImpl`'s cmd-stream dispatch but does NO
//  byte copies. Every pointer (cmd, lit, off16, off32, length, dst)
//  advances by the same amount as the real decoder, but the bytes
//  themselves are never moved. Used to estimate the Amdahl serial
//  fraction for the per-token-bit parallel decode design — both
//  threads have to parse every token, only the actual write work is
//  split.
// ────────────────────────────────────────────────────────────

fn parseOnlyFastSubChunk(
    lz: *FastLzTable,
    dst_size: usize,
    saved_dist: *i32,
    start_off: usize,
    out_byte_count: *u64,
) void {
    _ = dst_size;
    var dst_off: usize = start_off;
    var recent_offs: i64 = saved_dist.*;

    var cmd_stream = lz.cmd_start;
    const cmd_stream_end = lz.cmd_end;
    var length_stream = lz.length_stream;
    var off16_stream: [*]align(1) const u16 = lz.off16_start;
    var off32_stream: [*]align(1) const u32 = lz.off32_start;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        if (cmd >= 24) {
            const literal_length: usize = cmd & 7;
            const use_new_dist: bool = (cmd & 0x80) == 0;
            dst_off += literal_length;
            if (use_new_dist) {
                const new_dist: i64 = off16_stream[0];
                recent_offs = -new_dist;
                off16_stream = @ptrFromInt(@intFromPtr(off16_stream) + 2);
            }
            const match_length: usize = (cmd >> 3) & 0xF;
            dst_off += match_length;
        } else if (cmd > 2) {
            const length: usize = cmd + 5;
            off32_stream += 1;
            dst_off += length;
            recent_offs = -1;
        } else if (cmd == 0) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 64;
            dst_off += length;
        } else if (cmd == 1) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 91;
            off16_stream += 1;
            dst_off += length;
        } else {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 29;
            off32_stream += 1;
            dst_off += length;
            recent_offs = -1;
        }
    }
    saved_dist.* = @intCast(recent_offs);
    lz.length_stream = length_stream;
    lz.off16_start = off16_stream;
    lz.off32_start = off32_stream;
    out_byte_count.* += dst_off - start_off;
}

fn parseOnlyFastChunkPayload(
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    out_byte_count: *u64,
) !void {
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);
        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            (@as(u32, chunk_src[src_pos + 2]));

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            out_byte_count.* += dst_count;
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;
        if (src_pos + src_used > chunk_src.len) return error.Truncated;
        if (src_used >= dst_count) {
            out_byte_count.* += dst_count;
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        const fast_lz_table_size: usize = @sizeOf(FastLzTable);
        const lz_ptr: *FastLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + fast_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        var dst_slot: [*]u8 = dummy_dst.ptr;
        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try fast.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            &dst_slot,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        var saved_dist: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
        var dst_size_left: usize = dst_count;
        var iteration: u32 = 0;
        while (iteration != 2) : (iteration += 1) {
            var dst_size_cur: usize = dst_size_left;
            if (dst_size_cur > 0x10000) dst_size_cur = 0x10000;

            if (iteration == 0) {
                lz_ptr.off32_start = lz_ptr.off32_backing1;
                lz_ptr.off32_end = lz_ptr.off32_backing1 + lz_ptr.off32_count1;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset;
            } else {
                lz_ptr.off32_start = lz_ptr.off32_backing2;
                lz_ptr.off32_end = lz_ptr.off32_backing2 + lz_ptr.off32_count2;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset_end;
                lz_ptr.cmd_start += lz_ptr.cmd_stream2_offset;
            }
            const s_off: usize = if (iteration == 0) 8 else 0;
            parseOnlyFastSubChunk(lz_ptr, dst_size_cur, &saved_dist, s_off, out_byte_count);
            dst_size_left -= dst_size_cur;
            if (dst_size_left == 0) break;
        }

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

fn parseOnlyFastBlock(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: u64,
    block_file_pos_base: u64,
    out_byte_count: *u64,
) !void {
    const max_chunk: usize = 0x20000;
    const scratch_bytes: usize = constants.scratch_size;
    const scratch = try allocator.alignedAlloc(u8, .@"64", scratch_bytes);
    defer allocator.free(scratch);
    const dummy_decode_buf = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_decode_buf);
    const dummy_dst = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_dst);

    const is_sc = blk: {
        if (block_src.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src.len) return error.Truncated;
    const block_payload: []const u8 = block_src[0 .. block_src.len - prefix_size];

    var src_pos: usize = 0;
    var dst_remaining: u64 = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;
    var dst_off_running: u64 = 0;

    while (dst_remaining > 0) {
        const at_chunk_boundary = (dst_off_running & (constants.chunk_size - 1)) == 0;
        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_payload.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_payload[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const ihdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = @intCast(dst_remaining);

        if (ihdr.uncompressed) {
            out_byte_count.* += dst_this_chunk;
            src_pos += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }
        const ch = block_header.parseChunkHeader(block_payload[src_pos..], ihdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;
        if (ch.is_memset) {
            out_byte_count.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }
        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_payload.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;
        if (comp_size == dst_this_chunk) {
            out_byte_count.* += dst_this_chunk;
            src_pos += comp_size;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }
        try parseOnlyFastChunkPayload(
            block_payload[src_pos..][0..comp_size],
            dst_this_chunk,
            block_file_pos_base + dst_off_running,
            scratch,
            dummy_decode_buf,
            dummy_dst,
            out_byte_count,
        );
        src_pos += comp_size;
        dst_remaining -= dst_this_chunk;
        dst_off_running += dst_this_chunk;
    }
}

/// Top-level parse-only walk. Walks the cmd stream and advances all
/// pointers as the real decoder would, but does no byte copies. Returns
/// the total decompressed-byte count it walked through (sanity check).
pub fn parseOnlyWalkFile(allocator: std.mem.Allocator, src: []const u8) !u64 {
    var byte_count: u64 = 0;
    const hdr = try frame.parseHeader(src);
    var src_pos: usize = hdr.header_size;
    if (hdr.codec != .fast and hdr.codec != .turbo) return byte_count;

    var file_pos_running: u64 = 0;
    while (src_pos < src.len) {
        if (src_pos + 4 > src.len) break;
        const first_word = std.mem.readInt(u32, src[src_pos..][0..4], .little);
        if (first_word == frame.end_mark) break;
        const bh = try frame.parseBlockHeader(src[src_pos..]);
        if (bh.isEndMark()) break;
        src_pos += 8;
        if (bh.uncompressed) {
            byte_count += bh.decompressed_size;
            src_pos += bh.compressed_size;
            file_pos_running += bh.decompressed_size;
            continue;
        }
        const block_payload = src[src_pos..][0..bh.compressed_size];
        try parseOnlyFastBlock(allocator, block_payload, bh.decompressed_size, file_pos_running, &byte_count);
        src_pos += bh.compressed_size;
        file_pos_running += bh.decompressed_size;
    }
    return byte_count;
}

// ────────────────────────────────────────────────────────────
//  Level-0-only bitmap analyzer
//
//  Uses a 1-bit-per-byte bitmap (12.5 MB for a 100 MB file) that fits
//  entirely in L3, instead of the per-byte `byte_round` u16 array
//  (200 MB) that the full-DAG analyzer uses. Bitmap[i] = 1 iff byte i
//  was produced by an LZ match (vs a literal).
//
//  For each match token T:
//    * If no bit in T's source range is set → T is "level 0" (its
//      source is fully literal-derived; no transitive match dependency).
//    * Set all bits in T's target range so subsequent tokens that read
//      from T's output know it's a match-byte.
// ────────────────────────────────────────────────────────────

pub const Level0Stats = struct {
    total_match_tokens: u64,
    level0_match_tokens: u64,
    decompressed_size: u64,

    pub fn level0Fraction(self: Level0Stats) f64 {
        if (self.total_match_tokens == 0) return 0;
        return @as(f64, @floatFromInt(self.level0_match_tokens)) /
            @as(f64, @floatFromInt(self.total_match_tokens));
    }
};

/// Test whether any bit in `bitmap[start..end)` is set. Operates on
/// `u64` words for speed; first/last partial words are masked.
inline fn bitmapAnyInRange(bitmap: []const u64, start: usize, end: usize) bool {
    if (start >= end) return false;
    const start_word: usize = start / 64;
    const end_word: usize = (end - 1) / 64;

    if (start_word == end_word) {
        const lo: u6 = @intCast(start % 64);
        const hi: u6 = @intCast((end - 1) % 64);
        const lo_mask: u64 = @as(u64, std.math.maxInt(u64)) << lo;
        const hi_mask: u64 = @as(u64, std.math.maxInt(u64)) >> (63 - hi);
        return (bitmap[start_word] & lo_mask & hi_mask) != 0;
    }

    const lo: u6 = @intCast(start % 64);
    const lo_mask: u64 = @as(u64, std.math.maxInt(u64)) << lo;
    if ((bitmap[start_word] & lo_mask) != 0) return true;

    var i: usize = start_word + 1;
    while (i < end_word) : (i += 1) {
        if (bitmap[i] != 0) return true;
    }

    const hi: u6 = @intCast((end - 1) % 64);
    const hi_mask: u64 = @as(u64, std.math.maxInt(u64)) >> (63 - hi);
    return (bitmap[end_word] & hi_mask) != 0;
}

/// Set all bits in `bitmap[start..end)`.
inline fn bitmapSetRange(bitmap: []u64, start: usize, end: usize) void {
    if (start >= end) return;
    const start_word: usize = start / 64;
    const end_word: usize = (end - 1) / 64;

    if (start_word == end_word) {
        const lo: u6 = @intCast(start % 64);
        const hi: u6 = @intCast((end - 1) % 64);
        const lo_mask: u64 = @as(u64, std.math.maxInt(u64)) << lo;
        const hi_mask: u64 = @as(u64, std.math.maxInt(u64)) >> (63 - hi);
        bitmap[start_word] |= (lo_mask & hi_mask);
        return;
    }

    const lo: u6 = @intCast(start % 64);
    bitmap[start_word] |= @as(u64, std.math.maxInt(u64)) << lo;

    var i: usize = start_word + 1;
    while (i < end_word) : (i += 1) {
        bitmap[i] = @as(u64, std.math.maxInt(u64));
    }

    const hi: u6 = @intCast((end - 1) % 64);
    bitmap[end_word] |= @as(u64, std.math.maxInt(u64)) >> (63 - hi);
}

/// Update for one match token: query source range, mark target range,
/// increment level-0 counter if the source had no match-bytes.
fn level0UpdateMatch(
    bitmap: []u64,
    dst_file_pos: u64,
    recent_offs: i64,
    length: usize,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) void {
    if (length == 0) return;
    stats.total_match_tokens += 1;

    const src_pos_signed: i64 = @as(i64, @intCast(dst_file_pos)) + recent_offs;
    if (src_pos_signed < 0) {
        // Source straddles file start — treat as level 0 (no prior
        // match could have written there).
        stats.level0_match_tokens += 1;
        const tgt_end = @min(dst_file_pos + length, bitmap_byte_capacity);
        if (dst_file_pos < bitmap_byte_capacity) {
            bitmapSetRange(bitmap, @intCast(dst_file_pos), @intCast(tgt_end));
        }
        return;
    }

    const src_start: usize = @intCast(src_pos_signed);
    const dist: usize = @intCast(-recent_offs);
    const real_src_len: usize = @min(length, dist);
    const src_end: usize = @min(src_start + real_src_len, @as(usize, @intCast(bitmap_byte_capacity)));

    const is_level0 = if (src_start < @as(usize, @intCast(bitmap_byte_capacity)))
        !bitmapAnyInRange(bitmap, src_start, src_end)
    else
        true;

    if (is_level0) stats.level0_match_tokens += 1;

    const tgt_end = @min(dst_file_pos + length, bitmap_byte_capacity);
    if (dst_file_pos < bitmap_byte_capacity) {
        bitmapSetRange(bitmap, @intCast(dst_file_pos), @intCast(tgt_end));
    }
}

// ── Fast-codec token walker, level-0 mode ────────────────────────────

fn level0FastSubChunk(
    comptime mode: enum { delta, raw },
    lz: *FastLzTable,
    dst_size: usize,
    saved_dist: *i32,
    start_off: usize,
    file_pos_base: u64,
    bitmap: []u64,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) void {
    _ = mode;
    _ = dst_size;
    var dst_off: usize = start_off;
    var recent_offs: i64 = saved_dist.*;

    var cmd_stream = lz.cmd_start;
    const cmd_stream_end = lz.cmd_end;
    var length_stream = lz.length_stream;
    var off16_stream: [*]align(1) const u16 = lz.off16_start;
    var off32_stream: [*]align(1) const u32 = lz.off32_start;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        if (cmd >= 24) {
            const literal_length: usize = cmd & 7;
            const use_new_dist: bool = (cmd & 0x80) == 0;
            dst_off += literal_length;

            if (use_new_dist) {
                const new_dist: i64 = off16_stream[0];
                recent_offs = -new_dist;
                off16_stream = @ptrFromInt(@intFromPtr(off16_stream) + 2);
            }
            const match_length: usize = (cmd >> 3) & 0xF;
            level0UpdateMatch(bitmap, file_pos_base + dst_off, recent_offs, match_length, bitmap_byte_capacity, stats);
            dst_off += match_length;
        } else if (cmd > 2) {
            const length: usize = cmd + 5;
            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            level0UpdateMatch(bitmap, file_pos_base + dst_off, dist_match, length, bitmap_byte_capacity, stats);
            dst_off += length;
            recent_offs = -1;
        } else if (cmd == 0) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 64;
            dst_off += length;
        } else if (cmd == 1) {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 91;

            const off16: u16 = off16_stream[0];
            off16_stream += 1;
            recent_offs = -@as(i64, off16);
            level0UpdateMatch(bitmap, file_pos_base + dst_off, recent_offs, length, bitmap_byte_capacity, stats);
            dst_off += length;
        } else {
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 29;

            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            level0UpdateMatch(bitmap, file_pos_base + dst_off, dist_match, length, bitmap_byte_capacity, stats);
            dst_off += length;
            recent_offs = -1;
        }
    }
    saved_dist.* = @intCast(recent_offs);
    lz.length_stream = length_stream;
    lz.off16_start = off16_stream;
    lz.off32_start = off32_stream;
}

// ── High-codec token walker, level-0 mode ────────────────────────────

fn level0HighSubChunk(
    comptime mode: enum { delta, raw },
    lz: *const HighLzTable,
    base_offset: usize,
    file_pos_base: u64,
    bitmap: []u64,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) void {
    const start_off: usize = if (base_offset == 0) 8 else 0;
    var dst_off: usize = start_off;

    var cmd_stream = lz.cmd_stream;
    const cmd_stream_end = lz.cmd_stream + lz.cmd_stream_size;
    var len_stream: [*]align(1) const i32 = lz.len_stream;
    var offs_stream: [*]align(1) const i32 = lz.offs_stream;

    const init_recent: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
    var ro3: i32 = init_recent;
    var ro4: i32 = init_recent;
    var ro5: i32 = init_recent;
    var last_offset: i32 = init_recent;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        var literal_length: u32 = cmd & 0x3;
        const offset_index: u32 = cmd >> 6;
        const match_length: u32 = (cmd >> 2) & 0xF;

        if (literal_length == 3) {
            literal_length = @bitCast(len_stream[0]);
            len_stream += 1;
        }

        const new_off: i32 = offs_stream[0];

        var picked: i32 = ro3;
        if (offset_index >= 1) picked = ro4;
        if (offset_index >= 2) picked = ro5;
        if (offset_index >= 3) picked = new_off;
        const next_ro4: i32 = if (offset_index == 0) ro4 else ro3;
        const next_ro5: i32 = if (offset_index < 2) ro5 else ro4;
        ro3 = picked;
        ro4 = next_ro4;
        ro5 = next_ro5;

        if (offset_index == 3) offs_stream += 1;

        const actual_match_len: usize = blk: {
            if (match_length != 15) break :blk match_length + 2;
            const extra: i32 = len_stream[0];
            len_stream += 1;
            break :blk @intCast(14 + extra);
        };

        if (mode == .delta and literal_length > 0) {
            level0UpdateMatch(bitmap, file_pos_base + dst_off, @as(i64, last_offset), literal_length, bitmap_byte_capacity, stats);
        }
        dst_off += literal_length;
        level0UpdateMatch(bitmap, file_pos_base + dst_off, @as(i64, picked), actual_match_len, bitmap_byte_capacity, stats);
        dst_off += actual_match_len;
        last_offset = picked;
    }
}

fn level0FastChunkPayload(
    allocator: std.mem.Allocator,
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    bitmap: []u64,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) !void {
    _ = allocator;
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);
        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            @as(u32, chunk_src[src_pos + 2]);

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;
        if (src_pos + src_used > chunk_src.len) return error.Truncated;
        if (src_used >= dst_count) {
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        const fast_lz_table_size: usize = @sizeOf(FastLzTable);
        const lz_ptr: *FastLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + fast_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        var dst_slot: [*]u8 = dummy_dst.ptr;
        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try fast.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            &dst_slot,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        var saved_dist: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
        var dst_size_left: usize = dst_count;
        var iteration: u32 = 0;
        while (iteration != 2) : (iteration += 1) {
            var dst_size_cur: usize = dst_size_left;
            if (dst_size_cur > 0x10000) dst_size_cur = 0x10000;

            if (iteration == 0) {
                lz_ptr.off32_start = lz_ptr.off32_backing1;
                lz_ptr.off32_end = lz_ptr.off32_backing1 + lz_ptr.off32_count1;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset;
            } else {
                lz_ptr.off32_start = lz_ptr.off32_backing2;
                lz_ptr.off32_end = lz_ptr.off32_backing2 + lz_ptr.off32_count2;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset_end;
                lz_ptr.cmd_start += lz_ptr.cmd_stream2_offset;
            }
            const s_off: usize = if (iteration == 0) 8 else 0;
            const sub_chunk_file_pos: u64 = running_dst_off + dst_off_in_chunk + (dst_count - dst_size_left);
            if (mode == 0) {
                level0FastSubChunk(.delta, lz_ptr, dst_size_cur, &saved_dist, s_off, sub_chunk_file_pos, bitmap, bitmap_byte_capacity, stats);
            } else {
                level0FastSubChunk(.raw, lz_ptr, dst_size_cur, &saved_dist, s_off, sub_chunk_file_pos, bitmap, bitmap_byte_capacity, stats);
            }
            dst_size_left -= dst_size_cur;
            if (dst_size_left == 0) break;
        }

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

fn level0HighChunkPayload(
    allocator: std.mem.Allocator,
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    bitmap: []u64,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) !void {
    _ = allocator;
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);
        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            @as(u32, chunk_src[src_pos + 2]);

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;
        if (src_pos + src_used > chunk_src.len) return error.Truncated;
        if (src_used >= dst_count) {
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        const high_lz_table_size: usize = @sizeOf(HighLzTable);
        const lz_ptr: *HighLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + high_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try high.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            dummy_dst.ptr,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        if (mode == 0) {
            level0HighSubChunk(.delta, lz_ptr, @intCast(this_base_off), running_dst_off + dst_off_in_chunk, bitmap, bitmap_byte_capacity, stats);
        } else {
            level0HighSubChunk(.raw, lz_ptr, @intCast(this_base_off), running_dst_off + dst_off_in_chunk, bitmap, bitmap_byte_capacity, stats);
        }

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

fn level0Block(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: u64,
    block_file_pos_base: u64,
    is_high: bool,
    bitmap: []u64,
    bitmap_byte_capacity: u64,
    stats: *Level0Stats,
) !void {
    const max_chunk: usize = 0x20000;
    const scratch_bytes: usize = constants.scratch_size;
    const scratch = try allocator.alignedAlloc(u8, .@"64", scratch_bytes);
    defer allocator.free(scratch);
    const dummy_decode_buf = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_decode_buf);
    const dummy_dst = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_dst);

    const is_sc = blk: {
        if (block_src.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src.len) return error.Truncated;
    const block_payload: []const u8 = block_src[0 .. block_src.len - prefix_size];

    var src_pos: usize = 0;
    var dst_remaining: u64 = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;
    var dst_off_running: u64 = 0;

    while (dst_remaining > 0) {
        const at_chunk_boundary = (dst_off_running & (constants.chunk_size - 1)) == 0;
        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_payload.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_payload[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const ihdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = @intCast(dst_remaining);

        if (ihdr.uncompressed) {
            src_pos += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const ch = block_header.parseChunkHeader(block_payload[src_pos..], ihdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_payload.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            src_pos += comp_size;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        if (is_high) {
            try level0HighChunkPayload(
                allocator,
                block_payload[src_pos..][0..comp_size],
                dst_this_chunk,
                block_file_pos_base + dst_off_running,
                scratch,
                dummy_decode_buf,
                dummy_dst,
                bitmap,
                bitmap_byte_capacity,
                stats,
            );
        } else {
            try level0FastChunkPayload(
                allocator,
                block_payload[src_pos..][0..comp_size],
                dst_this_chunk,
                block_file_pos_base + dst_off_running,
                scratch,
                dummy_decode_buf,
                dummy_dst,
                bitmap,
                bitmap_byte_capacity,
                stats,
            );
        }
        src_pos += comp_size;
        dst_remaining -= dst_this_chunk;
        dst_off_running += dst_this_chunk;
    }
}

/// Top-level entry: walk the file in stream order using a 1-bit-per-byte
/// bitmap to track "is this output byte from a match?" and count how
/// many match tokens are level-0 (source range entirely literal).
pub fn analyzeFileLevel0(allocator: std.mem.Allocator, src: []const u8) !Level0Stats {
    var stats: Level0Stats = .{
        .total_match_tokens = 0,
        .level0_match_tokens = 0,
        .decompressed_size = 0,
    };

    const hdr = try frame.parseHeader(src);
    var src_pos: usize = hdr.header_size;
    const is_high: bool = hdr.codec == .high;
    const is_fast: bool = hdr.codec == .fast or hdr.codec == .turbo;
    if (!is_high and !is_fast) return stats;

    const total_decomp: u64 = if (hdr.content_size) |cs| cs else 200 * 1024 * 1024;
    stats.decompressed_size = total_decomp;
    const word_count: usize = @intCast((total_decomp + 63) / 64);
    const bitmap = try allocator.alloc(u64, word_count);
    defer allocator.free(bitmap);
    @memset(bitmap, 0);

    var file_pos_running: u64 = 0;

    while (src_pos < src.len) {
        if (src_pos + 4 > src.len) break;
        const first_word = std.mem.readInt(u32, src[src_pos..][0..4], .little);
        if (first_word == frame.end_mark) {
            src_pos += 4;
            break;
        }
        const bh = try frame.parseBlockHeader(src[src_pos..]);
        if (bh.isEndMark()) break;
        src_pos += 8;

        if (bh.uncompressed) {
            src_pos += bh.compressed_size;
            file_pos_running += bh.decompressed_size;
            continue;
        }

        const block_payload = src[src_pos..][0..bh.compressed_size];
        try level0Block(allocator, block_payload, bh.decompressed_size, file_pos_running, is_high, bitmap, total_decomp, &stats);
        src_pos += bh.compressed_size;
        file_pos_running += bh.decompressed_size;
    }

    return stats;
}

/// Walk the cmd stream of one Fast sub-chunk. Computes both:
///   1. Per-byte taint bitmap (deprecated — kept for compatibility)
///   2. Token-dependency DAG round assignment via `byte_round`
///
/// `byte_round` is FILE-WIDE (not per-chunk); `file_pos_base` is the
/// absolute file offset of byte 0 in this sub-chunk.
fn analyzeOneSubChunk(
    comptime mode: enum { delta, raw },
    lz: *FastLzTable,
    dst_size: usize,
    saved_dist: *i32,
    start_off: usize,
    taint: []u8,
    stats: *SubChunkStats,
    file_pos_base: u64,
    byte_round: []u16,
    file_stats: *FileStats,
) void {
    _ = mode;

    @memset(taint[0..dst_size], 0);

    var dst_off: usize = start_off;
    var recent_offs: i64 = saved_dist.*;

    var cmd_stream = lz.cmd_start;
    const cmd_stream_end = lz.cmd_end;
    var length_stream = lz.length_stream;
    var off16_stream: [*]align(1) const u16 = lz.off16_start;
    var off32_stream: [*]align(1) const u32 = lz.off32_start;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;
        stats.token_count += 1;

        if (cmd >= 24) {
            // ── Short token ──
            const literal_length: usize = cmd & 7;
            const use_new_dist: bool = (cmd & 0x80) == 0;
            dst_off += literal_length;

            if (use_new_dist) {
                const new_dist: i64 = off16_stream[0];
                recent_offs = -new_dist;
                off16_stream = @ptrFromInt(@intFromPtr(off16_stream) + 2);
            }

            const match_length: usize = (cmd >> 3) & 0xF;
            propagateMatch(taint, dst_off, recent_offs, match_length, dst_size, stats);
            // DAG round update for the match
            updateDagRound(byte_round, file_pos_base + dst_off, recent_offs, match_length, file_stats);
            dst_off += match_length;
        } else if (cmd > 2) {
            // ── Medium match (32-bit far offset) ──
            const length: usize = cmd + 5;
            const far: u32 = off32_stream[0];
            off32_stream += 1;
            // far offset is from `dst_begin` (sub-chunk start), but in
            // the file-wide coord system source = file_pos_base + dst_off - dist
            // where dist = (file_pos_base + dst_off) - (file_pos_base of dst_begin) + far
            // = dst_off + far (if file_pos_base of dst_begin == file_pos_base).
            // Equivalently: src_file = file_pos_base - far + offset_within_sub_chunk
            // = (file_pos_base + dst_off) - (dst_off + far)
            // distance = dst_off + far  (in file-wide coords)
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            propagateCrossChunk(taint, dst_off, length, dst_size, stats);
            updateDagRound(byte_round, file_pos_base + dst_off, dist_match, length, file_stats);
            dst_off += length;
            recent_offs = -1;
        } else if (cmd == 0) {
            // ── Long literal run ──
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 64;
            // Literals: byte_round stays at default for these positions.
            dst_off += length;
        } else if (cmd == 1) {
            // ── Long match with 16-bit offset (relative to dst) ──
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 91;

            const off16: u16 = off16_stream[0];
            off16_stream += 1;
            recent_offs = -@as(i64, off16);
            propagateMatch(taint, dst_off, recent_offs, length, dst_size, stats);
            updateDagRound(byte_round, file_pos_base + dst_off, recent_offs, length, file_stats);
            dst_off += length;
        } else {
            // ── cmd == 2: Long match with 32-bit far offset ──
            var length: usize = length_stream[0];
            if (length > extended_length_threshold) {
                length += @as(usize, std.mem.readInt(u16, (length_stream + 1)[0..2], .little)) * 4;
                length_stream += 2;
            }
            length_stream += 1;
            length += 29;

            const far: u32 = off32_stream[0];
            off32_stream += 1;
            const dist_match: i64 = -(@as(i64, @intCast(dst_off)) + @as(i64, @intCast(far)));
            propagateCrossChunk(taint, dst_off, length, dst_size, stats);
            updateDagRound(byte_round, file_pos_base + dst_off, dist_match, length, file_stats);
            dst_off += length;
            recent_offs = -1;
        }
    }

    // Trailing literals — clean.

    saved_dist.* = @intCast(recent_offs);
    lz.length_stream = length_stream;
    lz.off16_start = off16_stream;
    lz.off32_start = off32_stream;
}

inline fn propagateMatch(
    taint: []u8,
    dst_off: usize,
    recent_offs: i64,
    length: usize,
    dst_size: usize,
    stats: *SubChunkStats,
) void {
    // Source position relative to the start of the sub-chunk (which is
    // position 0 in our coordinate system). recent_offs is negative;
    // src_pos_first = dst_off + recent_offs (interpreted as signed).
    const src_pos_signed: i64 = @as(i64, @intCast(dst_off)) + recent_offs;

    if (src_pos_signed < 0) {
        // Source range starts before the sub-chunk → cross-chunk.
        stats.cross_chunk_token_count += 1;
        if (stats.first_cross_chunk_pos == null) {
            stats.first_cross_chunk_pos = @intCast(dst_off);
        }
        propagateCrossChunkInner(taint, dst_off, length, dst_size);
        return;
    }

    // Intra-chunk: copy source bytes' taint to target bytes.
    // Handle self-overlap: if recent_offs > -length (i.e. distance < length)
    // some target bytes' sources are themselves being written by this match.
    // We walk byte-by-byte so each later target reads the just-written
    // source byte's taint correctly (matches LZ semantics).
    const dist: usize = @intCast(-recent_offs);
    const end = @min(dst_off + length, dst_size);
    var i: usize = dst_off;
    while (i < end) : (i += 1) {
        // src_byte is at (i - dist), guaranteed >= 0 because src_pos_signed >= 0
        const src_idx: usize = i - dist;
        if (src_idx < dst_size and i < dst_size) {
            taint[i] = taint[src_idx];
        }
    }
}

inline fn propagateCrossChunk(
    taint: []u8,
    dst_off: usize,
    length: usize,
    dst_size: usize,
    stats: *SubChunkStats,
) void {
    stats.cross_chunk_token_count += 1;
    if (stats.first_cross_chunk_pos == null) {
        stats.first_cross_chunk_pos = @intCast(@min(dst_off, dst_size));
    }
    propagateCrossChunkInner(taint, dst_off, length, dst_size);
}

inline fn propagateCrossChunkInner(
    taint: []u8,
    dst_off: usize,
    length: usize,
    dst_size: usize,
) void {
    const end = @min(dst_off + length, dst_size);
    if (dst_off >= dst_size) return;
    @memset(taint[dst_off..end], 1);
}

/// Token-dependency DAG update for one match token.
///
/// `dst_file_pos` is the file-absolute position of the match's first
/// target byte. `recent_offs` is the negative offset (so source position
/// = dst_file_pos + recent_offs). `length` is the match length.
///
/// Computes the round of this token = 1 + max byte_round over the
/// source range, then writes that round into the target range and
/// records it in the histogram.
fn updateDagRound(
    byte_round: []u16,
    dst_file_pos: u64,
    recent_offs: i64,
    length: usize,
    file_stats: *FileStats,
) void {
    if (length == 0) return;
    const src_pos_signed: i64 = @as(i64, @intCast(dst_file_pos)) + recent_offs;
    if (src_pos_signed < 0) {
        // Source is outside the file (shouldn't happen for a valid stream).
        // Treat as round 1 (no dependency on anything we've seen).
        const round: u16 = 1;
        const end = @min(dst_file_pos + length, byte_round.len);
        if (dst_file_pos < byte_round.len) {
            @memset(byte_round[dst_file_pos..end], round);
        }
        file_stats.total_match_tokens += 1;
        file_stats.round_histogram[round] += 1;
        return;
    }

    const src_start: usize = @intCast(src_pos_signed);
    const dist: usize = @intCast(-recent_offs);

    // Compute max round over the source range. Handle self-overlap by
    // walking byte-by-byte (when dist < length, source bytes after the
    // first `dist` are themselves bytes this token is currently writing
    // — but in the DAG view we only care about the FINALIZED rounds, so
    // we treat self-overlap as "the source is the first `dist` source
    // bytes repeating," all of which are stable").
    var max_round: u16 = 0;
    const real_src_len: usize = @min(length, dist);
    const src_end: usize = @min(src_start + real_src_len, byte_round.len);
    if (src_start < byte_round.len) {
        var i: usize = src_start;
        while (i < src_end) : (i += 1) {
            if (byte_round[i] > max_round) max_round = byte_round[i];
        }
    }

    const this_round: u16 = if (max_round == std.math.maxInt(u16)) std.math.maxInt(u16) else max_round + 1;
    const tgt_end = @min(dst_file_pos + length, byte_round.len);
    if (dst_file_pos < byte_round.len) {
        @memset(byte_round[dst_file_pos..tgt_end], this_round);
    }
    file_stats.total_match_tokens += 1;
    file_stats.round_histogram[this_round] += 1;
}

/// Walk the contents of one compressed Fast chunk's payload, mirroring
/// `fast.decodeChunk` but computing taint instead of writing bytes. The
/// payload is the bytes after the 4-byte chunk header (or 7 with checksum)
/// and contains one or more 3-byte-headed sub-chunks of up to 128 KB each.
///
/// `running_dst_off` is the running output position relative to the start
/// of the file, used as `base_offset` for `readLzTable` so that the
/// "first chunk" 8-byte raw initial read fires only when needed.
fn analyzeFastChunkPayload(
    allocator: std.mem.Allocator,
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    taint: []u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    byte_round: []u16,
    file_stats: *FileStats,
) !void {
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);

        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            @as(u32, chunk_src[src_pos + 2]);

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            // Entropy-only sub-chunk: no LZ tokens. Run the entropy
            // decoder to learn how many source bytes it consumed.
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_count),
                .clean_bytes = @intCast(dst_count),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_count;
            file_stats.total_clean += dst_count;
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;

        if (src_pos + src_used > chunk_src.len) return error.Truncated;

        if (src_used >= dst_count) {
            // Raw / all-equal sub-chunk — no LZ tokens, all clean.
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_count),
                .clean_bytes = @intCast(dst_count),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_count;
            file_stats.total_clean += dst_count;
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        // Normal compressed sub-chunk with LZ tokens.
        const fast_lz_table_size: usize = @sizeOf(FastLzTable);
        const lz_ptr: *FastLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + fast_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        var dst_slot: [*]u8 = dummy_dst.ptr;
        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try fast.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            &dst_slot,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        // Walk the two 64 KB sub-sub-chunks (mirrors processLzRuns).
        var saved_dist: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
        var dst_size_left: usize = dst_count;
        var iteration: u32 = 0;
        while (iteration != 2) : (iteration += 1) {
            var dst_size_cur: usize = dst_size_left;
            if (dst_size_cur > 0x10000) dst_size_cur = 0x10000;

            if (iteration == 0) {
                lz_ptr.off32_start = lz_ptr.off32_backing1;
                lz_ptr.off32_end = lz_ptr.off32_backing1 + lz_ptr.off32_count1;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset;
            } else {
                lz_ptr.off32_start = lz_ptr.off32_backing2;
                lz_ptr.off32_end = lz_ptr.off32_backing2 + lz_ptr.off32_count2;
                lz_ptr.cmd_end = lz_ptr.cmd_start + lz_ptr.cmd_stream2_offset_end;
                lz_ptr.cmd_start += lz_ptr.cmd_stream2_offset;
            }

            const s_off: usize = if (iteration == 0) 8 else 0;
            var stats: SubChunkStats = .{
                .total_bytes = @intCast(dst_size_cur),
                .clean_bytes = 0,
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            };

            const sub_chunk_file_pos: u64 = running_dst_off + dst_off_in_chunk + (dst_count - dst_size_left);
            if (mode == 0) {
                analyzeOneSubChunk(.delta, lz_ptr, dst_size_cur, &saved_dist, s_off, taint, &stats, sub_chunk_file_pos, byte_round, file_stats);
            } else {
                analyzeOneSubChunk(.raw, lz_ptr, dst_size_cur, &saved_dist, s_off, taint, &stats, sub_chunk_file_pos, byte_round, file_stats);
            }

            var clean: u32 = 0;
            for (taint[s_off..dst_size_cur]) |t| {
                if (t == 0) clean += 1;
            }
            stats.clean_bytes = clean + @as(u32, @intCast(s_off));
            try file_stats.sub_chunks.append(allocator, stats);
            file_stats.total_bytes += stats.total_bytes;
            file_stats.total_clean += stats.clean_bytes;

            dst_size_left -= dst_size_cur;
            if (dst_size_left == 0) break;
        }

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

// ────────────────────────────────────────────────────────────
//  High codec analyzer (L9-L11 / High decoder)
// ────────────────────────────────────────────────────────────

/// Walk the cmd stream of one High sub-chunk computing per-token DAG round.
/// Mirrors `high_lz_process_runs.processLzRunsType{0,1}` for the dispatch
/// portion: extracts literal_length / match_length / offset_index / picked
/// offset from each cmd byte, then updates `byte_round` for the affected
/// target ranges.
///
/// Type 0 (delta literals): each literal byte at file position P depends
/// on the byte at P + last_offset, so the literal range gets a DAG
/// dependency through `last_offset`.
/// Type 1 (raw literals): literals are independent (round 0).
fn analyzeHighSubChunk(
    comptime mode: enum { delta, raw },
    lz: *const HighLzTable,
    base_offset: usize,
    file_pos_base: u64,
    byte_round: []u16,
    file_stats: *FileStats,
) void {
    const start_off: usize = if (base_offset == 0) 8 else 0;
    var dst_off: usize = start_off;

    var cmd_stream = lz.cmd_stream;
    const cmd_stream_end = lz.cmd_stream + lz.cmd_stream_size;
    var len_stream: [*]align(1) const i32 = lz.len_stream;
    var offs_stream: [*]align(1) const i32 = lz.offs_stream;

    // 3-entry recent-offset LIFO (mirrors processLzRunsType0).
    const init_recent: i32 = -@as(i32, @intCast(constants.initial_recent_offset));
    var ro3: i32 = init_recent;
    var ro4: i32 = init_recent;
    var ro5: i32 = init_recent;
    var last_offset: i32 = init_recent;

    while (@intFromPtr(cmd_stream) < @intFromPtr(cmd_stream_end)) {
        const cmd: u32 = cmd_stream[0];
        cmd_stream += 1;

        var literal_length: u32 = cmd & 0x3;
        const offset_index: u32 = cmd >> 6;
        const match_length: u32 = (cmd >> 2) & 0xF;

        // Long literal extension via len_stream.
        if (literal_length == 3) {
            literal_length = @bitCast(len_stream[0]);
            len_stream += 1;
        }

        // Speculative new offset read.
        const new_off: i32 = offs_stream[0];

        // CMOV select picked offset.
        var picked: i32 = ro3;
        if (offset_index >= 1) picked = ro4;
        if (offset_index >= 2) picked = ro5;
        if (offset_index >= 3) picked = new_off;
        const next_ro4: i32 = if (offset_index == 0) ro4 else ro3;
        const next_ro5: i32 = if (offset_index < 2) ro5 else ro4;
        ro3 = picked;
        ro4 = next_ro4;
        ro5 = next_ro5;

        if (offset_index == 3) offs_stream += 1;

        // Match length extension.
        const actual_match_len: usize = blk: {
            if (match_length != 15) break :blk match_length + 2;
            const extra: i32 = len_stream[0];
            len_stream += 1;
            break :blk @intCast(14 + extra);
        };

        // Literal range DAG update — Type 0 only (delta-coded literals
        // depend on byte at P + last_offset).
        if (mode == .delta and literal_length > 0) {
            updateDagRound(byte_round, file_pos_base + dst_off, @as(i64, last_offset), literal_length, file_stats);
        }

        dst_off += literal_length;

        // Match copy DAG update.
        updateDagRound(byte_round, file_pos_base + dst_off, @as(i64, picked), actual_match_len, file_stats);
        dst_off += actual_match_len;

        last_offset = picked;
    }
}

/// Walk the contents of one compressed High chunk's payload, mirroring
/// `high.decodeChunk` but computing DAG rounds instead of executing.
fn analyzeHighChunkPayload(
    allocator: std.mem.Allocator,
    chunk_src: []const u8,
    chunk_dst_size: usize,
    running_dst_off: u64,
    scratch: []align(64) u8,
    dummy_decode_buf: []u8,
    dummy_dst: []u8,
    byte_round: []u16,
    file_stats: *FileStats,
) !void {
    var src_pos: usize = 0;
    var dst_remaining: usize = chunk_dst_size;
    var dst_off_in_chunk: u64 = 0;

    while (dst_remaining != 0) {
        const dst_count: usize = @min(@as(usize, 0x20000), dst_remaining);

        if (src_pos + 4 > chunk_src.len) return error.Truncated;
        const chunkhdr: u32 = (@as(u32, chunk_src[src_pos]) << 16) |
            (@as(u32, chunk_src[src_pos + 1]) << 8) |
            @as(u32, chunk_src[src_pos + 2]);

        if ((chunkhdr & constants.chunk_header_compressed_flag) == 0) {
            // Entropy-only sub-chunk.
            const src_left: usize = chunk_src.len - src_pos;
            const res = try entropy.highDecodeBytes(
                dummy_decode_buf.ptr,
                dst_count,
                chunk_src[src_pos..][0..src_left],
                false,
                scratch.ptr,
                scratch.ptr + scratch.len,
            );
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_count),
                .clean_bytes = @intCast(dst_count),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_count;
            file_stats.total_clean += dst_count;
            src_pos += res.bytes_consumed;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        src_pos += 3;
        const src_used: usize = chunkhdr & 0x7FFFF;
        const mode: u32 = (chunkhdr >> constants.sub_chunk_type_shift) & 0xF;

        if (src_pos + src_used > chunk_src.len) return error.Truncated;

        if (src_used >= dst_count) {
            // Raw / all-equal — no LZ tokens.
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_count),
                .clean_bytes = @intCast(dst_count),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_count;
            file_stats.total_clean += dst_count;
            src_pos += src_used;
            dst_remaining -= dst_count;
            dst_off_in_chunk += dst_count;
            continue;
        }

        // Compressed High sub-chunk: parse via readLzTable.
        const high_lz_table_size: usize = @sizeOf(HighLzTable);
        const lz_ptr: *HighLzTable = @ptrCast(@alignCast(scratch.ptr));
        const inner_scratch: [*]u8 = scratch.ptr + high_lz_table_size;
        const inner_scratch_end: [*]u8 = scratch.ptr + scratch.len;

        const this_base_off: i64 = @intCast(running_dst_off + dst_off_in_chunk);
        try high.readLzTable(
            mode,
            chunk_src[src_pos..].ptr,
            chunk_src[src_pos..].ptr + src_used,
            dummy_dst.ptr,
            @intCast(dst_count),
            this_base_off,
            inner_scratch,
            inner_scratch_end,
            lz_ptr,
        );

        if (mode == 0) {
            analyzeHighSubChunk(.delta, lz_ptr, @intCast(this_base_off), running_dst_off + dst_off_in_chunk, byte_round, file_stats);
        } else {
            analyzeHighSubChunk(.raw, lz_ptr, @intCast(this_base_off), running_dst_off + dst_off_in_chunk, byte_round, file_stats);
        }

        // Append a placeholder SubChunkStats for accounting (clean fraction
        // not computed for High — we focus on DAG metrics).
        try file_stats.sub_chunks.append(allocator, .{
            .total_bytes = @intCast(dst_count),
            .clean_bytes = 0,
            .first_cross_chunk_pos = null,
            .token_count = 0,
            .cross_chunk_token_count = 0,
        });
        file_stats.total_bytes += dst_count;

        src_pos += src_used;
        dst_remaining -= dst_count;
        dst_off_in_chunk += dst_count;
    }
}

/// Mirror of `decompressCompressedBlock` for High codec blocks.
fn analyzeHighBlock(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: u64,
    block_file_pos_base: u64,
    byte_round: []u16,
    file_stats: *FileStats,
) !void {
    const max_chunk: usize = 0x20000;
    const scratch_bytes: usize = constants.scratch_size;
    const scratch = try allocator.alignedAlloc(u8, .@"64", scratch_bytes);
    defer allocator.free(scratch);
    const dummy_decode_buf = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_decode_buf);
    const dummy_dst = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_dst);

    const is_sc = blk: {
        if (block_src.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src.len) return error.Truncated;
    const block_payload: []const u8 = block_src[0 .. block_src.len - prefix_size];

    var src_pos: usize = 0;
    var dst_remaining: u64 = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;
    var dst_off_running: u64 = 0;

    while (dst_remaining > 0) {
        const at_chunk_boundary = (dst_off_running & (constants.chunk_size - 1)) == 0;
        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_payload.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_payload[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const ihdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = @intCast(dst_remaining);

        if (ihdr.uncompressed) {
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            src_pos += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const ch = block_header.parseChunkHeader(block_payload[src_pos..], ihdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_payload.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            src_pos += comp_size;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        try analyzeHighChunkPayload(
            allocator,
            block_payload[src_pos..][0..comp_size],
            dst_this_chunk,
            block_file_pos_base + dst_off_running,
            scratch,
            dummy_decode_buf,
            dummy_dst,
            byte_round,
            file_stats,
        );
        src_pos += comp_size;
        dst_remaining -= dst_this_chunk;
        dst_off_running += dst_this_chunk;
    }
}

/// Mirror of `decompressCompressedBlock` that walks internal block headers
/// and chunk headers, then dispatches each compressed chunk to the
/// payload analyzer above.
fn analyzeFastBlock(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: u64,
    block_file_pos_base: u64,
    byte_round: []u16,
    file_stats: *FileStats,
) !void {
    // Allocate scratch + buffers once per block.
    const max_chunk: usize = 0x20000; // 128 KB
    const scratch_bytes: usize = constants.scratch_size;
    const scratch = try allocator.alignedAlloc(u8, .@"64", scratch_bytes);
    defer allocator.free(scratch);
    const taint = try allocator.alloc(u8, max_chunk);
    defer allocator.free(taint);
    const dummy_decode_buf = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_decode_buf);
    const dummy_dst = try allocator.alloc(u8, max_chunk + safe_space);
    defer allocator.free(dummy_dst);

    // Detect SC mode and account for trailing prefix table (mirrors
    // decompressCompressedBlock setup).
    const is_sc = blk: {
        if (block_src.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src.len) return error.Truncated;
    const block_payload: []const u8 = block_src[0 .. block_src.len - prefix_size];

    var src_pos: usize = 0;
    var dst_remaining: u64 = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;
    var dst_off_running: u64 = 0;

    while (dst_remaining > 0) {
        const at_chunk_boundary = (dst_off_running & (constants.chunk_size - 1)) == 0;
        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_payload.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_payload[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const ihdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = @intCast(dst_remaining);

        if (ihdr.uncompressed) {
            // Raw uncompressed chunk — all clean.
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            src_pos += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        // 4-byte (or 7-byte) chunk header
        const ch = block_header.parseChunkHeader(block_payload[src_pos..], ihdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            // Memset chunk — all bytes are the same, trivially clean.
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_payload.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            // Stored raw within "compressed" flag block — all clean.
            try file_stats.sub_chunks.append(allocator, .{
                .total_bytes = @intCast(dst_this_chunk),
                .clean_bytes = @intCast(dst_this_chunk),
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            file_stats.total_bytes += dst_this_chunk;
            file_stats.total_clean += dst_this_chunk;
            src_pos += comp_size;
            dst_remaining -= dst_this_chunk;
            dst_off_running += dst_this_chunk;
            continue;
        }

        // Real compressed chunk — walk via the payload analyzer.
        try analyzeFastChunkPayload(
            allocator,
            block_payload[src_pos..][0..comp_size],
            dst_this_chunk,
            block_file_pos_base + dst_off_running,
            scratch,
            taint,
            dummy_decode_buf,
            dummy_dst,
            byte_round,
            file_stats,
        );
        src_pos += comp_size;
        dst_remaining -= dst_this_chunk;
        dst_off_running += dst_this_chunk;
    }
}

/// Top-level entry: analyze a complete .slz file and return per-sub-chunk
/// cleanness stats + token-dependency-DAG round histogram.
pub fn analyzeFile(allocator: std.mem.Allocator, src: []const u8) !FileStats {
    var stats: FileStats = .{
        .sub_chunks = .{},
        .total_bytes = 0,
        .total_clean = 0,
        .total_match_tokens = 0,
        .round_histogram = [_]u64{0} ** 65536,
    };
    errdefer stats.deinit(allocator);

    const hdr = try frame.parseHeader(src);
    var src_pos: usize = hdr.header_size;
    const is_high: bool = hdr.codec == .high;
    const is_fast: bool = hdr.codec == .fast or hdr.codec == .turbo;
    if (!is_high and !is_fast) return stats;

    // File-wide byte_round array: 2 bytes per output byte. For a 200 MB
    // file that's 400 MB of working memory.
    const total_decomp: u64 = if (hdr.content_size) |cs| cs else 200 * 1024 * 1024;
    const byte_round = try allocator.alloc(u16, @intCast(total_decomp));
    defer allocator.free(byte_round);
    @memset(byte_round, 0);

    var file_pos_running: u64 = 0;

    while (src_pos < src.len) {
        if (src_pos + 4 > src.len) break;
        const first_word = std.mem.readInt(u32, src[src_pos..][0..4], .little);
        if (first_word == frame.end_mark) {
            src_pos += 4;
            break;
        }

        const bh = try frame.parseBlockHeader(src[src_pos..]);
        if (bh.isEndMark()) break;
        src_pos += 8;

        if (bh.uncompressed) {
            try stats.sub_chunks.append(allocator, .{
                .total_bytes = bh.decompressed_size,
                .clean_bytes = bh.decompressed_size,
                .first_cross_chunk_pos = null,
                .token_count = 0,
                .cross_chunk_token_count = 0,
            });
            stats.total_bytes += bh.decompressed_size;
            stats.total_clean += bh.decompressed_size;
            src_pos += bh.compressed_size;
            file_pos_running += bh.decompressed_size;
            continue;
        }

        const block_payload = src[src_pos..][0..bh.compressed_size];
        if (is_high) {
            try analyzeHighBlock(allocator, block_payload, bh.decompressed_size, file_pos_running, byte_round, &stats);
        } else {
            try analyzeFastBlock(allocator, block_payload, bh.decompressed_size, file_pos_running, byte_round, &stats);
        }
        src_pos += bh.compressed_size;
        file_pos_running += bh.decompressed_size;
    }

    return stats;
}
