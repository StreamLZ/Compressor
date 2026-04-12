//! Port of src/StreamLZ/Common/BitReader.cs
//!
//! Bit-level reader with a 32-bit accumulator. Consumes bits MSB-first.
//! Supports forward and backward refill so the same reader works on
//! entropy streams that are laid out in either direction.
//!
//! Invariant: after any refill, `bit_pos <= 0`, which guarantees at
//! least 24 valid bits for consumption without another refill.

const std = @import("std");
const constants = @import("../format/streamlz_constants.zig");

pub const BitReader = struct {
    /// Current byte-stream pointer. Forward: points at the next byte to read.
    /// Backward: points just above the next byte to read (refill does `--p`).
    p: [*]const u8,
    /// Forward: one-past-last byte. Backward: lowest valid byte address.
    p_end: [*]const u8,
    /// 32-bit bit buffer. Consumed bits are on the MSB side.
    bits: u32,
    /// Bit position of the next byte to land in `bits`.
    /// When ≤ 0 the buffer holds ≥24 valid bits.
    bit_pos: i32,

    /// Initialises a reader over `src` in forward mode.
    pub fn initForward(src: []const u8) BitReader {
        return .{
            .p = src.ptr,
            .p_end = src.ptr + src.len,
            .bits = 0,
            .bit_pos = 24,
        };
    }

    /// Initialises a reader in backward mode. The first read consumes
    /// `src[src.len - 1]`; subsequent reads walk backwards to `src[0]`.
    pub fn initBackward(src: []const u8) BitReader {
        return .{
            .p = src.ptr + src.len,
            .p_end = src.ptr,
            .bits = 0,
            .bit_pos = 24,
        };
    }

    pub inline fn refill(self: *BitReader) void {
        std.debug.assert(self.bit_pos <= 24);
        while (self.bit_pos > 0) {
            if (@intFromPtr(self.p) >= @intFromPtr(self.p_end)) break;
            const byte: u32 = self.p[0];
            self.bits |= byte << @intCast(self.bit_pos);
            self.bit_pos -= 8;
            self.p += 1;
        }
    }

    pub inline fn refillBackwards(self: *BitReader) void {
        std.debug.assert(self.bit_pos <= 24);
        while (self.bit_pos > 0) {
            if (@intFromPtr(self.p) <= @intFromPtr(self.p_end)) break;
            self.p -= 1;
            const byte: u32 = self.p[0];
            self.bits |= byte << @intCast(self.bit_pos);
            self.bit_pos -= 8;
        }
    }

    pub inline fn refillConditional(self: *BitReader, backwards: bool) void {
        if (backwards) self.refillBackwards() else self.refill();
    }

    pub inline fn readBit(self: *BitReader) u32 {
        self.refill();
        const r = self.bits >> 31;
        self.bits <<= 1;
        self.bit_pos += 1;
        return r;
    }

    pub inline fn readBitNoRefill(self: *BitReader) u32 {
        const r = self.bits >> 31;
        self.bits <<= 1;
        self.bit_pos += 1;
        return r;
    }

    /// Reads `n` bits without refilling. `n` must be ≥ 1.
    pub inline fn readBitsNoRefill(self: *BitReader, n: u5) u32 {
        std.debug.assert(n >= 1);
        const r = self.bits >> @intCast(32 - @as(u6, n));
        self.bits <<= n;
        self.bit_pos += n;
        return r;
    }

    /// Reads `n` bits without refilling. `n` may be 0; double-shift
    /// dodges the undefined shift-by-32 case that the C# version avoids.
    pub inline fn readBitsNoRefillZero(self: *BitReader, n: u6) u32 {
        const r = (self.bits >> 1) >> @intCast(31 - n);
        // In Zig, shifting u32 by n requires n to fit in u5. For n == 0
        // we cannot use the vanilla `<<` path because `@intCast(0)` is fine
        // but the value must round-trip; split into the two halves the C#
        // version uses.
        if (n == 0) {
            // no-op; bits/bit_pos unchanged
            return 0;
        }
        self.bits <<= @intCast(n);
        self.bit_pos += @intCast(n);
        return r;
    }

    /// Reads up to 32 bits (may exceed 24) with conditional refill direction.
    pub inline fn readMoreThan24Bits(self: *BitReader, n: u6) u32 {
        return self.readMoreThan24BitsCore(n, false);
    }

    pub inline fn readMoreThan24BitsBackward(self: *BitReader, n: u6) u32 {
        return self.readMoreThan24BitsCore(n, true);
    }

    inline fn readMoreThan24BitsCore(self: *BitReader, n: u6, backwards: bool) u32 {
        std.debug.assert(n > 0 and n <= 32);
        var rv: u32 = 0;
        if (n <= 24) {
            rv = self.readBitsNoRefillZero(n);
        } else {
            const hi: u32 = self.readBitsNoRefill(24);
            const shift: u5 = @intCast(n - 24);
            rv = hi << shift;
            self.refillConditional(backwards);
            const lo: u5 = @intCast(n - 24);
            rv += self.readBitsNoRefill(lo);
        }
        self.refillConditional(backwards);
        return rv;
    }

    /// Exponential-Golomb (γ) decode. Caller must guarantee ≥23 valid bits.
    pub fn readGamma(self: *BitReader) error{CorruptStream}!u32 {
        if (self.bits == 0) return error.CorruptStream;
        var n: u32 = @clz(self.bits);
        n = 2 * n + 2;
        std.debug.assert(n < 24);
        self.bit_pos += @intCast(n);
        const shift: u5 = @intCast(32 - n);
        const r = self.bits >> shift;
        self.bits <<= @intCast(n);
        return r - 2;
    }

    /// γ code with `forced` extra bits appended for precision.
    pub fn readGammaX(self: *BitReader, forced: u5) u32 {
        if (self.bits == 0) return 0;
        const lz: u32 = @clz(self.bits);
        std.debug.assert(lz < 24);
        const lz_u5: u5 = @intCast(lz);
        const right_shift: u5 = @intCast(31 - lz_u5 - @as(u32, forced));
        const part_a: u32 = self.bits >> right_shift;
        const part_b: u32 = (lz - 1) << forced;
        const result = part_a + part_b;
        const total: u5 = @intCast(lz_u5 + forced + 1);
        self.bits <<= total;
        self.bit_pos += total;
        return result;
    }

    pub fn readDistance(self: *BitReader, distance_symbol: u32) u32 {
        return self.readDistanceCore(distance_symbol, false);
    }

    pub fn readDistanceBackward(self: *BitReader, distance_symbol: u32) u32 {
        return self.readDistanceCore(distance_symbol, true);
    }

    fn readDistanceCore(self: *BitReader, distance_symbol: u32, backwards: bool) u32 {
        var result: u32 = 0;
        if (distance_symbol < constants.high_offset_marker) {
            const bits_to_read: u5 = @intCast((distance_symbol >> 4) + 5);
            const rotated = std.math.rotl(u32, self.bits | 1, bits_to_read);
            self.bit_pos += bits_to_read;
            const mask: u32 = (@as(u32, 2) << bits_to_read) - 1;
            self.bits = rotated & ~mask;
            result = ((rotated & mask) << 4) + (distance_symbol & 0xF) - constants.offset_bias_constant;
        } else {
            const bits_to_read: u5 = @intCast(distance_symbol - constants.high_offset_marker + 4);
            const rotated = std.math.rotl(u32, self.bits | 1, bits_to_read);
            self.bit_pos += bits_to_read;
            const mask: u32 = (@as(u32, 2) << bits_to_read) - 1;
            self.bits = rotated & ~mask;
            result = constants.low_offset_encoding_limit + ((rotated & mask) << 12);
            self.refillConditional(backwards);
            result += self.bits >> 20;
            self.bit_pos += 12;
            self.bits <<= 12;
        }
        self.refillConditional(backwards);
        return result;
    }

    pub fn readLength(self: *BitReader, out: *u32) bool {
        return self.readLengthCore(out, false);
    }

    pub fn readLengthBackward(self: *BitReader, out: *u32) bool {
        return self.readLengthCore(out, true);
    }

    fn readLengthCore(self: *BitReader, out: *u32, backwards: bool) bool {
        const leading_zeros: u32 = @clz(self.bits);
        if (leading_zeros > 12) {
            out.* = 0;
            return false;
        }
        const lz_u5: u5 = @intCast(leading_zeros);
        self.bit_pos += @intCast(leading_zeros);
        self.bits <<= lz_u5;
        self.refillConditional(backwards);
        const total_bits: u32 = leading_zeros + 7;
        self.bit_pos += @intCast(total_bits);
        const shift: u5 = @intCast(32 - total_bits);
        out.* = (self.bits >> shift) - 64;
        const total_u5: u5 = @intCast(total_bits);
        self.bits <<= total_u5;
        self.refillConditional(backwards);
        return true;
    }
};

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "forward refill fills 24 bits from 3 bytes" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF, 0x12 };
    var r = BitReader.initForward(&data);
    r.refill();
    // bits = 0xAB_CD_EF_00, bit_pos = 0
    try testing.expectEqual(@as(u32, 0xABCDEF00), r.bits);
    try testing.expectEqual(@as(i32, 0), r.bit_pos);
}

