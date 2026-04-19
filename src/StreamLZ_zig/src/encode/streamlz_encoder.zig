//! Top-level StreamLZ framed compressor — public API surface.
//!
//! This module is the single import target for callers that need
//! `compressFramed` or `compressBound`.  Internally it delegates to:
//!
//!   - `fast_framed.zig`        — Fast codec (L1-L5) single-frame builder
//!   - `high_framed.zig`        — High codec (L6-L11) serial frame builder
//!   - `compress_parallel.zig`  — parallel block dispatch (both codecs)
//!
//! Format overview:
//!   [SLZ1 frame header]            (format/frame_format.zig)
//!   [block header 8 bytes]         per 256 KB outer block (only 1 for now)
//!   [internal block header 2B]     magic=0x5, decoder=Fast(1)
//!   [chunk header 4B]              compressed_size-1
//!   [sub-chunk(s)]                 one or two per 256 KB, 3-byte header each
//!   [end mark 4B]                  zero u32

const std = @import("std");
const frame = @import("../format/frame_format.zig");
const lz_constants = @import("../format/streamlz_constants.zig");
const fast_constants = @import("fast/fast_constants.zig");
const fast_enc = @import("fast/fast_lz_encoder.zig");
const entropy_enc = @import("entropy/entropy_encoder.zig");
const text_detector = @import("text_detector.zig");
const cost_coeffs = @import("cost_coefficients.zig");
const EntropyOptions = entropy_enc.EntropyOptions;

// Re-export the fast-framed builder for the multi-piece retry path.
const fast_framed = @import("fast_framed.zig");

/// Default dictionary size when the caller doesn't override (1 GB).
pub const default_dictionary_size: u32 = @intCast(lz_constants.max_dictionary_size);

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

/// When the allocator cannot satisfy a single-piece compress, the encoder
/// automatically splits the input into concatenated self-contained frames.
/// The decompressor handles this transparently.
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
pub const ResolvedParams = struct {
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

pub fn resolveParams(src: []const u8, opts: Options) ResolvedParams {
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

/// Returns the entropy option mask for a given user-level:
///   raw-coded levels (L1, L2) -> SupportsShortMemset only
///   lazy entropy levels (L5 only, engine 4) -> full mask minus MultiArrayAdvanced
///   greedy entropy levels (L3, L4, engines 1, 2) -> full mask minus
///     MultiArrayAdvanced AND minus TANS AND minus MultiArray
///     AND minus RLE/RLEEntropy
pub fn entropyOptionsForLevel(user_level: u8) EntropyOptions {
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
    const whole = fast_framed.compressFramedOne(allocator, src, dst, opts);
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
            const piece_n = fast_framed.compressFramedOne(allocator, piece_src, piece_dst, piece_opts) catch |err| switch (err) {
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

    const n0 = try fast_framed.compressFramedOne(allocator, src[0..half], tmp, .{
        .level = 1,
        .self_contained = true,
    });
    const n1 = try fast_framed.compressFramedOne(allocator, src[half..], tmp[n0..], .{
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

    const n0 = try fast_framed.compressFramedOne(allocator, src[0..half], tmp, .{ .level = 6 });
    const n1 = try fast_framed.compressFramedOne(allocator, src[half..], tmp[n0..], .{ .level = 9 });
    const total = n0 + n1;

    const decoded = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decoded);
    const written = try decoder.decompressFramed(tmp[0..total], decoded);
    try testing.expectEqual(src.len, written);
    try testing.expectEqualSlices(u8, &src, decoded[0..written]);
}
