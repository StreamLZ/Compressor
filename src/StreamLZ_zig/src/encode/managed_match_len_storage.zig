//! Managed match-length storage + variable-length codec + extract helpers.
//! Used by: High codec (L6-L11)
//!
//! Shared data structure used by the High codec: each source offset maps
//! to a variable-length sequence of (length, offset) pairs encoded via
//! the `VarLen*` helpers. The match finder populates this storage once
//! per round; the optimal parser then reads back (length, offset) lists
//! via `extractLaoFromMls`.

const std = @import("std");
const match_eval = @import("match_eval.zig");

/// (length, offset) pair. Offset is the
/// backward distance to the match source (always positive for hash-based
/// matches).
pub const LengthAndOffset = struct {
    length: i32,
    offset: i32,

    pub inline fn set(self: *LengthAndOffset, len: i32, off: i32) void {
        self.length = len;
        self.offset = off;
    }
};

/// Match-length storage. Each byte position in the source window maps
/// to a variable-length byte sequence holding its match candidates.
/// `offset2_pos[i] == 0` means "no matches at position i".
pub const ManagedMatchLenStorage = struct {
    /// Variable-length encoded match data buffer.
    byte_buffer: []u8,
    /// Current write position in `byte_buffer` (starts at 1 so `0` is
    /// reserved for "no matches" in `offset2_pos`).
    byte_buffer_use: usize,
    /// Maps source offset to position in `byte_buffer`.
    offset2_pos: []i32,
    /// Base offset of the source window within the match finder's byte array.
    window_base_offset: i32 = 0,
    /// Absolute start-position of the round that populated this MLS.
    round_start_pos: i32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, entries: usize, avg_bytes: f32) !ManagedMatchLenStorage {
        const byte_cap: usize = @intFromFloat(@as(f32, @floatFromInt(entries)) * avg_bytes);
        const byte_buffer = try allocator.alloc(u8, byte_cap);
        const offset2_pos = try allocator.alloc(i32, entries);
        @memset(offset2_pos, 0);
        return .{
            .byte_buffer = byte_buffer,
            .byte_buffer_use = 1,
            .offset2_pos = offset2_pos,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ManagedMatchLenStorage) void {
        self.allocator.free(self.byte_buffer);
        self.allocator.free(self.offset2_pos);
        self.* = undefined;
    }

    /// Reset for reuse. Grows buffers if needed; clears `offset2_pos`.
    pub fn reset(self: *ManagedMatchLenStorage, entries: usize, avg_bytes: f32) !void {
        const needed_bytes: usize = @intFromFloat(@as(f32, @floatFromInt(entries)) * avg_bytes);
        if (self.byte_buffer.len < needed_bytes) {
            self.allocator.free(self.byte_buffer);
            self.byte_buffer = try self.allocator.alloc(u8, needed_bytes);
        }
        if (self.offset2_pos.len < entries) {
            self.allocator.free(self.offset2_pos);
            self.offset2_pos = try self.allocator.alloc(i32, entries);
        }
        @memset(self.offset2_pos[0..entries], 0);
        self.byte_buffer_use = 1;
        self.window_base_offset = 0;
        self.round_start_pos = 0;
    }

    /// Grows `byte_buffer` to hold at least `needed_bytes`. Matches the
    /// Growth policy (1.25×) so any cost-model test that compares
    /// allocation counts stays predictable.
    fn ensureByteBuffer(self: *ManagedMatchLenStorage, needed_bytes: usize) !void {
        if (needed_bytes < self.byte_buffer.len) return;
        const grown: usize = @max(needed_bytes, self.byte_buffer.len + (self.byte_buffer.len >> 2));
        const new_buf = try self.allocator.alloc(u8, grown);
        @memcpy(new_buf[0..self.byte_buffer.len], self.byte_buffer);
        self.allocator.free(self.byte_buffer);
        self.byte_buffer = new_buf;
    }
};

// ────────────────────────────────────────────────────────────
//  Variable-length encoding
// ────────────────────────────────────────────────────────────

/// Writes a variable-length encoded value using a split high/low scheme.
inline fn varLenWriteSpill(dst: []u8, dst_pos_in: usize, value_in: u32, a: u5) usize {
    var dst_pos = dst_pos_in;
    var value = value_in;
    const shifted: u32 = @as(u32, 1) << a;
    const thres: u32 = 256 - shifted;
    while (value >= thres) {
        value -= thres;
        dst[dst_pos] = @intCast(value & (shifted - 1));
        dst_pos += 1;
        value >>= a;
    }
    dst[dst_pos] = @intCast(value + shifted);
    return dst_pos + 1;
}

