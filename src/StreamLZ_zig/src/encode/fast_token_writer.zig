//! Fast LZ token emitter. Port of the `WriteOffset` / `WriteComplexOffset`
//! / `WriteLengthValue` / `WriteOffset32` helpers in
//! src/StreamLZ/Compression/Fast/Encoder.cs.
//! Used by: Fast codec (L1-L5)
//!
//! Hot-loop design:
//!   * `writeOffset` is the fast path: literal run ≤ 7 bytes, match ≤ 15,
//!     near offset. One `copy64` from `literal_start`, one byte written to
//!     the token stream, one u16 written to the off16 stream (or skipped if
//!     `offset == 0`). Zero branches on the common case after the guard.
//!   * `writeComplexOffset` handles long literal runs, long matches, and
//!     large offsets. Cold-path, rarely taken on typical data.
//!   * `writeLengthValue` is branchless for the common `value ≤ 251` case
//!     (single byte store) and takes a cold 3-byte extended encoding for
//!     the tail.

const std = @import("std");
const constants = @import("fast_constants.zig");
const writer_mod = @import("fast_stream_writer.zig");
const copy = @import("../io/copy_helpers.zig");
const offset_encoder = @import("offset_encoder.zig");

const FastStreamWriter = writer_mod.FastStreamWriter;

// ────────────────────────────────────────────────────────────
//  Low-level helpers
// ────────────────────────────────────────────────────────────

/// Extend a match forward by comparing 4 bytes at a time. Port of
///
pub inline fn extendMatchForward(
    source: [*]const u8,
    source_end: [*]const u8,
    recent_offset: isize,
) [*]const u8 {
    var s = source;
    while (@intFromPtr(s) < @intFromPtr(source_end)) {
        const lhs: u32 = std.mem.readInt(u32, s[0..4], .little);
        const rhs_addr: usize = @intFromPtr(s) +% @as(usize, @bitCast(recent_offset));
        const rhs_ptr: [*]const u8 = @ptrFromInt(rhs_addr);
        const rhs: u32 = std.mem.readInt(u32, rhs_ptr[0..4], .little);
        const xor = lhs ^ rhs;
        s += 4;
        if (xor != 0) {
            const tz_bits: u32 = @ctz(xor);
            s = s + @as(usize, tz_bits >> 3) - 4;
            break;
        }
    }
    return if (@intFromPtr(s) < @intFromPtr(source_end)) s else source_end;
}

/// Copy bytes in 4-byte chunks (may overshoot `count` but never read past
/// `source_end`). Used by the complex-path literal copy.
inline fn copyBytesUnsafe(dst: [*]u8, source: [*]const u8, count: usize) void {
    var d = dst;
    const d_end = dst + count;
    var s = source;
    while (@intFromPtr(d) < @intFromPtr(d_end)) {
        std.mem.writeInt(u32, d[0..4], std.mem.readInt(u32, s[0..4], .little), .little);
        d += 4;
        s += 4;
    }
}

// ────────────────────────────────────────────────────────────
//  Length + offset stream writers
// ────────────────────────────────────────────────────────────

/// Writes a length value to the length stream. `value` must be ≥ 0.
///
/// Single-byte path for `value ≤ 251`; extended 3-byte path for larger.
/// The extended encoding packs `(value - base) >> 2` into a u16 and the
/// low 2 bits into the tag byte as `(value & 3) - 4` (i.e., 0xFC..0xFF).
pub inline fn writeLengthValue(w: *FastStreamWriter, value: u32) void {
    const lp = w.length_cursor;
    if (value <= constants.max_single_byte_length_value) {
        lp[0] = @intCast(value);
        w.length_cursor = lp + 1;
    } else {
        const low2: u32 = value & constants.extended_length_mask;
        const tag: u8 = @intCast((low2 -% 4) & 0xFF);
        lp[0] = tag;
        const remainder: u32 = (value - (low2 + constants.extended_length_base)) >> 2;
        std.mem.writeInt(u16, lp[1..3], @intCast(remainder), .little);
        w.length_cursor = lp + 3;
    }
}

