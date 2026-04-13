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
const match_hasher = @import("match_hasher.zig");
const writer_mod = @import("fast_stream_writer.zig");
const token_writer = @import("fast_token_writer.zig");

const FastStreamWriter = writer_mod.FastStreamWriter;
const MatchHasher2x = match_hasher.MatchHasher2x;
const HasherHashPos = match_hasher.HasherHashPos;

/// (length, offset) pair returned by the hash-based match finders. Offset 0
/// means "reuse the parser's current recent offset".
pub const LengthAndOffset = struct {
    length: i32,
    offset: i32,
};

/// Runs a single-block greedy parse. On entry, `source_cursor` points at the
/// first byte to process; `literal_start_in` points at the first unmatched
/// byte (usually the same as `source_cursor` at block start). On return,
/// any trailing literals have been copied to the writer.
///
/// `recent_offset_inout` is read/written — the initial value is -8 at the
/// top of a sub-chunk; for block2 it carries over from block1.
///
/// `source_block_base` is the base pointer of the source SUB-CHUNK. Used for
/// the bound check `offset <= cursor - source_block_base` which rejects
/// candidates reaching before the current sub-chunk's start.
///
/// `window_base` is the base pointer of the whole COMPRESS WINDOW (the
/// pointer that hash-table-stored positions are measured from). For the
/// C# parity behavior we use `src.ptr` — the hash table is persistent
/// across sub-chunks, and stored positions are in whole-input coordinates.
/// Cross-sub-chunk stale entries then give huge offsets that fail the
/// sub-chunk-local bound check, matching C# `RunGreedyParser`.
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
    window_base: [*]const u8,
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
        token_writer.copyTrailingLiterals(w, literal_start, source_end, recent_offset);
        recent_offset_inout.* = recent_offset;
        return;
    }

    outer: while (true) {
        const bytes_at_cursor: u32 = std.mem.readInt(u32, source_cursor[0..4], .little);
        const word_at_cursor: u64 = std.mem.readInt(u64, source_cursor[0..8], .little);
        const hash_index: usize = @intCast((word_at_cursor *% hash_mult) >> hash_shift);
        // `stored_pos` is a position TRUNCATED to T's width (u16 or u32). The
        // offset is computed as `(cur_pos_T - stored_pos_T)` with wrap-around
        // mod 2^width, matching C# `T.CreateTruncating(...)` semantics. For
        // T=u16 this means offsets > 65535 collapse into apparent small
        // offsets and get filtered by the byte comparison below.
        const stored_pos_t: T = hash_table[hash_index];

        // Storage coordinate: position within the WHOLE input (measured
        // from window_base). Bound coordinate: position within the
        // current SUB-CHUNK (measured from source_block_base).
        const cur_pos_in_window: usize = @intFromPtr(source_cursor) - @intFromPtr(window_base);
        const cur_pos_in_block: usize = @intFromPtr(source_cursor) - @intFromPtr(source_block_base);
        const cur_pos_t: T = @truncate(cur_pos_in_window);
        hash_table[hash_index] = cur_pos_t;

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
            // Pre-advance hash insert: store the NEXT cursor (cursor+1) in
            // whole-input coordinates so the next iteration's lookup sees it.
            const pos2: usize = @intFromPtr(source_cursor) - @intFromPtr(window_base);
            const word2: u64 = std.mem.readInt(u64, source_cursor[0..8], .little);
            const hi2: usize = @intCast((word2 *% hash_mult) >> hash_shift);
            hash_table[hi2] = @truncate(pos2);
            current_offset = recent_offset;
            match_end = token_writer.extendMatchForward(source_cursor + 3, safe_source_end, current_offset);
            found_match = true;
        } else {
            // Try hash-table match. Offset is computed T-width and widened.
            // For T=u16 this wraps mod 65536; stale entries from > 64 KB
            // ago will appear as small offsets and get filtered by the
            // byte comparison at `source_cursor[-offset]` which mismatches
            // for wrong-direction candidates.
            const offset_candidate_t: T = cur_pos_t -% stored_pos_t;
            const offset_candidate: u32 = @intCast(offset_candidate_t);
            const cur_pos_for_bound: u32 = @truncate(cur_pos_in_block);

            if (offset_candidate >= 8 and offset_candidate < dictionary_size and
                offset_candidate <= cur_pos_for_bound)
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

        // Extend match backward into the literal run. C# FastParser.cs:142 bounds
        // the extension with:
        //   (sourceBlock - sourceCursor) + hasherBaseAdjustment < currentOffset
        // With hasherBaseAdjustment = SrcBaseOffset - blockBasePosition = -startPos,
        // and sourceBlock = the current SUB-CHUNK base pointer, this simplifies to
        //   -(absolutePos) < currentOffset ⟺ absolutePos > |offset|
        // i.e., the bound is the WHOLE-INPUT base (`window_base`), NOT the sub-chunk
        // base. Cross-sub-chunk backward extension is legal because earlier sub-chunks
        // already exist in the output buffer by the time the decoder processes the
        // current one.
        while (@intFromPtr(source_cursor) > @intFromPtr(literal_start)) {
            const cursor_prev_addr: usize = @intFromPtr(source_cursor) - 1;
            const back_match_addr: usize = cursor_prev_addr +% @as(usize, @bitCast(current_offset));
            if (back_match_addr < @intFromPtr(window_base)) break;
            const cur_byte: u8 = @as([*]const u8, @ptrFromInt(cursor_prev_addr))[0];
            const back_byte: u8 = @as([*]const u8, @ptrFromInt(back_match_addr))[0];
            if (cur_byte != back_byte) break;
            source_cursor -= 1;
        }

        const match_length: u32 = @intCast(@intFromPtr(match_end) - @intFromPtr(source_cursor));
        const lit_run_length: u32 = @intCast(@intFromPtr(source_cursor) - @intFromPtr(literal_start));

        if (std.process.hasEnvVarConstant("SLZ_TOKEN_TRACE")) {
            const src_pos: usize = @intFromPtr(source_cursor) - @intFromPtr(source_block_base);
            std.debug.print("[tok] pos={d} lit={d} mlen={d} off={d} curOff={d}\n", .{
                src_pos, lit_run_length, match_length, offset_or_recent, current_offset,
            });
        }

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
        // Stored positions are in WHOLE-INPUT coordinates (window_base).
        if (comptime level >= 2) {
            const match_start_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) - match_length);
            var i: u32 = 1;
            while (i < match_length) : (i *%= 2) {
                const rehash_ptr = match_start_ptr + i;
                const rw: u64 = std.mem.readInt(u64, rehash_ptr[0..8], .little);
                const rh: usize = @intCast((rw *% hash_mult) >> hash_shift);
                const rpos: usize = @intFromPtr(rehash_ptr) - @intFromPtr(window_base);
                hash_table[rh] = @truncate(rpos);
                if (i >= match_length) break;
            }
        }
    }

    token_writer.copyTrailingLiterals(w, literal_start, source_end, recent_offset);
    recent_offset_inout.* = recent_offset;
}

