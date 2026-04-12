//! Byte-value frequency histogram. Port of
//! src/StreamLZ/Compression/ByteHistogram.cs (count-only subset used by the
//! entropy encoder).

const std = @import("std");

/// Frequency histogram over 256 byte values.
pub const ByteHistogram = struct {
    count: [256]u32 = @splat(0),

    /// Counts occurrences of each byte in `src`. Clears first, so the
    /// returned histogram exactly describes `src`.
    pub fn count_bytes(self: *ByteHistogram, src: []const u8) void {
        self.count = @splat(0);
        for (src) |b| self.count[b] += 1;
    }
};

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "ByteHistogram counts byte frequencies" {
    var h: ByteHistogram = .{};
    h.count_bytes("aaabbc");
    try testing.expectEqual(@as(u32, 3), h.count['a']);
    try testing.expectEqual(@as(u32, 2), h.count['b']);
    try testing.expectEqual(@as(u32, 1), h.count['c']);
    try testing.expectEqual(@as(u32, 0), h.count['d']);
}

test "ByteHistogram resets on re-count" {
    var h: ByteHistogram = .{};
    h.count_bytes("xxx");
    h.count_bytes("y");
    try testing.expectEqual(@as(u32, 0), h.count['x']);
    try testing.expectEqual(@as(u32, 1), h.count['y']);
}
