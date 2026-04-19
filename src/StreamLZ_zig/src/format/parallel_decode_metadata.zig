//! StreamLZ v2 parallel-decode sidecar format.
//! Optional sidecar block for L1-L5 parallel decode. Not present in L6-L11 or v1 frames.
//!
//! A sidecar block carries the pre-computed "phase 1" state that a
//! parallel Fast L1-L4 decoder needs in order to execute cross-chunk
//! match copies and populate literal-leaf positions before spawning
//! per-sub-chunk worker threads. It consists of:
//!
//!   * a list of **match ops** — (target_start, src_start, length)
//!     triples the decoder executes with byte-wise forward copy to
//!     populate the closure
//!   * a list of **literal byte leaves** — (position, byte_value)
//!     pairs that phase 1 writes directly into dst
//!
//! Both lists are global across the frame (not per-block), since the
//! closure is a whole-file property. Decoders load the whole sidecar
//! into memory at startup, run phase 1, then dispatch phase 2 workers.
//!
//! Wire format of the sidecar block body (appears after the v2 frame's
//! standard 8-byte block header when the header's compressed_size field
//! has bit 30 set, i.e. `parallel_decode_metadata_flag`):
//!
//!   [4] magic = 'PDSC' (0x43534450 LE)
//!   [1] sidecar_version = 2
//!   [3] reserved (must be zero on write)
//!   [varint] num_match_ops       (u32 LEB128)
//!   [varint] num_literal_runs    (u32 LEB128)
//!   [match_ops section]:
//!     for each op (in monotonically-increasing target_start order):
//!       [varint] delta_target   = target_start - prev_target_start
//!                                 (prev = 0 for first op)
//!       [varint] offset          = target_start - src_start
//!                                 (always > 0 for a valid match; the
//!                                 walker drops any entry with src<0)
//!       [varint] length
//!   [literal_runs section]:
//!     for each run (sorted by position, grouped into maximal
//!     consecutive-position runs):
//!       [varint] delta_position = run.position - prev_run_end
//!                                 (prev_run_end = 0 for first run)
//!       [varint] run.length
//!       [run.length bytes]  raw byte values
//!
//! Why the shape:
//!   * Positions are mostly monotonic (closure ops come in cmd_stream
//!     order = file position order). Deltas are small → fit in 1-2
//!     varint bytes each instead of 8 raw bytes.
//!   * Match src positions are always offset-back from the target, so
//!     storing `target - src` as a small positive integer is 1-2
//!     varint bytes instead of 8.
//!   * Literal leaves come in runs (especially the new overcopy leaves
//!     which are 4-16 contiguous bytes at block boundaries). Grouping
//!     them into runs saves the per-byte position overhead.
//!
//! Decoders that recognize the block flag but don't support parallel
//! decode MUST skip the sidecar block by advancing past its compressed
//! bytes. Sidecar blocks have `decompressed_size == 0` and contribute
//! zero output.

const std = @import("std");

pub const magic: u32 = 0x43534450; // 'PDSC' LE (P=0x50 D=0x44 S=0x53 C=0x43)
pub const sidecar_version: u8 = 2;

/// Header inside the sidecar block payload (before the match-op and
/// literal sections). Always 8 bytes (magic + version + reserved).
pub const payload_header_size: usize = 8;

/// One entry in the match ops list.
pub const MatchOp = struct {
    target_start: u64,
    src_start: i64,
    length: u32,
};

/// One entry in the literal byte list.
pub const LiteralByte = struct {
    position: u64,
    byte_value: u8,
};

/// Returned by `parseBlockBody`. Owns its arrays; caller must deinit.
pub const ParsedSidecar = struct {
    match_ops: []MatchOp,
    literal_bytes: []LiteralByte,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedSidecar) void {
        self.allocator.free(self.match_ops);
        self.allocator.free(self.literal_bytes);
    }
};

pub const ParseError = error{
    Truncated,
    BadMagic,
    UnsupportedSidecarVersion,
    VarintTooLong,
    OutOfMemory,
};

pub const WriteError = error{
    DestinationTooSmall,
};

// ────────────────────────────────────────────────────────────
//  LEB128 varint helpers
// ────────────────────────────────────────────────────────────