// ────────────────────────────────────────────────────────────
//  Lazy-parser helpers (port of Matcher.cs)
// ────────────────────────────────────────────────────────────

/// Count matching bytes 8-then-4 wide, starting at `p`. Port of
/// `MatchEvaluation.CountMatchingBytes`. Returns how many bytes past `p`
/// continue to match the source at `p - offset`. `offset` is positive.
inline fn countMatchingBytes(p: [*]const u8, p_end: [*]const u8, offset: usize) usize {
    var cur = p;
    var len: usize = 0;
    while (@intFromPtr(p_end) -| @intFromPtr(cur) >= 8) {
        const a: u64 = std.mem.readInt(u64, cur[0..8], .little);
        const b_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(cur) - offset);
        const b: u64 = std.mem.readInt(u64, b_ptr[0..8], .little);
        if (a != b) {
            const xor = a ^ b;
            return len + (@as(usize, @ctz(xor)) >> 3);
        }
        cur += 8;
        len += 8;
    }
    if (@intFromPtr(p_end) -| @intFromPtr(cur) >= 4) {
        const a: u32 = std.mem.readInt(u32, cur[0..4], .little);
        const b_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(cur) - offset);
        const b: u32 = std.mem.readInt(u32, b_ptr[0..4], .little);
        if (a != b) {
            const xor = a ^ b;
            return len + (@as(usize, @ctz(xor)) >> 3);
        }
        cur += 4;
        len += 4;
    }
    // Byte-wise tail.
    while (@intFromPtr(cur) < @intFromPtr(p_end)) {
        const bp: [*]const u8 = @ptrFromInt(@intFromPtr(cur) - offset);
        if (cur[0] != bp[0]) break;
        cur += 1;
        len += 1;
    }
    return len;
}

