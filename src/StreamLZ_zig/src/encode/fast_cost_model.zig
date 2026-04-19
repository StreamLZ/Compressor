//! Platform cost
//! Used by: Fast codec (L1-L5)
//! combination and decompression-time estimates used by the Fast
//! compressor's rate-distortion decisions.
//!
//! The four per-platform coefficient sets are empirically tuned
//! against 4 hardware targets; when `platforms = 0` (the default
//! used by the Fast path) we compute the simple average
//! `(a + b + c + d) * 0.25`.
//!
//! These estimates feed the "lzCost vs memsetCost" decision in
//! `streamlz_encoder.zig`. Correctness is mandatory — a single
//! rounding difference here flips whether a sub-chunk stores raw or
//! compressed, producing byte-level output drift.

const std = @import("std");

/// Combine four platform-specific cost values. `platforms == 0` → simple
/// average (the default Fast path).
pub inline fn combinePlatformCosts(platforms: u32, a: f32, b: f32, c: f32, d: f32) f32 {
    if ((platforms & 0xf) == 0) return (a + b + c + d) * 0.25;
    var sum: f32 = 0;
    var n: u32 = 0;
    if ((platforms & 1) != 0) {
        sum += c * 0.762;
        n += 1;
    }
    if ((platforms & 2) != 0) {
        sum += a * 1.130;
        n += 1;
    }
    if ((platforms & 4) != 0) {
        sum += d * 1.310;
        n += 1;
    }
    if ((platforms & 8) != 0) {
        sum += b * 0.961;
        n += 1;
    }
    return sum / @as(f32, @floatFromInt(n));
}

pub inline fn combinePlatformCostsScaled(
    platforms: u32,
    value: f32,
    a: f32,
    b: f32,
    c: f32,
    d: f32,
) f32 {
    return combinePlatformCosts(platforms, value * a, value * b, value * c, value * d);
}

pub inline fn combinePlatformCostsWithBias(
    platforms: u32,
    value: f32,
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    bias_a: f32,
    bias_b: f32,
    bias_c: f32,
    bias_d: f32,
) f32 {
    return combinePlatformCosts(
        platforms,
        value * a + bias_a,
        value * b + bias_b,
        value * c + bias_c,
        value * d + bias_d,
    );
}

// ────────────────────────────────────────────────────────────
//  Decompression time estimates
// ────────────────────────────────────────────────────────────

/// Offset16 stream decode time.
pub fn getDecodingTimeOffset16(platforms: u32, count: i32) f32 {
    const v: f32 = @floatFromInt(count);
    return combinePlatformCostsWithBias(
        platforms,
        v,
        0.270,
        0.428,
        0.550,
        0.213,
        24.0,
        53.0,
        62.0,
        33.0,
    );
}

/// Offset32 stream decode time.
pub fn getDecodingTimeOffset32(platforms: u32, count: i32) f32 {
    const v: f32 = @floatFromInt(count);
    return combinePlatformCostsWithBias(
        platforms,
        v,
        1.285,
        3.369,
        2.446,
        1.032,
        56.010,
        33.347,
        133.394,
        67.640,
    );
}

/// Entropy-coded (literal + token entropy) decode time.
pub fn getDecodingTimeEntropyCoded(
    platforms: u32,
    length: i32,
    token_count: i32,
    complex_token_count: i32,
) f32 {
    const l: f32 = @floatFromInt(length);
    const t: f32 = @floatFromInt(token_count);
    const ct: f32 = @floatFromInt(complex_token_count);
    return combinePlatformCosts(
        platforms,
        200.0 + l * 0.363 + t * 5.393 + ct * 29.655,
        200.0 + l * 0.429 + t * 6.977 + ct * 49.739,
        200.0 + l * 0.538 + t * 8.676 + ct * 69.864,
        200.0 + l * 0.255 + t * 5.364 + ct * 30.818,
    );
}

/// Raw-coded (memcpy literals + raw tokens) decode time.
pub fn getDecodingTimeRawCoded(
    platforms: u32,
    length: i32,
    token_count: i32,
    complex_token_count: i32,
    literal_count: i32,
) f32 {
    const l: f32 = @floatFromInt(length);
    const t: f32 = @floatFromInt(token_count);
    const ct: f32 = @floatFromInt(complex_token_count);
    const lit: f32 = @floatFromInt(literal_count);
    return combinePlatformCosts(
        platforms,
        200.0 + l * 0.371 + t * 5.259 + ct * 25.474 + lit * 0.131,
        200.0 + l * 0.414 + t * 6.678 + ct * 62.007 + lit * 0.065,
        200.0 + l * 0.562 + t * 8.190 + ct * 75.523 + lit * 0.008,
        200.0 + l * 0.272 + t * 5.018 + ct * 29.297 + lit * 0.070,
    );
}

const testing = std.testing;

test "combinePlatformCosts default (platforms=0) is simple average" {
    try testing.expectApproxEqAbs(@as(f32, 2.5), combinePlatformCosts(0, 1, 2, 3, 4), 1e-6);
}

test "getDecodingTimeOffset16 averages bias terms" {
    // count=0 → just averaged biases: (24+53+62+33)/4 = 43
    try testing.expectApproxEqAbs(@as(f32, 43.0), getDecodingTimeOffset16(0, 0), 1e-3);
}

test "getDecodingTimeRawCoded sanity at length=0,counts=0" {
    // Each platform contributes 200, average = 200
    try testing.expectApproxEqAbs(@as(f32, 200.0), getDecodingTimeRawCoded(0, 0, 0, 0, 0), 1e-3);
}