/// Writes a 32-bit offset to the off32 stream. Uses a compact 3-byte
/// encoding for `offset < 0xC00000` and a 4-byte encoding for larger.
pub inline fn writeOffset32(w: *FastStreamWriter, offset: u32) void {
    const p = w.off32_cursor;
    if (offset >= constants.large_offset_threshold) {
        const truncated: u32 = (offset & 0x3FFFFF) | 0xC00000;
        p[0] = @intCast(truncated & 0xFF);
        p[1] = @intCast((truncated >> 8) & 0xFF);
        p[2] = @intCast((truncated >> 16) & 0xFF);
        p[3] = @intCast((offset - truncated) >> 22);
        w.off32_cursor = p + 4;
    } else {
        p[0] = @intCast(offset & 0xFF);
        p[1] = @intCast((offset >> 8) & 0xFF);
        p[2] = @intCast((offset >> 16) & 0xFF);
        w.off32_cursor = p + 3;
    }
    w.off32_count += 1;
}

// ────────────────────────────────────────────────────────────
//  Token writers
// ────────────────────────────────────────────────────────────

/// Complex-path writer for the tokens that don't fit the short encoding.
/// Handles long literal runs (≥ 8 bytes), long matches, and large offsets.
pub fn writeComplexOffset(
    w: *FastStreamWriter,
    match_length_in: u32,
    literal_run_length_in: u32,
    offset: u32,
    recent_offset: isize,
    literal_start: [*]const u8,
) void {
    var match_length = match_length_in;
    var literal_run_length = literal_run_length_in;

    // Copy literals into the stream. We read past the end (up to 4 bytes)
    // but the parser guarantees the scratch buffer has room.
    const old_literal = w.literal_cursor;
    w.literal_cursor = old_literal + literal_run_length;
    if (literal_run_length > 0) {
        copyBytesUnsafe(old_literal, literal_start, literal_run_length);
    }
    if (w.delta_literal_cursor) |delta_cur| {
        w.delta_literal_cursor = delta_cur + literal_run_length;
        if (literal_run_length > 0) {
            offset_encoder.subtractBytesUnsafe(delta_cur, literal_start, literal_run_length, recent_offset);
        }
    }

    if (literal_run_length < 64) {
        // Split long-ish literal runs into 0x87 continuation tokens
        // (= "7 literal bytes, new 0 match"). Each emits 7 literals.
        while (literal_run_length > 7) {
            w.token_cursor[0] = 0x87;
            w.token_cursor += 1;
            literal_run_length -= 7;
        }
    } else {
        // Long literal run: use command 0 with extended length value.
        writeLengthValue(w, literal_run_length - 64);
        w.token_cursor[0] = 0x00;
        w.token_cursor += 1;
        w.complex_token_count += 1;
        literal_run_length = 0;
        if (match_length == 0) return;
    }

    if (offset <= 0xFFFF and match_length < constants.near_offset_max_match_length + 1) {
        // Near-offset match with partial length (first slot) + continuation.
        var current_match_length: u32 = @min(match_length, 15);
        var token: u8 = @intCast(literal_run_length + 8 * current_match_length);
        if (offset == 0) {
            token += 0x80;
        } else {
            w.off16_cursor[0] = @intCast(offset);
            w.off16_cursor += 1;
        }
        match_length -= current_match_length;
        w.token_cursor[0] = token;
        w.token_cursor += 1;

        // Continuation chain: each 0x80 + 8*L emits L more match bytes from
        // the same offset.
        while (match_length != 0) {
            current_match_length = @min(match_length, 15);
            w.token_cursor[0] = @intCast(0x80 + 8 * current_match_length);
            w.token_cursor += 1;
            match_length -= current_match_length;
        }
        return;
    }

    // Long-match and/or far-offset path.
    w.complex_token_count += 1;
    if (literal_run_length != 0) {
        w.token_cursor[0] = @intCast(0x80 + literal_run_length);
        w.token_cursor += 1;
    }

    // "offset == 0" means recent-offset; resolve to the actual recent value.
    var effective_offset: u32 = offset;
    if (effective_offset == 0) {
        const neg_recent: isize = -recent_offset;
        effective_offset = @intCast(@as(isize, neg_recent));
    }

    var token_byte: u8 = undefined;
    var length_value: i64 = undefined;
    var write_length = false;

    if (effective_offset > 0xFFFF) {
        const delta: i64 = @as(i64, @intCast(match_length)) - 5;
        if (delta >= 0 and delta <= 23) {
            token_byte = @intCast(match_length - 5);
            length_value = 0;
        } else {
            token_byte = 2;
            length_value = @as(i64, @intCast(match_length)) - 29;
            write_length = true;
        }
    } else {
        token_byte = 1;
        length_value = @as(i64, @intCast(match_length)) - 91;
        write_length = true;
    }

    w.token_cursor[0] = token_byte;
    w.token_cursor += 1;
    if (write_length) {
        // length_value can be 0 here; that's valid and encodes as a single 0 byte.
        const lv: u32 = @intCast(@max(length_value, 0));
        writeLengthValue(w, lv);
    }

    if (effective_offset > 0xFFFF) {
        // Offset adjustment: `+ (sourcePointer + block2StartOffset - literalEnd)`.
        // For the serial port we compute it from writer state.
        const literal_end_pos: usize = @intFromPtr(literal_start) + literal_run_length_in;
        const src_base_plus_block2: usize = @intFromPtr(w.source_ptr) + w.block2_start_offset;
        const adjusted: u32 = effective_offset +% @as(u32, @truncate(src_base_plus_block2 -% literal_end_pos));
        writeOffset32(w, adjusted);
    } else {
        w.off16_cursor[0] = @intCast(effective_offset);
        w.off16_cursor += 1;
    }
}

