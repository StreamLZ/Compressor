//! MatchHasher — bucket-based Fibonacci-hash match finder used by the lazy
//! parsers. Port of `MatchHasherBase` + `MatchHasher2x` in
//! src/StreamLZ/Compression/MatchFinding/MatchHasher.cs.
//!
//! Each table entry stores `(tag<<25) | (pos & 0x01FFFFFF)` — 7 high tag bits
//! for collision rejection and 25 low position bits. Positions are tracked
//! relative to `src_base`, which the caller sets to the pinned source base
//! pointer before parsing a sub-chunk.
//!
//! Bucket insert semantics are type-parameterized via comptime `num_hash`:
//!
//!   num_hash = 1  → overwrite (`MatchHasher1`)
//!   num_hash = 2  → shift index+1 ← index, then index ← hval (`MatchHasher2x`)
//!
//! The lazy parser in `fast_lz_parser.zig` uses the 2-entry bucket to keep
//! one "alternate" candidate alive per hash slot without paying for a full
//! chain walk.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");

/// Snapshot of hash state returned by `getHashPos` and consumed by `insert`.
pub const HasherHashPos = struct {
    ptr1_index: u32,
    pos: u32,
    tag: u32,
};

/// Generic bucket hash. `num_hash` is the bucket width (power of 2, no dual).
pub fn MatchHasher(comptime num_hash: u32) type {
    comptime {
        if (num_hash != 1 and num_hash != 2) {
            @compileError("MatchHasher: unsupported num_hash (only 1 or 2 for now)");
        }
    }
    return struct {
        const Self = @This();

        /// Power-of-two-sized hash table. Entry width is 32 bits: tag|pos.
        hash_table: []u32,
        /// Fibonacci multiplier scaled by min-match-length.
        hash_mult: u64,
        /// `(1 << hash_bits) - num_hash` — bucket-aligned index mask.
        hash_mask: u32,
        /// log2 of table size.
        hash_bits: u6,
        /// Minimum-match-length seed used to derive `hash_mult`.
        k: u32,

        /// Pinned raw base pointer to the source window. The caller sets this
        /// before each sub-chunk so position-from-pointer math stays branchless.
        src_base: [*]const u8 = undefined,

        /// Src base offset (relative to the window base). For non-streaming
        /// single-block compress this stays 0.
        src_base_offset: i64 = 0,

        /// Offset of the most recent `setHashPos` call. Used by `insertRange`
        /// to decide whether the cached hash should be flushed before stepping.
        src_cur_offset: i64 = 0,

        // Cached state from the last `setHashPos`.
        hash_entry_ptr_index: u32 = 0,
        current_hash_tag: u32 = 0,

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, hash_bits: u6, min_match_length: u32) !Self {
            if (hash_bits < 8 or hash_bits > 24) return error.HashBitsOutOfRange;
            const size: usize = @as(usize, 1) << hash_bits;
            const table = try allocator.alloc(u32, size);
            @memset(table, 0);

            const k_in: u32 = if (min_match_length == 0) 4 else min_match_length;
            const k_clamped: u32 = @max(@min(k_in, 8), 1);
            const shift_bits_val: u32 = (8 - k_clamped) * 8;
            const mult: u64 = if (shift_bits_val >= 64)
                0
            else
                lz_constants.fibonacci_hash_multiplier << @intCast(shift_bits_val);

            return .{
                .hash_table = table,
                .hash_mult = mult,
                .hash_mask = @as(u32, @intCast((@as(usize, 1) << hash_bits) - num_hash)),
                .hash_bits = hash_bits,
                .k = k_clamped,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.hash_table);
            self.* = undefined;
        }

        /// Zero the hash table and clear the cached state. Cheap for L1 sizes.
        pub fn reset(self: *Self) void {
            @memset(self.hash_table, 0);
            self.src_base_offset = 0;
            self.src_cur_offset = 0;
            self.hash_entry_ptr_index = 0;
            self.current_hash_tag = 0;
        }

        /// Set the pinned source base for position-from-pointer math.
        pub inline fn setSrcBase(self: *Self, base: [*]const u8) void {
            self.src_base = base;
        }

        pub inline fn setBaseWithoutPreload(self: *Self, base_offset: i64) void {
            self.src_base_offset = base_offset;
        }

        /// Combine tag and position into a 32-bit table entry.
        pub inline fn makeHashValue(hash_tag: u32, cur_pos: u32) u32 {
            return (hash_tag & lz_constants.hash_tag_mask) | (cur_pos & lz_constants.hash_position_mask);
        }

        /// Compute the hash for the 8 bytes at `p` and cache the index + tag.
        pub inline fn setHashPos(self: *Self, p: [*]const u8) void {
            const offset: i64 = @intCast(@intFromPtr(p) - @intFromPtr(self.src_base));
            self.src_cur_offset = offset;
            const at_src: u64 = std.mem.readInt(u64, p[0..8], .little);
            const product: u64 = self.hash_mult *% at_src;
            const hi32: u32 = @intCast(product >> 32);
            const hash1: u32 = std.math.rotl(u32, hi32, self.hash_bits);
            self.current_hash_tag = hash1;
            self.hash_entry_ptr_index = hash1 & self.hash_mask;
        }

        /// `setHashPos` + prefetch the cache line containing the target bucket.
        pub inline fn setHashPosPrefetch(self: *Self, p: [*]const u8) void {
            self.setHashPos(p);
            @prefetch(&self.hash_table[self.hash_entry_ptr_index], .{
                .rw = .read,
                .locality = 3,
                .cache = .data,
            });
        }

        /// Capture the current state as an immutable snapshot.
        pub inline fn getHashPos(self: *const Self, p: [*]const u8) HasherHashPos {
            const pos: u32 = @intCast(@as(i64, @intCast(@intFromPtr(p) - @intFromPtr(self.src_base))) - self.src_base_offset);
            return .{
                .ptr1_index = self.hash_entry_ptr_index,
                .pos = pos,
                .tag = self.current_hash_tag,
            };
        }

        /// Insert the captured state into the bucket.
        pub inline fn insert(self: *Self, hp: HasherHashPos) void {
            const he = makeHashValue(hp.tag, hp.pos);
            self.insertAtIndex(hp.ptr1_index, he);
        }

        /// Bucket ring-buffer insert.
        pub inline fn insertAtIndex(self: *Self, index: u32, hval: u32) void {
            if (num_hash == 1) {
                self.hash_table[index] = hval;
            } else if (num_hash == 2) {
                self.hash_table[index + 1] = self.hash_table[index];
                self.hash_table[index] = hval;
            }
        }

        /// Insert entries covering the interior of a freshly emitted match at
        /// exponentially spaced positions. Ported from `MatchHasherBase.InsertRange`.
        pub fn insertRange(self: *Self, match_start: [*]const u8, len: usize) void {
            const offset: i64 = @intCast(@intFromPtr(match_start) - @intFromPtr(self.src_base));
            if (self.src_cur_offset < offset + @as(i64, @intCast(len))) {
                const he = makeHashValue(self.current_hash_tag, @as(u32, @intCast(self.src_cur_offset - self.src_base_offset)));
                self.insertAtIndex(self.hash_entry_ptr_index, he);

                var i: i64 = self.src_cur_offset - offset + 1;
                while (i < @as(i64, @intCast(len))) : (i *= 2) {
                    const p: [*]const u8 = @ptrFromInt(@intFromPtr(match_start) + @as(usize, @intCast(i)));
                    const at_src: u64 = std.mem.readInt(u64, p[0..8], .little);
                    const product: u64 = self.hash_mult *% at_src;
                    const hi32: u32 = @intCast(product >> 32);
                    const hash: u32 = std.math.rotl(u32, hi32, self.hash_bits);
                    const idx: u32 = hash & self.hash_mask;
                    const pos_here: u32 = @intCast(offset + i - self.src_base_offset);
                    self.insertAtIndex(idx, makeHashValue(hash, pos_here));
                }
                const after: [*]const u8 = @ptrFromInt(@intFromPtr(match_start) + len);
                self.setHashPos(after);
            } else if (self.src_cur_offset != offset + @as(i64, @intCast(len))) {
                const after: [*]const u8 = @ptrFromInt(@intFromPtr(match_start) + len);
                self.setHashPos(after);
            }
        }
    };
}

