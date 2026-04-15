//! StreamLZ v2 parallel-decode sidecar format.
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
//!   [1] sidecar_version = 1
//!   [3] reserved (must be zero on write)
//!   [4] num_match_ops (u32 LE)
//!   [4] num_literal_bytes (u32 LE)
//!   [num_match_ops * 20]:
//!     [8] dst_pos (u64 LE)
//!     [8] src_pos (i64 LE — signed because the walker emits raw offsets)
//!     [4] length (u32 LE)
//!   [num_literal_bytes * 9]:
//!     [8] position (u64 LE)
//!     [1] byte_value (u8)
//!
//! Literal bytes are stored flat (one record per byte) rather than
//! RLE-compressed over runs. This is the simplest encoding; an RLE
//! variant can be added in a future sidecar_version bump if size
//! matters. In measured files the sidecar is 0.3-1.1% of compressed
//! size, so the simplicity is worth it.
//!
//! Decoders that recognize the block flag but don't support parallel
//! decode MUST skip the sidecar block by advancing past its compressed
//! bytes. Sidecar blocks have `decompressed_size == 0` and contribute
//! zero output.

const std = @import("std");

pub const magic: u32 = 0x43534450; // 'PDSC' LE (P=0x50 D=0x44 S=0x53 C=0x43)
pub const sidecar_version: u8 = 1;

/// Header inside the sidecar block payload (before the match-op and
/// literal sections). Always 16 bytes.
pub const payload_header_size: usize = 16;
pub const match_op_record_size: usize = 20;
pub const literal_byte_record_size: usize = 9;

/// One entry in the `match_ops` table.
pub const MatchOp = struct {
    target_start: u64,
    src_start: i64,
    length: u32,
};

/// One entry in the `literal_bytes` table.
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
    OutOfMemory,
};

pub const WriteError = error{
    DestinationTooSmall,
};

/// Computes the exact serialized byte length of a sidecar block BODY
/// (excluding the outer 8-byte block header that marks it as a
/// parallel-decode-metadata block). Callers use this to allocate a
/// slot before calling `writeBlockBody`.
pub fn serializedBodySize(num_match_ops: usize, num_literal_bytes: usize) usize {
    return payload_header_size +
        num_match_ops * match_op_record_size +
        num_literal_bytes * literal_byte_record_size;
}

/// Writes a sidecar block BODY into `dst`. Returns the number of bytes
/// written. Caller is responsible for writing the outer 8-byte frame
/// block header (with the `parallel_decode_metadata_flag` set on the
/// compressed_size field) before/around this call.
pub fn writeBlockBody(
    dst: []u8,
    match_ops: []const MatchOp,
    literal_bytes: []const LiteralByte,
) WriteError!usize {
    const needed = serializedBodySize(match_ops.len, literal_bytes.len);
    if (dst.len < needed) return error.DestinationTooSmall;

    var pos: usize = 0;

    // Payload header.
    std.mem.writeInt(u32, dst[pos..][0..4], magic, .little);
    pos += 4;
    dst[pos] = sidecar_version;
    pos += 1;
    dst[pos + 0] = 0;
    dst[pos + 1] = 0;
    dst[pos + 2] = 0;
    pos += 3;
    std.mem.writeInt(u32, dst[pos..][0..4], @intCast(match_ops.len), .little);
    pos += 4;
    std.mem.writeInt(u32, dst[pos..][0..4], @intCast(literal_bytes.len), .little);
    pos += 4;

    // Match ops.
    for (match_ops) |op| {
        std.mem.writeInt(u64, dst[pos..][0..8], op.target_start, .little);
        pos += 8;
        std.mem.writeInt(i64, dst[pos..][0..8], op.src_start, .little);
        pos += 8;
        std.mem.writeInt(u32, dst[pos..][0..4], op.length, .little);
        pos += 4;
    }

    // Literal bytes (flat, 9 bytes per record).
    for (literal_bytes) |lit| {
        std.mem.writeInt(u64, dst[pos..][0..8], lit.position, .little);
        pos += 8;
        dst[pos] = lit.byte_value;
        pos += 1;
    }

    return pos;
}

