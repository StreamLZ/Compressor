//! Bit-level writers for entropy encoding.
//!
//! Four bit-writer variants:
//!   * `BitWriter64Forward`  — 64-bit buffer, big-endian byte-swap on flush,
//!     forward pointer.
//!   * `BitWriter64Backward` — 64-bit buffer, native-endian on flush,
//!     retreating pointer.
//!   * `BitWriter32Forward`  — 64-bit accumulator, native (LE) u32 flush,
//!     forward pointer.
//!   * `BitWriter32Backward` — 64-bit accumulator, byte-swapped u32 flush,
//!     retreating pointer.
//!
//! All four share the same `Write(bits, n)` semantics; the 64-bit variants
//! flush on every write, the 32-bit variants flush via `push32` when the
//! accumulator crosses 32 bits.

const std = @import("std");

pub const BitWriter64Forward = struct {
    position: [*]u8,
    bits: u64 = 0,
    pos: u32 = 63,
    total_bits: i64 = 0,

    pub fn init(dst: [*]u8) BitWriter64Forward {
        return .{ .position = dst };
    }

    pub inline fn flush(self: *BitWriter64Forward) void {
        if (self.pos == 63) return;
        const t: u32 = (63 - self.pos) >> 3;
        const shift: u6 = @intCast(self.pos + 1);
        const v: u64 = self.bits << shift;
        self.pos += 8 * t;
        // Forward: big-endian (byte-swapped) write, advance pointer.
        const swapped = @byteSwap(v);
        std.mem.writeInt(u64, self.position[0..8], swapped, .little);
        self.position += t;
    }

    pub inline fn write(self: *BitWriter64Forward, bits: u32, n: u6) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
        self.flush();
    }

    pub inline fn writeNoFlush(self: *BitWriter64Forward, bits: u32, n: u6) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
    }

    pub inline fn getFinalPtr(self: *BitWriter64Forward) [*]u8 {
        const adj: usize = if (self.pos != 63) 1 else 0;
        return self.position + adj;
    }
};

pub const BitWriter64Backward = struct {
    position: [*]u8,
    bits: u64 = 0,
    pos: u32 = 63,
    total_bits: i64 = 0,

    pub fn init(dst: [*]u8) BitWriter64Backward {
        return .{ .position = dst };
    }

    pub inline fn flush(self: *BitWriter64Backward) void {
        if (self.pos == 63) return;
        const t: u32 = (63 - self.pos) >> 3;
        const shift: u6 = @intCast(self.pos + 1);
        const v: u64 = self.bits << shift;
        self.pos += 8 * t;
        // Backward: native-endian at position-8, retreat pointer.
        const dst: [*]u8 = self.position - 8;
        std.mem.writeInt(u64, dst[0..8], v, .little);
        self.position -= t;
    }

    pub inline fn write(self: *BitWriter64Backward, bits: u32, n: u6) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
        self.flush();
    }

    pub inline fn writeNoFlush(self: *BitWriter64Backward, bits: u32, n: u6) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
    }

    pub inline fn getFinalPtr(self: *BitWriter64Backward) [*]u8 {
        const adj: usize = if (self.pos != 63) 1 else 0;
        return self.position - adj;
    }
};

pub const BitWriter32Forward = struct {
    bits: u64 = 0,
    position: [*]u8,
    bit_pos: i32 = 0,

    pub fn init(dst: [*]u8) BitWriter32Forward {
        return .{ .position = dst };
    }

    pub inline fn write(self: *BitWriter32Forward, bits: u32, n: u6) void {
        self.bits |= @as(u64, bits) << @intCast(self.bit_pos);
        self.bit_pos += @intCast(n);
    }

    pub inline fn push32(self: *BitWriter32Forward) void {
        if (self.bit_pos >= 32) {
            std.mem.writeInt(u32, self.position[0..4], @truncate(self.bits), .little);
            self.position += 4;
            self.bits >>= 32;
            self.bit_pos -= 32;
        }
    }

    pub inline fn pushFinal(self: *BitWriter32Forward) void {
        while (self.bit_pos > 0) {
            self.position[0] = @truncate(self.bits);
            self.position += 1;
            self.bits >>= 8;
            self.bit_pos -= 8;
        }
        std.debug.assert(self.bit_pos <= 0);
    }
};

