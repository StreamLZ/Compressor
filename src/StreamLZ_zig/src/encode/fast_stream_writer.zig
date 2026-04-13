//! FastStreamWriter — the parallel-stream output buffer used by the Fast
//! parser during a single sub-chunk encode. Port of `FastStreamWriter` in
//! src/StreamLZ/Compression/Fast/Encoder.cs.
//!
//! The parser emits six streams in parallel:
//!
//!   1. Literal stream       — raw unmatched bytes
//!   2. Delta-literal stream — literal - byte_at_recent_offset (entropy mode)
//!   3. Token stream         — one byte per LZ token (and extended follow-ups)
//!   4. Offset16 stream      — u16 near-offsets for short tokens
//!   5. Offset32 stream      — 3/4-byte far-offsets
//!   6. Length stream        — extended length values (variable width)
//!
//! In RAW mode (user levels 1/2) the parser writes literals directly into the
//! final dst buffer (past a reserved 3-byte count prefix). Everything else
//! lives in a single scratch allocation that `init` carves up.
//!
//! Hot-loop design:
//!   * All six cursors are [*]u8 pointers, kept in adjacent struct fields so
//!     the hot cache line (~64 B) covers all of them. The greedy parser
//!     pulls them into locals at entry and flushes back at exit.
//!   * `assembleRaw` does the raw-mode output assembly (3-byte literal count
//!     header + token memcpy block + off16 raw + off32 packed + length stream)
//!     with no branches on size inside the copy loops — it's called once per
//!     sub-chunk, not in the hot path.

const std = @import("std");
const fast_constants = @import("fast_constants.zig");
const lz_constants = @import("../format/streamlz_constants.zig");

