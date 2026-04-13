//! Block/chunk header write helpers. Port of
//! src/StreamLZ/Compression/BlockHeaderWriter.cs.
//!
//! Companion module to `../format/block_header.zig` (which holds the
//! read-side parsers). These helpers emit the 2-byte internal block
//! header and the 4-byte / 5-byte / 3-byte-BE variants of the chunk
//! header, matching the wire format the decoder expects.
//!
//! Currently `streamlz_encoder.zig` inlines equivalent write sequences.
//! Extracting them here lets the upcoming High encoder reuse the same
//! primitives without copying logic — step 23 of the parity punch list.
//! Fast continues to use its own inlined copies for now to preserve
//! byte-exact output against C#; consolidation happens after High lands.

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");

// ── Block header byte 0 flag bits ───────────────────────────────────
// Matches C# `BlockHeaderWriter.cs:11-20` and the decoder parser in
// `format/block_header.zig`.
pub const block_header_magic_nibble: u8 = 0x05;
pub const block_header_self_contained_flag: u8 = 0x10;
pub const block_header_two_phase_flag: u8 = 0x20;
pub const block_header_keyframe_flag: u8 = 0x40;
pub const block_header_uncompressed_flag: u8 = 0x80;

/// CRC-present flag in block header byte 1.
pub const block_header_crc_flag: u8 = 0x80;

pub const BlockHdrOptions = struct {
    compr_id: u8,
    crc: bool = false,
    keyframe: bool = false,
    uncompressed: bool = false,
    self_contained: bool = false,
    two_phase: bool = false,
};

/// Writes the 2-byte internal block header at `dst[0..2]`. Port of C#
/// `StreamLZCompressor.WriteBlockHdr` (`BlockHeaderWriter.cs:44-54`).
pub inline fn writeBlockHdr(dst: [*]u8, opts: BlockHdrOptions) void {
    var byte0: u8 = block_header_magic_nibble;
    if (opts.self_contained) byte0 |= block_header_self_contained_flag;
    if (opts.two_phase) byte0 |= block_header_two_phase_flag;
    if (opts.keyframe) byte0 |= block_header_keyframe_flag;
    if (opts.uncompressed) byte0 |= block_header_uncompressed_flag;
    dst[0] = byte0;
    dst[1] = opts.compr_id | (if (opts.crc) block_header_crc_flag else @as(u8, 0));
}

/// Writes a 3-byte big-endian value — used for sub-chunk headers
/// inside a 256 KB chunk. Port of `WriteBE24` (`BlockHeaderWriter.cs:63-68`).
pub inline fn writeBE24(dst: [*]u8, v: u32) void {
    dst[0] = @intCast((v >> 16) & 0xFF);
    dst[1] = @intCast((v >> 8) & 0xFF);
    dst[2] = @intCast(v & 0xFF);
}

/// Writes a 4-byte little-endian chunk header encoding the compressed
/// size. Port of `WriteChunkHeader` (`BlockHeaderWriter.cs:78-83`).
/// The chunk type is 0 (normal); the size field is `size - 1`.
pub inline fn writeChunkHeader(dst: [*]u8, compressed_size_minus_1: u32) void {
    const v: u32 = compressed_size_minus_1 & lz_constants.chunk_size_mask;
    std.mem.writeInt(u32, dst[0..4], v, .little);
}

/// Writes a 5-byte memset chunk header (4-byte LE header + 1 fill byte).
/// Port of `WriteMemsetChunkHeader` (`BlockHeaderWriter.cs:92-97`).
pub inline fn writeMemsetChunkHeader(dst: [*]u8, v: u8) void {
    const hdr: u32 = lz_constants.chunk_size_mask | (@as(u32, 1) << lz_constants.chunk_type_shift);
    std.mem.writeInt(u32, dst[0..4], hdr, .little);
    dst[4] = v;
}

/// Returns true when every byte in `data` equals the first byte.
/// Port of C# `AreAllBytesEqual` (`BlockHeaderWriter.cs:106-121`).
pub inline fn areAllBytesEqual(data: []const u8) bool {
    if (data.len <= 1) return true;
    const first = data[0];
    for (data[1..]) |b| {
        if (b != first) return false;
    }
    return true;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeBlockHdr: magic nibble + compr id" {
    var buf: [2]u8 = @splat(0);
    writeBlockHdr(&buf, .{ .compr_id = 1 });
    try testing.expectEqual(@as(u8, 0x05), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "writeBlockHdr: all flags set" {
    var buf: [2]u8 = @splat(0);
    writeBlockHdr(&buf, .{
        .compr_id = 2,
        .crc = true,
        .keyframe = true,
        .uncompressed = true,
        .self_contained = true,
        .two_phase = true,
    });
    // byte0: 0x05 | 0x10 | 0x20 | 0x40 | 0x80 = 0xF5
    try testing.expectEqual(@as(u8, 0xF5), buf[0]);
    // byte1: 2 | 0x80 = 0x82
    try testing.expectEqual(@as(u8, 0x82), buf[1]);
}

test "writeBlockHdr: keyframe + self_contained only" {
    var buf: [2]u8 = @splat(0);
    writeBlockHdr(&buf, .{ .compr_id = 1, .keyframe = true, .self_contained = true });
    try testing.expectEqual(@as(u8, 0x05 | 0x10 | 0x40), buf[0]);
}

test "writeBE24: big-endian byte order" {
    var buf: [3]u8 = @splat(0);
    writeBE24(&buf, 0x12_34_56);
    try testing.expectEqual(@as(u8, 0x12), buf[0]);
    try testing.expectEqual(@as(u8, 0x34), buf[1]);
    try testing.expectEqual(@as(u8, 0x56), buf[2]);
}

test "writeChunkHeader: little-endian size encoding" {
    var buf: [4]u8 = @splat(0);
    writeChunkHeader(&buf, 1000);
    const read = std.mem.readInt(u32, &buf, .little);
    try testing.expectEqual(@as(u32, 1000), read & lz_constants.chunk_size_mask);
}

test "writeMemsetChunkHeader: header + fill byte" {
    var buf: [5]u8 = @splat(0);
    writeMemsetChunkHeader(&buf, 0xAA);
    // First 4 bytes: chunk_size_mask | (1 << chunk_type_shift)
    const hdr = std.mem.readInt(u32, buf[0..4], .little);
    try testing.expect((hdr & lz_constants.chunk_size_mask) == lz_constants.chunk_size_mask);
    try testing.expect((hdr >> @intCast(lz_constants.chunk_type_shift)) & 3 == 1);
    try testing.expectEqual(@as(u8, 0xAA), buf[4]);
}

test "areAllBytesEqual: empty and single byte trivially true" {
    try testing.expect(areAllBytesEqual(&[_]u8{}));
    try testing.expect(areAllBytesEqual(&[_]u8{0x42}));
}

test "areAllBytesEqual: all equal" {
    try testing.expect(areAllBytesEqual(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }));
    try testing.expect(areAllBytesEqual(&[_]u8{ 'a', 'a', 'a' }));
}

test "areAllBytesEqual: first-byte mismatch" {
    try testing.expect(!areAllBytesEqual(&[_]u8{ 1, 2, 1, 1 }));
}

test "areAllBytesEqual: last-byte mismatch" {
    try testing.expect(!areAllBytesEqual(&[_]u8{ 7, 7, 7, 8 }));
}
