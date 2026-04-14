//! Binary-tree (BT4) match finder for the High optimal parser at level 11.
//! Port of `MatchFinder.FindMatchesBT4` + `BT4InsertOnly` +
//! `BT4SearchAndInsert` from src/StreamLZ/Compression/MatchFinding/MatchFinder.cs.
//!
//! Finds higher-quality matches than the hash-chain finder at the cost of
//! slower insertion. Each position is both inserted into and searched
//! against a binary tree ordered by suffix content; the tree walk
//! simultaneously descends toward a match and carves out the insertion
//! point.
//!
//! Layout:
//!   * `head[hash(pfx4(pos))]` → most recent position with this 4-byte
//!     prefix (1-based, 0 = empty).
//!   * `left[pos]` / `right[pos]` → child positions in the binary tree
//!     (1-based). `left[p]` has lexicographically-smaller suffix,
//!     `right[p]` has lexicographically-larger suffix.
//!
//! Each position walk updates `head`, carves the tree at the matched
//! descent point, and records up to `max_num_matches` matches into
//! the `ManagedMatchLenStorage` via `insertMatches`.
//!
//! Unlike the C# version which uses `ArrayPool<int>`, this port allocates
//! scratch via the supplied `std.mem.Allocator` on each call. Per-round
//! scratch caching can be layered in later if needed.

const std = @import("std");
const mls_mod = @import("managed_match_len_storage.zig");

const LengthAndOffset = mls_mod.LengthAndOffset;
const ManagedMatchLenStorage = mls_mod.ManagedMatchLenStorage;

/// On-stack match-capture buffer. Mirrors C# `stackalloc
/// LengthAndOffset[maxNumMatches + 2]` with a small upper bound (the
/// optimal parser reads at most 4 matches per position).
const match_buf_cap: usize = 8;

