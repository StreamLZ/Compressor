//! Top-level StreamLZ framed decompressor.
//!
//! Port of the framed decompress loop in src/StreamLZ/StreamLZ.cs
//! (`Slz.DecompressFramed`) and the inner dispatcher in
//! src/StreamLZ/Decompression/StreamLzDecoder.cs.
//!
//! Current coverage:
//!   * Frame-level uncompressed block path (phase 3a)
//!   * Fast codec (L1–5) compressed path via fast_lz_decoder (phase 3b)
//!   * High codec (L6–11) not yet wired — returns `HighNotImplemented`

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const constants = @import("../format/streamlz_constants.zig");
const fast = @import("fast_lz_decoder.zig");
const high = @import("high_lz_decoder.zig");
const parallel = @import("decompress_parallel.zig");

/// Extra bytes the decoder is allowed to write past `dst_len`.
/// Ported from `StreamLZDecoder.SafeSpace` (64 in C#).
pub const safe_space: usize = 64;

pub const DecompressError = error{
    BadFrame,
    Truncated,
    SizeMismatch,
    InvalidBlockHeader,
    InvalidInternalHeader,
    BadChunkHeader,
    BlockDataTruncated,
    OutputTooSmall,
    HighNotImplemented,
    ChecksumMismatch,
    ChunkSizeMismatch,
} || fast.DecodeError || high.DecodeError || std.mem.Allocator.Error || std.Thread.SpawnError || std.Thread.CpuCountError;

/// Streams `src` (an SLZ1-framed buffer) into `dst`, returning the number
/// of bytes written to `dst`. `dst.len` must be at least `content_size + safe_space`
/// bytes when the frame declares a content size.
pub fn decompressFramed(src: []const u8, dst: []u8) DecompressError!usize {
    return decompressFramedInner(null, src, dst);
}

/// Parallel variant of `decompressFramed`. Uses `allocator` to spawn
/// worker threads + allocate per-thread scratch for SC (L6-L8) blocks.
/// Non-SC blocks fall through to the serial path. Phase 13 step 35 (A1).
pub fn decompressFramedParallel(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
) DecompressError!usize {
    return decompressFramedInner(allocator, src, dst);
}

/// Lazy thread pool wrapper. The pool is expensive to init (24 thread
/// spawns ≈ 5 ms on Arrow Lake) and many decompress calls don't need
/// it — Fast L1-L5 files and single-chunk inputs go through the serial
/// path. Init is deferred to the first parallel dispatch so those cases
/// pay nothing.
const LazyPool = struct {
    allocator: ?std.mem.Allocator,
    storage: std.Thread.Pool,
    inited: bool,

    fn init(allocator_opt: ?std.mem.Allocator) LazyPool {
        return .{
            .allocator = allocator_opt,
            .storage = undefined,
            .inited = false,
        };
    }

    fn get(self: *LazyPool) ?*std.Thread.Pool {
        if (self.inited) return &self.storage;
        const alloc = self.allocator orelse return null;
        self.storage.init(.{ .allocator = alloc }) catch return null;
        self.inited = true;
        return &self.storage;
    }

    fn deinit(self: *LazyPool) void {
        if (self.inited) self.storage.deinit();
    }
};

fn decompressFramedInner(
    allocator_opt: ?std.mem.Allocator,
    src: []const u8,
    dst: []u8,
) DecompressError!usize {
    if (src.len == 0) return 0;

    // Lazy thread pool — only init on first parallel dispatch. Fast
    // codec inputs and single-chunk inputs skip pool init entirely.
    var lazy_pool = LazyPool.init(allocator_opt);
    defer lazy_pool.deinit();

    // Multi-piece support: the encoder's `compressFramed` retry
    // ladder (step 39) emits concatenated SLZ1 frames when the
    // single-shot path OOMs. Loop over pieces, decoding each
    // complete frame in order. Single-piece inputs exit after one
    // iteration via the empty-trailer check.
    var src_pos: usize = 0;
    var dst_off: usize = 0;
    while (src_pos < src.len) {
        const piece_src = src[src_pos..];
        const piece_dst = dst[dst_off..];
        const pair = try decompressOneFrame(allocator_opt, &lazy_pool, piece_src, piece_dst);
        src_pos += pair.src_consumed;
        dst_off += pair.dst_written;
        if (pair.src_consumed == 0) break;
    }
    return dst_off;
}

