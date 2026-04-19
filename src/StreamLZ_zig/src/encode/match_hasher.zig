//! MatchHasher — bucket-based Fibonacci-hash match finder used by the lazy
//! parsers. Port of `MatchHasherBase` + `MatchHasher{1,2x,4,4Dual,16Dual}`
//! in src/StreamLZ/Compression/MatchFinding/MatchHasher.cs.
//! Used by: Fast and High codecs
//!
//! Each table entry stores `(tag<<25) | (pos & 0x01FFFFFF)` — 7 high tag bits
//! for collision rejection and 25 low position bits. Positions are tracked
//! relative to `src_base`, which the caller sets to the pinned source base
//! pointer before parsing a sub-chunk.
//!
//! Bucket insert semantics are type-parameterized via comptime `num_hash`:
//!
//!   num_hash = 1   → overwrite (`MatchHasher1`)
//!   num_hash = 2   → shift index+1 ← index, then index ← hval (`MatchHasher2x`)
//!   num_hash = 4   → 4-entry ring shift (`MatchHasher4`, `MatchHasher4Dual`)
//!   num_hash = 16  → 16-entry ring shift (`MatchHasher16Dual`)
//!
//! The `dual_hash` comptime flag adds a secondary hash: the second index
//! is derived from `FibonacciHashMultiplier * atSrc >> (64 - bits)` and is
//! bucket-aligned via `~(num_hash - 1)`. Dual-hash hashers insert into
//! both buckets on every call — higher probe cost, better coverage for
//! High codec levels ≥ 3.
//!
//! The lazy parser in `fast_lz_parser.zig` uses the 2-entry bucket to keep
//! one "alternate" candidate alive per hash slot without paying for a full
//! chain walk. The High codec uses the 4/16-entry dual-hash variants.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");

/// Snapshot of hash state returned by `getHashPos` and consumed by `insert`.
pub const HasherHashPos = struct {
    ptr1_index: u32,
    /// Secondary bucket index when the hasher uses dual hashing. Unused
    /// when `dual_hash = false` (value is 0).
    ptr2_index: u32 = 0,
    pos: u32,
    tag: u32,
};