/// Writes a variable-length encoded offset (2-byte base + optional spill).
inline fn varLenWriteOffset(dst: []u8, dst_pos_in: usize, value: u32, a: u5, b: u5) usize {
    var dst_pos = dst_pos_in;
    const shifted: u32 = @as(u32, 1) << a;
    const thres: u32 = 65536 - shifted;
    if (value >= thres) {
        const v: u32 = (value - thres) & (shifted - 1);
        dst[dst_pos] = @intCast((v >> 8) & 0xFF);
        dst[dst_pos + 1] = @intCast(v & 0xFF);
        dst_pos += 2;
        return varLenWriteSpill(dst, dst_pos, (value - thres) >> a, b);
    }
    const v: u32 = value + shifted;
    dst[dst_pos] = @intCast((v >> 8) & 0xFF);
    dst[dst_pos + 1] = @intCast(v & 0xFF);
    return dst_pos + 2;
}

/// Writes a variable-length encoded length (1-byte base + optional spill).
inline fn varLenWriteLength(dst: []u8, dst_pos_in: usize, value: u32, a: u5, b: u5) usize {
    var dst_pos = dst_pos_in;
    const shifted: u32 = @as(u32, 1) << a;
    const thres: u32 = 256 - shifted;
    if (value >= thres) {
        const v: u32 = (value - thres) & (shifted - 1);
        dst[dst_pos] = @intCast(v);
        dst_pos += 1;
        return varLenWriteSpill(dst, dst_pos, (value - thres) >> a, b);
    }
    const v: u32 = value + shifted;
    dst[dst_pos] = @intCast(v);
    return dst_pos + 1;
}

// ────────────────────────────────────────────────────────────
//  Insertion into storage
// ────────────────────────────────────────────────────────────

/// Inserts one or more matches into the MLS at `at_offset`.
pub fn insertMatches(
    mls: *ManagedMatchLenStorage,
    at_offset: usize,
    lao: []const LengthAndOffset,
    num_lao: usize,
) !void {
    if (num_lao == 0) return;

    mls.offset2_pos[at_offset] = @intCast(mls.byte_buffer_use);

    const needed: usize = mls.byte_buffer_use + 16 * num_lao + 2;
    try mls.ensureByteBuffer(needed);

    var pos = mls.byte_buffer_use;
    const buf = mls.byte_buffer;

    var i: usize = 0;
    while (i < num_lao and lao[i].length != 0) : (i += 1) {
        std.debug.assert(lao[i].offset != 0);
        pos = varLenWriteLength(buf, pos, @intCast(lao[i].length), 1, 3);
        pos = varLenWriteOffset(buf, pos, @intCast(lao[i].offset), 13, 7);
    }
    pos = varLenWriteLength(buf, pos, 0, 1, 3);

    mls.byte_buffer_use = pos;
}

// ────────────────────────────────────────────────────────────
//  Deduplication
// ────────────────────────────────────────────────────────────

/// Removes entries with duplicate lengths from a sorted match array.
pub fn removeIdentical(matches: []LengthAndOffset, count_in: usize) usize {
    std.debug.assert(count_in > 0);
    var count = count_in;
    var p: usize = 0;
    while (p < count - 1 and matches[p].length != matches[p + 1].length) p += 1;
    if (p < count - 1) {
        var dst: usize = p;
        var r: usize = p + 2;
        while (r < count) : (r += 1) {
            if (matches[dst].length != matches[r].length) {
                dst += 1;
                matches[dst] = matches[r];
            }
        }
        count = dst + 1;
    }
    return count;
}

// ────────────────────────────────────────────────────────────
//  Extraction (decoder-side of VarLen codec)
// ────────────────────────────────────────────────────────────