const FrameResult = struct { src_consumed: usize, dst_written: usize };

fn decompressOneFrame(
    allocator_opt: ?std.mem.Allocator,
    lazy_pool: *LazyPool,
    src: []const u8,
    dst: []u8,
) DecompressError!FrameResult {
    if (src.len == 0) return .{ .src_consumed = 0, .dst_written = 0 };

    const hdr = frame.parseHeader(src) catch return error.BadFrame;

    if (hdr.content_size) |cs| {
        const needed: usize = @intCast(cs + safe_space);
        if (dst.len < needed) return error.OutputTooSmall;
    }

    var pos: usize = hdr.header_size;
    var dst_off: usize = 0;
    // Scratch buffer for Fast decoder tables and stream storage.
    var scratch: [constants.scratch_size]u8 = undefined;

    while (pos + 4 <= src.len) {
        const first_word = std.mem.readInt(u32, src[pos..][0..4], .little);
        if (first_word == frame.end_mark) {
            pos += 4;
            break;
        }

        const bh = frame.parseBlockHeader(src[pos..]) catch return error.InvalidBlockHeader;
        if (bh.isEndMark()) {
            pos += 8;
            break;
        }
        pos += 8;

        // v2: parallel-decode-metadata (sidecar) block. Serial decoders
        // skip it — the sidecar is optional metadata for parallel decode
        // paths, and contributes zero bytes to dst. The compressed_size
        // bytes carry the sidecar payload, which we advance past here.
        if (bh.parallel_decode_metadata) {
            if (pos + bh.compressed_size > src.len) return error.BlockDataTruncated;
            pos += bh.compressed_size;
            continue;
        }

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

        // Dispatch: if caller provided an allocator AND this block
        // has multiple chunks, try the appropriate parallel path —
        //   * SC (L6-L8)  → DecompressCoreParallel
        //   * non-SC High → DecompressCoreTwoPhase (entropy parallel,
        //                   match resolve serial)
        // Anything else (single-chunk, Fast, mixed decoder types) falls
        // through to the existing serial loop.
        const block_src = src[pos .. pos + bh.compressed_size];
        var dispatched_parallel: bool = false;
        if (allocator_opt) |allocator| {
            if (block_src.len >= 2) {
                const peek = block_header.parseBlockHeader(block_src) catch null;
                if (peek) |ph| {
                    const has_many_chunks = bh.decompressed_size > constants.chunk_size;
                    if (ph.self_contained and has_many_chunks) {
                        try parallel.decompressCoreParallel(
                            allocator,
                            lazy_pool.get(),
                            block_src,
                            dst,
                            &dst_off,
                            bh.decompressed_size,
                            hdr.sc_group_size,
                        );
                        dispatched_parallel = true;
                    } else if (ph.decoder_type == .high and has_many_chunks) {
                        const ok = try parallel.decompressCoreTwoPhase(
                            allocator,
                            lazy_pool.get(),
                            block_src,
                            dst,
                            &dst_off,
                            bh.decompressed_size,
                        );
                        if (ok) dispatched_parallel = true;
                    }
                }
            }
        }

        if (!dispatched_parallel) {
            // Compressed block — iterate 256 KB chunks inside serially.
            try decompressCompressedBlock(
                block_src,
                dst,
                &dst_off,
                bh.decompressed_size,
                &scratch,
                hdr.sc_group_size,
            );
        }
        pos += bh.compressed_size;
    }

    if (hdr.content_size) |cs| {
        if (dst_off != cs) return error.SizeMismatch;
    }
    return .{ .src_consumed = pos, .dst_written = dst_off };
}

/// Whole-chunk match copy: reads `length` bytes from `dst - offset` into
/// `dst[0..length]`. Used for "whole-match" chunk variants where the entire
/// chunk is a single back-reference to earlier output.
///
/// Port of C# `StreamLZDecoder.CopyWholeMatch` at
/// `StreamLzDecoder.cs:142-157`. Uses 8-byte chunks when `offset >= 8` so
/// the load and store regions don't overlap. Falls through to byte-at-a-time
/// for the tail.
///
/// Unreachable via the current encoder (no compressor populates
/// `chunk_header.whole_match_distance`) but kept for structural parity and
/// to match the wire format reservation.
fn copyWholeMatch(dst: [*]u8, offset: u32, length: usize) void {
    std.debug.assert(offset > 0);
    const src_addr: usize = @intFromPtr(dst) - offset;
    const src: [*]const u8 = @ptrFromInt(src_addr);
    var i: usize = 0;
    if (offset >= 8) {
        while (i + 8 <= length) : (i += 8) {
            const word = std.mem.readInt(u64, src[i..][0..8], .little);
            std.mem.writeInt(u64, dst[i..][0..8], word, .little);
        }
    }
    while (i < length) : (i += 1) dst[i] = src[i];
}

