//! Parallel decompression helpers for phase 13.
//!
//! Port of `StreamLzDecoder.DecompressCoreParallel` + `PreScanChunks`
//! from `src/StreamLZ/Decompression/StreamLzDecoder.cs`. This module
//! provides the SC (self-contained) parallel decode path used by
//! unified levels L6-L8. The two-phase path for L9-L11 lives in
//! step 36 (see `decompressCoreTwoPhase`).
//!
//! SC semantics refresher: self-contained blocks chunk the output into
//! `sc_group_size`-sized groups (4 chunks = 1 MB). Within a group,
//! chunks may LZ-reference earlier chunks in the same group (so they
//! must be decoded serially). Between groups, no back-references are
//! allowed, so groups can run in parallel. After the main decode,
//! the encoder's tail prefix table restores the first 8 bytes of
//! every chunk except the first chunk in each group (actually every
//! chunk except chunk 0, but within a group the earlier chunks have
//! already written correct bytes — the tail prefix is a belt-and-
//! suspenders mechanism matching the C# wire format).

const std = @import("std");
const block_header = @import("../format/block_header.zig");
const constants = @import("../format/streamlz_constants.zig");
const fast = @import("fast_lz_decoder.zig");
const high = @import("high_lz_decoder.zig");

pub const DecodeError = error{
    Truncated,
    SizeMismatch,
    InvalidInternalHeader,
    BadChunkHeader,
    BlockDataTruncated,
    OutputTooSmall,
    ChunkSizeMismatch,
} || fast.DecodeError || high.DecodeError || std.mem.Allocator.Error || std.Thread.SpawnError || std.Thread.CpuCountError;

/// Describes a single 256 KB-output-sized chunk within a compressed
/// block, annotated with its byte ranges in both input and output.
/// Populated by `preScanBlock`; consumed by the per-thread workers.
pub const ChunkScanInfo = struct {
    /// Offset of the chunk's 2-byte internal block header inside `block_src`.
    src_offset: usize,
    /// Total bytes spanned by this chunk in `block_src` (2-byte hdr +
    /// 4-byte chunk hdr + compressed payload, or 2-byte hdr + raw
    /// payload for uncompressed chunks).
    src_size: usize,
    /// Offset of this chunk's output in `dst` (absolute, relative to
    /// the start of the frame block's output region).
    dst_offset: usize,
    /// Decompressed byte count for this chunk (typically `chunk_size`,
    /// smaller for the tail chunk).
    dst_size: usize,
    /// Decoder type for this chunk (High / Fast / Turbo).
    decoder_type: block_header.CodecType,
};

pub const PreScanResult = struct {
    chunks: []ChunkScanInfo,
    /// Byte range reserved for the tail prefix table at the end of
    /// `block_src` (excluded from the per-chunk byte ranges).
    prefix_size: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PreScanResult) void {
        self.allocator.free(self.chunks);
    }
};

/// Walks a compressed frame block and produces a list of chunk
/// boundaries. Mirrors C# `PreScanChunks` at `StreamLzDecoder.cs:587`.
/// Accepts the full frame-block payload *including* the tail prefix
/// table (when SC); callers that need prefix-excluded byte ranges can
/// read `prefix_size` from the result.
pub fn preScanBlock(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    decompressed_size: usize,
) !PreScanResult {
    // Upper bound on chunk count so we can pre-allocate the list.
    const max_chunks: usize = (decompressed_size + constants.chunk_size - 1) / constants.chunk_size + 1;
    var chunks = try std.ArrayList(ChunkScanInfo).initCapacity(allocator, max_chunks);
    errdefer chunks.deinit(allocator);

    var src_pos: usize = 0;
    var dst_off: usize = 0;
    var dst_rem: usize = decompressed_size;

    while (dst_rem > 0) {
        if (src_pos + block_header.BlockHeader.size > block_src.len) {
            // Ran into the tail prefix area — stop.
            break;
        }
        const chunk_src_start = src_pos;
        const bh = block_header.parseBlockHeader(block_src[src_pos..]) catch return error.InvalidInternalHeader;
        src_pos += block_header.BlockHeader.size;

        const is_high = bh.decoder_type == .high or bh.decoder_type == .fast;
        const chunk_cap: usize = if (is_high) constants.chunk_size else 0x4000;
        const dst_bytes: usize = @min(chunk_cap, dst_rem);

        if (bh.uncompressed) {
            if (src_pos + dst_bytes > block_src.len) return error.Truncated;
            src_pos += dst_bytes;
        } else {
            const ch = block_header.parseChunkHeader(block_src[src_pos..], bh.use_checksums) catch return error.BadChunkHeader;
            src_pos += ch.bytes_consumed;
            if (ch.is_memset) {
                // No payload — chunk is 4-byte header only.
            } else {
                if (src_pos + ch.compressed_size > block_src.len) return error.Truncated;
                src_pos += ch.compressed_size;
            }
        }

        try chunks.append(allocator, .{
            .src_offset = chunk_src_start,
            .src_size = src_pos - chunk_src_start,
            .dst_offset = dst_off,
            .dst_size = dst_bytes,
            .decoder_type = bh.decoder_type,
        });

        dst_off += dst_bytes;
        dst_rem -= dst_bytes;
    }

    // The tail prefix table is `(num_chunks - 1) * 8` bytes past the
    // last chunk's src_end when the block was encoded as SC. Callers
    // that need it should compute it themselves; this function only
    // reports chunk boundaries.
    const num_chunks: usize = chunks.items.len;
    const prefix_size: usize = if (num_chunks > 1) (num_chunks - 1) * 8 else 0;

    return .{
        .chunks = try chunks.toOwnedSlice(allocator),
        .prefix_size = prefix_size,
        .allocator = allocator,
    };
}

