//! High-level entropy encoder wrapper.
//! Used by: Fast and High codecs
//!
//! Two primary paths:
//!
//!   * `encodeArrayU8Memcpy` — raw memcpy with a 3-byte BE24 chunk type 0
//!     header. Always valid, always falls back to this.
//!   * `encodeArrayU8` — try tANS (if allowed), pick the cheaper of
//!     {tANS, memcpy}. Writes either a 5-byte non-compact header (tANS)
//!     or the 3-byte memcpy header.
//!
//! The returned byte count includes the chunk header. Negative / error
//! returns mean "doesn't fit" (caller should fall back elsewhere).

const std = @import("std");
const hist_mod = @import("ByteHistogram.zig");
const tans = @import("tans_encoder.zig");

const ByteHistogram = hist_mod.ByteHistogram;

/// Entropy option bit flags.
pub const EntropyOptions = packed struct(u8) {
    allow_tans: bool = false,
    allow_rle_entropy: bool = false,
    allow_double_huffman: bool = false,
    allow_rle: bool = false,
    allow_multi_array: bool = false,
    supports_new_huffman: bool = false,
    allow_multi_array_advanced: bool = false,
    supports_short_memset: bool = false,

    pub fn raw(self: EntropyOptions) u8 {
        return @bitCast(self);
    }
};

pub const EncodeError = error{
    DestinationTooSmall,
    EntropyNotBeneficial,
} || std.mem.Allocator.Error;

/// Write a 3-byte BE24 chunk type 0 memcpy header + the raw bytes.
/// Returns total bytes written.
pub fn encodeArrayU8Memcpy(dst: []u8, src: []const u8) EncodeError!usize {
    if (src.len + 3 > dst.len) return error.DestinationTooSmall;
    dst[0] = @intCast((src.len >> 16) & 0xFF);
    dst[1] = @intCast((src.len >> 8) & 0xFF);
    dst[2] = @intCast(src.len & 0xFF);
    @memcpy(dst[3 .. 3 + src.len], src);
    return src.len + 3;
}

/// Write a 5-byte non-compact chunk header. `decompressed_size` and
/// `compressed_size` must each fit in 18 bits; `chunk_type` in 4 bits.
fn writeNonCompactChunkHeader(dst: []u8, chunk_type: u8, compressed_size: u32, decompressed_size: u32) void {
    const dst_minus_1: u32 = decompressed_size - 1;
    dst[0] = @intCast((@as(u32, chunk_type) << 4) | ((dst_minus_1 >> 14) & 0xF));
    const bits: u32 = compressed_size | ((dst_minus_1 & 0x3FFF) << 18);
    dst[1] = @intCast((bits >> 24) & 0xFF);
    dst[2] = @intCast((bits >> 16) & 0xFF);
    dst[3] = @intCast((bits >> 8) & 0xFF);
    dst[4] = @intCast(bits & 0xFF);
}

/// Convert a fresh 5-byte non-compact header (or Type-0 3-byte memcpy
/// header) into a compact variant when possible. Decrements `cost_ptr`
/// by 1 (memcpy shrink) or 2 (compressed shrink) when the header compacts.
/// Returns the new total byte count.
fn makeCompactChunkHdr(dst: []u8, total_n: usize, cost_ptr: ?*f32) usize {
    const chunk_type: u32 = (dst[0] >> 4) & 0x7;
    if (chunk_type == 0) {
        // Memcpy: try a compact 2-byte header.
        const src_size: u32 = (@as(u32, dst[0]) << 16) | (@as(u32, dst[1]) << 8) | @as(u32, dst[2]);
        if (src_size <= 0xFFF) {
            const hdr_val: u32 = 0x8000 | src_size;
            const h0: u8 = @intCast((hdr_val >> 8) & 0xFF);
            const h1: u8 = @intCast(hdr_val & 0xFF);
            // Shift payload 1 byte left (from dst[3..] to dst[2..]).
            std.mem.copyForwards(u8, dst[2 .. 2 + src_size], dst[3 .. 3 + src_size]);
            dst[0] = h0;
            dst[1] = h1;
            if (cost_ptr) |c| c.* -= 1;
            return total_n - 1;
        }
        return total_n;
    }

    // Non-memcpy chunk: try a compact 3-byte header.
    const bits5: u32 = (@as(u32, dst[1]) << 24) |
        (@as(u32, dst[2]) << 16) |
        (@as(u32, dst[3]) << 8) |
        @as(u32, dst[4]);
    const src_size: u32 = bits5 & 0x3FFFF;
    const dst_size: u32 = (((bits5 >> 18) | (@as(u32, dst[0]) << 14)) & 0x3FFFF) + 1;
    if (dst_size <= src_size) return total_n;
    const delta: u32 = dst_size - src_size - 1;
    if (src_size <= 0x3FF and delta <= 0x3FF) {
        const bits3: u32 = src_size |
            (delta << 10) |
            (chunk_type << 20) |
            (@as(u32, 1) << 23);
        const b0: u8 = @intCast((bits3 >> 16) & 0xFF);
        const b1: u8 = @intCast((bits3 >> 8) & 0xFF);
        const b2: u8 = @intCast(bits3 & 0xFF);
        // Shift payload 2 bytes left (from dst[5..] to dst[3..]).
        std.mem.copyForwards(u8, dst[3 .. 3 + src_size], dst[5 .. 5 + src_size]);
        dst[0] = b0;
        dst[1] = b1;
        dst[2] = b2;
        if (cost_ptr) |c| c.* -= 2;
        return total_n - 2;
    }
    return total_n;
}