/// Streaming decompression options.
pub const StreamDecompressOptions = struct {
    /// Sliding window size in bytes. LZ back-references can reach this far
    /// into previously-decoded output. Clamped to `[block_size, max_window_size]`
    /// where `block_size` comes from the frame header. Default 4 MB.
    window_size: u32 = 4 * 1024 * 1024,
    /// Maximum allowed total decompressed output bytes. 0 = no limit.
    /// Port of the `maxDecompressedSize` parameter in C#
    /// `StreamLzFrameDecompressor.Decompress` — protects against decompression
    /// bombs where a small malicious frame claims a huge output.
    max_decompressed_size: u64 = 0,
    /// If the frame has `content_checksum` set, verify the XXH32 at the end
    /// and return `error.ChecksumMismatch` on failure. Default true.
    verify_checksum: bool = true,
};

/// Streams an SLZ1 frame from `src` to `writer`, maintaining a sliding
/// window for cross-block LZ back-references and optionally verifying the
/// XXH32 content checksum. Returns the total number of decompressed bytes
/// written.
///
/// Port of C# `StreamLzFrameDecompressor.Decompress` at
/// `StreamLzFrameDecompressor.cs:28-196`. Unlike C#, `src` here is a single
/// byte slice (the caller is responsible for reading the file / memory-
/// mapping); output goes to any `std.Io.Writer`. For file-to-file streaming,
/// the caller can wrap a file writer.
pub fn decompressStream(
    allocator: std.mem.Allocator,
    src: []const u8,
    writer: *std.Io.Writer,
    opts: StreamDecompressOptions,
) DecompressError!u64 {
    if (src.len == 0) return 0;

    const hdr = frame.parseHeader(src) catch return error.BadFrame;
    const block_size: usize = @intCast(hdr.block_size);

    // Window size clamp: must hold at least one full block plus safe_space
    // slack; capped at the maximum window.
    var window_size: usize = @intCast(opts.window_size);
    if (window_size < block_size) window_size = block_size;
    if (window_size > frame.max_window_size) window_size = frame.max_window_size;

    // Window buffer layout: [dict ... current block output ... safe_space].
    // The dict portion holds the sliding window for cross-block back-refs;
    // the current block's output is written past dict_bytes. Mirrors C#
    // `StreamLzFrameDecompressor.cs:66-67`.
    const window_buf_size: usize = window_size + block_size + safe_space * 2;
    const window_buf = try allocator.alloc(u8, window_buf_size);
    defer allocator.free(window_buf);

    var hasher: ?std.hash.XxHash32 = if (hdr.flags.content_checksum and opts.verify_checksum)
        std.hash.XxHash32.init(0)
    else
        null;

    var pos: usize = hdr.header_size;
    var total_written: u64 = 0;
    var dict_bytes: usize = 0;

    while (pos + 4 <= src.len) {
        // Check for end mark.
        const first_word = std.mem.readInt(u32, src[pos..][0..4], .little);
        if (first_word == frame.end_mark) {
            pos += 4;
            break;
        }

        if (pos + 8 > src.len) return error.Truncated;
        const bh = frame.parseBlockHeader(src[pos..]) catch return error.InvalidBlockHeader;
        if (bh.isEndMark()) {
            pos += 4;
            break;
        }
        pos += 8;

        // Sanity caps matching C# `StreamLzFrameDecompressor.cs:96-99`.
        if (bh.decompressed_size > frame.max_decompressed_block_size) return error.BadFrame;
        if (bh.compressed_size > frame.max_decompressed_block_size) return error.BadFrame;

        // v2: skip parallel-decode-metadata (sidecar) blocks.
        if (bh.parallel_decode_metadata) {
            if (pos + bh.compressed_size > src.len) return error.BlockDataTruncated;
            pos += bh.compressed_size;
            continue;
        }

        // Grow the output budget check before decoding.
        if (dict_bytes + bh.decompressed_size + safe_space > window_buf.len) return error.OutputTooSmall;

        if (bh.uncompressed) {
            if (pos + bh.decompressed_size > src.len) return error.BlockDataTruncated;
            @memcpy(
                window_buf[dict_bytes..][0..bh.decompressed_size],
                src[pos..][0..bh.decompressed_size],
            );
            pos += bh.compressed_size;
        } else {
            if (pos + bh.compressed_size > src.len) return error.BlockDataTruncated;
            const n = try decompressBlockWithDict(
                src[pos .. pos + bh.compressed_size],
                window_buf,
                dict_bytes,
                bh.decompressed_size,
            );
            if (n != bh.decompressed_size) return error.SizeMismatch;
            pos += bh.compressed_size;
        }

        const decoded = window_buf[dict_bytes..][0..bh.decompressed_size];

        // Hash before writing so a later flush failure doesn't corrupt state.
        if (hasher) |*h| h.update(decoded);

        writer.writeAll(decoded) catch return error.OutputTooSmall;
        total_written += bh.decompressed_size;

        if (opts.max_decompressed_size != 0 and total_written > opts.max_decompressed_size) {
            return error.OutputTooSmall;
        }

        // Slide the window: keep the last `window_size` bytes so the next
        // block's LZ back-references can still reach them. Port of C#
        // `StreamLzFrameDecompressor.cs:155-166`.
        const total_used: usize = dict_bytes + bh.decompressed_size;
        if (total_used > window_size) {
            const keep: usize = window_size;
            const discard: usize = total_used - keep;
            std.mem.copyForwards(u8, window_buf[0..keep], window_buf[discard .. discard + keep]);
            dict_bytes = keep;
        } else {
            dict_bytes = total_used;
        }
    }

    // Optional XXH32 content checksum verification. C# reads the 4 checksum
    // bytes after the 4-byte end mark (`StreamLzFrameDecompressor.cs:172-187`).
    if (hasher) |*h| {
        if (pos + 4 > src.len) return error.ChecksumMismatch;
        const stored = std.mem.readInt(u32, src[pos..][0..4], .little);
        const computed = h.final();
        if (stored != computed) return error.ChecksumMismatch;
    }

    return total_written;
}

