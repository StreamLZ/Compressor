//! Parallel compression dispatch — worker structs and thread-pool
//! orchestration for the High codec.
//!
//! Extracted from `streamlz_encoder.zig` to isolate the parallel
//! block dispatch from the serial frame-building paths.  Two public
//! entry points:
//!   - `compressBlocksParallel`     — non-SC parallel over 256 KB blocks
//!   - `compressInternalParallelSc` — SC parallel over SC chunk groups

const std = @import("std");
const lz_constants = @import("../format/streamlz_constants.zig");

const high_compressor = @import("high/high_compressor.zig");
const high_encoder = @import("high/high_encoder.zig");
const match_finder = @import("high/match_finder.zig");
const match_finder_bt4 = @import("high/match_finder_bt4.zig");
const mls_mod = @import("high/managed_match_len_storage.zig");

const high_framed = @import("high_framed.zig");
const HighMapping = high_framed.HighMapping;
const compressOneHighBlock = high_framed.compressOneHighBlock;

const encoder = @import("streamlz_encoder.zig");
const CompressError = encoder.CompressError;
const compressBound = encoder.compressBound;

// ────────────────────────────────────────────────────────────
//  compressBlocksParallel — non-SC High parallel block dispatch
// ────────────────────────────────────────────────────────────
//
// Parallel block compression for the High codec. Works per-block (one 256 KB chunk),
// each thread owning a dedicated tmp buffer. Shared read-only
// across workers: `src` (the full source), `mls` (pre-computed
// match storage), `ctx` (config). The per-block `compressOneHigh
// Block` never mutates any of these, so thread-safety is
// guaranteed without locks.
//
// Workers run at the OS default thread priority.
// `ThreadPriority.BelowNormal` to keep compression off the UI
// critical path; the Zig `std.Thread` API doesn't expose priority
// directly on all targets, so we leave this at default — this is
// only a fairness/latency property, not a correctness one.

const PcShared = struct {
    src: []const u8,
    /// Base context (shared, read-only). Each worker builds a local
    /// copy with its own arena-backed allocator (step 14 LzTemp
    /// equivalent) so per-block scratch allocations reuse bump-
    /// pointer pages across blocks instead of round-tripping through
    /// the backing allocator.
    base_ctx: *const high_encoder.HighEncoderContext,
    /// Per-worker backing allocator (shared by all workers but
    /// thread-safe — e.g. page_allocator or an upstream thread-safe
    /// allocator). Each worker wraps it in a private ArenaAllocator.
    backing_allocator: std.mem.Allocator,
    mls: *const mls_mod.ManagedMatchLenStorage,
    self_contained: bool,
    sc_flag_bit: u8,
    dict_prefix_len: usize,
    /// Per-block result slots. Each worker writes into `tmp_bufs[i]`
    /// and stores the written byte count in `written[i]`.
    tmp_bufs: []const []u8,
    written: []usize,
    /// Work-stealing counter: next block index to claim.
    next_block: std.atomic.Value(usize),
    error_flag: std.atomic.Value(u32),
    captured_err: std.atomic.Value(u16),
    num_blocks: usize,
};

fn pcWorkerFn(shared: *PcShared) void {
    // Per-worker `LzTemp` equivalent: an arena allocator rooted at
    // `backing_allocator`. Reset between blocks with
    // `.retain_capacity` so the second+ block's allocations are
    // bump-pointer within the already-grown arena pages, matching
    // Thread-local scratch reuse pattern. Step 14
    // (D13).
    var arena = std.heap.ArenaAllocator.init(shared.backing_allocator);
    defer arena.deinit();

    // Worker-local context copy with the arena allocator + private
    // cross-block state:
    // each worker has its own `LzCoder` clone so stats accumulate
    // within a worker's block range but not across workers.
    var worker_ctx = shared.base_ctx.*;
    worker_ctx.allocator = arena.allocator();
    var worker_cross_block: high_encoder.HighCrossBlockState = .{};
    worker_ctx.cross_block = &worker_cross_block;

    // Each worker allocates its OWN `HighHasher` once and reuses it
    // across blocks, matching the per-thread context clone. For
    // L5+ this is `.none` (the optimal parser uses the shared MLS
    // directly), so no per-thread state besides the arena.
    var hasher: high_compressor.HighHasher = .{ .none = {} };
    defer hasher.deinit();

    // Pre-allocate match table once per worker thread (L5+ only).
    const worker_mt_buf: ?[]mls_mod.LengthAndOffset = if (shared.base_ctx.compression_level >= 5)
        (shared.backing_allocator.alloc(mls_mod.LengthAndOffset, 4 * high_compressor.sub_chunk_size) catch {
            _ = shared.captured_err.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        })
    else
        null;
    defer if (worker_mt_buf) |buf| shared.backing_allocator.free(buf);

    while (true) {
        const block_idx = shared.next_block.fetchAdd(1, .monotonic);
        if (block_idx >= shared.num_blocks) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

        // Fresh cross-block state per block → output is deterministic
        // regardless of which thread wins which block via the atomic
        // counter. Without this, a thread that processes blocks 0, 5,
        // 10, ... carries different stats forward than one processing
        // 1, 6, 11, ... → run-to-run nondeterminism.
        worker_cross_block = .{};

        const src_off = shared.dict_prefix_len + block_idx * lz_constants.chunk_size;
        const block_src_len = @min(shared.src.len - src_off, lz_constants.chunk_size);
        const keyframe = shared.self_contained or block_idx == 0;

        const n_or_err = compressOneHighBlock(
            &worker_ctx,
            &hasher,
            shared.mls,
            shared.src,
            src_off,
            block_src_len,
            shared.tmp_bufs[block_idx],
            shared.sc_flag_bit,
            keyframe,
            worker_mt_buf,
        );
        if (n_or_err) |n| {
            shared.written[block_idx] = n;
        } else |err| {
            const code: u16 = @intFromError(err);
            _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        }

        // Reset the arena for the next block. Keeps the pages
        // allocated so subsequent blocks get bump-pointer speed.
        _ = arena.reset(.retain_capacity);
    }
}

