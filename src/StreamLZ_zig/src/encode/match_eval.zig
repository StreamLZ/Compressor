//! Shared LZ match-evaluation helpers. Port of
//! src/StreamLZ/Compression/MatchEvaluation.cs (`MatchUtils`).
//!
//! These are the building blocks the High codec's parsers and cost model
//! use to measure and rank candidate matches. Fast's `fast_lz_parser.zig`
//! has its own inlined copies of `countMatchingBytes` and friends — those
//! stay where they are to preserve the Fast-encoder byte-exact parity;
//! this module exists so the High codec (step 29+) can share the same
//! algorithms without touching Fast.

const std = @import("std");

const fast_parser = @import("fast_lz_parser.zig");
const LengthAndOffset = fast_parser.LengthAndOffset;

pub const CompareLengthAndOffset = LengthAndOffset;

/// Counts the number of matching bytes starting at `p`, comparing against
/// `p - offset`, up to `p_end`. Uses 8-byte and 4-byte scans with a
/// trailing-zero count on the XOR difference for a precise match length.
///
/// Port of C# `MatchUtils.CountMatchingBytes` (`MatchEvaluation.cs:19-52`).
pub fn countMatchingBytes(p: [*]const u8, p_end: [*]const u8, offset: isize) usize {
    var len: usize = 0;
    var cursor = p;
    while (@intFromPtr(p_end) - @intFromPtr(cursor) >= 8) {
        const a: u64 = std.mem.readInt(u64, cursor[0..8], .little);
        const back_addr: usize = @intFromPtr(cursor) -% @as(usize, @bitCast(offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: u64 = std.mem.readInt(u64, back_ptr[0..8], .little);
        if (a != b) {
            const xor = a ^ b;
            return len + (@as(usize, @ctz(xor)) >> 3);
        }
        cursor += 8;
        len += 8;
    }
    if (@intFromPtr(p_end) - @intFromPtr(cursor) >= 4) {
        const a: u32 = std.mem.readInt(u32, cursor[0..4], .little);
        const back_addr: usize = @intFromPtr(cursor) -% @as(usize, @bitCast(offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        const b: u32 = std.mem.readInt(u32, back_ptr[0..4], .little);
        if (a != b) {
            const xor = a ^ b;
            return len + (@as(usize, @ctz(xor)) >> 3);
        }
        cursor += 4;
        len += 4;
    }
    while (@intFromPtr(cursor) < @intFromPtr(p_end)) : ({
        cursor += 1;
        len += 1;
    }) {
        const back_addr: usize = @intFromPtr(cursor) -% @as(usize, @bitCast(offset));
        const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
        if (cursor[0] != back_ptr[0]) break;
    }
    return len;
}

/// Quick match-length computation starting from a 4-byte prefix. Returns
/// 4 + tail when the prefix matches, or 0..3 for short partial matches.
///
/// Port of C# `MatchUtils.GetMatchLengthQuick` (`MatchEvaluation.cs:59-75`).
pub fn getMatchLengthQuick(
    src: [*]const u8,
    offset: isize,
    src_end: [*]const u8,
    u32_at_cur: u32,
) usize {
    const back_addr: usize = @intFromPtr(src) -% @as(usize, @bitCast(offset));
    const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
    const u32_at_match: u32 = std.mem.readInt(u32, back_ptr[0..4], .little);
    if (u32_at_cur == u32_at_match) {
        return 4 + countMatchingBytes(src + 4, src_end, offset);
    }
    const xor: u32 = u32_at_cur ^ u32_at_match;
    // Low 16 bits differ → length 0. Low 24 bits match → length 3, else 2.
    if (@as(u16, @truncate(xor)) != 0) return 0;
    return if ((xor & 0xFFFFFF) != 0) 2 else 3;
}

/// Match length with minimum 2 — single-byte matches fold to 0.
/// Port of C# `MatchUtils.GetMatchLengthMin2`.
pub fn getMatchLengthMin2(
    src_ptr_cur: [*]const u8,
    offset: isize,
    src_ptr_safe_end: [*]const u8,
) usize {
    const len = countMatchingBytes(src_ptr_cur, src_ptr_safe_end, offset);
    return if (len == 1) 0 else len;
}

/// Match length with minimum 3. Returns 0 if the first 3 bytes differ.
/// Port of C# `MatchUtils.GetMatchLengthQuickMin3`.
pub fn getMatchLengthQuickMin3(
    src_ptr_cur: [*]const u8,
    offset: isize,
    src_ptr_safe_end: [*]const u8,
    u32_at_cur: u32,
) usize {
    const back_addr: usize = @intFromPtr(src_ptr_cur) -% @as(usize, @bitCast(offset));
    const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
    const u32_at_match: u32 = std.mem.readInt(u32, back_ptr[0..4], .little);
    if (u32_at_cur == u32_at_match) {
        return 4 + countMatchingBytes(src_ptr_cur + 4, src_ptr_safe_end, offset);
    }
    return if (((u32_at_cur ^ u32_at_match) & 0xFFFFFF) != 0) 0 else 3;
}

/// Match length with minimum 4. Returns 0 if the first 4 bytes differ.
/// Port of C# `MatchUtils.GetMatchLengthQuickMin4`.
pub fn getMatchLengthQuickMin4(
    src_ptr_cur: [*]const u8,
    offset: isize,
    src_ptr_safe_end: [*]const u8,
    u32_at_cur: u32,
) usize {
    const back_addr: usize = @intFromPtr(src_ptr_cur) -% @as(usize, @bitCast(offset));
    const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
    const u32_at_match: u32 = std.mem.readInt(u32, back_ptr[0..4], .little);
    if (u32_at_cur == u32_at_match) {
        return 4 + countMatchingBytes(src_ptr_cur + 4, src_ptr_safe_end, offset);
    }
    return 0;
}

/// True when a normal match of the given length/offset beats the current
/// recent-offset match. Port of `MatchUtils.IsBetterThanRecent`.
pub fn isBetterThanRecent(recent_match_length: i32, match_length: i32, offset: i32) bool {
    return recent_match_length < 2 or
        (recent_match_length + 1 < match_length and
        (recent_match_length + 2 < match_length or offset < 1024) and
        (recent_match_length + 3 < match_length or offset < 65536));
}

/// True when `(match_length, offset)` is better than `(best_match_length,
/// best_offset)` under the length-biased heuristic. Port of
/// `MatchUtils.IsMatchBetter`.
pub fn isMatchBetter(match_length: u32, offset: u32, best_match_length: u32, best_offset: u32) bool {
    if (match_length < best_match_length) return false;
    if (match_length == best_match_length) return offset < best_offset;
    if (match_length == best_match_length + 1) return (offset >> 7) <= best_offset;
    return true;
}

/// Lazy-match score — compares the prospective lazy match at position+1
/// against the current match. Positive means the lazy candidate wins.
///
/// Port of C# `MatchUtils.GetLazyScore` (`MatchEvaluation.cs:161-166`).
///
/// `a` and `b` can be any struct type with `length: i32` and
/// `offset: i32` fields — both `fast_lz_parser.LengthAndOffset` and
/// `managed_match_len_storage.LengthAndOffset` qualify, so the same
/// function serves both the Fast and High parsers without forcing a
/// shared struct type.
pub fn getLazyScore(a: anytype, b: anytype) i32 {
    const bits_a: i32 = if (a.offset > 0)
        @as(i32, @intCast(std.math.log2_int(u32, @intCast(a.offset)))) + 3
    else
        0;
    const bits_b: i32 = if (b.offset > 0)
        @as(i32, @intCast(std.math.log2_int(u32, @intCast(b.offset)))) + 3
    else
        0;
    return 4 * (a.length - b.length) - 4 - (bits_a - bits_b);
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "countMatchingBytes: 8-byte aligned match" {
    const src = "ABCDEFGHABCDEFGH!!"; // 16 bytes match, then '!' differs
    const len = countMatchingBytes(src[8..].ptr, src[src.len..].ptr, 8);
    try testing.expectEqual(@as(usize, 8), len);
}

test "countMatchingBytes: short match ends on XOR low byte" {
    //  01234567  89...
    // "ABCDEFGH" "ABCXYZ" — offset 8, first 3 bytes match, byte 3 differs
    const src = "ABCDEFGHABCXYZ...";
    const len = countMatchingBytes(src[8..].ptr, src[src.len..].ptr, 8);
    try testing.expectEqual(@as(usize, 3), len);
}

test "countMatchingBytes: full overlap" {
    const src = "ZZZZZZZZZZZZZZZZ"; // all same byte
    const len = countMatchingBytes(src[1..].ptr, src[src.len..].ptr, 1);
    try testing.expectEqual(@as(usize, 15), len);
}

test "getMatchLengthQuick: 4-byte prefix match extends" {
    const src = "abcdefghabcdijkl"; // offset 8: 'abcd' matches, 'efgh' vs 'ijkl' differs
    const len = getMatchLengthQuick(
        src[8..].ptr,
        8,
        src[src.len..].ptr,
        std.mem.readInt(u32, src[8..12], .little),
    );
    try testing.expectEqual(@as(usize, 4), len);
}

test "getMatchLengthQuick: short partial match returns 2" {
    //      01234567  89ABCDEF
    //     "abcdefgh" "abXYEFGH"
    const src = "abcdefghabXYEFGH";
    const len = getMatchLengthQuick(
        src[8..].ptr,
        8,
        src[src.len..].ptr,
        std.mem.readInt(u32, src[8..12], .little),
    );
    try testing.expectEqual(@as(usize, 2), len);
}

test "getMatchLengthQuickMin3: 3-byte match" {
    const src = "abcdefghabcXefgh";
    const len = getMatchLengthQuickMin3(
        src[8..].ptr,
        8,
        src[src.len..].ptr,
        std.mem.readInt(u32, src[8..12], .little),
    );
    try testing.expectEqual(@as(usize, 3), len);
}

test "getMatchLengthQuickMin4: 4-byte prefix required" {
    const src = "abcdefghabcXefgh";
    const len = getMatchLengthQuickMin4(
        src[8..].ptr,
        8,
        src[src.len..].ptr,
        std.mem.readInt(u32, src[8..12], .little),
    );
    try testing.expectEqual(@as(usize, 0), len);
}

test "isBetterThanRecent: recent length < 2 always wins" {
    try testing.expect(isBetterThanRecent(0, 3, 100));
    try testing.expect(isBetterThanRecent(1, 3, 100));
}

test "isBetterThanRecent: recent +1 gate" {
    // recentLen=5, matchLen=6 → not better (need recent+1 < match)
    try testing.expect(!isBetterThanRecent(5, 6, 100));
    // recentLen=5, matchLen=7, offset=100 → better (recent+2 gate:
    // 7 < 7 is false, but offset 100 < 1024 passes).
    try testing.expect(isBetterThanRecent(5, 7, 100));
    // recentLen=5, matchLen=7, offset=2000 → NOT better (recent+2 gate
    // fails: 7<7 is false AND 2000<1024 is false).
    try testing.expect(!isBetterThanRecent(5, 7, 2000));
    // recentLen=5, matchLen=9 → better at any offset (recent+2 = 7 < 9).
    try testing.expect(isBetterThanRecent(5, 9, 2000));
}

test "isMatchBetter: length ties go to smaller offset" {
    try testing.expect(isMatchBetter(10, 100, 10, 500));
    try testing.expect(!isMatchBetter(10, 500, 10, 100));
}

test "isMatchBetter: +1 length gated by offset/128" {
    // match length = best + 1; offset >> 7 must be <= best_offset.
    try testing.expect(isMatchBetter(11, 12800, 10, 100)); // 12800 >> 7 = 100 <= 100
    try testing.expect(!isMatchBetter(11, 13000, 10, 100)); // 13000 >> 7 = 101 > 100
}

test "getLazyScore: longer match with smaller offset wins" {
    const a: CompareLengthAndOffset = .{ .length = 10, .offset = 100 };
    const b: CompareLengthAndOffset = .{ .length = 8, .offset = 1000 };
    // a wins: 4*(10-8) - 4 - (log2(100)+3 - log2(1000)+3) = 8-4-(-3) = 7
    try testing.expect(getLazyScore(a, b) > 0);
}