/// Maximum bytes a u64 can take in LEB128 (ceil(64/7) = 10).
const varint_max_u64: usize = 10;
/// Maximum bytes a u32 can take in LEB128 (ceil(32/7) = 5).
const varint_max_u32: usize = 5;

fn writeVarint(dst: []u8, value: u64) WriteError!usize {
    var v = value;
    var pos: usize = 0;
    while (v >= 0x80) {
        if (pos >= dst.len) return error.DestinationTooSmall;
        dst[pos] = @intCast((v & 0x7f) | 0x80);
        pos += 1;
        v >>= 7;
    }
    if (pos >= dst.len) return error.DestinationTooSmall;
    dst[pos] = @intCast(v);
    return pos + 1;
}

fn varintSize(value: u64) usize {
    var v = value;
    var n: usize = 1;
    while (v >= 0x80) : (n += 1) {
        v >>= 7;
    }
    return n;
}

const VarintRead = struct { value: u64, consumed: usize };

fn readVarint(src: []const u8) ParseError!VarintRead {
    var v: u64 = 0;
    var shift: u6 = 0;
    var pos: usize = 0;
    while (true) {
        if (pos >= src.len) return error.Truncated;
        const b = src[pos];
        pos += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        if (shift >= 63) return error.VarintTooLong;
        shift += 7;
    }
    return .{ .value = v, .consumed = pos };
}

/// Fast-path varint decode for the common 1-2 byte case (values 0-16383).
/// Falls back to the generic loop for 3+ byte varints.
inline fn readVarintFast(src: []const u8) ParseError!VarintRead {
    if (src.len == 0) return error.Truncated;
    const b0 = src[0];
    if ((b0 & 0x80) == 0) return .{ .value = b0, .consumed = 1 };
    if (src.len < 2) return error.Truncated;
    const b1 = src[1];
    if ((b1 & 0x80) == 0) return .{ .value = (@as(u64, b1) << 7) | (b0 & 0x7f), .consumed = 2 };
    return readVarint(src); // fallback for 3+ byte varints
}

// ────────────────────────────────────────────────────────────
//  Size computation
// ────────────────────────────────────────────────────────────

/// Pre-computes the exact serialized size of a v2 sidecar body given
/// the match ops and literal bytes that will be serialized. Literal
/// bytes MUST already be sorted by position for the run-length
/// pass to work.
///
/// Callers use this to size the outer block header's `compressed_size`
/// field and to reserve dst space before calling `writeBlockBody`.
pub fn serializedBodySize(
    match_ops: []const MatchOp,
    literal_bytes: []const LiteralByte,
) usize {
    var total: usize = payload_header_size;

    // Count runs in the literal_bytes (assumed sorted).
    const num_runs = countLiteralRuns(literal_bytes);

    // Varint counts.
    total += varintSize(@intCast(match_ops.len));
    total += varintSize(@intCast(num_runs));

    // Match ops section.
    var prev_target: u64 = 0;
    for (match_ops) |op| {
        const delta_target: u64 = op.target_start -| prev_target;
        const offset: u64 = blk: {
            const tgt_i: i64 = @intCast(op.target_start);
            if (op.src_start < 0 or op.src_start > tgt_i) break :blk 0;
            break :blk @intCast(tgt_i - op.src_start);
        };
        total += varintSize(delta_target);
        total += varintSize(offset);
        total += varintSize(@intCast(op.length));
        prev_target = op.target_start;
    }

    // Literal runs section.
    var prev_run_end: u64 = 0;
    var i: usize = 0;
    while (i < literal_bytes.len) {
        const run_start = literal_bytes[i].position;
        var run_len: usize = 1;
        while (i + run_len < literal_bytes.len and
            literal_bytes[i + run_len].position == run_start + run_len)
        {
            run_len += 1;
        }
        const delta_pos: u64 = run_start -| prev_run_end;
        total += varintSize(delta_pos);
        total += varintSize(@intCast(run_len));
        total += run_len;
        prev_run_end = run_start + run_len;
        i += run_len;
    }

    return total;
}

/// Counts maximal consecutive-position runs in a sorted literal_bytes
/// slice. Caller must pre-sort.
fn countLiteralRuns(literal_bytes: []const LiteralByte) usize {
    var runs: usize = 0;
    var i: usize = 0;
    while (i < literal_bytes.len) {
        const start = literal_bytes[i].position;
        var run_len: usize = 1;
        while (i + run_len < literal_bytes.len and
            literal_bytes[i + run_len].position == start + run_len)
        {
            run_len += 1;
        }
        runs += 1;
        i += run_len;
    }
    return runs;
}