/// Fast-path token writer. Takes the short-encoding route when the literal
/// run is ≤ 7 bytes, match length is ≤ 15, and offset fits in 16 bits.
/// Falls back to `writeComplexOffset` otherwise.
pub inline fn writeOffset(
    w: *FastStreamWriter,
    match_length: u32,
    literal_run_length: u32,
    offset: u32,
    recent_offset: isize,
    literal_start: [*]const u8,
) void {
    if (literal_run_length <= 7 and match_length <= 15 and offset <= 0xFFFF) {
        @branchHint(.likely);
        // Fast path — single copy64, single token store, conditional u16 store.
        copy.copy64(w.literal_cursor, literal_start);
        w.literal_cursor += literal_run_length;
        if (w.delta_literal_cursor) |delta_cur| {
            // SIMD byte subtract: delta[i] = literal[i] - byte_at_recent_offset[i]
            const V8 = @Vector(8, u8);
            const a: V8 = literal_start[0..8].*;
            const back_addr: usize = @intFromPtr(literal_start) +% @as(usize, @bitCast(recent_offset));
            const back_ptr: [*]const u8 = @ptrFromInt(back_addr);
            const b: V8 = back_ptr[0..8].*;
            const out: V8 = a -% b;
            delta_cur[0..8].* = out;
            w.delta_literal_cursor = delta_cur + literal_run_length;
        }

        const use_distance_bit: u8 = if (offset == 0) 0x80 else 0;
        const token: u8 = @intCast(literal_run_length + 8 * match_length);
        w.token_cursor[0] = use_distance_bit + token;
        w.token_cursor += 1;

        if (offset != 0) {
            w.off16_cursor[0] = @intCast(offset);
            w.off16_cursor += 1;
        }
        return;
    }
    writeComplexOffset(w, match_length, literal_run_length, offset, recent_offset, literal_start);
}

