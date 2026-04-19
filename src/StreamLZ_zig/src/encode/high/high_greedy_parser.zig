//! High fast parser (levels 1-4): greedy / 1-lazy / 2-lazy match
//! finder emitting tokens via `high_encoder.addToken`.
//! Used by: High codec (L6-L11)
//!
//! The parser is comptime-generic over the hasher type — each High
//! level instantiates a specialized copy for its `MatchHasher*` so
//! the hot loop is branch-free over `num_hash` and `dual_hash`. The
//! hash table probe at the current position fans out through 1, 2,
//! 4, 8, or 16 bucket entries depending on the hasher variant.
//!
//! Level / lazy-step mapping:
//!   L1, L2 → numLazy = 0  (pure greedy)
//!   L3     → numLazy = 1  (one lazy step)
//!   L4     → numLazy = 2  (two lazy steps)

const std = @import("std");
const lz_constants = @import("../../format/streamlz_constants.zig");
const match_eval = @import("../match_eval.zig");
const mls_mod = @import("managed_match_len_storage.zig");
const high_types = @import("high_types.zig");
const high_matcher = @import("high_matcher.zig");
const high_encoder = @import("high_encoder.zig");
const hasher_mod = @import("../match_hasher.zig");

const LengthAndOffset = mls_mod.LengthAndOffset;
const HighRecentOffs = high_types.HighRecentOffs;
const HighStreamWriter = high_types.HighStreamWriter;
const HighEncoderContext = high_encoder.HighEncoderContext;
const HighWriterStorage = high_encoder.HighWriterStorage;

/// Options threaded through `compressFast`.
pub const FastParserOptions = struct {
    /// Dictionary size (0 = default).
    dictionary_size: u32 = 0,
    /// Minimum match length (clamped to >= 4).
    min_match_length: u32 = 0,
    /// Self-contained mode.
    self_contained: bool = false,
};

/// Inspects a recent-offset slot and updates `best_ml` / `best_off`
/// if it produces a longer match.
inline fn checkRecentMatch(
    src: [*]const u8,
    src_end: [*]const u8,
    u32_at_src: u32,
    recent_offs: [*]const i32,
    idx: i32,
    best_ml: *i32,
    best_off: *i32,
) void {
    const recent_off: isize = recent_offs[@as(usize, @intCast(4 + idx))];
    const ml_raw = match_eval.getMatchLengthQuick(src, recent_off, src_end, u32_at_src);
    const ml: i32 = @intCast(ml_raw);
    if (ml > best_ml.*) {
        best_ml.* = ml;
        best_off.* = idx;
    }
}