/// Parses a sidecar block BODY from `src`. Allocates owning arrays for
/// the match_ops and literal_bytes tables. On error the returned
/// struct's arrays are not set; the caller must not deinit.
pub fn parseBlockBody(src: []const u8, allocator: std.mem.Allocator) ParseError!ParsedSidecar {
    if (src.len < payload_header_size) return error.Truncated;

    const got_magic = std.mem.readInt(u32, src[0..4], .little);
    if (got_magic != magic) return error.BadMagic;

    const ver = src[4];
    if (ver != sidecar_version) return error.UnsupportedSidecarVersion;
    // bytes 5..8 reserved, not validated

    const num_match_ops = std.mem.readInt(u32, src[8..12], .little);
    const num_literal_bytes = std.mem.readInt(u32, src[12..16], .little);

    const match_ops_bytes: usize = @as(usize, num_match_ops) * match_op_record_size;
    const literal_bytes_bytes: usize = @as(usize, num_literal_bytes) * literal_byte_record_size;
    const expected_size = payload_header_size + match_ops_bytes + literal_bytes_bytes;
    if (src.len < expected_size) return error.Truncated;

    const match_ops = try allocator.alloc(MatchOp, num_match_ops);
    errdefer allocator.free(match_ops);
    const literal_bytes = try allocator.alloc(LiteralByte, num_literal_bytes);
    errdefer allocator.free(literal_bytes);

    var pos: usize = payload_header_size;
    var i: usize = 0;
    while (i < num_match_ops) : (i += 1) {
        match_ops[i] = .{
            .target_start = std.mem.readInt(u64, src[pos..][0..8], .little),
            .src_start = std.mem.readInt(i64, src[pos + 8 ..][0..8], .little),
            .length = std.mem.readInt(u32, src[pos + 16 ..][0..4], .little),
        };
        pos += match_op_record_size;
    }
    var j: usize = 0;
    while (j < num_literal_bytes) : (j += 1) {
        literal_bytes[j] = .{
            .position = std.mem.readInt(u64, src[pos..][0..8], .little),
            .byte_value = src[pos + 8],
        };
        pos += literal_byte_record_size;
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

test "serializedBodySize math" {
    try testing.expectEqual(@as(usize, 16), serializedBodySize(0, 0));
    try testing.expectEqual(@as(usize, 16 + 20), serializedBodySize(1, 0));
    try testing.expectEqual(@as(usize, 16 + 9), serializedBodySize(0, 1));
    try testing.expectEqual(@as(usize, 16 + 20 * 3 + 9 * 5), serializedBodySize(3, 5));
}

test "writeBlockBody / parseBlockBody round trip — empty sidecar" {
    var buf: [64]u8 = undefined;
    const n = try writeBlockBody(&buf, &[_]MatchOp{}, &[_]LiteralByte{});
    try testing.expectEqual(@as(usize, payload_header_size), n);
    var parsed = try parseBlockBody(buf[0..n], testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.match_ops.len);
    try testing.expectEqual(@as(usize, 0), parsed.literal_bytes.len);
}

test "writeBlockBody / parseBlockBody round trip — mixed payload" {
    const match_ops = [_]MatchOp{
        .{ .target_start = 100, .src_start = 50, .length = 8 },
        .{ .target_start = 200, .src_start = 150, .length = 16 },
    };
    const literal_bytes = [_]LiteralByte{
        .{ .position = 10, .byte_value = 0xAA },
        .{ .position = 42, .byte_value = 0x55 },
        .{ .position = 1000, .byte_value = 0xFF },
    };

    var buf: [256]u8 = undefined;
    const n = try writeBlockBody(&buf, &match_ops, &literal_bytes);
    try testing.expectEqual(serializedBodySize(2, 3), n);

    var parsed = try parseBlockBody(buf[0..n], testing.allocator);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.match_ops.len);
    try testing.expectEqual(@as(u64, 100), parsed.match_ops[0].target_start);
    try testing.expectEqual(@as(i64, 50), parsed.match_ops[0].src_start);
    try testing.expectEqual(@as(u32, 8), parsed.match_ops[0].length);
    try testing.expectEqual(@as(u64, 200), parsed.match_ops[1].target_start);

    try testing.expectEqual(@as(usize, 3), parsed.literal_bytes.len);
    try testing.expectEqual(@as(u64, 42), parsed.literal_bytes[1].position);
    try testing.expectEqual(@as(u8, 0x55), parsed.literal_bytes[1].byte_value);
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
    var buf: [payload_header_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], magic, .little);
    buf[4] = sidecar_version;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    std.mem.writeInt(u32, buf[8..12], 1, .little); // claim 1 match op
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    // We only provided the header — no match op bytes.
    try testing.expectError(error.Truncated, parseBlockBody(&buf, testing.allocator));
}
