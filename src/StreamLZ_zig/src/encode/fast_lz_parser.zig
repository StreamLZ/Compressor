//! Greedy Fast LZ parser. Direct port of `FastParser.RunGreedyParser` in
//! src/StreamLZ/Compression/Fast/FastParser.cs.
//!
//! Hot-loop design:
//!   * All pointers are `[*]u8` — no slice bounds checks.
//!   * Hash table, multiplier, and shift are pulled into locals so they stay
//!     in registers across the hot loop.
//!   * The recent-offset match path (first branch) is the ~60% common case
//!     on compressible data; branch-hinted `.likely`.
//!   * `comptime level` lets each specialization fold out the level-dependent
//!     branches (rehash, 2/3-byte recent match).
//!
//! The parser operates over a single "block" (≤ 64 KB half of a 128 KB
//! sub-chunk). Its caller is responsible for splitting the source into
//! block1/block2 and invoking `runGreedyParser` twice.

const std = @import("std");
const fast_constants = @import("fast_constants.zig");
const FastMatchHasher = @import("fast_match_hasher.zig").FastMatchHasher;
const writer_mod = @import("fast_stream_writer.zig");
const token_writer = @import("fast_token_writer.zig");

const FastStreamWriter = writer_mod.FastStreamWriter;

/// Runs a single-block greedy parse. On entry, `source_cursor` points at the
/// first byte to process; `literal_start_in` points at the first unmatched
/// byte (usually the same as `source_cursor` at block start). On return,
/// any trailing literals have been copied to the writer.
///
/// `recent_offset_inout` is read/written — the initial value is -8 at the
/// top of a sub-chunk; for block2 it carries over from block1.
///
/// `source_block_base` is the base pointer of the source sub-chunk. Used to
/// compute positions relative to the sub-chunk start.
///
/// `min_match_length_table` has 32 entries indexed by `31 - log2(offset)`.
pub fn runGreedyParser(
    comptime level: i32,
    comptime T: type,
    w: *FastStreamWriter,
    hasher: *FastMatchHasher(T),
    source_cursor_in: [*]const u8,
    safe_source_end: [*]const u8,
    source_end: [*]const u8,
    recent_offset_inout: *isize,
    dictionary_size: u32,
    min_match_length_table: *const [32]u32,
    source_block_base: [*]const u8,
) void {
    // Hoist into locals.
    const hash_table = hasher.hash_table;
    const hash_mult = hasher.hash_mult;
    const hash_shift = hasher.hash_shift;

    // Parser-local recent offset (signed negative distance).
    var recent_offset: isize = recent_offset_inout.*;

    const skip_factor: u6 = if (level <= -3) 3 else if (level <= 1) 4 else 5;
    var skip_accumulator: u32 = @as(u32, 1) << skip_factor;

    var source_cursor: [*]const u8 = source_cursor_in;
    var literal_start: [*]const u8 = source_cursor_in;

    // Loop guard: keep 5 bytes of lookahead + guard.
    if (@intFromPtr(source_cursor) + 5 >= @intFromPtr(safe_source_end)) {
        token_writer.copyTrailingLiterals(w, literal_start, source_end);
        recent_offset_inout.* = recent_offset;
        return;
    }

    outer: while (true) {
        const bytes_at_cursor: u32 = std.mem.readInt(u32, source_cursor[0..4], .little);
        const word_at_cursor: u64 = std.mem.readInt(u64, source_cursor[0..8], .little);
        const hash_index: usize = @intCast((word_at_cursor *% hash_mult) >> hash_shift);
        const stored_pos: u32 = @intCast(hash_table[hash_index]);

        const cur_pos_in_block: usize = @intFromPtr(source_cursor) - @intFromPtr(source_block_base);
        hash_table[hash_index] = @intCast(@as(u32, @truncate(cur_pos_in_block)));

        // Recent-offset candidate.
        const recent_src_addr: usize = @intFromPtr(source_cursor) +% @as(usize, @bitCast(recent_offset));
        const recent_src_ptr: [*]const u8 = @ptrFromInt(recent_src_addr);
        const recent_word: u32 = std.mem.readInt(u32, recent_src_ptr[0..4], .little);
        const xor_value: u32 = bytes_at_cursor ^ recent_word;

        var found_match = false;
        var offset_or_recent: u32 = 0;
        var current_offset: isize = 0;
        var match_end: [*]const u8 = undefined;

        if ((xor_value & 0xFFFFFF00) == 0) {
            @branchHint(.likely);
            // 1-byte literal + at least 3-byte recent match.
            source_cursor += 1;
            offset_or_recent = 0;
            const pos2: usize = @intFromPtr(source_cursor) - @intFromPtr(source_block_base);
            const word2: u64 = std.mem.readInt(u64, source_cursor[0..8], .little);
            const hi2: usize = @intCast((word2 *% hash_mult) >> hash_shift);
            hash_table[hi2] = @intCast(@as(u32, @truncate(pos2)));
            current_offset = recent_offset;
            match_end = token_writer.extendMatchForward(source_cursor + 3, safe_source_end, current_offset);
            found_match = true;
        } else {
            // Try hash-table match.
            const cur_pos_u32: u32 = @as(u32, @truncate(cur_pos_in_block));
            const offset_candidate: u32 = cur_pos_u32 -% stored_pos;

            if (offset_candidate >= 8 and offset_candidate < dictionary_size and
                offset_candidate <= cur_pos_u32)
            {
                const match_base_addr: usize = @intFromPtr(source_cursor) -% offset_candidate;
                const match_base_ptr: [*]const u8 = @ptrFromInt(match_base_addr);
                const candidate_word: u32 = std.mem.readInt(u32, match_base_ptr[0..4], .little);
                if (bytes_at_cursor == candidate_word) {
                    const ext_end = token_writer.extendMatchForward(
                        source_cursor + 4,
                        safe_source_end,
                        -@as(isize, @intCast(offset_candidate)),
                    );
                    const match_len: usize = @intFromPtr(ext_end) - @intFromPtr(source_cursor);
                    // Table index is `31 - log2(offset)` which equals `@clz(offset)`
                    // for u32. Near offsets (bit 16 and below) have small indexes
                    // (>=16) mapping to minimum_match_length; far offsets have
                    // smaller indexes mapping to the long-match threshold.
                    const log2_idx: u5 = @intCast(@clz(offset_candidate));
                    const min_len: u32 = min_match_length_table[log2_idx];
                    if (match_len >= min_len) {
                        offset_or_recent = offset_candidate;
                        current_offset = -@as(isize, @intCast(offset_candidate));
                        match_end = ext_end;
                        found_match = true;
                    }
                }
            }

            // Fallback: offset-8 match.
            if (!found_match) {
                const off8_src_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% 8);
                const off8_word: u32 = std.mem.readInt(u32, off8_src_ptr[0..4], .little);
                if (bytes_at_cursor == off8_word) {
                    offset_or_recent = 8;
                    current_offset = -8;
                    match_end = token_writer.extendMatchForward(source_cursor + 4, safe_source_end, -8);
                    found_match = true;
                }
            }

            // Level ≥ 2: try 2/3-byte recent match when the first 2 bytes match.
            if (comptime level >= 2) {
                if (!found_match and (xor_value & 0xFFFF) == 0) {
                    offset_or_recent = 0;
                    current_offset = recent_offset;
                    const extra: usize = if ((xor_value & 0xFFFFFF) == 0) 3 else 2;
                    match_end = source_cursor + extra;
                    found_match = true;
                }
            }
        }

        if (!found_match) {
            @branchHint(.unlikely);
            const step: u32 = skip_accumulator >> skip_factor;
            const remaining: usize = @intFromPtr(safe_source_end) - 5 - @intFromPtr(source_cursor);
            if (remaining <= step) break :outer;

            if (comptime level >= -2) {
                skip_accumulator += 1;
            } else {
                const run_len: usize = @intFromPtr(source_cursor) - @intFromPtr(literal_start);
                const grow: u32 = @intCast(@min(run_len >> 1, 296));
                const sum: u32 = skip_accumulator + grow;
                skip_accumulator = @min(sum, @as(u32, 296));
            }

            source_cursor += step;
            continue :outer;
        }

        // Extend match backward into the literal run (up to 4 bytes typically).
        while (@intFromPtr(source_cursor) > @intFromPtr(literal_start)) {
            const cursor_prev_addr: usize = @intFromPtr(source_cursor) - 1;
            const back_match_addr: usize = cursor_prev_addr +% @as(usize, @bitCast(current_offset));
            if (back_match_addr < @intFromPtr(source_block_base)) break;
            const cur_byte: u8 = @as([*]const u8, @ptrFromInt(cursor_prev_addr))[0];
            const back_byte: u8 = @as([*]const u8, @ptrFromInt(back_match_addr))[0];
            if (cur_byte != back_byte) break;
            source_cursor -= 1;
        }

        const match_length: u32 = @intCast(@intFromPtr(match_end) - @intFromPtr(source_cursor));
        const lit_run_length: u32 = @intCast(@intFromPtr(source_cursor) - @intFromPtr(literal_start));

        token_writer.writeOffset(
            w,
            match_length,
            lit_run_length,
            offset_or_recent,
            recent_offset,
            literal_start,
        );

        literal_start = match_end;
        source_cursor = match_end;
        skip_accumulator = @as(u32, 1) << skip_factor;
        recent_offset = current_offset;

        if (@intFromPtr(source_cursor) + 5 >= @intFromPtr(safe_source_end)) break :outer;

        // Level ≥ 2: rehash match interior at exponential intervals.
        if (comptime level >= 2) {
            const match_start_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) - match_length);
            var i: u32 = 1;
            while (i < match_length) : (i *%= 2) {
                const rehash_ptr = match_start_ptr + i;
                const rw: u64 = std.mem.readInt(u64, rehash_ptr[0..8], .little);
                const rh: usize = @intCast((rw *% hash_mult) >> hash_shift);
                const rpos: usize = @intFromPtr(rehash_ptr) - @intFromPtr(source_block_base);
                hash_table[rh] = @intCast(@as(u32, @truncate(rpos)));
                if (i >= match_length) break;
            }
        }
    }

    token_writer.copyTrailingLiterals(w, literal_start, source_end);
    recent_offset_inout.* = recent_offset;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "runGreedyParser runs over a short source without crashing" {
    // Pattern with a clear repetition: "abcdefghabcdefghabcdefgh..."
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('a' + (i % 8));

    var hasher = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 12, .min_match_length = 4 });
    defer hasher.deinit();

    var w = try FastStreamWriter.init(testing.allocator, &src, src.len, null);
    defer w.deinit(testing.allocator);

    var mmlt: [32]u32 = undefined;
    fast_constants.buildMinimumMatchLengthTable(&mmlt, 4, 14);

    var recent: isize = -8;
    runGreedyParser(
        1,
        u32,
        &w,
        &hasher,
        src[fast_constants.initial_copy_bytes..].ptr,
        src[0..].ptr + src.len - 16,
        src[0..].ptr + src.len,
        &recent,
        @intCast(src.len),
        &mmlt,
        src[0..].ptr,
    );

    // On a repeating pattern the parser should emit at least one match.
    try testing.expect(w.tokenCount() > 0);
}
