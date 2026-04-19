//! FastMatchHasher — single-entry Fibonacci-hash table used by the greedy
//! Fast LZ parser. Port of `FastMatchHasher<T>` in
//! src/StreamLZ/Compression/MatchFinding/MatchHasher.cs.
//! Used by: Fast codec (L1-L5)
//!
//! Hot-loop design:
//!   * The hash table is plain contiguous memory (slice of `T`), sized to a
//!     power of two. The parser reads `*(u64*)src * hashMult >> (64 - bits)`
//!     and indexes the table directly — no indirection or method call.
//!   * Table entries store positions truncated to `T`'s width (u16 or u32),
//!     relative to a fixed "base offset" (usually 0 for non-streaming).
//!     Truncation means the parser always subtracts the stored value from the
//!     current position mod-`T`, giving an unsigned offset it can bounds-check
//!     against the dictionary size.
//!   * The parser doesn't call any hasher method; it pulls `hash_table`,
//!     `hash_mult`, and `hash_shift` into locals at entry and keeps them in
//!     registers across iterations.
//!
//! Cache notes:
//!   * For u32 entries at 17 bits, table = 512 KB → spills to L2. For 14 bits
//!     (u16 entries, level -2) it's 32 KB → fits in L1. Keep the bit count at
//!     or below the per-level maximum from `Fast.Compressor.SetupEncoder`.

const std = @import("std");
const constants = @import("fast_constants.zig");

/// Parameters used to size a `FastMatchHasher`.
pub const HasherParams = struct {
    hash_bits: u6,
    /// Minimum match length (usually 4). Used to scale the Fibonacci hash so
    /// the multiplied value emphasizes the first `k` bytes.
    min_match_length: u32,
};

/// Generic single-entry hash table. `T` is `u16` for engine level ≤ -2 and
/// `u32` otherwise. A larger `T` lets the table span a larger effective
/// dictionary without truncation ambiguity, but costs twice the memory.
pub fn FastMatchHasher(comptime T: type) type {
    comptime {
        if (T != u16 and T != u32) @compileError("FastMatchHasher: T must be u16 or u32");
    }
    return struct {
        const Self = @This();

        /// Contiguous hash table. Length is `1 << hash_bits`.
        hash_table: []T,
        /// Multiplier applied to the 64-bit word at the cursor before shifting.
        /// `0x9E3779B97F4A7C15 << (8 * (8 - min_match_length))`.
        hash_mult: u64,
        /// Right-shift amount after the multiply: `64 - hash_bits`.
        hash_shift: u6,
        /// Base offset subtracted from positions before storing in the table.
        /// Source base offset. For non-streaming compress, this is 0.
        src_base_offset: i64,
        /// Allocator kept for `deinit`.
        allocator: std.mem.Allocator,

        /// Allocates and zeros a new hash table for the given parameters.
        ///
        /// Allocates hash table, including
        /// the special-case for k=4 (the default):
        ///
        ///   if (k in [5, 8]):  hashMult = FibonacciHashMultiplier << (8 * (8 - k))
        ///   else (k = 0 or 4): hashMult = 0x9E3779B100000000UL
        ///
        /// This is intentionally DIFFERENT from `MatchHasherBase.AllocateHash`
        /// which uses `FibonacciHashMultiplier << (8 * (8 - k))` for all k.
        pub fn init(allocator: std.mem.Allocator, params: HasherParams) !Self {
            if (params.hash_bits < 8 or params.hash_bits > 24) return error.HashBitsOutOfRange;
            const k: u32 = if (params.min_match_length == 0) 4 else params.min_match_length;
            const size: usize = @as(usize, 1) << params.hash_bits;
            const table = try allocator.alloc(T, size);
            @memset(table, 0);

            const mult: u64 = if (k >= 5 and k <= 8) blk: {
                const shift_bits_val: u32 = (8 - k) * 8;
                break :blk constants.fibonacci_hash_multiplier << @intCast(shift_bits_val);
            } else 0x9E3779B100000000;

            return .{
                .hash_table = table,
                .hash_mult = mult,
                .hash_shift = @intCast(64 - @as(u32, params.hash_bits)),
                .src_base_offset = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.hash_table);
            self.* = undefined;
        }

        /// Zeroes the hash table. O(n) — cheap for L1 sizes, meaningful for L5.
        pub fn reset(self: *Self) void {
            @memset(self.hash_table, 0);
        }

        /// Insert dictionary positions into the hash table so the first
        /// chunk can find matches against dictionary content.
        pub fn preloadDictionary(self: *Self, src: [*]const u8, dict_len: usize) void {
            if (dict_len < 8) return;
            var pos: usize = 0;
            while (pos + 8 <= dict_len) : (pos += 1) {
                const word = std.mem.readInt(u64, (src + pos)[0..8], .little);
                const idx: usize = @intCast((word *% self.hash_mult) >> self.hash_shift);
                self.hash_table[idx] = @intCast(pos + 1);
            }
        }
    };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "FastMatchHasher(u32) allocates a power-of-two table and computes shift" {
    var h = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 14, .min_match_length = 4 });
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1 << 14), h.hash_table.len);
    try testing.expectEqual(@as(u6, 50), h.hash_shift);
    // k = 4 falls out of the [5,8] band so use the special constant.
    try testing.expectEqual(@as(u64, 0x9E3779B100000000), h.hash_mult);
    for (h.hash_table) |e| try testing.expectEqual(@as(u32, 0), e);
}

test "FastMatchHasher(u32) k=5 uses shifted Fibonacci constant" {
    var h = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 14, .min_match_length = 5 });
    defer h.deinit();
    try testing.expectEqual(@as(u64, constants.fibonacci_hash_multiplier << 24), h.hash_mult);
}

test "FastMatchHasher(u16) 13-bit table" {
    var h = try FastMatchHasher(u16).init(testing.allocator, .{ .hash_bits = 13, .min_match_length = 4 });
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1 << 13), h.hash_table.len);
    try testing.expectEqual(@as(u6, 51), h.hash_shift);
}

test "FastMatchHasher hashes to valid index" {
    var h = try FastMatchHasher(u32).init(testing.allocator, .{ .hash_bits = 16, .min_match_length = 4 });
    defer h.deinit();
    const buf = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };
    const word: u64 = std.mem.readInt(u64, &buf, .little);
    const index: usize = @intCast((word *% h.hash_mult) >> h.hash_shift);
    try testing.expect(index < h.hash_table.len);
}