/// Encode a byte array picking the cheaper of tANS and memcpy. Writes
/// the chunk header (non-compact 5 bytes for compressed, 3 bytes for
/// memcpy). Returns the total byte count written.
///
/// `speed_tradeoff`
/// biases tANS vs memcpy cost comparison, `cost_out` receives the
/// rate-distortion cost of the chosen encoding (used by callers to
/// pick between multiple candidates), `level` gates level-dependent
/// algorithm choices. `histo_out` optionally receives the computed
/// histogram so callers can reuse it.
pub fn encodeArrayU8(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    options: EntropyOptions,
    speed_tradeoff: f32,
    cost_out: ?*f32,
    level: u32,
    histo_out: ?*ByteHistogram,
) EncodeError!usize {
    if (src.len <= 32) {
        if (histo_out) |h| h.countBytes(src);
        if (cost_out) |c| c.* = @floatFromInt(src.len + 3);
        return encodeArrayU8Memcpy(dst, src);
    }

    var histo: ByteHistogram = .{};
    histo.countBytes(src);
    if (histo_out) |h| h.* = histo;

    return encodeArrayU8CoreWithHisto(allocator, dst, src, &histo, options, speed_tradeoff, cost_out, level);
}

/// Core encode with pre-computed histogram. Takes the histogram by
/// value (copies internally so the caller's copy is untouched by any
/// in-place adjustments the encoders make).
pub fn encodeArrayU8WithHisto(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    histo: ByteHistogram,
    options: EntropyOptions,
    speed_tradeoff: f32,
    cost_out: ?*f32,
    level: u32,
) EncodeError!usize {
    if (src.len <= 32) {
        if (cost_out) |c| c.* = @floatFromInt(src.len + 3);
        return encodeArrayU8Memcpy(dst, src);
    }
    var histo_copy = histo;
    return encodeArrayU8CoreWithHisto(allocator, dst, src, &histo_copy, options, speed_tradeoff, cost_out, level);
}

