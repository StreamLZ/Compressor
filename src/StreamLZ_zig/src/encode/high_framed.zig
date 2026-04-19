//! High codec frame builder — produces SLZ1-framed blocks for High
//! levels L6-L11.
//!
//! Extracted from `streamlz_encoder.zig` to isolate the High-codec
//! frame construction (serial paths) from the top-level dispatch,
//! the Fast-codec path, and the parallel dispatch.  Public entry
//! points: `compressFramedHigh`, `compressOneFrameBlockWindowed`,
//! `compressOneHighBlock`.

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const lz_constants = @import("../format/streamlz_constants.zig");
const fast_constants = @import("fast/fast_constants.zig");
const cost_coeffs = @import("cost_coefficients.zig");

const high_compressor = @import("high/high_compressor.zig");
const high_encoder = @import("high/high_encoder.zig");
const match_finder = @import("high/match_finder.zig");
const match_finder_bt4 = @import("high/match_finder_bt4.zig");
const mls_mod = @import("high/managed_match_len_storage.zig");

const encoder = @import("streamlz_encoder.zig");
const Options = encoder.Options;
const CompressError = encoder.CompressError;
const compressBound = encoder.compressBound;
const calculateMaxThreads = encoder.calculateMaxThreads;

const compress_parallel = @import("compress_parallel.zig");

const areAllBytesEqual = block_header.areAllBytesEqual;

/// Unified-to-codec-level mapping for the High codec path. Mirrors
/// Map unified levels 6-11 to High-codec encoder parameters.
pub const HighMapping = struct {
    codec_level: i32,
    self_contained: bool,
    use_bt4: bool,
};

pub fn mapHighLevel(user_level: u8) HighMapping {
    //
    // codec_level >= 9 enables the BT4 match finder.
    return switch (user_level) {
        6 => .{ .codec_level = 5, .self_contained = true, .use_bt4 = false },
        7 => .{ .codec_level = 7, .self_contained = true, .use_bt4 = false },
        8 => .{ .codec_level = 9, .self_contained = true, .use_bt4 = true },
        9 => .{ .codec_level = 5, .self_contained = false, .use_bt4 = false },
        10 => .{ .codec_level = 7, .self_contained = false, .use_bt4 = false },
        11 => .{ .codec_level = 9, .self_contained = false, .use_bt4 = true },
        else => unreachable,
    };
}

