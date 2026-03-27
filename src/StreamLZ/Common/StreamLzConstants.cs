using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Common;

/// <summary>
/// Centralized named constants for the StreamLZ codec family.
/// Eliminates magic numbers scattered across compression and decompression code.
/// </summary>
internal static class StreamLZConstants
{
#if DEBUG
    static StreamLZConstants()
    {
        Debug.Assert(HuffmanLutSize == (1 << HuffmanLutBits), "HuffmanLutSize must equal 1 << HuffmanLutBits");
        Debug.Assert(HighOffsetThreshold == (1 << 24) - OffsetBiasConstant, $"HighOffsetThreshold must equal (1 << 24) - OffsetBiasConstant = {(1 << 24) - OffsetBiasConstant}");
        Debug.Assert(HighOffsetCostAdjust == HighOffsetMarker - 16, "HighOffsetCostAdjust must equal HighOffsetMarker - 16");
    }
#endif

    // ────────────────────────────────────────────────────────────
    //  Chunk and buffer sizing
    // ────────────────────────────────────────────────────────────

    /// <summary>Size of one StreamLZ chunk (256 KB). All block processing aligns to this boundary.</summary>
    public const int ChunkSize = 0x40000; // 262,144

    /// <summary>Number of bits needed to represent a chunk size (log2 of ChunkSize).</summary>
    public const int ChunkSizeBits = 18;

    /// <summary>Size of the per-chunk header in bytes (4-byte little-endian).</summary>
    public const int ChunkHeaderSize = 4;

    /// <summary>Bit mask for the compressed size field in the chunk header.</summary>
    public const uint ChunkSizeMask = ChunkSize - 1; // 0x3FFFF

    /// <summary>Bit position of the type field in the chunk header (immediately above the size field).</summary>
    public const int ChunkTypeShift = ChunkSizeBits;

    /// <summary>Type value indicating a memset chunk (all bytes identical).</summary>
    public const uint ChunkTypeMemset = 1u << ChunkTypeShift;

    /// <summary>
    /// Extra bytes added to compressed output buffers beyond the compress bound.
    /// Provides headroom for the 3-byte chunk header and 8-byte initial literal copy written by the compressor.
    /// </summary>
    public const int CompressBufferPadding = 16;

    /// <summary>
    /// Bit position of the chunk type field in the 3-byte big-endian sub-chunk header.
    /// The sub-chunk header packs: [23] compressed flag | [22:19] type | [18:0] size.
    /// Equals <c>ChunkSizeBits + 1</c> because bit 18 is reserved for the size MSB.
    /// </summary>
    public const int SubChunkTypeShift = 19;

    /// <summary>
    /// Bit flag in the 3-byte big-endian chunk header indicating the chunk contains LZ-compressed data.
    /// When clear, the chunk is entropy-only (pure Huffman, no match-copy loop).
    /// </summary>
    public const uint ChunkHeaderCompressedFlag = 0x800000;

    /// <summary>Scratch buffer size required for decompression (~440 KB).</summary>
    // Max scratch buffer: 3 * ChunkSize + 0x2C000 overhead for entropy decode tables.
    public const int ScratchSize = 0x6C000; // 442,368

    /// <summary>Workspace reserved for entropy decode tables during decompression.</summary>
    public const int EntropyScratchSize = 0xD000; // 53,248 bytes

    /// <summary>Calculates scratch buffer size needed for a chunk of the given decompressed size.</summary>
    public static int CalculateScratchSize(int dstCount) => (int)Math.Min(3L * dstCount + 32 + EntropyScratchSize, ScratchSize);

    /// <summary>
    /// Initial value for the recent-offset carousel, and the number of bytes
    /// copied verbatim at the start of the first chunk (<c>initialCopyBytes</c>).
    /// Must be &gt;= 8 to guarantee non-overlapping 8-byte Copy64 operations.
    /// All encoder and decoder init code must use this constant.
    /// </summary>
    public const int InitialRecentOffset = 8;