// ────────────────────────────────────────────────────────────
//  Write
// ────────────────────────────────────────────────────────────

/// Writes a v2 sidecar block BODY into `dst`. Returns the number of
/// bytes written. Literal bytes MUST already be sorted by position
/// (the caller in the encoder path sorts during sidecar build).
pub fn writeBlockBody(
    dst: []u8,
    match_ops: []const MatchOp,
    literal_bytes: []const LiteralByte,
) WriteError!usize {
    const needed = serializedBodySize(match_ops, literal_bytes);
    if (dst.len < needed) return error.DestinationTooSmall;

    var pos: usize = 0;

    // Payload header: magic + version + 3 reserved bytes.
    std.mem.writeInt(u32, dst[pos..][0..4], magic, .little);
    pos += 4;
    dst[pos] = sidecar_version;
    pos += 1;
    dst[pos + 0] = 0;
    dst[pos + 1] = 0;
    dst[pos + 2] = 0;
    pos += 3;

    const num_runs = countLiteralRuns(literal_bytes);
    pos += try writeVarint(dst[pos..], @intCast(match_ops.len));
    pos += try writeVarint(dst[pos..], @intCast(num_runs));

    // Match ops: delta_target + offset + length, all varint.
    var prev_target: u64 = 0;
    for (match_ops) |op| {
        const delta_target: u64 = op.target_start -| prev_target;
        const offset: u64 = blk: {
            const tgt_i: i64 = @intCast(op.target_start);
            if (op.src_start < 0 or op.src_start > tgt_i) break :blk 0;
            break :blk @intCast(tgt_i - op.src_start);
        };
        pos += try writeVarint(dst[pos..], delta_target);
        pos += try writeVarint(dst[pos..], offset);
        pos += try writeVarint(dst[pos..], @intCast(op.length));
        prev_target = op.target_start;
    }

    // Literal runs: delta_position + run_length + raw bytes.
    var prev_run_end: u64 = 0;
    var i: usize = 0;
    while (i < literal_bytes.len) {
        const run_start = literal_bytes[i].position;
        var run_len: usize = 1;
        while (i + run_len < literal_bytes.len and
            literal_bytes[i + run_len].position == run_start + run_len)
        {
            run_len += 1;
        }
        const delta_pos: u64 = run_start -| prev_run_end;
        pos += try writeVarint(dst[pos..], delta_pos);
        pos += try writeVarint(dst[pos..], @intCast(run_len));
        // Raw bytes — copy from the literal_bytes slice.
        if (pos + run_len > dst.len) return error.DestinationTooSmall;
        var b: usize = 0;
        while (b < run_len) : (b += 1) {
            dst[pos + b] = literal_bytes[i + b].byte_value;
        }
        pos += run_len;
        prev_run_end = run_start + run_len;
        i += run_len;
    }

    return pos;
}

// ────────────────────────────────────────────────────────────
//  Parse
// ────────────────────────────────────────────────────────────

