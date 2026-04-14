//! High LZ compressor public entry points. Port of
//! src/StreamLZ/Compression/High/Compressor.cs.
//!
//! The High codec dispatches by compression level:
//!   L1-L2  → greedy fast parser
//!   L3-L4  → lazy fast parser (1 / 2 lazy steps)
//!   L5+    → optimal DP parser
//!
//! Each level requires a specific hasher family:
//!   L1-L4  : `MatchHasher{1, 2x, 4, 4Dual}` (see parity step 25)
//!   L5+    : `MatchHasher16Dual` via `match_finder.findMatchesHashBased`
//!            pre-computes `ManagedMatchLenStorage` (step 26 + 27)
//!
//! This file currently contains the type-level wiring + the
//! `SetupEncoder` helper. The actual parsers land in subsequent
//! parity steps:
//!   - step 29 (F2): `fastCompress` (greedy + lazy)
//!   - step 30 (F4): `assembleCompressedOutput` (token assembly)
//!   - step 31 (F5): `CostModel` (UpdateStats, MakeCostModel, BitsFor*)
//!   - step 32 (F3): `optimal` (DP parser)

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const high_types = @import("high_types.zig");
const high_encoder = @import("high_encoder.zig");
const high_fast_parser = @import("high_fast_parser.zig");
const high_optimal_parser = @import("high_optimal_parser.zig");
const match_hasher = @import("match_hasher.zig");
const mls_mod = @import("managed_match_len_storage.zig");
const entropy_enc = @import("entropy_encoder.zig");
const cost_coeffs = @import("cost_coefficients.zig");

pub const EncodeFlags = enum(u32) {
    none = 0,
    /// C# `encodeFlags = 4`: the optimal parser signals that the
    /// caller wants the exported token array. Set for L5+.
    export_tokens = 4,
};

pub const HasherType = enum {
    /// `MatchHasher1` — High levels ≤ 2.
    hasher1,
    /// `MatchHasher2x` — High level 2.
    hasher2x,
    /// `MatchHasher4` — High level 3.
    hasher4,
    /// `MatchHasher4Dual` — High level 4.
    hasher4_dual,
    /// No hasher — L5+ uses `match_finder.findMatchesHashBased`
    /// which creates its own `MatchHasher16Dual` internally.
    none,
};

/// Level-table entry matching C# `Compressor.SetupEncoder`'s internal
/// lookup (`Compressor.cs:90-108`). Indexed by `level + 3`, so index 0
/// is level -3 and index 7 is level 4. Levels ≥ 5 use a different
/// hasher path (Optimal creates its own).
pub const LevelEntry = struct {
    /// Maximum hash bits when `copts.HashBits <= 0`. `null` = no cap
    /// (C# uses `int.MaxValue` sentinel).
    max_hash: ?u32,
    /// Entropy-option bits to CLEAR from the default 0xFF mask.
    entropy_mask: u32,
    /// Which hasher family to instantiate.
    hasher_type: HasherType,
};

/// Per-level setup table. Index = `level + 3`.
pub const level_table: [8]LevelEntry = .{
    // level -3 (idx 0)
    .{ .max_hash = 12, .entropy_mask = tans_multi_rle, .hasher_type = .hasher1 },
    // level -2 (idx 1)
    .{ .max_hash = 14, .entropy_mask = tans_multi_rle, .hasher_type = .hasher1 },
    // level -1 (idx 2)
    .{ .max_hash = 16, .entropy_mask = tans_multi_rle, .hasher_type = .hasher1 },
    // level 0 (idx 3)
    .{ .max_hash = 19, .entropy_mask = tans_multi_rle, .hasher_type = .hasher1 },
    // level 1 (idx 4)
    .{ .max_hash = 19, .entropy_mask = tans_multi_rle, .hasher_type = .hasher1 },
    // level 2 (idx 5)
    .{ .max_hash = null, .entropy_mask = tans_multi, .hasher_type = .hasher2x },
    // level 3 (idx 6)
    .{ .max_hash = null, .entropy_mask = tans_multi, .hasher_type = .hasher4 },
    // level 4 (idx 7)
    .{ .max_hash = null, .entropy_mask = tans_multi_adv, .hasher_type = .hasher4_dual },
};