/// Finds the best match at the current position using the hash table
/// + 3 recent offsets. Comptime-generic over the hasher type so each
/// level compiles to its own specialized copy.
///
///
pub fn getMatch(
    comptime HasherT: type,
    hasher: *HasherT,
    cur_ptr: [*]const u8,
    src_end_safe: [*]const u8,
    recent_offs: [*]const i32,
    src_span_len: usize,
    increment: isize,
    dict_size: u32,
    min_match_length: i32,
) LengthAndOffset {
    const hash_ptr: u32 = hasher.hash_entry_ptr_index;
    const hash2_ptr: u32 = if (HasherT.uses_dual_hash) hasher.hash_entry2_ptr_index else 0;
    const hash_tag: u32 = hasher.current_hash_tag;
    const cur_offset: i64 = hasher.src_cur_offset;
    const hash_pos: u32 = @intCast(cur_offset - hasher.src_base_offset);
    const hashval: u32 = HasherT.makeHashValue(hash_tag, hash_pos);

    // Prefetch the next iteration's hash.
    const next_offset: i64 = cur_offset + increment;
    if (next_offset < @as(i64, @intCast(src_span_len)) - 8) {
        const next_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(hasher.src_base) + @as(usize, @intCast(next_offset)));
        hasher.setHashPosPrefetch(next_ptr);
    } else if (next_offset < @as(i64, @intCast(src_span_len))) {
        const next_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(hasher.src_base) + @as(usize, @intCast(next_offset)));
        hasher.setHashPos(next_ptr);
    }

    const u32_at_src: u32 = std.mem.readInt(u32, cur_ptr[0..4], .little);

    // Check the 3 recent offsets.
    var recent_ml: i32 = 0;
    var recent_off: i32 = -1;
    checkRecentMatch(cur_ptr, src_end_safe, u32_at_src, recent_offs, 0, &recent_ml, &recent_off);
    checkRecentMatch(cur_ptr, src_end_safe, u32_at_src, recent_offs, 1, &recent_ml, &recent_off);
    checkRecentMatch(cur_ptr, src_end_safe, u32_at_src, recent_offs, 2, &recent_ml, &recent_off);

    var best_offs: i32 = 0;
    var best_ml: i32 = 0;

    if (recent_ml >= 4) {
        hasher.insertAtDual(hash_ptr, hash2_ptr, hashval);
        best_offs = -recent_off;
        best_ml = recent_ml;
    } else {
        const hash_table = hasher.hash_table;
        const num_hash: u32 = HasherT.bucket_width;

        var cur_hash_idx: u32 = hash_ptr;
        while (true) {
            var hashidx: u32 = 0;
            while (hashidx < num_hash) : (hashidx += 1) {
                const entry: u32 = hash_table[cur_hash_idx + hashidx];
                if ((entry & lz_constants.hash_tag_mask) == (hash_tag & lz_constants.hash_tag_mask)) {
                    var cur_offs: i32 = @intCast((hash_pos -% entry) & lz_constants.hash_position_mask);
                    if (@as(u32, @intCast(cur_offs)) < dict_size) {
                        if (cur_offs < 8) cur_offs = 8;
                        const cur_ml_raw = match_eval.getMatchLengthQuickMin4(cur_ptr, cur_offs, src_end_safe, u32_at_src);
                        const cur_ml: i32 = @intCast(cur_ml_raw);
                        if (cur_ml >= min_match_length and
                            high_matcher.isMatchLongEnough(@intCast(cur_ml), @intCast(cur_offs)) and
                            match_eval.isMatchBetter(@intCast(cur_ml), @intCast(cur_offs), @intCast(best_ml), @intCast(best_offs)))
                        {
                            best_offs = cur_offs;
                            best_ml = cur_ml;
                        }
                    }
                }
            }
            if (!HasherT.uses_dual_hash or cur_hash_idx == hash2_ptr) break;
            cur_hash_idx = hash2_ptr;
        }
        hasher.insertAtDual(hash_ptr, hash2_ptr, hashval);
        if (!match_eval.isBetterThanRecent(recent_ml, best_ml, best_offs)) {
            best_offs = -recent_off;
            best_ml = recent_ml;
        }
    }

    return .{ .length = best_ml, .offset = best_offs };
}

