//! Top-level StreamLZ framed decompressor.
//!
//! Port of the framed decompress loop in src/StreamLZ/StreamLZ.cs
//! (`Slz.DecompressFramed`) and the inner dispatcher in
//! src/StreamLZ/Decompression/StreamLzDecoder.cs.
//!
//! **Current status (phase 3a):** uncompressed frame blocks only.
//! The compressed codec paths (Fast L1–5, High L6–11) land in
//! subsequent phases — they currently return `error.NotImplemented`.

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const constants = @import("../format/streamlz_constants.zig");

/// Extra bytes the decoder is allowed to write past `dst_len`.
/// Ported from `StreamLZDecoder.SafeSpace` (64 in C#).
pub const safe_space: usize = 64;

pub const DecompressError = error{
    BadFrame,
    Truncated,
    SizeMismatch,
    InvalidBlockHeader,
    BlockDataTruncated,
    OutputTooSmall,
    /// A compressed (non-uncompressed) block requires the Fast/High codec
    /// decoder, which hasn't been ported yet.
    NotImplemented,
};

/// Streams `src` (an SLZ1-framed buffer) into `dst`, returning the number
/// of bytes written to `dst`. `dst.len` must be at least `content_size + safe_space`
/// bytes when the frame declares a content size; otherwise the caller is
/// responsible for providing a buffer large enough.
pub fn decompressFramed(src: []const u8, dst: []u8) DecompressError!usize {
    if (src.len == 0) return 0;

    const hdr = frame.parseHeader(src) catch return error.BadFrame;

    // Content-size known: require dst ≥ content_size + safe_space.
    if (hdr.content_size) |cs| {
        const needed: usize = @intCast(cs + safe_space);
        if (dst.len < needed) return error.OutputTooSmall;
    }

    var pos: usize = hdr.header_size;
    var dst_off: usize = 0;

    while (pos + 4 <= src.len) {
        // Peek for end mark (4 zero bytes).
        const first_word = std.mem.readInt(u32, src[pos..][0..4], .little);
        if (first_word == frame.end_mark) break;

        const bh = frame.parseBlockHeader(src[pos..]) catch return error.InvalidBlockHeader;
        if (bh.isEndMark()) break;
        pos += 8;

        if (bh.uncompressed) {
            if (pos + bh.decompressed_size > src.len) return error.BlockDataTruncated;
            if (dst_off + bh.decompressed_size > dst.len) return error.OutputTooSmall;
            @memcpy(
                dst[dst_off..][0..bh.decompressed_size],
                src[pos..][0..bh.decompressed_size],
            );
            dst_off += bh.decompressed_size;
            pos += bh.compressed_size;
            continue;
        }

        // Compressed path — land in phase 3b.
        return error.NotImplemented;
    }

    if (hdr.content_size) |cs| {
        if (dst_off != cs) return error.SizeMismatch;
    }
    return dst_off;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decompressFramed roundtrips a tiny uncompressed L1 fixture (synthesized)" {
    // Synthesize a valid SLZ1 frame with one uncompressed block containing "Hello, world\n".
    const payload = "Hello, world\n";
    const content_size: u64 = payload.len;

    var buf: [256]u8 = undefined;
    const hdr_len = try frame.writeHeader(&buf, .{
        .codec = .fast,
        .level = 1,
        .content_size = content_size,
    });

    // Block header: compressed_size = decompressed_size = payload.len, uncompressed flag
    frame.writeBlockHeader(buf[hdr_len..], .{
        .compressed_size = payload.len,
        .decompressed_size = payload.len,
        .uncompressed = true,
    });
    @memcpy(buf[hdr_len + 8 ..][0..payload.len], payload);
    frame.writeEndMark(buf[hdr_len + 8 + payload.len ..]);
    const total_len = hdr_len + 8 + payload.len + 4;

    var out: [256]u8 = @splat(0);
    const written = try decompressFramed(buf[0..total_len], out[0..]);
    try testing.expectEqual(@as(usize, payload.len), written);
    try testing.expectEqualSlices(u8, payload, out[0..written]);
}

test "decompressFramed rejects bad magic" {
    const junk = [_]u8{ 'N', 'O', 'P', 'E', 1, 0, 0, 1, 2, 0 };
    var out: [32]u8 = undefined;
    try testing.expectError(error.BadFrame, decompressFramed(&junk, &out));
}

test "decompressFramed returns NotImplemented on compressed block" {
    // Frame header + block header with uncompressed=false + 10-byte bogus payload + end mark.
    var buf: [128]u8 = undefined;
    const hdr_len = try frame.writeHeader(&buf, .{
        .codec = .fast,
        .level = 1,
        .content_size = 10,
    });
    frame.writeBlockHeader(buf[hdr_len..], .{
        .compressed_size = 10,
        .decompressed_size = 10,
        .uncompressed = false,
    });
    @memset(buf[hdr_len + 8 ..][0..10], 0xAA);
    frame.writeEndMark(buf[hdr_len + 8 + 10 ..]);
    var out: [128]u8 = undefined;
    try testing.expectError(error.NotImplemented, decompressFramed(buf[0 .. hdr_len + 8 + 10 + 4], &out));
}