pub fn compressBlocksParallel(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst_tail: []u8,
    ctx: *const high_encoder.HighEncoderContext,
    mls: *const mls_mod.ManagedMatchLenStorage,
    sc_flag_bit: u8,
    self_contained: bool,
    num_threads: u32,
    dict_prefix_len: usize,
) CompressError!usize {
    const content_len = src.len - dict_prefix_len;
    const num_blocks: usize = (content_len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
    std.debug.assert(num_blocks > 1);

    // Per-block tmp buffers sized to compressBound(block_src_len).
    // `compressBound` on `block_src_len` accounts for worst-case
    // incompressible + header overhead.
    const tmp_bufs = try allocator.alloc([]u8, num_blocks);
    defer {
        for (tmp_bufs) |b| if (b.len != 0) allocator.free(b);
        allocator.free(tmp_bufs);
    }
    for (tmp_bufs) |*b| b.* = &[_]u8{};
    for (tmp_bufs, 0..) |*b, i| {
        const blk_off = i * lz_constants.chunk_size;
        const block_src_len = @min(content_len - blk_off, lz_constants.chunk_size);
        b.* = try allocator.alloc(u8, compressBound(block_src_len));
    }

    const written = try allocator.alloc(usize, num_blocks);
    defer allocator.free(written);
    @memset(written, 0);

    var shared: PcShared = .{
        .src = src,
        .base_ctx = ctx,
        .backing_allocator = allocator,
        .mls = mls,
        .self_contained = self_contained,
        .sc_flag_bit = sc_flag_bit,
        .dict_prefix_len = dict_prefix_len,
        .tmp_bufs = tmp_bufs,
        .written = written,
        .next_block = std.atomic.Value(usize).init(0),
        .error_flag = std.atomic.Value(u32).init(0),
        .captured_err = std.atomic.Value(u16).init(0),
        .num_blocks = num_blocks,
    };

    // Cap worker count at num_blocks — no point spawning more.
    const worker_count: usize = @min(@as(usize, num_threads), num_blocks);
    if (worker_count == 1) {
        pcWorkerFn(&shared);
    } else {
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);
        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, pcWorkerFn, .{&shared}) catch |err| {
                for (threads[0..spawned]) |t| t.join();
                return err;
            };
        }
        for (threads) |t| t.join();
    }

    if (shared.error_flag.load(.monotonic) != 0) {
        const code = shared.captured_err.load(.monotonic);
        if (code != 0) {
            const any_err: anyerror = @errorFromInt(code);
            const narrow: CompressError = @errorCast(any_err);
            return narrow;
        }
        return error.DestinationTooSmall;
    }

    // Assemble results into dst_tail in order.
    var dst_pos: usize = 0;
    for (0..num_blocks) |i| {
        const n = written[i];
        if (dst_pos + n > dst_tail.len) return error.DestinationTooSmall;
        @memcpy(dst_tail[dst_pos..][0..n], tmp_bufs[i][0..n]);
        dst_pos += n;
    }
    return dst_pos;
}