/// Convenience aliases matching the C# class names.
pub const MatchHasher1 = MatchHasher(1);
pub const MatchHasher2x = MatchHasher(2);

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "MatchHasher2x init sizes the table and computes mask/mult" {
    var h = try MatchHasher2x.init(testing.allocator, 14, 4);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1 << 14), h.hash_table.len);
    // Mask is (1 << 14) - 2 = 0x3FFE — low bit is 0 so every bucket is 2-aligned.
    try testing.expectEqual(@as(u32, (1 << 14) - 2), h.hash_mask);
    try testing.expectEqual(@as(u64, lz_constants.fibonacci_hash_multiplier << 32), h.hash_mult);
}

test "MatchHasher2x insertAtIndex shifts then writes" {
    var h = try MatchHasher2x.init(testing.allocator, 10, 4);
    defer h.deinit();
    h.hash_table[4] = 0;
    h.hash_table[5] = 0;
    h.insertAtIndex(4, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), h.hash_table[4]);
    try testing.expectEqual(@as(u32, 0), h.hash_table[5]);
    h.insertAtIndex(4, 0x12345678);
    try testing.expectEqual(@as(u32, 0x12345678), h.hash_table[4]);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), h.hash_table[5]);
}

test "MatchHasher2x setHashPos caches tag and bucket-aligned index" {
    var h = try MatchHasher2x.init(testing.allocator, 12, 4);
    defer h.deinit();
    const buf = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };
    h.setSrcBase(&buf);
    h.setHashPos(&buf);
    try testing.expect(h.hash_entry_ptr_index < h.hash_table.len);
    // The low bit of the index must be 0 because num_hash=2 zeros bit 0 in the mask.
    try testing.expectEqual(@as(u32, 0), h.hash_entry_ptr_index & 1);
}

test "MatchHasher2x insert writes tag+pos into bucket" {
    var buf: [64]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('a' + (i % 8));
    var h = try MatchHasher2x.init(testing.allocator, 12, 4);
    defer h.deinit();
    h.setSrcBase(&buf);

    h.setHashPos(&buf);
    const hp = h.getHashPos(&buf);
    h.insert(hp);

    const stored = h.hash_table[hp.ptr1_index];
    // Pos portion must round-trip.
    try testing.expectEqual(@as(u32, 0), stored & lz_constants.hash_position_mask);
    // Tag portion must match.
    try testing.expectEqual(hp.tag & lz_constants.hash_tag_mask, stored & lz_constants.hash_tag_mask);
}

test "MatchHasher2x insertRange populates exponentially spaced positions" {
    var buf: [512]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    var h = try MatchHasher2x.init(testing.allocator, 12, 4);
    defer h.deinit();
    h.setSrcBase(&buf);

    const p10: [*]const u8 = buf[10..].ptr;
    h.setHashPos(p10);
    h.insert(h.getHashPos(p10));

    // Match starting at offset 10, length 100.
    h.insertRange(p10, 100);

    // After insertRange the cached state should point at offset 110.
    try testing.expectEqual(@as(i64, 110), h.src_cur_offset);
}
