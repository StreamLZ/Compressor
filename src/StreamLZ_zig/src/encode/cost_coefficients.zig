//! Port of `src/StreamLZ/Compression/CostCoefficients.cs`.
//!
//! Empirically-tuned timing coefficients used by the cost model to decide
//! between LZ, memset, plain-Huffman, and raw-store encodings in marginal
//! cases. Default values come from the C# reference build's sweep on Intel
//! Arrow Lake-S (Ultra 9 285K). They do NOT affect the wire format or the
//! decompressor — only encoder decisions.
//!
//! We only expose the subset of coefficients the Fast encoder actually
//! consults: memset cost, speed-tradeoff factors, and the per-stream
//! decoding-time constants consumed via `cost_model.zig`.
//!
//! Exact numeric parity with C# is important — these are the thresholds
//! that decide whether a sub-chunk compresses or stores raw, and any
//! rounding drift here causes byte-level differences vs C# output.

/// Memset-encoding decode cost per source byte.
pub const memset_per_byte: f32 = 0.161208;

/// Memset-encoding decode cost base (per block).
pub const memset_base: f32 = 56.6145;

// ── Offset encoding timing (used by OffsetEncoder / step 17 — H8/H9) ──
// All values are the C# `CostCoefficients.Current.*` defaults from
// `CostCoefficients.cs:21-30`. Exact numeric parity is required because
// these coefficients drive the LZ-vs-entropy cost decisions that pick
// the final encoding type.

/// Type-0 (legacy) offset decode: per-item cost.
pub const offset_type0_per_item: f32 = 8.85935;
/// Type-0 (legacy) offset decode: base cost.
pub const offset_type0_base: f32 = 44.0563;

/// Type-1 (modular) offset decode: per-item cost.
pub const offset_type1_per_item: f32 = 6.75172;
/// Type-1 (modular) offset decode: base cost.
pub const offset_type1_base: f32 = 76.0104;

/// Modular-coded offset overhead: per-item cost.
pub const offset_modular_per_item: f32 = 0.978096;
/// Modular-coded offset overhead: base cost.
pub const offset_modular_base: f32 = 52.0707;

/// Single-Huffman decode overhead base.
pub const single_huffman_base: f32 = 2149.44;
/// Single-Huffman decode overhead: per-item.
pub const single_huffman_per_item: f32 = 3.12304;
/// Single-Huffman decode overhead: per-symbol.
pub const single_huffman_per_symbol: f32 = 25.279;

/// Scaling applied to `CompressOptions.SpaceSpeedTradeoffBytes` in
/// `Fast.Compressor.SetupEncoder` — `1 / 256` so the default `256` yields
/// a multiplicative factor of 1.
pub const speed_tradeoff_scale: f32 = 1.0 / 256.0;

/// Additional multiplier applied to the speed tradeoff in Fast RAW modes
/// (engine levels ≤ -1 — user L1 and L2).
pub const raw_speed_factor: f32 = 0.14;

/// Additional multiplier applied to the speed tradeoff in Fast ENTROPY
/// modes (engine levels ≥ 1 — user L3, L4, L5).
pub const entropy_speed_factor: f32 = 0.050000001;

/// Default `CompressOptions.SpaceSpeedTradeoffBytes`. Higher values bias
/// toward better compression ratio at the cost of decode speed.
pub const default_space_speed_tradeoff_bytes: i32 = 256;

/// Computes the `coder.SpeedTradeoff` scalar the way C#
/// `Fast.Compressor.SetupEncoder` does.
pub fn speedTradeoffFor(space_speed_tradeoff_bytes: i32, use_literal_entropy_coding: bool) f32 {
    const factor = if (use_literal_entropy_coding) entropy_speed_factor else raw_speed_factor;
    return @as(f32, @floatFromInt(space_speed_tradeoff_bytes)) * speed_tradeoff_scale * factor;
}

const testing = @import("std").testing;

test "speedTradeoffFor raw default" {
    // (256 * 1/256) * 0.14 = 0.14
    try testing.expectApproxEqAbs(@as(f32, 0.14), speedTradeoffFor(default_space_speed_tradeoff_bytes, false), 1e-6);
}

test "speedTradeoffFor entropy default" {
    // (256 * 1/256) * 0.050000001 ≈ 0.05
    try testing.expectApproxEqAbs(@as(f32, 0.05), speedTradeoffFor(default_space_speed_tradeoff_bytes, true), 1e-6);
}
