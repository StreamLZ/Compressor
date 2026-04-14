//! 64-bit bit writers used by the tANS encoder. Port of
//! `BitWriter64Forward` / `BitWriter64Backward` from
//! src/StreamLZ/Compression/BitWriter.cs.
//!
//! Semantics:
//!   * Bits accumulate MSB-first in a 64-bit buffer. `pos` starts at 63
//!     (empty) and decreases as bits are written. When `pos < 56`, a flush
//!     drains complete bytes in big-endian byte order.
//!   * The forward writer advances its `position` pointer toward higher
//!     addresses and writes big-endian bytes (reverse of native LE).
//!   * The backward writer retreats its `position` pointer toward lower
//!     addresses and writes native-endian bytes at `position - 8`.
//!   * `total_bits` is a running total of all bits written (unaffected by
//!     flushes). Used to compute expected payload sizes.

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
        if (self.pos == 63) return; // buffer empty
        const t: u32 = (63 - self.pos) >> 3;
        const shift: u6 = @intCast(self.pos + 1);
        const v: u64 = self.bits << shift;
        self.pos += 8 * t;
        // Write big-endian (byteswap) and advance
        const be: u64 = @byteSwap(v);
        @as(*align(1) u64, @ptrCast(self.position)).* = be;
        self.position += t;
    }

    pub inline fn write(self: *BitWriter64Forward, bits: u32, n: u5) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
        self.flush();
    }

    pub inline fn writeNoFlush(self: *BitWriter64Forward, bits: u32, n: u5) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
    }

    /// Returns the pointer just past the last byte written, accounting for
    /// residual bits in the buffer.
    pub inline fn getFinalPtr(self: *const BitWriter64Forward) [*]u8 {
        return self.position + @as(usize, if (self.pos != 63) 1 else 0);
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
        // Write native-endian at Position - 8 and retreat
        const dst_ptr: [*]u8 = self.position - 8;
        @as(*align(1) u64, @ptrCast(dst_ptr)).* = v;
        self.position -= t;
    }

    pub inline fn write(self: *BitWriter64Backward, bits: u32, n: u5) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
        self.flush();
    }

    pub inline fn writeNoFlush(self: *BitWriter64Backward, bits: u32, n: u5) void {
        self.total_bits += n;
        self.pos -= n;
        self.bits = (self.bits << n) | bits;
    }

    pub inline fn getFinalPtr(self: *const BitWriter64Backward) [*]u8 {
        return self.position - @as(usize, if (self.pos != 63) 1 else 0);
    }
};

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "BitWriter64Forward single write" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(&buf);
    w.write(0x5, 3); // bits 101
    w.flush();
    // After 3 bits, flush writes nothing (need at least 8 accumulated).
    // write(5, 3) leaves pos at 60. 63-60 = 3, t = 0. Flush is a no-op.
    try testing.expectEqual(@intFromPtr(&buf[0]), @intFromPtr(w.position));
}

test "BitWriter64Forward 8-bit writes land big-endian" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(&buf);
    w.write(0xAB, 8);
    w.write(0xCD, 8);
    w.write(0xEF, 8);
    w.write(0x12, 8);
    w.flush();
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try testing.expectEqual(@as(u8, 0xCD), buf[1]);
    try testing.expectEqual(@as(u8, 0xEF), buf[2]);
    try testing.expectEqual(@as(u8, 0x12), buf[3]);
}

test "BitWriter64Forward getFinalPtr reflects residual" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(&buf);
    w.write(0x7, 4);
    const start: usize = @intFromPtr(&buf[0]);
    const end_ptr = w.getFinalPtr();
    try testing.expect(@intFromPtr(end_ptr) >= start);
    try testing.expect(@intFromPtr(end_ptr) <= start + 1);
}

test "BitWriter64Backward writes at position-8 and retreats" {
    var buf: [16]u8 = @splat(0);
    const dst_end: [*]u8 = buf[0..].ptr + buf.len;
    var w = BitWriter64Backward.init(dst_end);
    w.write(0xAB, 8);
    w.write(0xCD, 8);
    w.write(0xEF, 8);
    w.write(0x12, 8);
    w.flush();
    const end_offset: usize = @intFromPtr(w.position) - @intFromPtr(&buf[0]);
    try testing.expectEqual(@as(usize, 12), end_offset);
}

test "BitWriter64Backward + BitReader.initBackward roundtrip" {
    // Write a known sequence via the backward writer and read it back
    // via the backward reader. Verifies the writer/reader pair is
    // self-consistent.
    const bit_reader_mod = @import("bit_reader.zig");

    var buf: [64]u8 = @splat(0);
    const dst_end: [*]u8 = buf[0..].ptr + buf.len;
    var w = BitWriter64Backward.init(dst_end);
    // First write: value 1 at 3 bits  ("001")
    w.write(1, 3);
    // Second write: value 2 at 2 bits  ("10")
    w.write(2, 2);
    w.flush();
    const bp = w.getFinalPtr();
    const written_bytes: usize = @intFromPtr(dst_end) - @intFromPtr(bp);
    try testing.expect(written_bytes >= 1);

    // Read back via BitReader backward.
    var r = bit_reader_mod.BitReader.initBackward(buf[buf.len - written_bytes ..]);
    r.refillBackwards();
    // First read 3 bits → expect 1
    const v1 = r.readBitsNoRefill(3);
    try testing.expectEqual(@as(u32, 1), v1);
    // Then 2 bits → expect 2
    const v2 = r.readBitsNoRefill(2);
    try testing.expectEqual(@as(u32, 2), v2);
}

test "BitWriter64Forward total_bits tracks across writes" {
    var buf: [16]u8 = @splat(0);
    var w = BitWriter64Forward.init(&buf);
    w.write(0x3, 3);
    w.write(0x7, 5);
    w.write(0xFF, 8);
    try testing.expectEqual(@as(i64, 16), w.total_bits);
}
