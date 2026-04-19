//! Internal 2-byte StreamLZ block header + 4-byte chunk header parsers.
//!
//! Layout of the 2-byte block header (big-endian byte order):
//!   byte 0:
//!     [3:0]  magic nibble, must be 0x5
//!     [4]    self_contained
//!     [5]    two_phase
//!     [6]    restart_decoder
//!     [7]    uncompressed
//!   byte 1:
//!     [6:0]  decoder_type (0=High, 1=Fast, 2=Turbo)
//!     [7]    use_checksums
//!
//! Layout of the 4-byte LE chunk header (v2):
//!   bits [17:0]  compressed_size - 1
//!   bits [19:18] type (0=normal, 1=memset, 2+ reserved)
//!   bit  [20]    has_cross_chunk_match — set iff at least one LZ match
//!                in this chunk reads bytes produced BEFORE the chunk's
//!                own dst start. Decoders use this bit to short-circuit
//!                parallel decode: a chunk with has_cross_chunk_match == 0
//!                is independently decodable and needs no phase 1 state;
//!                one with == 1 requires the frame-level parallel-decode
//!                sidecar to be applied first.
//!   bits [31:21] reserved (must be 0 on write)
//!
//! When `use_checksums` is set, 3 extra bytes follow the 4-byte chunk header
//! (big-endian CRC24). The decoder currently parses but does not verify them.

const std = @import("std");
const constants = @import("streamlz_constants.zig");

pub const CodecType = enum(u8) {
    high = 0,
    fast = 1,
    turbo = 2,
    _,
};

pub const BlockHeader = struct {
    decoder_type: CodecType,
    restart_decoder: bool,
    uncompressed: bool,
    use_checksums: bool,
    self_contained: bool,
    two_phase: bool,

    pub const size: usize = 2;
};

pub const ChunkHeader = struct {
    /// Real compressed size (header field is stored as size-1).
    compressed_size: u32,
    /// Optional 3-byte CRC24. Zero when checksums are disabled.
    checksum: u32,
    /// Whole-chunk match-copy distance (non-zero only for special memset/wholematch).
    whole_match_distance: u32,
    /// How many bytes of `src` the header occupies (4 or 7).
    bytes_consumed: usize,
    /// True when this chunk is a memset fill (type==1 in the 4-byte header).
    is_memset: bool,
    /// For memset chunks, the fill byte (or first byte after the header).
    memset_fill: u8,
    /// v2: set iff at least one LZ match in this chunk reads bytes that
    /// live before the chunk's own dst start. Decoders that support
    /// parallel decode use this flag to identify chunks that can be
    /// decoded independently (has_cross_chunk_match == false) vs those
    /// that need phase-1 sidecar bytes in place (== true).
    has_cross_chunk_match: bool,
};

pub const ParseError = error{
    TooShort,
    BadMagic,
    BadDecoderType,
    BadChunkType,
};

pub fn parseBlockHeader(src: []const u8) ParseError!BlockHeader {
    if (src.len < BlockHeader.size) return error.TooShort;
    const b0 = src[0];
    const b1 = src[1];
    if ((b0 & 0x0F) != 0x5) return error.BadMagic;

    const decoder_byte: u8 = b1 & 0x7F;
    const decoder_type: CodecType = @enumFromInt(decoder_byte);
    switch (decoder_type) {
        .high, .fast, .turbo => {},
        else => return error.BadDecoderType,
    }

    return .{
        .decoder_type = decoder_type,
        .two_phase = ((b0 >> 5) & 1) != 0,
        .self_contained = ((b0 >> 4) & 1) != 0,
        .restart_decoder = ((b0 >> 6) & 1) != 0,
        .uncompressed = ((b0 >> 7) & 1) != 0,
        .use_checksums = (b1 >> 7) != 0,
    };
}

pub fn parseChunkHeader(src: []const u8, use_checksum: bool) ParseError!ChunkHeader {
    const min_bytes: usize = if (use_checksum) 7 else 4;
    if (src.len < min_bytes) return error.TooShort;

    const v = std.mem.readInt(u32, src[0..4], .little);
    const size = v & constants.chunk_size_mask;
    const chunk_type = (v >> constants.chunk_type_shift) & 3;
    const has_cross_chunk_match = (v & constants.chunk_has_cross_chunk_match_mask) != 0;

    switch (chunk_type) {
        0 => {
            // Normal compressed chunk.
            if (use_checksum) {
                const cs: u32 = (@as(u32, src[4]) << 16) | (@as(u32, src[5]) << 8) | @as(u32, src[6]);
                return .{
                    .compressed_size = size + 1,
                    .checksum = cs,
                    .whole_match_distance = 0,
                    .bytes_consumed = 7,
                    .is_memset = false,
                    .memset_fill = 0,
                    .has_cross_chunk_match = has_cross_chunk_match,
                };
            }
            return .{
                .compressed_size = size + 1,
                .checksum = 0,
                .whole_match_distance = 0,
                .bytes_consumed = 4,
                .is_memset = false,
                .memset_fill = 0,
                .has_cross_chunk_match = has_cross_chunk_match,
            };
        },
        1 => {
            // Memset chunk: 1 extra byte for fill value (no checksum path).
            // The cross-chunk-match bit is meaningless for a memset
            // (no LZ data) but we still surface it so the caller can
            // validate the encoder zeroed it.
            if (src.len < 5) return error.TooShort;
            return .{
                .compressed_size = 0,
                .checksum = src[4],
                .whole_match_distance = 0,
                .bytes_consumed = 5,
                .is_memset = true,
                .memset_fill = src[4],
                .has_cross_chunk_match = has_cross_chunk_match,
            };
        },
        else => return error.BadChunkType,
    }
}