/// Reads a variable-length integer from the MLS byte buffer.
/// Returns `error.Truncated` on underflow, otherwise the decoded value.
///
/// All arithmetic is done via wrapping `u32` ops then bitcast back to
/// `i32` to match signed-wrapping semantics (Zig's signed ops would
/// panic on overflow).
inline fn extractFromMlsInner(
    src: []const u8,
    pos_in_out: *usize,
    src_end: usize,
    a: u5,
) !i32 {
    var sum: u32 = 0;
    // bitpos can grow past 32 for garbage inputs; bail out rather than
    // shifting by >= bit-width of u32 (Zig UB). Valid streams produce
    // at most ~4 iterations for an 18-bit value with a=3 or a=7.
    var bitpos: u32 = 0;
    while (true) {
        if (pos_in_out.* >= src_end) return error.Truncated;
        if (bitpos >= 32) return error.Truncated;
        const byte_val: u32 = src[pos_in_out.*];
        pos_in_out.* += 1;
        const t: i32 = @as(i32, @intCast(byte_val)) - (@as(i32, 1) << a);
        const bitpos_u5: u5 = @intCast(bitpos);
        if (t >= 0) {
            return @bitCast(sum +% (@as(u32, @intCast(t)) << bitpos_u5));
        }
        sum +%= (@as(u32, @bitCast(t)) +% 256) << bitpos_u5;
        bitpos += a;
    }
}

/// Reads a variable-length encoded length.
pub fn extractLengthFromMls(
    src: []const u8,
    pos_in_out: *usize,
    src_end: usize,
    a: u5,
    b: u5,
) !i32 {
    if (pos_in_out.* >= src_end) return error.Truncated;
    const byte_val: i32 = src[pos_in_out.*];
    pos_in_out.* += 1;
    const t: i32 = byte_val - (@as(i32, 1) << a);
    if (t < 0) {
        const inner = try extractFromMlsInner(src, pos_in_out, src_end, b);
        const inner_shifted: u32 = @as(u32, @bitCast(inner)) << a;
        const result: u32 = @as(u32, @bitCast(t)) +% inner_shifted +% 256;
        return @bitCast(result);
    }
    return t;
}

/// Reads a variable-length encoded offset.
pub fn extractOffsetFromMls(
    src: []const u8,
    pos_in_out: *usize,
    src_end: usize,
    a: u5,
    b: u5,
) !i32 {
    if (src_end < pos_in_out.* + 2) return error.Truncated;
    const t: i32 = ((@as(i32, src[pos_in_out.*]) << 8) | @as(i32, src[pos_in_out.* + 1])) - (@as(i32, 1) << a);
    pos_in_out.* += 2;
    if (t < 0) {
        const inner = try extractFromMlsInner(src, pos_in_out, src_end, b);
        const inner_shifted: u32 = @as(u32, @bitCast(inner)) << a;
        const result: u32 = @as(u32, @bitCast(t)) +% inner_shifted +% 65536;
        return @bitCast(result);
    }
    return t;
}