/// Is `(match_length, match_offset)` better than `(best_length, best_offset)`?
/// Straight port of `Matcher.IsMatchBetter`.
inline fn isMatchBetter(match_length: i32, match_offset: i32, best_length: i32, best_offset: i32) bool {
    if (match_length == best_length) return match_offset < best_offset;
    if ((match_offset <= 0xffff) == (best_offset <= 0xffff)) return match_length > best_length;
    if (best_offset <= 0xffff) return match_length > best_length + 5;
    return match_length >= best_length - 5;
}

/// Is the current hash match preferable to reusing the recent-offset match?
inline fn isBetterThanRecentMatch(recent_match_length: i32, match_length: i32, match_offset: i32) bool {
    return recent_match_length < 2 or
        (recent_match_length + 1 < match_length and (recent_match_length + 4 < match_length or match_offset < 65536));
}

/// Is the lazy candidate worth the step delay over `current`?
inline fn isLazyMatchBetter(cand: LengthAndOffset, current: LengthAndOffset, step: i32) bool {
    const bits_cand: i32 = if (cand.offset > 0) (if (cand.offset > 0xffff) 32 else 16) else 0;
    const bits_cur: i32 = if (current.offset > 0) (if (current.offset > 0xffff) 32 else 16) else 0;
    return 5 * (cand.length - current.length) - 5 - (bits_cand - bits_cur) > step * 4;
}

