//! Greedy match finder + match validation helpers for the High
//! compressor. Port of src/StreamLZ/Compression/High/Matcher.cs and
//! the `IsMatchLongEnough` predicate at `CostModel.cs:14-25`.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const match_eval = @import("match_eval.zig");
const high_types = @import("high_types.zig");
const mls_mod = @import("managed_match_len_storage.zig");

const State = high_types.State;
const HighRecentOffs = high_types.HighRecentOffs;
const LengthAndOffset = mls_mod.LengthAndOffset;

/// True when a match of `match_length` at `offset` meets the minimum
/// viable length threshold for its offset tier. Port of C#
/// `Compressor.IsMatchLongEnough` (`CostModel.cs:14-25`).
pub inline fn isMatchLongEnough(match_length: u32, offset: u32) bool {
    return switch (match_length) {
        0, 1, 2 => false,
        3 => offset < lz_constants.offset_threshold_12kb,
        4 => offset < lz_constants.offset_threshold_96kb,
        5 => offset < lz_constants.offset_threshold_768kb,
        6, 7 => offset < lz_constants.offset_threshold_3mb,
        else => true,
    };
}

/// Returns true when the given (length, offset) pair is a valid match
/// given the offset-length tier thresholds. Port of C#
/// `Compressor.CheckMatchValidLength` (`Matcher.cs:12-17`).
pub inline fn checkMatchValidLength(match_length: u32, offset: u32) bool {
    if (offset < lz_constants.offset_threshold_768kb) return true;
    if (offset < lz_constants.offset_threshold_1_5mb) return match_length >= 5;
    if (offset < lz_constants.offset_threshold_3mb) return match_length >= 6;
    return match_length >= 8;
}

/// Returns the recent-offset index (0, 1, or 2) that matches `offset`,
/// or `null` if `offset` is not in the recent-offset ring. Port of C#
/// `Compressor.GetRecentOffsetIndex` (`Matcher.cs:20-35`).
pub inline fn getRecentOffsetIndex(st: *const State, offset: i32) ?u2 {
    if (offset == st.recent_offs0) return 0;
    if (offset == st.recent_offs1) return 1;
    if (offset == st.recent_offs2) return 2;
    return null;
}