/// Port of C# `MatchFinder.FindMatchesBT4` (`MatchFinder.cs:680-757`).
///
/// Populates `mls` with match candidates discovered via a binary-tree
/// walk. `max_num_matches` caps how many matches per source position
/// are kept. `preload_size` specifies how many leading bytes of `src`
/// correspond to a prior-window preload; those positions are inserted
/// into the tree without being stored into `mls`. `max_depth` bounds
/// how many tree nodes are visited per position (typical L11 value:
/// 256; smaller → faster + worse ratio).
pub fn findMatchesBT4(
    allocator: std.mem.Allocator,
    src: []const u8,
    mls: *ManagedMatchLenStorage,
    max_num_matches: usize,
    preload_size: usize,
    max_depth: u32,
) !void {
    const src_size: usize = src.len;
    if (src_size < 8) return;

    // Hash-table sizing: bits = clamp(log2(max(srcSize, 2) - 1) + 1, 16, 24).
    const raw_bits: u32 = @intCast(
        std.math.log2_int(u32, @intCast(@max(src_size, 2) - 1)) + 1,
    );
    const bits: u5 = @intCast(std.math.clamp(raw_bits, 16, 24));
    const hash_size: usize = @as(usize, 1) << bits;
    const hash_mask: u32 = @intCast(hash_size - 1);

    // Allocate + zero-init head; tree arrays are written before being read.
    const head = try allocator.alloc(u32, hash_size);
    defer allocator.free(head);
    @memset(head, 0);

    const tree_size: usize = src_size + 1;
    const left = try allocator.alloc(u32, tree_size);
    defer allocator.free(left);
    const right = try allocator.alloc(u32, tree_size);
    defer allocator.free(right);

    const src_size_safe: usize = src_size - 8;
    var match_buf: [match_buf_cap]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });

    // ── Preload: insert positions [0..preloadSize) into the tree. ──
    {
        var pos: usize = 0;
        while (pos < preload_size and pos < src_size_safe) : (pos += 1) {
            _ = bt4SearchAndInsert(
                src,
                @intCast(pos),
                head,
                left,
                right,
                hash_mask,
                max_depth,
                @intCast(src_size_safe),
                match_buf[0..0],
                0,
            );
        }
    }

    // ── Main loop: search + insert at each position. ──
    var pos: usize = preload_size;
    while (pos < src_size_safe) : (pos += 1) {
        var num_match = bt4SearchAndInsert(
            src,
            @intCast(pos),
            head,
            left,
            right,
            hash_mask,
            max_depth,
            @intCast(src_size_safe),
            match_buf[0..],
            @intCast(max_num_matches),
        );

        const mls_pos: usize = pos - preload_size;

        if (num_match > 0) {
            const slice = match_buf[0..num_match];
            std.sort.pdq(LengthAndOffset, slice, {}, compareDescending);
            num_match = @intCast(mls_mod.removeIdentical(slice, num_match));
            try mls_mod.insertMatches(mls, mls_pos, slice, @min(max_num_matches, num_match));
        }

        // Long-match skip: mirror of the hash-based finder. When the best
        // length is >= 77, insert synthetic sub-matches at stride-4 and
        // skip ahead past the long match.
        if (num_match > 0 and match_buf[0].length >= 77) {
            const skip_len: usize = @intCast(match_buf[0].length);
            const skip_offset: i32 = match_buf[0].offset;
            var skip_pos: usize = pos + 4;
            const skip_depth: u32 = if (max_depth >= 4) max_depth / 4 else 1;
            while (skip_pos + 4 < pos + skip_len and skip_pos < src_size_safe) : (skip_pos += 4) {
                _ = bt4SearchAndInsert(
                    src,
                    @intCast(skip_pos),
                    head,
                    left,
                    right,
                    hash_mask,
                    skip_depth,
                    @intCast(src_size_safe),
                    match_buf[0..0],
                    0,
                );
                const sub_len: isize = @as(isize, @intCast(skip_len)) - @as(isize, @intCast(skip_pos - pos));
                if (sub_len >= 4) {
                    var single: [1]LengthAndOffset = .{.{
                        .length = @intCast(sub_len),
                        .offset = skip_offset,
                    }};
                    try mls_mod.insertMatches(mls, skip_pos - preload_size, single[0..], 1);
                }
            }
            pos += skip_len - 5;
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Internal — search + insert
// ────────────────────────────────────────────────────────────

/// Walks the binary tree from `head[hash(pfx4(pos))]`, recording matches
/// of length > 3 along the descent and splicing `pos` into the tree at
/// the point where the descent naturally terminates. Returns the number
/// of matches written into `matches` (up to `max_matches`).
///
/// The C# code uses two pointer variables (`leftNodePtr`, `rightNodePtr`)
/// that each point to either `left[k]` or `right[k]` for some node k,
/// tracking "where we would write the next descended child". This port
/// models the same state with (index, which_array) pairs.
fn bt4SearchAndInsert(
    src: []const u8,
    pos: u32,
    head: []u32,
    left: []u32,
    right: []u32,
    hash_mask: u32,
    max_depth: u32,
    src_safe: u32,
    matches: []LengthAndOffset,
    max_matches: u32,
) u32 {
    // Hash of the 4-byte prefix at pos: rotl(u32 * 0x9E3779B9, 16) & mask.
    const pfx: u32 = std.mem.readInt(u32, src[pos..][0..4], .little);
    const hashed: u32 = std.math.rotl(u32, pfx *% 0x9E3779B9, 16);
    const hash_idx: u32 = hashed & hash_mask;

    const head_val: u32 = head[hash_idx];
    // `cur_match` is the previous writer at this hash slot, 0-based. Use
    // i64 so -1 unambiguously encodes "no candidate".
    var cur_match: i64 = @as(i64, head_val) - 1;
    head[hash_idx] = pos + 1;

    // Dangling-ref slots. Both start at `pos` — left[pos] and right[pos]
    // will be populated with the pos's final left/right subtree roots as
    // the descent narrows.
    var left_ref: usize = pos;
    var right_ref: usize = pos;
    // `*_ref_in_left == true` means the slot referenced by `*_ref` lives
    // in `left[*_ref]`; false means `right[*_ref]`.
    var left_ref_in_left: bool = true;
    var right_ref_in_right: bool = true;

    left[left_ref] = 0;
    right[right_ref] = 0;

    var match_len_left: u32 = 0;
    var match_len_right: u32 = 0;
    var num_found: u32 = 0;
    var best_len: u32 = 3;

    var depth: u32 = 0;
    while (depth < max_depth and cur_match >= 0) : (depth += 1) {
        const cur: u32 = @intCast(cur_match);
        const common_len: u32 = @min(match_len_left, match_len_right);
        const max_len_a: u32 = src_safe - pos;
        const max_len_b: u32 = src_safe - cur;
        const max_len: u32 = @min(max_len_a, max_len_b);
        if (max_len <= common_len) break;

        // Extend from `common_len`. 8-byte XOR + TZCNT tail.
        var match_len: u32 = common_len;
        var remain: u32 = max_len - common_len;
        var pa: usize = @as(usize, pos) + common_len;
        var pb: usize = @as(usize, cur) + common_len;
        var done_extend: bool = false;
        while (remain >= 8) {
            const a: u64 = std.mem.readInt(u64, src[pa..][0..8], .little);
            const b: u64 = std.mem.readInt(u64, src[pb..][0..8], .little);
            const diff: u64 = a ^ b;
            if (diff != 0) {
                match_len += @intCast(@ctz(diff) >> 3);
                done_extend = true;
                break;
            }
            pa += 8;
            pb += 8;
            match_len += 8;
            remain -= 8;
        }
        if (!done_extend) {
            while (remain > 0 and src[pa] == src[pb]) {
                pa += 1;
                pb += 1;
                match_len += 1;
                remain -= 1;
            }
        }

        if (match_len > best_len) {
            best_len = match_len;
            if (matches.len > 0) {
                if (num_found < max_matches) {
                    matches[num_found].set(@intCast(match_len), @intCast(pos - cur));
                    num_found += 1;
                } else if (num_found > 0) {
                    // Replace shortest (linear scan; max_matches is small).
                    var worst_idx: u32 = 0;
                    var k: u32 = 1;
                    while (k < num_found) : (k += 1) {
                        if (matches[k].length < matches[worst_idx].length) worst_idx = k;
                    }
                    if (@as(i32, @intCast(match_len)) > matches[worst_idx].length) {
                        matches[worst_idx].set(@intCast(match_len), @intCast(pos - cur));
                    }
                }
            }

            if (match_len >= max_len) {
                // Suffix exhausted: splice cur's children into our refs.
                writeRef(left, right, left_ref, left_ref_in_left, left[cur]);
                writeRef(left, right, right_ref, right_ref_in_right, right[cur]);
                return num_found;
            }
        }

        // Decide direction by the first mismatched byte.
        const go_left: bool = src[@as(usize, pos) + match_len] < src[@as(usize, cur) + match_len];
        if (go_left) {
            // cur becomes our right-side subtree root; descend into cur.left.
            writeRef(left, right, right_ref, right_ref_in_right, cur + 1);
            right_ref = cur;
            right_ref_in_right = false; // right_ref now lives in left[cur]
            match_len_right = match_len;
            cur_match = @as(i64, left[cur]) - 1;
        } else {
            writeRef(left, right, left_ref, left_ref_in_left, cur + 1);
            left_ref = cur;
            left_ref_in_left = false; // left_ref now lives in right[cur]
            match_len_left = match_len;
            cur_match = @as(i64, right[cur]) - 1;
        }
    }

    // Terminate any dangling pointers.
    writeRef(left, right, left_ref, left_ref_in_left, 0);
    writeRef(left, right, right_ref, right_ref_in_right, 0);

    return num_found;
}

inline fn writeRef(
    left: []u32,
    right: []u32,
    idx: usize,
    in_left: bool,
    val: u32,
) void {
    if (in_left) left[idx] = val else right[idx] = val;
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

test "findMatchesBT4: skip tiny input" {
    var src: [7]u8 = .{ 1, 2, 3, 4, 5, 6, 7 };
    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesBT4(testing.allocator, &src, &mls, 4, 0, 256);
    for (mls.offset2_pos) |p| try testing.expectEqual(@as(i32, 0), p);
}

test "findMatchesBT4: repeating pattern stores matches" {
    var src: [512]u8 = undefined;
    const pattern = "abcdefghABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesBT4(testing.allocator, &src, &mls, 4, 0, 256);

    var any_match: bool = false;
    for (mls.offset2_pos) |p| {
        if (p != 0) {
            any_match = true;
            break;
        }
    }
    try testing.expect(any_match);
}

test "findMatchesBT4: extractable matches via extractLaoFromMls" {
    var src: [1024]u8 = undefined;
    const pattern = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesBT4(testing.allocator, &src, &mls, 4, 0, 256);

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

test "findMatchesBT4: long match skip path" {
    // Build a buffer where bytes [1000..1300) duplicate bytes [0..300),
    // guaranteeing a >= 77 match and exercising the long-skip branch.
    var src: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = @truncate(i);
    @memcpy(src[1000..1300], src[0..300]);

    var mls = try ManagedMatchLenStorage.init(testing.allocator, src.len, 16.0);
    defer mls.deinit();
    try findMatchesBT4(testing.allocator, &src, &mls, 4, 0, 256);

    var long_found: bool = false;
    for (0..src.len) |off| {
        if (mls.offset2_pos[off] == 0) continue;
        var out: [4]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });
        try mls_mod.extractLaoFromMls(&mls, off, 1, &out, 4);
        if (out[0].length >= 77) {
            long_found = true;
            break;
        }
    }
    try testing.expect(long_found);
}