/// Parses a v2 sidecar block BODY from `src`. Allocates owning arrays
/// for the match_ops and literal_bytes tables. On error the returned
/// struct's arrays are not set; the caller must not deinit.
pub fn parseBlockBody(src: []const u8, allocator: std.mem.Allocator) ParseError!ParsedSidecar {
    if (src.len < payload_header_size) return error.Truncated;

    const got_magic = std.mem.readInt(u32, src[0..4], .little);
    if (got_magic != magic) return error.BadMagic;

    const ver = src[4];
    if (ver != sidecar_version) return error.UnsupportedSidecarVersion;

    var pos: usize = payload_header_size;

    const nm = try readVarintFast(src[pos..]);
    pos += nm.consumed;
    const num_match_ops: usize = @intCast(nm.value);

    const nr = try readVarintFast(src[pos..]);
    pos += nr.consumed;
    const num_literal_runs: usize = @intCast(nr.value);

    const match_ops = try allocator.alloc(MatchOp, num_match_ops);
    errdefer allocator.free(match_ops);

    var prev_target: u64 = 0;
    var i: usize = 0;
    while (i < num_match_ops) : (i += 1) {
        const dt = try readVarintFast(src[pos..]);
        pos += dt.consumed;
        const target_start = prev_target + dt.value;

        const off = try readVarintFast(src[pos..]);
        pos += off.consumed;
        const src_start_u: u64 = target_start -| off.value;

        const ln = try readVarintFast(src[pos..]);
        pos += ln.consumed;

        match_ops[i] = .{
            .target_start = target_start,
            .src_start = @intCast(src_start_u),
            .length = @intCast(ln.value),
        };
        prev_target = target_start;
    }

    // Two-pass literal parsing: tally total byte count for a single
    // allocation, then fill. The tally pass is pure varint decode with
    // no allocation — fast and cache-friendly.
    var tally_pos = pos;
    var tally_total: usize = 0;
    var runs_left: usize = num_literal_runs;
    while (runs_left > 0) : (runs_left -= 1) {
        const dp = try readVarintFast(src[tally_pos..]);
        tally_pos += dp.consumed;
        const rl = try readVarintFast(src[tally_pos..]);
        tally_pos += rl.consumed;
        tally_pos += @intCast(rl.value);
        if (tally_pos > src.len) return error.Truncated;
        tally_total += @intCast(rl.value);
    }

    const literal_bytes = try allocator.alloc(LiteralByte, tally_total);
    errdefer allocator.free(literal_bytes);

    var prev_run_end: u64 = 0;
    var lit_idx: usize = 0;
    var r: usize = 0;
    while (r < num_literal_runs) : (r += 1) {
        const dp = try readVarintFast(src[pos..]);
        pos += dp.consumed;
        const run_start = prev_run_end + dp.value;

        const rl = try readVarintFast(src[pos..]);
        pos += rl.consumed;
        const run_len: usize = @intCast(rl.value);

        if (pos + run_len > src.len) return error.Truncated;
        var b: usize = 0;
        while (b < run_len) : (b += 1) {
            literal_bytes[lit_idx + b] = .{
                .position = run_start + @as(u64, @intCast(b)),
                .byte_value = src[pos + b],
            };
        }
        lit_idx += run_len;
        pos += run_len;
        prev_run_end = run_start + run_len;
    }

    return .{
        .match_ops = match_ops,
        .literal_bytes = literal_bytes,
        .allocator = allocator,
    };
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "varint roundtrip" {
    var buf: [16]u8 = undefined;
    const cases = [_]u64{ 0, 1, 127, 128, 255, 16384, 1 << 32, std.math.maxInt(u64) };
    for (cases) |v| {
        const n = try writeVarint(&buf, v);
        try testing.expectEqual(varintSize(v), n);
        const r = try readVarint(buf[0..n]);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(n, r.consumed);
    }
}

test "readVarintFast matches readVarint for all sizes" {
    var buf: [16]u8 = undefined;
    const cases = [_]u64{ 0, 1, 63, 127, 128, 255, 16383, 16384, 1 << 21, 1 << 32, std.math.maxInt(u64) };
    for (cases) |v| {
        const n = try writeVarint(&buf, v);
        const slow = try readVarint(buf[0..n]);
        const fast = try readVarintFast(buf[0..n]);
        try testing.expectEqual(slow.value, fast.value);
        try testing.expectEqual(slow.consumed, fast.consumed);
    }
}

test "serializedBodySize == writeBlockBody's return value" {
    const match_ops = [_]MatchOp{
        .{ .target_start = 100, .src_start = 50, .length = 8 },
        .{ .target_start = 200, .src_start = 150, .length = 16 },
    };
    const literal_bytes = [_]LiteralByte{
        .{ .position = 10, .byte_value = 0xAA },
        .{ .position = 11, .byte_value = 0xBB }, // run of 3
        .{ .position = 12, .byte_value = 0xCC },
        .{ .position = 42, .byte_value = 0x55 }, // isolated
    };
    var buf: [256]u8 = undefined;
    const n = try writeBlockBody(&buf, &match_ops, &literal_bytes);
    try testing.expectEqual(serializedBodySize(&match_ops, &literal_bytes), n);
}

test "writeBlockBody / parseBlockBody round trip — empty sidecar" {
    var buf: [16]u8 = undefined;
    const n = try writeBlockBody(&buf, &[_]MatchOp{}, &[_]LiteralByte{});
    // 8 byte header + two 1-byte varints (zero counts) = 10 bytes.
    try testing.expectEqual(@as(usize, 10), n);
    var parsed = try parseBlockBody(buf[0..n], testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.match_ops.len);
    try testing.expectEqual(@as(usize, 0), parsed.literal_bytes.len);
}

test "writeBlockBody / parseBlockBody round trip — mixed payload" {
    const match_ops = [_]MatchOp{
        .{ .target_start = 100, .src_start = 50, .length = 8 },
        .{ .target_start = 200, .src_start = 150, .length = 16 },
        .{ .target_start = 1_000_000, .src_start = 999_500, .length = 32 },
    };
    const literal_bytes = [_]LiteralByte{
        .{ .position = 10, .byte_value = 0xAA },
        .{ .position = 11, .byte_value = 0xBB },
        .{ .position = 12, .byte_value = 0xCC },
        .{ .position = 42, .byte_value = 0x55 },
        .{ .position = 1000, .byte_value = 0xFF },
        .{ .position = 1001, .byte_value = 0xEE },
    };

    var buf: [512]u8 = undefined;
    const n = try writeBlockBody(&buf, &match_ops, &literal_bytes);

    var parsed = try parseBlockBody(buf[0..n], testing.allocator);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.match_ops.len);
    try testing.expectEqual(@as(u64, 100), parsed.match_ops[0].target_start);
    try testing.expectEqual(@as(i64, 50), parsed.match_ops[0].src_start);
    try testing.expectEqual(@as(u32, 8), parsed.match_ops[0].length);
    try testing.expectEqual(@as(u64, 1_000_000), parsed.match_ops[2].target_start);
    try testing.expectEqual(@as(i64, 999_500), parsed.match_ops[2].src_start);

    try testing.expectEqual(@as(usize, 6), parsed.literal_bytes.len);
    try testing.expectEqual(@as(u64, 10), parsed.literal_bytes[0].position);
    try testing.expectEqual(@as(u8, 0xAA), parsed.literal_bytes[0].byte_value);
    try testing.expectEqual(@as(u64, 12), parsed.literal_bytes[2].position);
    try testing.expectEqual(@as(u8, 0xCC), parsed.literal_bytes[2].byte_value);
    try testing.expectEqual(@as(u64, 42), parsed.literal_bytes[3].position);
    try testing.expectEqual(@as(u64, 1001), parsed.literal_bytes[5].position);
    try testing.expectEqual(@as(u8, 0xEE), parsed.literal_bytes[5].byte_value);
}

