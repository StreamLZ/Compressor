//! tANS (tabled asymmetric numeral system) encoder — 5-state interleaved.
//! Used by: Fast and High codecs
//!
//! Produces a
//! bit stream that `decode/tans_decoder.zig` can decode.
//!
//! Top-level entry: `encodeArrayU8Tans`, which:
//!   1. Temporarily subtracts the last 5 source bytes from the histogram
//!      (they are stored as initial states, not table-encoded).
//!   2. Normalizes the histogram so weights sum to L = 2^logTableBits
//!      via a max-heap greedy adjustment.
//!   3. Builds the 256-entry encoding table (`TansEncEntry`) with a 2048-
//!      entry `next_state` payload via 4-way interleaved state distribution.
//!   4. Computes exact forward/backward bit counts by dry-running the state
//!      machine so buffers can be sized precisely.
//!   5. Encodes the symbol stream via 5 interleaved states, with the first
//!      5 rounds writing to a forward bit writer and the next 5 writing
//!      to a backward bit writer (this alternates throughout).
//!   6. Writes a compact table header via `encodeTable` (sparse or
//!      Golomb-Rice coded) and stitches it to the bit streams.
//!
//! Hot-loop design:
//!   * The encode loop processes 10 symbols per iteration (5 forward, 5
//!     backward) so the state variables stay in registers.
//!   * Table lookup is a single indexed load from a 256-entry
//!     `TansEncEntry` array; each entry holds a `next_state` pointer,
//!     a threshold, and a bit count — all fitting in 16 bytes.
//!   * The hot loop avoids branches on state selection (fixed position
//!     in the 10-round cycle tells us which state to use).

const std = @import("std");
const hist_mod = @import("ByteHistogram.zig");
const bw_mod = @import("../io/bit_writer.zig");
const cost_coeffs = @import("cost_coefficients.zig");

const ByteHistogram = hist_mod.ByteHistogram;
const BitWriter64Forward = bw_mod.BitWriter64Forward;
const BitWriter64Backward = bw_mod.BitWriter64Backward;

pub const EncodeError = error{
    TansNotBeneficial,
    TooFewSymbols,
    DestinationTooSmall,
    BadParameters,
} || std.mem.Allocator.Error;

// ────────────────────────────────────────────────────────────
//  Constants + small helpers
// ────────────────────────────────────────────────────────────

/// Approximation table for `log(1 + 1/value)` used by the normalization heap
/// when we want to *increase* a weight by one. Indexed by the current weight.
const log_factor_up_table: [32]f32 = .{
    0.000000, 0.693147, 0.405465, 0.287682, 0.223144, 0.182322, 0.154151, 0.133531,
    0.117783, 0.105361, 0.095310, 0.087011, 0.080043, 0.074108, 0.068993, 0.064539,
    0.060625, 0.057158, 0.054067, 0.051293, 0.048790, 0.046520, 0.044452, 0.042560,
    0.040822, 0.039221, 0.037740, 0.036368, 0.035091, 0.033902, 0.032790, 0.031749,
};

/// Approximation table for `log(1 - 1/value)` — the analog for decrementing.
const log_factor_down_table: [32]f32 = .{
    0.000000,  0.000000,  -0.693147, -0.405465, -0.287682, -0.223144, -0.182322, -0.154151,
    -0.133531, -0.117783, -0.105361, -0.095310, -0.087011, -0.080043, -0.074108, -0.068993,
    -0.064539, -0.060625, -0.057158, -0.054067, -0.051293, -0.048790, -0.046520, -0.044452,
    -0.042560, -0.040822, -0.039221, -0.037740, -0.036368, -0.035091, -0.033902, -0.032790,
};

inline fn tansGetLogFactorUp(value: u32) f32 {
    if (value >= 32) {
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(value));
        return inv - inv * inv * 0.5;
    }
    return log_factor_up_table[value];
}

inline fn tansGetLogFactorDown(value: u32) f32 {
    if (value >= 32) {
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(value));
        return -inv - inv * inv * 0.5;
    }
    return log_factor_down_table[value];
}

/// `floor(v)` with rounding up when `v * v > u * (u + 1)`.
inline fn doubleToUintRoundPow2(v: f64) u32 {
    const u: u32 = @intFromFloat(v);
    const uf: f64 = @floatFromInt(u);
    return if (v * v > uf * (uf + 1.0)) u + 1 else u;
}

/// `log2(v)` rounded to the nearest integer based on geometric midpoint.
inline fn ilog2Round(v: u32) u32 {
    if (v == 0) return 0;
    const bsr: u32 = 31 - @clz(v);
    const lower: u32 = @as(u32, 1) << @intCast(bsr);
    const upper: u32 = lower << 1;
    return if (v - lower >= upper - v) bsr + 1 else bsr;
}

// ────────────────────────────────────────────────────────────
//  Encoding table data structures
// ────────────────────────────────────────────────────────────

/// Per-symbol encoding entry. Lookup: the successor state for the current
/// `state` (with `num_bits` or `num_bits + 1` bits consumed) lives at
/// `te_data[base_offset + (state >> nb)]`. `base_offset` may be negative
/// when the effective base is before the buffer — the minimum accessed
/// index is always within `[0, L)` by construction.
pub const TansEncEntry = extern struct {
    base_offset: i32,
    thres: u16,
    num_bits: u8,
    _pad: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(TansEncEntry) == 8);
}

// ────────────────────────────────────────────────────────────
//  Max heap for normalization (inline, HeapEntry-specialized)
// ────────────────────────────────────────────────────────────

const HeapEntry = extern struct {
    score: f32,
    index: i32,
};

inline fn heapLess(a: HeapEntry, b: HeapEntry) bool {
    return a.score < b.score;
}

fn heapMake(heap: []HeapEntry) void {
    const n: usize = heap.len;
    if (n < 2) return;
    var half: usize = n / 2;
    while (half > 0) {
        half -= 1;
        var t: usize = half;
        while (true) {
            var u: usize = 2 * t + 1;
            if (u >= n) break;
            if (u + 1 < n and heapLess(heap[u], heap[u + 1])) u += 1;
            if (heapLess(heap[u], heap[t])) break;
            const tmp = heap[t];
            heap[t] = heap[u];
            heap[u] = tmp;
            t = u;
        }
    }
}

/// Push: sift the last element at `heap[end-1]` upward.
fn heapPush(heap: []HeapEntry) void {
    var t: usize = heap.len;
    if (t == 0) return;
    t -= 1;
    while (t > 0) {
        const u: usize = (t - 1) >> 1;
        if (!heapLess(heap[u], heap[t])) break;
        const tmp = heap[t];
        heap[t] = heap[u];
        heap[u] = tmp;
        t = u;
    }
}

