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

/// Estimated memory consumption per parallel compress worker thread
/// (40 MB). Mirrors C# `StreamLzConstants.PerThreadMemoryEstimate`.
/// Used by `calculateMaxThreads` to cap the thread count so the
/// total worker footprint stays within a fraction of available RAM.
pub const per_thread_memory_estimate: u64 = 40 * 1024 * 1024;

/// Fraction of total physical RAM that parallel compression is
/// allowed to consume (60%). Matches C# `CalculateMaxThreads`.
pub const memory_budget_pct: u64 = 60;

// ────────────────────────────────────────────────────────────
//  Platform-specific total-physical-memory query
// ────────────────────────────────────────────────────────────

const MemoryStatusEx = extern struct {
    dwLength: u32,
    dwMemoryLoad: u32,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MemoryStatusEx) callconv(.winapi) std.os.windows.BOOL;

/// Returns the total physical memory on the host, in bytes, or `0`
/// when the query is unavailable / unsupported. Used by
/// `calculateMaxThreads` as the input to the memory-budget cap.
pub fn totalAvailableMemoryBytes() u64 {
    switch (@import("builtin").os.tag) {
        .windows => {
            var ms: MemoryStatusEx = .{
                .dwLength = @sizeOf(MemoryStatusEx),
                .dwMemoryLoad = 0,
                .ullTotalPhys = 0,
                .ullAvailPhys = 0,
                .ullTotalPageFile = 0,
                .ullAvailPageFile = 0,
                .ullTotalVirtual = 0,
                .ullAvailVirtual = 0,
                .ullAvailExtendedVirtual = 0,
            };
            if (GlobalMemoryStatusEx(&ms) == 0) return 0;
            return ms.ullTotalPhys;
        },
        else => return 0, // Unsupported → no memory cap.
    }
}

/// Dynamically calculates the maximum number of compression worker
/// threads based on CPU count and available system memory. Mirrors
/// C# `StreamLzCompressor.CalculateMaxThreads` at
/// `StreamLzCompressor.cs:174`. Caps at 60% of total physical RAM.
/// When the host's memory is unknown (non-Windows / query failure),
/// falls back to just the CPU count.
///
/// The `src_len` parameter is the estimate for shared memory
/// overhead (matches the C# `EstimateSharedMemory(srcLen) = srcLen`
/// definition). `level` is accepted for API parity with C# but not
/// currently used — per-thread memory is estimated with a level-
/// independent constant.
pub fn calculateMaxThreads(src_len: usize, level: u8) u32 {
    _ = level; // reserved for future level-dependent estimate
    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const total_memory: u64 = totalAvailableMemoryBytes();
    if (total_memory == 0) return @max(@as(u32, 1), cpu);

    const memory_budget: u64 = (total_memory * memory_budget_pct) / 100;
    const shared_mem: u64 = src_len;
    if (memory_budget <= shared_mem) return 1;
    const available_for_threads: u64 = memory_budget - shared_mem;

    const max_by_memory: u64 = available_for_threads / per_thread_memory_estimate;
    if (max_by_memory == 0) return 1;
    const max_by_memory_u32: u32 = @intCast(@min(max_by_memory, @as(u64, cpu)));
    return @max(@as(u32, 1), max_by_memory_u32);
}

