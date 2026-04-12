//! Top-level StreamLZ framed compressor.
//!
//! Produces an SLZ1-framed byte stream that `decode/streamlz_decoder.zig`
//! can decompress. Format layered:
//!
//!   [SLZ1 frame header]            (format/frame_format.zig)
//!   [block header 8 bytes]         per 256 KB outer block (only 1 for now)
//!   [internal block header 2B]     magic=0x5, decoder=Fast(1)
//!   [chunk header 4B]              compressed_size-1
//!   [sub-chunk(s)]                 one or two per 256 KB, 3-byte header each
//!   [end mark 4B]                  zero u32
//!
//! Phase 9 scope:
//!   * Raw-mode Fast encoder only (user levels 1 & 2). Entropy mode (L3-L5)
//!     lands in phase 10 alongside the Huffman / tANS encoders.
//!   * Single-threaded. One 256 KB chunk → one frame block.
//!   * No block checksums, no content checksum, no dictionary.

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const lz_constants = @import("../format/streamlz_constants.zig");
const fast_constants = @import("fast_constants.zig");
const FastMatchHasher = @import("fast_match_hasher.zig").FastMatchHasher;
const fast_enc = @import("fast_lz_encoder.zig");

pub const CompressError = error{
    BadLevel,
    BadBlockSize,
    DestinationTooSmall,
    HashBitsOutOfRange,
} || std.mem.Allocator.Error || fast_enc.EncodeError;

pub const Options = struct {
    /// User level 1 or 2 supported in Phase 9.
    level: u8 = 1,
    /// Include the content-size field in the frame header (strongly recommended).
    include_content_size: bool = true,
    /// Block size in the frame header. Must be a power of two between
    /// `frame.min_block_size` and `frame.max_block_size`. We always emit
    /// 256 KB blocks internally but the frame header can advertise larger.
    block_size: u32 = lz_constants.chunk_size,
};