/// Extracts `LengthAndOffset` arrays from a `ManagedMatchLenStorage` for
/// a range of source offsets.
pub fn extractLaoFromMls(
    mls: *const ManagedMatchLenStorage,
    start: usize,
    src_size: usize,
    lao: []LengthAndOffset,
    num_lao_per_offs: usize,
) !void {
    if (start + src_size > mls.offset2_pos.len) return error.OutOfBounds;

    var lao_idx: usize = 0;
    var s: usize = src_size;
    var off: usize = start;
    while (s > 0) : ({
        s -= 1;
        off += 1;
    }) {
        const pos: i32 = mls.offset2_pos[off];
        if (pos != 0) {
            var cur_pos: usize = @intCast(pos);
            if (cur_pos == 0 or cur_pos + 32 > mls.byte_buffer.len) {
                lao[lao_idx].length = 0;
                lao_idx += num_lao_per_offs;
                continue;
            }
            var lao_cur = lao_idx;
            var i: usize = num_lao_per_offs;
            while (i > 0) : ({
                i -= 1;
                lao_cur += 1;
            }) {
                if (cur_pos + 32 > mls.byte_buffer.len) break;
                const src_end = cur_pos + 32;
                const len = extractLengthFromMls(mls.byte_buffer, &cur_pos, src_end, 1, 3) catch {
                    lao[lao_cur].length = 0;
                    break;
                };
                lao[lao_cur].length = len;
                if (cur_pos + 32 > mls.byte_buffer.len) break;
                const src_end2 = cur_pos + 32;
                const offs = extractOffsetFromMls(mls.byte_buffer, &cur_pos, src_end2, 13, 7) catch {
                    lao[lao_cur].length = 0;
                    break;
                };
                lao[lao_cur].offset = offs;
                if (len == 0) break;
            }
        } else {
            lao[lao_idx].length = 0;
        }
        lao_idx += num_lao_per_offs;
    }
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "ManagedMatchLenStorage init + reset" {
    var mls = try ManagedMatchLenStorage.init(testing.allocator, 100, 8.0);
    defer mls.deinit();
    try testing.expectEqual(@as(usize, 100), mls.offset2_pos.len);
    try testing.expect(mls.byte_buffer.len >= 800);
    try testing.expectEqual(@as(usize, 1), mls.byte_buffer_use);

    try mls.reset(100, 8.0);
    try testing.expectEqual(@as(usize, 1), mls.byte_buffer_use);
    try testing.expectEqual(@as(i32, 0), mls.offset2_pos[0]);
}

test "varLen length codec round-trips a small length" {
    var buf: [32]u8 = @splat(0);
    const end = varLenWriteLength(&buf, 0, 42, 1, 3);
    var read_pos: usize = 0;
    const decoded = try extractLengthFromMls(buf[0..end], &read_pos, end, 1, 3);
    try testing.expectEqual(@as(i32, 42), decoded);
    try testing.expectEqual(end, read_pos);
}

test "varLen length codec round-trips a large length (spill path)" {
    var buf: [32]u8 = @splat(0);
    const end = varLenWriteLength(&buf, 0, 100_000, 1, 3);
    var read_pos: usize = 0;
    const decoded = try extractLengthFromMls(buf[0..end], &read_pos, end, 1, 3);
    try testing.expectEqual(@as(i32, 100_000), decoded);
    try testing.expectEqual(end, read_pos);
}

test "varLen offset codec round-trips a small offset" {
    var buf: [32]u8 = @splat(0);
    const end = varLenWriteOffset(&buf, 0, 1234, 13, 7);
    var read_pos: usize = 0;
    const decoded = try extractOffsetFromMls(buf[0..end], &read_pos, end, 13, 7);
    try testing.expectEqual(@as(i32, 1234), decoded);
    try testing.expectEqual(end, read_pos);
}

test "varLen offset codec round-trips a large offset (spill path)" {
    var buf: [32]u8 = @splat(0);
    const end = varLenWriteOffset(&buf, 0, 2_000_000, 13, 7);
    var read_pos: usize = 0;
    const decoded = try extractOffsetFromMls(buf[0..end], &read_pos, end, 13, 7);
    try testing.expectEqual(@as(i32, 2_000_000), decoded);
    try testing.expectEqual(end, read_pos);
}

test "insertMatches writes sequence then zero terminator" {
    var mls = try ManagedMatchLenStorage.init(testing.allocator, 100, 8.0);
    defer mls.deinit();

    var lao = [_]LengthAndOffset{
        .{ .length = 10, .offset = 100 },
        .{ .length = 6, .offset = 25 },
    };
    try insertMatches(&mls, 0, &lao, 2);
    try testing.expect(mls.offset2_pos[0] > 0);
    try testing.expect(mls.byte_buffer_use > 1);
}

test "extractLaoFromMls round-trips what insertMatches wrote" {
    var mls = try ManagedMatchLenStorage.init(testing.allocator, 10, 16.0);
    defer mls.deinit();

    var matches = [_]LengthAndOffset{
        .{ .length = 32, .offset = 1024 },
        .{ .length = 20, .offset = 50 },
        .{ .length = 6, .offset = 4 },
    };
    try insertMatches(&mls, 3, &matches, 3);

    var out: [10]LengthAndOffset = @splat(.{ .length = 0, .offset = 0 });
    try extractLaoFromMls(&mls, 3, 1, &out, 5);

    try testing.expectEqual(@as(i32, 32), out[0].length);
    try testing.expectEqual(@as(i32, 1024), out[0].offset);
    try testing.expectEqual(@as(i32, 20), out[1].length);
    try testing.expectEqual(@as(i32, 50), out[1].offset);
    try testing.expectEqual(@as(i32, 6), out[2].length);
    try testing.expectEqual(@as(i32, 4), out[2].offset);
    // Terminator: next entry has length 0.
    try testing.expectEqual(@as(i32, 0), out[3].length);
}

test "removeIdentical collapses duplicate lengths" {
    var matches = [_]LengthAndOffset{
        .{ .length = 10, .offset = 1 },
        .{ .length = 10, .offset = 2 },
        .{ .length = 8, .offset = 3 },
        .{ .length = 8, .offset = 4 },
        .{ .length = 5, .offset = 5 },
    };
    const n = removeIdentical(&matches, 5);
    // Keeps first of each run: [10, 8, 5] — 3 entries.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(i32, 10), matches[0].length);
    try testing.expectEqual(@as(i32, 8), matches[1].length);
    try testing.expectEqual(@as(i32, 5), matches[2].length);
}