/// Decompresses a raw StreamLZ block (no SLZ1 frame wrapper) into `dst[0..decompressed_size]`.
///
/// Port of C# `StreamLZDecoder.Decompress(src, srcLen, dst, dstLen)` at
/// `StreamLzDecoder.cs:376-379`. `src` is a raw compressed block — a
/// sequence of internal 2-byte block headers + 4-byte chunk headers +
/// chunk payloads (no frame header, no end mark). `dst.len` must be at
/// least `decompressed_size + safe_space`.
///
/// Returns the number of bytes decompressed (equal to `decompressed_size`
/// on success).
pub fn decompressBlock(
    src: []const u8,
    dst: []u8,
    decompressed_size: usize,
) DecompressError!usize {
    return decompressBlockWithDict(src, dst, 0, decompressed_size);
}

/// Decompresses a raw StreamLZ block into `dst[dst_offset..dst_offset + decompressed_size]`,
/// with `dst[0..dst_offset]` treated as a pre-populated dictionary window.
///
/// Port of C# `StreamLZDecoder.Decompress(src, srcLen, dst, dstLen, dstOffset)`
/// at `StreamLzDecoder.cs:392-417` and `SerialDecodeLoopWithOffset` at
/// `StreamLzDecoder.cs:438-469`. LZ back-references in the compressed
/// stream can reach into the dictionary bytes at `dst[0..dst_offset]`.
///
/// `dst.len` must be at least `dst_offset + decompressed_size + safe_space`.
/// Returns the number of bytes decompressed (NOT including the dictionary).
pub fn decompressBlockWithDict(
    src: []const u8,
    dst: []u8,
    dst_offset: usize,
    decompressed_size: usize,
) DecompressError!usize {
    if (decompressed_size == 0) return 0;
    if (dst_offset + decompressed_size + safe_space > dst.len) return error.OutputTooSmall;

    var scratch: [constants.scratch_size]u8 = undefined;
    var dst_off: usize = dst_offset;
    // Block-level APIs have no frame-header context, so we use the
    // v2 default sc_group_size. Streaming / framed callers should
    // instead use `decompressFramed` / `decompressStream` so the
    // header-declared sc_group_size flows through.
    try decompressCompressedBlock(src, dst, &dst_off, decompressed_size, &scratch, constants.default_sc_group_size);
    return dst_off - dst_offset;
}