/// High-codec framed compressor --
/// `CompressBlocksSerial` / `CompressOneBlock` / `CompressChunk`.
/// Initial scope: serial, no SC prefix table emission (treats L6-L8
/// as non-SC for now). Full SC parity layers on in a follow-up.
pub fn compressFramedHigh(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    const mapping = mapHighLevel(opts.level);

    // ── Frame header ────────────────────────────────────────────────────
    var pos: usize = 0;
    const hdr_len = try frame.writeHeader(dst, .{
        .codec = .high,
        .level = @intCast(mapping.codec_level),
        .block_size = opts.block_size,
        .content_size = if (opts.include_content_size) @as(u64, @intCast(src.len)) else null,
        .dictionary_id = opts.dictionary_id,
    });
    pos += hdr_len;

    if (src.len == 0) {
        if (pos + 4 > dst.len) return error.DestinationTooSmall;
        frame.writeEndMark(dst[pos..]);
        return pos + 4;
    }

    const can_compress = src.len > fast_constants.min_source_length;
    const self_contained: bool = mapping.self_contained or opts.self_contained or opts.two_phase;
    const sc_flag_bit: u8 = if (self_contained) 0x10 else 0;

    // ── High encoder context ───────────────────────────────────────────
    // L5+ enables `export_tokens`. Entropy options:
    // start at 0xFF & ~MultiArrayAdvanced, then re-enable MultiArrayAdvanced
    // when level >= 7.
    var entropy_raw: u8 = 0xFF & ~@as(u8, 0b0100_0000); // clear MultiArrayAdvanced
    if (mapping.codec_level >= 7) entropy_raw |= 0b0100_0000;
    // Cross-block stats scratch — symbol statistics + last chunk type.
    // The optimal parser reads these
    // at the start of each block and writes them back on success. Without
    // this, multi-block streams seed every block's cost model from cold
    // and diverge from byte-exact output.
    var cross_block_state: high_encoder.HighCrossBlockState = .{};
    const ctx: high_encoder.HighEncoderContext = .{
        .allocator = allocator,
        .compression_level = mapping.codec_level,
        // SetupEncoder:
        //   SpeedTradeoff = SpaceSpeedTradeoffBytes * Factor1 * Factor2
        // The Fast codec uses a different formula (scale * entropy_factor)
        // which would produce a speed_tradeoff ~5.6x too high here and
        // silently corrupt every cost-model comparison.
        .speed_tradeoff = cost_coeffs.speedTradeoffForHigh(
            cost_coeffs.default_space_speed_tradeoff_bytes,
        ),
        .entropy_options = @bitCast(entropy_raw),
        .encode_flags = 4, // export_tokens
        .self_contained = self_contained,
        .cross_block = &cross_block_state,
    };

    // Decide thread count up front — used to gate both the SC and
    // non-SC parallel paths. Explicit `opts.num_threads >= 1`
    // overrides the auto path; `opts.num_threads == 0` calls into
    // `calculateMaxThreads` which clamps against both CPU count and
    // the 60%-of-physical-RAM memory budget (step 40).
    const num_blocks: usize = if (can_compress) ((src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size) else 0;
    const resolved_threads: u32 = blk: {
        if (opts.num_threads >= 1) break :blk opts.num_threads;
        break :blk calculateMaxThreads(src.len);
    };
    const can_parallel_sc: bool =
        can_compress and
        self_contained and
        mapping.codec_level >= 5 and
        num_blocks > 1 and
        resolved_threads > 1;

    // Optional hasher for L1-L4. None for L5+.
    const setup = high_compressor.setupEncoder(
        mapping.codec_level,
        src.len,
        opts.hash_bits,
        256,
        opts.min_match_length,
    );
    var hasher = try high_compressor.allocateHighHasher(allocator, setup);
    defer hasher.deinit();

    // Parallel gating: non-SC parallel uses a global MLS (pre-computed
    // once). That path doesn't get the sliding-window treatment — it's
    // a separate step to make parallel byte-exact with the serial path.
    const can_parallel_blocks: bool =
        can_compress and
        num_blocks > 1 and
        resolved_threads > 1 and
        !self_contained and
        mapping.codec_level >= 5;

    if (can_parallel_sc) {
        const frame_block_hdr_pos: usize = pos;
        pos += 8;
        const frame_block_start: usize = pos;
        const written = try compress_parallel.compressInternalParallelSc(
            allocator,
            src,
            dst[pos..],
            &ctx,
            mapping,
            sc_flag_bit,
            resolved_threads,
        );
        pos += written;
        try emitScPrefixTable(src, dst, &pos);
        try finalizeSingleFrameBlock(
            src,
            dst,
            &pos,
            frame_block_hdr_pos,
            frame_block_start,
            can_compress,
        );
    } else if (can_parallel_blocks) {
        // Parallel non-SC High: build one global MLS covering all of
        // `src`, then hand blocks out to worker threads. Not byte-exact
        // (range partitioner assigns blocks in a
        // different order), but reproducible across Zig runs.
        var global_mls = try mls_mod.ManagedMatchLenStorage.init(allocator, src.len + 1, 8.0);
        defer global_mls.deinit();
        global_mls.window_base_offset = 0;
        global_mls.round_start_pos = 0;
        if (mapping.use_bt4) {
            try match_finder_bt4.findMatchesBT4(allocator, src, &global_mls, 4, 0, 128);
        } else {
            match_finder.findMatchesHashBased(allocator, src, &global_mls, 4, 0) catch |err| return if (err == error.HashBitsOutOfRange) error.BadLevel else @errorCast(err);
        }
        const frame_block_hdr_pos: usize = pos;
        pos += 8;
        const frame_block_start: usize = pos;
        const written = try compress_parallel.compressBlocksParallel(
            allocator,
            src,
            dst[pos..],
            &ctx,
            &global_mls,
            sc_flag_bit,
            self_contained,
            resolved_threads,
        );
        pos += written;
        try finalizeSingleFrameBlock(
            src,
            dst,
            &pos,
            frame_block_hdr_pos,
            frame_block_start,
            can_compress,
        );
    } else if (can_compress and mapping.codec_level >= 5 and !self_contained) {
        // ── Serial non-SC High: sliding-window frame-block loop ──────
        // Serial path: splits `src` into `frame_block_size`-sized reads and carries
        // the tail of each read forward as a dictionary for the next
        // read (bounded by `window_size`). Byte-exact at
        // any input size.
        //
        // Semantics note: each iteration of the serial loop calls
        // `StreamLZCompressor.CompressBlock`, which instantiates a fresh
        // `LzCoder { LastChunkType = -1 }` per call. That means the
        // cross-block cost-model stats DO NOT carry between frame
        // blocks — only within the 256 KB internal blocks of a single
        // frame block. We mirror that by resetting `cross_block_state`
        // at the start of every frame-block iteration.
        const frame_block_size: usize = if (mapping.codec_level >= 9)
            lz_constants.bt4_max_read_size // 8 MB for L11
        else
            lz_constants.default_window_size; // 128 MB for L9/L10
        const window_size: usize = lz_constants.default_window_size;

        // CompressInternal caps the effective
        // dictionary passed to the match finder at
        //   `localDictSize - srcSize`
        // where `localDictSize = max(opts.MaxLocalDictionarySize, 64 MB)`
        // and the default `MaxLocalDictionarySize` is 4 MB, so the
        // effective cap is `64 MB - block_bytes`. For L11 with 8 MB
        // blocks this is 56 MB; for L9/L10 with 128 MB blocks this
        // clamps to 0 (no cross-block reference). Without this cap,
        // blocks beyond the cap see a larger preload and
        // the match finder picks up extra matches.
        const local_dict_size: usize = if (mapping.codec_level >= 9 and !self_contained) 128 * 1024 * 1024 else 64 * 1024 * 1024;

        var src_off: usize = 0;
        while (src_off < src.len) {
            const block_bytes: usize = @min(src.len - src_off, frame_block_size);
            const raw_dict_bytes: usize = @min(src_off, window_size);
            const dict_cap: usize = if (local_dict_size > block_bytes) local_dict_size - block_bytes else 0;
            const dict_bytes: usize = @min(raw_dict_bytes, dict_cap);
            const window_start: usize = src_off - dict_bytes;
            const window_len: usize = dict_bytes + block_bytes;
            const window_slice: []const u8 = src[window_start..][0..window_len];

            // Fresh cost-model state per frame block (matches the
            // per-`CompressBlock` LzCoder instantiation).
            cross_block_state = .{};

            try compressOneFrameBlockWindowed(
                allocator,
                &ctx,
                &hasher,
                mapping,
                window_slice,
                dict_bytes,
                block_bytes,
                dst,
                &pos,
                src,
                src_off,
            );

            src_off += block_bytes;
        }
    } else {
        // Fallback serial path for the remaining cases:
        //   - `!can_compress` (src too short) → single uncompressed frame block
        //   - SC serial / SC single-thread → existing single-frame-block behaviour
        //   - High L1-L4 (no optimal parser) → same as above
        // All of these fit in one frame block.
        const frame_block_hdr_pos: usize = pos;
        pos += 8;
        const frame_block_start: usize = pos;

        // For SC and other paths, we still need a whole-source MLS for
        // L5+ optimal parsing.
        var mls_opt: ?mls_mod.ManagedMatchLenStorage = null;
        defer if (mls_opt) |*m| m.deinit();
        if (can_compress and mapping.codec_level >= 5) {
            var mls = try mls_mod.ManagedMatchLenStorage.init(allocator, src.len + 1, 8.0);
            mls.window_base_offset = 0;
            mls.round_start_pos = 0;
            if (mapping.use_bt4) {
                try match_finder_bt4.findMatchesBT4(allocator, src, &mls, 4, 0, 128);
            } else {
                match_finder.findMatchesHashBased(allocator, src, &mls, 4, 0) catch |err| return if (err == error.HashBitsOutOfRange) error.BadLevel else @errorCast(err);
            }
            mls_opt = mls;
        }

        // Pre-allocate match table once for all blocks (L5+ only).
        const serial_mt_buf: ?[]mls_mod.LengthAndOffset = if (can_compress and mapping.codec_level >= 5)
            allocator.alloc(mls_mod.LengthAndOffset, 4 * high_compressor.sub_chunk_size) catch return error.OutOfMemory
        else
            null;
        defer if (serial_mt_buf) |buf| allocator.free(buf);

        var src_off: usize = 0;
        while (can_compress and src_off < src.len) {
            const block_src_len: usize = @min(src.len - src_off, lz_constants.chunk_size);
            const block_dst_remaining: usize = dst.len - pos;
            const keyframe = self_contained or src_off == 0;
            const written = try compressOneHighBlock(
                &ctx,
                &hasher,
                if (mls_opt) |*m| m else null,
                src,
                src_off,
                block_src_len,
                dst[pos..][0..block_dst_remaining],
                sc_flag_bit,
                keyframe,
                serial_mt_buf,
            );
            pos += written;
            src_off += block_src_len;
        }

        try emitScPrefixTable(if (self_contained) src else src[0..0], dst, &pos);
        try finalizeSingleFrameBlock(
            src,
            dst,
            &pos,
            frame_block_hdr_pos,
            frame_block_start,
            can_compress,
        );
    }

    // End mark.
    if (pos + 4 > dst.len) return error.DestinationTooSmall;
    frame.writeEndMark(dst[pos..]);
    pos += 4;
    return pos;
}

/// Compresses one frame-sized block with dict carry-over into `dst[pos..]`.
/// Allocate per-block MLS, run match
/// finder on `window_slice` with `preload_size = dict_bytes`, iterate the
/// 256 KB internal blocks, write the 8-byte frame block header, and fall
/// back to an uncompressed frame block if the compressed payload didn't
/// beat raw. Updates `*pos_ptr` to the end of the written frame block.
pub fn compressOneFrameBlockWindowed(
    allocator: std.mem.Allocator,
    ctx: *const high_encoder.HighEncoderContext,
    hasher: *high_compressor.HighHasher,
    mapping: HighMapping,
    window_slice: []const u8,
    dict_bytes: usize,
    block_bytes: usize,
    dst: []u8,
    pos_ptr: *usize,
    src: []const u8,
    src_off_abs: usize,
) CompressError!void {
    var pos = pos_ptr.*;
    if (pos + 8 > dst.len) return error.DestinationTooSmall;
    const fbh_pos: usize = pos;
    pos += 8;
    const fb_start: usize = pos;

    // Per-frame-block MLS. Size is `block_bytes + 1` because the MLS
    // stores matches for the NEW bytes only (preload positions are
    // inserted into the match finder's hash/tree but no matches are
    // recorded for them).
    //
    // `round_start_pos` is the uncapped absolute offset of
    // the new bytes from the start of the stream, NOT the post-cap
    // dict size. The optimal parser uses
    //   `mls_start = start_pos - round_start_pos`
    // and `start_pos == 0` is also the trigger for the 8-byte initial
    // raw-literal copy at the very start of the stream. Using the
    // capped `dict_bytes` here would (a) make every multi-block stream
    // re-emit the 8-byte raw prefix at every block boundary, and
    // (b) make the cost model treat each block as a cold start.
    var mls = try mls_mod.ManagedMatchLenStorage.init(allocator, block_bytes + 1, 8.0);
    defer mls.deinit();
    mls.window_base_offset = @intCast(dict_bytes);
    mls.round_start_pos = @intCast(src_off_abs);

    if (mapping.use_bt4) {
        try match_finder_bt4.findMatchesBT4(allocator, window_slice, &mls, 4, dict_bytes, 128);
    } else {
        match_finder.findMatchesHashBased(allocator, window_slice, &mls, 4, dict_bytes) catch |err| return if (err == error.HashBitsOutOfRange) error.BadLevel else @errorCast(err);
    }

    // Iterate the 256 KB internal blocks of this frame block's NEW bytes.
    // Pass the FULL `src` (not `window_slice`) so the optimal parser's
    // `start_pos = src_off + sub_off` is the absolute stream offset that
    // matches `offset + (src - sourceStart)`.
    // With `mls.round_start_pos = src_off_abs`, this still gives the
    // block-relative MLS index: `start_pos - round_start_pos = inner_off
    // + sub_off`.
    // Keyframe rule:
    //   `bool keyframe = sc || (blockSrc == dictBase)`
    // where `dictBase = srcIn - dictSize_capped`. The first inner 256 KB
    // block has `blockSrc == srcIn`, so the keyframe flag fires whenever
    // the post-cap `dict_bytes == 0` (frame block 0 always; every L9/L10
    // frame block since their cap is `64 MB - 128 MB block = 0`; every
    // L11 frame block where the cap clamped dict to 0). Subsequent inner
    // blocks (`inner_off > 0`) are never keyframes.
    // Pre-allocate match table once for all sub-chunks in this frame
    // block (L5+ only). Max sub-chunk = sub_chunk_size, so the table
    // needs 4 * sub_chunk_size entries. Reused across inner blocks and
    // sub-chunks, eliminating repeated alloc/free cycles.
    const framed_mt_buf: ?[]mls_mod.LengthAndOffset = if (ctx.compression_level >= 5)
        allocator.alloc(mls_mod.LengthAndOffset, 4 * high_compressor.sub_chunk_size) catch return error.OutOfMemory
    else
        null;
    defer if (framed_mt_buf) |buf| allocator.free(buf);

    var inner_off: usize = 0;
    while (inner_off < block_bytes) {
        const inner_len: usize = @min(block_bytes - inner_off, lz_constants.chunk_size);
        const keyframe = (inner_off == 0 and dict_bytes == 0);
        const written = try compressOneHighBlock(
            ctx,
            hasher,
            &mls,
            src,
            src_off_abs + inner_off,
            inner_len,
            dst[pos..],
            0, // sc_flag_bit
            keyframe,
            framed_mt_buf,
        );
        pos += written;
        inner_off += inner_len;
    }

    // Frame-block fallback: rewrite as uncompressed if the LZ payload
    // didn't beat raw.
    const fb_compressed_size = pos - fb_start;
    if (fb_compressed_size >= block_bytes) {
        pos = fb_start;
        if (pos + block_bytes > dst.len) return error.DestinationTooSmall;
        frame.writeBlockHeader(dst[fbh_pos..], .{
            .compressed_size = @intCast(block_bytes),
            .decompressed_size = @intCast(block_bytes),
            .uncompressed = true,
            .parallel_decode_metadata = false,
        });
        @memcpy(dst[pos..][0..block_bytes], src[src_off_abs..][0..block_bytes]);
        pos += block_bytes;
    } else {
        frame.writeBlockHeader(dst[fbh_pos..], .{
            .compressed_size = @intCast(fb_compressed_size),
            .decompressed_size = @intCast(block_bytes),
            .uncompressed = false,
            .parallel_decode_metadata = false,
        });
    }

    pos_ptr.* = pos;
}

/// Appends the SC per-chunk first-8-bytes prefix table. Matches
/// `StreamLzCompressor.AppendSelfContainedPrefixTable`. `src` should be
/// empty (zero-length slice) in non-SC paths to no-op.
pub fn emitScPrefixTable(src: []const u8, dst: []u8, pos_ptr: *usize) CompressError!void {
    if (src.len == 0) return;
    const num_chunks: usize = (src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
    var i: usize = 1;
    var pos = pos_ptr.*;
    while (i < num_chunks) : (i += 1) {
        const chunk_start = i * lz_constants.chunk_size;
        if (chunk_start >= src.len) break;
        const copy_size: usize = @min(@as(usize, 8), src.len - chunk_start);
        if (pos + 8 > dst.len) return error.DestinationTooSmall;
        @memset(dst[pos..][0..8], 0);
        @memcpy(dst[pos..][0..copy_size], src[chunk_start..][0..copy_size]);
        pos += 8;
    }
    pos_ptr.* = pos;
}

/// Fallback for the legacy single-frame-block paths (parallel SC/non-SC
/// and short-source). Writes the frame block header and, if the codec's
/// output didn't beat raw, rewrites the frame block as one uncompressed
/// block. Used only for code paths that haven't been ported to the
/// sliding-window frame-block loop.
pub fn finalizeSingleFrameBlock(
    src: []const u8,
    dst: []u8,
    pos_ptr: *usize,
    frame_block_hdr_pos: usize,
    frame_block_start: usize,
    can_compress: bool,
) CompressError!void {
    var pos = pos_ptr.*;
    const frame_block_compressed_size = pos - frame_block_start;
    if (!can_compress or frame_block_compressed_size >= src.len) {
        pos = frame_block_start;
        if (pos + src.len > dst.len) return error.DestinationTooSmall;
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(src.len),
            .decompressed_size = @intCast(src.len),
            .uncompressed = true,
            .parallel_decode_metadata = false,
        });
        @memcpy(dst[pos..][0..src.len], src);
        pos += src.len;
    } else {
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(frame_block_compressed_size),
            .decompressed_size = @intCast(src.len),
            .uncompressed = false,
            .parallel_decode_metadata = false,
        });
    }
    pos_ptr.* = pos;
}

