//! Hash-based match finder for the High optimal parser. Port of
//! `MatchFinder.FindMatchesHashBased` from
//! src/StreamLZ/Compression/MatchFinding/MatchFinder.cs.
//!
//! Uses `MatchHasher16Dual` (16-entry dual-hash bucket) to probe
//! candidate match positions at each source offset, extends each
//! candidate via `countMatchingBytes`, and stores the best matches
//! into a `ManagedMatchLenStorage` via `insertMatches`.
//!
//! Design:
//!   * Two-bucket probe (primary `cur1` + dual `cur2`) is unrolled
//!     as a 2-iteration `pass` loop.
//!   * Each bucket holds 16 entries; every entry is tested via a
//!     scalar tag+position filter. C# uses SSE2 vectorized probes
//!     for this, but the scalar code path produces identical
//!     results and is simpler to port without intrinsic rewrites.
//!   * When a match's length is >= 77 bytes, the finder inserts
//!     synthetic sub-matches at stride-4 positions within the long
//!     match and skips the main loop past the end — this is the
//!     "long match skip" optimization that keeps the optimal parser
//!     from spending time on positions it would never consult.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const match_hasher = @import("match_hasher.zig");
const match_eval = @import("match_eval.zig");
const mls_mod = @import("managed_match_len_storage.zig");

const MatchHasher16Dual = match_hasher.MatchHasher16Dual;
const LengthAndOffset = mls_mod.LengthAndOffset;
const ManagedMatchLenStorage = mls_mod.ManagedMatchLenStorage;

/// Max matches stored per source position. C# uses 33 as the on-stack
/// buffer size in `FindMatchesHashBased`.
const max_matches_per_pos: usize = 33;