/// Walks 256 KB chunks inside a single compressed frame block. Parses the
/// internal 2-byte block header at every 256 KB boundary and the 4-byte
/// chunk header before each chunk's payload, dispatching to the codec.
///
/// **Self-contained (L6–L8) handling:** when the first internal block
/// header has `self_contained` set, the encoder stores `(num_chunks-1)*8`
/// "delta prefix" bytes at the very end of the block payload. After the
/// main decode, the first 8 bytes of every chunk except chunk 0 are
/// overwritten with those tail bytes. C# parallelizes SC decode and
/// forms per-group dst_start boundaries; our serial equivalent just
/// decodes sequentially with a buffer-wide dst_start (which is safe
/// because a well-formed encoder emits no cross-group references
/// beyond what the tail-prefix restoration then overwrites).
fn decompressCompressedBlock(
    block_src_in: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    scratch: []u8,
    sc_group_size: u8,
) DecompressError!void {
    // Peek the first 2-byte internal block header to detect SC mode up-front.
    const is_sc = blk: {
        if (block_src_in.len < 2) break :blk false;
        const peek = block_header.parseBlockHeader(block_src_in) catch break :blk false;
        break :blk peek.self_contained;
    };
    const num_chunks: usize = if (is_sc)
        (decompressed_size + constants.chunk_size - 1) / constants.chunk_size
    else
        0;
    const prefix_size: usize = if (is_sc and num_chunks > 1) (num_chunks - 1) * 8 else 0;
    if (prefix_size > block_src_in.len) return error.Truncated;
    const block_src: []const u8 = block_src_in[0 .. block_src_in.len - prefix_size];
    const sc_start_dst_off: usize = dst_off_inout.*;
    // Index of the chunk within this frame block (0-based). Used to compute
    // the group-local dst_start for SC mode so each group's first chunk
    // decodes with base_offset == 0 and fires the initial 8-byte Copy64.
    var chunk_idx_in_block: usize = 0;

    var src_pos: usize = 0;
    var dst_remaining: usize = decompressed_size;
    var internal_hdr: ?block_header.BlockHeader = null;

    while (dst_remaining > 0) {
        const dst_off = dst_off_inout.*;
        const at_chunk_boundary = (dst_off & (constants.chunk_size - 1)) == 0;

        if (at_chunk_boundary or internal_hdr == null) {
            if (src_pos + 2 > block_src.len) return error.Truncated;
            internal_hdr = block_header.parseBlockHeader(block_src[src_pos..]) catch return error.InvalidInternalHeader;
            src_pos += 2;
        }
        const hdr = internal_hdr.?;

        var dst_this_chunk: usize = constants.chunk_size;
        if (dst_this_chunk > dst_remaining) dst_this_chunk = dst_remaining;

        // ── Uncompressed chunk (header says so) — raw copy ──
        if (hdr.uncompressed) {
            if (src_pos + dst_this_chunk > block_src.len) return error.Truncated;
            if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
            @memcpy(dst[dst_off..][0..dst_this_chunk], block_src[src_pos..][0..dst_this_chunk]);
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            src_pos += dst_this_chunk;
            continue;
        }

        // ── Parse 4-byte chunk header ──
        const ch = block_header.parseChunkHeader(block_src[src_pos..], hdr.use_checksums) catch return error.BadChunkHeader;
        src_pos += ch.bytes_consumed;

        if (ch.is_memset) {
            // C# DecodeStep line 253-269: when compressed_size == 0, prefer
            // whole-match over memset if whole_match_distance is set.
            // `ParseChunkHeader` on both sides never populates this field,
            // so the branch is unreachable in practice — keeping it for
            // structural parity with the C# reference.
            if (ch.whole_match_distance != 0) {
                if (ch.whole_match_distance > dst_off) return error.BadChunkHeader;
                if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
                copyWholeMatch(
                    dst[dst_off..].ptr,
                    ch.whole_match_distance,
                    dst_this_chunk,
                );
            } else {
                if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
                @memset(dst[dst_off..][0..dst_this_chunk], ch.memset_fill);
            }
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            continue;
        }

        const comp_size: usize = ch.compressed_size;
        if (src_pos + comp_size > block_src.len) return error.Truncated;
        if (comp_size > dst_this_chunk) return error.BadChunkHeader;

        if (comp_size == dst_this_chunk) {
            // Stored raw within a "compressed" flag block.
            if (dst_off + dst_this_chunk > dst.len) return error.OutputTooSmall;
            @memcpy(dst[dst_off..][0..dst_this_chunk], block_src[src_pos..][0..dst_this_chunk]);
            dst_off_inout.* += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
            src_pos += comp_size;
            continue;
        }

        // Dispatch to codec decoder.
        switch (hdr.decoder_type) {
            .fast, .turbo => {
                if (dst_off + dst_this_chunk + safe_space > dst.len) return error.OutputTooSmall;
                const src_slice_start: [*]const u8 = block_src[src_pos..].ptr;
                const src_slice_end: [*]const u8 = src_slice_start + comp_size;
                const dst_ptr: [*]u8 = dst[dst_off..].ptr;
                const dst_end_ptr: [*]u8 = dst_ptr + dst_this_chunk;
                const dst_start_ptr: [*]const u8 = dst.ptr;
                const scratch_ptr: [*]u8 = scratch.ptr;
                const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;

                const n = try fast.decodeChunk(
                    dst_ptr,
                    dst_end_ptr,
                    dst_start_ptr,
                    src_slice_start,
                    src_slice_end,
                    scratch_ptr,
                    scratch_end_ptr,
                );
                if (n != comp_size) return error.SizeMismatch;
            },
            .high => {
                if (dst_off + dst_this_chunk + safe_space > dst.len) return error.OutputTooSmall;
                const src_slice_start: [*]const u8 = block_src[src_pos..].ptr;
                const src_slice_end: [*]const u8 = src_slice_start + comp_size;
                const dst_ptr: [*]u8 = dst[dst_off..].ptr;
                const dst_end_ptr: [*]u8 = dst_ptr + dst_this_chunk;
                // For SC mode, dst_start must be the FIRST chunk of the
                // current SC group (not the whole output) so that the
                // encoder's per-group `base_offset == 0` assumption holds
                // and the initial 8-byte Copy64 fires at each group start.
                // For non-SC, use the whole-buffer start (sliding window).
                const dst_start_ptr: [*]const u8 = if (is_sc) blk: {
                    const gs: usize = sc_group_size;
                    const group_start_chunk = (chunk_idx_in_block / gs) * gs;
                    const group_start_offset = sc_start_dst_off + group_start_chunk * constants.chunk_size;
                    break :blk dst[group_start_offset..].ptr;
                } else dst.ptr;
                const scratch_ptr: [*]u8 = scratch.ptr;
                const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;

                const n = try high.decodeChunk(
                    dst_ptr,
                    dst_end_ptr,
                    dst_start_ptr,
                    src_slice_start,
                    src_slice_end,
                    scratch_ptr,
                    scratch_end_ptr,
                );
                if (n != comp_size) return error.SizeMismatch;
            },
            else => return error.InvalidInternalHeader,
        }

        dst_off_inout.* += dst_this_chunk;
        dst_remaining -= dst_this_chunk;
        src_pos += comp_size;
        chunk_idx_in_block += 1;
    }

    // Any trailing source bytes in the frame block are a corruption signal.
    if (src_pos != block_src.len) return error.SizeMismatch;

    // SC: restore the first 8 bytes of each chunk (except chunk 0) from the
    // tail prefix table that we excluded from `block_src` above.
    if (prefix_size != 0) {
        const prefix_base: [*]const u8 = block_src_in[block_src_in.len - prefix_size ..].ptr;
        var i: usize = 0;
        while (i + 1 < num_chunks) : (i += 1) {
            const chunk_dst_off: usize = sc_start_dst_off + (i + 1) * constants.chunk_size;
            var copy_size: usize = 8;
            const remaining_in_chunk: usize = decompressed_size - (i + 1) * constants.chunk_size;
            if (copy_size > remaining_in_chunk) copy_size = remaining_in_chunk;
            @memcpy(
                dst[chunk_dst_off..][0..copy_size],
                prefix_base[i * 8 ..][0..copy_size],
            );
        }
    }
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decompressFramed roundtrips a tiny uncompressed L1 fixture (synthesized)" {
    const payload = "Hello, world\n";
    const content_size: u64 = payload.len;

    var buf: [256]u8 = undefined;
    const hdr_len = try frame.writeHeader(&buf, .{
        .codec = .fast,
        .level = 1,
        .content_size = content_size,
    });

    frame.writeBlockHeader(buf[hdr_len..], .{
        .compressed_size = payload.len,
        .decompressed_size = payload.len,
        .uncompressed = true,
        .parallel_decode_metadata = false,
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

test "decompressBlock roundtrips a raw compressed block (no frame wrapper)" {
    // Build a compressible payload large enough to clear min_source_length (128).
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 37) & 0xFF);
    // Inject a repeated region so the LZ parser has something to find.
    @memcpy(payload[100..164], payload[0..64]);
    @memcpy(payload[300..364], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    // Compress via the framed API, then strip the SLZ1 frame header + 8-byte
    // outer block header to get the raw inner compressed block that
    // `decompressBlock` expects.
    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    const hdr = try frame.parseHeader(framed[0..framed_len]);
    const bh = try frame.parseBlockHeader(framed[hdr.header_size..]);
    // Only validate the roundtrip when the encoder chose the compressed path.
    // For very short inputs the frame block may come back uncompressed.
    if (bh.uncompressed) return;
    const inner_start = hdr.header_size + 8;
    const inner = framed[inner_start .. inner_start + bh.compressed_size];

    var out: [1024]u8 = @splat(0);
    const written = try decompressBlock(inner, &out, payload.len);
    try testing.expectEqual(payload.len, written);
    try testing.expectEqualSlices(u8, &payload, out[0..payload.len]);
}

test "decompressBlockWithDict writes output at dst_offset for an uncompressed block" {
    // Hand-craft a minimal uncompressed internal block:
    //   byte 0: magic 0x5 | uncompressed flag 0x80
    //   byte 1: decoder type 0x01 (fast)
    //   bytes 2..N: raw payload
    // No SLZ1 frame wrapper, no outer 8-byte block header — exactly what
    // `decompressBlock` expects as input.
    //
    // The uncompressed path doesn't depend on `base_offset == 0` for an
    // initial Copy64, so it exercises the dst_offset plumbing cleanly. The
    // compressed path needs encoder-side dictionary support (D11) to test
    // end-to-end with dst_offset != 0.
    const payload_len: usize = 64;
    var block: [2 + payload_len]u8 = undefined;
    block[0] = 0x05 | 0x80; // magic nibble + uncompressed flag
    block[1] = 0x01; // decoder = fast
    for (block[2..], 0..) |*b, i| b.* = @intCast(i);

    const dict_len: usize = 100;
    var out: [256]u8 = @splat(0xAA);
    const written = try decompressBlockWithDict(&block, &out, dict_len, payload_len);
    try testing.expectEqual(payload_len, written);
    // Dictionary prefix untouched.
    for (out[0..dict_len]) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    // Decoded bytes land at dst[dict_len..dict_len + payload_len].
    for (out[dict_len .. dict_len + payload_len], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), b);
    }
    // Post-output trailing bytes untouched (except safe_space slack).
    for (out[dict_len + payload_len + safe_space ..]) |b| {
        try testing.expectEqual(@as(u8, 0xAA), b);
    }
}