// ────────────────────────────────────────────────────────────
//  compressOneHighBlock — single 256 KB block → caller-owned dst
// ────────────────────────────────────────────────────────────

/// Compresses a single 256 KB block of `src` (starting at `src_off`,
/// `block_src_len` bytes) into `dst_block`. Returns the number of
/// bytes written. The output contains the 2-byte internal block
/// header + 4-byte chunk header + sub-chunk payload(s), or a
/// fall-back uncompressed 2-byte block header + raw payload when
/// LZ compression doesn't beat raw for this block.
///
/// Single-block High compression helper with
/// per-sub-chunk loop inlined (matching `compressFramedHigh`'s
/// structure). Shared by the serial and parallel block loops.
pub fn compressOneHighBlock(
    ctx: *const high_encoder.HighEncoderContext,
    hasher: *high_compressor.HighHasher,
    mls_ptr: ?*const mls_mod.ManagedMatchLenStorage,
    src: []const u8,
    src_off: usize,
    block_src_len: usize,
    dst_block: []u8,
    sc_flag_bit: u8,
    keyframe: bool,
    match_table_buf: ?[]mls_mod.LengthAndOffset,
) CompressError!usize {
    var local_pos: usize = 0;
    const block_src: []const u8 = src[src_off..][0..block_src_len];

    // 2-byte block header (compressed, codec=high)
    if (local_pos + 2 > dst_block.len) return error.DestinationTooSmall;
    var flags0: u8 = 0x05 | sc_flag_bit;
    if (keyframe) flags0 |= 0x40;
    dst_block[local_pos] = flags0;
    dst_block[local_pos + 1] = @intFromEnum(block_header.CodecType.high);
    local_pos += 2;

    if (areAllBytesEqual(block_src)) {
        if (local_pos + 4 + 1 > dst_block.len) return error.DestinationTooSmall;
        const memset_hdr: u32 = lz_constants.chunk_size_mask | (@as(u32, 1) << lz_constants.chunk_type_shift);
        std.mem.writeInt(u32, dst_block[local_pos..][0..4], memset_hdr, .little);
        local_pos += 4;
        dst_block[local_pos] = block_src[0];
        local_pos += 1;
        return local_pos;
    }

    // 4-byte chunk header placeholder
    if (local_pos + 4 > dst_block.len) return error.DestinationTooSmall;
    const chunk_hdr_pos: usize = local_pos;
    local_pos += 4;
    const chunk_payload_start: usize = local_pos;

    var total_cost: f32 = 0;
    var sub_off: usize = 0;

    while (sub_off < block_src_len) {
        const round_bytes: usize = @min(block_src_len - sub_off, high_compressor.sub_chunk_size);
        const sub_src: []const u8 = src[src_off + sub_off ..][0..round_bytes];

        const round_f: f32 = @floatFromInt(round_bytes);
        const sub_memset_cost: f32 =
            (round_f * cost_coeffs.memset_per_byte + cost_coeffs.memset_base) *
            ctx.speed_tradeoff +
            round_f + 3.0;

        var lz_chose = false;
        if (round_bytes >= 32 and !areAllBytesEqual(sub_src)) {
            const sub_hdr_pos: usize = local_pos;
            local_pos += 3;
            const sub_payload_start: usize = local_pos;
            // `start_pos` is the cumulative offset from `windowBase` —
            // the absolute position of this sub-chunk within the
            // current frame block:
            // `offset + (int)(src - sourceStart)`. Both SC and non-SC
            // pass the same monotonic offset; the SC enforcement happens
            // inside the optimal parser via `scMaxBack = startPos + pos`.
            const start_position_for_sub: usize = src_off + sub_off;

            var chunk_type: i32 = -1;
            var lz_cost: f32 = std.math.inf(f32);
            const dst_remaining_for_sub: usize = dst_block.len - sub_payload_start;
            const dst_sub_start: [*]u8 = dst_block[sub_payload_start..].ptr;
            const dst_sub_end: [*]u8 = dst_sub_start + dst_remaining_for_sub;
            const n_opt: ?usize = high_compressor.doCompress(
                ctx,
                hasher,
                mls_ptr,
                sub_src.ptr,
                @intCast(round_bytes),
                dst_sub_start,
                dst_sub_end,
                @intCast(start_position_for_sub),
                &chunk_type,
                &lz_cost,
                match_table_buf,
            ) catch null;

            if (n_opt) |n| {
                const total_lz_cost = lz_cost + 3.0;
                const lz_wins = total_lz_cost < sub_memset_cost and n > @as(usize, 0) and n < round_bytes;
                if (lz_wins) {
                    const hdr: u32 = @as(u32, @intCast(n)) |
                        (@as(u32, @intCast(chunk_type)) << lz_constants.sub_chunk_type_shift) |
                        lz_constants.chunk_header_compressed_flag;
                    dst_block[sub_hdr_pos + 0] = @intCast((hdr >> 16) & 0xFF);
                    dst_block[sub_hdr_pos + 1] = @intCast((hdr >> 8) & 0xFF);
                    dst_block[sub_hdr_pos + 2] = @intCast(hdr & 0xFF);
                    local_pos = sub_payload_start + n;
                    total_cost += total_lz_cost;
                    lz_chose = true;
                } else {
                    local_pos = sub_hdr_pos;
                }
            } else {
                // Compression wasn't beneficial — fall back to raw.
                local_pos = sub_hdr_pos;
            }
        }

        if (!lz_chose) {
            if (local_pos + 3 + round_bytes > dst_block.len) return error.DestinationTooSmall;
            const hdr: u32 = @as(u32, @intCast(round_bytes)) | lz_constants.chunk_header_compressed_flag;
            dst_block[local_pos + 0] = @intCast((hdr >> 16) & 0xFF);
            dst_block[local_pos + 1] = @intCast((hdr >> 8) & 0xFF);
            dst_block[local_pos + 2] = @intCast(round_bytes & 0xFF);
            @memcpy(dst_block[local_pos + 3 ..][0..round_bytes], sub_src);
            local_pos += 3 + round_bytes;
            total_cost += sub_memset_cost;
        }

        sub_off += round_bytes;
    }

    const chunk_compressed_size: usize = local_pos - chunk_payload_start;
    const block_f: f32 = @floatFromInt(block_src_len);
    const block_memset_cost: f32 =
        (block_f * cost_coeffs.memset_per_byte + cost_coeffs.memset_base) *
        ctx.speed_tradeoff +
        block_f + 4.0;
    const should_bail = chunk_compressed_size >= block_src_len or total_cost > block_memset_cost;
    if (should_bail) {
        local_pos = 0;
        if (local_pos + 2 + block_src_len > dst_block.len) return error.DestinationTooSmall;
        var unc_flags0: u8 = 0x05 | 0x80 | sc_flag_bit;
        if (keyframe) unc_flags0 |= 0x40;
        dst_block[local_pos] = unc_flags0;
        dst_block[local_pos + 1] = @intFromEnum(block_header.CodecType.high);
        local_pos += 2;
        @memcpy(dst_block[local_pos..][0..block_src_len], block_src);
        local_pos += block_src_len;
    } else {
        // v2 chunk header: conservative 0 for has_cross_chunk_match (see
        // comment at the Fast encoder's write site). High codec chunks
        // always get 0 for now — the High parallel decode path uses
        // SC-group semantics rather than the Fast phase-1 sidecar, so
        // the bit has no effect on High decode correctness.
        const has_cross_chunk_match_bit: u32 = 0;
        const raw: u32 = @as(u32, @intCast(chunk_compressed_size - 1)) | has_cross_chunk_match_bit;
        std.mem.writeInt(u32, dst_block[chunk_hdr_pos..][0..4], raw, .little);
    }

    return local_pos;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

test "mapHighLevel L6" {
    const m = mapHighLevel(6);
    try std.testing.expectEqual(@as(i32, 5), m.codec_level);
    try std.testing.expect(m.self_contained);
    try std.testing.expect(!m.use_bt4);
}

test "mapHighLevel L7" {
    const m = mapHighLevel(7);
    try std.testing.expectEqual(@as(i32, 7), m.codec_level);
    try std.testing.expect(m.self_contained);
    try std.testing.expect(!m.use_bt4);
}

test "mapHighLevel L8" {
    const m = mapHighLevel(8);
    try std.testing.expectEqual(@as(i32, 9), m.codec_level);
    try std.testing.expect(m.self_contained);
    try std.testing.expect(m.use_bt4);
}

test "mapHighLevel L9" {
    const m = mapHighLevel(9);
    try std.testing.expectEqual(@as(i32, 5), m.codec_level);
    try std.testing.expect(!m.self_contained);
    try std.testing.expect(!m.use_bt4);
}

test "mapHighLevel L10" {
    const m = mapHighLevel(10);
    try std.testing.expectEqual(@as(i32, 7), m.codec_level);
    try std.testing.expect(!m.self_contained);
    try std.testing.expect(!m.use_bt4);
}

test "mapHighLevel L11" {
    const m = mapHighLevel(11);
    try std.testing.expectEqual(@as(i32, 9), m.codec_level);
    try std.testing.expect(!m.self_contained);
    try std.testing.expect(m.use_bt4);
}

test "compressFramedHigh: empty input roundtrip" {
    const allocator = std.testing.allocator;
    var dst: [256]u8 = undefined;
    const n = try compressFramedHigh(allocator, &.{}, &dst, .{ .level = 9 });
    try std.testing.expect(n > 0);
    try std.testing.expect(n < 64);
    const decoder = @import("../decode/streamlz_decoder.zig");
    var dec_buf: [64]u8 = undefined;
    const dec_n = try decoder.decompressFramed(dst[0..n], &dec_buf);
    try std.testing.expectEqual(@as(usize, 0), dec_n);
}
