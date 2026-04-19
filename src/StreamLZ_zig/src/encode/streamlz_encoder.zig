//! Top-level StreamLZ framed compressor.
//! Used by: both codecs, top-level dispatcher
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
const pdm = @import("../format/parallel_decode_metadata.zig");
const cleanness = @import("../decode/cross_chunk_analyzer.zig");
const fast_constants = @import("fast_constants.zig");
const FastMatchHasher = @import("fast_match_hasher.zig").FastMatchHasher;
const match_hasher = @import("match_hasher.zig");
const fast_enc = @import("fast_lz_encoder.zig");
const entropy_enc = @import("entropy_encoder.zig");
const text_detector = @import("text_detector.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const EntropyOptions = entropy_enc.EntropyOptions;

const MatchHasher2x = match_hasher.MatchHasher2x;
const MatchHasher2 = match_hasher.MatchHasher2;

/// Default dictionary size when the caller doesn't override (1 GB).
pub const default_dictionary_size: u32 = 0x40000000;

// ────────────────────────────────────────────────────────────
//  Platform-specific memory query (delegated to platform/)
// ────────────────────────────────────────────────────────────
const memory_query = @import("../platform/memory_query.zig");

pub const per_thread_memory_estimate = memory_query.per_thread_memory_estimate;
pub const memory_budget_pct = memory_query.memory_budget_pct;
pub const totalAvailableMemoryBytes = memory_query.totalAvailableMemoryBytes;
pub const calculateMaxThreads = memory_query.calculateMaxThreads;

pub const CompressError = error{
    BadLevel,
    BadBlockSize,
    BadScGroupSize,
    DestinationTooSmall,
} || std.mem.Allocator.Error || fast_enc.EncodeError || std.Thread.SpawnError;

pub const Options = struct {
    /// User level 1–5 supported by the Fast encoder. (L6–L11 High codec
    /// lands in a later phase.)
    level: u8 = 1,
    /// Include the content-size field in the frame header (strongly recommended).
    include_content_size: bool = true,
    /// Block size in the frame header. Must be a power of two between
    /// `frame.min_block_size` and `frame.max_block_size`. We always emit
    /// 256 KB blocks internally but the frame header can advertise larger.
    block_size: u32 = lz_constants.chunk_size,

    // ── CompressOptions parity fields ────────────────────────────────────
    // Most of
    // these are plumbed here for API symmetry; the behavioral wiring lands
    // with subsequent parity steps (see the punch list in memory).

    /// Override the hash-table bit count (0 = adaptive). Matches
    /// Override hash-table bit count (0 = adaptive).
    hash_bits: u32 = 0,
    /// Minimum match length override (0 = auto-derive from level + text
    /// detection). Values below 4 are ignored. Matches
    /// `CompressOptions.MinMatchLength`.
    min_match_length: u32 = 0,
    /// Maximum backward reference distance. 0 = `default_dictionary_size`.
    /// Matches `CompressOptions.DictionarySize`.
    dictionary_size: u32 = 0,
    /// Maximum local dictionary size for self-contained mode. 0 = default
    /// (4 MB). Matches `CompressOptions.MaxLocalDictionarySize`.
    max_local_dictionary_size: u32 = 0,
    /// Seek chunk length for seekable compression (0 = off). Matches
    /// `CompressOptions.SeekChunkLen`.
    seek_chunk_len: u32 = 0,
    /// Number of bytes between seek-point resets (0 = off). Matches
    /// `CompressOptions.SeekChunkReset`.
    seek_chunk_reset: u32 = 0,
    /// Space-speed tradeoff parameter in bytes. 0 = default (256). Matches
    /// `CompressOptions.SpaceSpeedTradeoffBytes`.
    space_speed_tradeoff_bytes: u32 = 0,
    /// Whether to generate 3-byte CRC24 chunk-header checksums. Matches
    /// `CompressOptions.GenerateChunkHeaderChecksum`. CRC24 algorithm is
    /// not yet implemented on either side — flag parsed, not acted on.
    generate_chunk_header_checksum: bool = false,
    /// Whether each frame block is self-contained (enables parallel
    /// decompression). Matches `CompressOptions.SelfContained`. When set,
    /// the encoder also appends a per-chunk first-8-byte prefix table.
    self_contained: bool = false,
    /// Whether to use two-phase compression (self-contained + cross-chunk
    /// patches). Matches `CompressOptions.TwoPhase`. When set, also forces
    /// `self_contained = true`.
    two_phase: bool = false,

    // ── Decode-cost penalty knobs ────────────────────────────────────────
    // These bias the optimal parser toward cheaper-to-decode matches.
    // Only exercised by the High codec (L6+); Fast L1-L5 ignores them.

    /// Per-token fixed decode overhead penalty (32nds of a bit).
    decode_cost_per_token: u32 = 0,
    /// Penalty for matches with offset < 16 (byte-at-a-time copy). Applied
    /// per match byte. In 32nds of a bit.
    decode_cost_small_offset: u32 = 0,
    /// Penalty for very short matches (length 2-3). In 32nds of a bit.
    decode_cost_short_match: u32 = 0,

    /// Worker thread count for parallel compress. `0` = auto (one per
    /// CPU core, capped by the memory-aware heuristic from step 40).
    /// `1` forces the serial path.
    num_threads: u32 = 0,

    /// v2: emit a parallel-decode sidecar block alongside the Fast
    /// L1-L4 compressed data so new-format decoders can run phase-1
    /// cross-chunk resolution before spawning phase-2 worker threads.
    /// Defaults to on for Fast levels; ignored for High/Turbo paths.
    /// The sidecar is ~0.3-1% of compressed size and has no impact on
    /// compression ratio of the main payload.
    emit_parallel_decode_metadata: bool = true,
};

/// Resolved per-input parameters derived from `Options` + heuristics.
const ResolvedParams = struct {
    engine_level: i32,
    use_entropy: bool,
    hash_bits: u6,
    /// Passed to `FastMatchHasher.init` as the hash `k` parameter. Applies
    /// the text-detector bump here (6 for text, 4 otherwise). This affects
    /// the Fibonacci hash multiplier, NOT the parser's acceptance threshold.
    hasher_min_match_length: u32,
    /// Passed to the parser's `buildMinimumMatchLengthTable` and is the
    /// acceptance threshold for match lengths. `FastParser.CompressGreedy`
    /// reads this from `opts.MinMatchLength` (default 0 → floor 4), so the
    /// text bump DOES NOT apply.
    parser_min_match_length: u32,
    dict_size: u32,
};

fn resolveParams(src: []const u8, opts: Options) ResolvedParams {
    const mapped = fast_constants.mapLevel(opts.level);
    const eng = mapped.engine_level;

    // SetupEncoder computes a LOCAL minimumMatchLength that
    // starts at 4 and is bumped to 6 for text inputs. That local is passed to
    // `CreateFastHasher<T>.AllocateHash(hashBits, minimumMatchLength)` to pick
    // the Fibonacci hash multiplier (k=6 shifts differently than k=4).
    var hasher_k: u32 = if (opts.min_match_length >= 4) opts.min_match_length else 4;
    if (opts.min_match_length == 0 and src.len > 0x4000 and eng >= -2 and eng <= 3) {
        if (text_detector.isProbablyText(src)) {
            hasher_k = 6;
        }
    }

    // FastParser.CompressGreedy computes `minimumMatchLength`
    // FRESHLY from `Math.Max(opts.MinMatchLength, 4)` and passes THIS value
    // to `BuildMinimumMatchLengthTable`. The text-detector bump is NOT
    // applied to the parser's acceptance threshold, only to the hasher's
    // hash-multiplier. So the parser accepts 4-byte matches at low offsets
    // even on text input, which the hasher's higher k hints it was built for.
    const parser_min_ml: u32 = if (opts.min_match_length >= 4) opts.min_match_length else 4;

    const bits = fast_constants.getHashBits(
        src.len,
        @max(eng, 2),
        opts.hash_bits,
        16,
        20,
        17,
        24,
    );

    const dict: u32 = if (opts.dictionary_size != 0) opts.dictionary_size else default_dictionary_size;

    return .{
        .engine_level = eng,
        .use_entropy = mapped.use_entropy_coding,
        .hash_bits = bits,
        .hasher_min_match_length = hasher_k,
        .parser_min_match_length = parser_min_ml,
        .dict_size = dict,
    };
}

const areAllBytesEqual = block_header.areAllBytesEqual;

/// Returns the entropy option mask for a given user-level:
///   raw-coded levels (L1, L2) -> SupportsShortMemset only
///   lazy entropy levels (L5 only, engine 4) -> full mask minus MultiArrayAdvanced
///   greedy entropy levels (L3, L4, engines 1, 2) -> full mask minus
///     MultiArrayAdvanced AND minus TANS AND minus MultiArray
///     AND minus RLE/RLEEntropy
fn entropyOptionsForLevel(user_level: u8) EntropyOptions {
    const mapped = fast_constants.mapLevel(user_level);
    if (!mapped.use_entropy_coding) {
        // Raw-coded mode: `coder.EntropyOptions = (int)EntropyOptions.SupportsShortMemset;`
        return .{ .supports_short_memset = true };
    }
    const eng = mapped.engine_level;
    // Entropy-coded mode. Start with 0xff and clear selected flags.
    if (eng >= 5) {
        // level >= 5 branch: clear MultiArrayAdvanced only.
        return .{
            .allow_tans = true,
            .allow_rle_entropy = true,
            .allow_double_huffman = true,
            .allow_rle = true,
            .allow_multi_array = true,
            .supports_new_huffman = true,
            .supports_short_memset = true,
        };
    }
    // Engine level < 5: clear MultiArrayAdvanced, TANS, MultiArray.
    var opts: EntropyOptions = .{
        .allow_rle_entropy = true,
        .allow_double_huffman = true,
        .allow_rle = true,
        .supports_new_huffman = true,
        .supports_short_memset = true,
    };
    // Engine levels in {1, 2} → greedy/greedy-rehash parser branch at
    // Additionally clear AllowRLE | AllowRLEEntropy.
    // Engine level 4 (user L5) → `level == 4` branch keeps RLE bits.
    if (eng != 3 and eng != 4) {
        opts.allow_rle = false;
        opts.allow_rle_entropy = false;
    }
    return opts;
}

/// Worst-case bound on the compressed size given `src_len`.
pub fn compressBound(src_len: usize) usize {
    // Generous bound that accounts for frame/block/chunk/sub-chunk headers
    // plus encoder slack (the per-sub-chunk `encodeSubChunkRaw` needs 256
    // bytes of headroom past the literal stream for the token/off16/off32
    // headers). The worst-case incompressible path stores source verbatim
    // so the output is strictly ≤ src_len + small fixed overhead.
    //
    // Includes the SC prefix table upper bound (8 bytes per chunk after
    // the first) so the bound is valid regardless of `opts.self_contained`.
    const chunk_count: usize = (src_len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
    const sub_chunks: usize = (src_len + fast_constants.sub_chunk_size - 1) / fast_constants.sub_chunk_size;
    const per_sub_chunk_overhead: usize = 3 + 8 + 3 + 256; // sub hdr + initial 8 + lit hdr + assembly slack
    const sc_prefix_upper_bound: usize = chunk_count * 8; // (n-1)*8 ≤ n*8
    // v2 parallel-decode sidecar: 8-byte outer block header + body.
    // Body size is bounded by cross-chunk literal bytes + match ops;
    // observed worst case is ~1.2% of decompressed size (L5 enwik8).
    // Use 3% as conservative headroom.
    const sidecar_headroom: usize = 8 + src_len / 32;
    return frame.max_header_size + 4 + chunk_count * (8 + 2 + 4) + sub_chunks * per_sub_chunk_overhead + src_len + 64 + sc_prefix_upper_bound + sidecar_headroom;
}

/// Compress `src` into `dst` as an SLZ1 byte stream. Returns the
/// number of bytes written to `dst`. `dst` must be at least
/// `compressBound(src.len)`.
///
/// On `error.OutOfMemory` from the single-shot path, automatically
/// splits the input into smaller SELF-CONTAINED pieces and retries
/// through a fallback size ladder (1 GB → 512 MB → 256 MB → 128 MB
/// -> 64 MB -> 32 MB -> 16 MB). Each piece is written as its own
/// complete SLZ1 frame; the decompressor iterates pieces in its
/// `DecompressCore` loop.
pub fn compressFramed(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    if (opts.level < 1 or opts.level > 11) return error.BadLevel;
    if (opts.hash_bits != 0 and (opts.hash_bits < 8 or opts.hash_bits > 24)) return error.BadLevel;
    const min_dst = compressBound(src.len);
    if (dst.len < min_dst) return error.DestinationTooSmall;

    // Fast path: attempt the whole input in a single piece.
    const whole = compressFramedOne(allocator, src, dst, opts);
    if (whole) |n| return n else |err| switch (err) {
        error.OutOfMemory => {
            // Fall through to multi-piece retry below.
        },
        else => return err,
    }

    // Multi-piece retry ladder. Each size is a multiple of chunk_size
    // (256 KB) so piece outputs concatenate into a valid byte stream.
    const min_piece_size: usize = 16 * 1024 * 1024;
    const fallback_ladder = [_]usize{
        1 * 1024 * 1024 * 1024, // 1 GB
        512 * 1024 * 1024,
        256 * 1024 * 1024,
        128 * 1024 * 1024,
        64 * 1024 * 1024,
        32 * 1024 * 1024,
        min_piece_size,
    };

    var piece_size: usize = std.math.maxInt(usize);
    while (true) {
        // Pick the next smaller piece size.
        var next: usize = 0;
        for (fallback_ladder) |candidate| {
            if (candidate < piece_size and candidate < src.len) {
                next = candidate;
                break;
            }
        }
        if (next == 0) return error.OutOfMemory;
        piece_size = next;

        // Compress each piece as its own self-contained SLZ1 frame.
        var piece_opts = opts;
        piece_opts.self_contained = true;

        var total: usize = 0;
        var off: usize = 0;
        var piece_ok = true;
        while (off < src.len) {
            const remaining = src.len - off;
            const this_piece_len = @min(piece_size, remaining);
            const piece_src = src[off..][0..this_piece_len];
            const piece_dst = dst[total..];
            const piece_bound = compressBound(this_piece_len);
            if (piece_dst.len < piece_bound) return error.DestinationTooSmall;
            const piece_n = compressFramedOne(allocator, piece_src, piece_dst, piece_opts) catch |err| switch (err) {
                error.OutOfMemory => {
                    piece_ok = false;
                    break;
                },
                else => return err,
            };
            total += piece_n;
            off += this_piece_len;
        }
        if (piece_ok) return total;
        // Else: loop and try a smaller piece size.
    }
}

/// Single-piece compress — the original `compressFramed` body. The
/// public wrapper above handles the multi-piece OOM retry ladder.
fn compressFramedOne(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    // Levels 6-11 use the High codec (optimal parser + hash-based /
    // BT4 match finder). Fork here so the Fast path below stays
    // byte-exact for L1-L5.
    if (opts.level >= 6) {
        return compressFramedHigh(allocator, src, dst, opts);
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
//  High codec (levels 6-11)
// ────────────────────────────────────────────────────────────

const high_compressor = @import("high_compressor.zig");
const high_encoder = @import("high_encoder.zig");
const match_finder = @import("match_finder.zig");
const match_finder_bt4 = @import("match_finder_bt4.zig");
const mls_mod = @import("managed_match_len_storage.zig");

/// Unified-to-codec-level mapping for the High codec path. Mirrors
/// Map unified levels 6-11 to High-codec encoder parameters.
const HighMapping = struct {
    codec_level: i32,
    self_contained: bool,
    use_bt4: bool,
};

fn mapHighLevel(user_level: u8) HighMapping {
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
fn compressFramedHigh(
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
        break :blk calculateMaxThreads(src.len, opts.level);
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
        const written = try compressInternalParallelSc(
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
        const written = try compressBlocksParallel(
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
        const local_dict_size: usize = 64 * 1024 * 1024;

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
fn compressOneFrameBlockWindowed(
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
fn emitScPrefixTable(src: []const u8, dst: []u8, pos_ptr: *usize) CompressError!void {
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
fn finalizeSingleFrameBlock(
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
fn compressOneHighBlock(
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

        const src_off = block_idx * lz_constants.chunk_size;
        const block_src_len = @min(shared.src.len - src_off, lz_constants.chunk_size);
        const keyframe = shared.self_contained or src_off == 0;

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

fn compressBlocksParallel(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst_tail: []u8,
    ctx: *const high_encoder.HighEncoderContext,
    mls: *const mls_mod.ManagedMatchLenStorage,
    sc_flag_bit: u8,
    self_contained: bool,
    num_threads: u32,
) CompressError!usize {
    const num_blocks: usize = (src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
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
        const src_off = i * lz_constants.chunk_size;
        const block_src_len = @min(src.len - src_off, lz_constants.chunk_size);
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

        const group_src_off = first_chunk * lz_constants.chunk_size;
        const group_src_end = @min(group_src_off + chunks_in_group * lz_constants.chunk_size, shared.src.len);
        const group_src = shared.src[group_src_off..group_src_end];

        // Reset arena once per group so the per-group MLS alloc +
        // match-finder working set are released before the next group.
        _ = arena.reset(.retain_capacity);

        // Per-group match finder → MLS rooted at group-relative
        // positions. This enforces the SC "no cross-group refs"
        // invariant by construction — matches discovered against
        // `group_src` can only reach other bytes inside the same
        // `group_src` slice.
        var mls = mls_mod.ManagedMatchLenStorage.init(arena.allocator(), group_src.len + 1, 8.0) catch {
            _ = shared.error_flag.store(1, .monotonic);
            _ = shared.captured_err.cmpxchgStrong(0, @intFromError(error.OutOfMemory), .monotonic, .monotonic);
            return;
        };
        // No `mls.deinit()` — arena owns the allocation.
        mls.window_base_offset = 0;
        mls.round_start_pos = 0;

        const mf_ok = blk: {
            if (shared.mapping.use_bt4) {
                match_finder_bt4.findMatchesBT4(arena.allocator(), group_src, &mls, 4, 0, 96) catch |err| {
                    const code: u16 = @intFromError(err);
                    _ = shared.captured_err.cmpxchgStrong(0, code, .monotonic, .monotonic);
                    break :blk false;
                };
            } else {
                match_finder.findMatchesHashBased(arena.allocator(), group_src, &mls, 4, 0) catch |err| {
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

        // Compress each chunk in the group sequentially. The shared
        // source slice view lets `compressOneHighBlock` compute offsets
        // into `group_src` via `(src_off + sub_off) % sc_group_bytes`,
        // but because we're passing `group_src` (not `shared.src`) as
        // the source buffer, the % reduces to `src_off + sub_off`
        // within the group — same effect.
        var ci: usize = 0;
        while (ci < chunks_in_group) : (ci += 1) {
            const chunk_idx = first_chunk + ci;
            const in_group_src_off = ci * lz_constants.chunk_size;
            const block_src_len = @min(group_src.len - in_group_src_off, lz_constants.chunk_size);
            // Only the first chunk in each group is a keyframe — matches
            //
            // The block header keyframe bit (0x40) is part of the 2-byte
            // header so getting this wrong shifts every block's bytes.
            const keyframe = (ci == 0);

            const n_or_err = compressOneHighBlock(
                &worker_ctx,
                &hasher,
                &mls,
                group_src,
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

fn compressInternalParallelSc(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst_tail: []u8,
    ctx: *const high_encoder.HighEncoderContext,
    mapping: HighMapping,
    sc_flag_bit: u8,
    num_threads: u32,
) CompressError!usize {
    const num_chunks: usize = (src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
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
        const src_off = i * lz_constants.chunk_size;
        const block_src_len = @min(src.len - src_off, lz_constants.chunk_size);
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

test "compressFramedHigh L6 roundtrip: tiny input (uncompressed fallback)" {
    const src = "Hello, world!\n";
    try roundtrip(src, 6);
}

test "compressFramedHigh L9 roundtrip: incompressible input (raw fallback)" {
    var src: [4096]u8 = undefined;
    var rng = std.Random.Xoshiro256.init(0xDEADBEEF);
    rng.random().bytes(&src);
    try roundtrip(&src, 9);
}

test "compressFramedHigh L9 roundtrip: 4 KB repeating pattern" {
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 9);
}

test "compressFramedHigh L9 roundtrip: 8 KB English-ish" {
    var src: [8192]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 9);
}

test "compressFramedHigh L11 roundtrip: 8 KB English-ish (BT4 path)" {
    var src: [8192]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 11);
}

test "compressFramedHigh L6 roundtrip: 64 KB repeating pattern" {
    var src: [65536]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 6);
}

test "compressFramedHigh L9 roundtrip: 64 KB repeating pattern" {
    var src: [65536]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 9);
}

test "compressFramedHigh L11 roundtrip: 128 KB highly repetitive" {
    var src: [128 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 16);
    try roundtrip(&src, 11);
}

test "compressFramedHigh L9 roundtrip: 100 KB English-ish (fits 1 sub-chunk)" {
    var src: [100 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 9);
}

test "compressFramedHigh L9 roundtrip: 192 KB English-ish (spans 2 sub-chunks)" {
    var src: [192 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 9);
}

test "compressFramedHigh L11 roundtrip: 192 KB English-ish (BT4, 2 sub-chunks)" {
    var src: [192 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 11);
}

test "compressFramedHigh L6 roundtrip: 8 KB English-ish (SC path)" {
    var src: [8192]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 6);
}

test "compressFramedHigh L7 roundtrip: 64 KB repeating pattern (SC path)" {
    var src: [65536]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 7);
}

test "compressFramedHigh L8 roundtrip: 64 KB repeating pattern (SC + BT4)" {
    var src: [65536]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 8);
}

test "compressFramedHigh L6 roundtrip: 384 KB English-ish (SC, 2 chunks)" {
    // 384 KB = 1.5 * chunk_size → two SC chunks with a prefix table entry.
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtrip(&src, 6);
}

test "compressFramedHigh L9 roundtrip: 256 KB repeating (1 full chunk)" {
    var src: [256 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtrip(&src, 9);
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

// ────────────────────────────────────────────────────────────
//  Edge cases (Phase 10l)
// ────────────────────────────────────────────────────────────

/// Roundtrip helper that runs one `source` through every supported level
/// (1..5) and verifies byte-exact decompression.
fn roundtripAllLevels(source: []const u8) !void {
    var lvl: u8 = 1;
    while (lvl <= 5) : (lvl += 1) {
        try roundtrip(source, lvl);
    }
}

test "edge: single byte" {
    const src = [_]u8{'Z'};
    try roundtripAllLevels(&src);
}

test "edge: empty input" {
    const src: []const u8 = &[_]u8{};
    try roundtripAllLevels(src);
}

test "edge: all zeros, 128 KB (single sub-chunk exact)" {
    const src: [128 * 1024]u8 = @splat(0);
    try roundtripAllLevels(&src);
}

test "edge: all same byte (0xFF), 2 MB" {
    const src: [2 * 1024 * 1024]u8 = @splat(0xFF);
    try roundtripAllLevels(&src);
}

// ────────────────────────────────────────────────────────────
//  Self-contained mode roundtrips (step 10, gap D1)
// ────────────────────────────────────────────────────────────

/// SC-mode roundtrip helper that compresses with `self_contained = true`
/// and decompresses via the standard framed decoder (which already handles
/// the tail prefix restoration for SC streams).
fn roundtripSC(source: []const u8, level: u8) !void {
    const allocator = testing.allocator;
    const bound = compressBound(source.len);
    const dst = try allocator.alloc(u8, bound);
    defer allocator.free(dst);

    const n = try compressFramed(allocator, source, dst, .{ .level = level, .self_contained = true });
    try testing.expect(n > 0);
    try testing.expect(n <= bound);

    const decoded = try allocator.alloc(u8, source.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(dst[0..n], decoded);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, source, decoded[0..written]);
}

test "SC: 64 KB repeating roundtrips via decompressFramed" {
    var src: [65536]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripSC(&src, 1);
}

test "SC: 256 KB single-chunk still roundtrips with SC flag set" {
    var src: [256 * 1024]u8 = undefined;
    const p = "ABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripSC(&src, 1);
}

test "SC: 1 MB (4 chunks) roundtrips with prefix table" {
    // 4 × 256 KB — exercises the multi-chunk SC path with a full prefix
    // table of (4 - 1) * 8 = 24 bytes at the end of the frame block.
    var src: [1024 * 1024]u8 = undefined;
    const p = "ABCDEFGH";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripSC(&src, 1);
}

test "SC: 768 KB (3 chunks) pseudo-varied text roundtrips" {
    var src: [768 * 1024]u8 = undefined;
    var state: u32 = 0xBEEF1234;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        state = state *% 1103515245 +% 12345;
        // Bias toward printable ASCII to give the parser something to compress.
        src[i] = @intCast(0x20 + (state >> 16) % 95);
    }
    try roundtripSC(&src, 1);
}

test "SC: block header has bit 4 set in first internal header" {
    var src: [1024 * 1024]u8 = undefined;
    const p = "DEADBEEF";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];

    const allocator = testing.allocator;
    const bound = compressBound(src.len);
    const out = try allocator.alloc(u8, bound);
    defer allocator.free(out);
    const n = try compressFramed(allocator, &src, out, .{ .level = 1, .self_contained = true });
    _ = n;

    // Peek the first internal block header just past the frame header + 8 outer block bytes.
    const hdr = try frame.parseHeader(out);
    const block_hdr_pos = hdr.header_size + 8;
    const byte0 = out[block_hdr_pos];
    // magic nibble 0x5, self_contained bit 4 set, keyframe bit 6 also set.
    try testing.expectEqual(@as(u8, 0x05), byte0 & 0x0F); // magic
    try testing.expect((byte0 & 0x10) != 0); // self_contained
    try testing.expect((byte0 & 0x40) != 0); // keyframe
}

test "TwoPhase: implies self_contained and sets block header bits 4 + 5" {
    var src: [768 * 1024]u8 = undefined;
    const p = "DEADBEEFCAFEBABE";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];

    const allocator = testing.allocator;
    const bound = compressBound(src.len);
    const out = try allocator.alloc(u8, bound);
    defer allocator.free(out);
    const n = try compressFramed(allocator, &src, out, .{ .level = 1, .two_phase = true });

    const hdr = try frame.parseHeader(out);
    const block_hdr_pos = hdr.header_size + 8;
    const byte0 = out[block_hdr_pos];
    try testing.expectEqual(@as(u8, 0x05), byte0 & 0x0F); // magic
    try testing.expect((byte0 & 0x10) != 0); // self_contained
    try testing.expect((byte0 & 0x20) != 0); // two_phase
    try testing.expect((byte0 & 0x40) != 0); // keyframe

    // Roundtrip via the standard decoder.
    const decoded = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(out[0..n], decoded);
    try testing.expectEqual(src.len, written);
    try testing.expectEqualSlices(u8, &src, decoded[0..written]);
}

test "SC: all levels roundtrip 1 MB" {
    var src: [1024 * 1024]u8 = undefined;
    var state: u32 = 0xC0FFEE42;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        state = state *% 1664525 +% 1013904223;
        src[i] = @intCast(0x20 + (state >> 16) % 95);
    }
    var lvl: u8 = 1;
    while (lvl <= 5) : (lvl += 1) {
        try roundtripSC(&src, lvl);
    }
}

test "edge: input exactly 128 KB (one sub-chunk, no block2)" {
    var src: [128 * 1024]u8 = undefined;
    var state: u32 = 0xBEEF;
    for (&src) |*b| {
        state = state *% 1664525 +% 1013904223;
        b.* = @intCast((state >> 24) & 0xFF);
    }
    try roundtripAllLevels(&src);
}

test "edge: input exactly 128 KB + 1 (straddles sub-chunk boundary by 1 byte)" {
    var src: [128 * 1024 + 1]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('a' + (i % 7));
    try roundtripAllLevels(&src);
}

test "edge: input exactly 256 KB (one outer chunk, two full sub-chunks)" {
    var src: [256 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripAllLevels(&src);
}

test "edge: input exactly 256 KB + 1 (straddles outer chunk boundary)" {
    var src: [256 * 1024 + 1]u8 = undefined;
    const p = "abcdefghij";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripAllLevels(&src);
}

test "edge: random incompressible 64 KB (bail path)" {
    var src: [64 * 1024]u8 = undefined;
    var state: u32 = 0xCAFEBABE;
    for (&src) |*b| {
        state = state *% 2654435761 +% 0x9E3779B1;
        b.* = @intCast((state >> 16) & 0xFF);
    }
    try roundtripAllLevels(&src);
}

test "edge: 1 MB alternating 64-byte runs of A and B" {
    var src: [1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = if ((i / 64) & 1 == 0) @as(u8, 'A') else @as(u8, 'B');
    try roundtripAllLevels(&src);
}

test "edge: 300 KB (chunk boundary at 256 KB + tail < sub-chunk)" {
    var src: [300 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 131 + 7) & 0xFF);
    try roundtripAllLevels(&src);
}

test "edge: 520 KB (three outer chunks: 256 KB + 256 KB + 8 KB tail)" {
    var src: [520 * 1024]u8 = undefined;
    const p = "The persistence test pattern repeats. 1234567890 abcdefg ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripAllLevels(&src);
}

// ────────────────────────────────────────────────────────────
//  Phase 14 step 37 — CompressBlocksParallel tests
// ────────────────────────────────────────────────────────────

/// Roundtrip helper that forces the parallel block path via
/// `num_threads > 1` and verifies byte-exact decompression.
fn roundtripParallel(source: []const u8, level: u8, num_threads: u32) !void {
    const allocator = testing.allocator;
    const bound = compressBound(source.len);
    const dst = try allocator.alloc(u8, bound);
    defer allocator.free(dst);

    const n = try compressFramed(allocator, source, dst, .{
        .level = level,
        .num_threads = num_threads,
    });
    try testing.expect(n > 0);
    try testing.expect(n <= bound);

    const decoded = try allocator.alloc(u8, source.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(dst[0..n], decoded);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, source, decoded[0..written]);
}

test "compressBlocksParallel: L9 384 KB non-SC 2 threads (2 blocks)" {
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripParallel(&src, 9, 2);
}

test "compressBlocksParallel: L9 512 KB non-SC 2 threads (2 blocks)" {
    var src: [512 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtripParallel(&src, 9, 2);
}

test "compressBlocksParallel: L11 768 KB non-SC 4 threads (3 blocks, BT4)" {
    var src: [768 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtripParallel(&src, 11, 4);
}

test "compressBlocksParallel: single-thread override matches serial (L9 384 KB)" {
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripParallel(&src, 9, 1);
}

// ────────────────────────────────────────────────────────────
//  Phase 14 step 38 — CompressInternalParallelSC tests
// ────────────────────────────────────────────────────────────

test "compressInternalParallelSc: L6 2 MB (2 SC groups, 2 threads)" {
    // 2 MB = 8 chunks = 2 full SC groups. Each worker runs its own
    // per-group match finder and compresses the group's 4 chunks
    // sequentially with group-relative offsets.
    var src: [2 * 1024 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripParallel(&src, 6, 2);
}

test "compressInternalParallelSc: L7 1 MB (1 SC group, 1 worker)" {
    // 1 MB = 4 chunks = 1 full SC group. Worker-count resolves to
    // 1 because num_groups = 1, so this exercises the single-worker
    // fast path inside the SC parallel dispatch.
    var src: [1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtripParallel(&src, 7, 4);
}

test "compressInternalParallelSc: L8 2 MB (SC + BT4, 2 groups, 2 threads)" {
    // L8 → BT4 match finder (codec_level=9). Verifies the per-worker
    // BT4 path gives the same byte-exact output that the serial path
    // would via the serial decoder.
    var src: [2 * 1024 * 1024]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try roundtripParallel(&src, 8, 2);
}

test "compressInternalParallelSc: L6 384 KB (partial last group)" {
    // 384 KB = 1.5 chunks = 2 chunks → 1 group with only 2 chunks.
    // Exercises the chunks_in_group < group_size tail path.
    var src: [384 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];
    try roundtripParallel(&src, 6, 2);
}

// ────────────────────────────────────────────────────────────
//  Phase 14 step 39 — multi-piece concatenated frame tests
// ────────────────────────────────────────────────────────────

test "decompressFramed: decoder accepts 2 concatenated SLZ1 frames" {
    // Triggering the OOM retry path reliably requires an input
    // bigger than the 1 GB top of the fallback ladder, which is
    // impractical in unit tests. Instead we verify the structural
    // piece: if you concatenate two fully-framed compressed outputs,
    // the decoder's multi-piece loop decodes them into one
    // contiguous destination byte-exact. This is the wire-format
    // contract the retry path produces.
    const allocator = testing.allocator;

    var src: [64 * 1024]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];

    const half = src.len / 2;
    const piece0_bound = compressBound(half);
    const piece1_bound = compressBound(src.len - half);
    const tmp = try allocator.alloc(u8, piece0_bound + piece1_bound);
    defer allocator.free(tmp);

    const n0 = try compressFramedOne(allocator, src[0..half], tmp, .{
        .level = 1,
        .self_contained = true,
    });
    const n1 = try compressFramedOne(allocator, src[half..], tmp[n0..], .{
        .level = 1,
        .self_contained = true,
    });
    const total = n0 + n1;

    const decoded = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(tmp[0..total], decoded);
    try testing.expectEqual(src.len, written);
    try testing.expectEqualSlices(u8, &src, decoded[0..written]);
}

test "decompressFramed: multi-piece concatenation across L6 + L9 codecs" {
    // Mix an L6 (SC High) piece and an L9 (non-SC High) piece.
    // Verifies the decoder can switch codecs mid-stream since each
    // piece carries its own frame header.
    const allocator = testing.allocator;

    var src: [64 * 1024]u8 = undefined;
    const p = "The persistent test pattern iterates reliably. ";
    var i: usize = 0;
    while (i < src.len) : (i += 1) src[i] = p[i % p.len];

    const half = src.len / 2;
    const piece0_bound = compressBound(half);
    const piece1_bound = compressBound(src.len - half);
    const tmp = try allocator.alloc(u8, piece0_bound + piece1_bound);
    defer allocator.free(tmp);

    const n0 = try compressFramedOne(allocator, src[0..half], tmp, .{ .level = 6 });
    const n1 = try compressFramedOne(allocator, src[half..], tmp[n0..], .{ .level = 9 });
    const total = n0 + n1;

    const decoded = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(tmp[0..total], decoded);
    try testing.expectEqual(src.len, written);
    try testing.expectEqualSlices(u8, &src, decoded[0..written]);
}