/// Port of C# `MatchFinder.FindMatchesHashBased` (`MatchFinder.cs:289-512`).
///
/// `src` is the full source buffer (dictionary preload + window).
/// `mls` receives the match lists indexed by `pos - preload_size`.
/// `max_num_matches` caps how many matches per position are stored.
/// `preload_size` is the number of bytes already in the hash from a
/// previous window (for streaming / sliding-window compress).
pub fn findMatchesHashBased(
    allocator: std.mem.Allocator,
    src: []const u8,
    mls: *ManagedMatchLenStorage,
    max_num_matches: usize,
    preload_size: usize,
) !void {
    const src_size = src.len;
    if (src_size < 9) return; // need at least 8 bytes for 8-byte loads

    // Hash table size: bits = log2(max(src_size, 2) - 1) + 1, clamped [18, 24].
    const raw_bits: u32 = @intCast(std.math.log2_int(u32, @intCast(@max(src_size, 2) - 1)) + 1);
    const bits: u6 = @intCast(std.math.clamp(raw_bits, 18, 24));

    var hasher = try MatchHasher16Dual.init(allocator, bits, 0);
    defer hasher.deinit();
    hasher.setSrcBase(src.ptr);

    // Preload the hash with positions [0..preload_size).
    if (preload_size > 0) {
        hasher.setBaseAndPreload(
            src.ptr,
            0,
            @intCast(preload_size),
            preload_size,
        );
    } else {
        hasher.setBaseAndPreloadNone(0);
    }

    if (preload_size < src_size) {
        hasher.setHashPos(src[preload_size..].ptr);
    }

    if (src_size < 8) return;
    const src_safe4: usize = src_size - 4;
    const src_size_safe: usize = src_size - 8;

    var match_buf: [max_matches_per_pos]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });

    var cur_pos: usize = preload_size;
    while (cur_pos < src_size_safe) : (cur_pos += 1) {
        // 4-byte prefix at the current position for fast collision rejection.
        const u32_to_scan: u32 = std.mem.readInt(u32, src[cur_pos..][0..4], .little);

        // Capture this position's hash results (computed by the previous
        // iteration's setHashPos call — or the initial call above).
        const cur1: u32 = hasher.hash_entry_ptr_index;
        const cur2: u32 = hasher.hash_entry2_ptr_index;
        const cur_hash_tag: u32 = hasher.current_hash_tag;

        // Prefetch for cur_pos+8 and compute hash for cur_pos+1 now so
        // the loads overlap with the probe work below.
        if (cur_pos + 8 < src_size_safe) {
            hasher.setHashPosPrefetch(src[cur_pos + 8 ..].ptr);
        }
        hasher.setHashPos(src[cur_pos + 1 ..].ptr);

        var num_match: usize = 0;
        const hash_table = hasher.hash_table;

        // Two-pass probe: primary bucket then dual bucket.
        var hash_cur_idx: u32 = cur1;
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            var best_ml: usize = 0;

            // SSE2 vectorized 16-entry hash probe — direct port of C#
            // MatchFinder.FindMatchesHashBased lines 354-432. Processes
            // 4 hash entries per @Vector(4, i32), 4 rounds = 16 entries.
            // Each round computes the (curPos - 1 - pos) & mask + 1
            // offset, packs it into a 4-bit subfield of a 16-bit
            // bitmask along with the tag check, and the candidate loop
            // BSF-iterates only the bits set.
            const V = @Vector(4, i32);
            const v_max_pos: V = @splat(@as(i32, @intCast(cur_pos)) - 1);
            const cur_pos_clamped: i32 = @intCast(@min(cur_pos, lz_constants.max_dictionary_size));
            const v_max_off: V = @splat(cur_pos_clamped);
            const v_mask26: V = @splat(@as(i32, @bitCast(lz_constants.hash_position_mask)));
            const v_one: V = @splat(@as(i32, 1));
            const v_high_mask: V = @splat(@as(i32, @bitCast(lz_constants.hash_tag_mask)));
            const v_hash_high: V = @splat(@as(i32, @bitCast(cur_hash_tag)));

            // Aligned bucket of 16 entries → 4 unaligned 4-lane vectors.
            // Load via @Vector pointer cast (one MOVDQU each) instead of
            // std.mem.readInt(u128) which generated scalar-equivalent
            // shuffle code on Zig 0.15.
            const h_ptr: [*]const u32 = hash_table.ptr + hash_cur_idx;
            const VP = [*]align(1) const V;
            const v0: V = @as(VP, @ptrCast(h_ptr + 0))[0];
            const v1: V = @as(VP, @ptrCast(h_ptr + 4))[0];
            const v2: V = @as(VP, @ptrCast(h_ptr + 8))[0];
            const v3: V = @as(VP, @ptrCast(h_ptr + 12))[0];

            // u_n = ((maxPos - vN) & mask26) + 1   — the candidate offset.
            const off0: V = ((v_max_pos - v0) & v_mask26) + v_one;
            const off1: V = ((v_max_pos - v1) & v_mask26) + v_one;
            const off2: V = ((v_max_pos - v2) & v_mask26) + v_one;
            const off3: V = ((v_max_pos - v3) & v_mask26) + v_one;

            // Match condition: off_n <= v_max_off AND (vN ^ hashHigh) & highMask == 0
            // We compute: !(out_of_range OR tag_mismatch).
            const out0: V = @select(i32, off0 > v_max_off, @as(V, @splat(-1)), @as(V, @splat(0)));
            const tag0: V = (v0 ^ v_hash_high) & v_high_mask;
            const bad0: V = out0 | tag0;
            const m0: u4 = @bitCast(bad0 == @as(V, @splat(0)));

            const out1: V = @select(i32, off1 > v_max_off, @as(V, @splat(-1)), @as(V, @splat(0)));
            const tag1: V = (v1 ^ v_hash_high) & v_high_mask;
            const bad1: V = out1 | tag1;
            const m1: u4 = @bitCast(bad1 == @as(V, @splat(0)));

            const out2: V = @select(i32, off2 > v_max_off, @as(V, @splat(-1)), @as(V, @splat(0)));
            const tag2: V = (v2 ^ v_hash_high) & v_high_mask;
            const bad2: V = out2 | tag2;
            const m2: u4 = @bitCast(bad2 == @as(V, @splat(0)));

            const out3: V = @select(i32, off3 > v_max_off, @as(V, @splat(-1)), @as(V, @splat(0)));
            const tag3: V = (v3 ^ v_hash_high) & v_high_mask;
            const bad3: V = out3 | tag3;
            const m3: u4 = @bitCast(bad3 == @as(V, @splat(0)));

            const matching_offsets_init: u16 =
                @as(u16, m0) |
                (@as(u16, m1) << 4) |
                (@as(u16, m2) << 8) |
                (@as(u16, m3) << 12);

            // Stash offsets for BSF iteration. Lane index → which off_n.
            var offsets_buf: [16]u32 = undefined;
            offsets_buf[0] = @bitCast(off0[0]);
            offsets_buf[1] = @bitCast(off0[1]);
            offsets_buf[2] = @bitCast(off0[2]);
            offsets_buf[3] = @bitCast(off0[3]);
            offsets_buf[4] = @bitCast(off1[0]);
            offsets_buf[5] = @bitCast(off1[1]);
            offsets_buf[6] = @bitCast(off1[2]);
            offsets_buf[7] = @bitCast(off1[3]);
            offsets_buf[8] = @bitCast(off2[0]);
            offsets_buf[9] = @bitCast(off2[1]);
            offsets_buf[10] = @bitCast(off2[2]);
            offsets_buf[11] = @bitCast(off2[3]);
            offsets_buf[12] = @bitCast(off3[0]);
            offsets_buf[13] = @bitCast(off3[1]);
            offsets_buf[14] = @bitCast(off3[2]);
            offsets_buf[15] = @bitCast(off3[3]);

            // BSF iteration of the bitmask — typically 0-3 candidates pass
            // the SIMD filter, so this loop body is short.
            var matching_offsets: u16 = matching_offsets_init;
            while (matching_offsets != 0) {
                const bit: u4 = @intCast(@ctz(matching_offsets));
                matching_offsets &= matching_offsets - 1;
                const offset_u: u32 = offsets_buf[bit];
                const offset_s: usize = offset_u;
                if (cur_pos < offset_s) continue;

                // 4-byte prefix check at the match position.
                const match_word: u32 = std.mem.readInt(u32, src[cur_pos - offset_s ..][0..4], .little);
                if (match_word != u32_to_scan) continue;

                // Quick reject against the current best length.
                if (best_ml >= 4) {
                    if (cur_pos + best_ml >= src_safe4) continue;
                    if (src[cur_pos + best_ml] != src[cur_pos + best_ml - offset_s]) continue;
                }

                // Extend the match.
                const ml: usize = 4 + match_eval.countMatchingBytes(
                    src[cur_pos + 4 ..].ptr,
                    src[src_safe4..].ptr,
                    @intCast(offset_s),
                );
                if (ml > best_ml) {
                    best_ml = ml;
                    if (num_match < max_matches_per_pos) {
                        match_buf[num_match].set(@intCast(ml), @intCast(offset_u));
                        num_match += 1;
                    }
                }
            }

            if (hash_cur_idx == cur2) break;
            hash_cur_idx = cur2;
        }

        // Insert cur_pos into BOTH buckets AFTER probing so we never
        // match against ourselves.
        hasher.insertAtDual(
            cur1,
            cur2,
            MatchHasher16Dual.makeHashValue(cur_hash_tag, @intCast(cur_pos)),
        );

        if (num_match == 0) continue;

        // Sort longest-first so the optimal parser sees best matches first.
        const match_slice = match_buf[0..num_match];
        std.sort.pdq(LengthAndOffset, match_slice, {}, compareDescending);
        num_match = mls_mod.removeIdentical(match_slice, num_match);

        const mls_pos: usize = cur_pos - preload_size;
        try mls_mod.insertMatches(mls, mls_pos, match_slice, @min(max_num_matches, num_match));

        const best_ml_total: usize = @intCast(match_slice[0].length);

        // Long-match skip optimization: when the best match is >= 77
        // bytes, fan out synthetic sub-matches at stride-4 and skip
        // the main loop past the end of the match.
        if (best_ml_total >= 77) {
            // match_buf[0].length mutates — restore it after the trick.
            const saved_len = match_slice[0].length;
            const saved_off = match_slice[0].offset;
            match_slice[0].length = @intCast(best_ml_total - 1);
            try mls_mod.insertMatches(mls, mls_pos + 1, match_slice[0..1], 1);
            var k: usize = 4;
            while (k < best_ml_total) : (k += 4) {
                match_slice[0].length = @intCast(best_ml_total - k);
                try mls_mod.insertMatches(mls, mls_pos + k, match_slice[0..1], 1);
            }
            match_slice[0].length = saved_len;
            match_slice[0].offset = saved_off;
            if (cur_pos + best_ml_total < src_size_safe) {
                hasher.insertRange(src[cur_pos..].ptr, best_ml_total);
            }
            cur_pos += best_ml_total - 1;
        }
    }
}