// ────────────────────────────────────────────────────────────
//  compressInternalParallelSc — SC parallel across chunk groups
// ────────────────────────────────────────────────────────────
//
// Parallel SC compression for the High codec. The key difference vs
// `compressBlocksParallel`: each worker runs its OWN match finder
// on only its group's `sc_group_size * chunk_size` bytes, so
// there's no shared global MLS. This is required for SC mode
// because LZ references must not cross group boundaries — a
// per-group match finder naturally enforces that (matches found
// within the group can't exceed the group's bounds).
//
// Within a group, chunks are compressed sequentially with a
// cumulative `group_offset` so cross-chunk references ARE allowed
// (within the group). Output is assembled chunk-by-chunk into
// per-chunk tmp buffers then concatenated.

const ScShared = struct {
    src: []const u8,
    base_ctx: *const high_encoder.HighEncoderContext,
    backing_allocator: std.mem.Allocator,
    mapping: HighMapping,
    sc_flag_bit: u8,
    dict_prefix_len: usize,
    /// Per-chunk result slots (one per 256 KB output chunk).
    tmp_bufs: []const []u8,
    written: []usize,
    /// Work-stealing counter over group indices (not chunk indices).
    next_group: std.atomic.Value(usize),
    error_flag: std.atomic.Value(u32),
    captured_err: std.atomic.Value(u16),
    num_chunks: usize,
    num_groups: usize,
};

fn scWorkerFn(shared: *ScShared) void {
    var arena = std.heap.ArenaAllocator.init(shared.backing_allocator);
    defer arena.deinit();

    var worker_ctx = shared.base_ctx.*;
    worker_ctx.allocator = arena.allocator();

    // Per-worker cross-block state. Resets to default at the start of
    // every group so output is deterministic regardless of which thread
    // happens to claim which group via the atomic counter. Without this,
    // a thread that processes groups 0, 5, 10, ... would carry stats
    // forward across them and produce different output than a thread
    // that processes 1, 6, 11, ...
    var worker_cross_block: high_encoder.HighCrossBlockState = .{};
    worker_ctx.cross_block = &worker_cross_block;
    worker_ctx.dict_prefix_len = @intCast(shared.dict_prefix_len);

    var hasher: high_compressor.HighHasher = .{ .none = {} };
    defer hasher.deinit();

    // Pre-allocate match table once per SC worker thread (L5+ only).
    const sc_mt_buf: ?[]mls_mod.LengthAndOffset = if (shared.base_ctx.compression_level >= 5)
        (shared.backing_allocator.alloc(mls_mod.LengthAndOffset, 4 * high_compressor.sub_chunk_size) catch {
            _ = shared.captured_err.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .monotonic, .monotonic);
            _ = shared.error_flag.store(1, .monotonic);
            return;
        })
    else
        null;
    defer if (sc_mt_buf) |buf| shared.backing_allocator.free(buf);

    const group_size = lz_constants.sc_group_size;

    while (true) {
        const g = shared.next_group.fetchAdd(1, .monotonic);
        if (g >= shared.num_groups) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

        // Fresh cross-block state per group → deterministic output.
        worker_cross_block = .{};

        const first_chunk = g * group_size;
        const last_chunk = @min(first_chunk + group_size, shared.num_chunks);
        const chunks_in_group = last_chunk - first_chunk;

        const dpl = shared.dict_prefix_len;
        const group_src_off = first_chunk * lz_constants.chunk_size;
        const group_content_len = @min(chunks_in_group * lz_constants.chunk_size, shared.src.len - dpl - group_src_off);

        const finder_preload: usize = dpl;
        var dict_group_buf: ?[]u8 = null;
        const group_src: []const u8 = if (dpl > 0) blk: {
            const buf = shared.backing_allocator.alloc(u8, dpl + group_content_len) catch {
                _ = shared.error_flag.store(1, .monotonic);
                _ = shared.captured_err.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .monotonic, .monotonic);
                return;
            };
            @memcpy(buf[0..dpl], shared.src[0..dpl]);
            @memcpy(buf[dpl..], shared.src[dpl + group_src_off ..][0..group_content_len]);
            dict_group_buf = buf;
            break :blk buf;
        } else shared.src[group_src_off .. group_src_off + group_content_len];
        defer if (dict_group_buf) |buf| shared.backing_allocator.free(buf);

        _ = arena.reset(.retain_capacity);

        var mls = mls_mod.ManagedMatchLenStorage.init(arena.allocator(), group_content_len + 1, 8.0) catch {
            _ = shared.error_flag.store(1, .monotonic);
            _ = shared.captured_err.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .monotonic, .monotonic);
            return;
        };
        mls.window_base_offset = 0;
        mls.round_start_pos = 0;

        const mf_ok = blk: {
            if (shared.mapping.use_bt4) {
                match_finder_bt4.findMatchesBT4(arena.allocator(), group_src, &mls, 4, finder_preload, 96) catch |err| {
                    const code: u16 = @intFromError(err);
                    _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
                    break :blk false;
                };
            } else {
                match_finder.findMatchesHashBased(arena.allocator(), group_src, &mls, 4, finder_preload) catch |err| {
                    const code: u16 = @intFromError(err);
                    _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
                    break :blk false;
                };
            }
            break :blk true;
        };
        if (!mf_ok) {
            _ = shared.error_flag.store(1, .monotonic);
            return;
        }

        // Content-only slice for the block compressor. Contiguous with
        // the dictionary prefix in memory so pointer arithmetic reaches
        // dictionary bytes via negative offsets from the content start.
        const group_content = group_src[dpl..];

        var ci: usize = 0;
        while (ci < chunks_in_group) : (ci += 1) {
            const chunk_idx = first_chunk + ci;
            const in_group_src_off = ci * lz_constants.chunk_size;
            const block_src_len = @min(group_content_len - in_group_src_off, lz_constants.chunk_size);
            const keyframe = (ci == 0);

            const n_or_err = compressOneHighBlock(
                &worker_ctx,
                &hasher,
                &mls,
                group_content,
                in_group_src_off,
                block_src_len,
                shared.tmp_bufs[chunk_idx],
                shared.sc_flag_bit,
                keyframe,
                sc_mt_buf,
            );
            if (n_or_err) |n| {
                shared.written[chunk_idx] = n;
            } else |err| {
                const code: u16 = @intFromError(err);
                _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
                _ = shared.error_flag.store(1, .monotonic);
                return;
            }
        }
    }
}

