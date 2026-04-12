//! Port of src/StreamLZ/Common/StreamLzConstants.cs — centralized magic numbers
//! for the StreamLZ codec family. See the C# file for rationale; keep in sync.

// ────────────────────────────────────────────────────────────
//  Chunk and buffer sizing
// ────────────────────────────────────────────────────────────

pub const chunk_size: usize = 0x40000; // 256 KB
pub const chunk_size_bits: u6 = 18;
pub const chunk_header_size: usize = 4;
pub const chunk_size_mask: u32 = chunk_size - 1; // 0x3FFFF
pub const chunk_type_shift: u6 = chunk_size_bits;
pub const chunk_type_memset: u32 = 1 << chunk_type_shift;

pub const bt4_max_read_size: usize = 8 * 1024 * 1024;
pub const compress_buffer_padding: usize = 16;

pub const sub_chunk_type_shift: u6 = 19;
pub const chunk_header_compressed_flag: u32 = 0x800000;

pub const scratch_size: usize = 0x6C000; // 442,368
pub const entropy_scratch_size: usize = 0xD000; // 53,248

pub fn calculateScratchSize(dst_count: usize) usize {
    const needed = 3 * dst_count + 32 + entropy_scratch_size;
    return if (needed < scratch_size) needed else scratch_size;
}

pub const initial_recent_offset: u32 = 8;
pub const max_dictionary_size: usize = 0x40000000; // 1 GB

// ────────────────────────────────────────────────────────────
//  Offset encoding constants
// ────────────────────────────────────────────────────────────

pub const offset_bias_constant: u32 = 760;
pub const high_offset_threshold: u32 = 16_776_456;
pub const low_offset_encoding_limit: u32 = 16_710_912;
pub const high_offset_marker: u8 = 0xF0;
pub const high_offset_cost_adjust: u32 = 0xE0;

// ────────────────────────────────────────────────────────────
//  Huffman lookup table sizing
// ────────────────────────────────────────────────────────────

pub const huffman_lut_bits: u6 = 11;
pub const huffman_lut_size: usize = 1 << huffman_lut_bits; // 2048
pub const huffman_lut_mask: u32 = @intCast(huffman_lut_size - 1);
pub const huffman_bitpos_clamp_mask: u32 = 0x18;
pub const huffman_lut_overflow: usize = 16;

// ────────────────────────────────────────────────────────────
//  Entropy block-size encoding masks
// ────────────────────────────────────────────────────────────

pub const block_size_mask_10: u32 = 0x3FF;
pub const block_size_mask_12: u32 = 0xFFF;
pub const rle_short_command_threshold: u32 = 0x2F;

// ────────────────────────────────────────────────────────────
//  Symbol alphabet
// ────────────────────────────────────────────────────────────

pub const alphabet_size: usize = 256;

// ────────────────────────────────────────────────────────────
//  Match finder / hash table
// ────────────────────────────────────────────────────────────

pub const hash_position_mask: u32 = 0x01FFFFFF;
pub const hash_position_bits: u6 = 25;
pub const hash_tag_mask: u32 = 0xFE000000;
pub const fast_large_offset_threshold: u32 = 0xC00000;

// ────────────────────────────────────────────────────────────
//  Match distance thresholds
// ────────────────────────────────────────────────────────────

pub const offset_threshold_12kb: u32 = 0x3000;
pub const offset_threshold_96kb: u32 = 0x18000;
pub const offset_threshold_768kb: u32 = 0xC0000;
pub const offset_threshold_1_5mb: u32 = 0x180000;
pub const offset_threshold_3mb: u32 = 0x300000;

// ────────────────────────────────────────────────────────────
//  Cost model
// ────────────────────────────────────────────────────────────

pub const invalid_cost: f32 = @import("std").math.floatMax(f32) / 2;
pub const cost_scale_factor: i32 = 32;

// ────────────────────────────────────────────────────────────
//  Entropy table sizing
// ────────────────────────────────────────────────────────────

pub const log2_lookup_table_size: usize = 4097;

// ────────────────────────────────────────────────────────────
//  Hashing
// ────────────────────────────────────────────────────────────

pub const fibonacci_hash_multiplier: u64 = 0x9E3779B97F4A7C15;

// ────────────────────────────────────────────────────────────
//  Threading
// ────────────────────────────────────────────────────────────

pub const sc_group_size: usize = 4;
pub const per_thread_memory_estimate: usize = 40 * 1024 * 1024;

// ────────────────────────────────────────────────────────────
//  Debug sanity checks (compile-time)
// ────────────────────────────────────────────────────────────

comptime {
    const std = @import("std");
    std.debug.assert(huffman_lut_size == (@as(usize, 1) << huffman_lut_bits));
    std.debug.assert(high_offset_threshold == (@as(u32, 1) << 24) - offset_bias_constant);
    std.debug.assert(high_offset_cost_adjust == high_offset_marker - 16);
}
