// Compressor.cs — High LZ compression.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.High;

/// <summary>
/// The High LZ compressor.
/// Contains the full compression pipeline: veryfast, fast (with lazy matching),
/// and optimal (multi-state DP parser).
/// </summary>
internal static unsafe partial class Compressor
{
    /// <summary>
    /// Main High compression entry point. Dispatches based on compression level.
    /// </summary>
    [SkipLocalsInit]
    public static int DoCompress(LzCoder coder, LzTemp lztemp, ManagedMatchLenStorage? mls,
        byte* src, int srcSize,
        byte* dst, byte* destinationEnd,
        int startPos, int* chunkTypePtr, float* costPtr,
        ExportedTokens? exportedTokens = null)
    {
        // Levels 5+: optimal parser
        if (coder.CompressionLevel >= 5)
        {
            return Optimal(coder, lztemp, mls,
                src, srcSize, dst, destinationEnd, startPos, chunkTypePtr, costPtr, exportedTokens);
        }

        // Levels 1-4: fast greedy/lazy parser
        int numLazy = coder.CompressionLevel switch
        {
            1 => 0,
            2 => 0,
            3 => 1,
            4 => 2,
            _ => 0
        };
        return FastParser.CompressFast(coder, lztemp, src, srcSize, dst, destinationEnd,
            startPos, chunkTypePtr, costPtr, numLazy);
    }

    /// <summary>
    /// Initialize the LzCoder for High compression at the given level.
    /// </summary>
    public static void SetupEncoder(LzCoder coder, int sourceLength, int level,
        CompressOptions copts, byte* srcBase, byte* srcStart)
    {
        Debug.Assert(srcBase != null && srcStart != null);
        int hashBits = EntropyEncoder.GetHashBits(sourceLength, Math.Max(level, 2), copts, 16, 20, 17, 24);

        coder.CodecId = (int)CodecType.High;
        coder.SubChunkSize = 0x20000;
        coder.CheckPlainHuffman = level >= 3;
        coder.CompressionLevel = level;
        coder.Options = copts;
        coder.SpeedTradeoff = (copts.SpaceSpeedTradeoffBytes * CostCoefficients.Current.SpeedTradeoffFactor1) * CostCoefficients.Current.SpeedTradeoffFactor2;
        coder.MaxMatchesToConsider = 4;
        coder.CompressorFileId = (int)CodecType.High;
        coder.EncodeFlags = 0;
        coder.EntropyOptions = 0xFF & ~(int)EntropyOptions.AllowMultiArrayAdvanced;

        if (level >= 7)
        {
            coder.EntropyOptions |= (int)EntropyOptions.AllowMultiArrayAdvanced;
        }

        if (level >= 5)
        {
            coder.EncodeFlags = 4;
        }

        // minMatchLen (4 or 6 for text) would be passed to CreateLzHasher.
        // Hash table creation is level-dependent.
        // The hash bits are computed and stored but the hasher itself requires MatchHasher.

        // Lookup table: (maxHashBits, entropyMask, hasherFactory) per level.
        // Index 0 = level -3, index 7 = level 4. Levels >= 5 have no entry (hasher already created above).
        const int TansMultiRle = (int)(EntropyOptions.AllowTANS | EntropyOptions.AllowMultiArray | EntropyOptions.AllowRLE);
        const int TansMulti = (int)(EntropyOptions.AllowTANS | EntropyOptions.AllowMultiArray);
        const int TansMultiAdv = (int)(EntropyOptions.AllowTANS | EntropyOptions.AllowMultiArrayAdvanced);

        // (maxHashBits when copts.HashBits <= 0, entropyMask, hasherType)
        // hasherType: 0=MatchHasher1, 1=MatchHasher2x, 2=MatchHasher4, 3=MatchHasher4Dual
        ReadOnlySpan<int> levelTable =
        [
            // level -3: idx 0
            12, TansMultiRle, 0,
            // level -2: idx 1
            14, TansMultiRle, 0,
            // level -1: idx 2
            16, TansMultiRle, 0,
            // level 0: idx 3
            19, TansMultiRle, 0,
            // level 1: idx 4
            19, TansMultiRle, 0,
            // level 2: idx 5
            int.MaxValue, TansMulti, 1,
            // level 3: idx 6
            int.MaxValue, TansMulti, 2,
            // level 4: idx 7
            int.MaxValue, TansMultiAdv, 3,
        ];

        // Levels >= 5 use a different hasher path (Optimal creates its own).
        // Only levels -3 through 4 need hasher + entropy mask setup here.
        if (level <= 4)
        {
            int tableIndex = Math.Clamp(level + 3, 0, 7);
            int maxHash = levelTable[tableIndex * 3];
            int entropyMask = levelTable[tableIndex * 3 + 1];
            int hasherType = levelTable[tableIndex * 3 + 2];

            if (copts.HashBits <= 0 && maxHash != int.MaxValue)
            {
                hashBits = Math.Min(hashBits, maxHash);
            }

            coder.EntropyOptions &= ~entropyMask;

            MatchHasherBase hasher = hasherType switch
            {
                1 => new MatchHasher2x(),
                2 => new MatchHasher4(),
                3 => new MatchHasher4Dual(),
                _ => new MatchHasher1(),
            };
            CreateLzHasher(coder, hasher, srcBase, srcStart, hashBits);
        }
    }

    private const int MaxPreload = 0x4000000; // 64MB

    /// <summary>
    /// Creates a MatchHasherBase, allocates its hash table, and preloads from the window.
    /// </summary>
    internal static void CreateLzHasher(LzCoder coder, MatchHasherBase hasher,
        byte* srcBase, byte* srcStart, int hashBits, int minMatchLen = 0)
    {
        coder.Hasher = hasher;
        hasher.AllocateHash(hashBits, minMatchLen);

        if (srcStart == srcBase)
        {
            hasher.SetBaseWithoutPreload(0);
        }
        else
        {
            int preloadLen = (int)(srcStart - srcBase);
            var copts = coder.Options!;

            if (copts.DictionarySize > 0)
            {
                preloadLen = Math.Min(preloadLen, copts.DictionarySize);
            }
            preloadLen = Math.Min(preloadLen, MaxPreload);

            int spanLen = (int)(srcStart - srcBase) + 8; // need at least 8 bytes past start for hashing
            var span = new ReadOnlySpan<byte>(srcBase, spanLen);
            long srcStartOffset = srcStart - srcBase;
            hasher.SetBaseAndPreload(span, srcStartOffset - preloadLen, srcStartOffset, preloadLen);
        }
    }
}