test "parseBlockBody rejects bad magic" {
    var buf: [payload_header_size]u8 = undefined;
    @memset(&buf, 0);
    try testing.expectError(error.BadMagic, parseBlockBody(&buf, testing.allocator));
}

test "parseBlockBody rejects unsupported sidecar_version" {
    var buf: [payload_header_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], magic, .little);
    buf[4] = 99;
    @memset(buf[5..], 0);
    try testing.expectError(error.UnsupportedSidecarVersion, parseBlockBody(&buf, testing.allocator));
}

test "parseBlockBody rejects truncated body" {
    var buf: [payload_header_size + 4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], magic, .little);
    buf[4] = sidecar_version;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    // Claim 1 match op but provide no body.
    buf[8] = 1; // varint 1: num_match_ops
    buf[9] = 0; // varint 0: num_literal_runs
    // No match op data, so readVarint on the delta_target will hit Truncated.
    buf[10] = 0;
    buf[11] = 0;
    try testing.expectError(error.Truncated, parseBlockBody(buf[0..10], testing.allocator));
}

test "delta + varint compresses monotonic match ops" {
    // 100 match ops at positions 1000, 2000, ..., 100000, all offset 500.
    var match_ops: [100]MatchOp = undefined;
    for (&match_ops, 0..) |*op, i| {
        op.* = .{
            .target_start = @as(u64, @intCast(i + 1)) * 1000,
            .src_start = @as(i64, @intCast(i + 1)) * 1000 - 500,
            .length = 16,
        };
    }
    const raw_size: usize = 100 * 20 + 16; // old v1 format cost
    const v2_size = serializedBodySize(&match_ops, &[_]LiteralByte{});
    // v2 should be dramatically smaller: 100 × (~2 + 2 + 1) = ~500 bytes
    // vs 2016 for raw. Anything under half the raw size is a pass.
    try testing.expect(v2_size < raw_size / 2);
}