// ────────────────────────────────────────────────────────────
//  SC parallel decode
// ────────────────────────────────────────────────────────────

/// Shared context threaded through the worker functions. A single
/// instance lives on the stack of `decompressCoreParallel` for the
/// duration of a call; workers only read from it.
const Shared = struct {
    chunks: []const ChunkScanInfo,
    block_src: []const u8,
    dst: []u8,
    dst_start_off: usize,
    group_size: usize,
    next_group: std.atomic.Value(usize),
    error_flag: std.atomic.Value(u32),
    /// First error code captured by a worker — used by the main
    /// thread to re-raise after join. Encoded as an anyerror.
    captured_err: std.atomic.Value(u16),
};

fn workerFn(shared: *Shared, scratch: []u8) void {
    const num_groups = (shared.chunks.len + shared.group_size - 1) / shared.group_size;
    while (true) {
        const group_idx = shared.next_group.fetchAdd(1, .monotonic);
        if (group_idx >= num_groups) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

        const first_chunk = group_idx * shared.group_size;
        const last_chunk: usize = @min(first_chunk + shared.group_size, shared.chunks.len);
        const group_dst_off = shared.dst_start_off + shared.chunks[first_chunk].dst_offset;

        decodeGroup(
            shared.chunks[first_chunk..last_chunk],
            shared.block_src,
            shared.dst,
            shared.dst_start_off,
            group_dst_off,
            scratch,
        ) catch |err| {
            const code: u16 = @intFromError(err);
            // Only the first error sticks.
            _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        };
    }
}

fn decodeGroup(
    group_chunks: []const ChunkScanInfo,
    block_src: []const u8,
    dst: []u8,
    dst_start_off: usize,
    group_dst_off: usize,
    scratch: []u8,
) DecodeError!void {
    for (group_chunks) |q| {
        const chunk_dst_off = dst_start_off + q.dst_offset;
        try decodeOneChunk(
            block_src[q.src_offset .. q.src_offset + q.src_size],
            dst,
            chunk_dst_off,
            q.dst_size,
            group_dst_off,
            scratch,
        );
    }
}