pub fn compressInternalParallelSc(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst_tail: []u8,
    ctx: *const high_encoder.HighEncoderContext,
    mapping: HighMapping,
    sc_flag_bit: u8,
    num_threads: u32,
    dict_prefix_len_sc: usize,
) CompressError!usize {
    const content_len = src.len - dict_prefix_len_sc;
    const num_chunks: usize = (content_len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
    const group_size = lz_constants.sc_group_size;
    const num_groups: usize = (num_chunks + group_size - 1) / group_size;

    // Per-chunk tmp buffers sized to compressBound(block_src_len).
    const tmp_bufs = try allocator.alloc([]u8, num_chunks);
    defer {
        for (tmp_bufs) |b| if (b.len != 0) allocator.free(b);
        allocator.free(tmp_bufs);
    }
    for (tmp_bufs) |*b| b.* = &[_]u8{};
    for (tmp_bufs, 0..) |*b, i| {
        const blk_off = i * lz_constants.chunk_size;
        const block_src_len = @min(content_len - blk_off, lz_constants.chunk_size);
        b.* = try allocator.alloc(u8, compressBound(block_src_len));
    }

    const written = try allocator.alloc(usize, num_chunks);
    defer allocator.free(written);
    @memset(written, 0);

    var shared: ScShared = .{
        .src = src,
        .base_ctx = ctx,
        .backing_allocator = allocator,
        .mapping = mapping,
        .sc_flag_bit = sc_flag_bit,
        .dict_prefix_len = dict_prefix_len_sc,
        .tmp_bufs = tmp_bufs,
        .written = written,
        .next_group = std.atomic.Value(usize).init(0),
        .error_flag = std.atomic.Value(u32).init(0),
        .captured_err = std.atomic.Value(u16).init(0),
        .num_chunks = num_chunks,
        .num_groups = num_groups,
    };

    const worker_count: usize = @min(@as(usize, num_threads), num_groups);
    if (worker_count == 1) {
        scWorkerFn(&shared);
    } else {
        const threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);
        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, scWorkerFn, .{&shared}) catch |err| {
                for (threads[0..spawned]) |t| t.join();
                return err;
            };
        }
        for (threads) |t| t.join();
    }

    if (shared.error_flag.load(.monotonic) != 0) {
        const code = shared.captured_err.load(.monotonic);
        if (code != 0) {
            const any_err: anyerror = @errorFromInt(code);
            const narrow: CompressError = @errorCast(any_err);
            return narrow;
        }
        return error.DestinationTooSmall;
    }

    // Assemble chunk results into dst_tail.
    var dst_pos: usize = 0;
    for (0..num_chunks) |i| {
        const n = written[i];
        if (dst_pos + n > dst_tail.len) return error.DestinationTooSmall;
        @memcpy(dst_tail[dst_pos..][0..n], tmp_bufs[i][0..n]);
        dst_pos += n;
    }
    return dst_pos;
}