test "decompressBlockWithDict matches decompressBlock when dst_offset == 0" {
    // Equivalence check: `decompressBlockWithDict(..., 0, ...)` must produce
    // identical output to `decompressBlock(..., ...)` on the same input.
    var payload: [384]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 17) & 0xFF);
    @memcpy(payload[128..192], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    const hdr = try frame.parseHeader(framed[0..framed_len]);
    const bh = try frame.parseBlockHeader(framed[hdr.header_size..]);
    if (bh.uncompressed) return;
    const inner_start = hdr.header_size + 8;
    const inner = framed[inner_start .. inner_start + bh.compressed_size];

    var out_a: [1024]u8 = @splat(0);
    var out_b: [1024]u8 = @splat(0);
    const n_a = try decompressBlock(inner, &out_a, payload.len);
    const n_b = try decompressBlockWithDict(inner, &out_b, 0, payload.len);
    try testing.expectEqual(n_a, n_b);
    try testing.expectEqualSlices(u8, out_a[0..n_a], out_b[0..n_b]);
    try testing.expectEqualSlices(u8, &payload, out_a[0..payload.len]);
}

test "decompressBlock rejects undersized output buffer" {
    const dummy_src = [_]u8{ 0x05, 0x01, 0x00, 0x00, 0x00, 0x00 };
    var out: [16]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, decompressBlock(&dummy_src, &out, 1024));
}

