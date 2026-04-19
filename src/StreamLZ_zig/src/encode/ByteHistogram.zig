//! Byte-value frequency histogram (count-only subset used by the
//! entropy encoder).
//! Used by: Fast and High codecs

const std = @import("std");

/// Frequency histogram over 256 byte values.
pub const ByteHistogram = struct {
    count: [256]u32 = @splat(0),

    /// Counts occurrences of each byte in `src`. Clears first, so the
    /// returned histogram exactly describes `src`.
    pub fn countBytes(self: *ByteHistogram, src: []const u8) void {
        self.count = @splat(0);
        for (src) |b| self.count[b] += 1;
    }
};

/// Log2 lookup table — `4096 * log2(4096 / i)` for i in 1..4096; entry 0 is 0.
/// Built once at comptime so cost calls are pure.
pub const log2_lookup_table: [4097]u32 = blk: {
    @setEvalBranchQuota(50_000);
    var t: [4097]u32 = undefined;
    t[0] = 0;
    var i: usize = 1;
    while (i <= 4096) : (i += 1) {
        const v: f64 = 4096.0 * @log2(4096.0 / @as(f64, @floatFromInt(i)));
        t[i] = @intFromFloat(v);
    }
    break :blk t;
};

/// Approximate bit cost of encoding a histogram entropy-coded.
/// Approximate entropy cost computation. Returns the
/// estimated cost in bit-units (fixed-point, NOT bytes).
pub fn getCostApproxCore(histo: []const u32, histo_sum: i32) u32 {
    if (histo_sum <= 1) return 40;

    const factor: i64 = @intCast(@as(u32, 0x40000000) / @as(u32, @intCast(histo_sum)));
    var zeros_run: u32 = 0;
    var nonzero_entries: u32 = 0;
    var bit_usage_z: u32 = 0;
    var bit_usage: u32 = 0;
    var bit_usage_f: u64 = 0;

    for (histo) |v| {
        if (v == 0) {
            zeros_run += 1;
            continue;
        }
        nonzero_entries += 1;
        if (zeros_run != 0) {
            bit_usage_z += 2 * std.math.log2_int(u32, zeros_run + 1) + 1;
            zeros_run = 0;
        } else {
            bit_usage_z += 1;
        }
        bit_usage += std.math.log2_int(u32, v) * 2 + 1;
        var log2_index: u64 = @intCast((factor * @as(i64, @intCast(v))) >> 18);
        if (log2_index > 4096) log2_index = 4096;
        bit_usage_f += @as(u64, v) * @as(u64, log2_lookup_table[@intCast(log2_index)]);
    }

    if (nonzero_entries == 1) return 6 * 8;

    bit_usage_z += 2 * std.math.log2_int(u32, zeros_run + 1) + 1;
    bit_usage_z = @min(bit_usage_z, 8 * nonzero_entries);

    return @as(u32, @intCast(bit_usage_f >> 12)) + bit_usage + bit_usage_z + 5 * 8;
}


// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "ByteHistogram counts byte frequencies" {
    var h: ByteHistogram = .{};
    h.countBytes("aaabbc");
    try testing.expectEqual(@as(u32, 3), h.count['a']);
    try testing.expectEqual(@as(u32, 2), h.count['b']);
    try testing.expectEqual(@as(u32, 1), h.count['c']);
    try testing.expectEqual(@as(u32, 0), h.count['d']);
}

test "ByteHistogram resets on re-count" {
    var h: ByteHistogram = .{};
    h.countBytes("xxx");
    h.countBytes("y");
    try testing.expectEqual(@as(u32, 0), h.count['x']);
    try testing.expectEqual(@as(u32, 1), h.count['y']);
}