/// Hash-based match finder used by the lazy parser. `comptime num_hash` is
/// the bucket width (2 for L3). Direct port of `Matcher.FindMatchWithHasher`.
///
/// `next_cursor_ptr` is where the caller wants the hasher to prefetch next —
/// usually `source_cursor + 1` so the next parser iteration finds the hash
/// bucket hot in L1.
pub fn findMatchWithHasher(
    comptime num_hash: u32,
    source_cursor: [*]const u8,
    safe_source_end: [*]const u8,
    literal_start: [*]const u8,
    recent_offset: isize,
    hasher: *match_hasher.MatchHasher(num_hash),
    next_cursor_ptr: [*]const u8,
    dictionary_size: u32,
    minimum_match_length_in: u32,
    min_match_length_table: *const [32]u32,
) LengthAndOffset {
    const hp = hasher.getHashPos(source_cursor);
    const bytes_at_source: u32 = std.mem.readInt(u32, source_cursor[0..4], .little);
    hasher.setHashPosPrefetch(next_cursor_ptr);

    // ── Recent-offset match path ───────────────────────────────────────
    const recent_src_addr: usize = @intFromPtr(source_cursor) +% @as(usize, @bitCast(recent_offset));
    const recent_src_ptr: [*]const u8 = @ptrFromInt(recent_src_addr);
    const recent_word: u32 = std.mem.readInt(u32, recent_src_ptr[0..4], .little);
    const xor_value: u32 = recent_word ^ bytes_at_source;
    if (xor_value == 0) {
        const ext_end = token_writer.extendMatchForward(source_cursor + 4, safe_source_end, recent_offset);
        const match_len: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
        hasher.insert(hp);
        return .{ .length = @intCast(match_len), .offset = 0 };
    }
    var recent_match_length: i32 = @intCast(@as(u32, @ctz(xor_value)) >> 3);

    var minimum_match_length: i32 = @intCast(minimum_match_length_in);
    if (@intFromPtr(source_cursor) - @intFromPtr(literal_start) >= 64) {
        if (recent_match_length < 3) recent_match_length = 0;
        minimum_match_length += 1;
    }
    var best_offset: i32 = 0;
    var best_match_length: i32 = minimum_match_length - 1;

    // ── Hash bucket scan ───────────────────────────────────────────────
    const hash_table = hasher.hash_table;
    const cur_from_base: usize = @intFromPtr(source_cursor) - @intFromPtr(hasher.src_base);
    const tag_mask: u32 = 0xfc000000;
    const off_mask: u32 = 0x3ffffff;
    const tag_masked: u32 = hp.tag & tag_mask;

    comptime var entry_index: u32 = 0;
    inline while (entry_index < num_hash) : (entry_index += 1) {
        const stored: u32 = hash_table[hp.ptr1_index + entry_index];
        if ((stored & tag_mask) == tag_masked) {
            const candidate_offset: u32 = (hp.pos -% stored) & off_mask;
            if (candidate_offset > 8 and candidate_offset < dictionary_size and
                @as(usize, candidate_offset) <= cur_from_base)
            {
                const cand_base: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% @as(usize, candidate_offset));
                const cand_word: u32 = std.mem.readInt(u32, cand_base[0..4], .little);
                if (cand_word == bytes_at_source) {
                    const ext_end = token_writer.extendMatchForward(
                        source_cursor + 4,
                        safe_source_end,
                        -@as(isize, @intCast(candidate_offset)),
                    );
                    const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
                    const cand_len: i32 = @intCast(cand_len_u);
                    // Index is `31 - log2(offset) = @clz(offset)` for u32.
                    const mmlt_idx: u5 = @intCast(@clz(candidate_offset));
                    const min_len_here: i32 = @intCast(min_match_length_table[mmlt_idx]);
                    if (cand_len > best_match_length and cand_len >= min_len_here and
                        isMatchBetter(cand_len, @intCast(candidate_offset), best_match_length, best_offset))
                    {
                        best_offset = @intCast(candidate_offset);
                        best_match_length = cand_len;
                    }
                }
            }
        }
    }

    // ── Offset-8 fallback ──────────────────────────────────────────────
    {
        const off8_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% 8);
        const off8_word: u32 = std.mem.readInt(u32, off8_ptr[0..4], .little);
        if (off8_word == bytes_at_source) {
            const ext_end = token_writer.extendMatchForward(source_cursor + 4, safe_source_end, -8);
            const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
            const cand_len: i32 = @intCast(cand_len_u);
            if (cand_len >= best_match_length and cand_len >= minimum_match_length) {
                best_match_length = cand_len;
                best_offset = 8;
            }
        }
    }

    hasher.insert(hp);

    if (best_offset == 0 or !isBetterThanRecentMatch(recent_match_length, best_match_length, best_offset)) {
        best_match_length = recent_match_length;
        best_offset = 0;
    }
    return .{ .length = best_match_length, .offset = best_offset };
}