/// Worst-case bound on the compressed size given `src_len`.
pub fn compressBound(src_len: usize) usize {
    // Generous bound that accounts for frame/block/chunk/sub-chunk headers
    // plus encoder slack (the per-sub-chunk `encodeSubChunkRaw` needs 256
    // bytes of headroom past the literal stream for the token/off16/off32
    // headers). The worst-case incompressible path stores source verbatim
    // so the output is strictly ≤ src_len + small fixed overhead.
    const chunk_count: usize = (src_len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
    const sub_chunks: usize = (src_len + fast_constants.sub_chunk_size - 1) / fast_constants.sub_chunk_size;
    const per_sub_chunk_overhead: usize = 3 + 8 + 3 + 256; // sub hdr + initial 8 + lit hdr + assembly slack
    return frame.max_header_size + 4 + chunk_count * (8 + 2 + 4) + sub_chunks * per_sub_chunk_overhead + src_len + 64;
}

/// Compress `src` into `dst` as a full SLZ1 frame. Returns the number of
/// bytes written to `dst`. `dst` must be at least `compressBound(src.len)`.
pub fn compressFramed(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    if (opts.level < 1 or opts.level > 2) return error.BadLevel;
    const min_dst = compressBound(src.len);
    if (dst.len < min_dst) return error.DestinationTooSmall;

    // ── Frame header ────────────────────────────────────────────────────
    var pos: usize = 0;
    const hdr_len = try frame.writeHeader(dst, .{
        .codec = .fast,
        .level = opts.level,
        .block_size = opts.block_size,
        .content_size = if (opts.include_content_size) @as(u64, @intCast(src.len)) else null,
    });
    pos += hdr_len;

    // ── Allocate persistent hasher (reused across sub-chunks) ──────────
    const params: @import("fast_match_hasher.zig").HasherParams = .{
        .hash_bits = if (opts.level >= 2) 17 else 16,
        .min_match_length = 4,
    };
    var hasher = try FastMatchHasher(u32).init(allocator, params);
    defer hasher.deinit();

    // ── Loop over 256 KB outer blocks ──────────────────────────────────
    var src_off: usize = 0;
    while (src_off < src.len) {
        const block_src_len: usize = @min(src.len - src_off, lz_constants.chunk_size);

        // Reserve space for the 8-byte frame block header.
        const block_hdr_pos: usize = pos;
        pos += 8;
        const block_start: usize = pos;

        // Decide: small input → store uncompressed; else try compressed.
        const try_compress = block_src_len > fast_constants.min_source_length;

        var compressed_payload_size: usize = 0;
        var stored_uncompressed = false;

        if (try_compress) {
            // Internal block header (2 bytes) — Fast codec, no flags.
            dst[pos] = 0x05; // magic nibble
            dst[pos + 1] = @intFromEnum(block_header.CodecType.fast);
            pos += 2;

            // 4-byte chunk header — the whole 256 KB block is one "chunk"
            // from the outer decoder's point of view. We write a placeholder
            // and backfill after encoding.
            const chunk_hdr_pos: usize = pos;
            pos += 4;
            const chunk_payload_start: usize = pos;

            // Iterate 128 KB sub-chunks within this chunk.
            var sub_off: usize = 0;

            while (sub_off < block_src_len) {
                const sub_len: usize = @min(block_src_len - sub_off, fast_constants.sub_chunk_size);
                const sub_src: []const u8 = src[src_off + sub_off ..][0..sub_len];

                // Reserve 3-byte sub-chunk header.
                const sub_hdr_pos: usize = pos;
                pos += 3;
                const sub_payload_start: usize = pos;
                const sub_payload_cap: usize = dst.len - pos;

                // start_position tells the sub-chunk encoder whether this is
                // the very first sub-chunk of the whole decompressed output.
                // Only the first sub-chunk of the first outer chunk (src_off==0
                // and sub_off==0) gets the initial 8-byte literal copy — every
                // later sub-chunk's decoder side has `base_offset != 0` and
                // skips that path.
                const start_position_for_sub: usize = src_off + sub_off;
                const result = try switch (opts.level) {
                    1 => fast_enc.encodeSubChunkRaw(1, allocator, &hasher, sub_src, dst[sub_payload_start..], start_position_for_sub),
                    2 => fast_enc.encodeSubChunkRaw(2, allocator, &hasher, sub_src, dst[sub_payload_start..], start_position_for_sub),
                    else => unreachable,
                };
                _ = sub_payload_cap;

                if (result.bail) {
                    // Store this sub-chunk as uncompressed: clear comp flag.
                    if (sub_payload_start + sub_len > dst.len) return error.DestinationTooSmall;
                    @memcpy(dst[sub_payload_start..][0..sub_len], sub_src);
                    const hdr: u32 = @as(u32, @intCast(sub_len)) | lz_constants.chunk_header_compressed_flag;
                    // Header format (3-byte BE): [23]=comp | [22:19]=mode | [18:0]=size
                    // For uncompressed we still set the comp flag but use size == sub_len
                    // and mode == 0. The decoder treats `comp_size == dst_count` as raw.
                    dst[sub_hdr_pos + 0] = @intCast((hdr >> 16) & 0xFF);
                    dst[sub_hdr_pos + 1] = @intCast((hdr >> 8) & 0xFF);
                    dst[sub_hdr_pos + 2] = @intCast(hdr & 0xFF);
                    pos = sub_payload_start + sub_len;
                } else {
                    // Backfill 3-byte sub-chunk header.
                    const hdr: u32 = @as(u32, @intCast(result.bytes_written)) |
                        (@as(u32, @intFromEnum(result.chunk_type)) << lz_constants.sub_chunk_type_shift) |
                        lz_constants.chunk_header_compressed_flag;
                    dst[sub_hdr_pos + 0] = @intCast((hdr >> 16) & 0xFF);
                    dst[sub_hdr_pos + 1] = @intCast((hdr >> 8) & 0xFF);
                    dst[sub_hdr_pos + 2] = @intCast(hdr & 0xFF);
                    pos = sub_payload_start + result.bytes_written;
                }

                sub_off += sub_len;
            }

            // Check that the compressed chunk actually beat uncompressed.
            // If not, rewind and emit as uncompressed frame block.
            compressed_payload_size = pos - chunk_payload_start;
            // Chunk total = 4-byte chunk header + payload + the 2-byte internal block header.
            const chunk_total_size: usize = 2 + 4 + compressed_payload_size;
            if (chunk_total_size >= block_src_len) {
                pos = block_start;
                stored_uncompressed = true;
            } else {
                // Backfill the 4-byte chunk header with (compressed_payload_size - 1).
                const raw: u32 = @intCast(compressed_payload_size - 1);
                std.mem.writeInt(u32, dst[chunk_hdr_pos..][0..4], raw, .little);
            }
        } else {
            stored_uncompressed = true;
        }

        if (stored_uncompressed) {
            // Uncompressed frame block: write the 8-byte block header with
            // the uncompressed flag set and copy the bytes verbatim.
            if (pos + block_src_len > dst.len) return error.DestinationTooSmall;
            frame.writeBlockHeader(dst[block_hdr_pos..], .{
                .compressed_size = @intCast(block_src_len),
                .decompressed_size = @intCast(block_src_len),
                .uncompressed = true,
            });
            @memcpy(dst[block_start..][0..block_src_len], src[src_off..][0..block_src_len]);
            pos = block_start + block_src_len;
        } else {
            // Compressed: write the final 8-byte block header now that we know
            // compressed_size.
            const compressed_block_size: usize = pos - block_start;
            frame.writeBlockHeader(dst[block_hdr_pos..], .{
                .compressed_size = @intCast(compressed_block_size),
                .decompressed_size = @intCast(block_src_len),
                .uncompressed = false,
            });
        }

        src_off += block_src_len;
    }

    // ── End mark ───────────────────────────────────────────────────────
    if (pos + 4 > dst.len) return error.DestinationTooSmall;
    frame.writeEndMark(dst[pos..]);
    pos += 4;

    return pos;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;
const decoder = @import("../decode/streamlz_decoder.zig");

fn roundtrip(source: []const u8, level: u8) !void {
    const allocator = testing.allocator;
    const bound = compressBound(source.len);
    const dst = try allocator.alloc(u8, bound);
    defer allocator.free(dst);

    const n = try compressFramed(allocator, source, dst, .{ .level = level });
    try testing.expect(n > 0);
    try testing.expect(n <= bound);

    // Decode.
    const decoded = try allocator.alloc(u8, source.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(dst[0..n], decoded);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, source, decoded[0..written]);
}

test "compressFramed L1 roundtrip: tiny input stored uncompressed" {
    const src = "Hello, world!\n";
    try roundtrip(src, 1);
}

test "compressFramed L1 roundtrip: 4 KB repeating pattern" {
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 64 KB English-ish" {
    var src: [65536]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 192 KB English-ish (spans 2 sub-chunks)" {
    var src: [192 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 256 KB English-ish" {
    var src: [256 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 256 KB XML-ish varied text" {
    // Closer to real enwik8: varied lines, short words.
    var src: [256 * 1024]u8 = undefined;
    const lines = [_][]const u8{
        "<page>\n",
        "  <title>Example Article</title>\n",
        "  <text>This is a test paragraph with varied words. ",
        "The parser sees shorter matches here than with a tiny fixed pattern. ",
        "Numbers: 12345 67890. More: foo bar baz qux. ",
        "&lt;link&gt;wiki/Article&lt;/link&gt; see also [[refs]]. ",
        "Random: zyxwvu tsrqpo nmlkji hgfedcba. ",
        "</text>\n",
        "</page>\n",
    };
    var i: usize = 0;
    var line_idx: usize = 0;
    while (i < src.len) {
        const line = lines[line_idx % lines.len];
        const n: usize = @min(line.len, src.len - i);
        @memcpy(src[i..][0..n], line[0..n]);
        i += n;
        line_idx += 1;
    }
    try roundtrip(&src, 1);
}

test "compressFramed L2 roundtrip: 256 KB repeating" {
    var src: [256 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 7 + 11) & 0xFF);
    try roundtrip(&src, 2);
}

test "compressFramed L1 roundtrip: 128 KB highly repetitive" {
    var src: [128 * 1024]u8 = undefined;
    const p = "ABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 256 KB highly repetitive" {
    var src: [256 * 1024]u8 = undefined;
    const p = "ABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: 1 MB highly repetitive" {
    var src: [1024 * 1024]u8 = undefined;
    const p = "ABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 1);
}

test "compressFramed L1 roundtrip: pseudo-random 4 KB (likely uncompressible)" {
    var src: [4096]u8 = undefined;
    var state: u32 = 0xC0FFEE;
    for (&src) |*b| {
        state = state *% 1103515245 +% 12345;
        b.* = @intCast((state >> 16) & 0xFF);
    }
    try roundtrip(&src, 1);
}