/// Entropy option masks precomputed from the combinations C# lists
/// at `Compressor.cs:84-86`.
const tans_multi_rle: u32 = 0b1011010; // AllowTANS | AllowMultiArray | AllowRLE
const tans_multi: u32 = 0b0010010; // AllowTANS | AllowMultiArray
const tans_multi_adv: u32 = 0b1000010; // AllowTANS | AllowMultiArrayAdvanced

/// Resolved High-codec setup parameters. Computed by `setupEncoder`;
/// the actual hasher / match-finder is created by the caller.
pub const HighSetup = struct {
    level: i32,
    codec_id: u32,
    sub_chunk_size: usize,
    check_plain_huffman: bool,
    speed_tradeoff: f32,
    max_matches_to_consider: u32,
    compressor_file_id: u32,
    encode_flags: u32,
    entropy_options: u32,
    hasher_type: HasherType,
    hash_bits: u32,
    min_match_length: u32,
};

/// C# `StreamLZConstants.ScratchSize` and `ChunkSize` constants.
pub const sub_chunk_size: usize = 0x20000;

/// Port of C# `High.Compressor.SetupEncoder` (`Compressor.cs:51-135`).
/// Computes the level-dependent encoder parameters but DOES NOT
/// allocate the hasher — the caller creates the hasher based on
/// `setup.hasher_type` / `hash_bits` / `min_match_length`.
pub fn setupEncoder(
    level: i32,
    source_length: usize,
    hash_bits_in: u32,
    space_speed_tradeoff_bytes: i32,
    min_match_length: u32,
) HighSetup {
    // C# EntropyEncoder.GetHashBits(srcLen, max(level, 2), copts, 16, 20, 17, 24).
    const raw_bits = computeHashBits(source_length, @max(level, 2), 16, 20, 17, 24);
    var hash_bits: u32 = if (hash_bits_in > 0) hash_bits_in else raw_bits;

    // C# line 62: SpeedTradeoff = bytes * Factor1 * Factor2
    const speed_tradeoff: f32 =
        @as(f32, @floatFromInt(space_speed_tradeoff_bytes)) *
        cost_coeffs.speed_tradeoff_factor_1 *
        cost_coeffs.speed_tradeoff_factor_2;

    // Start with the full 0xFF mask, always clear MultiArrayAdvanced.
    var entropy_options: u32 = 0xFF & ~tans_multi_adv_bit;
    if (level >= 7) {
        entropy_options |= tans_multi_adv_bit;
    }

    const encode_flags: u32 = if (level >= 5) @intFromEnum(EncodeFlags.export_tokens) else 0;

    var hasher_type: HasherType = .none;

    if (level <= 4) {
        const table_index: usize = @intCast(std.math.clamp(level + 3, 0, 7));
        const entry = level_table[table_index];
        if (entry.max_hash) |max| {
            if (hash_bits_in == 0) hash_bits = @min(hash_bits, max);
        }
        entropy_options &= ~entry.entropy_mask;
        hasher_type = entry.hasher_type;
    }

    return .{
        .level = level,
        .codec_id = @intFromEnum(CodecId.high),
        .sub_chunk_size = sub_chunk_size,
        .check_plain_huffman = level >= 3,
        .speed_tradeoff = speed_tradeoff,
        .max_matches_to_consider = 4,
        .compressor_file_id = @intFromEnum(CodecId.high),
        .encode_flags = encode_flags,
        .entropy_options = entropy_options,
        .hasher_type = hasher_type,
        .hash_bits = hash_bits,
        .min_match_length = min_match_length,
    };
}

/// C# `CodecType`.
pub const CodecId = enum(u32) {
    high = 0,
    fast = 1,
    turbo = 2,
};