/// Output of a single sub-chunk encode. The parser fills these six streams,
/// then `assembleRaw` / `assembleEntropy` serializes them into the dst buffer.
pub const FastStreamWriter = struct {
    // ── Stream cursors (adjacent — one cache line — hot) ────────────────
    literal_start: [*]u8,
    literal_cursor: [*]u8,
    /// Non-null in entropy mode: alongside each literal write, the token
    /// writer also subtracts the byte at `recent_offset` from the literal
    /// value and stores the delta into this stream. The assembly step
    /// picks the cheaper of the delta and raw literal streams.
    delta_literal_start: ?[*]u8 = null,
    delta_literal_cursor: ?[*]u8 = null,
    token_start: [*]u8,
    token_cursor: [*]u8,
    off16_start: [*]u16,
    off16_cursor: [*]u16,
    off32_start: [*]u8,
    off32_cursor: [*]u8,
    length_start: [*]u8,
    length_cursor: [*]u8,

    // ── Bookkeeping (cold path) ─────────────────────────────────────────
    source_ptr: [*]const u8,
    source_length: usize,
    /// Offset of the current parser block within the sub-chunk (0 or 64 KB).
    block2_start_offset: u32,
    block1_size: u32,
    block2_size: u32,
    /// Token count at the start of the block-2 parser pass. Read back by the
    /// decoder as the `cmd_stream2_offset` field.
    token_stream2_offset: u32,
    /// Running off32 counts split between the two parser blocks.
    off32_count_block1: u32,
    off32_count_block2: u32,
    /// Complex-token counter (not used by the raw-mode decoder, but kept for
    /// format parity with the cost model).
    complex_token_count: u32,
    /// Running off32 count within the current parser block. Reset between
    /// block1 and block2 passes.
    off32_count: u32,

    // ── Backing storage ─────────────────────────────────────────────────
    /// Base of the scratch allocation. Free this via `allocator.free(scratch)`.
    scratch: []u8,

    /// Allocate and carve up the scratch buffer.
    ///
    /// `source_length` is the size of the sub-chunk being encoded (≤ 128 KB).
    /// `raw_literals_dst` is used in raw mode: the parser writes literals
    /// directly to that pointer, bypassing the scratch literal stream.
    /// For entropy mode, pass `null` and the literal stream lives in scratch.
    /// `use_delta_literals` enables a parallel delta-literal stream (the
    /// parser writes `literal[i] - byte_at_recent_offset[i]` alongside the
    /// raw literals). Entropy mode picks the cheaper stream at assembly.
    pub fn init(
        allocator: std.mem.Allocator,
        source_ptr: [*]const u8,
        source_length: usize,
        raw_literals_dst: ?[*]u8,
        use_delta_literals: bool,
    ) !FastStreamWriter {
        // Match C# FastStreamWriter.Initialize sizing (with generous rounding).
        const literal_size: usize = source_length + 8;
        const token_size: usize = source_length / 2 + 16;
        const off16_size: usize = source_length / 3 + 8; // number of u16s
        const off32_size: usize = source_length / 8 + 8; // number of 4-byte slots
        const length_size: usize = source_length / 29 + 16;

        // Layout: [token_stream][off16_stream (aligned 2)][off32_stream][length_stream][delta?][literal?]
        const literal_in_scratch = raw_literals_dst == null;
        const total_size: usize = token_size + (off16_size * 2) + (off32_size * 4) + length_size +
            (if (literal_in_scratch) literal_size else 0) +
            (if (use_delta_literals) literal_size else 0) + 64;

        const scratch = try allocator.alloc(u8, total_size);
        var p: usize = 0;

        const token_ptr: [*]u8 = scratch.ptr + p;
        p += token_size;
        // Align off16 stream to 2 bytes.
        p = (p + 1) & ~@as(usize, 1);
        const off16_ptr: [*]u16 = @ptrCast(@alignCast(scratch.ptr + p));
        p += off16_size * 2;
        const off32_ptr: [*]u8 = scratch.ptr + p;
        p += off32_size * 4;
        const length_ptr: [*]u8 = scratch.ptr + p;
        p += length_size;

        var delta_literal_ptr: ?[*]u8 = null;
        if (use_delta_literals) {
            delta_literal_ptr = scratch.ptr + p;
            p += literal_size;
        }

        const literal_ptr: [*]u8 = if (raw_literals_dst) |d| d else blk: {
            const lp = scratch.ptr + p;
            p += literal_size;
            break :blk lp;
        };

        std.debug.assert(p <= total_size);

        const block1: u32 = @intCast(@min(source_length, fast_constants.block1_max_size));
        const block2: u32 = @intCast(source_length - block1);

        return .{
            .literal_start = literal_ptr,
            .literal_cursor = literal_ptr,
            .delta_literal_start = delta_literal_ptr,
            .delta_literal_cursor = delta_literal_ptr,
            .token_start = token_ptr,
            .token_cursor = token_ptr,
            .off16_start = off16_ptr,
            .off16_cursor = off16_ptr,
            .off32_start = off32_ptr,
            .off32_cursor = off32_ptr,
            .length_start = length_ptr,
            .length_cursor = length_ptr,
            .source_ptr = source_ptr,
            .source_length = source_length,
            .block2_start_offset = 0,
            .block1_size = block1,
            .block2_size = block2,
            .token_stream2_offset = 0,
            .off32_count_block1 = 0,
            .off32_count_block2 = 0,
            .complex_token_count = 0,
            .off32_count = 0,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *FastStreamWriter, allocator: std.mem.Allocator) void {
        allocator.free(self.scratch);
        self.* = undefined;
    }

    // ── Stream size accessors ───────────────────────────────────────────

    pub inline fn literalCount(self: *const FastStreamWriter) usize {
        return @intFromPtr(self.literal_cursor) - @intFromPtr(self.literal_start);
    }
    pub inline fn deltaLiteralCount(self: *const FastStreamWriter) usize {
        if (self.delta_literal_cursor) |cur| {
            return @intFromPtr(cur) - @intFromPtr(self.delta_literal_start.?);
        }
        return 0;
    }
    pub inline fn tokenCount(self: *const FastStreamWriter) usize {
        return @intFromPtr(self.token_cursor) - @intFromPtr(self.token_start);
    }
    pub inline fn off16Count(self: *const FastStreamWriter) usize {
        return (@intFromPtr(self.off16_cursor) - @intFromPtr(self.off16_start)) / 2;
    }
    pub inline fn off32ByteCount(self: *const FastStreamWriter) usize {
        return @intFromPtr(self.off32_cursor) - @intFromPtr(self.off32_start);
    }
    pub inline fn lengthCount(self: *const FastStreamWriter) usize {
        return @intFromPtr(self.length_cursor) - @intFromPtr(self.length_start);
    }
};

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "FastStreamWriter.init allocates and sets cursors at start" {
    const src: [100]u8 = @splat('A');
    var w = try FastStreamWriter.init(testing.allocator, &src, src.len, null, false);
    defer w.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), w.literalCount());
    try testing.expectEqual(@as(usize, 0), w.tokenCount());
    try testing.expectEqual(@as(usize, 0), w.off16Count());
    try testing.expectEqual(@as(usize, 0), w.lengthCount());
    try testing.expectEqual(@as(u32, 100), w.block1_size);
    try testing.expectEqual(@as(u32, 0), w.block2_size);
}

test "FastStreamWriter block1/block2 split at 64 KB" {
    const src: [150 * 1024]u8 = @splat('A');
    var w = try FastStreamWriter.init(testing.allocator, &src, src.len, null, false);
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 65536), w.block1_size);
    try testing.expectEqual(@as(u32, 150 * 1024 - 65536), w.block2_size);
}

test "FastStreamWriter raw mode accepts external literal dst" {
    const src: [100]u8 = @splat('A');
    var dst: [200]u8 = undefined;
    var w = try FastStreamWriter.init(testing.allocator, &src, src.len, dst[0..].ptr, false);
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), w.literalCount());
    try testing.expectEqual(@intFromPtr(&dst[0]), @intFromPtr(w.literal_start));
}