/// Lazy-parser entry point: scans literal runs in the [8, 63] range for
/// 1-byte recent-offset matches, splitting the run into multiple length-1
/// recent-offset tokens when the slot accounting allows. Port of
///
///
/// Caller invariant: used after the lazy parser
/// (chain hasher and 2x hasher) emits a match. For literal runs outside
/// [8, 63] this collapses to a plain `writeOffset`.
pub fn writeOffsetWithLiteral1(
    w: *FastStreamWriter,
    match_length: u32,
    literal_run_length: u32,
    offset: u32,
    recent_offset: isize,
    literal_start: [*]const u8,
) void {
    if ((literal_run_length -% 8) > 55) {
        writeOffset(w, match_length, literal_run_length, offset, recent_offset, literal_start);
        return;
    }
    writeOffsetWithLiteral1Inner(w, match_length, literal_run_length, offset, recent_offset, literal_start);
}

fn writeOffsetWithLiteral1Inner(
    w: *FastStreamWriter,
    match_length: u32,
    literal_run_length_in: u32,
    offset: u32,
    recent_offset: isize,
    literal_start_in: [*]const u8,
) void {
    var literal_start = literal_start_in;
    var literal_run_length = literal_run_length_in;

    var found: [33]u32 = undefined;
    var found_count: u32 = 0;
    var last: u32 = 0;
    var i: u32 = 1;
    const V16 = @Vector(16, u8);
    const V16Bool = @Vector(16, bool);
    while (i < literal_run_length) {
        const a_ptr = literal_start + i;
        const b_addr: usize = @intFromPtr(a_ptr) +% @as(usize, @bitCast(recent_offset));
        const b_ptr: [*]const u8 = @ptrFromInt(b_addr);
        const a: V16 = a_ptr[0..16].*;
        const b: V16 = b_ptr[0..16].*;
        const eq: V16Bool = a == b;
        const mask: u16 = @bitCast(eq);
        if (mask == 0) {
            i += 16;
        } else {
            const j: u32 = i + @ctz(mask);
            if (j >= literal_run_length) break;
            i = j + 1;
            if (j != last) {
                found[found_count] = j - last;
                found_count += 1;
                last = i;
            }
        }
    }

    if (found_count != 0) {
        std.debug.assert(found_count < 33);
        found[found_count] = literal_run_length - last;
        var fi: u32 = 0;
        while (fi < found_count) : (fi += 1) {
            const current: u32 = found[fi];
            if (constants.literalRunSlotCount(current) + constants.literalRunSlotCount(found[fi + 1]) + 1 > 7) {
                writeOffset(w, 1, current, 0, recent_offset, literal_start);
                literal_start += current + 1;
                literal_run_length -= current + 1;
            } else {
                found[fi + 1] += current + 1;
            }
        }
    }
    writeOffset(w, match_length, literal_run_length, offset, recent_offset, literal_start);
}

/// Copy the trailing literals (after the last emitted match) into the stream.
/// Shared epilogue for all parser variants.
pub fn copyTrailingLiterals(
    w: *FastStreamWriter,
    literal_start: [*]const u8,
    source_end: [*]const u8,
    recent_offset: isize,
) void {
    const count_addr_diff: isize = @as(isize, @bitCast(@intFromPtr(source_end) -% @intFromPtr(literal_start)));
    if (count_addr_diff <= 0) return;
    const count: usize = @intCast(count_addr_diff);
    const old = w.literal_cursor;
    w.literal_cursor = old + count;
    @memcpy(old[0..count], literal_start[0..count]);
    if (w.delta_literal_cursor) |delta_cur| {
        w.delta_literal_cursor = delta_cur + count;
        offset_encoder.subtractBytes(delta_cur, literal_start, count, recent_offset);
    }
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeLengthValue single-byte path" {
    const buf: [16]u8 = @splat(0);
    var w = try FastStreamWriter.init(testing.allocator, &buf, 16, null, false);
    defer w.deinit(testing.allocator);

    writeLengthValue(&w, 0);
    writeLengthValue(&w, 100);
    writeLengthValue(&w, 251);

    try testing.expectEqual(@as(usize, 3), w.lengthCount());
    try testing.expectEqual(@as(u8, 0), w.length_start[0]);
    try testing.expectEqual(@as(u8, 100), w.length_start[1]);
    try testing.expectEqual(@as(u8, 251), w.length_start[2]);
}

