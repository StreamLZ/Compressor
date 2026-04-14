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
const match_hasher = @import("match_hasher.zig");
const fast_enc = @import("fast_lz_encoder.zig");
const entropy_enc = @import("entropy_encoder.zig");
const text_detector = @import("text_detector.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const EntropyOptions = entropy_enc.EntropyOptions;

const MatchHasher2x = match_hasher.MatchHasher2x;
const MatchHasher2 = match_hasher.MatchHasher2;

/// Default dictionary size when the caller doesn't override. Matches C#
/// `FastConstants.DefaultDictionarySize = 0x40000000` (1 GB).
pub const default_dictionary_size: u32 = 0x40000000;

pub const CompressError = error{
    BadLevel,
    BadBlockSize,
    DestinationTooSmall,
    HashBitsOutOfRange,
} || std.mem.Allocator.Error || fast_enc.EncodeError;

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
    // Ported from `src/StreamLZ/Compression/CompressOptions.cs`. Most of
    // these are plumbed here for API symmetry; the behavioral wiring lands
    // with subsequent parity steps (see the punch list in memory).

    /// Override the hash-table bit count (0 = adaptive). Matches
    /// `CompressOptions.HashBits` in C#.
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
};

/// Resolved per-input parameters derived from `Options` + heuristics.
const ResolvedParams = struct {
    engine_level: i32,
    use_entropy: bool,
    hash_bits: u6,
    /// Passed to `FastMatchHasher.init` as the hash `k` parameter. C# applies
    /// the text-detector bump here (6 for text, 4 otherwise). This affects
    /// the Fibonacci hash multiplier, NOT the parser's acceptance threshold.
    hasher_min_match_length: u32,
    /// Passed to the parser's `buildMinimumMatchLengthTable` and is the
    /// acceptance threshold for match lengths. C# `FastParser.CompressGreedy`
    /// reads this from `opts.MinMatchLength` (default 0 → floor 4), so the
    /// text bump DOES NOT apply. Diverging these matches C# behaviour.
    parser_min_match_length: u32,
    dict_size: u32,
};