/// Picks the best match candidate at the current source position,
/// comparing each recent-offset candidate and the hash-based match list
/// under the length-biased tiebreak in `match_eval.isMatchBetter`.
///
/// Port of C# `Compressor.GetBestMatch` (`Matcher.cs:37-116`). Returns
/// a `LengthAndOffset` where `offset >= 0` is a raw backward distance
/// and `offset < 0` encodes a recent-offset slot (0 = most-recent, -1 =
/// second, -2 = third).
pub fn getBestMatch(
    matches: []const LengthAndOffset,
    recents: *const HighRecentOffs,
    src: [*]const u8,
    src_end: [*]const u8,
    min_match_len_in: i32,
    literals_since_last_match: i32,
    window_base: [*]const u8,
    max_match_offset: i32,
) LengthAndOffset {
    var min_match_len = min_match_len_in;
    const m32: u32 = std.mem.readInt(u32, src[0..4], .little);

    var best_ml: i32 = 0;
    var best_offs: i32 = 0;

    // Recent offsets (slots 4, 5, 6 in the 8-entry HighRecentOffs ring).
    {
        const ml_raw = match_eval.getMatchLengthQuick(src, recents.offs[4], src_end, m32);
        const ml: i32 = @intCast(ml_raw);
        if (ml > best_ml) {
            best_ml = ml;
            best_offs = 0;
        }
    }
    {
        const ml_raw = match_eval.getMatchLengthQuick(src, recents.offs[5], src_end, m32);
        const ml: i32 = @intCast(ml_raw);
        if (ml > best_ml) {
            best_ml = ml;
            best_offs = -1;
        }
    }
    {
        const ml_raw = match_eval.getMatchLengthQuick(src, recents.offs[6], src_end, m32);
        const ml: i32 = @intCast(ml_raw);
        if (ml > best_ml) {
            best_ml = ml;
            best_offs = -2;
        }
    }

    if (best_ml < 4) {
        if (literals_since_last_match >= 56) {
            if (best_ml <= 2) best_ml = 0;
            min_match_len += 1;
        }

        var best_match_length: u32 = 0;
        var best_match_offset: u32 = 0;

        // Walk the top-4 hash match candidates.
        const max_matches: usize = @min(@as(usize, 4), matches.len);
        var i: usize = 0;
        while (i < max_matches) : (i += 1) {
            var match_length: u32 = @intCast(matches[i].length);
            if (match_length < @as(u32, @intCast(min_match_len))) break;

            const remaining: usize = @intFromPtr(src_end) - @intFromPtr(src);
            if (match_length > remaining) {
                match_length = @intCast(remaining);
                if (match_length < @as(u32, @intCast(min_match_len))) break;
            }

            var offset: u32 = @intCast(matches[i].offset);
            if (offset >= @as(u32, @intCast(max_match_offset))) continue;

            if (offset < 8) {
                // Offset < 8: extend until offset >= 8 by doubling.
                const tt: u32 = offset;
                while (offset < 8) offset += tt;
                const src_pos: usize = @intFromPtr(src) - @intFromPtr(window_base);
                if (offset > @as(u32, @intCast(src_pos))) continue;
                const extended_raw = match_eval.getMatchLengthQuickMin3(src, @intCast(offset), src_end, m32);
                const extended: u32 = @intCast(extended_raw);
                if (extended < @as(u32, @intCast(min_match_len))) continue;
                match_length = extended;
            }

            if (isMatchLongEnough(match_length, offset) and match_eval.isMatchBetter(match_length, offset, best_match_length, best_match_offset)) {
                best_match_offset = offset;
                best_match_length = match_length;
            }
        }

        if (match_eval.isBetterThanRecent(best_ml, @intCast(best_match_length), @intCast(best_match_offset))) {
            best_ml = @intCast(best_match_length);
            best_offs = @intCast(best_match_offset);
        }
    }

    return .{ .length = best_ml, .offset = best_offs };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "isMatchLongEnough: length tiers" {
    try testing.expect(!isMatchLongEnough(2, 100));
    try testing.expect(isMatchLongEnough(3, 0x1000));
    try testing.expect(!isMatchLongEnough(3, 0x4000));
    try testing.expect(isMatchLongEnough(4, 0x10000));
    try testing.expect(!isMatchLongEnough(4, 0x20000));
    try testing.expect(isMatchLongEnough(8, 0xFFFFFFFF));
}

test "checkMatchValidLength: offset tiers" {
    try testing.expect(checkMatchValidLength(4, 1000)); // under 768KB → any length ok
    try testing.expect(!checkMatchValidLength(4, 0x120000)); // 1_5MB tier needs >= 5
    try testing.expect(checkMatchValidLength(5, 0x120000));
    try testing.expect(!checkMatchValidLength(5, 0x200000)); // 3MB tier needs >= 6
    try testing.expect(checkMatchValidLength(6, 0x200000));
    try testing.expect(!checkMatchValidLength(7, 0x400000)); // >= 3MB tier needs >= 8
    try testing.expect(checkMatchValidLength(8, 0x400000));
}

test "getRecentOffsetIndex: matches slots" {
    var s: State = .{};
    s.init();
    s.recent_offs0 = 100;
    s.recent_offs1 = 200;
    s.recent_offs2 = 300;
    try testing.expectEqual(@as(?u2, 0), getRecentOffsetIndex(&s, 100));
    try testing.expectEqual(@as(?u2, 1), getRecentOffsetIndex(&s, 200));
    try testing.expectEqual(@as(?u2, 2), getRecentOffsetIndex(&s, 300));
    try testing.expectEqual(@as(?u2, null), getRecentOffsetIndex(&s, 999));
}