const tans_multi_adv_bit: u32 = 0b1000000; // bit 6 in the entropy option mask

/// Port of C# `EntropyEncoder.GetHashBits` (`EntropyEncoder.cs:222-232`).
/// Uses the `log2 + 1` version that the Fast codec also consumes.
fn computeHashBits(
    src_len: usize,
    level: i32,
    min_low_level_bits: u32,
    max_low_level_bits: u32,
    min_high_level_bits: u32,
    max_high_level_bits: u32,
) u32 {
    const capped: u32 = @intCast(@min(src_len, std.math.maxInt(u32)));
    const bits: u32 = std.math.log2_int(u32, @max(capped, 1)) + 1;
    const lo: u32 = if (level >= 3) min_high_level_bits else min_low_level_bits;
    const hi: u32 = if (level >= 5) max_high_level_bits else if (level >= 3) min_high_level_bits else max_low_level_bits;
    return std.math.clamp(bits, lo, hi);
}

// ────────────────────────────────────────────────────────────
//  doCompress — High-codec compression entry point
// ────────────────────────────────────────────────────────────

const MatchHasher1 = match_hasher.MatchHasher(1, false);
const MatchHasher2x = match_hasher.MatchHasher(2, false);
const MatchHasher4 = match_hasher.MatchHasher(4, false);
const MatchHasher4Dual = match_hasher.MatchHasher(4, true);

/// Tagged union holding an allocated hasher for a specific High level.
/// Levels 1-4 consume one of these; L5+ uses the shared MLS.
pub const HighHasher = union(enum) {
    none: void,
    h1: MatchHasher1,
    h2x: MatchHasher2x,
    h4: MatchHasher4,
    h4_dual: MatchHasher4Dual,

    pub fn deinit(self: *HighHasher) void {
        switch (self.*) {
            .none => {},
            .h1 => |*h| h.deinit(),
            .h2x => |*h| h.deinit(),
            .h4 => |*h| h.deinit(),
            .h4_dual => |*h| h.deinit(),
        }
        self.* = .{ .none = {} };
    }

    pub fn reset(self: *HighHasher) void {
        switch (self.*) {
            .none => {},
            .h1 => |*h| h.reset(),
            .h2x => |*h| h.reset(),
            .h4 => |*h| h.reset(),
            .h4_dual => |*h| h.reset(),
        }
    }
};

/// Allocates the hasher required by the High codec at the given codec
/// level. Returns `.none` for levels ≥ 5 (which use pre-computed MLS
/// instead). Caller owns `out.*` and must call `out.deinit`.
pub fn allocateHighHasher(
    allocator: std.mem.Allocator,
    setup: HighSetup,
) !HighHasher {
    if (setup.level >= 5) return .{ .none = {} };
    const bits: u6 = @intCast(setup.hash_bits);
    const mml: u32 = @max(setup.min_match_length, 4);
    return switch (setup.hasher_type) {
        .hasher1 => .{ .h1 = try MatchHasher1.init(allocator, bits, mml) },
        .hasher2x => .{ .h2x = try MatchHasher2x.init(allocator, bits, mml) },
        .hasher4 => .{ .h4 = try MatchHasher4.init(allocator, bits, mml) },
        .hasher4_dual => .{ .h4_dual = try MatchHasher4Dual.init(allocator, bits, mml) },
        .none => .{ .none = {} },
    };
}

/// Per-level lazy-step count, matching C# `High.Compressor.DoCompress`.
fn numLazyFor(level: i32) u32 {
    return switch (level) {
        1, 2 => 0,
        3 => 1,
        4 => 2,
        else => 0,
    };
}