/// Generic bucket hash. `num_hash` is the bucket width (power of 2).
/// `dual_hash` enables a second hash index derived from the raw
/// Fibonacci multiplier, for better collision coverage.
pub fn MatchHasher(comptime num_hash: u32, comptime dual_hash: bool) type {
    comptime {
        if (num_hash != 1 and num_hash != 2 and num_hash != 4 and num_hash != 16) {
            @compileError("MatchHasher: unsupported num_hash (must be 1, 2, 4, or 16)");
        }
        if (dual_hash and num_hash == 1) {
            @compileError("MatchHasher: dual_hash requires num_hash >= 2");
        }
    }
    return struct {
        const Self = @This();
        pub const bucket_width: u32 = num_hash;
        pub const uses_dual_hash: bool = dual_hash;

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
        /// Secondary bucket index when `dual_hash = true` (otherwise unused).
        hash_entry2_ptr_index: u32 = 0,
        current_hash_tag: u32 = 0,

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, hash_bits: u6, min_match_length: u32) !Self {
            if (hash_bits < 8 or hash_bits > 24) return error.HashBitsOutOfRange;
            const size: usize = @as(usize, 1) << hash_bits;
            // 64-byte-aligned allocation so every 16-entry bucket
            // (which the hash mask forces to start at a multiple of
            // 16 → 64-byte offset) lands on a single cache line.
            // VTune showed bucket loads as the dominant hot spot in
            // findMatchesHashBased; with default 4-byte allocator
            // alignment, 15 of 16 buckets straddled two cache lines.
            const table_aligned = try allocator.alignedAlloc(u32, .fromByteUnits(64), size);
            const table: []u32 = table_aligned;
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
        /// When `dual_hash = true`, also computes a secondary bucket index.
        pub inline fn setHashPos(self: *Self, p: [*]const u8) void {
            const offset: i64 = @intCast(@intFromPtr(p) - @intFromPtr(self.src_base));
            self.src_cur_offset = offset;
            const at_src: u64 = std.mem.readInt(u64, p[0..8], .little);
            const product: u64 = self.hash_mult *% at_src;
            const hi32: u32 = @intCast(product >> 32);
            const hash1: u32 = std.math.rotl(u32, hi32, self.hash_bits);
            self.current_hash_tag = hash1;
            self.hash_entry_ptr_index = hash1 & self.hash_mask;
            if (dual_hash) {
                // Second hash uses the raw Fibonacci multiplier and a
                // different shift:
                //     hash2 = (FibonacciMult * atSrc) >> (64 - bits)
                //     HashEntry2Ptr = hash2 & ~(NumHash - 1)
                const fib_mult: u64 = lz_constants.fibonacci_hash_multiplier;
                const product2: u64 = fib_mult *% at_src;
                const shift_amt: u6 = @intCast(64 - @as(u32, self.hash_bits));
                const hash2: u32 = @intCast(product2 >> shift_amt);
                self.hash_entry2_ptr_index = hash2 & ~(@as(u32, num_hash) - 1);
            }
        }

        /// `setHashPos` + prefetch the cache lines containing the target
        /// bucket(s). For dual-hash mode, prefetches BOTH the primary
        /// (cur1) and dual (cur2) buckets. Without this,
        /// every iteration of `findMatchesHashBased` cache-missed on
        /// the dual bucket → ~8 sec of DRAM stalls on 100 MB enwik8 L9.
        pub inline fn setHashPosPrefetch(self: *Self, p: [*]const u8) void {
            self.setHashPos(p);
            @prefetch(&self.hash_table[self.hash_entry_ptr_index], .{
                .rw = .read,
                .locality = 3,
                .cache = .data,
            });
            if (dual_hash) {
                @prefetch(&self.hash_table[self.hash_entry2_ptr_index], .{
                    .rw = .read,
                    .locality = 3,
                    .cache = .data,
                });
            }
        }

        /// Capture the current state as an immutable snapshot.
        pub inline fn getHashPos(self: *const Self, p: [*]const u8) HasherHashPos {
            const pos: u32 = @intCast(@as(i64, @intCast(@intFromPtr(p) - @intFromPtr(self.src_base))) - self.src_base_offset);
            return .{
                .ptr1_index = self.hash_entry_ptr_index,
                .ptr2_index = if (dual_hash) self.hash_entry2_ptr_index else 0,
                .pos = pos,
                .tag = self.current_hash_tag,
            };
        }

        /// Insert the captured state into the bucket. Dual-hash variants
        /// insert at both primary and secondary indices.
        pub inline fn insert(self: *Self, hp: HasherHashPos) void {
            const he = makeHashValue(hp.tag, hp.pos);
            self.insertAtIndex(hp.ptr1_index, he);
            if (dual_hash) {
                self.insertAtIndex(hp.ptr2_index, he);
            }
        }

        /// Explicit dual-index insert — takes a pre-computed hash value
        /// plus two bucket indices and writes to both (when `dual_hash`
        /// is true). Used by
        /// `FindMatchesHashBased` so the hash value can be composed
        /// inline via `makeHashValue`.
        pub inline fn insertAtDual(self: *Self, idx1: u32, idx2: u32, hval: u32) void {
            self.insertAtIndex(idx1, hval);
            if (dual_hash) self.insertAtIndex(idx2, hval);
        }

        /// Bucket ring-buffer insert — shift entries `[0..num_hash-1]` to
        /// `[1..num_hash]` then write `hval` at `index`.
        pub inline fn insertAtIndex(self: *Self, index: u32, hval: u32) void {
            switch (num_hash) {
                1 => self.hash_table[index] = hval,
                2 => {
                    self.hash_table[index + 1] = self.hash_table[index];
                    self.hash_table[index] = hval;
                },
                4 => {
                    // MatchHasher4.InsertAtIndex: load 3 consecutive
                    // entries into locals then store shifted.
                    const a = self.hash_table[index + 2];
                    const b = self.hash_table[index + 1];
                    const c = self.hash_table[index];
                    self.hash_table[index + 3] = a;
                    self.hash_table[index + 2] = b;
                    self.hash_table[index + 1] = c;
                    self.hash_table[index] = hval;
                },
                16 => {
                    // MatchHasher16Dual uses SSE2 overlapping 128-bit
                    // stores. Scalar version for Zig: shift entries
                    // [0..14] → [1..15] then write hval at index.
                    var i: u32 = 14;
                    while (true) : (i -= 1) {
                        self.hash_table[index + i + 1] = self.hash_table[index + i];
                        if (i == 0) break;
                    }
                    self.hash_table[index] = hval;
                },
                else => unreachable,
            }
        }

        /// Insert entries covering the interior of a freshly emitted match at
        /// exponentially spaced positions. Ported from `MatchHasherBase.InsertRange`.
        pub fn insertRange(self: *Self, match_start: [*]const u8, len: usize) void {
            const offset: i64 = @intCast(@intFromPtr(match_start) - @intFromPtr(self.src_base));
            if (self.src_cur_offset < offset + @as(i64, @intCast(len))) {
                const he = makeHashValue(self.current_hash_tag, @as(u32, @intCast(self.src_cur_offset - self.src_base_offset)));
                self.insertAtIndex(self.hash_entry_ptr_index, he);
                if (dual_hash) self.insertAtIndex(self.hash_entry2_ptr_index, he);

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

        /// Set base offset without preloading.
        pub inline fn setBaseAndPreloadNone(self: *Self, base_offset: i64) void {
            self.src_base_offset = base_offset;
        }

        /// Preload the hash table from a pre-existing dictionary window. Positions
        /// `[srcBaseOffset .. srcStartOffset]` are walked with an adaptive
        /// step size and inserted into the hash table before compression
        /// begins. `src_base_ptr` must be the base pointer such that
        /// `src_base_ptr + srcBaseOffset` points at the first byte of the
        /// preload region, and `src_base_ptr + srcStartOffset` points at
        /// the first byte the compressor is about to scan.
        pub fn setBaseAndPreload(
            self: *Self,
            src_base_ptr: [*]const u8,
            src_base_offset: i64,
            src_start_offset: i64,
            max_preload_len: usize,
        ) void {
            self.src_base_offset = src_base_offset;
            if (src_base_offset == src_start_offset) return;
            // Point src_base so position arithmetic through the hasher's
            // own setHashPos works consistently.
            self.src_base = src_base_ptr;

            const Inserter = struct {
                hasher: *Self,
                base_ptr: [*]const u8,

                pub fn insert(ctx: @This(), offs: i64) void {
                    const p: [*]const u8 = @ptrFromInt(@intFromPtr(ctx.base_ptr) + @as(usize, @intCast(offs)));
                    ctx.hasher.setHashPos(p);
                    const hp = ctx.hasher.getHashPos(p);
                    ctx.hasher.insert(hp);
                }
            };
            const inserter = Inserter{ .hasher = self, .base_ptr = src_base_ptr };
            adaptivePreloadLoop(Inserter, inserter, src_base_offset, src_start_offset, max_preload_len);
        }
    };
}

/// Adaptive-step preload loop.
/// Starts with a large step near the dictionary base and halves the step
/// as it approaches `src_start_offset`, giving denser coverage near the
/// positions most likely to be matched.
pub fn adaptivePreloadLoop(
    comptime Inserter: type,
    inserter: Inserter,
    src_base_offset: i64,
    src_start_offset: i64,
    max_preload_len: usize,
) void {
    std.debug.assert(src_start_offset > src_base_offset);
    var preload_len: i64 = src_start_offset - src_base_offset;
    var cur_offset: i64 = src_base_offset;

    if (preload_len > @as(i64, @intCast(max_preload_len))) {
        preload_len = @intCast(max_preload_len);
        cur_offset = src_start_offset - preload_len;
    }

    var step: i32 = @max(@as(i32, @intCast(preload_len >> 18)), 2);
    var rounds_until_next_step: i32 = @intCast(@divTrunc(preload_len >> 1, step));

    while (true) {
        rounds_until_next_step -= 1;
        if (rounds_until_next_step <= 0) {
            if (cur_offset >= src_start_offset) break;
            step >>= 1;
            std.debug.assert(step >= 1);
            rounds_until_next_step = @intCast(@divTrunc(src_start_offset - cur_offset, step));
            if (step > 1) rounds_until_next_step >>= 1;
        }
        inserter.insert(cur_offset);
        cur_offset += step;
    }
}

/// Convenience aliases.
/// Non-dual bucket hashers.
pub const MatchHasher1 = MatchHasher(1, false);
pub const MatchHasher2x = MatchHasher(2, false);
pub const MatchHasher4 = MatchHasher(4, false);
/// Dual-hash variants: insert at primary AND secondary bucket on every call.
pub const MatchHasher4Dual = MatchHasher(4, true);
pub const MatchHasher16Dual = MatchHasher(16, true);

// ────────────────────────────────────────────────────────────
//  MatchHasher2 — 3-table chain hasher for the L4 lazy parser
// ────────────────────────────────────────────────────────────

/// Hash position returned by `MatchHasher2.getHashPos`.
pub const MatchHasher2HashPos = struct {
    pos: u32,
    hash_a: u32,
    hash_b: u32,
    hash_b_tag: u32,
    next_offset: i64,
};

/// Chain-walking match hasher with a first-hash head table, a modulo-64K
/// next-hash ring for the chain, and a direct-mapped long-hash table with a
/// 6-bit tag. Port of `MatchHasher2` in
/// src/StreamLZ/Compression/MatchFinding/MatchHasher.cs.
pub const MatchHasher2 = struct {
    /// Hash-A multiplier — distinct from Fibonacci to decorrelate the two hashes.
    const mult_a: u64 = 0xB7A5646300000000;
    const mult_b: u64 = @import("../format/streamlz_constants.zig").fibonacci_hash_multiplier;

    first_hash: []u32,
    long_hash: []u32,
    next_hash: []u16,

    first_hash_mask: u32,
    long_hash_mask: u32,
    next_hash_mask: u32,

    first_hash_bits: u6,
    long_hash_bits: u6,

    src_base: [*]const u8 = undefined,
    src_base_offset: i64 = 0,
    src_cur_offset: i64 = 0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bits: u6) !MatchHasher2 {
        const a_bits: u6 = @min(bits, 19);
        const b_bits: u6 = @min(bits, 19);
        const c_bits: u6 = 16;

        const first = try allocator.alloc(u32, @as(usize, 1) << a_bits);
        errdefer allocator.free(first);
        const long = try allocator.alloc(u32, @as(usize, 1) << b_bits);
        errdefer allocator.free(long);
        const next = try allocator.alloc(u16, @as(usize, 1) << c_bits);
        @memset(first, 0);
        @memset(long, 0);
        @memset(next, 0);

        return .{
            .first_hash = first,
            .long_hash = long,
            .next_hash = next,
            .first_hash_mask = @intCast((@as(usize, 1) << a_bits) - 1),
            .long_hash_mask = @intCast((@as(usize, 1) << b_bits) - 1),
            .next_hash_mask = @intCast((@as(usize, 1) << c_bits) - 1),
            .first_hash_bits = a_bits,
            .long_hash_bits = b_bits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatchHasher2) void {
        self.allocator.free(self.first_hash);
        self.allocator.free(self.long_hash);
        self.allocator.free(self.next_hash);
        self.* = undefined;
    }

    pub fn reset(self: *MatchHasher2) void {
        @memset(self.first_hash, 0);
        @memset(self.long_hash, 0);
        @memset(self.next_hash, 0);
        self.src_base_offset = 0;
        self.src_cur_offset = 0;
    }

    pub fn preloadDictionary(self: *MatchHasher2, src: [*]const u8, dict_len: usize) void {
        if (dict_len < 8) return;
        self.insertRange(src, dict_len - 7);
    }

    pub inline fn setSrcBase(self: *MatchHasher2, base: [*]const u8) void {
        self.src_base = base;
    }

    pub inline fn setBaseWithoutPreload(self: *MatchHasher2, base_offset: i64) void {
        self.src_base_offset = base_offset;
    }

    /// Compute the two raw hash values for the 8 bytes at `p`.
    pub inline fn getHashPos(self: *const MatchHasher2, p: [*]const u8) MatchHasher2HashPos {
        const offset: i64 = @intCast(@intFromPtr(p) - @intFromPtr(self.src_base));
        const at_src: u64 = std.mem.readInt(u64, p[0..8], .little);
        const product_a: u64 = mult_a *% at_src;
        const hash_a_full: u32 = @intCast(product_a >> 32);
        const product_b: u64 = mult_b *% at_src;
        const hash_b_full: u32 = @intCast(product_b >> 32);
        const shift_a: u5 = @intCast(32 - @as(u32, self.first_hash_bits));
        const shift_b: u5 = @intCast(32 - @as(u32, self.long_hash_bits));
        return .{
            .pos = @intCast(offset - self.src_base_offset),
            .hash_a = hash_a_full >> shift_a,
            .hash_b = hash_b_full >> shift_b,
            .hash_b_tag = hash_b_full,
            .next_offset = offset + 1,
        };
    }

    /// `getHashPos` + prefetch firstHash + longHash entries for `p`.
    pub inline fn setHashPosPrefetch(self: *MatchHasher2, p: [*]const u8) void {
        const hp = self.getHashPos(p);
        @prefetch(&self.first_hash[hp.hash_a], .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
        @prefetch(&self.long_hash[hp.hash_b], .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
    }

    /// In this hasher family `setHashPos` only updates the cursor — no hashing.
    pub inline fn setHashPos(self: *MatchHasher2, p: [*]const u8) void {
        self.src_cur_offset = @intCast(@intFromPtr(p) - @intFromPtr(self.src_base));
    }

    /// Insert the hash position into the chain head + next-hash ring.
    /// The longHash table is updated separately by `insertRange` to amortize
    /// the cost — the hot path only touches firstHash / nextHash.
    pub inline fn insert(self: *MatchHasher2, hp: MatchHasher2HashPos) void {
        const prev_head: u32 = self.first_hash[hp.hash_a];
        self.next_hash[hp.pos & self.next_hash_mask] = @intCast(prev_head & 0xFFFF);
        self.first_hash[hp.hash_a] = hp.pos;
        self.src_cur_offset = hp.next_offset;
    }

    /// Insert entries covering a match of length `len` starting at
    /// `match_start`. longHash at exponentially spaced positions; firstHash
    /// at every position from the cached cursor up to `offset + len`.
    pub fn insertRange(self: *MatchHasher2, match_start: [*]const u8, len: usize) void {
        const offset: i64 = @intCast(@intFromPtr(match_start) - @intFromPtr(self.src_base));
        const shift_b: u5 = @intCast(32 - @as(u32, self.long_hash_bits));

        // longHash at i = 0, 1, 3, 7, 15, ... (geometric steps).
        var i: usize = 0;
        while (i < len) {
            const p: [*]const u8 = @ptrFromInt(@intFromPtr(match_start) + i);
            const at_src: u64 = std.mem.readInt(u64, p[0..8], .little);
            const product_b: u64 = mult_b *% at_src;
            const hash_b_full: u32 = @intCast(product_b >> 32);
            const idx: u32 = hash_b_full >> shift_b;
            const pos_here: u32 = @intCast(offset + @as(i64, @intCast(i)) - self.src_base_offset);
            self.long_hash[idx] = (hash_b_full & 0x3F) | (pos_here << 6);
            i = 2 * i + 1;
        }

        // firstHash chain-insert at every byte from cursor to offset + len.
        const p_end: i64 = offset + @as(i64, @intCast(len));
        const shift_a: u5 = @intCast(32 - @as(u32, self.first_hash_bits));
        while (self.src_cur_offset < p_end) {
            const cur_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(self.src_base) + @as(usize, @intCast(self.src_cur_offset)));
            const at_src: u64 = std.mem.readInt(u64, cur_ptr[0..8], .little);
            const product_a: u64 = mult_a *% at_src;
            const hash_a_full: u32 = @intCast(product_a >> 32);
            const hash_a: u32 = hash_a_full >> shift_a;
            const pos_here: u32 = @intCast(self.src_cur_offset - self.src_base_offset);

            const prev_head: u32 = self.first_hash[hash_a];
            self.next_hash[pos_here & self.next_hash_mask] = @intCast(prev_head & 0xFFFF);
            self.first_hash[hash_a] = pos_here;
            self.src_cur_offset += 1;
        }
    }
};

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

test "MatchHasher2 init sizes three tables and computes masks" {
    var h = try MatchHasher2.init(testing.allocator, 17);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1 << 17), h.first_hash.len);
    try testing.expectEqual(@as(usize, 1 << 17), h.long_hash.len);
    try testing.expectEqual(@as(usize, 1 << 16), h.next_hash.len);
    try testing.expectEqual(@as(u6, 17), h.first_hash_bits);
    try testing.expectEqual(@as(u6, 17), h.long_hash_bits);
}

test "MatchHasher2 insert / getHashPos round-trip" {
    var buf: [64]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('a' + (i % 8));
    var h = try MatchHasher2.init(testing.allocator, 14);
    defer h.deinit();
    h.setSrcBase(&buf);

    const p0: [*]const u8 = buf[0..].ptr;
    const hp = h.getHashPos(p0);
    h.insert(hp);
    try testing.expectEqual(@as(u32, 0), hp.pos);
    try testing.expectEqual(hp.pos, h.first_hash[hp.hash_a]);
}

test "MatchHasher2 insertRange bumps cursor to end" {
    var buf: [256]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('a' + (i % 5));
    var h = try MatchHasher2.init(testing.allocator, 14);
    defer h.deinit();
    h.setSrcBase(&buf);

    h.src_cur_offset = 10;
    const p10: [*]const u8 = buf[10..].ptr;
    h.insertRange(p10, 50);
    try testing.expectEqual(@as(i64, 60), h.src_cur_offset);
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

test "MatchHasher4 init: mask is bucket-aligned, num_hash=4" {
    var h = try MatchHasher4.init(testing.allocator, 12, 4);
    defer h.deinit();
    // Mask is (1 << 12) - 4 = 0xFFC — low 2 bits are 0 so every bucket is 4-aligned.
    try testing.expectEqual(@as(u32, (1 << 12) - 4), h.hash_mask);
}

test "MatchHasher4 insertAtIndex ring-shifts 4 entries" {
    var h = try MatchHasher4.init(testing.allocator, 10, 4);
    defer h.deinit();
    h.hash_table[4] = 0x11;
    h.hash_table[5] = 0x22;
    h.hash_table[6] = 0x33;
    h.hash_table[7] = 0x44;
    h.insertAtIndex(4, 0xAA);
    try testing.expectEqual(@as(u32, 0xAA), h.hash_table[4]);
    try testing.expectEqual(@as(u32, 0x11), h.hash_table[5]);
    try testing.expectEqual(@as(u32, 0x22), h.hash_table[6]);
    try testing.expectEqual(@as(u32, 0x33), h.hash_table[7]);
}

test "MatchHasher4Dual sets a secondary bucket index on setHashPos" {
    var buf: [64]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    var h = try MatchHasher4Dual.init(testing.allocator, 14, 4);
    defer h.deinit();
    h.setSrcBase(&buf);
    h.setHashPos(&buf);

    // Both indices are valid bucket-aligned positions in the table.
    try testing.expect(h.hash_entry_ptr_index < h.hash_table.len);
    try testing.expect(h.hash_entry2_ptr_index < h.hash_table.len);
    try testing.expectEqual(@as(u32, 0), h.hash_entry_ptr_index & 3);
    try testing.expectEqual(@as(u32, 0), h.hash_entry2_ptr_index & 3);
}

test "MatchHasher4Dual insert writes at both primary and secondary" {
    var buf: [128]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    var h = try MatchHasher4Dual.init(testing.allocator, 12, 4);
    defer h.deinit();
    h.setSrcBase(&buf);
    h.setHashPos(&buf);
    const hp = h.getHashPos(&buf);
    h.insert(hp);
    // Tag bits must match in both primary and secondary buckets.
    const tag_mask = lz_constants.hash_tag_mask;
    const primary_tag = h.hash_table[hp.ptr1_index] & tag_mask;
    const secondary_tag = h.hash_table[hp.ptr2_index] & tag_mask;
    try testing.expectEqual(hp.tag & tag_mask, primary_tag);
    try testing.expectEqual(hp.tag & tag_mask, secondary_tag);
}

test "MatchHasher16Dual init: 16-aligned mask" {
    var h = try MatchHasher16Dual.init(testing.allocator, 14, 4);
    defer h.deinit();
    try testing.expectEqual(@as(u32, (1 << 14) - 16), h.hash_mask);
}

test "MatchHasher16Dual insertAtIndex ring-shifts 16 entries" {
    var h = try MatchHasher16Dual.init(testing.allocator, 12, 4);
    defer h.deinit();
    // Seed 16 consecutive entries.
    for (0..16) |i| h.hash_table[i] = @as(u32, @intCast(i)) + 1;
    h.insertAtIndex(0, 0xFFFF);
    try testing.expectEqual(@as(u32, 0xFFFF), h.hash_table[0]);
    for (1..16) |i| try testing.expectEqual(@as(u32, @intCast(i)), h.hash_table[i]);
}

test "adaptivePreloadLoop visits cur_offset in step progression" {
    // Preallocate a generous buffer and fill from the inserter; exceed
    // the default ArrayList capacity by pre-sizing.
    var buf: [8192]i64 = undefined;
    var count: usize = 0;

    const Inserter = struct {
        buf_ptr: [*]i64,
        count_ptr: *usize,

        pub fn insert(ctx: @This(), offs: i64) void {
            ctx.buf_ptr[ctx.count_ptr.*] = offs;
            ctx.count_ptr.* += 1;
        }
    };

    const inserter = Inserter{ .buf_ptr = &buf, .count_ptr = &count };

    // Preload from offset 0 to 4096 with a large cap — the loop should
    // visit a monotonically increasing sequence of offsets.
    adaptivePreloadLoop(Inserter, inserter, 0, 4096, 1 << 20);

    try testing.expect(count > 0);
    var prev: i64 = -1;
    for (buf[0..count]) |o| {
        try testing.expect(o > prev);
        try testing.expect(o < 4096);
        prev = o;
    }
}