/// Lazy parser driving a `MatchHasher(num_hash)` — port of
/// `FastParser.RunLazyParser`. Emits directly to the supplied writer; on
/// return, trailing literals have been copied.
///
/// `engine_level` selects the lazy depth:
///   * <= 1 → lazy-1 only (user level 3)
///   * > 1  → lazy-1 + lazy-2 (unused by the 2x hasher path today)
pub fn runLazyParser(
    comptime engine_level: i32,
    comptime num_hash: u32,
    w: *FastStreamWriter,
    hasher: *match_hasher.MatchHasher(num_hash),
    source_cursor_in: [*]const u8,
    safe_source_end: [*]const u8,
    source_end: [*]const u8,
    recent_offset_inout: *isize,
    dictionary_size: u32,
    min_match_length_table: *const [32]u32,
    minimum_match_length: u32,
) void {
    var recent_offset: isize = recent_offset_inout.*;
    var source_cursor: [*]const u8 = source_cursor_in;
    var literal_start: [*]const u8 = source_cursor_in;

    const guard_addr = @intFromPtr(safe_source_end) -| 5;
    if (@intFromPtr(source_cursor) < guard_addr) {
        hasher.setHashPos(source_cursor);

        while (@intFromPtr(source_cursor) + 1 < guard_addr) {
            var match = findMatchWithHasher(
                num_hash,
                source_cursor,
                safe_source_end,
                literal_start,
                recent_offset,
                hasher,
                source_cursor + 1,
                dictionary_size,
                minimum_match_length,
                min_match_length_table,
            );
            if (match.length < 2) {
                source_cursor += 1;
                continue;
            }

            // Lazy evaluation loop.
            while (@intFromPtr(source_cursor) + 1 < guard_addr) {
                const lazy1 = findMatchWithHasher(
                    num_hash,
                    source_cursor + 1,
                    safe_source_end,
                    literal_start,
                    recent_offset,
                    hasher,
                    source_cursor + 2,
                    dictionary_size,
                    minimum_match_length,
                    min_match_length_table,
                );
                if (lazy1.length >= 2 and isLazyMatchBetter(lazy1, match, 0)) {
                    source_cursor += 1;
                    match = lazy1;
                } else {
                    if (comptime engine_level <= 3) break;
                    if (@intFromPtr(source_cursor) + 2 > guard_addr or match.length == 2) break;
                    const lazy2 = findMatchWithHasher(
                        num_hash,
                        source_cursor + 2,
                        safe_source_end,
                        literal_start,
                        recent_offset,
                        hasher,
                        source_cursor + 3,
                        dictionary_size,
                        minimum_match_length,
                        min_match_length_table,
                    );
                    if (lazy2.length >= 2 and isLazyMatchBetter(lazy2, match, 1)) {
                        source_cursor += 2;
                        match = lazy2;
                    } else break;
                }
            }

            // actual_offset is the positive distance used for writes and for
            // backward extension. For recent-offset matches it's `-recent`.
            const actual_offset: isize = if (match.offset == 0)
                -recent_offset
            else
                @intCast(match.offset);

            // Extend backward into the literal run.
            while (@intFromPtr(source_cursor) > @intFromPtr(literal_start)) {
                const cursor_prev_addr: usize = @intFromPtr(source_cursor) - 1;
                if (cursor_prev_addr < @intFromPtr(hasher.src_base) + @as(usize, @bitCast(@as(i64, actual_offset)))) break;
                const back_addr: usize = cursor_prev_addr - @as(usize, @bitCast(@as(i64, actual_offset)));
                const cur_b: u8 = @as([*]const u8, @ptrFromInt(cursor_prev_addr))[0];
                const back_b: u8 = @as([*]const u8, @ptrFromInt(back_addr))[0];
                if (cur_b != back_b) break;
                source_cursor -= 1;
                match.length += 1;
            }

            const match_length_u: u32 = @intCast(match.length);
            const lit_run_u: u32 = @intCast(@intFromPtr(source_cursor) - @intFromPtr(literal_start));
            const offset_or_recent: u32 = @intCast(match.offset);

            token_writer.writeOffsetWithLiteral1(
                w,
                match_length_u,
                lit_run_u,
                offset_or_recent,
                recent_offset,
                literal_start,
            );

            recent_offset = -actual_offset;
            source_cursor += match_length_u;
            literal_start = source_cursor;

            if (@intFromPtr(source_cursor) >= guard_addr) break;
            const match_start: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) - match_length_u);
            hasher.insertRange(match_start, match_length_u);
        }
    }

    token_writer.copyTrailingLiterals(w, literal_start, source_end, recent_offset);
    recent_offset_inout.* = recent_offset;
}

// ────────────────────────────────────────────────────────────
//  Chain-hasher lazy parser (MatchHasher2, user level 4)
// ────────────────────────────────────────────────────────────

