//! Fast codec frame builder — produces a single SLZ1-framed block
//! for Fast levels L1-L5.
//!
//! Extracted from `streamlz_encoder.zig` to isolate the Fast-codec
//! frame construction from the top-level dispatch and the High-codec
//! path.  `compressFramedOne` is the sole public entry point.

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const block_header = @import("../format/block_header.zig");
const lz_constants = @import("../format/streamlz_constants.zig");
const pdm = @import("../format/parallel_decode_metadata.zig");
const cleanness = @import("../decode/cross_chunk_analyzer.zig");
const fast_constants = @import("fast/fast_constants.zig");
const FastMatchHasher = @import("fast/fast_match_hasher.zig").FastMatchHasher;
const match_hasher = @import("match_hasher.zig");
const fast_enc = @import("fast/fast_lz_encoder.zig");
const entropy_enc = @import("entropy/entropy_encoder.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const EntropyOptions = entropy_enc.EntropyOptions;

const MatchHasher2 = match_hasher.MatchHasher2;

const encoder = @import("streamlz_encoder.zig");
const Options = encoder.Options;
const CompressError = encoder.CompressError;
const resolveParams = encoder.resolveParams;
const entropyOptionsForLevel = encoder.entropyOptionsForLevel;
const compressBound = encoder.compressBound;

// Also need the High-framed path for L6+ dispatch inside compressFramedOne.
const high_framed = @import("high_framed.zig");

const areAllBytesEqual = block_header.areAllBytesEqual;

/// Single-piece compress — builds one Fast-codec SLZ1 frame from
/// `src` into `dst`.  For levels 6+, delegates to the High-codec
/// frame builder.  The public `compressFramed` wrapper handles
/// multi-piece OOM retry around this function.
pub fn compressFramedOne(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    // Levels 6-11 use the High codec (optimal parser + hash-based /
    // BT4 match finder). Fork here so the Fast path below stays
    // byte-exact for L1-L5.
    if (opts.level >= 6) {
        return high_framed.compressFramedHigh(allocator, src, dst, opts);
    }

    // ── Frame header ────────────────────────────────────────────────────
    //
    // MapLevel maps unified level (1-11) to
    // (codec, codecLevel). For Fast levels 1-5 the mapping is 1→1, 2→2,
    // 3→3, 4→5 (Fast 4 is skipped), 5→6. The STORED level in the frame
    // header is the codec-level, not the unified level. Replicate that so
    // the written byte matches the format spec exactly.
    const codec_level: u8 = switch (opts.level) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 5,
        5 => 6,
        else => unreachable,
    };
    var pos: usize = 0;
    const hdr_len = try frame.writeHeader(dst, .{
        .codec = .fast,
        .level = codec_level,
        .block_size = opts.block_size,
        .content_size = if (opts.include_content_size) @as(u64, @intCast(src.len)) else null,
        .dictionary_id = opts.dictionary_id,
    });
    pos += hdr_len;

    // ── Resolve per-input parameters ───────────────────────────────────
    const resolved = resolveParams(src, opts);
    // Per-level engine hash-bit caps
    // where `maxHashBits = level switch { -3=>13, -2=>14, -1=>16, 0|1=>17, 2=>19, _ => adaptive }`.
    const engine_level_cap: u6 = switch (resolved.engine_level) {
        -3 => 13,
        -2 => 14,
        -1 => 16,
        0, 1 => 17,
        2 => 19,
        else => resolved.hash_bits,
    };
    const greedy_hash_bits: u6 = @min(resolved.hash_bits, engine_level_cap);

    // ── Allocate the persistent hasher(s) this level needs ────────────
    //
    //   engine level ≤ -2  → FastMatchHasher<ushort>   (user L1)
    //   engine level ∈ {-1,1,2} → FastMatchHasher<uint>   (user L2, L3, L4)
    //   engine level == 4  → MatchHasher2 chain hasher (user L5)
    // Slz.MapLevel skips Fast 4 entirely, so no MatchHasher2x bucket.
    var greedy_hasher_u16: ?FastMatchHasher(u16) = null;
    defer if (greedy_hasher_u16) |*h| h.deinit();
    var greedy_hasher_u32: ?FastMatchHasher(u32) = null;
    defer if (greedy_hasher_u32) |*h| h.deinit();
    var chain_hasher: ?MatchHasher2 = null;
    defer if (chain_hasher) |*h| h.deinit();

    switch (opts.level) {
        1 => {
            // Fast 1 (engine -2): u16 hash table, 14-bit cap. Hasher gets
            // the text-bumped min_match_length (affects hash multiplier).
            greedy_hasher_u16 = FastMatchHasher(u16).init(allocator, .{
                .hash_bits = greedy_hash_bits,
                .min_match_length = resolved.hasher_min_match_length,
            }) catch |err| return if (err == error.HashBitsOutOfRange) error.BadLevel else @errorCast(err);
        },
        5 => {
            // Fast 6 (engine 4): lazy chain hasher with lazy-2 evaluation.
            chain_hasher = try MatchHasher2.init(allocator, resolved.hash_bits);
        },
        else => {
            // Fast 2 (engine -1), Fast 3 (engine 1), Fast 5 (engine 2).
            greedy_hasher_u32 = FastMatchHasher(u32).init(allocator, .{
                .hash_bits = greedy_hash_bits,
                .min_match_length = resolved.hasher_min_match_length,
            }) catch |err| return if (err == error.HashBitsOutOfRange) error.BadLevel else @errorCast(err);
        },
    }

    const speed_tradeoff = cost_coeffs.speedTradeoffFor(
        cost_coeffs.default_space_speed_tradeoff_bytes,
        resolved.use_entropy,
    );
    const parser_config: fast_enc.ParserConfig = .{
        // Parser mmlt uses the UN-bumped value (reads opts.MinMatchLength
        // in FastParser.CompressGreedy regardless of the text bump).
        .minimum_match_length = resolved.parser_min_match_length,
        .dictionary_size = resolved.dict_size,
        .speed_tradeoff = speed_tradeoff,
    };

    // Reset all hashers ONCE at the top of compressFramed
    // `SetupEncoder` → `CreateFastHasher<T>.AllocateHash` which clears the
    // table once per CompressBlock_Fast call and then never re-clears.
    //
    // The greedy parser uses the hash table with positions stored in
    // WHOLE-INPUT coordinates (measured from src.ptr). Stale entries from
    // sub-chunk N−1 read during sub-chunk N give huge offsets that fail
    // the `offset <= cursor - source_block_base` bound check.
    if (greedy_hasher_u16) |*h| h.reset();
    if (greedy_hasher_u32) |*h| h.reset();
    if (chain_hasher) |*h| {
        h.reset();
        h.setSrcBase(src.ptr);
        h.setBaseWithoutPreload(0);
    }

    // ── ONE frame block wraps all internal 256 KB chunks ───────────────
    // Empty source: the stream-based compress loop
    // never enters the body (`while (bytesRead > 0)`), so it writes only the
    // frame header + end mark and returns. Match that here to keep parity
    // on zero-byte inputs.
    if (src.len == 0) {
        if (pos + 4 > dst.len) return error.DestinationTooSmall;
        frame.writeEndMark(dst[pos..]);
        pos += 4;
        return pos;
    }

    // The framed compressor calls the block compressor
    // which produces a single buffer of concatenated internal blocks, and
    // wraps the whole thing in ONE frame block header. Match that.
    const frame_block_hdr_pos: usize = pos;
    pos += 8;
    const frame_block_start: usize = pos;

    const can_compress = src.len > fast_constants.min_source_length;

    // Self-contained mode: each 256 KB block is independently decodable.
    // CompressOneBlock and
    // `AppendSelfContainedPrefixTable`. `two_phase` implies `self_contained`
    //
    const self_contained: bool = opts.self_contained or opts.two_phase;
    const sc_flag_bit: u8 = if (self_contained) 0x10 else 0;
    const two_phase_flag_bit: u8 = if (opts.two_phase) 0x20 else 0;

    // CompressBlocksSerial -> CompressOneBlock -> CompressChunk.
    // Structure:
    //   per 256 KB block:
    //     if all-equal → 2-byte block hdr + 5-byte memset chunk hdr, done
    //     else: 2-byte block hdr + 4-byte chunk hdr placeholder + sub-chunks
    //            per sub-chunk:
    //              < 32 → 3-byte raw sub-chunk hdr + memcpy
    //              all-equal → EncodeArrayU8 memcpy (no compressed flag)
    //              else → LZ; compare lzCost vs memsetCost vs plainHuffCost
    //            if totalCost > blockMemsetCost → rewind, emit uncompressed block
    //            else backfill chunk hdr
    const check_plain_huffman: bool = resolved.use_entropy and resolved.engine_level >= 4;

    var src_off: usize = 0;
    while (can_compress and src_off < src.len) {
        const block_src_len: usize = @min(src.len - src_off, lz_constants.chunk_size);
        const block_src: []const u8 = src[src_off..][0..block_src_len];

        // SC mode: the backward-extend bound + hasher visibility must be
        // block-local so no LZ back-reference reaches across 256 KB chunks.
        // Reset the hasher at every block boundary, set window_base to the
        // current block's start. Non-SC keeps the whole-input window (phase 10j).
        if (self_contained) {
            if (greedy_hasher_u16) |*h| h.reset();
            if (greedy_hasher_u32) |*h| h.reset();
            if (chain_hasher) |*h| {
                h.reset();
                h.setSrcBase(block_src.ptr);
                h.setBaseWithoutPreload(0);
            }
        }
        const window_base_ptr: [*]const u8 = if (self_contained) block_src.ptr else src.ptr;

        const block_start: usize = pos;
        // For SC mode, EVERY block is a keyframe (independently decodable).
        // Keyframe when sc || first block in frame.
        const keyframe = self_contained or src_off == 0;

        // ── Write 2-byte block header (compressed) ──────────────────────
        if (pos + 2 > dst.len) return error.DestinationTooSmall;
        var flags0: u8 = 0x05 | sc_flag_bit | two_phase_flag_bit;
        if (keyframe) flags0 |= 0x40;
        dst[pos] = flags0;
        dst[pos + 1] = @intFromEnum(block_header.CodecType.fast);
        pos += 2;

        // ── Block-level AreAllBytesEqual → memset chunk header ─────────
        //
        if (areAllBytesEqual(block_src)) {
            if (pos + 4 + 1 > dst.len) return error.DestinationTooSmall;
            const memset_hdr: u32 = lz_constants.chunk_size_mask | (@as(u32, 1) << lz_constants.chunk_type_shift);
            std.mem.writeInt(u32, dst[pos..][0..4], memset_hdr, .little);
            pos += 4;
            dst[pos] = block_src[0];
            pos += 1;
            src_off += block_src_len;
            continue;
        }

        // ── 4-byte chunk header placeholder ────────────────────────────
        if (pos + 4 > dst.len) return error.DestinationTooSmall;
        const chunk_hdr_pos: usize = pos;
        pos += 4;
        const chunk_payload_start: usize = pos;

        // ── Iterate sub-chunks ─────────────────────────────────────────
        // Per sub-chunk:
        //   * < 32 bytes → raw-flag sub-chunk header + raw bytes
        //   * all-equal → EncodeArrayU8 (memcpy, no compressed flag)
        //   * else → LZ encode + cost-based 3-way decision
        var total_cost: f32 = 0;
        var sub_off: usize = 0;

        while (sub_off < block_src_len) {
            const round_bytes: usize = @min(block_src_len - sub_off, fast_constants.sub_chunk_size);
            const sub_src: []const u8 = src[src_off + sub_off ..][0..round_bytes];

            const round_f: f32 = @floatFromInt(round_bytes);
            const sub_memset_cost: f32 =
                (round_f * cost_coeffs.memset_per_byte + cost_coeffs.memset_base) *
                speed_tradeoff +
                round_f + 3.0;

            if (round_bytes >= 32) {
                if (areAllBytesEqual(sub_src)) {
                    // Plain memcpy via
                    // EncodeArrayU8. For Fast (tANS disabled) this falls
                    // through to a 3-byte BE memcpy header + raw bytes,
                    // which has the compressed flag CLEAR (size ≤ 18 bits).
                    if (pos + round_bytes + 3 > dst.len) return error.DestinationTooSmall;
                    dst[pos + 0] = @intCast((round_bytes >> 16) & 0xFF);
                    dst[pos + 1] = @intCast((round_bytes >> 8) & 0xFF);
                    dst[pos + 2] = @intCast(round_bytes & 0xFF);
                    @memcpy(dst[pos + 3 ..][0..round_bytes], sub_src);
                    pos += round_bytes + 3;
                    // EncodeArrayU8 memcpy cost = count + 3.
                    total_cost += @floatFromInt(round_bytes + 3);
                    sub_off += round_bytes;
                    continue;
                }

                // ── LZ trial encode ────────────────────────────────────
                const sub_hdr_pos: usize = pos;
                pos += 3;
                const sub_payload_start: usize = pos;

                const start_position_for_sub: usize = src_off + sub_off;
                const entropy_options = entropyOptionsForLevel(opts.level);
                const result = try switch (opts.level) {
                    1 => fast_enc.encodeSubChunkRaw(-2, u16, allocator, &greedy_hasher_u16.?, sub_src, window_base_ptr, dst[sub_payload_start..], start_position_for_sub, parser_config),
                    2 => fast_enc.encodeSubChunkRaw(-1, u32, allocator, &greedy_hasher_u32.?, sub_src, window_base_ptr, dst[sub_payload_start..], start_position_for_sub, parser_config),
                    3 => fast_enc.encodeSubChunkEntropy(1, allocator, &greedy_hasher_u32.?, sub_src, window_base_ptr, dst[sub_payload_start..], start_position_for_sub, entropy_options, parser_config),
                    4 => fast_enc.encodeSubChunkEntropy(2, allocator, &greedy_hasher_u32.?, sub_src, window_base_ptr, dst[sub_payload_start..], start_position_for_sub, entropy_options, parser_config),
                    5 => fast_enc.encodeSubChunkEntropyChain(4, allocator, &chain_hasher.?, sub_src, window_base_ptr, dst[sub_payload_start..], start_position_for_sub, entropy_options, parser_config),
                    else => unreachable,
                };
                const lz_cost: f32 = result.cost + 3.0; // +3 for sub-chunk header

                // ── Plain-Huffman trial encode (CheckPlainHuffman path) ──
                //
                // For Fast with no tANS/Huffman, EncodeArrayU8 falls back to
                // memcpy which always returns count+3 bytes (i.e., never
                // beats raw), so plain_huff_cost is always invalidated.
                // We still emit the same decision arm to stay byte-parity
                // in case the order of operations matters.
                var plain_huff_cost: f32 = std.math.inf(f32);
                if (check_plain_huffman) {
                    plain_huff_cost = @min(sub_memset_cost, lz_cost);
                    // EncodeArrayU8 memcpy returns count + 3. Check matches
                    // plainHuffN < 0 || plainHuffN >= roundBytes.
                    const plain_huff_n: usize = round_bytes + 3;
                    if (plain_huff_n >= round_bytes) {
                        plain_huff_cost = std.math.inf(f32);
                    }
                }

                const lz_wins = !result.bail and
                    lz_cost < sub_memset_cost and
                    lz_cost <= plain_huff_cost and
                    result.bytes_written > 0 and
                    result.bytes_written < round_bytes;

                if (lz_wins) {
                    // LZ path: backfill 3-byte sub-chunk header.
                    const hdr: u32 = @as(u32, @intCast(result.bytes_written)) |
                        (@as(u32, @intFromEnum(result.chunk_type)) << lz_constants.sub_chunk_type_shift) |
                        lz_constants.chunk_header_compressed_flag;
                    dst[sub_hdr_pos + 0] = @intCast((hdr >> 16) & 0xFF);
                    dst[sub_hdr_pos + 1] = @intCast((hdr >> 8) & 0xFF);
                    dst[sub_hdr_pos + 2] = @intCast(hdr & 0xFF);
                    pos = sub_payload_start + result.bytes_written;
                    total_cost += lz_cost;
                } else if (sub_memset_cost <= plain_huff_cost) {
                    // Memset (uncompressed) path: 3-byte header with
                    // compressed flag set, size = round_bytes, then raw
                    // bytes verbatim. Rewind the LZ-written payload.
                    pos = sub_hdr_pos;
                    if (pos + 3 + round_bytes > dst.len) return error.DestinationTooSmall;
                    const hdr: u32 = @as(u32, @intCast(round_bytes)) | lz_constants.chunk_header_compressed_flag;
                    dst[pos + 0] = @intCast((hdr >> 16) & 0xFF);
                    dst[pos + 1] = @intCast((hdr >> 8) & 0xFF);
                    dst[pos + 2] = @intCast(hdr & 0xFF);
                    @memcpy(dst[pos + 3 ..][0..round_bytes], sub_src);
                    pos += 3 + round_bytes;
                    total_cost += sub_memset_cost;
                } else {
                    // Plain-huffman won. Without a real Huffman encoder this
                    // path is unreachable (plain_huff_cost is always ∞) but
                    //
                    pos = sub_hdr_pos;
                    if (pos + round_bytes + 3 > dst.len) return error.DestinationTooSmall;
                    dst[pos + 0] = @intCast((round_bytes >> 16) & 0xFF);
                    dst[pos + 1] = @intCast((round_bytes >> 8) & 0xFF);
                    dst[pos + 2] = @intCast(round_bytes & 0xFF);
                    @memcpy(dst[pos + 3 ..][0..round_bytes], sub_src);
                    pos += round_bytes + 3;
                    total_cost += plain_huff_cost;
                }
            } else {
                // round_bytes < 32: too small to compress.
                if (pos + 3 + round_bytes > dst.len) return error.DestinationTooSmall;
                const hdr: u32 = @as(u32, @intCast(round_bytes)) | lz_constants.chunk_header_compressed_flag;
                dst[pos + 0] = @intCast((hdr >> 16) & 0xFF);
                dst[pos + 1] = @intCast((hdr >> 8) & 0xFF);
                dst[pos + 2] = @intCast(hdr & 0xFF);
                @memcpy(dst[pos + 3 ..][0..round_bytes], sub_src);
                pos += 3 + round_bytes;
                total_cost += sub_memset_cost;
            }

            sub_off += round_bytes;
        }

        // ── Block-level cost decision ──────────────────────────────────
        // Rewrite
        // the whole block as uncompressed if either the compressed chunk
        // didn't shrink the payload OR its cost exceeded the block-level
        // memset cost.
        const chunk_compressed_size: usize = pos - chunk_payload_start;
        const block_f: f32 = @floatFromInt(block_src_len);
        const block_memset_cost: f32 =
            (block_f * cost_coeffs.memset_per_byte + cost_coeffs.memset_base) *
            speed_tradeoff +
            block_f + 4.0; // +4 = ChunkHeaderSize
        const should_bail = chunk_compressed_size >= block_src_len or total_cost > block_memset_cost;
        if (should_bail) {
            pos = block_start;
            if (pos + 2 + block_src_len > dst.len) return error.DestinationTooSmall;
            var unc_flags0: u8 = 0x05 | 0x80 | sc_flag_bit | two_phase_flag_bit;
            if (keyframe) unc_flags0 |= 0x40;
            dst[pos] = unc_flags0;
            dst[pos + 1] = @intFromEnum(block_header.CodecType.fast);
            pos += 2;
            @memcpy(dst[pos..][0..block_src_len], block_src);
            pos += block_src_len;
        } else {
            // v2 chunk header: bits [17:0] = compressed_size - 1,
            // bits [19:18] = type (0 = normal), bit [20] = has_cross_chunk_match.
            // We conservatively write the bit as 0 ("may have cross-chunk refs")
            // for now — a true-value computation would require tracking
            // min_match_src across the Fast parser variants and plumbing it up
            // into EncodeResult. Decoders treat 0 as "check the sidecar"; a
            // future encoder can set the bit to 1 when it knows the chunk is
            // cross-chunk-free, enabling a fast dispatch path.
            const has_cross_chunk_match_bit: u32 = 0;
            const raw: u32 = @as(u32, @intCast(chunk_compressed_size - 1)) | has_cross_chunk_match_bit;
            std.mem.writeInt(u32, dst[chunk_hdr_pos..][0..4], raw, .little);
        }

        src_off += block_src_len;
    }

    // SC mode: append a prefix table of (num_chunks - 1) * 8 bytes at the
    // end of the frame block payload. Each entry holds the first 8 bytes of
    // chunks 1..N-1 (the 0-fill + memcpy trick matches the format
    // `StreamLzCompressor.AppendSelfContainedPrefixTable` lines 407-426).
    // The parallel decompressor uses these to restore the corrupted first
    // 8 bytes of each per-worker-decoded chunk.
    if (self_contained and can_compress) {
        const num_chunks: usize = (src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
        var i: usize = 1;
        while (i < num_chunks) : (i += 1) {
            const chunk_start = i * lz_constants.chunk_size;
            if (chunk_start >= src.len) break;
            const copy_size: usize = @min(@as(usize, 8), src.len - chunk_start);
            if (pos + 8 > dst.len) return error.DestinationTooSmall;
            // Zero-fill the 8-byte slot before copying, so the trailing
            // bytes past `copy_size` are deterministic.
            @memset(dst[pos..][0..8], 0);
            @memcpy(dst[pos..][0..copy_size], src[chunk_start..][0..copy_size]);
            pos += 8;
        }
    }

    // Frame block fallback: if compressed total didn't beat uncompressed
    // (or input too small), rewrite the frame block as one uncompressed
    // frame block.
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

    // ── v2 parallel-decode sidecar block ───────────────────────────────
    //
    // For Fast L1-L4 compressed data (opts.level 1..4), compute the
    // cross-sub-chunk closure from the just-written compressed bytes
    // and append a sidecar block that parallel decoders can consume.
    // The sidecar lives BETWEEN the last compressed block and the end
    // mark, with the new `parallel_decode_metadata_flag` on its outer
    // block header so serial decoders skip it cleanly.
    //
    // buildPpocSidecar walks the just-written frame (header + blocks)
    // using `src` as the reference for literal-leaf byte values — the
    // original input, which we already have. No decode pass needed.
    //
    // Encoder failures (OOM from the analyzer's byte_earliest /
    // producer_map allocations) are swallowed: we silently omit the
    // sidecar and leave the frame flag clear. The frame still decodes
    // correctly via the serial path; only parallel-decode acceleration
    // is forfeited for that specific compress call.
    // Sidecar emission is scoped to Fast L1-L4 (the levels the PoC
    // closure analysis and parallel-decode path were designed for).
    // L5 uses the lazy chain parser with a very different token
    // distribution — the closure frequently exceeds millions of
    // entries on text input, the sidecar grows to 40%+ of the main
    // payload, and the walker's overcopy heuristics are unreliable
    // on its token layout. L5 decompresses correctly via the serial
    // path; extending parallel-decode support to it is a separate
    // task (probably needs a distinct codepath).
    if (opts.emit_parallel_decode_metadata and opts.level >= 1 and opts.level <= 5 and can_compress) {
        const sidecar_result = cleanness.buildPpocSidecar(allocator, dst[0..pos], src);
        if (sidecar_result) |*sc| {
            var sidecar = sc.*;
            defer sidecar.deinit(allocator);
            if (sidecar.match_ops.items.len > 0 or sidecar.literal_bytes.items.len > 0) {
                // Convert the analyzer's ArrayLists to pdm's
                // slice-based view. The analyzer's MatchOp and
                // LiteralByte structs have the same layout as pdm's,
                // so we copy via field names (no bitcast).
                //
                // Match ops are already emitted by the analyzer in
                // cmd_stream order (= file position order, which is
                // monotonically increasing in target_start). That's
                // exactly what the v2 sidecar writer wants, so no
                // re-sort needed.
                var tmp_match_ops = try allocator.alloc(pdm.MatchOp, sidecar.match_ops.items.len);
                defer allocator.free(tmp_match_ops);
                for (sidecar.match_ops.items, 0..) |op, i| {
                    tmp_match_ops[i] = .{
                        .target_start = op.target_start,
                        .src_start = op.src_start,
                        .length = op.length,
                    };
                }

                // Literal bytes come from two unrelated sources in
                // the analyzer (the closure BFS's literal leaves and
                // the walker's overcopy leaves), so they're NOT in
                // sorted order. The v2 writer assumes sorted input
                // (for run detection), so we sort before emitting.
                var tmp_literal_bytes = try allocator.alloc(pdm.LiteralByte, sidecar.literal_bytes.items.len);
                defer allocator.free(tmp_literal_bytes);
                for (sidecar.literal_bytes.items, 0..) |lit, i| {
                    tmp_literal_bytes[i] = .{
                        .position = lit.position,
                        .byte_value = lit.byte_value,
                    };
                }
                std.mem.sort(pdm.LiteralByte, tmp_literal_bytes, {}, struct {
                    fn lessThan(_: void, a: pdm.LiteralByte, b: pdm.LiteralByte) bool {
                        return a.position < b.position;
                    }
                }.lessThan);

                const body_size = pdm.serializedBodySize(tmp_match_ops, tmp_literal_bytes);
                // Outer block header (8 bytes) + body.
                if (pos + 8 + body_size > dst.len) {
                    // Out of output budget — skip the sidecar rather
                    // than failing the whole compress. Frame is still
                    // valid without it.
                } else {
                    // Write the 8-byte outer block header.
                    frame.writeBlockHeader(dst[pos..], .{
                        .compressed_size = @intCast(body_size),
                        .decompressed_size = 0,
                        .uncompressed = false,
                        .parallel_decode_metadata = true,
                    });
                    pos += 8;

                    // Write the sidecar body.
                    const body_written = try pdm.writeBlockBody(
                        dst[pos..],
                        tmp_match_ops,
                        tmp_literal_bytes,
                    );
                    pos += body_written;

                    // Patch the frame header flags byte to advertise the
                    // sidecar's presence. The flags byte is at offset 5
                    // (after magic+version). We use a bitwise-or so we
                    // don't clobber the other flag bits the encoder set.
                    dst[5] |= @as(u8, 1) << 4; // parallel_decode_metadata_present
                }
            }
        } else |_| {
            // buildPpocSidecar failed (probably OOM from the 400+ MB
            // byte_earliest + producer_map). Silently continue without
            // a sidecar — the frame is still correct, just slower to
            // parallel-decode.
        }
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

test "compressFramedOne: empty input roundtrip" {
    const allocator = std.testing.allocator;
    var dst: [256]u8 = undefined;
    const n = try compressFramedOne(allocator, &.{}, &dst, .{ .level = 1 });
    try std.testing.expect(n > 0);
    try std.testing.expect(n < 64);
    const decoder = @import("../decode/streamlz_decoder.zig");
    var dec_buf: [64]u8 = undefined;
    const dec_n = try decoder.decompressFramed(dst[0..n], &dec_buf);
    try std.testing.expectEqual(@as(usize, 0), dec_n);
}

test "compressFramedOne: all-equal bytes compresses small" {
    const allocator = std.testing.allocator;
    const src = try allocator.alloc(u8, 4096);
    defer allocator.free(src);
    @memset(src, 0xAA);
    const bound = compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    defer allocator.free(dst);
    const n = try compressFramedOne(allocator, src, dst, .{ .level = 1 });
    try std.testing.expect(n < 200);
    const decoder = @import("../decode/streamlz_decoder.zig");
    const dec = try allocator.alloc(u8, src.len + 64);
    defer allocator.free(dec);
    const dec_n = try decoder.decompressFramed(dst[0..n], dec);
    try std.testing.expectEqual(src.len, dec_n);
    try std.testing.expectEqualSlices(u8, src, dec[0..dec_n]);
}
