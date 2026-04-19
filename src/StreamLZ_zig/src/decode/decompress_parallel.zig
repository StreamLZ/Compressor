//! Parallel decompression helpers.
//!
//! Three parallel strategies, dispatched by the caller based on the
//! compression level stored in the frame header:
//!
//!   **Strategy 1 — Sidecar Fast (L1-L5): `decompressFastL14Parallel`**
//!     Preconditions (encoder contract):
//!       - Frame carries a parallel_decode_metadata sidecar block whose
//!         literal-byte leaves cover every cross-sub-chunk dependency.
//!       - Worker slices are 16-chunk aligned so that sidecar boundary
//!         positions never fall mid-slice.
//!     The sidecar is applied to `dst` in a serial pre-pass (phase 1),
//!     then per-chunk Fast decode runs fully in parallel (phase 2).
//!
//!   **Strategy 2 — SC groups (L6-L8): `decompressCoreParallel`**
//!     Preconditions (encoder contract):
//!       - Blocks are encoded as self-contained (SC): LZ back-references
//!         never cross an `sc_group_size`-chunk boundary.
//!       - A tail prefix table of `(num_chunks - 1) * 8` bytes is
//!         appended after the last chunk's compressed data.
//!     Groups of `sc_group_size` chunks run in parallel; chunks within
//!     a group are decoded serially (intra-group refs are allowed).
//!     After all workers join, the tail prefix table restores the first
//!     8 bytes of every chunk except chunk 0.
//!
//!   **Strategy 3 — Two-phase High (L9-L11): `decompressCoreTwoPhase`**
//!     Preconditions (encoder contract):
//!       - All chunks in the block use the High codec (no Fast/Turbo).
//!       - No SC grouping; chunks may back-reference any earlier output.
//!     Phase 1 (parallel): entropy-decode (`readLzTable`) each chunk
//!     into a per-chunk scratch region. Phase 2 (serial): resolve
//!     match runs (`processLzRuns`) in chunk order since each chunk's
//!     matches depend on earlier output being fully materialized.
//!
//! SC semantics detail: self-contained blocks chunk the output into
//! `sc_group_size`-sized groups (4 chunks = 1 MB). Within a group,
//! chunks may LZ-reference earlier chunks in the same group (so they
//! must be decoded serially). Between groups, no back-references are
//! allowed, so groups can run in parallel. After the main decode,
//! the tail prefix table restores the first 8 bytes of every chunk
//! except the first chunk in each group (actually every chunk except
//! chunk 0, but within a group the earlier chunks have already written
//! correct bytes — the tail prefix is a belt-and-suspenders mechanism
//! matching the wire format).