pub const BitWriter32Backward = struct {
    bits: u64 = 0,
    position: [*]u8,
    bit_pos: i32 = 0,

    pub fn init(dst: [*]u8) BitWriter32Backward {
        return .{ .position = dst };
    }

    pub inline fn write(self: *BitWriter32Backward, bits: u32, n: u6) void {
        self.bits |= @as(u64, bits) << @intCast(self.bit_pos);
        self.bit_pos += @intCast(n);
    }

    pub inline fn push32(self: *BitWriter32Backward) void {
        if (self.bit_pos >= 32) {
            self.position -= 4;
            const swapped = @byteSwap(@as(u32, @truncate(self.bits)));
            std.mem.writeInt(u32, self.position[0..4], swapped, .little);
            self.bits >>= 32;
            self.bit_pos -= 32;
        }
    }

    pub inline fn pushFinal(self: *BitWriter32Backward) void {
        while (self.bit_pos > 0) {
            self.position -= 1;
            self.position[0] = @truncate(self.bits);
            self.bits >>= 8;
            self.bit_pos -= 8;
        }
        std.debug.assert(self.bit_pos <= 0);
    }
};

// ────────────────────────────────────────────────────────────
//  Tests: roundtrip writer → reader
// ────────────────────────────────────────────────────────────

const testing = std.testing;
const BitReader = @import("bit_reader.zig").BitReader;

test "BitWriter64Forward writes big-endian bytes readable by BitReader.refill" {
    // Write three 8-bit values that, viewed as a forward MSB-first stream,
    // become 0xAA 0xBB 0xCC.
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(buf[0..].ptr);
    w.write(0xAA, 8);
    w.write(0xBB, 8);
    w.write(0xCC, 8);
    // Pad to byte boundary (already on boundary since 24 bits) then flush.
    // The writer only flushes on 8-bit chunks at flush time; residual bits
    // (none here) would be left in the buffer.
    try testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try testing.expectEqual(@as(u8, 0xBB), buf[1]);
    try testing.expectEqual(@as(u8, 0xCC), buf[2]);

    // Reader consumes the same bytes as 8-bit tokens.
    var r = BitReader.initForward(buf[0..3]);
    r.refill();
    try testing.expectEqual(@as(u32, 0xAA), r.readBitsNoRefill(8));
    try testing.expectEqual(@as(u32, 0xBB), r.readBitsNoRefill(8));
    try testing.expectEqual(@as(u32, 0xCC), r.readBitsNoRefill(8));
}

test "BitWriter32Forward accumulates and flushes LSB-first" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter32Forward.init(buf[0..].ptr);
    // Write 0x12345678 as 32 bits in one shot.
    w.write(0x12345678, 32);
    w.push32();
    // LSB-first: byte 0 = 0x78, byte 1 = 0x56, byte 2 = 0x34, byte 3 = 0x12.
    try testing.expectEqual(@as(u8, 0x78), buf[0]);
    try testing.expectEqual(@as(u8, 0x56), buf[1]);
    try testing.expectEqual(@as(u8, 0x34), buf[2]);
    try testing.expectEqual(@as(u8, 0x12), buf[3]);
}

test "BitWriter32Forward.pushFinal flushes residual bits" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter32Forward.init(buf[0..].ptr);
    w.write(0xA5, 8); // 8 bits, not flushed by push32
    w.push32();
    w.pushFinal();
    try testing.expectEqual(@as(u8, 0xA5), buf[0]);
}

test "BitWriter64Forward residual bits flush on explicit .flush()" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(buf[0..].ptr);
    w.write(0b10110, 5);
    // pos = 58; 58 < 63 ⇒ t = (63-58)>>3 = 0 ⇒ nothing flushed yet.
    // write another 3 bits to complete a full byte:
    w.write(0b010, 3);
    // Now pos = 55, t = (63-55)>>3 = 1 ⇒ one byte flushed.
    try testing.expectEqual(@as(u8, 0b10110_010), buf[0]);
}