test "decompressStream roundtrips a compressed frame into a Writer" {
    var payload: [1024]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 23 + 11) & 0xFF);
    @memcpy(payload[200..264], payload[0..64]);
    @memcpy(payload[500..564], payload[0..64]);
    @memcpy(payload[800..864], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    var framed: [2048]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    var out_buf: [2048]u8 = @splat(0);
    var out_writer: std.Io.Writer = .fixed(&out_buf);
    const written = try decompressStream(
        allocator,
        framed[0..framed_len],
        &out_writer,
        .{},
    );
    try testing.expectEqual(@as(u64, payload.len), written);
    try testing.expectEqualSlices(u8, &payload, out_buf[0..payload.len]);
}

test "decompressStream enforces max_decompressed_size cap" {
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    var out_buf: [1024]u8 = @splat(0);
    var out_writer: std.Io.Writer = .fixed(&out_buf);
    const err = decompressStream(
        allocator,
        framed[0..framed_len],
        &out_writer,
        .{ .max_decompressed_size = 100 },
    );
    try testing.expectError(error.OutputTooSmall, err);
}

test "encoder sets RestartDecoder flag on first internal block header" {
    // Port parity check for A9: the encoder writes `keyframe` = true for
    // the first 256 KB block inside a frame, which sets bit 6 of the
    // 2-byte internal block header (`restart_decoder` on the decoder side).
    // C# consumers don't act on it but the flag IS written; confirm Zig
    // is consistent.
    var payload: [384]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    @memcpy(payload[64..128], payload[0..64]);

    const allocator = testing.allocator;
    const encoder = @import("../encode/streamlz_encoder.zig");

    var framed: [1024]u8 = undefined;
    const framed_len = try encoder.compressFramed(allocator, &payload, &framed, .{ .level = 1 });

    const hdr = try frame.parseHeader(framed[0..framed_len]);
    const bh = try frame.parseBlockHeader(framed[hdr.header_size..]);
    if (bh.uncompressed) return;
    const inner_start = hdr.header_size + 8;
    const internal = try block_header.parseBlockHeader(framed[inner_start..]);
    try testing.expect(internal.restart_decoder);
}