/// Decode a single chunk (2-byte block hdr + optional 4-byte chunk
/// hdr + payload) into `dst[dst_off..][0..dst_size]`. Mirrors the
/// inner body of `streamlz_decoder.decompressCompressedBlock` but
/// operates on a pre-sliced chunk-sized source range.
fn decodeOneChunk(
    src: []const u8,
    dst: []u8,
    dst_off: usize,
    dst_size: usize,
    group_dst_start_off: usize,
    scratch: []u8,
) DecodeError!void {
    if (src.len < block_header.BlockHeader.size) return error.Truncated;
    const bh = block_header.parseBlockHeader(src) catch return error.InvalidInternalHeader;
    var src_pos: usize = block_header.BlockHeader.size;

    // Uncompressed chunk: raw memcpy.
    if (bh.uncompressed) {
        if (src_pos + dst_size > src.len) return error.Truncated;
        if (dst_off + dst_size > dst.len) return error.OutputTooSmall;
        @memcpy(dst[dst_off..][0..dst_size], src[src_pos..][0..dst_size]);
        return;
    }

    // 4-byte chunk header + payload.
    const ch = block_header.parseChunkHeader(src[src_pos..], bh.use_checksums) catch return error.BadChunkHeader;
    src_pos += ch.bytes_consumed;

    if (ch.is_memset) {
        if (dst_off + dst_size > dst.len) return error.OutputTooSmall;
        @memset(dst[dst_off..][0..dst_size], ch.memset_fill);
        return;
    }

    const comp_size: usize = ch.compressed_size;
    if (src_pos + comp_size > src.len) return error.Truncated;
    if (comp_size > dst_size) return error.BadChunkHeader;

    if (comp_size == dst_size) {
        if (dst_off + dst_size > dst.len) return error.OutputTooSmall;
        @memcpy(dst[dst_off..][0..dst_size], src[src_pos..][0..dst_size]);
        return;
    }

    // Codec dispatch. For SC mode the dst_start for High must be the
    // start of the current SC group (not the whole buffer) — that's
    // `group_dst_start_off` in the caller.
    const src_slice_start: [*]const u8 = src[src_pos..].ptr;
    const src_slice_end: [*]const u8 = src_slice_start + comp_size;
    const dst_ptr: [*]u8 = dst[dst_off..].ptr;
    const dst_end_ptr: [*]u8 = dst_ptr + dst_size;
    const scratch_ptr: [*]u8 = scratch.ptr;
    const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;

    switch (bh.decoder_type) {
        .fast, .turbo => {
            const n = try fast.decodeChunk(
                dst_ptr,
                dst_end_ptr,
                dst.ptr,
                src_slice_start,
                src_slice_end,
                scratch_ptr,
                scratch_end_ptr,
            );
            if (n != comp_size) return error.ChunkSizeMismatch;
        },
        .high => {
            const dst_start_ptr: [*]const u8 = dst[group_dst_start_off..].ptr;
            const n = try high.decodeChunk(
                dst_ptr,
                dst_end_ptr,
                dst_start_ptr,
                src_slice_start,
                src_slice_end,
                scratch_ptr,
                scratch_end_ptr,
            );
            if (n != comp_size) return error.ChunkSizeMismatch;
        },
        else => return error.InvalidInternalHeader,
    }
}

/// Decompress a self-contained compressed frame block in parallel.
/// Mirrors C# `DecompressCoreParallel` at `StreamLzDecoder.cs:689`.
///
/// Splits the block's chunks into `sc_group_size`-sized groups and
/// dispatches one thread per active group via work-stealing. Each
/// worker owns a dedicated scratch buffer (442 KB), decodes its
/// groups sequentially inside, and drops back into the pool. After
/// all workers complete, the tail prefix table is restored.
///
/// `block_src` is the full frame-block payload *including* the tail
/// prefix bytes. `dst_off_inout` is advanced by `decompressed_size`
/// on success.
pub fn decompressCoreParallel(
    allocator: std.mem.Allocator,
    block_src: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
) DecodeError!void {
    // Pre-scan to count chunks and compute prefix size. The pre-scan
    // walks headers only and doesn't read into the tail prefix region.
    var scan = try preScanBlock(allocator, block_src, decompressed_size);
    defer scan.deinit();

    const num_chunks = scan.chunks.len;
    if (num_chunks == 0) return;
    const prefix_size = scan.prefix_size;
    if (prefix_size > block_src.len) return error.Truncated;

    // Sanity-check: the last chunk's src_end + prefix_size must not
    // exceed the buffer.
    const last_src_end: usize = scan.chunks[num_chunks - 1].src_offset + scan.chunks[num_chunks - 1].src_size;
    if (last_src_end + prefix_size > block_src.len) return error.Truncated;

    const dst_start_off = dst_off_inout.*;
    if (dst_start_off + decompressed_size + 64 > dst.len) return error.OutputTooSmall;

    // Worker count: min(num_groups, cpu_count).
    const group_size = constants.sc_group_size;
    const num_groups = (num_chunks + group_size - 1) / group_size;
    const cpu_count_raw: usize = std.Thread.getCpuCount() catch 1;
    const worker_count: usize = @min(num_groups, @max(@as(usize, 1), cpu_count_raw));

    // Per-worker scratch.
    const scratches = try allocator.alloc([]u8, worker_count);
    defer {
        for (scratches) |s| if (s.len != 0) allocator.free(s);
        allocator.free(scratches);
    }
    for (scratches) |*s| s.* = &[_]u8{};
    for (scratches) |*s| s.* = try allocator.alloc(u8, constants.scratch_size);

    // Shared coordinator.
    var shared: Shared = .{
        .chunks = scan.chunks,
        .block_src = block_src,
        .dst = dst,
        .dst_start_off = dst_start_off,
        .group_size = group_size,
        .next_group = std.atomic.Value(usize).init(0),
        .error_flag = std.atomic.Value(u32).init(0),
        .captured_err = std.atomic.Value(u16).init(0),
    };

    // Fast path: single worker. Skip thread spawn entirely.
    if (worker_count == 1) {
        workerFn(&shared, scratches[0]);
    } else {
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, workerFn, .{ &shared, scratches[spawned] }) catch |err| {
                // Spawn failed — join any we did spawn and propagate.
                for (threads[0..spawned]) |t| t.join();
                return err;
            };
        }
        for (threads) |t| t.join();
    }

    if (shared.error_flag.load(.monotonic) != 0) {
        const code = shared.captured_err.load(.monotonic);
        if (code != 0) {
            // Re-raise the first error captured by any worker. The
            // runtime error table gives every error a stable u16 code
            // we can round-trip via `@errorFromInt` → `@errorCast`
            // into our narrower `DecodeError` set.
            const any_err: anyerror = @errorFromInt(code);
            const narrow: DecodeError = @errorCast(any_err);
            return narrow;
        }
        return error.BadChunkHeader;
    }

    // Tail prefix restoration. Mirror of the serial path: overwrite
    // the first 8 bytes of every chunk except chunk 0 with the bytes
    // stored in the tail prefix table.
    if (prefix_size > 0) {
        const prefix_base: [*]const u8 = block_src[block_src.len - prefix_size ..].ptr;
        var i: usize = 0;
        while (i + 1 < num_chunks) : (i += 1) {
            const chunk_dst_off: usize = dst_start_off + (i + 1) * constants.chunk_size;
            const chunk_dst_size = scan.chunks[i + 1].dst_size;
            var copy_size: usize = 8;
            if (copy_size > chunk_dst_size) copy_size = chunk_dst_size;
            @memcpy(
                dst[chunk_dst_off..][0..copy_size],
                prefix_base[i * 8 ..][0..copy_size],
            );
        }
    }

    dst_off_inout.* += decompressed_size;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;