test "writeLengthValue extended 3-byte path" {
    const buf: [16]u8 = @splat(0);
    var w = try FastStreamWriter.init(testing.allocator, &buf, 16, null, false);
    defer w.deinit(testing.allocator);

    // value = 252: low2 = 0, tag = -4 = 0xFC; remainder = (252 - 252) >> 2 = 0
    writeLengthValue(&w, 252);
    try testing.expectEqual(@as(u8, 0xFC), w.length_start[0]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, w.length_start[1..3], .little));

    // value = 500: low2 = 0, tag = 0xFC; remainder = (500 - 252) >> 2 = 62
    writeLengthValue(&w, 500);
    try testing.expectEqual(@as(u8, 0xFC), w.length_start[3]);
    try testing.expectEqual(@as(u16, 62), std.mem.readInt(u16, w.length_start[4..6], .little));
}

test "writeOffset fast path emits one token byte and one u16" {
    var buf: [32]u8 = .{0} ** 32;
    // Set up source with some literal bytes at the start.
    buf[0] = 'A';
    buf[1] = 'B';
    buf[2] = 'C';
    var w = try FastStreamWriter.init(testing.allocator, &buf, 32, null, false);
    defer w.deinit(testing.allocator);

    // lit=3, match=5, offset=0x1234
    writeOffset(&w, 5, 3, 0x1234, -8, &buf);
    try testing.expectEqual(@as(usize, 1), w.tokenCount());
    try testing.expectEqual(@as(u8, 3 + 8 * 5), w.token_start[0]);
    try testing.expectEqual(@as(usize, 1), w.off16Count());
    try testing.expectEqual(@as(u16, 0x1234), w.off16_start[0]);
    try testing.expectEqual(@as(usize, 3), w.literalCount());
    try testing.expectEqual(@as(u8, 'A'), w.literal_start[0]);
}

test "writeOffset fast path offset==0 sets high bit and no off16 store" {
    const buf: [32]u8 = @splat('x');
    var w = try FastStreamWriter.init(testing.allocator, &buf, 32, null, false);
    defer w.deinit(testing.allocator);

    writeOffset(&w, 10, 2, 0, -8, &buf);
    try testing.expectEqual(@as(usize, 0), w.off16Count());
    try testing.expectEqual(@as(u8, 0x80 + 2 + 8 * 10), w.token_start[0]);
}

test "writeOffset32 small-offset path writes 3 bytes" {
    const buf: [8]u8 = @splat(0);
    var w = try FastStreamWriter.init(testing.allocator, &buf, 8, null, false);
    defer w.deinit(testing.allocator);

    writeOffset32(&w, 0x123456);
    try testing.expectEqual(@as(usize, 3), w.off32ByteCount());
    try testing.expectEqual(@as(u8, 0x56), w.off32_start[0]);
    try testing.expectEqual(@as(u8, 0x34), w.off32_start[1]);
    try testing.expectEqual(@as(u8, 0x12), w.off32_start[2]);
    try testing.expectEqual(@as(u32, 1), w.off32_count);
}

test "extendMatchForward finds end of match" {
    // src: "HELLO HELLO!"
    const src = "HELLO HELLO!";
    const cursor: [*]const u8 = src.ptr + 6;
    const end: [*]const u8 = src.ptr + src.len;
    // Match offset: 6 back, so recent_offset = -6
    const match_end = extendMatchForward(cursor, end, -6);
    // Should match "HELLO" (5 bytes) but not the '!'.
    const len = @intFromPtr(match_end) - @intFromPtr(cursor);
    try testing.expectEqual(@as(usize, 5), len);
}