/// Pop the max element at heap[0]. Logical size shrinks by one; caller
/// must resize the slice.
fn heapPop(heap: []HeapEntry) void {
    const n: usize = heap.len;
    if (n == 0) return;
    var t: usize = 0;
    while (true) {
        const u: usize = 2 * t + 1;
        if (u >= n) break;
        var child = u;
        if (u + 1 < n and heapLess(heap[u], heap[u + 1])) child = u + 1;
        heap[t] = heap[child];
        t = child;
    }
    if (t < n - 1) {
        heap[t] = heap[n - 1];
        while (t > 0) {
            const u: usize = (t - 1) >> 1;
            if (!heapLess(heap[u], heap[t])) break;
            const tmp = heap[t];
            heap[t] = heap[u];
            heap[u] = tmp;
            t = u;
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Normalize histogram counts to sum to L = 2^log_table_bits
// ────────────────────────────────────────────────────────────

/// Fills `weights[0..weights_size]` with normalized counts (summing to `L`).
/// `histo_sum` is the count total over `weights_size` symbols. Returns the
/// number of used symbols (weights > 0).
pub fn tansNormalizeCounts(
    weights: []u32,
    L: u32,
    histo: *const ByteHistogram,
    histo_sum: u32,
    weights_size: usize,
) u32 {
    var syms_used: u32 = 0;
    const multiplier: f64 = @as(f64, @floatFromInt(L)) / @as(f64, @floatFromInt(histo_sum));
    var weight_sum: u32 = 0;
    for (0..weights_size) |i| {
        const h: u32 = histo.count[i];
        var u: u32 = 0;
        if (h != 0) {
            u = doubleToUintRoundPow2(@as(f64, @floatFromInt(h)) * multiplier);
            weight_sum += u;
            syms_used += 1;
        }
        weights[i] = u;
    }
    for (weights_size..weights.len) |i| weights[i] = 0;
    if (weight_sum == L) return syms_used;

    var heap_buf: [256]HeapEntry = undefined;
    var heap_len: usize = 0;
    const diff_i64: i64 = @as(i64, L) - @as(i64, weight_sum);

    if (diff_i64 < 0) {
        // Need to decrement weights that are > 1.
        for (0..weights_size) |i| {
            if (weights[i] > 1) {
                heap_buf[heap_len] = .{
                    .index = @intCast(i),
                    .score = @as(f32, @floatFromInt(histo.count[i])) *
                        tansGetLogFactorDown(weights[i]),
                };
                heap_len += 1;
            }
        }
    } else {
        // Need to increment weights that are > 0.
        for (0..weights_size) |i| {
            if (histo.count[i] != 0) {
                heap_buf[heap_len] = .{
                    .index = @intCast(i),
                    .score = @as(f32, @floatFromInt(histo.count[i])) *
                        tansGetLogFactorUp(weights[i]),
                };
                heap_len += 1;
            }
        }
    }
    heapMake(heap_buf[0..heap_len]);

    var diff = diff_i64;
    if (diff < 0) {
        while (diff != 0) : (diff += 1) {
            std.debug.assert(heap_len > 0);
            const index: usize = @intCast(heap_buf[0].index);
            heapPop(heap_buf[0..heap_len]);
            heap_len -= 1;
            weights[index] -= 1;
            if (weights[index] > 1) {
                heap_buf[heap_len] = .{
                    .index = @intCast(index),
                    .score = @as(f32, @floatFromInt(histo.count[index])) *
                        tansGetLogFactorDown(weights[index]),
                };
                heap_len += 1;
                heapPush(heap_buf[0..heap_len]);
            }
        }
    } else {
        while (diff != 0) : (diff -= 1) {
            std.debug.assert(heap_len > 0);
            const index: usize = @intCast(heap_buf[0].index);
            heapPop(heap_buf[0..heap_len]);
            heap_len -= 1;
            weights[index] += 1;
            heap_buf[heap_len] = .{
                .index = @intCast(index),
                .score = @as(f32, @floatFromInt(histo.count[index])) *
                    tansGetLogFactorUp(weights[index]),
            };
            heap_len += 1;
            heapPush(heap_buf[0..heap_len]);
        }
    }
    return syms_used;
}

// ────────────────────────────────────────────────────────────
//  Build encoding table (4-way interleaved)
// ────────────────────────────────────────────────────────────

/// Populates `te[0..256]` and `te_data[0..L]` from the normalized `weights`.
/// Weight-1 symbols live at the
/// tail of te_data, multi-weight symbols are distributed across 4 pointer
/// tracks so consecutive state transitions land on different lanes.
pub fn tansInitTable(
    te: *[256]TansEncEntry,
    te_data: []u16,
    weights: []const u32,
    weights_size: usize,
    log_table_bits: u32,
) void {
    std.debug.assert(weights_size <= 256);
    const L: u32 = @as(u32, 1) << @intCast(log_table_bits);
    std.debug.assert(te_data.len >= L);

    // Count weight-1 symbols.
    var ones: u32 = 0;
    for (0..weights_size) |i| {
        if (weights[i] == 1) ones += 1;
    }

    const slots_left: u32 = L - ones;
    const sa: u32 = slots_left >> 2;
    var pointers: [4]u32 = .{0} ** 4;
    var sb: u32 = sa + (if ((slots_left & 3) > 0) @as(u32, 1) else 0);
    pointers[1] = sb;
    sb += sa + (if ((slots_left & 3) > 1) @as(u32, 1) else 0);
    pointers[2] = sb;
    sb += sa + (if ((slots_left & 3) > 2) @as(u32, 1) else 0);
    pointers[3] = sb;

    // Pointer where weight-1 entries are placed (after the slots_left area).
    var ones_ptr: usize = slots_left;

    var weights_sum: i32 = 0;

    for (0..weights_size) |i| {
        const w: u32 = weights[i];
        if (w == 0) {
            te[i].base_offset = 0;
            te[i].thres = 0;
            te[i].num_bits = 0;
            continue;
        }
        if (w == 1) {
            te[i].num_bits = @intCast(log_table_bits);
            te[i].thres = @intCast(2 * L);
            // The weight-1 entry has only one state value. When encoding,
            // we compute state_high = state >> log_table_bits. Since the
            // encoder's state is always in [L, 2L), state_high is exactly 1.
            // So we set base_offset = ones_ptr - 1 and store the next state
            // at te_data[ones_ptr]; the lookup `te_data[base + 1]` lands
            // on the right slot.
            te_data[ones_ptr] = @intCast(L + @as(u32, @intCast(ones_ptr)));
            te[i].base_offset = @intCast(@as(i64, @intCast(ones_ptr)) - 1);
            ones_ptr += 1;
        } else {
            const w_minus_1: u32 = w - 1;
            const nb_high: u32 = 31 - @clz(w_minus_1) + 1;
            te[i].num_bits = @intCast(log_table_bits - nb_high);
            te[i].thres = @intCast((2 * w) << @intCast(log_table_bits - nb_high));
            te[i].base_offset = @as(i32, @intCast(weights_sum)) - @as(i32, @intCast(w));

            var j: usize = 0;
            var ptr_cursor: i32 = @intCast(weights_sum);
            while (j < 4) : (j += 1) {
                const p_start: i32 = @intCast(pointers[j]);
                const y_signed: i32 = @as(i32, @intCast(w)) + ((@as(i32, @intCast(weights_sum)) - @as(i32, @intCast(j)) - 1) & 3);
                const y: i32 = y_signed >> 2;
                var y_left: i32 = y;
                var p: i32 = p_start;
                while (y_left > 0) : (y_left -= 1) {
                    const slot_idx: usize = @intCast(ptr_cursor);
                    te_data[slot_idx] = @intCast(p + @as(i32, @intCast(L)));
                    ptr_cursor += 1;
                    p += 1;
                }
                pointers[j] = @intCast(p);
            }
            weights_sum += @intCast(w);
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Encode bit-count dry run
// ────────────────────────────────────────────────────────────

/// Helper: look up the next state given a current state and the encoding
/// table. Centralizes the base_offset + state_high arithmetic.
inline fn nextState(te_data: []const u16, entry: *const TansEncEntry, state: u32) struct { u32, u32 } {
    const num_bits_base: u32 = entry.num_bits;
    const above_thres: u32 = if (state >= entry.thres) 1 else 0;
    const nb: u32 = num_bits_base + above_thres;
    const state_high: u32 = state >> @intCast(nb);
    const idx_signed: i64 = @as(i64, entry.base_offset) + @as(i64, state_high);
    std.debug.assert(idx_signed >= 0 and idx_signed < @as(i64, @intCast(te_data.len)));
    const idx: usize = @intCast(idx_signed);
    const new_state: u32 = te_data[idx];
    return .{ new_state, nb };
}

/// Computes the exact number of forward and backward bits the 5-state
/// encoder will emit for `src` (not counting the initial-state payloads).
/// The encoder's main loop processes 10 symbols per iteration (5 forward,
/// 5 backward); the initial remainder `(src.len - 5) % 10` is handled as
/// a tail.
pub fn tansGetEncodedBitCount(
    te: *const [256]TansEncEntry,
    te_data: []const u16,
    src: []const u8,
    log_table_bits: u32,
) struct { forward: u32, backward: u32 } {
    std.debug.assert(src.len >= 5);
    const L: u32 = @as(u32, 1) << @intCast(log_table_bits);

    // Initial states = last 5 source bytes (with the L-bit set).
    const src_end_idx: usize = src.len - 5;
    var state0: u32 = @as(u32, src[src_end_idx + 0]) | L;
    var state1: u32 = @as(u32, src[src_end_idx + 1]) | L;
    var state2: u32 = @as(u32, src[src_end_idx + 2]) | L;
    var state3: u32 = @as(u32, src[src_end_idx + 3]) | L;
    var state4: u32 = @as(u32, src[src_end_idx + 4]) | L;

    var forward_bits: u32 = 0;
    var backward_bits: u32 = 0;

    const body_len: usize = src_end_idx; // symbols to encode via the table
    const rounds: usize = body_len / 10;
    const remainder: usize = body_len % 10;

    var read_idx: usize = src_end_idx; // points one past the last written position
    if (read_idx == 0) return .{ .forward = forward_bits + 2 * log_table_bits, .backward = backward_bits + 3 * log_table_bits };
    read_idx -= 1; // now points at the last symbol to consume

    // Remainder: positions 0..9 in the 10-symbol cycle [4,3,2,1,0,4,3,2,1,0].
    // Remainder R enters the cycle at position (10 - R) and processes
    // positions (10 - R)..9.
    var ri: usize = 10 - remainder;
    while (ri < 10) : (ri += 1) {
        const sym: u8 = src[read_idx];
        if (read_idx > 0) read_idx -= 1;
        const entry = &te[sym];
        const si: usize = ri % 5;
        var sv: u32 = undefined;
        switch (si) {
            0 => sv = state4,
            1 => sv = state3,
            2 => sv = state2,
            3 => sv = state1,
            else => sv = state0,
        }
        const ns_nb = nextState(te_data, entry, sv);
        if (ri < 5) forward_bits += ns_nb[1] else backward_bits += ns_nb[1];
        switch (si) {
            0 => state4 = ns_nb[0],
            1 => state3 = ns_nb[0],
            2 => state2 = ns_nb[0],
            3 => state1 = ns_nb[0],
            else => state0 = ns_nb[0],
        }
    }

    // Body: `rounds` iterations of the full 10-symbol cycle.
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        inline for (.{ 4, 3, 2, 1, 0 }) |idx| {
            const sym = src[read_idx];
            if (read_idx > 0) read_idx -= 1;
            var sv: u32 = undefined;
            switch (idx) {
                0 => sv = state0,
                1 => sv = state1,
                2 => sv = state2,
                3 => sv = state3,
                4 => sv = state4,
                else => unreachable,
            }
            const entry = &te[sym];
            const ns_nb = nextState(te_data, entry, sv);
            forward_bits += ns_nb[1];
            switch (idx) {
                0 => state0 = ns_nb[0],
                1 => state1 = ns_nb[0],
                2 => state2 = ns_nb[0],
                3 => state3 = ns_nb[0],
                4 => state4 = ns_nb[0],
                else => unreachable,
            }
        }
        inline for (.{ 4, 3, 2, 1, 0 }) |idx| {
            const sym = src[read_idx];
            if (read_idx > 0) read_idx -= 1;
            var sv: u32 = undefined;
            switch (idx) {
                0 => sv = state0,
                1 => sv = state1,
                2 => sv = state2,
                3 => sv = state3,
                4 => sv = state4,
                else => unreachable,
            }
            const entry = &te[sym];
            const ns_nb = nextState(te_data, entry, sv);
            backward_bits += ns_nb[1];
            switch (idx) {
                0 => state0 = ns_nb[0],
                1 => state1 = ns_nb[0],
                2 => state2 = ns_nb[0],
                3 => state3 = ns_nb[0],
                4 => state4 = ns_nb[0],
                else => unreachable,
            }
        }
    }

    return .{
        // state3 + state1 are written to forward at the end (+2 * log_table_bits)
        .forward = forward_bits + 2 * log_table_bits,
        // state4 + state2 + state0 are written to backward (+3 * log_table_bits)
        .backward = backward_bits + 3 * log_table_bits,
    };
}

// ────────────────────────────────────────────────────────────
//  Encode hot loop (5-state interleaved)
// ────────────────────────────────────────────────────────────

/// Encodes `src` using the 5-state interleaved encoder. Writes forward
/// bit stream to `dst[0..]` growing up and backward bit stream to
/// `dst_end` growing down, then stitches them into a single payload at
/// `dst` with the BACKWARD stream FIRST followed by the FORWARD stream
/// (the decoder expects that order).
///
/// Returns the pointer one past the final byte written to `dst`.
pub fn tansEncodeBytes(
    dst: [*]u8,
    dst_end: [*]u8,
    te: *const [256]TansEncEntry,
    te_data: []const u16,
    src: []const u8,
    log_table_bits: u32,
    forward_bits_pad: u32,
    backward_bits_pad: u32,
) TansEncodeBytesResult {
    var forward = BitWriter64Forward.init(dst);
    var backward = BitWriter64Backward.init(dst_end);

    if ((forward_bits_pad & 7) != 0) {
        const pad: u5 = @intCast(8 - (forward_bits_pad & 7));
        forward.writeNoFlush(0, pad);
    }
    if ((backward_bits_pad & 7) != 0) {
        const pad: u5 = @intCast(8 - (backward_bits_pad & 7));
        backward.writeNoFlush(0, pad);
    }

    const L: u32 = @as(u32, 1) << @intCast(log_table_bits);
    const src_end_idx: usize = src.len - 5;
    var state0: u32 = @as(u32, src[src_end_idx + 0]) | L;
    var state1: u32 = @as(u32, src[src_end_idx + 1]) | L;
    var state2: u32 = @as(u32, src[src_end_idx + 2]) | L;
    var state3: u32 = @as(u32, src[src_end_idx + 3]) | L;
    var state4: u32 = @as(u32, src[src_end_idx + 4]) | L;

    const body_len: usize = src_end_idx;
    const rounds: usize = body_len / 10;
    const remainder: usize = body_len % 10;

    var read_idx_plus1: usize = src_end_idx;
    if (read_idx_plus1 > 0) read_idx_plus1 -= 1;

    // Process remainder symbols first.
    var ri: usize = 10 - remainder;
    while (ri < 10) : (ri += 1) {
        const sym: u8 = src[read_idx_plus1];
        if (read_idx_plus1 > 0) read_idx_plus1 -= 1;
        const entry = &te[sym];
        const si: usize = ri % 5;
        var sv: u32 = undefined;
        switch (si) {
            0 => sv = state4,
            1 => sv = state3,
            2 => sv = state2,
            3 => sv = state1,
            else => sv = state0,
        }
        const ns_nb = nextState(te_data, entry, sv);
        const nb_u5: u5 = @intCast(ns_nb[1]);
        const mask: u32 = if (ns_nb[1] >= 32) 0xFFFF_FFFF else ((@as(u32, 1) << nb_u5) - 1);
        const bits: u32 = sv & mask;
        if (ri < 5) forward.writeNoFlush(bits, nb_u5) else backward.writeNoFlush(bits, nb_u5);
        switch (si) {
            0 => state4 = ns_nb[0],
            1 => state3 = ns_nb[0],
            2 => state2 = ns_nb[0],
            3 => state1 = ns_nb[0],
            else => state0 = ns_nb[0],
        }
    }
    if (remainder > 0) {
        backward.flush();
        forward.flush();
    }

    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        // Forward 5: state4, state3, state2, state1, state0
        inline for (.{ 4, 3, 2, 1, 0 }) |idx| {
            const sym = src[read_idx_plus1];
            if (read_idx_plus1 > 0) read_idx_plus1 -= 1;
            var sv: u32 = undefined;
            switch (idx) {
                0 => sv = state0,
                1 => sv = state1,
                2 => sv = state2,
                3 => sv = state3,
                4 => sv = state4,
                else => unreachable,
            }
            const entry = &te[sym];
            const ns_nb = nextState(te_data, entry, sv);
            const nb_u5: u5 = @intCast(ns_nb[1]);
            const mask: u32 = if (ns_nb[1] >= 32) 0xFFFF_FFFF else ((@as(u32, 1) << nb_u5) - 1);
            forward.writeNoFlush(sv & mask, nb_u5);
            switch (idx) {
                0 => state0 = ns_nb[0],
                1 => state1 = ns_nb[0],
                2 => state2 = ns_nb[0],
                3 => state3 = ns_nb[0],
                4 => state4 = ns_nb[0],
                else => unreachable,
            }
        }
        // Backward 5: state4, state3, state2, state1, state0
        inline for (.{ 4, 3, 2, 1, 0 }) |idx| {
            const sym = src[read_idx_plus1];
            if (read_idx_plus1 > 0) read_idx_plus1 -= 1;
            var sv: u32 = undefined;
            switch (idx) {
                0 => sv = state0,
                1 => sv = state1,
                2 => sv = state2,
                3 => sv = state3,
                4 => sv = state4,
                else => unreachable,
            }
            const entry = &te[sym];
            const ns_nb = nextState(te_data, entry, sv);
            const nb_u5: u5 = @intCast(ns_nb[1]);
            const mask: u32 = if (ns_nb[1] >= 32) 0xFFFF_FFFF else ((@as(u32, 1) << nb_u5) - 1);
            backward.writeNoFlush(sv & mask, nb_u5);
            switch (idx) {
                0 => state0 = ns_nb[0],
                1 => state1 = ns_nb[0],
                2 => state2 = ns_nb[0],
                3 => state3 = ns_nb[0],
                4 => state4 = ns_nb[0],
                else => unreachable,
            }
        }
        backward.flush();
        forward.flush();
    }
    // Write final states.
    const mask_L: u32 = L - 1;
    const ltb_u5: u5 = @intCast(log_table_bits);
    backward.writeNoFlush(state4 & mask_L, ltb_u5);
    backward.writeNoFlush(state2 & mask_L, ltb_u5);
    backward.writeNoFlush(state0 & mask_L, ltb_u5);
    forward.writeNoFlush(state3 & mask_L, ltb_u5);
    forward.writeNoFlush(state1 & mask_L, ltb_u5);
    backward.flush();
    forward.flush();

    std.debug.assert(backward.pos == 63);
    std.debug.assert(forward.pos == 63);

    const forward_bytes: usize = @intFromPtr(forward.position) - @intFromPtr(dst);
    const backward_bytes: usize = @intFromPtr(dst_end) - @intFromPtr(backward.position);

    // Caller is responsible for reading the two streams from `dst[0..forward_bytes]`
    // and `backward.position[0..backward_bytes]` and assembling them in the
    // correct order (backward first, then forward — the decoder reads the
    // backward stream from the start of the output).
    return .{
        .forward_bytes = forward_bytes,
        .backward_bytes = backward_bytes,
        .forward_start = dst,
        .backward_start = backward.position,
    };
}

pub const TansEncodeBytesResult = struct {
    forward_bytes: usize,
    backward_bytes: usize,
    forward_start: [*]const u8,
    backward_start: [*]const u8,
};

// ────────────────────────────────────────────────────────────
//  Table encoding — sparse and Golomb-Rice paths
// ────────────────────────────────────────────────────────────

/// Encode symbol ranges (runs of nonzero vs zero weights) for table
/// serialization. `ranges` is a sequence of alternating run lengths:
/// the first entry is the number of leading zeros (starting range count),
/// then nonzero-run length, zero-run length, etc. The output arrays
/// (`rice`, `bits`, `bitcount`) hold the Golomb-Rice encoding of the
/// inner runs.
fn encodeSymRange(
    rice: []u8,
    bits: []u8,
    bitcount: []u8,
    used_syms: u32,
    range: []const i32,
    numrange: usize,
) usize {
    if (used_syms >= 256) return 0;
    var which: i32 = if (range[0] == 0) 1 else 0;
    const range_offset: usize = if (range[0] == 0) 1 else 0;
    const num: usize = @intCast(@as(i32, @intCast(if (range[0] != 0) @as(i32, 1) else @as(i32, 0))) + 2 * @as(i32, @intCast((numrange - 3) / 2)));

    for (0..num) |i| {
        var v: i32 = range[range_offset + i];
        const ebit: i32 = @bitCast(~(@as(u32, @bitCast(which))) & 1);
        which += 1;
        v += (@as(i32, 1) << @intCast(ebit)) - 1;
        const vshift: i32 = v >> @intCast(ebit);
        const nb_u32: u32 = @as(u32, 31 - @clz(@as(u32, @intCast(vshift))));
        rice[i] = @intCast(nb_u32);
        const nb_total: u32 = nb_u32 + @as(u32, @intCast(ebit));
        const mask: u32 = (@as(u32, 1) << @intCast(nb_total)) - 1;
        bits[i] = @intCast(@as(u32, @intCast(v)) & mask);
        bitcount[i] = @intCast(nb_total);
    }
    return num;
}

fn writeNumSymRange(bw: *BitWriter64Forward, num_symrange: usize, used_syms: usize) void {
    if (used_syms == 256) return;
    const x: usize = @min(used_syms, 257 - used_syms);
    const nb: u32 = 32 - @clz(@as(u32, @intCast(2 * x - 1)));
    const base: i32 = @as(i32, @intCast(@as(u32, 1) << @intCast(nb))) - @as(i32, @intCast(2 * x));
    if (@as(i32, @intCast(num_symrange)) >= base) {
        bw.write(@intCast(@as(i32, @intCast(num_symrange)) + base), @intCast(nb));
    } else {
        bw.write(@intCast(num_symrange), @intCast(nb - 1));
    }
}

fn writeManyRiceCodes(bw: *BitWriter64Forward, data: []const u8) void {
    for (data) |d| {
        var v: u32 = d;
        while (v >= 24) : (v -= 24) bw.write(0, 24);
        bw.write(1, @intCast(v + 1));
    }
}

fn writeSymRangeLowBits(bw: *BitWriter64Forward, data: []const u8, bitcount: []const u8) void {
    for (data, bitcount) |d, n| {
        if (n == 0) continue;
        bw.write(d, @intCast(n));
    }
}

fn getBitsForArraysOfRice(arr: []const u32, k: u5) u32 {
    var result: u32 = 0;
    for (arr, 0..) |v, i| {
        if (v != 0) {
            const shifted: u32 = (@as(u32, @intCast(i)) >> k) + 1;
            const log: u32 = 31 - @clz(shifted);
            result += v * (@as(u32, k) + 1 + 2 * log);
        }
    }
    return result;
}

/// Encodes the frequency table. Picks the sparse format for ≤7 symbols
/// and the Golomb-Rice format otherwise. Writes to `bw`.
pub fn tansEncodeTable(
    bw: *BitWriter64Forward,
    log_table_bits: u32,
    lookup: []const u32,
    histo_size: usize,
    used_symbols: u32,
) void {
    if (used_symbols <= 7) {
        bw.writeNoFlush(0, 1);
        bw.writeNoFlush(@intCast(used_symbols - 2), 3);

        // Collect used symbols with their counts, sorted by symbol id.
        var sympos: [8]u32 = @splat(0);
        var sympos_len: usize = 0;
        for (0..histo_size) |i| {
            if (lookup[i] != 0) {
                sympos[sympos_len] = @as(u32, @intCast(i)) | (lookup[i] << 16);
                sympos_len += 1;
            }
        }
        std.sort.pdq(u32, sympos[0..sympos_len], {}, std.sort.asc(u32));

        // Compute delta-bits width — the smallest `nb` such that all
        // (weight_i - weight_{i-1}) differences fit in `nb` bits.
        var delta_bits: u32 = 1;
        {
            var p: u32 = 0;
            var i: usize = 0;
            while (i < used_symbols - 1) : (i += 1) {
                const sv: u32 = sympos[i] >> 16;
                const diff: u32 = sv - p;
                const nb: u32 = if (diff != 0) (31 - @clz(diff)) + 1 else 0;
                if (nb > delta_bits) delta_bits = nb;
                p = sv;
            }
        }
        const bps: u32 = ilog2Round(log_table_bits) + 1;
        bw.writeNoFlush(delta_bits, @intCast(bps));

        // Write (count-1) delta/symbol pairs.
        {
            var p: u32 = 0;
            var i: usize = 0;
            while (i < used_symbols - 1) : (i += 1) {
                const sv: u32 = sympos[i] >> 16;
                const diff: u32 = sv - p;
                const sym_byte: u32 = @as(u32, @intCast(sympos[i] & 0xFF));
                bw.write(diff | (sym_byte << @intCast(delta_bits)), @intCast(delta_bits + 8));
                p = sv;
            }
        }
        // Write the last symbol byte only (its weight is implicit: L - sum).
        bw.write(@as(u32, @intCast(sympos[used_symbols - 1] & 0xFF)), 8);
        return;
    }

    // Golomb-Rice path — used for > 7 symbols. This matches the layout
    // closely. Written in two sub-passes: (1) compute range metadata and
    // weight classification, (2) emit the encoded bits.
    bw.writeNoFlush(1, 1);

    var arr_z: [128]u32 = @splat(0);
    var ranges: [257]i32 = @splat(0);
    var ranges_len: usize = 0;
    var arr_x: [256]i32 = @splat(0);
    var arr_x_count: usize = 0;
    var arr_y: [32]i32 = @splat(0);
    var arr_y_count: usize = 0;
    var arr_w: [256]u8 = @splat(0);
    var sr_rice: [256]u8 = @splat(0);
    var sr_bits: [256]u8 = @splat(0);
    var sr_bitcount: [256]u8 = @splat(0);

    var pos: usize = 0;
    while (pos < histo_size and lookup[pos] == 0) pos += 1;
    ranges[ranges_len] = @intCast(pos);
    ranges_len += 1;

    var average: i32 = 6;
    var used_syms: u32 = 0;
    while (pos < histo_size) {
        const pos_start: usize = pos;
        while (pos < histo_size) {
            const vraw: i32 = @intCast(lookup[pos]);
            if (vraw == 0) break;
            const v: i32 = vraw - 1;
            const avg_div_4: i32 = average >> 2;
            const limit: i32 = 2 * avg_div_4;
            const u: i32 = if (v > limit) v else (2 * (v - avg_div_4)) ^ ((v - avg_div_4) >> 31);
            arr_x[arr_x_count] = u;
            arr_x_count += 1;
            if (u >= 0x80) {
                arr_y[arr_y_count] = u;
                arr_y_count += 1;
            } else {
                arr_z[@intCast(u)] += 1;
            }
            const nlimit: i32 = if (v < limit) v else limit;
            pos += 1;
            used_syms += 1;
            average += nlimit - avg_div_4;
        }
        ranges[ranges_len] = @intCast(pos - pos_start);
        ranges_len += 1;
        const zero_start: usize = pos;
        while (pos < histo_size and lookup[pos] == 0) pos += 1;
        ranges[ranges_len] = @intCast(pos - zero_start);
        ranges_len += 1;
    }
    ranges[ranges_len - 1] += @intCast(256 - pos);

    // Find best Q (Golomb-Rice parameter).
    var best_score: u32 = std.math.maxInt(u32);
    var Q: u5 = 0;
    {
        var tq: u5 = 0;
        while (tq < 8) : (tq += 1) {
            var score: u32 = getBitsForArraysOfRice(&arr_z, tq);
            for (0..arr_y_count) |i| {
                const shifted: u32 = @as(u32, @intCast((arr_y[i] >> @intCast(tq)) + 1));
                const log: u32 = 31 - @clz(shifted);
                score += tq + 2 * log + 1;
            }
            if (score < best_score) {
                best_score = score;
                Q = tq;
            }
        }
    }

    const num_symrange: usize = encodeSymRange(
        &sr_rice,
        &sr_bits,
        &sr_bitcount,
        used_syms,
        &ranges,
        ranges_len,
    );
    bw.writeNoFlush(@intCast((used_syms - 1) + (@as(u32, Q) << 8)), 11);

    writeNumSymRange(bw, num_symrange, @intCast(used_syms));

    // Compute per-entry low bits after Q split.
    for (0..arr_x_count) |i| {
        const x: u32 = @intCast(arr_x[i] + (@as(i32, 1) << Q));
        const nb: u32 = 31 - @clz(x >> Q);
        arr_w[i] = @intCast(nb);
        const mask_bits: u32 = @as(u32, 1) << @intCast(Q + @as(u5, @intCast(nb)));
        arr_x[i] = @intCast(x & (mask_bits - 1));
    }

    writeManyRiceCodes(bw, arr_w[0..arr_x_count]);
    writeManyRiceCodes(bw, sr_rice[0..num_symrange]);
    writeSymRangeLowBits(bw, sr_bits[0..num_symrange], sr_bitcount[0..num_symrange]);

    for (0..arr_x_count) |i| {
        const total: u32 = Q + arr_w[i];
        if (total != 0) {
            bw.write(@intCast(arr_x[i]), @intCast(total));
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Top-level entry
// ────────────────────────────────────────────────────────────

/// Encodes `src` using tANS. On success, returns the number of bytes
/// written to `dst` (NOT including any outer 5-byte chunk header — the
/// caller writes that before/after). On failure (or if tANS is not
/// beneficial), returns `error.TansNotBeneficial`.
///
/// The caller typically wraps the output in a 5-byte non-compact chunk
/// header with `chunkType = 1` (or a 3-byte compact header if small
/// enough). The decoder's `highDecodeBytes` reads that header and
/// dispatches to `highDecodeTans`.
pub fn encodeArrayU8Tans(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    histo: *ByteHistogram,
    speed_tradeoff: f32,
    cost_out: *f32,
) EncodeError!usize {
    if (src.len < 32) return error.TansNotBeneficial;

    // Temporarily subtract last 5 bytes from histogram.
    const src_end_idx: usize = src.len - 5;
    histo.count[src[src_end_idx + 0]] -= 1;
    histo.count[src[src_end_idx + 1]] -= 1;
    histo.count[src[src_end_idx + 2]] -= 1;
    histo.count[src[src_end_idx + 3]] -= 1;
    histo.count[src[src_end_idx + 4]] -= 1;
    defer {
        histo.count[src[src_end_idx + 0]] += 1;
        histo.count[src[src_end_idx + 1]] += 1;
        histo.count[src[src_end_idx + 2]] += 1;
        histo.count[src[src_end_idx + 3]] += 1;
        histo.count[src[src_end_idx + 4]] += 1;
    }

    // Choose log table bits based on source size.
    const raw_log: i32 = @as(i32, @intCast(ilog2Round(@intCast(src.len - 5)))) - 2;
    const clamped: i32 = @max(@min(raw_log, 11), 8);
    const log_table_bits: u32 = @intCast(clamped);

    // Determine used range of the histogram.
    var weights_size: usize = 256;
    while (weights_size > 0 and histo.count[weights_size - 1] == 0) weights_size -= 1;
    if (weights_size == 0) return error.TooFewSymbols;

    var weights: [256]u32 = @splat(0);
    const used_symbols = tansNormalizeCounts(
        &weights,
        @as(u32, 1) << @intCast(log_table_bits),
        histo,
        @intCast(src.len - 5),
        weights_size,
    );
    if (used_symbols <= 1) return error.TooFewSymbols;

    // Speed-adjusted cost estimate. The caller seeds `cost_out.*` with the best-known
    // alternative (typically `memcpy_cost = src.len + 3`); if the speed cost
    // alone already eats the remaining budget, tANS is not worth attempting.
    const src_len_minus_5: usize = src.len - 5;
    const src_len_f: f32 = @floatFromInt(src_len_minus_5);
    const used_sym_f: f32 = @floatFromInt(used_symbols);
    const table_entries_f: f32 = @floatFromInt(@as(u32, 1) << @intCast(log_table_bits));
    const cost: f32 = (cost_coeffs.tans_base +
        src_len_f * cost_coeffs.tans_per_src_byte +
        used_sym_f * cost_coeffs.tans_per_used_symbol +
        table_entries_f * cost_coeffs.tans_per_table_entry) *
        speed_tradeoff + 5;

    const cost_left_f: f32 = cost_out.* - cost;
    // Clamp to i32 range so an `inf` budget (test helpers pass `inf` to
    // mean "always accept") doesn't overflow `@intFromFloat`.
    const max_i32_f: f32 = @floatFromInt(std.math.maxInt(i32));
    const min_i32_f: f32 = @floatFromInt(std.math.minInt(i32));
    const cost_left: i32 = if (cost_left_f >= max_i32_f)
        std.math.maxInt(i32)
    else if (cost_left_f <= min_i32_f)
        std.math.minInt(i32)
    else
        @intFromFloat(cost_left_f);
    if (cost_left < 4) return error.TansNotBeneficial;

    // Emit the table into a scratch buffer. We use a separate scratch so
    // the bit writer's 8-byte overshoot stores don't clobber adjacent data.
    var table_buf: [512]u8 = @splat(0);
    var bw = BitWriter64Forward.init(&table_buf);
    bw.writeNoFlush(log_table_bits - 8, 3);
    tansEncodeTable(&bw, log_table_bits, &weights, weights_size, used_symbols);
    bw.flush();
    const table_final_ptr = bw.getFinalPtr();
    const table_bytes: usize = @intFromPtr(table_final_ptr) - @intFromPtr(&table_buf[0]);

    // Build encoding table.
    var te: [256]TansEncEntry = undefined;
    var te_data: [2048]u16 = undefined;
    tansInitTable(&te, &te_data, &weights, weights_size, log_table_bits);

    // Compute exact bit counts.
    const counts = tansGetEncodedBitCount(&te, &te_data, src, log_table_bits);
    const payload_bytes: usize = bitsUp(counts.forward) + bitsUp(counts.backward);
    if (payload_bytes < 8) return error.TansNotBeneficial;

    const total_size: usize = table_bytes + payload_bytes;
    if (total_size + 8 > dst.len) return error.DestinationTooSmall;
    //
    // both conditions must leave headroom vs the caller's budget.
    if (@as(i32, @intCast(total_size)) >= cost_left) return error.TansNotBeneficial;
    if (@as(f32, @floatFromInt(total_size)) + cost >= cost_out.*) return error.TansNotBeneficial;

    // Encode the body into a scratch buffer sized to the payload plus
    // 48 bytes of slack (16 at each end + 16 for the writers' overshoot
    // gap). Both writers retain ≥ 16 bytes of headroom around their
    // working range so their 8-byte flush stores never collide with
    // each other or the table bytes.
    const body_scratch_size: usize = payload_bytes + 64;
    const body_scratch = try allocator.alloc(u8, body_scratch_size);
    defer allocator.free(body_scratch);
    @memset(body_scratch, 0);

    const fwd_start: [*]u8 = body_scratch[16..].ptr;
    const bwd_end: [*]u8 = body_scratch[body_scratch.len - 16 ..].ptr;
    const body = tansEncodeBytes(
        fwd_start,
        bwd_end,
        &te,
        &te_data,
        src,
        log_table_bits,
        counts.forward,
        counts.backward,
    );
    std.debug.assert(body.forward_bytes + body.backward_bytes == payload_bytes);

    // Assemble: table, then backward stream, then forward stream. The
    // decoder reads the backward stream (= our "backward writer" output)
    // from the START of the payload.
    @memcpy(dst[0..table_bytes], table_buf[0..table_bytes]);
    @memcpy(dst[table_bytes..][0..body.backward_bytes], body.backward_start[0..body.backward_bytes]);
    @memcpy(dst[table_bytes + body.backward_bytes ..][0..body.forward_bytes], body.forward_start[0..body.forward_bytes]);

    // The reported cost is
    // the speed-adjusted overhead plus the actual encoded byte count, so
    // the caller's `cost < memcpyCost` check includes both terms.
    cost_out.* = cost + @as(f32, @floatFromInt(total_size));
    return table_bytes + payload_bytes;
}

inline fn bitsUp(bits: u32) usize {
    return @intCast((bits + 7) >> 3);
}

// ────────────────────────────────────────────────────────────
//  Tests (normalize + init_table — no encode yet)
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "ilog2Round basics" {
    try testing.expectEqual(@as(u32, 0), ilog2Round(0));
    try testing.expectEqual(@as(u32, 0), ilog2Round(1));
    try testing.expectEqual(@as(u32, 1), ilog2Round(2));
    try testing.expectEqual(@as(u32, 2), ilog2Round(3)); // 3 closer to 4 than to 2
    try testing.expectEqual(@as(u32, 2), ilog2Round(4));
    try testing.expectEqual(@as(u32, 3), ilog2Round(8));
}

test "doubleToUintRoundPow2" {
    try testing.expectEqual(@as(u32, 1), doubleToUintRoundPow2(1.0));
    try testing.expectEqual(@as(u32, 2), doubleToUintRoundPow2(1.5));
    try testing.expectEqual(@as(u32, 2), doubleToUintRoundPow2(2.0));
}

test "tansNormalizeCounts sums to L exactly" {
    var histo: ByteHistogram = .{};
    histo.countBytes("aaaabbbccdee");
    const L: u32 = 256;
    var weights: [256]u32 = @splat(0);
    const used = tansNormalizeCounts(&weights, L, &histo, 12, 256);
    try testing.expectEqual(@as(u32, 5), used);
    var sum: u32 = 0;
    for (weights) |w| sum += w;
    try testing.expectEqual(L, sum);
}

test "tansInitTable runs without panicking on a small histogram" {
    var histo: ByteHistogram = .{};
    histo.countBytes("aaaabbbccdee");
    var weights: [256]u32 = @splat(0);
    const L: u32 = 256;
    _ = tansNormalizeCounts(&weights, L, &histo, 12, 256);

    var te: [256]TansEncEntry = undefined;
    var te_data: [2048]u16 = undefined;
    tansInitTable(&te, &te_data, &weights, 256, 8);
}

test "tANS roundtrip: 32 bytes of 'abab' (2-symbol sparse path)" {
    const tans_dec = @import("../decode/tans_decoder.zig");
    var src: [32]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('a' + (i % 2));

    var histo: ByteHistogram = .{};
    histo.countBytes(&src);

    var dst: [512]u8 = @splat(0);
    var tans_cost: f32 = std.math.inf(f32);
    const n = try encodeArrayU8Tans(testing.allocator, &dst, &src, &histo, 1.0, &tans_cost);

    var decoded: [src.len + 16]u8 = @splat(0);
    var scratch: [32 * 1024]u8 align(16) = undefined;
    _ = try tans_dec.highDecodeTans(
        dst[0..].ptr,
        n,
        decoded[0..].ptr,
        src.len,
        scratch[0..].ptr,
        scratch[0..].ptr + scratch.len,
    );
    try testing.expectEqualSlices(u8, &src, decoded[0..src.len]);
}

test "tANS roundtrip: 256 bytes of 'abc' repeating (3-symbol sparse)" {
    const tans_dec = @import("../decode/tans_decoder.zig");
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('a' + (i % 3));

    var histo: ByteHistogram = .{};
    histo.countBytes(&src);

    var dst: [2048]u8 = @splat(0);
    var tans_cost: f32 = std.math.inf(f32);
    const n = try encodeArrayU8Tans(testing.allocator, &dst, &src, &histo, 1.0, &tans_cost);

    var decoded: [src.len + 16]u8 = @splat(0);
    var scratch: [32 * 1024]u8 align(16) = undefined;
    _ = try tans_dec.highDecodeTans(
        dst[0..].ptr,
        n,
        decoded[0..].ptr,
        src.len,
        scratch[0..].ptr,
        scratch[0..].ptr + scratch.len,
    );
    try testing.expectEqualSlices(u8, &src, decoded[0..src.len]);
}

test "tANS roundtrip: 512 bytes of varied English text (Golomb-Rice path)" {
    const tans_dec = @import("../decode/tans_decoder.zig");
    const pattern = "The quick brown fox jumps over the lazy dog. ";
    var src: [512]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = pattern[i % pattern.len];

    var histo: ByteHistogram = .{};
    histo.countBytes(&src);

    var dst: [2048]u8 = @splat(0);
    var tans_cost: f32 = std.math.inf(f32);
    const n = try encodeArrayU8Tans(testing.allocator, &dst, &src, &histo, 1.0, &tans_cost);

    var decoded: [src.len + 16]u8 = @splat(0);
    var scratch: [32 * 1024]u8 align(16) = undefined;
    _ = try tans_dec.highDecodeTans(
        dst[0..].ptr,
        n,
        decoded[0..].ptr,
        src.len,
        scratch[0..].ptr,
        scratch[0..].ptr + scratch.len,
    );
    try testing.expectEqualSlices(u8, &src, decoded[0..src.len]);
}

/// Roundtrip a single byte chunk through the tANS encoder and decoder.
fn tansRoundtripChunk(allocator: std.mem.Allocator, src: []const u8) !void {
    const tans_dec = @import("../decode/tans_decoder.zig");
    var histo: ByteHistogram = .{};
    histo.countBytes(src);

    const dst = try allocator.alloc(u8, src.len + 256);
    defer allocator.free(dst);
    @memset(dst, 0);

    var tans_cost: f32 = std.math.inf(f32);
    const n = try encodeArrayU8Tans(allocator, dst, src, &histo, 1.0, &tans_cost);
    try testing.expect(n > 8);

    const decoded = try allocator.alloc(u8, src.len + 16);
    defer allocator.free(decoded);
    @memset(decoded, 0);

    const scratch = try allocator.alignedAlloc(u8, .@"16", 64 * 1024);
    defer allocator.free(scratch);

    _ = try tans_dec.highDecodeTans(
        dst.ptr,
        n,
        decoded.ptr,
        src.len,
        scratch.ptr,
        scratch.ptr + scratch.len,
    );
    try testing.expectEqualSlices(u8, src, decoded[0..src.len]);
}

test "tANS roundtrip: enwik8 first 64 KB" {
    const allocator = testing.allocator;
    const file = std.fs.cwd().openFile(
        "c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/enwik8.txt",
        .{},
    ) catch return; // Skip if asset missing.
    defer file.close();

    const src = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(src);
    const read = try file.readAll(src);
    if (read != src.len) return error.SkipZigTest;

    try tansRoundtripChunk(allocator, src);
}

test "tANS roundtrip: enwik8 offset 1 MB, 128 KB chunk" {
    const allocator = testing.allocator;
    const file = std.fs.cwd().openFile(
        "c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/enwik8.txt",
        .{},
    ) catch return;
    defer file.close();

    try file.seekTo(1024 * 1024);
    const src = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(src);
    const read = try file.readAll(src);
    if (read != src.len) return error.SkipZigTest;

    try tansRoundtripChunk(allocator, src);
}

test "tANS roundtrip: silesia first 64 KB (binary-ish)" {
    const allocator = testing.allocator;
    const file = std.fs.cwd().openFile(
        "c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/silesia_all.tar",
        .{},
    ) catch return;
    defer file.close();

    // Skip the tar header zero padding at the very start.
    try file.seekTo(1024 * 1024);
    const src = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(src);
    const read = try file.readAll(src);
    if (read != src.len) return error.SkipZigTest;

    try tansRoundtripChunk(allocator, src);
}

test "tANS roundtrip: silesia 128 KB at offset 2 MB" {
    const allocator = testing.allocator;
    const file = std.fs.cwd().openFile(
        "c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/silesia_all.tar",
        .{},
    ) catch return;
    defer file.close();

    try file.seekTo(2 * 1024 * 1024);
    const src = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(src);
    const read = try file.readAll(src);
    if (read != src.len) return error.SkipZigTest;

    try tansRoundtripChunk(allocator, src);
}