/// Hash-based match finder that walks the firstHash chain, optionally
/// dereferences the longHash secondary table, and falls back to offset 8.
/// Port of `Matcher.FindMatchWithChainHasher`.
pub fn findMatchWithChainHasher(
    source_cursor: [*]const u8,
    safe_source_end: [*]const u8,
    literal_start: [*]const u8,
    recent_offset: isize,
    hasher: *match_hasher.MatchHasher2,
    next_cursor_ptr: [*]const u8,
    dictionary_size: u32,
    minimum_match_length_in: u32,
    min_match_length_table: *const [32]u32,
) LengthAndOffset {
    const hp = hasher.getHashPos(source_cursor);
    const bytes_at_source: u32 = std.mem.readInt(u32, source_cursor[0..4], .little);
    hasher.setHashPosPrefetch(next_cursor_ptr);

    // ── Recent-offset match path ───────────────────────────────────────
    const recent_src_addr: usize = @intFromPtr(source_cursor) +% @as(usize, @bitCast(recent_offset));
    const recent_src_ptr: [*]const u8 = @ptrFromInt(recent_src_addr);
    const recent_word: u32 = std.mem.readInt(u32, recent_src_ptr[0..4], .little);
    const xor_value: u32 = recent_word ^ bytes_at_source;
    if (xor_value == 0) {
        const ext_end = token_writer.extendMatchForward(source_cursor + 4, safe_source_end, recent_offset);
        const match_len: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
        hasher.insert(hp);
        return .{ .length = @intCast(match_len), .offset = 0 };
    }
    var recent_match_length: i32 = @intCast(@as(u32, @ctz(xor_value)) >> 3);

    var minimum_match_length: i32 = @intCast(minimum_match_length_in);
    if (@intFromPtr(source_cursor) - @intFromPtr(literal_start) >= 64) {
        if (recent_match_length < 3) recent_match_length = 0;
        minimum_match_length += 1;
    }

    var best_offset: i32 = 0;
    var best_match_length: i32 = 0;

    const first_hash = hasher.first_hash;
    const next_hash = hasher.next_hash;
    const long_hash = hasher.long_hash;

    const cur_from_base: usize = @intFromPtr(source_cursor) - @intFromPtr(hasher.src_base);

    // ── First-hash chain walk ──────────────────────────────────────────
    var hash_value: u32 = first_hash[hp.hash_a];
    var candidate_offset: u32 = hp.pos -% hash_value;
    if (candidate_offset <= 0xffff) {
        if (candidate_offset != 0) {
            var chain_steps: u32 = 8;
            while (candidate_offset < dictionary_size) {
                if (candidate_offset > 8) {
                    if (@as(usize, candidate_offset) <= cur_from_base) {
                        const cand_base: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% @as(usize, candidate_offset));
                        const cand_word: u32 = std.mem.readInt(u32, cand_base[0..4], .little);
                        if (cand_word == bytes_at_source) {
                            // Three-stage filter: also require the byte at
                            // `best_match_length` to agree before the full
                            // extension (cheaper rejection on long candidates).
                            var quick_ok = true;
                            if (best_match_length >= 4) {
                                const tail_addr: usize = @intFromPtr(source_cursor) + @as(usize, @intCast(best_match_length));
                                if (tail_addr >= @intFromPtr(safe_source_end)) {
                                    quick_ok = false;
                                } else {
                                    const s_byte: u8 = @as([*]const u8, @ptrFromInt(tail_addr))[0];
                                    const m_byte: u8 = @as([*]const u8, @ptrFromInt(tail_addr - candidate_offset))[0];
                                    if (s_byte != m_byte) quick_ok = false;
                                }
                            }
                            if (quick_ok) {
                                const ext_end = token_writer.extendMatchForward(
                                    source_cursor + 4,
                                    safe_source_end,
                                    -@as(isize, @intCast(candidate_offset)),
                                );
                                const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
                                const cand_len: i32 = @intCast(cand_len_u);
                                if (cand_len > best_match_length and cand_len >= minimum_match_length) {
                                    best_match_length = cand_len;
                                    best_offset = @intCast(candidate_offset);
                                }
                            }
                        }
                    }
                    chain_steps -= 1;
                    if (chain_steps == 0) break;
                }
                const previous_offset: u32 = candidate_offset;
                hash_value = next_hash[hash_value & 0xFFFF];
                // Chain positions are stored modulo 64K — subtract as u16.
                candidate_offset = @as(u16, @truncate(@as(u32, @intCast(hp.pos)) -% hash_value));
                if (candidate_offset <= previous_offset) break;
            }
        }
    } else if (candidate_offset < dictionary_size and
        @as(usize, candidate_offset) <= cur_from_base)
    {
        const cand_base: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% @as(usize, candidate_offset));
        const cand_word: u32 = std.mem.readInt(u32, cand_base[0..4], .little);
        if (cand_word == bytes_at_source) {
            const ext_end = token_writer.extendMatchForward(
                source_cursor + 4,
                safe_source_end,
                -@as(isize, @intCast(candidate_offset)),
            );
            const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
            const cand_len: i32 = @intCast(cand_len_u);
            const mmlt_idx: u5 = @intCast(@clz(candidate_offset));
            const min_len_here: i32 = @intCast(min_match_length_table[mmlt_idx]);
            if (cand_len > minimum_match_length and cand_len >= min_len_here) {
                best_match_length = cand_len;
                best_offset = @intCast(candidate_offset);
            }
        }
    }

    // ── Long-hash secondary table ──────────────────────────────────────
    {
        const lh_value: u32 = long_hash[hp.hash_b];
        if (((hp.hash_b_tag ^ lh_value) & 0x3F) == 0) {
            const cand_off: u32 = hp.pos -% (lh_value >> 6);
            if (cand_off >= 8 and cand_off < dictionary_size and
                @as(usize, cand_off) <= cur_from_base)
            {
                const cand_base: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% @as(usize, cand_off));
                const cand_word: u32 = std.mem.readInt(u32, cand_base[0..4], .little);
                if (cand_word == bytes_at_source) {
                    const ext_end = token_writer.extendMatchForward(
                        source_cursor + 4,
                        safe_source_end,
                        -@as(isize, @intCast(cand_off)),
                    );
                    const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
                    const cand_len: i32 = @intCast(cand_len_u);
                    const mmlt_idx: u5 = @intCast(@clz(cand_off));
                    const min_len_here: i32 = @intCast(min_match_length_table[mmlt_idx]);
                    if (cand_len >= min_len_here and
                        isMatchBetter(cand_len, @intCast(cand_off), best_match_length, best_offset))
                    {
                        best_match_length = cand_len;
                        best_offset = @intCast(cand_off);
                    }
                }
            }
        }
    }

    // ── Fixed-offset-8 fallback ────────────────────────────────────────
    {
        const off8_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) -% 8);
        const off8_word: u32 = std.mem.readInt(u32, off8_ptr[0..4], .little);
        if (off8_word == bytes_at_source) {
            const ext_end = token_writer.extendMatchForward(source_cursor + 4, safe_source_end, -8);
            const cand_len_u: usize = 4 + (@intFromPtr(ext_end) - @intFromPtr(source_cursor + 4));
            const cand_len: i32 = @intCast(cand_len_u);
            if (cand_len >= best_match_length and cand_len >= minimum_match_length) {
                best_match_length = cand_len;
                best_offset = 8;
            }
        }
    }

    hasher.insert(hp);

    if (!isBetterThanRecentMatch(recent_match_length, best_match_length, best_offset)) {
        best_match_length = recent_match_length;
        best_offset = 0;
    }
    return .{ .length = best_match_length, .offset = best_offset };
}