fn resolveParams(src: []const u8, opts: Options) ResolvedParams {
    const mapped = fast_constants.mapLevel(opts.level);
    const eng = mapped.engine_level;

    // C# Fast.Compressor.SetupEncoder computes a LOCAL minimumMatchLength that
    // starts at 4 and is bumped to 6 for text inputs. That local is passed to
    // `CreateFastHasher<T>.AllocateHash(hashBits, minimumMatchLength)` to pick
    // the Fibonacci hash multiplier (k=6 shifts differently than k=4).
    var hasher_k: u32 = if (opts.min_match_length >= 4) opts.min_match_length else 4;
    if (opts.min_match_length == 0 and src.len > 0x4000 and eng >= -2 and eng <= 3) {
        if (text_detector.isProbablyText(src)) {
            hasher_k = 6;
        }
    }

    // C# FastParser.CompressGreedy (line 375) computes `minimumMatchLength`
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

/// Direct port of C# BlockHeaderWriter.AreAllBytesEqual. Returns true when
/// every byte in `data` is identical (or when len ≤ 1).
inline fn areAllBytesEqual(data: []const u8) bool {
    if (data.len <= 1) return true;
    const first = data[0];
    for (data[1..]) |b| {
        if (b != first) return false;
    }
    return true;
}

/// Returns the entropy option mask for a given user-level. Mirrors
/// C# Fast.Compressor.SetupEncoder exactly:
///   raw-coded levels (L1, L2) → SupportsShortMemset only
///   lazy entropy levels (L5 only — engine 4) → full mask minus MultiArrayAdvanced
///   greedy entropy levels (L3, L4 — engines 1, 2) → full mask minus MultiArrayAdvanced
///     AND minus TANS AND minus MultiArray
///     AND minus RLE/RLEEntropy (greedy path clears RLE bits at line 233)
fn entropyOptionsForLevel(user_level: u8) EntropyOptions {
    const mapped = fast_constants.mapLevel(user_level);
    if (!mapped.use_entropy_coding) {
        // Raw-coded mode: `coder.EntropyOptions = (int)EntropyOptions.SupportsShortMemset;`
        return .{ .supports_short_memset = true };
    }
    const eng = mapped.engine_level;
    // Entropy-coded mode. C# starts with 0xff and clears selected flags.
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
    // C# line 213, which additionally clears AllowRLE | AllowRLEEntropy.
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
    return frame.max_header_size + 4 + chunk_count * (8 + 2 + 4) + sub_chunks * per_sub_chunk_overhead + src_len + 64 + sc_prefix_upper_bound;
}

/// Compress `src` into `dst` as a full SLZ1 frame. Returns the number of
/// bytes written to `dst`. `dst` must be at least `compressBound(src.len)`.
pub fn compressFramed(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    if (opts.level < 1 or opts.level > 11) return error.BadLevel;
    const min_dst = compressBound(src.len);
    if (dst.len < min_dst) return error.DestinationTooSmall;

    // Levels 6-11 use the High codec (optimal parser + hash-based /
    // BT4 match finder). Fork here so the Fast path below stays
    // byte-exact with C# for L1-L5.
    if (opts.level >= 6) {
        return compressFramedHigh(allocator, src, dst, opts);
    }

    // ── Frame header ────────────────────────────────────────────────────
    //
    // C# StreamLZ.MapLevel (StreamLZ.cs:90) maps unified level (1-11) to
    // (codec, codecLevel). For Fast levels 1-5 the mapping is 1→1, 2→2,
    // 3→3, 4→5 (Fast 4 is skipped), 5→6. The STORED level in the frame
    // header is the codec-level, not the unified level. Replicate that so
    // the written byte matches C# exactly.
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
    // Per-level engine hash-bit caps to match C# Fast.Compressor.SetupEncoder
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
    // Matches C# `Fast.Compressor.SetupEncoder`:
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
            greedy_hasher_u16 = try FastMatchHasher(u16).init(allocator, .{
                .hash_bits = greedy_hash_bits,
                .min_match_length = resolved.hasher_min_match_length,
            });
        },
        5 => {
            // Fast 6 (engine 4): lazy chain hasher with lazy-2 evaluation.
            chain_hasher = try MatchHasher2.init(allocator, resolved.hash_bits);
        },
        else => {
            // Fast 2 (engine -1), Fast 3 (engine 1), Fast 5 (engine 2).
            greedy_hasher_u32 = try FastMatchHasher(u32).init(allocator, .{
                .hash_bits = greedy_hash_bits,
                .min_match_length = resolved.hasher_min_match_length,
            });
        },
    }

    const speed_tradeoff = cost_coeffs.speedTradeoffFor(
        cost_coeffs.default_space_speed_tradeoff_bytes,
        resolved.use_entropy,
    );
    const parser_config: fast_enc.ParserConfig = .{
        // Parser mmlt uses the UN-bumped value (C# reads opts.MinMatchLength
        // in FastParser.CompressGreedy regardless of the text bump).
        .minimum_match_length = resolved.parser_min_match_length,
        .dictionary_size = resolved.dict_size,
        .speed_tradeoff = speed_tradeoff,
    };

    // Reset all hashers ONCE at the top of compressFramed, matching C#
    // `SetupEncoder` → `CreateFastHasher<T>.AllocateHash` which clears the
    // table once per CompressBlock_Fast call and then never re-clears.
    //
    // The greedy parser uses the hash table with positions stored in
    // WHOLE-INPUT coordinates (measured from src.ptr). Stale entries from
    // sub-chunk N−1 read during sub-chunk N give huge offsets that fail
    // the `offset <= cursor - source_block_base` bound check — same as C#.
    if (greedy_hasher_u16) |*h| h.reset();
    if (greedy_hasher_u32) |*h| h.reset();
    if (chain_hasher) |*h| {
        h.reset();
        h.setSrcBase(src.ptr);
        h.setBaseWithoutPreload(0);
    }

    // ── ONE frame block wraps all internal 256 KB chunks ───────────────
    // Empty source: C# StreamLzFrameCompressor's stream-based Compress loop
    // never enters the body (`while (bytesRead > 0)`), so it writes only the
    // frame header + end mark and returns. Match that here to keep parity
    // on zero-byte inputs.
    if (src.len == 0) {
        if (pos + 4 > dst.len) return error.DestinationTooSmall;
        frame.writeEndMark(dst[pos..]);
        pos += 4;
        return pos;
    }

    // C# StreamLzFrameCompressor calls StreamLZCompressor.Compress(pSrc, len, ...)
    // which produces a single buffer of concatenated internal blocks, and
    // wraps the whole thing in ONE frame block header. Match that.
    const frame_block_hdr_pos: usize = pos;
    pos += 8;
    const frame_block_start: usize = pos;

    const can_compress = src.len > fast_constants.min_source_length;

    // Self-contained mode: each 256 KB block is independently decodable.
    // Port of C# `StreamLzCompressor.CompressOneBlock` and
    // `AppendSelfContainedPrefixTable`. `two_phase` implies `self_contained`
    // per C# `StreamLZCompressor.Compress` lines 90-95.
    const self_contained: bool = opts.self_contained or opts.two_phase;
    const sc_flag_bit: u8 = if (self_contained) 0x10 else 0;
    const two_phase_flag_bit: u8 = if (opts.two_phase) 0x20 else 0;

    // Direct port of C# CompressBlocksSerial → CompressOneBlock → CompressChunk.
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
        // Matches C# `CompressOneBlock` line 707: `bool keyframe = sc || (blockSrc == dictBase)`.
        const keyframe = self_contained or src_off == 0;

        // ── Write 2-byte block header (compressed) ──────────────────────
        if (pos + 2 > dst.len) return error.DestinationTooSmall;
        var flags0: u8 = 0x05 | sc_flag_bit | two_phase_flag_bit;
        if (keyframe) flags0 |= 0x40;
        dst[pos] = flags0;
        dst[pos + 1] = @intFromEnum(block_header.CodecType.fast);
        pos += 2;

        // ── Block-level AreAllBytesEqual → memset chunk header ─────────
        // Port of StreamLzCompressor.CompressOneBlock line 713-717.
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
        // Port of StreamLzCompressor.CompressChunk. Per sub-chunk:
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
                    // C# CompressChunk line 882-890: plain memcpy via
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
                // Port of StreamLzCompressor.CompressChunk line 920-942.
                // For Fast with no tANS/Huffman, EncodeArrayU8 falls back to
                // memcpy which always returns count+3 bytes (i.e., never
                // beats raw), so plain_huff_cost is always invalidated.
                // We still emit the same decision arm to stay byte-parity
                // with C# in case the order of operations matters.
                var plain_huff_cost: f32 = std.math.inf(f32);
                if (check_plain_huffman) {
                    plain_huff_cost = @min(sub_memset_cost, lz_cost);
                    // EncodeArrayU8 memcpy returns count + 3. Check matches
                    // C# `plainHuffN < 0 || plainHuffN >= roundBytes`.
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
                    // kept for structural parity with C#.
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
                // round_bytes < 32: too small to compress. C# line 984-989.
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
        // Port of StreamLzCompressor.CompressOneBlock line 728. Rewrite
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
            const raw: u32 = @intCast(chunk_compressed_size - 1);
            std.mem.writeInt(u32, dst[chunk_hdr_pos..][0..4], raw, .little);
        }

        src_off += block_src_len;
    }

    // SC mode: append a prefix table of (num_chunks - 1) * 8 bytes at the
    // end of the frame block payload. Each entry holds the first 8 bytes of
    // chunks 1..N-1 (the 0-fill + memcpy trick matches C#
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
    // frame block (matching C# StreamLzFrameCompressor.Compress).
    const frame_block_compressed_size = pos - frame_block_start;
    if (!can_compress or frame_block_compressed_size >= src.len) {
        pos = frame_block_start;
        if (pos + src.len > dst.len) return error.DestinationTooSmall;
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(src.len),
            .decompressed_size = @intCast(src.len),
            .uncompressed = true,
        });
        @memcpy(dst[pos..][0..src.len], src);
        pos += src.len;
    } else {
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(frame_block_compressed_size),
            .decompressed_size = @intCast(src.len),
            .uncompressed = false,
        });
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
/// C# `Slz.MapLevel` for unified levels 6-11.
const HighMapping = struct {
    codec_level: i32,
    self_contained: bool,
    use_bt4: bool,
};

