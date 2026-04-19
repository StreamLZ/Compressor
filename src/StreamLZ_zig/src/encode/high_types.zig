//! Core data structures for the High compressor.
//! Used by: High codec (L6-L11)
//!
//! These types are shared across the High encoder, High cost model,
//! High optimal parser, and High fast parser -- they live here to
//! avoid circular imports.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");
const hist_mod = @import("ByteHistogram.zig");

const ByteHistogram = hist_mod.ByteHistogram;

pub const min_bytes_per_round: usize = 256;
pub const max_bytes_per_round: usize = 4096;
pub const recent_offset_count: usize = 3;

/// Recent-offset ring for the High compressor (3 active entries at
/// indices 4-6). The carousel rotation uses overlapping array access
/// patterns that require scratch space at indices 0-3. This layout
/// matches the decoder's carousel in `ProcessLzRuns` and must not be
/// changed without updating both sides.
///
pub const HighRecentOffs = struct {
    offs: [8]i32 = @splat(0),

    pub fn create() HighRecentOffs {
        var r: HighRecentOffs = .{};
        r.offs[4] = @intCast(lz_constants.initial_recent_offset);
        r.offs[5] = @intCast(lz_constants.initial_recent_offset);
        r.offs[6] = @intCast(lz_constants.initial_recent_offset);
        return r;
    }
};

/// Intermediate LZ encoding state — holds the six output streams
/// (literals, delta-literals, tokens, u8 offsets, u32 offsets,
/// literal run lengths, overflow lengths).
pub const HighStreamWriter = struct {
    literals_start: [*]u8,
    literals: [*]u8,

    delta_literals_start: [*]u8,
    delta_literals: [*]u8,

    tokens_start: [*]u8,
    tokens: [*]u8,

    near_offsets_start: [*]u8,
    near_offsets: [*]u8,

    // The High stream writer always allocates 4-byte-aligned regions
    // for the u32 streams (see `high_encoder.initializeStreamWriter`),
    // so default-aligned `[*]u32` is safe and keeps the offset encoder
    // signatures clean.
    far_offsets_start: [*]u32,
    far_offsets: [*]u32,

    literal_run_lengths_start: [*]u8,
    literal_run_lengths: [*]u8,

    overflow_lengths_start: [*]u32,
    overflow_lengths: [*]u32,

    src_len: i32,
    src_ptr: [*]const u8,
    recent0: i32,
    encode_flags: i32,
};

/// A single token in the parsed LZ sequence.
pub const Token = struct {
    recent_offset0: i32,
    lit_len: i32,
    match_len: i32,
    offset: i32,
};

/// Growable token array.
pub const TokenArray = struct {
    data: [*]Token,
    size: usize,
    capacity: usize,
};

/// Token array exported from the optimal parser for two-phase compression.
pub const ExportedTokens = struct {
    tokens: []Token,
    count: usize,
    chunk_type: i32,
};

/// Optimal-parser state (one per grid cell).
pub const State = struct {
    best_bit_count: i32 = 0,
    recent_offs0: i32 = 0,
    recent_offs1: i32 = 0,
    recent_offs2: i32 = 0,
    match_len: i32 = 0,
    lit_len: i32 = 0,
    /// Packed recent-match-after-literals descriptor. 0 = none.
    /// Low byte = literal count (1 or 2), upper bytes = match length (value >> 8).
    /// Used by the DP parser to represent a "match recent0 after N literals" shortcut.
    quick_recent_match_len_lit_len: i32 = 0,
    prev_state: i32 = 0,

    pub fn init(self: *State) void {
        self.best_bit_count = 0;
        self.recent_offs0 = @intCast(lz_constants.initial_recent_offset);
        self.recent_offs1 = @intCast(lz_constants.initial_recent_offset);
        self.recent_offs2 = @intCast(lz_constants.initial_recent_offset);
        self.match_len = 0;
        self.lit_len = 0;
        self.prev_state = 0;
        self.quick_recent_match_len_lit_len = 0;
    }

    pub inline fn getRecentOffs(self: *const State, idx: u2) i32 {
        return switch (idx) {
            0 => self.recent_offs0,
            1 => self.recent_offs1,
            2 => self.recent_offs2,
            else => unreachable,
        };
    }

    pub inline fn setRecentOffs(self: *State, idx: u2, value: i32) void {
        switch (idx) {
            0 => self.recent_offs0 = value,
            1 => self.recent_offs1 = value,
            2 => self.recent_offs2 = value,
            else => unreachable,
        }
    }
};

/// Cost model built from running statistics.
pub const CostModel = struct {
    chunk_type: i32,
    sub_or_copy_mask: i32,
    lit_cost: [256]u32,
    token_cost: [256]u32,
    offs_encode_type: i32,
    offs_cost: [256]u32,
    offs_lo_cost: [256]u32,
    match_len_cost: [256]u32,

    // Decode-cost penalties (in 32nds of a bit, 0 = disabled).
    decode_cost_per_token: i32,
    decode_cost_small_offset: i32,
    decode_cost_short_match: i32,
};

/// Running compression statistics (histograms for each stream).
pub const Stats = struct {
    lit_raw: ByteHistogram = .{},
    lit_sub: ByteHistogram = .{},
    token_histo: ByteHistogram = .{},
    match_len_histo: ByteHistogram = .{},
    offs_encode_type: i32 = 0,
    offs_histo: ByteHistogram = .{},
    offs_lo_histo: ByteHistogram = .{},
};

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "HighRecentOffs.create populates the active 3 entries" {
    const r = HighRecentOffs.create();
    const init: i32 = @intCast(lz_constants.initial_recent_offset);
    try testing.expectEqual(init, r.offs[4]);
    try testing.expectEqual(init, r.offs[5]);
    try testing.expectEqual(init, r.offs[6]);
    // Scratch region 0-3 + the 7th slot stay zero.
    try testing.expectEqual(@as(i32, 0), r.offs[0]);
    try testing.expectEqual(@as(i32, 0), r.offs[7]);
}

test "State.init resets to initial recent offsets" {
    var s: State = .{};
    s.init();
    const init: i32 = @intCast(lz_constants.initial_recent_offset);
    try testing.expectEqual(init, s.recent_offs0);
    try testing.expectEqual(init, s.recent_offs1);
    try testing.expectEqual(init, s.recent_offs2);
}

test "State.getRecentOffs / setRecentOffs round-trip" {
    var s: State = .{};
    s.init();
    s.setRecentOffs(0, 42);
    s.setRecentOffs(1, 1234);
    s.setRecentOffs(2, 65536);
    try testing.expectEqual(@as(i32, 42), s.getRecentOffs(0));
    try testing.expectEqual(@as(i32, 1234), s.getRecentOffs(1));
    try testing.expectEqual(@as(i32, 65536), s.getRecentOffs(2));
}