const std = @import("std");
const block_header = @import("../format/block_header.zig");
const constants = @import("../format/streamlz_constants.zig");
const pdm = @import("../format/parallel_decode_metadata.zig");
const fast = @import("fast/fast_lz_decoder.zig");
const high = @import("high/high_lz_decoder.zig");
const high_runs = @import("high/high_lz_token_executor.zig");

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
/// boundaries. Accepts the full frame-block payload *including* the tail prefix
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
        const block_hdr= block_header.parseBlockHeader(block_src[src_pos..]) catch return error.InvalidInternalHeader;
        src_pos += block_header.BlockHeader.size;

        const is_high = block_hdr.decoder_type == .high or block_hdr.decoder_type == .fast;
        const chunk_cap: usize = if (is_high) constants.chunk_size else 0x4000;
        const dst_bytes: usize = @min(chunk_cap, dst_rem);

        if (block_hdr.uncompressed) {
            if (src_pos + dst_bytes > block_src.len) return error.Truncated;
            src_pos += dst_bytes;
        } else {
            const ch = block_header.parseChunkHeader(block_src[src_pos..], block_hdr.use_checksums) catch return error.BadChunkHeader;
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
            .decoder_type = block_hdr.decoder_type,
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

/// SC work-stealing worker. Claims groups atomically via `next_group`
/// and decodes each group's chunks serially. Safe because the encoder
/// guarantees no LZ back-references cross group boundaries, so each
/// group is fully self-contained and independent of other groups.
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
    const block_hdr= block_header.parseBlockHeader(src) catch return error.InvalidInternalHeader;
    var src_pos: usize = block_header.BlockHeader.size;

    // Uncompressed chunk: raw memcpy.
    if (block_hdr.uncompressed) {
        if (src_pos + dst_size > src.len) return error.Truncated;
        if (dst_off + dst_size > dst.len) return error.OutputTooSmall;
        @memcpy(dst[dst_off..][0..dst_size], src[src_pos..][0..dst_size]);
        return;
    }

    // 4-byte chunk header + payload.
    const ch = block_header.parseChunkHeader(src[src_pos..], block_hdr.use_checksums) catch return error.BadChunkHeader;
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

    switch (block_hdr.decoder_type) {
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
///
/// Encoder contract:
///   - The encoder MUST produce SC blocks where no LZ back-reference
///     crosses an `sc_group_size`-chunk boundary. If this invariant is
///     violated, parallel workers will read stale/zero bytes from
///     output regions owned by other workers, producing silent corruption.
///   - A tail prefix table of exactly `(num_chunks - 1) * 8` bytes MUST
///     be appended after the last chunk's compressed data. If missing or
///     truncated, the first 8 bytes of each chunk (except chunk 0) will
///     retain whatever the LZ decoder wrote, which may differ from the
///     serial-decode result.
///
/// Caller contract:
///   - `dst` MUST have at least `decompressed_size + 64` bytes available
///     from `dst_off_inout.*` onward. The extra 64 bytes absorb overcopy
///     from SIMD `wildCopy16` at the end of the last chunk.
///   - `sc_group_size` MUST be > 0 (typically 4, from the frame header).
pub fn decompressCoreParallel(
    allocator: std.mem.Allocator,
    pool_opt: ?*std.Thread.Pool,
    block_src: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    sc_group_size: u8,
    max_threads: usize,
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

    // -- Invariant assertions (debug only) --
    // sc_group_size must be positive; zero would cause division-by-zero
    // in the group count calculation below.
    std.debug.assert(sc_group_size > 0);
    // The dst buffer must have safe_space padding (64 bytes) beyond the
    // decompressed region for SIMD wildCopy16 overcopy at chunk tails.
    std.debug.assert(dst.len >= dst_start_off + decompressed_size + 64);

    // Worker count: min(num_groups, cpu_count).
    //
    // v2: `group_size` is now taken from the frame header rather than
    // the compile-time `constants.sc_group_size` constant. Encoders may
    // eventually pick different sizes without a format bump.
    const group_size: usize = sc_group_size;
    const num_groups = (num_chunks + group_size - 1) / group_size;
    var cpu_count_raw: usize = if (max_threads > 0) max_threads else std.Thread.getCpuCount() catch 1;
    if (max_threads == 0) {
        if (std.process.getEnvVarOwned(allocator, "SLZ_CORES") catch null) |val| {
            defer allocator.free(val);
            cpu_count_raw = std.fmt.parseInt(usize, val, 10) catch cpu_count_raw;
        }
    }
    const worker_count: usize = @min(num_groups, @max(@as(usize, 1), cpu_count_raw));
    // Worker count must be at least 1; zero workers would silently skip
    // all decode work and return success with an uninitialized dst.
    std.debug.assert(worker_count > 0);

    // Per-worker scratch. Sized to scratch_size * 2 (matching the
    // two-phase path) so the token array overflow into the heap
    // fallback is rare for L6-L8 SC. With 24 workers × 884 KB ≈ 21 MB
    // total → fits in the 36 MB L3 (the 1.9 MB-per-worker experiment
    // overflowed L3 at 46 MB; see FailedExperiments.md).
    const sc_scratch_bytes: usize = constants.scratch_size * 2;
    const scratches = try allocator.alloc([]u8, worker_count);
    defer {
        for (scratches) |s| if (s.len != 0) allocator.free(s);
        allocator.free(scratches);
    }
    for (scratches) |*s| s.* = &[_]u8{};
    for (scratches) |*s| s.* = try allocator.alloc(u8, sc_scratch_bytes);

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

    // Fast path: single worker. Skip pool dispatch entirely.
    if (worker_count == 1) {
        workerFn(&shared, scratches[0]);
    } else if (pool_opt) |pool| {
        // Pool path: persistent thread pool reused across frame blocks.
        // Avoids std.Thread.spawn syscall + new OS thread per call.
        var wg: std.Thread.WaitGroup = .{};
        for (0..worker_count) |i| {
            pool.spawnWg(&wg, workerFn, .{ &shared, scratches[i] });
        }
        pool.waitAndWork(&wg);
    } else {
        // Fallback: spawn one-shot threads (used when caller didn't
        // hand us a pool — currently only the test path).
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, workerFn, .{ &shared, scratches[spawned] }) catch |err| {
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
//  Two-phase parallel decode (L9-L11, non-SC High)
// ────────────────────────────────────────────────────────────
//
// The High codec's decoding time is dominated by entropy decode
// (`readLzTable`), not match resolve (`processLzRuns`). We
// parallelize the expensive phase and keep the sequentially-
// dependent phase serial.
//
// Per batch of `batch_size` chunks:
//   Phase 2 (parallel): `phase1ProcessChunk` runs entropy decode on
//     each chunk into the chunk's dedicated scratch region (one
//     region per chunk). Produces a `ChunkPhase1Result` recording
//     each sub-chunk's mode / dst_offset / dst_size / is_lz plus
//     the `HighLzTable` pointer into scratch.
//   Phase 3 (serial): the main thread walks the batch in order,
//     calling `processLzRuns` on each LZ sub-chunk. Each sub-chunk
//     depends on earlier output being fully materialized, which is
//     why this phase stays serial.

const TpShared = struct {
    chunks: []const ChunkScanInfo,
    block_src: []const u8,
    dst: []u8,
    dst_start_off: usize,
    /// Per-chunk `ChunkPhase1Result`, indexed relative to `batch_start`.
    phase1_results: []high.ChunkPhase1Result,
    /// Per-chunk scratch regions (one per chunk in the batch). Each
    /// region is `scratch_per_chunk` bytes and holds BOTH sub-chunks'
    /// HighLzTable + decoded streams.
    scratch_ptrs: []const []u8,
    /// Work-stealing counter: the next chunk index within this batch
    /// to claim. Resets to zero at the start of every batch.
    next_chunk: std.atomic.Value(usize),
    error_flag: std.atomic.Value(u32),
    captured_err: std.atomic.Value(u16),
    batch_start: usize,
    batch_count: usize,
};

fn tpWorkerFn(shared: *TpShared) void {
    while (true) {
        const local_idx = shared.next_chunk.fetchAdd(1, .monotonic);
        if (local_idx >= shared.batch_count) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

        const chunk_idx = shared.batch_start + local_idx;
        const q = shared.chunks[chunk_idx];
        const scratch = shared.scratch_ptrs[local_idx];

        tpPhase1OneChunk(
            q,
            shared.block_src,
            shared.dst,
            shared.dst_start_off,
            scratch,
            &shared.phase1_results[local_idx],
        ) catch |err| {
            const code: u16 = @intFromError(err);
            _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        };
    }
}

fn tpPhase1OneChunk(
    q: ChunkScanInfo,
    block_src: []const u8,
    dst: []u8,
    dst_start_off: usize,
    scratch: []u8,
    result: *high.ChunkPhase1Result,
) DecodeError!void {
    result.* = .{};

    const src = block_src[q.src_offset .. q.src_offset + q.src_size];
    if (src.len < block_header.BlockHeader.size) return error.Truncated;
    const block_hdr= block_header.parseBlockHeader(src) catch return error.InvalidInternalHeader;
    var src_pos: usize = block_header.BlockHeader.size;

    const chunk_dst_off = dst_start_off + q.dst_offset;

    // Uncompressed chunk: raw memcpy. Nothing for phase 2 to do.
    if (block_hdr.uncompressed) {
        if (src_pos + q.dst_size > src.len) return error.Truncated;
        if (chunk_dst_off + q.dst_size > dst.len) return error.OutputTooSmall;
        @memcpy(dst[chunk_dst_off..][0..q.dst_size], src[src_pos..][0..q.dst_size]);
        result.is_special = true;
        result.sub_chunk_count = 0;
        return;
    }

    // 4-byte chunk header + payload.
    const ch = block_header.parseChunkHeader(src[src_pos..], block_hdr.use_checksums) catch return error.BadChunkHeader;
    src_pos += ch.bytes_consumed;

    if (ch.is_memset) {
        if (chunk_dst_off + q.dst_size > dst.len) return error.OutputTooSmall;
        if (ch.whole_match_distance != 0) {
            result.is_special = true;
            result.is_whole_match = true;
            result.whole_match_distance = ch.whole_match_distance;
            // Phase 2 will perform the whole-match copy since it needs
            // the earlier output to have been resolved first.
        } else {
            @memset(dst[chunk_dst_off..][0..q.dst_size], ch.memset_fill);
            result.is_special = true;
        }
        result.sub_chunk_count = 0;
        return;
    }

    const comp_size: usize = ch.compressed_size;
    if (src_pos + comp_size > src.len) return error.Truncated;
    if (comp_size > q.dst_size) return error.BadChunkHeader;

    if (comp_size == q.dst_size) {
        // Stored raw within a "compressed" flag block.
        if (chunk_dst_off + q.dst_size > dst.len) return error.OutputTooSmall;
        @memcpy(dst[chunk_dst_off..][0..q.dst_size], src[src_pos..][0..q.dst_size]);
        result.is_special = true;
        result.sub_chunk_count = 0;
        return;
    }

    // Normal compressed chunk — dispatch to `phase1ProcessChunk` which
    // walks the 1 or 2 sub-chunks and runs `readLzTable` on each.
    switch (block_hdr.decoder_type) {
        .high => {
            const dst_ptr: [*]u8 = dst[chunk_dst_off..].ptr;
            const dst_end_ptr: [*]u8 = dst_ptr + q.dst_size;
            const src_slice_start: [*]const u8 = src[src_pos..].ptr;
            const src_slice_end: [*]const u8 = src_slice_start + comp_size;
            const scratch_ptr: [*]u8 = scratch.ptr;
            const scratch_end_ptr: [*]u8 = scratch.ptr + scratch.len;
            _ = try high.phase1ProcessChunk(
                dst_ptr,
                dst_end_ptr,
                dst.ptr,
                src_slice_start,
                src_slice_end,
                scratch_ptr,
                scratch_end_ptr,
                result,
            );
        },
        else => return error.InvalidInternalHeader,
    }
}

/// Decompress a non-SC High compressed frame block via parallel
/// entropy-decode + serial match-resolve. All chunks in the block
/// must be High-decoder; if any is Fast/Turbo the caller falls
/// back to the serial path.
///
/// Encoder contract:
///   - Every chunk in the block MUST use the High codec. If any chunk
///     is Fast or Turbo, this function returns `false` (fall back to
///     serial) rather than producing incorrect output.
///   - Chunks may back-reference any earlier output (no SC constraint).
///     This is safe because phase 2 (match-resolve) runs serially in
///     chunk order, so all prior output is materialized before each
///     chunk's `processLzRuns` executes.
///
/// Caller contract:
///   - `dst` MUST have at least `decompressed_size + 64` bytes from
///     `dst_off_inout.*` onward (same safe_space as SC path).
///   - Returns `false` without modifying `dst` when the block is not
///     eligible (single chunk or mixed codec types). The caller must
///     then use the serial decode path.
pub fn decompressCoreTwoPhase(
    allocator: std.mem.Allocator,
    pool_opt: ?*std.Thread.Pool,
    block_src: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    max_threads: usize,
) DecodeError!bool {
    // Pre-scan all chunks (no tail-prefix for non-SC).
    var scan = try preScanBlock(allocator, block_src, decompressed_size);
    defer scan.deinit();
    const num_chunks = scan.chunks.len;
    if (num_chunks <= 1) return false; // fall back to serial

    // Require uniform High decoder — otherwise bail to serial.
    for (scan.chunks) |q| {
        if (q.decoder_type != .high) return false;
    }

    const dst_start_off = dst_off_inout.*;
    if (dst_start_off + decompressed_size + 64 > dst.len) return error.OutputTooSmall;

    // -- Invariant assertions (debug only) --
    // Safe-space padding must be present for SIMD wildCopy16 overcopy.
    std.debug.assert(dst.len >= dst_start_off + decompressed_size + 64);

    var cpu_count_raw: usize = if (max_threads > 0) max_threads else std.Thread.getCpuCount() catch 1;
    if (max_threads == 0) {
        if (std.process.getEnvVarOwned(allocator, "SLZ_CORES") catch null) |val| {
            defer allocator.free(val);
            cpu_count_raw = std.fmt.parseInt(usize, val, 10) catch cpu_count_raw;
        }
    }
    const batch_size: usize = @max(@as(usize, 1), cpu_count_raw);
    // Per-chunk scratch: 2 sub-chunks, each up to `scratch_size` bytes.
    // Tested bumping this to fit the worst-case token array (1 MB) but
    // it overflows L2 (2.5 MB per core) → executeTokensType1 went +48%
    // from L2 misses on the token reads. The 4% CPU we save on the
    // libc free_base path is way smaller than the cache penalty, so
    // we keep the heap fallback as the rare-case safety net.
    const scratch_per_chunk: usize = constants.scratch_size * 2;

    // Allocate `batch_size` scratches upfront; reused across batches.
    const scratches = try allocator.alloc([]u8, batch_size);
    defer {
        for (scratches) |s| if (s.len != 0) allocator.free(s);
        allocator.free(scratches);
    }
    for (scratches) |*s| s.* = &[_]u8{};
    for (scratches) |*s| s.* = try allocator.alloc(u8, scratch_per_chunk);

    const phase1_results = try allocator.alloc(high.ChunkPhase1Result, batch_size);
    defer allocator.free(phase1_results);

    // One-shot thread fallback only used when no pool is provided.
    const threads = try allocator.alloc(std.Thread, batch_size);
    defer allocator.free(threads);

    var batch_start: usize = 0;
    while (batch_start < num_chunks) {
        const batch_end = @min(batch_start + batch_size, num_chunks);
        const batch_count = batch_end - batch_start;

        // Reset phase1 results for this batch.
        for (phase1_results[0..batch_count]) |*r| r.* = .{};

        var shared: TpShared = .{
            .chunks = scan.chunks,
            .block_src = block_src,
            .dst = dst,
            .dst_start_off = dst_start_off,
            .phase1_results = phase1_results[0..batch_count],
            .scratch_ptrs = scratches[0..batch_count],
            .next_chunk = std.atomic.Value(usize).init(0),
            .error_flag = std.atomic.Value(u32).init(0),
            .captured_err = std.atomic.Value(u16).init(0),
            .batch_start = batch_start,
            .batch_count = batch_count,
        };

        // Phase 2: parallel entropy decode.
        if (batch_count == 1) {
            tpWorkerFn(&shared);
        } else if (pool_opt) |pool| {
            // Persistent pool: no thread spawn cost per batch.
            const worker_count: usize = @min(batch_count, batch_size);
            var wg: std.Thread.WaitGroup = .{};
            for (0..worker_count) |_| {
                pool.spawnWg(&wg, tpWorkerFn, .{&shared});
            }
            pool.waitAndWork(&wg);
        } else {
            // Fallback: one-shot thread spawn per batch (test path).
            const worker_count: usize = @min(batch_count, batch_size);
            var spawned: usize = 0;
            while (spawned < worker_count) : (spawned += 1) {
                threads[spawned] = std.Thread.spawn(.{}, tpWorkerFn, .{&shared}) catch |err| {
                    for (threads[0..spawned]) |t| t.join();
                    return err;
                };
            }
            for (threads[0..worker_count]) |t| t.join();
        }

        if (shared.error_flag.load(.monotonic) != 0) {
            const code = shared.captured_err.load(.monotonic);
            if (code != 0) {
                const any_err: anyerror = @errorFromInt(code);
                const narrow: DecodeError = @errorCast(any_err);
                return narrow;
            }
            return error.BadChunkHeader;
        }

        // Phase 3: serial ProcessLzRuns for this batch.
        for (0..batch_count) |j| {
            const r = &phase1_results[j];
            if (r.is_special) {
                if (r.is_whole_match) {
                    const q = scan.chunks[batch_start + j];
                    const chunk_dst_off = dst_start_off + q.dst_offset;
                    if (r.whole_match_distance > chunk_dst_off) return error.BadChunkHeader;
                    // Whole-match copy is unreachable in practice since
                    // the current encoder never emits whole_match_distance,
                    // but the path is here for wire-format parity.
                    return error.BadChunkHeader; // unreachable in tests
                }
                continue;
            }

            const sub_count = r.sub_chunk_count;
            var s: u32 = 0;
            while (s < sub_count) : (s += 1) {
                const sub: *high.SubChunkPhase1Result = if (s == 0) &r.sub0 else &r.sub1;
                if (!sub.is_lz) continue;

                if (sub.resolved_tokens) |tokens| {
                    const sub_dst_ptr: [*]u8 = dst[sub.dst_offset..].ptr;
                    try high_runs.processLzRunsType1PreResolved(
                        tokens,
                        sub.resolved_count,
                        sub.lz_table.?,
                        sub_dst_ptr,
                        sub.dst_size,
                        sub.dst_offset,
                    );
                    if (sub.fallback_tokens) |f| {
                        std.heap.c_allocator.free(f);
                        sub.fallback_tokens = null;
                    }
                } else {
                    const sub_dst_ptr: [*]u8 = dst[sub.dst_offset..].ptr;
                    try high_runs.processLzRuns(
                        sub.mode,
                        sub_dst_ptr,
                        sub.dst_size,
                        sub.dst_offset,
                        sub.lz_table.?,
                        sub.scratch_free,
                        sub.scratch_end,
                    );
                }
            }
        }

        batch_start = batch_end;
    }

    dst_off_inout.* += decompressed_size;
    return true;
}

// ────────────────────────────────────────────────────────────
//  v2 Fast L1-L4 parallel decode (sidecar-driven phase 1 + phase 2)
// ────────────────────────────────────────────────────────────
//
// For files compressed by a v2 Fast L1-L4 encoder, the frame carries a
// parallel-decode sidecar block containing the pre-computed phase-1
// state: a list of cross-sub-chunk match ops + literal byte leaves the
// decoder must populate in `dst` before spawning per-chunk workers.
//
// The workflow:
//   1. Parse the sidecar body into `pdm.ParsedSidecar`.
//   2. Run phase 1 on `dst[dst_start_off..][0..decompressed_size]`:
//      write literal byte leaves, then execute match ops in
//      cmd-stream order with byte-wise forward copy.
//   3. Pre-scan the compressed block to discover sub-chunk boundaries.
//   4. Dispatch worker threads via `fastL14WorkerFn` to decode chunks
//      in parallel via `decodeOneChunk` + `fast.decodeChunk`. Every
//      chunk's cross-sub-chunk reads now hit phase-1-populated bytes.
//   5. Return after all workers join.
//
// Unlike the SC (L6-L8) path, there are no groups — every chunk runs
// independently. The closure sidecar makes cross-chunk reads safe.

const FastL14Shared = struct {
    chunks: []const ChunkScanInfo,
    block_src: []const u8,
    dst: []u8,
    dst_start_off: usize,
    error_flag: std.atomic.Value(u32),
    captured_err: std.atomic.Value(u16),
    /// Sidecar literal bytes (sorted by position, relative to frame
    /// output start). Workers apply only the subset that falls within
    /// their chunk range, eliminating the serial applySidecar bottleneck.
    sidecar_literals: []const pdm.LiteralByte,
};

/// Decode a contiguous slice of chunks [start, end) within a Fast L1-L4
/// parallel frame.
///
/// **64-byte guard trick**: The Fast LZ decoder uses `wildCopy16` (SIMD
/// 16-byte unaligned stores) for literal and match copies. At the very
/// end of a chunk's decompressed output, the last wildCopy16 may write
/// up to 15 bytes past the chunk boundary into the NEXT chunk's output
/// region. When chunks are decoded in parallel by different workers,
/// this overcopy stomps bytes that the neighboring worker is about to
/// (or has already) written correctly.
///
/// Fix: each worker saves the first 64 bytes of its FIRST chunk
/// immediately after decoding it (before the previous slice's worker
/// can overcopy into that region). After the full slice is decoded,
/// those saved bytes are restored, undoing any overcopy damage. 64
/// bytes is chosen as a safe upper bound: wildCopy16 can overcopy at
/// most 15 bytes, but aligning to a cache line (64) avoids partial-
/// line contention between workers.
///
/// The LAST chunk in each slice may overcopy into the next slice's
/// region, but that next slice's worker will restore its own guard,
/// so the overcopy is harmless.
fn fastL14WorkerFn(shared: *FastL14Shared, scratch: []u8, start: usize, end: usize) void {
    // ── Apply sidecar literals for this worker's chunk range ─────────
    // The literal_bytes array is sorted by position (ascending). We
    // binary-search to find the sub-range that falls within this
    // worker's output region, then scatter those bytes into dst.
    // This distributes the formerly serial applySidecar work across
    // all workers in parallel.
    if (start < end and shared.sidecar_literals.len > 0) {
        const first_chunk = shared.chunks[start];
        const last_chunk = shared.chunks[end - 1];
        const region_start: u64 = @intCast(first_chunk.dst_offset);
        const region_end: u64 = @intCast(last_chunk.dst_offset + last_chunk.dst_size);
        const lits = shared.sidecar_literals;

        // Binary search: find first literal with position >= region_start.
        var lo: usize = 0;
        var hi: usize = lits.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lits[mid].position < region_start) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Apply all literals in [region_start, region_end).
        var li = lo;
        while (li < lits.len and lits[li].position < region_end) : (li += 1) {
            shared.dst[shared.dst_start_off + @as(usize, @intCast(lits[li].position))] = lits[li].byte_value;
        }
    }

    // Guard buffer: saves the first 64 bytes of this slice's first
    // chunk so they can be restored after potential overcopy from
    // the previous slice's last wildCopy16.
    var guard: [64]u8 = undefined;
    var guard_pos: usize = 0;
    var guard_len: usize = 0;

    var chunk_idx: usize = start;
    while (chunk_idx < end) : (chunk_idx += 1) {
        if (shared.error_flag.load(.monotonic) != 0) return;
        const q = shared.chunks[chunk_idx];
        decodeOneChunk(
            shared.block_src[q.src_offset .. q.src_offset + q.src_size],
            shared.dst,
            shared.dst_start_off + q.dst_offset,
            q.dst_size,
            shared.dst_start_off,
            scratch,
        ) catch |err| {
            const code: u16 = @intFromError(err);
            _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        };

        // Save the first 64 bytes of this slice's leading chunk right
        // after decoding it. The previous slice's last chunk will
        // eventually overcopy via wildCopy16 and stomp these bytes.
        // We restore them after the full decode loop finishes.
        // (Only needed when this is not the first slice — slice 0 has
        // no predecessor that could overcopy into it.)
        if (chunk_idx == start and start > 0) {
            guard_pos = shared.dst_start_off + q.dst_offset;
            guard_len = @min(64, shared.dst.len - guard_pos);
            @memcpy(guard[0..guard_len], shared.dst[guard_pos..][0..guard_len]);
        }
    }

    // Restore the guard bytes, undoing any overcopy damage from the
    // previous slice's last wildCopy16.
    if (guard_len > 0) {
        @memcpy(shared.dst[guard_pos..][0..guard_len], guard[0..guard_len]);
    }
}

/// Apply the phase-1 sidecar literal bytes to `dst[dst_off..][0..region_len]`.
///
/// Positions in the sidecar are relative to the FRAME's output start.
/// When called for a single-piece frame with `dst_off == 0`, those
/// positions are direct indices into `dst`. For multi-piece framed
/// streams (each piece its own frame with its own sidecar), the
/// caller supplies the running dst offset so positions land in the
/// correct piece region.
///
/// Assumes: all `lit.position` values are < `region_len`. Positions
/// outside the region are silently skipped (defensive, but should not
/// occur if the encoder produced a valid sidecar).
fn applySidecar(
    dst: []u8,
    dst_off: usize,
    region_len: usize,
    sidecar: *const pdm.ParsedSidecar,
) void {
    for (sidecar.literal_bytes) |lit| {
        if (lit.position >= region_len) continue;
        dst[dst_off + @as(usize, @intCast(lit.position))] = lit.byte_value;
    }
}

/// Decompress a v2 Fast L1-L4 compressed frame block in parallel,
/// using a pre-computed parallel-decode sidecar for phase 1.
///
/// On entry `dst_off_inout.*` points at the first byte this block's
/// output should occupy. On successful return it has been advanced by
/// `decompressed_size`.
///
/// Encoder contract:
///   - The frame MUST carry a parallel_decode_metadata sidecar block
///     whose literal-byte leaves cover every byte position that a
///     cross-sub-chunk LZ match would read before the owning chunk's
///     worker has decoded it. If any leaf is missing, the affected
///     worker reads stale/zero bytes and produces silent corruption.
///   - Sidecar literal positions are relative to the frame's output
///     start (not the absolute dst offset). They must all be less than
///     `decompressed_size`.
///
/// Caller contract:
///   - `dst` MUST have at least `decompressed_size + 64` bytes from
///     `dst_off_inout.*` onward (safe_space for SIMD overcopy).
///   - `sidecar_body` must be the raw body of the parallel_decode_metadata
///     block (after the block-type header has been stripped).
///
/// Worker slice alignment:
///   Worker slices are rounded up to multiples of 16 chunks so that
///   sidecar boundaries (which the encoder emits at 16-chunk intervals)
///   never fall inside a slice. If the alignment invariant is broken,
///   a worker could decode a chunk whose sidecar literals were meant
///   to be pre-populated by a different worker's slice, causing races.
pub fn decompressFastL14Parallel(
    allocator: std.mem.Allocator,
    pool_opt: ?*std.Thread.Pool,
    block_src: []const u8,
    sidecar_body: []const u8,
    dst: []u8,
    dst_off_inout: *usize,
    decompressed_size: usize,
    max_threads: usize,
) DecodeError!void {
    // ── Pre-scan chunks ──────────────────────────────────────────────
    var scan = try preScanBlock(allocator, block_src, decompressed_size);
    defer scan.deinit();

    const num_chunks = scan.chunks.len;
    if (num_chunks == 0) return;

    const dst_start_off = dst_off_inout.*;
    if (dst_start_off + decompressed_size + 64 > dst.len) return error.OutputTooSmall;

    // -- Invariant assertions (debug only) --
    // Safe-space padding for SIMD wildCopy16 overcopy at chunk tails.
    std.debug.assert(dst.len >= dst_start_off + decompressed_size + 64);

    // ── Parse sidecar ──────────────────────────────────────────────────
    var sidecar = pdm.parseBlockBody(sidecar_body, allocator) catch return error.InvalidInternalHeader;
    defer sidecar.deinit();

    // -- Sidecar invariant assertions (debug only) --
    // Every literal-byte position in the sidecar must fall within the
    // decompressed region. Out-of-bounds positions would write past the
    // allocated dst buffer in applySidecar.
    for (sidecar.literal_bytes) |lit| {
        std.debug.assert(lit.position < decompressed_size);
    }

    // ── Worker setup ─────────────────────────────────────────────────
    // Slice size aligned to 16 chunks (matching sidecar boundaries).
    var cpu_count_raw: usize = if (max_threads > 0) max_threads else std.Thread.getCpuCount() catch 1;
    if (max_threads == 0) {
        if (std.process.getEnvVarOwned(allocator, "SLZ_CORES") catch null) |val| {
            defer allocator.free(val);
            cpu_count_raw = std.fmt.parseInt(usize, val, 10) catch cpu_count_raw;
        }
    }
    const max_workers: usize = @min(24, @min(num_chunks, cpu_count_raw));
    // Slice size is rounded up to a multiple of 16 chunks so that
    // sidecar boundaries (emitted by the encoder at 16-chunk intervals)
    // always fall on slice edges, never mid-slice. This prevents two
    // workers from racing on the same sidecar-populated region.
    const aligned_slice: usize = blk: {
        if (max_workers <= 1) break :blk num_chunks;
        const ideal = (num_chunks + max_workers - 1) / max_workers;
        break :blk ((ideal + 15) / 16) * 16;
    };
    // When multiple workers are used, verify the 16-chunk alignment.
    if (max_workers > 1) {
        std.debug.assert(aligned_slice % 16 == 0);
    }
    const worker_count: usize = if (aligned_slice >= num_chunks) 1 else (num_chunks + aligned_slice - 1) / aligned_slice;
    // Worker count must be at least 1.
    std.debug.assert(worker_count > 0);

    const sc_scratch_bytes: usize = constants.scratch_size * 2;
    const scratches = try allocator.alloc([]u8, worker_count);
    defer {
        for (scratches) |s| if (s.len != 0) allocator.free(s);
        allocator.free(scratches);
    }
    for (scratches) |*s| s.* = &[_]u8{};
    for (scratches) |*s| s.* = try allocator.alloc(u8, sc_scratch_bytes);

    var shared: FastL14Shared = .{
        .chunks = scan.chunks,
        .block_src = block_src,
        .dst = dst,
        .dst_start_off = dst_start_off,
        .error_flag = std.atomic.Value(u32).init(0),
        .captured_err = std.atomic.Value(u16).init(0),
        .sidecar_literals = sidecar.literal_bytes,
    };

    // Sidecar literals applied inside each worker (distributed across cores).
    dispatchWorkers(&shared, scratches, worker_count, aligned_slice, pool_opt);
    if (shared.error_flag.load(.monotonic) != 0) return reportWorkerError(&shared);

    dst_off_inout.* += decompressed_size;
}

fn dispatchWorkers(
    shared: *FastL14Shared,
    scratches: [][]u8,
    worker_count: usize,
    slice_size_arg: usize,
    pool_opt: ?*std.Thread.Pool,
) void {
    const slice_size: usize = slice_size_arg;
    if (worker_count == 1) {
        fastL14WorkerFn(shared, scratches[0], 0, shared.chunks.len);
    } else if (pool_opt) |pool| {
        var wg: std.Thread.WaitGroup = .{};
        for (0..worker_count) |i| {
            const s = i * slice_size;
            const e = @min(s + slice_size, shared.chunks.len);
            pool.spawnWg(&wg, fastL14WorkerFn, .{ shared, scratches[i], s, e });
        }
        pool.waitAndWork(&wg);
    } else {
        var threads_buf: [256]std.Thread = undefined;
        const threads = threads_buf[0..worker_count];
        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            const s = spawned * slice_size;
            const e = @min(s + slice_size, shared.chunks.len);
            threads[spawned] = std.Thread.spawn(.{}, fastL14WorkerFn, .{ shared, scratches[spawned], s, e }) catch {
                shared.error_flag.store(1, .monotonic);
                break;
            };
        }
        for (threads[0..spawned]) |t| t.join();
    }
}

fn reportWorkerError(shared: *const FastL14Shared) DecodeError {
    const code = shared.captured_err.load(.monotonic);
    if (code != 0) {
        const any_err: anyerror = @errorFromInt(code);
        return @errorCast(any_err);
    }
    return error.Truncated;
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

test "decompressFramedParallel: non-SC L9 single-chunk falls through to serial" {
    // Single-chunk non-SC: both parallel paths decline (SC check fails,
    // two-phase requires multi-chunk). Serial loop handles it.
    var src: [8192]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try parallelRoundtrip(&src, 9);
}

test "decompressFramedParallel: non-SC L9 2 chunks (two-phase path)" {
    // 384 KB non-SC L9 → 2 chunks → dispatched via decompressCoreTwoPhase.
    // Exercises the parallel entropy-decode + serial match-resolve path.
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try parallelRoundtrip(&src, 9);
}

test "decompressFramedParallel: non-SC L10 512 KB (two-phase)" {
    var src: [512 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try parallelRoundtrip(&src, 10);
}

test "decompressFramedParallel: non-SC L11 768 KB (two-phase + BT4)" {
    // L11 uses BT4 match finder; this test exercises the parallel
    // decoder on its output.
    var src: [768 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try parallelRoundtrip(&src, 11);
}