test "readBit consumes MSB-first" {
    const data = [_]u8{ 0b10110010, 0, 0, 0 };
    var r = BitReader.initForward(&data);
    try testing.expectEqual(@as(u32, 1), r.readBit());
    try testing.expectEqual(@as(u32, 0), r.readBit());
    try testing.expectEqual(@as(u32, 1), r.readBit());
    try testing.expectEqual(@as(u32, 1), r.readBit());
    try testing.expectEqual(@as(u32, 0), r.readBit());
    try testing.expectEqual(@as(u32, 0), r.readBit());
    try testing.expectEqual(@as(u32, 1), r.readBit());
    try testing.expectEqual(@as(u32, 0), r.readBit());
}

test "readBitsNoRefill arbitrary widths" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var r = BitReader.initForward(&data);
    r.refill();
    // bits = 0xDEADBE00 (last byte is lost because we only loaded 3 bytes)
    try testing.expectEqual(@as(u32, 0xD), r.readBitsNoRefill(4));
    try testing.expectEqual(@as(u32, 0xE), r.readBitsNoRefill(4));
    try testing.expectEqual(@as(u32, 0xA), r.readBitsNoRefill(4));
    try testing.expectEqual(@as(u32, 0xD), r.readBitsNoRefill(4));
}

test "backward refill fills 24 bits from last 3 bytes" {
    const data = [_]u8{ 0x00, 0x11, 0xAB, 0xCD, 0xEF };
    var r = BitReader.initBackward(&data);
    r.refillBackwards();
    // Last byte 0xEF shifts first into bits 31..24; second-to-last into 23..16; third into 15..8.
    try testing.expectEqual(@as(u32, 0xEFCDAB00), r.bits);
    try testing.expectEqual(@as(i32, 0), r.bit_pos);
}

test "readGamma decodes 1..8 golomb-style" {
    // readGamma returns (bits >> (32-n)) - 2 where n = 2*clz+2.
    // For the fixed input 0x40000000: clz=1 → n=4 → bits>>28 = 4 → result = 2.
    const data = [_]u8{ 0x40, 0, 0, 0 };
    var r = BitReader.initForward(&data);
    r.refill();
    const v = try r.readGamma();
    try testing.expectEqual(@as(u32, 2), v);
}

test "readGamma on zero bits returns CorruptStream" {
    const data = [_]u8{ 0, 0, 0, 0 };
    var r = BitReader.initForward(&data);
    r.refill();
    try testing.expectError(error.CorruptStream, r.readGamma());
}
