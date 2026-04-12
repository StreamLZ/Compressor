//! Port of src/StreamLZ/Compression/Fast/FastToken.cs FastConstants class.
//! Shared constants and small helpers for the Fast encoder.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");

/// Minimum source length below which compression is skipped (returned as-is).
pub const min_source_length: usize = 128;

/// Initial literal bytes copied verbatim at the start of the very first chunk.
pub const initial_copy_bytes: usize = 8;

/// Maximum size of a single parser block (the two 64 KB halves of a sub-chunk).
pub const block1_max_size: usize = 0x10000;

/// Sub-chunk size: 128 KB. Each outer 256 KB chunk contains up to 2 sub-chunks.
pub const sub_chunk_size: usize = 0x20000;

/// Threshold above which 32-bit offsets use the 4-byte encoding.
pub const large_offset_threshold: u32 = lz_constants.fast_large_offset_threshold;

/// Marker in the off16 count field indicating entropy-coded offsets.
pub const entropy_coded_16_marker: u16 = 0xFFFF;

/// Maximum match length that fits in a simple token (before falling back to
/// the chained `0x80 + 8*matchLen` continuation byte trick).
pub const near_offset_max_match_length: usize = 90;

/// Maximum length value that fits in a single byte of the length stream.
pub const max_single_byte_length_value: u32 = 251;

/// Base value subtracted in the extended (3-byte) length encoding.
pub const extended_length_base: u32 = 252;

/// Mask for the low 2 bits of length in extended encoding.
pub const extended_length_mask: u32 = 3;

/// Fibonacci hash multiplier (64-bit golden ratio).
pub const fibonacci_hash_multiplier: u64 = lz_constants.fibonacci_hash_multiplier;

/// Chunk type values written to the 3-byte sub-chunk header.
/// `(chunk_type << 19) | compressed_size | chunk_header_compressed_flag`.
pub const ChunkType = enum(u32) {
    /// Delta-literal mode. Encoder emits `literal - byte_at_recent_offset` to a
    /// separate stream; decoder uses `copy64Add`. Used by L3+ entropy mode.
    delta = 0,
    /// Raw literal mode. Encoder writes literals verbatim. Used by L1/L2 and
    /// selected by L3+ when delta literals compress worse than raw.
    raw = 1,
};

/// The bit offsets / flags used in the 3-byte sub-chunk header.
pub const sub_chunk_type_shift: u5 = lz_constants.sub_chunk_type_shift;
pub const chunk_header_compressed_flag: u32 = lz_constants.chunk_header_compressed_flag;

// ────────────────────────────────────────────────────────────
//  Level mapping
// ────────────────────────────────────────────────────────────

/// Description of an internal (engine) compression level after user-level
/// remapping. See C# Fast.Compressor.MapLevel.
pub const InternalLevel = struct {
    engine_level: i32,
    use_entropy_coding: bool,
};

/// Maps a user-facing compression level (1..5 for this phase) to the internal
/// engine parameters consumed by the parser/encoder.
pub fn mapLevel(user_level: u8) InternalLevel {
    return switch (user_level) {
        0, 1 => .{ .engine_level = -2, .use_entropy_coding = false },
        2 => .{ .engine_level = -1, .use_entropy_coding = false },
        3 => .{ .engine_level = 1, .use_entropy_coding = true },
        4 => .{ .engine_level = 3, .use_entropy_coding = true },
        5 => .{ .engine_level = 2, .use_entropy_coding = true },
        // Levels >=6 are routed through the High codec in C#; Phase 9 doesn't handle them.
        else => .{ .engine_level = 2, .use_entropy_coding = true },
    };
}

// ────────────────────────────────────────────────────────────
//  Minimum match length table
// ────────────────────────────────────────────────────────────

/// Builds the minimum-match-length table indexed by `31 - log2(offset)`.
/// Direct port of Matcher.BuildMinimumMatchLengthTable (C#).
///
///   indexes  0..9   offsets > 4 MB   → 32 bytes (effectively disabled)
///   indexes 10..11  offsets 1-4 MB   → 2*long_offset_threshold - 6
///   indexes 12..15  offsets 64K-1MB  → long_offset_threshold
///   indexes 16..31  offsets < 64 KB  → minimum_match_length (4)
pub fn buildMinimumMatchLengthTable(
    table: *[32]u32,
    minimum_match_length: u32,
    long_offset_threshold: u32,
) void {
    var i: usize = 0;
    while (i < 10) : (i += 1) table[i] = 32;
    table[10] = long_offset_threshold * 2 - 6;
    table[11] = long_offset_threshold * 2 - 6;
    table[12] = long_offset_threshold;
    table[13] = long_offset_threshold;
    table[14] = long_offset_threshold;
    table[15] = long_offset_threshold;
    i = 16;
    while (i < 32) : (i += 1) table[i] = minimum_match_length;
}

// ────────────────────────────────────────────────────────────
//  Helpers
// ────────────────────────────────────────────────────────────

/// `value mod 7` for values > 7, else `value` unchanged. Used to decide how
/// many literal bytes fit in a single short token.
pub inline fn literalRunSlotCount(value: u32) u32 {
    return if (value > 7) (value - 1) % 7 + 1 else value;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "mapLevel matches C# Fast.Compressor.MapLevel" {
    try testing.expectEqual(@as(i32, -2), mapLevel(1).engine_level);
    try testing.expect(!mapLevel(1).use_entropy_coding);
    try testing.expectEqual(@as(i32, -1), mapLevel(2).engine_level);
    try testing.expect(!mapLevel(2).use_entropy_coding);
    try testing.expectEqual(@as(i32, 1), mapLevel(3).engine_level);
    try testing.expect(mapLevel(3).use_entropy_coding);
    try testing.expectEqual(@as(i32, 3), mapLevel(4).engine_level);
    try testing.expectEqual(@as(i32, 2), mapLevel(5).engine_level);
}

test "buildMinimumMatchLengthTable — raw mode threshold 14" {
    var table: [32]u32 = undefined;
    buildMinimumMatchLengthTable(&table, 4, 14);
    // indexes 0..9: 32
    for (0..10) |i| try testing.expectEqual(@as(u32, 32), table[i]);
    // 10..11: 2*14 - 6 = 22
    try testing.expectEqual(@as(u32, 22), table[10]);
    try testing.expectEqual(@as(u32, 22), table[11]);
    // 12..15: 14
    try testing.expectEqual(@as(u32, 14), table[12]);
    try testing.expectEqual(@as(u32, 14), table[15]);
    // 16..31: 4
    try testing.expectEqual(@as(u32, 4), table[16]);
    try testing.expectEqual(@as(u32, 4), table[31]);
}

test "literalRunSlotCount" {
    try testing.expectEqual(@as(u32, 0), literalRunSlotCount(0));
    try testing.expectEqual(@as(u32, 7), literalRunSlotCount(7));
    try testing.expectEqual(@as(u32, 1), literalRunSlotCount(8));
    try testing.expectEqual(@as(u32, 7), literalRunSlotCount(14));
    try testing.expectEqual(@as(u32, 1), literalRunSlotCount(15));
}