    /// <summary>Maximum dictionary / offset distance (1 GB). Offsets beyond this are invalid.</summary>
    public const int MaxDictionarySize = 0x40000000; // 1,073,741,824

    // ────────────────────────────────────────────────────────────
    //  Offset encoding constants
    //
    //  StreamLZ encodes match offsets in two ranges:
    //    Low range:  offset ∈ [8 .. HighOffsetThreshold)
    //      Packed as: nibbleIndex = ((offset - 8) & 0xF) + 16 * (Log2(offset + OffsetBiasConstant) - 9)
    //    High range: offset ≥ HighOffsetThreshold
    //      Packed as: Log2(offset - LowOffsetEncodingLimit) | HighOffsetMarker
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Bias added to offsets in the low-range nibble encoding formula.
    /// Formula: <c>Log2(offset + 760) - 9</c> extracts the log₂ bucket.
    /// Equals 768 − 8 (the minimum raw offset), ensuring <c>Log2(8 + 760) = Log2(768) = 9</c>.
    /// </summary>
    public const int OffsetBiasConstant = 760;

    /// <summary>
    /// Upper bound of the low-range offset encoding path.
    /// Offsets &gt;= this value use the high-range (log₂) encoding instead.
    /// Equals <c>(1 &lt;&lt; 24) - OffsetBiasConstant</c> = 16,777,216 − 760 = 16,776,456.
    /// This is the boundary where <c>Log2(offset + 760) - 9</c> reaches nibble index 0xF0.
    /// </summary>
    public const int HighOffsetThreshold = 16776456;

    /// <summary>
    /// Base subtracted from offsets in the high-range encoding path.
    /// <c>Log2(offset - LowOffsetEncodingLimit)</c> determines the variable-length code.
    /// Equals HighOffsetThreshold − (1 &lt;&lt; 16) − 8 = 16,710,912.
    /// </summary>
    public const int LowOffsetEncodingLimit = 16710912;

    /// <summary>
    /// Marker OR'd into the packed offset byte to signal high-range encoding.
    /// Decoders check <c>(packedByte &amp; 0xF0) == 0xF0</c> to detect this path.
    /// </summary>
    public const int HighOffsetMarker = 0xF0;

    /// <summary>
    /// Cost adjustment subtracted from the packed offset byte in high-range encoding
    /// to extract the number of extra bits. Equals <c>HighOffsetMarker - 16</c>.
    /// </summary>
    public const int HighOffsetCostAdjust = 0xE0;

    // ────────────────────────────────────────────────────────────
    //  Huffman lookup table sizing
    // ────────────────────────────────────────────────────────────

    /// <summary>Number of entries in the main Huffman lookup table (11-bit, 2^11 = 2048).</summary>
    public const int HuffmanLutSize = 2048;

    /// <summary>Mask for Huffman LUT index (HuffmanLutSize - 1 = 0x7FF).</summary>
    public const int HuffmanLutMask = HuffmanLutSize - 1;

    /// <summary>Minimum bitpos value after OR clamping in the Huffman 3-stream decode loop.
    /// OR with 0x18 sets bits 3+4, ensuring bitpos >= 24 before refill.</summary>
    public const int HuffmanBitposClampMask = 0x18;

    // ────────────────────────────────────────────────────────────
    //  Entropy block size encoding masks
    // ────────────────────────────────────────────────────────────

    /// <summary>10-bit mask for entropy short-mode size fields (compact chunk header).</summary>
    public const int BlockSizeMask10 = 0x3FF;

    /// <summary>12-bit mask for memcopy short-mode size field (compact memcopy header).</summary>
    public const int BlockSizeMask12 = 0xFFF;

    /// <summary>RLE short-copy command threshold. Commands at or above this value (+ 1) use compact copy+RLE encoding.</summary>
    public const uint RleShortCommandThreshold = 0x2F;

    /// <summary>Bit width of the Huffman LUT index (log₂ of <see cref="HuffmanLutSize"/>).</summary>
    public const int HuffmanLutBits = 11;