test "copyWholeMatch with large offset uses 8-byte chunks" {
    // Seed the buffer with a pattern, then call copyWholeMatch to copy
    // from earlier in the buffer to a new position.
    var buf: [64]u8 = undefined;
    for (buf[0..16], 0..) |*b, i| b.* = @intCast(i + 1); // [1..16]
    // Copy buf[0..16] to buf[32..48] via copyWholeMatch(dst=buf+32, offset=32, length=16).
    copyWholeMatch(buf[32..].ptr, 32, 16);
    for (buf[32..48], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @intCast(i + 1)), b);
    }
}

test "copyWholeMatch with small offset uses scalar path" {
    // offset < 8 exercises the byte-at-a-time tail loop (no 8-byte chunking
    // because a wide load would read unwritten bytes past the write cursor).
    var buf: [32]u8 = @splat(0);
    buf[0] = 0xAA;
    // Copy buf[0..1] → buf[1..5] with offset=1 → repeats the byte.
    copyWholeMatch(buf[1..].ptr, 1, 4);
    try testing.expectEqual(@as(u8, 0xAA), buf[1]);
    try testing.expectEqual(@as(u8, 0xAA), buf[2]);
    try testing.expectEqual(@as(u8, 0xAA), buf[3]);
    try testing.expectEqual(@as(u8, 0xAA), buf[4]);
}

test "decompressStream handles empty source" {
    const allocator = testing.allocator;
    var out_buf: [16]u8 = undefined;
    var out_writer: std.Io.Writer = .fixed(&out_buf);
    const written = try decompressStream(
        allocator,
        &[_]u8{},
        &out_writer,
        .{},
    );
    try testing.expectEqual(@as(u64, 0), written);
}