/// Fast High compression -- greedy / 1-lazy / 2-lazy parser emitting
/// via `HighStreamWriter`. Returns the number of compressed bytes
/// written to `dst`, or `src.len` on bail-out.
pub fn compressFast(
    comptime HasherT: type,
    ctx: *const HighEncoderContext,
    hasher: *HasherT,
    src_ptr: [*]const u8,
    source_length: i32,
    dst: [*]u8,
    dst_end: [*]u8,
    start_pos: i32,
    num_lazy: u32,
    opts: FastParserOptions,
    cost_out: *f32,
    chunk_type_out: *i32,
) !usize {
    chunk_type_out.* = -1;
    if (source_length <= 128) return @intCast(source_length);

    const src_len_usize: usize = @intCast(source_length);
    const src_end_safe: [*]const u8 = src_ptr + src_len_usize - 8;

    var dict_size: u32 = if (opts.dictionary_size == 0) 0x40000000 else @min(opts.dictionary_size, 0x40000000);
    if (opts.self_contained) {
        const sc_cap: u32 = lz_constants.chunk_size * lz_constants.sc_group_size;
        dict_size = @min(dict_size, sc_cap);
    }

    const min_match_length: i32 = @intCast(@max(opts.min_match_length, 4));
    const initial_copy_bytes: usize = if (start_pos == 0) 8 else 0;
    var cur_pos: usize = initial_copy_bytes;

    var recent = HighRecentOffs.create();

    var writer: HighStreamWriter = undefined;
    var storage: HighWriterStorage = undefined;
    try high_encoder.initializeStreamWriter(&writer, &storage, ctx.allocator, source_length, src_ptr, @intCast(ctx.encode_flags));
    defer storage.deinit();

    var increment: isize = 1;
    var loops_since_match: i32 = 0;
    var lit_start: usize = cur_pos;

    // Set the source base so the hasher's pointer math lines up with our
    // `src_ptr + offset` coordinates. For non-dict / non-streaming the
    // span base equals src_ptr; `start_pos` indexes into a larger window
    // when the caller is preloading from a dictionary.
    const src_offset_from_base: i64 = start_pos;
    const span_len: usize = @intCast(src_offset_from_base + source_length);
    const span_base: [*]const u8 = @ptrFromInt(@intFromPtr(src_ptr) - @as(usize, @intCast(src_offset_from_base)));

    hasher.setSrcBase(span_base);
    hasher.setHashPos(@ptrFromInt(@intFromPtr(span_base) + @as(usize, @intCast(src_offset_from_base + @as(i64, @intCast(cur_pos))))));

    const num_hash1: bool = HasherT.bucket_width == 1;

    while (cur_pos + @as(usize, @intCast(increment)) < src_len_usize - 16) {
        var cur_ptr: [*]const u8 = src_ptr + cur_pos;

        var m = getMatch(
            HasherT,
            hasher,
            cur_ptr,
            src_end_safe,
            &recent.offs,
            span_len,
            increment,
            dict_size,
            min_match_length,
        );

        if (m.length == 0) {
            loops_since_match += 1;
            cur_pos += @as(usize, @intCast(increment));
            if (num_hash1) {
                increment = @min(@as(isize, loops_since_match >> 5) + 1, 12);
            }
            continue;
        }

        // Lazy evaluation: look 1 (and maybe 2) bytes ahead for a better match.
        if (num_lazy >= 1) {
            while (cur_pos + 1 < src_len_usize - 16) {
                const m1 = getMatch(
                    HasherT,
                    hasher,
                    cur_ptr + 1,
                    src_end_safe,
                    &recent.offs,
                    span_len,
                    1,
                    dict_size,
                    min_match_length,
                );
                if (m1.length != 0 and match_eval.getLazyScore(m1, m) > 0) {
                    cur_pos += 1;
                    cur_ptr += 1;
                    m = m1;
                } else {
                    if (num_lazy < 2 or cur_pos + 2 >= src_len_usize - 16 or m.length == 2) break;
                    const m2 = getMatch(
                        HasherT,
                        hasher,
                        cur_ptr + 2,
                        src_end_safe,
                        &recent.offs,
                        span_len,
                        1,
                        dict_size,
                        min_match_length,
                    );
                    if (m2.length != 0 and match_eval.getLazyScore(m2, m) > 3) {
                        cur_pos += 2;
                        cur_ptr += 2;
                        m = m2;
                    } else break;
                }
            }
        }

        // Resolve the actual backward offset from the recent-offset slot
        // or a new offset (m.offset > 0). The "avoid recent0 right after
        // a match" rule (line 230-233): if we would emit recent0 with no
        // literals in between, shift to recent1 to allow the decoder to
        // distinguish the two runs.
        var actual_offs: i32 = m.offset;
        if (m.offset <= 0) {
            if (m.offset == 0 and cur_pos == lit_start) m.offset = -1;
            const idx: usize = @intCast(-m.offset + 4);
            actual_offs = recent.offs[idx];
        }

        // Back-extend: grow the match backward while bytes match.
        while (cur_pos > lit_start and
            @as(i64, @intCast(cur_pos)) + @as(i64, start_pos) >= @as(i64, actual_offs) + 1)
        {
            const prev_byte: u8 = (cur_ptr - 1)[0];
            const back_byte_addr: usize = @intFromPtr(cur_ptr) - @as(usize, @intCast(actual_offs)) - 1;
            const back_byte: u8 = (@as([*]const u8, @ptrFromInt(back_byte_addr)))[0];
            if (prev_byte != back_byte) break;
            cur_pos -= 1;
            cur_ptr -= 1;
            m.length += 1;
        }

        // Emit the token.
        const lit_run_len: usize = cur_pos - lit_start;
        high_encoder.addToken(
            &writer,
            &recent,
            src_ptr + lit_start,
            lit_run_len,
            m.length,
            m.offset,
            true, // do_recent
            true, // do_subtract
        );

        // Insert the match interior into the hash table.
        const match_start_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(span_base) + @as(usize, @intCast(src_offset_from_base + @as(i64, @intCast(cur_pos)))));
        hasher.insertRange(match_start_ptr, @intCast(m.length));
        loops_since_match = 0;
        increment = 1;
        cur_pos += @intCast(m.length);
        lit_start = cur_pos;
    }

    // Trailing literals past the last match.
    high_encoder.addFinalLiterals(&writer, src_ptr + lit_start, src_ptr + src_len_usize, true);

    return try high_encoder.assembleCompressedOutput(
        ctx,
        &writer,
        null,
        dst,
        dst_end,
        start_pos,
        cost_out,
        chunk_type_out,
    );
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "compressFast: short input (<= 128) returns source length" {
    var src: [100]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);

    const MatchHasher1 = hasher_mod.MatchHasher1;
    var hasher = try MatchHasher1.init(testing.allocator, 14, 4);
    defer hasher.deinit();

    const ctx: HighEncoderContext = .{
        .allocator = testing.allocator,
        .compression_level = 1,
        .speed_tradeoff = 0.05,
        .entropy_options = .{},
        .encode_flags = 0,
        .sub_or_copy_mask = 0,
    };

    var dst_buf: [1024]u8 = undefined;
    var cost: f32 = 0;
    var chunk_type: i32 = -1;
    const n = try compressFast(
        MatchHasher1,
        &ctx,
        &hasher,
        &src,
        @intCast(src.len),
        &dst_buf,
        dst_buf[dst_buf.len..].ptr,
        0,
        0, // num_lazy
        .{},
        &cost,
        &chunk_type,
    );
    // Short input: parser bails and returns source length.
    try testing.expectEqual(src.len, n);
}

test "compressFast: 1 KB repeating input produces compressed output" {
    var src: [1024]u8 = undefined;
    const pattern = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    const MatchHasher1 = hasher_mod.MatchHasher1;
    var hasher = try MatchHasher1.init(testing.allocator, 16, 4);
    defer hasher.deinit();

    const ctx: HighEncoderContext = .{
        .allocator = testing.allocator,
        .compression_level = 1,
        .speed_tradeoff = 0.05,
        .entropy_options = .{},
        .encode_flags = 0,
        .sub_or_copy_mask = 0,
    };

    var dst_buf: [2048]u8 = undefined;
    var cost: f32 = 0;
    var chunk_type: i32 = -1;
    const n = try compressFast(
        MatchHasher1,
        &ctx,
        &hasher,
        &src,
        @intCast(src.len),
        &dst_buf,
        dst_buf[dst_buf.len..].ptr,
        0,
        0,
        .{},
        &cost,
        &chunk_type,
    );
    // Didn't bail, and did something.
    try testing.expect(n > 0);
    try testing.expect(n < src.len);
}