const encoder = @import("../encode/streamlz_encoder.zig");
const decoder = @import("streamlz_decoder.zig");

fn parallelRoundtrip(source: []const u8, level: u8) !void {
    const allocator = testing.allocator;
    const bound = encoder.compressBound(source.len);
    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);

    const n = try encoder.compressFramed(allocator, source, compressed, .{ .level = level });
    try testing.expect(n > 0);
    try testing.expect(n <= bound);

    // Serial path first — acts as a regression guard and isolates
    // encoder bugs from parallel-decoder bugs.
    const decoded_ser = try allocator.alloc(u8, source.len + decoder.safe_space);
    defer allocator.free(decoded_ser);
    const written_ser = try decoder.decompressFramed(compressed[0..n], decoded_ser);
    try testing.expectEqual(source.len, written_ser);
    try testing.expectEqualSlices(u8, source, decoded_ser[0..written_ser]);

    // Parallel path.
    const decoded_par = try allocator.alloc(u8, source.len + decoder.safe_space);
    defer allocator.free(decoded_par);
    const written_par = try decoder.decompressFramedParallel(
        allocator,
        compressed[0..n],
        decoded_par,
    );
    try testing.expectEqual(source.len, written_par);
    try testing.expectEqualSlices(u8, source, decoded_par[0..written_par]);
}

test "decompressFramedParallel: L6 SC 384 KB (multi-chunk, exercises parallel path)" {
    // 384 KB is 1.5 chunks so SC produces exactly 2 chunks + 1 prefix entry.
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try parallelRoundtrip(&src, 6);
}

test "decompressFramedParallel: L6 SC 1 MB (one full SC group)" {
    // sc_group_size = 4 chunks = 1 MB → exactly one parallel worker.
    var src: [1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try parallelRoundtrip(&src, 6);
}

test "decompressFramedParallel: L6 SC 2 MB (two full SC groups, real parallelism)" {
    // 2 MB = 8 chunks = 2 SC groups → two workers, tests real parallel
    // dispatch. Requires the encoder's SC group-relative start_pos
    // fix (`src_off + sub_off` mod `sc_group_bytes`) to produce
    // within-group-only LZ references.
    var src: [2 * 1024 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try parallelRoundtrip(&src, 6);
}

test "decompressFramedParallel: L7 SC 1 MB (hash-based L7)" {
    var src: [1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try parallelRoundtrip(&src, 7);
}

test "decompressFramedParallel: L8 SC 1 MB (BT4 path)" {
    var src: [1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try parallelRoundtrip(&src, 8);
}

test "decompressFramedParallel: non-SC L9 falls through to serial" {
    // L9 is non-SC in the mapping, so the parallel entry point should
    // not dispatch to the SC parallel path — the serial loop handles
    // it and the result is still correct.
    var src: [8192]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try parallelRoundtrip(&src, 9);
}
