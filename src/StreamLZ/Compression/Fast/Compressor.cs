// Compressor.cs — Top-level Fast compressor entry points.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// Top-level Fast compressor entry points: encoder setup and compression dispatch.
/// The Fast codec supports levels 0-9, ranging from greedy parsing with minimal
/// hashing (fastest) to optimal DP parsing with entropy coding (best ratio).
/// </summary>
internal static unsafe class Compressor
{
    // ────────────────────────────────────────────────────────────────
    //  Level mapping
    // ────────────────────────────────────────────────────────────────

    /// <summary>Internal level descriptor mapping user-facing levels to engine parameters.</summary>
    private struct InternalLevel
    {
        /// <summary>Internal level value passed to the parser and encoder functions.</summary>
        public int EngineLevel;
        /// <summary>Whether to use entropy coding on literal and token streams.</summary>
        public bool UseLiteralEntropyCoding;
    }

    /// <summary>
    /// Maps a user-facing compression level (0-9) to internal engine parameters.
    /// </summary>
    /// <remarks>
    /// <list type="table">
    /// <listheader><term>Level</term><description>Strategy</description></listheader>
    /// <item><term>0-1</term><description>Greedy, ushort hash, raw streams</description></item>
    /// <item><term>2</term><description>Greedy, uint hash, raw streams</description></item>
    /// <item><term>3</term><description>Greedy, uint hash, entropy-coded streams</description></item>
    /// <item><term>4</term><description>Lazy, MatchHasher2x, entropy-coded (swapped with 5 for
    ///   better speed progression — the lazy parser is slower but on some data
    ///   achieves better ratio than greedy-rehash at level 5)</description></item>
    /// <item><term>5</term><description>Greedy with match rehashing, entropy-coded</description></item>
    /// <item><term>6</term><description>Lazy, MatchHasher2 with chain walking, entropy-coded</description></item>
    /// <item><term>7</term><description>Optimal DP parser, raw streams</description></item>
    /// <item><term>8-9</term><description>Optimal DP parser, entropy-coded streams</description></item>
    /// </list>
    /// </remarks>
    private static InternalLevel MapLevel(int userLevel)
    {
        return userLevel switch
        {
            0 or 1 => new InternalLevel { EngineLevel = -2, UseLiteralEntropyCoding = false },
            2 => new InternalLevel { EngineLevel = -1, UseLiteralEntropyCoding = false },
            3 => new InternalLevel { EngineLevel = 1, UseLiteralEntropyCoding = true },
            // Levels 4-5 are swapped vs the engine ordering: the engine has greedy-rehash
            // (EngineLevel=2) before lazy-MatchHasher2x (EngineLevel=3), but lazy-MatchHasher2x
            // produces worse ratios than greedy-rehash on most data. Swapping puts the
            // worse-ratio lazy parser at the lower level to keep the ratio curve monotonic
            // from level 6 onward.
            4 => new InternalLevel { EngineLevel = 3, UseLiteralEntropyCoding = true },
            5 => new InternalLevel { EngineLevel = 2, UseLiteralEntropyCoding = true },
            6 => new InternalLevel { EngineLevel = 4, UseLiteralEntropyCoding = true },
            7 => new InternalLevel { EngineLevel = 5, UseLiteralEntropyCoding = false },
            _ => new InternalLevel { EngineLevel = 5, UseLiteralEntropyCoding = true }, // 8, 9+
        };
    }