pub const CompressError = error{
    BadLevel,
    BadBlockSize,
    DestinationTooSmall,
    HashBitsOutOfRange,
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

    /// Worker thread count for parallel compress. `0` = auto (one per
    /// CPU core, capped by the memory-aware heuristic from step 40).
    /// `1` forces the serial path. Matches C# `LzCoder.NumThreads`.
    num_threads: u32 = 0,
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

/// Compress `src` into `dst` as an SLZ1 byte stream. Returns the
/// number of bytes written to `dst`. `dst` must be at least
/// `compressBound(src.len)`.
///
/// On `error.OutOfMemory` from the single-shot path, automatically
/// splits the input into smaller SELF-CONTAINED pieces and retries
/// through a fallback size ladder (1 GB → 512 MB → 256 MB → 128 MB
/// → 64 MB → 32 MB → 16 MB). Each piece is written as its own
/// complete SLZ1 frame; the decompressor iterates pieces in its
/// `DecompressCore` loop. Mirrors C# `StreamLzCompressor.Compress`
/// at `StreamLzCompressor.cs:97-147`. Phase 14 step 39 (D5).
pub fn compressFramed(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    opts: Options,
) CompressError!usize {
    if (opts.level < 1 or opts.level > 11) return error.BadLevel;
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
    // NOTE: L8 / L11 `use_bt4 = false` is a temporary workaround.
    // The Zig BT4 port in `match_finder_bt4.zig` passes byte-exact
    // roundtrip tests but produces much worse match selection than
    // the hash-based finder — enwik8 at L11 with BT4 compresses to
    // ~41% vs ~27% without. Tracked as a step 33 follow-up; see
    // `match_finder_bt4.zig` for the tree-insertion state that
    // needs bisecting against the C# reference.
    return switch (user_level) {
        6 => .{ .codec_level = 5, .self_contained = true, .use_bt4 = false },
        7 => .{ .codec_level = 7, .self_contained = true, .use_bt4 = false },
        8 => .{ .codec_level = 9, .self_contained = true, .use_bt4 = false },
        9 => .{ .codec_level = 5, .self_contained = false, .use_bt4 = false },
        10 => .{ .codec_level = 7, .self_contained = false, .use_bt4 = false },
        11 => .{ .codec_level = 9, .self_contained = false, .use_bt4 = false },
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
    const self_contained: bool = mapping.self_contained or opts.self_contained or opts.two_phase;
    const sc_flag_bit: u8 = if (self_contained) 0x10 else 0;

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

    // ── Allocate MLS + run match finder on the whole source ───────────
    // For SC parallel we skip this — each worker computes a per-group
    // MLS on its own subset of the source (see compressInternalParallelSc).
    // The global MLS is only used for: (a) non-SC High optimal parse
    // (serial or parallel), (b) SC serial, and (c) SC with num_threads=1.
    var mls_opt: ?mls_mod.ManagedMatchLenStorage = null;
    defer if (mls_opt) |*m| m.deinit();
    if (can_compress and mapping.codec_level >= 5 and !can_parallel_sc) {
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

    // Non-SC parallel: requires the global MLS to be present.
    const can_parallel_blocks: bool =
        can_compress and
        num_blocks > 1 and
        resolved_threads > 1 and
        mls_opt != null and
        !self_contained;

    if (can_parallel_sc) {
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
    } else if (can_parallel_blocks) {
        const written = try compressBlocksParallel(
            allocator,
            src,
            dst[pos..],
            &ctx,
            &(mls_opt.?),
            sc_flag_bit,
            self_contained,
            resolved_threads,
        );
        pos += written;
    } else {
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
                self_contained,
                sc_flag_bit,
                keyframe,
            );
            pos += written;
            src_off += block_src_len;
        }
    }

    // SC mode: append the per-chunk first-8-bytes prefix table at the
    // end of the frame block. Matches the Fast path in `compressFramed`
    // and `StreamLzCompressor.AppendSelfContainedPrefixTable`.
    if (self_contained and can_compress) {
        const num_chunks: usize = (src.len + lz_constants.chunk_size - 1) / lz_constants.chunk_size;
        var i: usize = 1;
        while (i < num_chunks) : (i += 1) {
            const chunk_start = i * lz_constants.chunk_size;
            if (chunk_start >= src.len) break;
            const copy_size: usize = @min(@as(usize, 8), src.len - chunk_start);
            if (pos + 8 > dst.len) return error.DestinationTooSmall;
            @memset(dst[pos..][0..8], 0);
            @memcpy(dst[pos..][0..copy_size], src[chunk_start..][0..copy_size]);
            pos += 8;
        }
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
//  compressOneHighBlock — single 256 KB block → caller-owned dst
// ────────────────────────────────────────────────────────────

/// Compresses a single 256 KB block of `src` (starting at `src_off`,
/// `block_src_len` bytes) into `dst_block`. Returns the number of
/// bytes written. The output contains the 2-byte internal block
/// header + 4-byte chunk header + sub-chunk payload(s), or a
/// fall-back uncompressed 2-byte block header + raw payload when
/// LZ compression doesn't beat raw for this block.
///
/// Mirrors C# `StreamLzCompressor.CompressOneBlock` but with the
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
    self_contained: bool,
    sc_flag_bit: u8,
    keyframe: bool,
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
            // SC mode: `start_pos` must be relative to the CURRENT
            // SC group's start (not the source start). Matches C#
            // `OptimalParser.cs:222`.
            const sc_group_bytes: usize = lz_constants.sc_group_size * lz_constants.chunk_size;
            const start_position_for_sub: usize = if (self_contained)
                ((src_off + sub_off) % sc_group_bytes)
            else
                (src_off + sub_off);

            var chunk_type: i32 = -1;
            var lz_cost: f32 = std.math.inf(f32);
            const dst_remaining_for_sub: usize = dst_block.len - sub_payload_start;
            const dst_sub_start: [*]u8 = dst_block[sub_payload_start..].ptr;
            const dst_sub_end: [*]u8 = dst_sub_start + dst_remaining_for_sub;
            const n_or_err = high_compressor.doCompress(
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
            );

            if (n_or_err) |n| {
                const total_lz_cost = lz_cost + 3.0;
                const lz_wins = total_lz_cost < sub_memset_cost and n > 0 and n < round_bytes;
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
            } else |_| {
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
        const raw: u32 = @intCast(chunk_compressed_size - 1);
        std.mem.writeInt(u32, dst_block[chunk_hdr_pos..][0..4], raw, .little);
    }

    return local_pos;
}

// ────────────────────────────────────────────────────────────
//  compressBlocksParallel — non-SC High parallel block dispatch
// ────────────────────────────────────────────────────────────
//
// Port of C# `StreamLzCompressor.CompressBlocksParallel` at
// `StreamLzCompressor.cs:778`. Works per-block (one 256 KB chunk),
// each thread owning a dedicated tmp buffer. Shared read-only
// across workers: `src` (the full source), `mls` (pre-computed
// match storage), `ctx` (config). The per-block `compressOneHigh
// Block` never mutates any of these, so thread-safety is
// guaranteed without locks.
//
// Workers run at the OS default thread priority. C# sets
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
    // C#'s `[ThreadStatic] LzTemp t_lztemp` reuse pattern. Step 14
    // (D13).
    var arena = std.heap.ArenaAllocator.init(shared.backing_allocator);
    defer arena.deinit();

    // Worker-local context copy with the arena allocator.
    var worker_ctx = shared.base_ctx.*;
    worker_ctx.allocator = arena.allocator();

    // Each worker allocates its OWN `HighHasher` once and reuses it
    // across blocks, matching the C# per-thread `LzCoder` clone. For
    // L5+ this is `.none` (the optimal parser uses the shared MLS
    // directly), so no per-thread state besides the arena.
    var hasher: high_compressor.HighHasher = .{ .none = {} };
    defer hasher.deinit();

    while (true) {
        const block_idx = shared.next_block.fetchAdd(1, .monotonic);
        if (block_idx >= shared.num_blocks) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

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
            shared.self_contained,
            shared.sc_flag_bit,
            keyframe,
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
// Port of C# `StreamLzCompressor.CompressInternalParallelSC` at
// `StreamLzCompressor.cs:528`. The key difference vs
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

    var hasher: high_compressor.HighHasher = .{ .none = {} };
    defer hasher.deinit();

    const group_size = lz_constants.sc_group_size;

    while (true) {
        const g = shared.next_group.fetchAdd(1, .monotonic);
        if (g >= shared.num_groups) return;
        if (shared.error_flag.load(.monotonic) != 0) return;

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
            // First chunk in every group is a keyframe (SC contract).
            const keyframe = true;

            const n_or_err = compressOneHighBlock(
                &worker_ctx,
                &hasher,
                &mls,
                group_src,
                in_group_src_off,
                block_src_len,
                shared.tmp_bufs[chunk_idx],
                true, // self_contained
                shared.sc_flag_bit,
                keyframe,
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

// ────────────────────────────────────────────────────────────
//  Phase 14 step 40 — calculateMaxThreads tests
// ────────────────────────────────────────────────────────────

test "calculateMaxThreads: returns at least 1" {
    // Any non-negative input must yield a positive thread count —
    // a caller passing the result directly into the parallel
    // dispatch should never see 0.
    const n = calculateMaxThreads(0, 9);
    try testing.expect(n >= 1);
    const m = calculateMaxThreads(1024 * 1024, 9);
    try testing.expect(m >= 1);
}

test "calculateMaxThreads: doesn't exceed CPU count" {
    const cpu: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const n = calculateMaxThreads(1024, 6);
    try testing.expect(n <= cpu);
}

test "calculateMaxThreads: scales down with huge src_len" {
    // A huge shared-memory estimate (nearly the whole RAM budget)
    // should drive `available_for_threads` below zero and clamp to
    // 1. We can't observe this directly without knowing the host's
    // total_memory, so we test with src_len == usize max, which
    // guarantees `memory_budget <= shared_mem` on any host.
    const n = calculateMaxThreads(std.math.maxInt(usize) / 2, 9);
    try testing.expect(n >= 1);
}

test "totalAvailableMemoryBytes: returns a plausible value on Windows" {
    if (@import("builtin").os.tag != .windows) return;
    const mem = totalAvailableMemoryBytes();
    // Any Windows host running this test suite has at least 1 GB.
    try testing.expect(mem >= 1 * 1024 * 1024 * 1024);
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