// ────────────────────────────────────────────────────────────
//  Write helpers (encode side)
// ────────────────────────────────────────────────────────────

/// Block header byte 0 flag bits.
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

/// Writes the 2-byte internal block header at `dst[0..2]`.
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
/// inside a 256 KB chunk.
pub inline fn writeBE24(dst: [*]u8, v: u32) void {
    dst[0] = @intCast((v >> 16) & 0xFF);
    dst[1] = @intCast((v >> 8) & 0xFF);
    dst[2] = @intCast(v & 0xFF);
}

/// Writes a 4-byte little-endian chunk header encoding the compressed
/// size. The chunk type is 0 (normal); the size field is `size - 1`.
pub inline fn writeChunkHeader(dst: [*]u8, compressed_size_minus_1: u32) void {
    const v: u32 = compressed_size_minus_1 & constants.chunk_size_mask;
    std.mem.writeInt(u32, dst[0..4], v, .little);
}

/// Writes a 5-byte memset chunk header (4-byte LE header + 1 fill byte).
pub inline fn writeMemsetChunkHeader(dst: [*]u8, v: u8) void {
    const hdr: u32 = constants.chunk_size_mask | (@as(u32, 1) << constants.chunk_type_shift);
    std.mem.writeInt(u32, dst[0..4], hdr, .little);
    dst[4] = v;
}

/// Returns true when every byte in `data` equals the first byte.
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

test "parseBlockHeader rejects bad magic" {
    try testing.expectError(error.BadMagic, parseBlockHeader(&[_]u8{ 0x00, 0x01 }));
}

test "parseBlockHeader accepts Fast codec" {
    // magic 0x5 in low nibble + Fast (1) in low 7 bits of byte 1
    const hdr = try parseBlockHeader(&[_]u8{ 0x05, 0x01 });
    try testing.expectEqual(CodecType.fast, hdr.decoder_type);
    try testing.expect(!hdr.uncompressed);
    try testing.expect(!hdr.self_contained);
    try testing.expect(!hdr.two_phase);
    try testing.expect(!hdr.restart_decoder);
    try testing.expect(!hdr.use_checksums);
}

test "parseBlockHeader parses all flag bits" {
    // byte 0: magic 0x5 | self_contained(4) | two_phase(5) | restart(6) | uncomp(7) = 0xF5
    // byte 1: decoder=0 (High) | use_checksums(7) = 0x80
    const hdr = try parseBlockHeader(&[_]u8{ 0xF5, 0x80 });
    try testing.expectEqual(CodecType.high, hdr.decoder_type);
    try testing.expect(hdr.uncompressed);
    try testing.expect(hdr.restart_decoder);
    try testing.expect(hdr.two_phase);
    try testing.expect(hdr.self_contained);
    try testing.expect(hdr.use_checksums);
}

test "parseBlockHeader rejects invalid decoder type" {
    // decoder = 5 is not High/Fast/Turbo
    try testing.expectError(error.BadDecoderType, parseBlockHeader(&[_]u8{ 0x05, 0x05 }));
}

test "parseChunkHeader parses normal chunk, no checksum" {
    // size field = 1023 → compressed_size = 1024, type = 0, high bits 0
    const value: u32 = 1023; // (compressed_size - 1)
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    const ch = try parseChunkHeader(&buf, false);
    try testing.expectEqual(@as(u32, 1024), ch.compressed_size);
    try testing.expect(!ch.is_memset);
    try testing.expectEqual(@as(usize, 4), ch.bytes_consumed);
    try testing.expect(!ch.has_cross_chunk_match);
}

test "parseChunkHeader reads has_cross_chunk_match bit" {
    const value: u32 = 1023 | constants.chunk_has_cross_chunk_match_mask;
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    const ch = try parseChunkHeader(&buf, false);
    try testing.expectEqual(@as(u32, 1024), ch.compressed_size);
    try testing.expect(ch.has_cross_chunk_match);
}

test "parseChunkHeader parses normal chunk with checksum" {
    const value: u32 = 99; // compressed_size = 100, type = 0
    var buf: [7]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .little);
    buf[4] = 0xAA;
    buf[5] = 0xBB;
    buf[6] = 0xCC;
    const ch = try parseChunkHeader(&buf, true);
    try testing.expectEqual(@as(u32, 100), ch.compressed_size);
    try testing.expectEqual(@as(u32, 0xAABBCC), ch.checksum);
    try testing.expectEqual(@as(usize, 7), ch.bytes_consumed);
}

test "parseChunkHeader parses memset chunk" {
    const value: u32 = constants.chunk_type_memset; // type=1, size=0
    var buf: [5]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .little);
    buf[4] = 0x42;
    const ch = try parseChunkHeader(&buf, false);
    try testing.expect(ch.is_memset);
    try testing.expectEqual(@as(u8, 0x42), ch.memset_fill);
    try testing.expectEqual(@as(usize, 5), ch.bytes_consumed);
}

// ────────────────────────────────────────────────────────────
//  Write-side tests
// ────────────────────────────────────────────────────────────

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
    try testing.expectEqual(@as(u32, 1000), read & constants.chunk_size_mask);
}

test "writeMemsetChunkHeader: header + fill byte" {
    var buf: [5]u8 = @splat(0);
    writeMemsetChunkHeader(&buf, 0xAA);
    // First 4 bytes: chunk_size_mask | (1 << chunk_type_shift)
    const hdr = std.mem.readInt(u32, buf[0..4], .little);
    try testing.expect((hdr & constants.chunk_size_mask) == constants.chunk_size_mask);
    try testing.expect((hdr >> @intCast(constants.chunk_type_shift)) & 3 == 1);
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