    /// <summary>
    /// Extra entries appended to Huffman LUT arrays for SIMD fill safety.
    /// Vectorized LUT construction may overshoot by up to this many entries.
    /// </summary>
    public const int HuffmanLutOverflow = 16;

    // ────────────────────────────────────────────────────────────
    //  Symbol alphabet
    // ────────────────────────────────────────────────────────────

    /// <summary>Size of the byte alphabet (256 symbols, 0x00–0xFF).</summary>
    public const int AlphabetSize = 256;

    // ────────────────────────────────────────────────────────────
    //  Match finder / hash table
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// 25-bit mask applied to positions stored in the hash table.
    /// Limits the addressable window to 32 MB per hash context.
    /// </summary>
    public const uint HashPositionMask = 0x01FFFFFF;

    /// <summary>Number of bits used for hash table position storage (25).</summary>
    public const int HashPositionBits = 25;

    /// <summary>
    /// 7-bit mask for the collision-rejection tag stored alongside the position in each hash entry.
    /// Used to quickly reject non-matching hash collisions without reading source data.
    /// </summary>
    public const uint HashTagMask = 0xFE000000;

    /// <summary>Offsets at or above this threshold (12 MB) require a 4th byte in the Fast far-offset encoding.</summary>
    public const int FastLargeOffsetThreshold = 0xC00000;

    // ────────────────────────────────────────────────────────────
    //  Match distance thresholds
    //  Longer minimum match lengths are required at larger offsets
    //  to ensure the match is worth encoding.
    // ────────────────────────────────────────────────────────────

    /// <summary>Offsets below 12 KB: minimum match length 3.</summary>
    public const int OffsetThreshold12KB = 0x3000;

    /// <summary>Offsets below 96 KB: minimum match length 4.</summary>
    public const int OffsetThreshold96KB = 0x18000;

    /// <summary>Offsets below 768 KB: minimum match length 4.</summary>
    public const int OffsetThreshold768KB = 0xC0000;

    /// <summary>Offsets in [768 KB .. 1.5 MB): minimum match length 5.</summary>
    public const int OffsetThreshold1_5MB = 0x180000;

    /// <summary>Offsets in [1.5 MB .. 3 MB): minimum match length 6.</summary>
    public const int OffsetThreshold3MB = 0x300000;

    // ────────────────────────────────────────────────────────────
    //  Cost model
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Sentinel value representing an impossibly high cost, used to initialize
    /// cost arrays and mark unreachable states in the DP optimal parser.
    /// </summary>
    // Sentinel "infinity" cost. Large enough to never be a valid compression cost.
    public const float InvalidCost = float.MaxValue / 2;

    /// <summary>
    /// Fixed-point scale factor for bit costs in the cost model.
    /// Costs are stored as <c>rawBits * CostScaleFactor</c> to allow fractional-bit precision.
    /// </summary>
    // Fixed-point cost precision: 5 fractional bits (1 << 5 = 32).
    public const int CostScaleFactor = 32;

    // ────────────────────────────────────────────────────────────
    //  Entropy table sizing
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Size of the log₂ lookup table used for entropy cost approximation.
    /// Table stores <c>4096 * log₂(4096 / i)</c> for <c>i ∈ [1..4096]</c>.
    /// </summary>
    public const int Log2LookupTableSize = 4097;

    // ────────────────────────────────────────────────────────────
    //  Hashing
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Fibonacci hashing multiplier (2^64 / φ). Used by all match hashers for
    /// high-quality hash distribution with multiplicative hashing.
    /// </summary>
    public const ulong FibonacciHashMultiplier = 0x9E3779B97F4A7C15UL;

    // ────────────────────────────────────────────────────────────
    //  Threading
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Estimated memory consumption per compression thread (40 MB).
    /// Used by the thread count calculator to avoid exceeding available RAM.
    /// </summary>
    public const long PerThreadMemoryEstimate = 40L * 1024 * 1024;
}