fn encodeArrayU8CoreWithHisto(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    histo: *ByteHistogram,
    options: EntropyOptions,
    speed_tradeoff: f32,
    cost_out: ?*f32,
    level: u32,
) EncodeError!usize {
    _ = level; // currently unused; reserved for Huffman / multi-array paths

    const memcpy_cost: f32 = @floatFromInt(src.len + 3);

    // Try tANS if allowed.
    if (options.allow_tans and dst.len > 5 + 8) {
        var tans_cost: f32 = memcpy_cost;
        const tans_n = tans.encodeArrayU8Tans(allocator, dst[5..], src, histo, speed_tradeoff, &tans_cost) catch |err| switch (err) {
            error.TansNotBeneficial, error.TooFewSymbols, error.DestinationTooSmall => {
                if (cost_out) |c| c.* = memcpy_cost;
                return encodeArrayU8Memcpy(dst, src);
            },
            error.BadParameters => return error.DestinationTooSmall,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (tans_n > 0 and tans_n < src.len and tans_cost < memcpy_cost) {
            writeNonCompactChunkHeader(dst, 1, @intCast(tans_n), @intCast(src.len));
            if (cost_out) |c| c.* = tans_cost;
            return 5 + tans_n;
        }
    }
    // Fall back to memcpy.
    if (cost_out) |c| c.* = memcpy_cost;
    return encodeArrayU8Memcpy(dst, src);
}

/// Same as `encodeArrayU8` but converts the result to a compact
/// chunk header where possible (saving 1–2 bytes). When the header
/// shrinks, `cost_out` is decremented to reflect the smaller output.
pub fn encodeArrayU8CompactHeader(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    options: EntropyOptions,
    speed_tradeoff: f32,
    cost_out: ?*f32,
    level: u32,
    histo_out: ?*ByteHistogram,
) EncodeError!usize {
    const n = try encodeArrayU8(allocator, dst, src, options, speed_tradeoff, cost_out, level, histo_out);
    return makeCompactChunkHdr(dst, n, cost_out);
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;
const entropy_dec = @import("../../decode/entropy/entropy_decoder.zig");

test "encodeArrayU8Memcpy + decoder roundtrip" {
    const src = "Hello, world! This is a small string.";
    var dst: [128]u8 = @splat(0);
    const n = try encodeArrayU8Memcpy(&dst, src);
    try testing.expect(n == src.len + 3);

    var decoded: [128]u8 = @splat(0);
    var scratch: [4096]u8 = undefined;
    const res = try entropy_dec.highDecodeBytes(&decoded, decoded.len, dst[0..n], false, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(src.len, res.decoded_size);
    try testing.expectEqualSlices(u8, src, res.out_ptr[0..res.decoded_size]);
}

test "encodeArrayU8 with tANS picks compressed path for compressible data" {
    const pattern = "The quick brown fox jumps over the lazy dog. ";
    var src: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var dst: [2048]u8 = @splat(0);
    var cost: f32 = std.math.inf(f32);
    // Use the High-codec speed tradeoff so tANS cost pricing matches
    // production call sites (the default for L9). At `speed_tradeoff = 1.0`
    // the tANS speed-penalty would exceed the memcpy budget and force
    // the encoder into memcpy fallback.
    const cost_coeffs = @import("../cost_coefficients.zig");
    const real_speed_tradeoff = cost_coeffs.speedTradeoffForHigh(cost_coeffs.default_space_speed_tradeoff_bytes);
    const n = try encodeArrayU8(
        testing.allocator,
        &dst,
        &src,
        .{ .allow_tans = true },
        real_speed_tradeoff,
        &cost,
        0,
        null,
    );
    try testing.expect(n < src.len);
    try testing.expect(cost < @as(f32, @floatFromInt(src.len + 3)));

    // Check that the header is the 5-byte non-compact form with chunk type 1.
    try testing.expect((dst[0] >> 4) & 0x7 == 1);

    // Decode back.
    var decoded: [2048]u8 = @splat(0);
    var scratch: [65536]u8 = undefined;
    const res = try entropy_dec.highDecodeBytes(&decoded, decoded.len, dst[0..n], false, &scratch, scratch[scratch.len..].ptr);
    try testing.expectEqual(src.len, res.decoded_size);
    try testing.expectEqualSlices(u8, &src, res.out_ptr[0..src.len]);
}

test "encodeArrayU8 without allow_tans falls back to memcpy" {
    const pattern = "aaaaaaaaaaaaaaaa";
    var src: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var dst: [2048]u8 = @splat(0);
    var cost: f32 = 0;
    const n = try encodeArrayU8(
        testing.allocator,
        &dst,
        &src,
        .{},
        1.0,
        &cost,
        0,
        null,
    );
    try testing.expectEqual(src.len + 3, n); // 3-byte BE24 memcpy header
    try testing.expectEqual(@as(u8, 0), (dst[0] >> 4) & 0x7);
    // Memcpy cost matches the encoded byte count.
    try testing.expectEqual(@as(f32, @floatFromInt(src.len + 3)), cost);
}

test "encodeArrayU8CompactHeader shrinks memcpy header for small input" {
    const src = "small";
    var dst: [128]u8 = @splat(0);
    var cost: f32 = 0;
    const n = try encodeArrayU8CompactHeader(
        testing.allocator,
        &dst,
        src,
        .{},
        1.0,
        &cost,
        0,
        null,
    );
    // 5-byte string -> compact memcpy header = 2 bytes + 5 payload = 7 bytes
    try testing.expectEqual(@as(usize, 2 + src.len), n);
    // High bit of first byte set for compact memcpy
    try testing.expect((dst[0] & 0x80) != 0);
    // Cost should drop by 1 due to the compact memcpy shrink:
    //   initial cost = src.len + 3 = 8, after shrink = 7.
    try testing.expectEqual(@as(f32, 7), cost);
}