/// Lazy parser driving a `MatchHasher2` chain hasher — port of
/// `FastParser.RunLazyParserChainHasher`. Handles both lazy-1 and lazy-2
/// evaluation based on `engine_level` (>3 enables lazy-2).
pub fn runLazyParserChain(
    comptime engine_level: i32,
    w: *FastStreamWriter,
    hasher: *match_hasher.MatchHasher2,
    source_cursor_in: [*]const u8,
    safe_source_end: [*]const u8,
    source_end: [*]const u8,
    recent_offset_inout: *isize,
    dictionary_size: u32,
    min_match_length_table: *const [32]u32,
    minimum_match_length: u32,
) void {
    var recent_offset: isize = recent_offset_inout.*;
    var source_cursor: [*]const u8 = source_cursor_in;
    var literal_start: [*]const u8 = source_cursor_in;

    const guard_addr = @intFromPtr(safe_source_end) -| 5;
    if (@intFromPtr(source_cursor) < guard_addr) {
        hasher.setHashPos(source_cursor);

        while (@intFromPtr(source_cursor) + 1 < guard_addr) {
            var match = findMatchWithChainHasher(
                source_cursor,
                safe_source_end,
                literal_start,
                recent_offset,
                hasher,
                source_cursor + 1,
                dictionary_size,
                minimum_match_length,
                min_match_length_table,
            );
            if (match.length < 2) {
                source_cursor += 1;
                continue;
            }

            while (@intFromPtr(source_cursor) + 1 < guard_addr) {
                const lazy1 = findMatchWithChainHasher(
                    source_cursor + 1,
                    safe_source_end,
                    literal_start,
                    recent_offset,
                    hasher,
                    source_cursor + 2,
                    dictionary_size,
                    minimum_match_length,
                    min_match_length_table,
                );
                if (lazy1.length >= 2 and isLazyMatchBetter(lazy1, match, 0)) {
                    source_cursor += 1;
                    match = lazy1;
                } else {
                    if (comptime engine_level <= 3) break;
                    if (@intFromPtr(source_cursor) + 2 > guard_addr or match.length == 2) break;
                    const lazy2 = findMatchWithChainHasher(
                        source_cursor + 2,
                        safe_source_end,
                        literal_start,
                        recent_offset,
                        hasher,
                        source_cursor + 3,
                        dictionary_size,
                        minimum_match_length,
                        min_match_length_table,
                    );
                    if (lazy2.length >= 2 and isLazyMatchBetter(lazy2, match, 1)) {
                        source_cursor += 2;
                        match = lazy2;
                    } else break;
                }
            }

            const actual_offset: isize = if (match.offset == 0)
                -recent_offset
            else
                @intCast(match.offset);

            // Backward extension.
            while (@intFromPtr(source_cursor) > @intFromPtr(literal_start)) {
                const cursor_prev_addr: usize = @intFromPtr(source_cursor) - 1;
                if (cursor_prev_addr < @intFromPtr(hasher.src_base) + @as(usize, @bitCast(@as(i64, actual_offset)))) break;
                const back_addr: usize = cursor_prev_addr - @as(usize, @bitCast(@as(i64, actual_offset)));
                const cur_b: u8 = @as([*]const u8, @ptrFromInt(cursor_prev_addr))[0];
                const back_b: u8 = @as([*]const u8, @ptrFromInt(back_addr))[0];
                if (cur_b != back_b) break;
                source_cursor -= 1;
                match.length += 1;
            }

            const match_length_u: u32 = @intCast(match.length);
            const lit_run_u: u32 = @intCast(@intFromPtr(source_cursor) - @intFromPtr(literal_start));
            const offset_or_recent: u32 = @intCast(match.offset);

            token_writer.writeOffsetWithLiteral1(
                w,
                match_length_u,
                lit_run_u,
                offset_or_recent,
                recent_offset,
                literal_start,
            );

            recent_offset = -actual_offset;
            source_cursor += match_length_u;
            literal_start = source_cursor;

            if (@intFromPtr(source_cursor) >= guard_addr) break;
            const match_start: [*]const u8 = @ptrFromInt(@intFromPtr(source_cursor) - match_length_u);
            hasher.insertRange(match_start, match_length_u);
        }
    }

    token_writer.copyTrailingLiterals(w, literal_start, source_end, recent_offset);
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

    var w = try FastStreamWriter.init(testing.allocator, &src, src.len, null, false);
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
        src[0..].ptr,
    );

    // On a repeating pattern the parser should emit at least one match.
    try testing.expect(w.tokenCount() > 0);
}