/// Sort comparator: descending by length, tiebreak by ascending offset.
fn compareDescending(_: void, a: LengthAndOffset, b: LengthAndOffset) bool {
    if (a.length != b.length) return a.length > b.length;
    return a.offset < b.offset;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "findMatchesHashBased: simple repetition stores a match" {
    // A repeating pattern guarantees at least one hit in the hash probe.
    var src: [512]u8 = undefined;
    const pattern = "abcdefghABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();

    try findMatchesHashBased(testing.allocator, &src, &mls, 4, 0);

    // At least one position should have matches stored.
    var any_match: bool = false;
    for (mls.offset2_pos) |p| {
        if (p != 0) {
            any_match = true;
            break;
        }
    }
    try testing.expect(any_match);
}

test "findMatchesHashBased: skip tiny input" {
    var src: [7]u8 = .{ 1, 2, 3, 4, 5, 6, 7 };
    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesHashBased(testing.allocator, &src, &mls, 4, 0);
    // Nothing should be populated on a tiny input.
    for (mls.offset2_pos) |p| try testing.expectEqual(@as(i32, 0), p);
}

test "findMatchesHashBased: extracts match via extractLaoFromMls" {
    // Build a buffer where position N contains a clear N-byte repeat of
    // position 0. The finder should store a match at N that extractLao
    // can then read back.
    var src: [1024]u8 = undefined;
    const pattern = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesHashBased(testing.allocator, &src, &mls, 4, 0);

    // At least one position should have readable matches via extract.
    var found: bool = false;
    for (0..src.len) |off| {
        if (mls.offset2_pos[off] == 0) continue;
        var out: [4]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });
        try mls_mod.extractLaoFromMls(&mls, off, 1, &out, 4);
        if (out[0].length > 0 and out[0].offset > 0) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