    // ────────────────────────────────────────────────────────────────
    //  Compression dispatch
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Main Fast compression dispatch. Routes to the appropriate parser
    /// based on the configured compression level.
    /// </summary>
    /// <param name="coder">Configured LZ coder with level, options, and hasher.</param>
    /// <param name="lztemp">Scratch memory for encoding operations.</param>
    /// <param name="matchStorage">Pre-computed match storage (used by optimal levels only).</param>
    /// <param name="source">Pointer to the source data.</param>
    /// <param name="sourceLength">Length of the source data in bytes.</param>
    /// <param name="destination">Pointer to the destination buffer for compressed output.</param>
    /// <param name="destinationEnd">Pointer past the end of the destination buffer.</param>
    /// <param name="startPosition">Offset of <paramref name="source"/> from the window base.</param>
    /// <param name="chunkTypeOutput">Receives the selected chunk type (0 = delta literals, 1 = raw literals).</param>
    /// <param name="costOutput">Receives the rate-distortion cost of the compressed output.</param>
    /// <returns>Number of compressed bytes written, or <paramref name="sourceLength"/> if compression failed.</returns>
    public static int DoCompress(LzCoder coder, LzTemp lztemp, ManagedMatchLenStorage? matchStorage,
        byte* source, int sourceLength, byte* destination, byte* destinationEnd,
        int startPosition, int* chunkTypeOutput, float* costOutput)
    {
        int level = coder.CompressionLevel;

        if (level == 1 || level == -1)
        {
            return FastParser.CompressGreedy<uint>(1, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        else if (level == 2)
        {
            return FastParser.CompressGreedy<uint>(2, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        else if (level == 3)
        {
            return FastParser.CompressLazy(3, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        else if (level == 4)
        {
            return FastParser.CompressLazyChainHasher(4, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        else if (level == -2)
        {
            return FastParser.CompressGreedy<ushort>(-2, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        else if (level == -3)
        {
            return FastParser.CompressGreedy<ushort>(-3, coder, lztemp, source, sourceLength, destination, destinationEnd, startPosition, chunkTypeOutput, costOutput);
        }
        // Levels 7-9 (engine level >= 5) are handled by CompressBlock_Fast
        // which delegates to the High compressor with self-contained mode.
        // They never reach DoCompress.
        return -1;
    }

    // ────────────────────────────────────────────────────────────────
    //  Encoder setup
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Initializes the <see cref="LzCoder"/> for Fast compression at the given level.
    /// Creates the appropriate hash table, configures entropy options, and sets up
    /// the level-specific parameters.
    /// </summary>
    /// <param name="coder">LzCoder to configure.</param>
    /// <param name="sourceLength">Total length of the source data in bytes.</param>
    /// <param name="userLevel">User-facing compression level (0-9).</param>
    /// <param name="compressionOptions">Compression options (dictionary size, match length, etc.).</param>
    /// <param name="sourceBase">Base pointer of the source window (dictionary start).</param>
    /// <param name="sourceStart">Pointer to the start of new data within the window.</param>
    public static void SetupEncoder(LzCoder coder, int sourceLength, int userLevel,
        CompressOptions compressionOptions, byte* sourceBase, byte* sourceStart)
    {
        Debug.Assert(sourceBase != null && sourceStart != null);

        var mapped = MapLevel(userLevel);
        int level = mapped.EngineLevel;
        bool useLiteralEntropyCoding = mapped.UseLiteralEntropyCoding;

        int hashBits = HighEntropyEncoder.GetHashBits(sourceLength, Math.Max(level, 2), compressionOptions, 16, 20, 17, 24);

        coder.SubChunkSize = 0x20000;
        coder.CheckPlainHuffman = useLiteralEntropyCoding && (level >= 4);
        coder.CompressionLevel = level;
        coder.Options = compressionOptions;
        coder.SpeedTradeoff = (compressionOptions.SpaceSpeedTradeoffBytes * FastConstants.SpeedTradeoffScale) * (useLiteralEntropyCoding ? FastConstants.EntropySpeedFactor : FastConstants.RawSpeedFactor);
        coder.MaxMatchesToConsider = 4;
        coder.CompressorFileId = (int)CodecType.Fast;
        coder.EncodeFlags = 0;
        coder.UseLiteralEntropyCoding = useLiteralEntropyCoding;

        // CodecId is used internally by the chunk dispatcher to route to DoCompress.
        // For entropy-coded mode, set to Fast; for raw (no entropy) mode, set to Turbo (internal marker).
        coder.CodecId = useLiteralEntropyCoding ? (int)CodecType.Fast : (int)CodecType.Turbo;

        if (useLiteralEntropyCoding)
        {
            if (level >= 5)
                coder.EntropyOptions = 0xff & ~(int)EntropyOptions.AllowMultiArrayAdvanced;
            else
                coder.EntropyOptions = 0xff & ~((int)EntropyOptions.AllowMultiArrayAdvanced | (int)EntropyOptions.AllowTANS | (int)EntropyOptions.AllowMultiArray);
            level = Math.Max(level, -3);
        }
        else
        {
            coder.EntropyOptions = (int)EntropyOptions.SupportsShortMemset;
        }

        int minimumMatchLength = 4;
        if (sourceLength > 0x4000 && level >= -2 && level <= 3 && HighEntropyEncoder.IsProbablyText(sourceStart, sourceLength))
            minimumMatchLength = 6;

        if (level == 3)
        {
            // Level 3 (lazy parser): MatchHasher2x with 2-entry buckets
            if (compressionOptions.HashBits <= 0)
                hashBits = Math.Min(hashBits, 20);
            var hasher = new MatchHasher2x();
            High.Compressor.CreateLzHasher(coder, hasher, sourceBase, sourceStart, hashBits, minimumMatchLength);
            hasher.SrcBase = sourceBase;
        }
        else if (level == 4)
        {
            // Level 4 (lazy parser): MatchHasher2 with chain walking
            var hasher = new MatchHasher2();
            hasher.AllocateHash(hashBits, minimumMatchLength);
            hasher.SrcBase = sourceBase;
            if (sourceStart != sourceBase)
            {
                int preloadLength = Math.Min((int)(sourceStart - sourceBase), 0x40000000);
                if (compressionOptions.DictionarySize > 0)
                    preloadLength = Math.Min(preloadLength, compressionOptions.DictionarySize);
                int spanLength = (int)(sourceStart - sourceBase) + 8;
                var span = new ReadOnlySpan<byte>(sourceBase, spanLength);
                long startOffset = sourceStart - sourceBase;
                hasher.SetBaseAndPreload(span, startOffset - preloadLength, startOffset, preloadLength);
            }
            else
            {
                hasher.SetBaseWithoutPreload(0);
            }
            coder.FastHasher = hasher;
        }
        else
        {
            // Greedy parser levels: simple FastMatchHasher with level-dependent hash size
            int maxHashBits = level switch
            {
                -3 => 13,
                -2 => 14,
                -1 => 16,
                0 or 1 => 17,
                2 => 19,
                _ => hashBits, // levels >= 5 don't use a greedy hasher
            };
            if (compressionOptions.HashBits <= 0)
                hashBits = Math.Min(hashBits, maxHashBits);

            if (level <= -2)
                CreateFastHasher<ushort>(coder, sourceBase, sourceStart, hashBits, minimumMatchLength);
            else
                CreateFastHasher<uint>(coder, sourceBase, sourceStart, hashBits, minimumMatchLength);

            coder.EntropyOptions &= ~((int)EntropyOptions.AllowRLE | (int)EntropyOptions.AllowRLEEntropy);
        }
    }

    /// <summary>
    /// Creates and attaches a <see cref="FastMatchHasher{T}"/> to the coder,
    /// with optional preloading from the dictionary window.
    /// </summary>
    private static void CreateFastHasher<T>(LzCoder coder, byte* sourceBase, byte* sourceStart, int hashBits, int minimumMatchLength)
        where T : unmanaged, INumberBase<T>
    {
        var hasher = new FastMatchHasher<T>();
        hasher.AllocateHash(hashBits, minimumMatchLength);
        if (sourceStart != sourceBase)
        {
            int preloadLength = Math.Min((int)(sourceStart - sourceBase), 0x40000000);
            if (coder.Options!.DictionarySize > 0)
                preloadLength = Math.Min(preloadLength, coder.Options.DictionarySize);
            int spanLength = (int)(sourceStart - sourceBase) + 8;
            var span = new ReadOnlySpan<byte>(sourceBase, spanLength);
            long startOffset = sourceStart - sourceBase;
            hasher.SetBaseAndPreload(span, startOffset - preloadLength, startOffset, preloadLength);
        }
        else
        {
            hasher.SetBaseWithoutPreload(0);
        }
        coder.FastHasher = hasher;
    }
}