/// Main High compression entry point. Port of C#
/// `High.Compressor.DoCompress` (`Compressor.cs:21-46`).
///
/// `mls` may be `null` for levels ≤ 4 (Fast parser uses the hasher);
/// levels ≥ 5 expect a pre-populated `ManagedMatchLenStorage`.
pub fn doCompress(
    ctx: *const high_encoder.HighEncoderContext,
    hasher: *HighHasher,
    mls: ?*const mls_mod.ManagedMatchLenStorage,
    src: [*]const u8,
    src_size: i32,
    dst: [*]u8,
    dst_end: [*]u8,
    start_pos: i32,
    chunk_type_out: *i32,
    cost_out: *f32,
) !usize {
    if (ctx.compression_level >= 5) {
        return high_optimal_parser.optimal(
            ctx,
            .{},
            mls,
            src,
            src_size,
            dst,
            dst_end,
            start_pos,
            chunk_type_out,
            cost_out,
        );
    }

    const num_lazy = numLazyFor(ctx.compression_level);
    const opts: high_fast_parser.FastParserOptions = .{};
    return switch (hasher.*) {
        .h1 => |*h| try high_fast_parser.compressFast(
            MatchHasher1,
            ctx,
            h,
            src,
            src_size,
            dst,
            dst_end,
            start_pos,
            num_lazy,
            opts,
            cost_out,
            chunk_type_out,
        ),
        .h2x => |*h| try high_fast_parser.compressFast(
            MatchHasher2x,
            ctx,
            h,
            src,
            src_size,
            dst,
            dst_end,
            start_pos,
            num_lazy,
            opts,
            cost_out,
            chunk_type_out,
        ),
        .h4 => |*h| try high_fast_parser.compressFast(
            MatchHasher4,
            ctx,
            h,
            src,
            src_size,
            dst,
            dst_end,
            start_pos,
            num_lazy,
            opts,
            cost_out,
            chunk_type_out,
        ),
        .h4_dual => |*h| try high_fast_parser.compressFast(
            MatchHasher4Dual,
            ctx,
            h,
            src,
            src_size,
            dst,
            dst_end,
            start_pos,
            num_lazy,
            opts,
            cost_out,
            chunk_type_out,
        ),
        .none => error.BailOut,
    };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "setupEncoder: level 1 uses hasher1 with max 19 bits" {
    const s = setupEncoder(1, 1024 * 1024, 0, 256, 0);
    try testing.expectEqual(HasherType.hasher1, s.hasher_type);
    try testing.expect(s.hash_bits <= 19);
    try testing.expectEqual(@as(u32, 0), s.encode_flags);
    try testing.expect(!s.check_plain_huffman);
}

test "setupEncoder: level 3 uses hasher4 + check_plain_huffman" {
    const s = setupEncoder(3, 4 * 1024 * 1024, 0, 256, 0);
    try testing.expectEqual(HasherType.hasher4, s.hasher_type);
    try testing.expect(s.check_plain_huffman);
}

test "setupEncoder: level 4 uses hasher4_dual" {
    const s = setupEncoder(4, 4 * 1024 * 1024, 0, 256, 0);
    try testing.expectEqual(HasherType.hasher4_dual, s.hasher_type);
    try testing.expect(s.check_plain_huffman);
}

test "setupEncoder: level 5 uses no hasher + export_tokens flag" {
    const s = setupEncoder(5, 4 * 1024 * 1024, 0, 256, 0);
    try testing.expectEqual(HasherType.none, s.hasher_type);
    try testing.expectEqual(@as(u32, @intFromEnum(EncodeFlags.export_tokens)), s.encode_flags);
}

test "setupEncoder: level 7+ re-enables MultiArrayAdvanced" {
    const s5 = setupEncoder(5, 1_000_000, 0, 256, 0);
    const s7 = setupEncoder(7, 1_000_000, 0, 256, 0);
    // Level 5 should have MultiArrayAdvanced CLEARED; level 7 should have it SET.
    try testing.expectEqual(@as(u32, 0), s5.entropy_options & tans_multi_adv_bit);
    try testing.expectEqual(tans_multi_adv_bit, s7.entropy_options & tans_multi_adv_bit);
}