fn mapHighLevel(user_level: u8) HighMapping {
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

/// Port of the High-codec slice of `StreamLzCompressor.Compress` /
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

    // ── Frame block header placeholder ─────────────────────────────────
    const frame_block_hdr_pos: usize = pos;
    pos += 8;
    const frame_block_start: usize = pos;

    const can_compress = src.len > fast_constants.min_source_length;

    // ── High encoder context ───────────────────────────────────────────
    // L5+ enables `export_tokens`. Entropy options per C# SetupEncoder:
    // start at 0xFF & ~MultiArrayAdvanced, then re-enable MultiArrayAdvanced
    // when level >= 7.
    var entropy_raw: u8 = 0xFF & ~@as(u8, 0b0100_0000); // clear MultiArrayAdvanced
    if (mapping.codec_level >= 7) entropy_raw |= 0b0100_0000;
    const ctx: high_encoder.HighEncoderContext = .{
        .allocator = allocator,
        .compression_level = mapping.codec_level,
        .speed_tradeoff = cost_coeffs.speedTradeoffFor(
            cost_coeffs.default_space_speed_tradeoff_bytes,
            true,
        ),
        .entropy_options = @bitCast(entropy_raw),
        .encode_flags = 4, // export_tokens, per C# SetupEncoder line 75
    };

    // ── Allocate MLS + run match finder on the whole source ───────────
    // C# allocates MLS over dictSize + srcSize; for the initial wiring
    // we pass preload_size=0 and let the optimal parser's SC filter
    // handle boundary cases when needed.
    var mls_opt: ?mls_mod.ManagedMatchLenStorage = null;
    defer if (mls_opt) |*m| m.deinit();
    if (can_compress and mapping.codec_level >= 5) {
        var mls = try mls_mod.ManagedMatchLenStorage.init(allocator, src.len + 1, 8.0);
        mls.window_base_offset = 0;
        mls.round_start_pos = 0;
        if (mapping.use_bt4) {
            try match_finder_bt4.findMatchesBT4(allocator, src, &mls, 4, 0, 128);
        } else {
            try match_finder.findMatchesHashBased(allocator, src, &mls, 4, 0);
        }
        mls_opt = mls;
    }

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

    var src_off: usize = 0;
    while (can_compress and src_off < src.len) {
        const block_src_len: usize = @min(src.len - src_off, lz_constants.chunk_size);
        const block_src: []const u8 = src[src_off..][0..block_src_len];

        const block_start: usize = pos;
        const keyframe = src_off == 0;

        // 2-byte block header (compressed, codec=high)
        if (pos + 2 > dst.len) return error.DestinationTooSmall;
        var flags0: u8 = 0x05;
        if (keyframe) flags0 |= 0x40;
        dst[pos] = flags0;
        dst[pos + 1] = @intFromEnum(block_header.CodecType.high);
        pos += 2;

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

        // 4-byte chunk header placeholder
        if (pos + 4 > dst.len) return error.DestinationTooSmall;
        const chunk_hdr_pos: usize = pos;
        pos += 4;
        const chunk_payload_start: usize = pos;

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
                const sub_hdr_pos: usize = pos;
                pos += 3;
                const sub_payload_start: usize = pos;
                const start_position_for_sub: usize = src_off + sub_off;

                var chunk_type: i32 = -1;
                var lz_cost: f32 = std.math.inf(f32);
                const mls_ptr: ?*const mls_mod.ManagedMatchLenStorage = if (mls_opt) |*m| m else null;
                const dst_remaining_for_sub: usize = dst.len - sub_payload_start;
                const dst_sub_start: [*]u8 = dst[sub_payload_start..].ptr;
                const dst_sub_end: [*]u8 = dst_sub_start + dst_remaining_for_sub;
                const n_or_err = high_compressor.doCompress(
                    &ctx,
                    &hasher,
                    mls_ptr,
                    sub_src.ptr,
                    @intCast(round_bytes),
                    dst_sub_start,
                    dst_sub_end,
                    @intCast(start_position_for_sub),
                    &chunk_type,
                    &lz_cost,
                );

                if (n_or_err) |n| {
                    const total_lz_cost = lz_cost + 3.0;
                    const lz_wins = total_lz_cost < sub_memset_cost and n > 0 and n < round_bytes;
                    if (lz_wins) {
                        const hdr: u32 = @as(u32, @intCast(n)) |
                            (@as(u32, @intCast(chunk_type)) << lz_constants.sub_chunk_type_shift) |
                            lz_constants.chunk_header_compressed_flag;
                        dst[sub_hdr_pos + 0] = @intCast((hdr >> 16) & 0xFF);
                        dst[sub_hdr_pos + 1] = @intCast((hdr >> 8) & 0xFF);
                        dst[sub_hdr_pos + 2] = @intCast(hdr & 0xFF);
                        pos = sub_payload_start + n;
                        total_cost += total_lz_cost;
                        lz_chose = true;
                    } else {
                        pos = sub_hdr_pos;
                    }
                } else |_| {
                    pos = sub_hdr_pos;
                }
            }

            if (!lz_chose) {
                if (pos + 3 + round_bytes > dst.len) return error.DestinationTooSmall;
                const hdr: u32 = @as(u32, @intCast(round_bytes)) | lz_constants.chunk_header_compressed_flag;
                dst[pos + 0] = @intCast((hdr >> 16) & 0xFF);
                dst[pos + 1] = @intCast((hdr >> 8) & 0xFF);
                dst[pos + 2] = @intCast(round_bytes & 0xFF);
                @memcpy(dst[pos + 3 ..][0..round_bytes], sub_src);
                pos += 3 + round_bytes;
                total_cost += sub_memset_cost;
            }

            sub_off += round_bytes;
        }

        const chunk_compressed_size: usize = pos - chunk_payload_start;
        const block_f: f32 = @floatFromInt(block_src_len);
        const block_memset_cost: f32 =
            (block_f * cost_coeffs.memset_per_byte + cost_coeffs.memset_base) *
            ctx.speed_tradeoff +
            block_f + 4.0;
        const should_bail = chunk_compressed_size >= block_src_len or total_cost > block_memset_cost;
        if (should_bail) {
            pos = block_start;
            if (pos + 2 + block_src_len > dst.len) return error.DestinationTooSmall;
            var unc_flags0: u8 = 0x05 | 0x80;
            if (keyframe) unc_flags0 |= 0x40;
            dst[pos] = unc_flags0;
            dst[pos + 1] = @intFromEnum(block_header.CodecType.high);
            pos += 2;
            @memcpy(dst[pos..][0..block_src_len], block_src);
            pos += block_src_len;
        } else {
            const raw: u32 = @intCast(chunk_compressed_size - 1);
            std.mem.writeInt(u32, dst[chunk_hdr_pos..][0..4], raw, .little);
        }

        src_off += block_src_len;
    }

    // Frame block fallback: if compressed total didn't beat uncompressed,
    // rewrite the frame block as one uncompressed frame block.
    const frame_block_compressed_size = pos - frame_block_start;
    if (!can_compress or frame_block_compressed_size >= src.len) {
        pos = frame_block_start;
        if (pos + src.len > dst.len) return error.DestinationTooSmall;
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(src.len),
            .decompressed_size = @intCast(src.len),
            .uncompressed = true,
        });
        @memcpy(dst[pos..][0..src.len], src);
        pos += src.len;
    } else {
        frame.writeBlockHeader(dst[frame_block_hdr_pos..], .{
            .compressed_size = @intCast(frame_block_compressed_size),
            .decompressed_size = @intCast(src.len),
            .uncompressed = false,
        });
    }

    // End mark.
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

test "compressFramedHigh L6 roundtrip: tiny input (uncompressed fallback)" {
    const src = "Hello, world!\n";
    try roundtrip(src, 6);
}

// NOTE: L9/L11 compressed-output roundtrip tests still hit an integer
// overflow inside the decoder's bit_reader.readDistanceCore when unpacking
// offset distance symbols. Root cause is a desync between the High
// encoder's assembleCompressedOutput stream layout and the decoder's
// readLzTable consumer — a direct unit test of writeLzOffsetBits →
// readDistance (see offset_encoder.zig tests) confirms the bit-level
// pair works in isolation, so the drift is at the multi-stream framing
// level. Tracked as step-34 part 2.

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

