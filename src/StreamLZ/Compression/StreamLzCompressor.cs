// StreamLZCompressor.cs -- Main compression dispatcher for StreamLZ-format streams.

using System.Buffers;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.High;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression;

// All shared types (CodecType, CompressOptions, LzCoder, LzTemp, LzScratchBlock,
// ByteHistogram, LengthAndOffset, HashPos, MatchUtils, CompressUtils)
// are defined in their own files (same namespace).
// BitWriter64Forward / BitWriter64Backward are defined in BitWriter.cs.
// Block header writers are in BlockHeaderWriter.cs.
// Text detection heuristics are in TextDetector.cs.

/// <summary>
/// Top-level StreamLZ compressor. Dispatches to format-specific encoders
/// (High, Fast).
/// </summary>
internal static unsafe partial class StreamLZCompressor
{
    // ================================================================
    //  Public API
    // ================================================================

    /// <summary>
    /// Compresses <paramref name="source"/> into <paramref name="destination"/>
    /// using the specified codec and level.
    /// </summary>
    /// <param name="source">The source data to compress.</param>
    /// <param name="destination">The buffer to receive compressed output. Must be at least <see cref="GetCompressBound"/> bytes.</param>
    /// <param name="codec">The compression codec to use (High or Fast).</param>
    /// <param name="level">Compression level (0-9). Higher levels yield better compression but are slower.</param>
    /// <param name="selfContained">When true, each chunk is independently decompressible (no cross-chunk references).</param>
    /// <returns>Number of compressed bytes written, or -1 on failure.</returns>
    public static int Compress(
        ReadOnlySpan<byte> source, Span<byte> destination,
        CodecType codec = CodecType.High, int level = 4,
        bool selfContained = false)
    {
        fixed (byte* src = source)
        fixed (byte* dst = destination)
        {
            return Compress(src, source.Length, dst, destination.Length, codec, level,
                selfContained: selfContained);
        }
    }

    /// <summary>
    /// Compresses data at <paramref name="src"/> into <paramref name="dst"/>
    /// using the specified codec and level.
    /// </summary>
    /// <param name="src">Pointer to the source data to compress.</param>
    /// <param name="srcLen">Length of the source data in bytes.</param>
    /// <param name="dst">Pointer to the destination buffer for compressed output.</param>
    /// <param name="dstLen">Length of the destination buffer. Must be at least <see cref="GetCompressBound"/> bytes.</param>
    /// <param name="codec">The compression codec to use (High or Fast).</param>
    /// <param name="level">Compression level (0-9). Higher levels yield better compression but are slower.</param>
    /// <param name="numThreads">Number of compression threads. 0 = auto (1 thread per core, capped by 60% RAM).</param>
    /// <param name="selfContained">When true, each chunk is independently decompressible (no cross-chunk references).</param>
    /// <param name="twoPhase">When true, enables two-phase parallel decompression support.</param>
    /// <returns>Number of compressed bytes written, or -1 on failure.</returns>
    public static int Compress(
        byte* src, int srcLen, byte* dst, int dstLen,
        CodecType codec = CodecType.High, int level = 4,
        int numThreads = 0, bool selfContained = false, bool twoPhase = false)
    {
        if (srcLen <= 0)
            throw new ArgumentOutOfRangeException(nameof(srcLen), "Source length must be positive.");
        if (dstLen < GetCompressBound(srcLen))
            throw new ArgumentException($"Destination buffer too small. Need at least {GetCompressBound(srcLen)} bytes, got {dstLen}.", nameof(dstLen));

        if (numThreads <= 0)
        {
            numThreads = CalculateMaxThreads(srcLen, level);
        }

        CompressOptions? opts = null;
        if (selfContained)
        {
            opts = GetDefaultCompressOpts(level);
            opts.SelfContained = true;
        }

        if (twoPhase)
        {
            opts ??= GetDefaultCompressOpts(level);
            opts.SelfContained = true;
            opts.TwoPhase = true;
        }

        return CompressBlock((int)codec, src, dst, srcLen, level,
            compressOpts: opts, srcWindowBase: null, numThreads: numThreads);
    }

    /// <summary>
    /// Estimated per-thread memory for parallel block compression (~40MB).
    /// Includes LzTemp scratch, tmpDst, token arrays, encoder buffers.
    /// </summary>
    private const long PerThreadMemoryEstimate = StreamLZConstants.PerThreadMemoryEstimate;

    /// <summary>
    /// Estimates shared (serial) memory overhead for the compression job.
    /// Just the compact match source copy (~srcLen).
    /// </summary>
    /// <param name="srcLen">Length of the source data in bytes.</param>
    /// <returns>Estimated shared memory requirement in bytes.</returns>
    private static long EstimateSharedMemory(int srcLen)
    {
        return srcLen;
    }

    /// <summary>
    /// Dynamically calculates the maximum number of compression threads based on
    /// available cores and system memory. Never exceeds 60% of total physical RAM.
    /// </summary>
    /// <param name="srcLen">Length of the source data in bytes, used to estimate shared memory overhead.</param>
    /// <param name="level">Compression level, which affects per-thread memory requirements.</param>
    /// <returns>The recommended number of threads, at least 1.</returns>
    public static int CalculateMaxThreads(int srcLen, int level)
    {
        int cores = Environment.ProcessorCount;

        long totalMemory = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;

        long memoryBudget = (totalMemory * 60) / 100;
        long sharedMem = EstimateSharedMemory(srcLen);
        long availableForThreads = memoryBudget - sharedMem;

        if (availableForThreads <= 0)
        {
            return 1;
        }

        int maxByMemory = (int)(availableForThreads / PerThreadMemoryEstimate);
        int result = Math.Max(1, Math.Min(cores, maxByMemory));
        return result;
    }

    /// <summary>
    /// Returns the maximum compressed size for a given source length.
    /// </summary>
    /// <param name="srcLen">Length of the uncompressed source data in bytes.</param>
    /// <returns>The worst-case compressed size in bytes, accounting for block headers.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int GetCompressBound(int srcLen)
    {
        const int MaxPerChunkOverhead = 274;
        long bound = srcLen + (long)MaxPerChunkOverhead * ((srcLen + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize);
        if (bound > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(srcLen), $"Source length {srcLen} produces a compress bound exceeding int.MaxValue. Use the streaming API for large inputs.");
        return (int)bound;
    }

    // ================================================================
    //  GetHashBits
    // ================================================================

    /// <summary>
    /// Computes the hash table size in bits for a given source length and level.
    /// </summary>
    /// <param name="srcLen">Length of the source data in bytes.</param>
    /// <param name="level">Compression level (affects hash size heuristic).</param>
    /// <param name="copts">Compression options that may override hash bit count.</param>
    /// <param name="minLowLevelBits">Minimum hash bits for levels 0-2.</param>
    /// <param name="maxLowLevelBits">Maximum hash bits for levels 0-2.</param>
    /// <param name="minHighLevelBits">Minimum hash bits for levels 3+.</param>
    /// <param name="maxHighLevelBits">Maximum hash bits for levels 3+.</param>
    /// <returns>The hash table size in bits, clamped to the appropriate range.</returns>
    public static int GetHashBits(int srcLen, int level, CompressOptions copts,
        int minLowLevelBits, int maxLowLevelBits, int minHighLevelBits, int maxHighLevelBits)
    {
        int len = srcLen; // already clamped to int range
        if (copts.SeekChunkReset != 0 && len > copts.SeekChunkLen)
        {
            len = copts.SeekChunkLen;
        }

        int bits = ILog2Round(len);
        if (level > 2)
        {
            bits = Math.Clamp(bits, minHighLevelBits, maxHighLevelBits);
        }
        else
        {
            bits = Math.Clamp(bits - 1, minLowLevelBits, maxLowLevelBits);
        }

        // HashBits <= AbsoluteHashBitsThreshold means "relative" mode (clamp to this max).
        // HashBits > AbsoluteHashBitsThreshold means "absolute" mode (use HashBits - threshold directly).
        const int AbsoluteHashBitsThreshold = 100;
        if (copts.HashBits > 0)
        {
            if (copts.HashBits <= AbsoluteHashBitsThreshold)
            {
                bits = Math.Clamp(Math.Min(bits, copts.HashBits), 12, 26);
            }
            else
            {
                bits = Math.Clamp(copts.HashBits - AbsoluteHashBitsThreshold, 8, 28);
            }
        }

        return bits;
    }

    /// <summary>
    /// Rounded integer log2 via float bit-trick.
    /// </summary>
    /// <param name="v">The value to compute the rounded log2 of.</param>
    /// <returns>The rounded base-2 logarithm of <paramref name="v"/>.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static int ILog2Round(int v)
    {
        // IEEE 754 bit trick: reinterprets the float exponent field to approximate log2(v).
        // Adding 0x257D86 (~0.29 * 2^23) before extracting the exponent rounds to the
        // nearest integer log2 instead of always flooring. Subtracting 127 removes the
        // IEEE 754 exponent bias.
        float f = (float)v;
        uint u = BitConverter.SingleToUInt32Bits(f);
        return (int)(((u + 0x257D86u) >> 23) - 127);
    }

    // ================================================================
    //  CompressBlock -- main entry point that dispatches per-codec
    // ================================================================

    /// <summary>
    /// Compresses a single block, dispatching to the appropriate format encoder.
    /// </summary>
    /// <param name="codecId">Codec identifier (cast from <see cref="CodecType"/>).</param>
    /// <param name="srcIn">Pointer to the source data.</param>
    /// <param name="dstIn">Pointer to the destination buffer.</param>
    /// <param name="srcSize">Size of the source data in bytes.</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="compressOpts">Compression options, or <c>null</c> for defaults.</param>
    /// <param name="srcWindowBase">Base of the dictionary window, or <c>null</c> to use <paramref name="srcIn"/>.</param>
    /// <param name="numThreads">Number of threads for parallel block compression.</param>
    /// <returns>Compressed size in bytes, or -1 on failure.</returns>
    public static int CompressBlock(
        int codecId, byte* srcIn, byte* dstIn, int srcSize, int level,
        CompressOptions? compressOpts, byte* srcWindowBase,
        int numThreads = 1)
    {
        return codecId switch
        {
            (int)CodecType.High =>
                CompressBlock_High(srcIn, dstIn, srcSize, level, compressOpts, srcWindowBase, numThreads),
            (int)CodecType.Fast =>
                CompressBlock_Fast(srcIn, dstIn, srcSize, level, compressOpts, srcWindowBase, (int)CodecType.Fast, numThreads),
            _ => -1,
        };
    }

    // ================================================================
    //  Per-format CompressBlock wrappers
    // ================================================================

    /// <summary>
    /// High block compressor. Initializes an <see cref="LzCoder"/> and calls
    /// <see cref="CompressInternal"/>.
    /// </summary>
    /// <param name="srcIn">Pointer to the source data.</param>
    /// <param name="dstIn">Pointer to the destination buffer.</param>
    /// <param name="srcSize">Size of the source data in bytes.</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="compressOpts">Compression options, or <c>null</c> for defaults.</param>
    /// <param name="srcWindowBase">Base of the dictionary window, or <c>null</c> to use <paramref name="srcIn"/>.</param>
    /// <param name="numThreads">Number of threads for parallel block compression.</param>
    /// <returns>Compressed size in bytes, or -1 on failure.</returns>
    public static int CompressBlock_High(
        byte* srcIn, byte* dstIn, int srcSize, int level,
        CompressOptions? compressOpts, byte* srcWindowBase,
        int numThreads = 1)
    {
        compressOpts ??= GetDefaultCompressOpts(level);
        if (srcWindowBase == null)
        {
            srcWindowBase = srcIn;
        }

        using var coder = new LzCoder { LastChunkType = -1, CodecId = (int)CodecType.High, NumThreads = numThreads };
        High.Compressor.SetupEncoder(coder, srcSize, level, compressOpts, srcWindowBase, srcIn);
        return CompressInternal(coder, srcIn, dstIn, srcSize, srcWindowBase);
    }

    /// <summary>
    /// Fast block compressor. Levels 7-9 delegate to the High compressor
    /// with self-contained mode for better speed at similar ratios.
    /// </summary>
    public static int CompressBlock_Fast(
        byte* srcIn, byte* dstIn, int srcSize, int level,
        CompressOptions? compressOpts, byte* srcWindowBase, int codecId,
        int numThreads = 1)
    {
        // Fast levels 7-9 use the High compressor with self-contained chunks.
        // This gives similar ratio but 5-7x faster compression and 1.5x faster decompression
        // compared to the Fast optimal parser.
        if (level >= 7)
        {
            int highLevel = level switch
            {
                7 => 5,
                8 => 7,
                _ => 9, // 9+
            };
            compressOpts ??= GetDefaultCompressOpts(highLevel);
            compressOpts.SelfContained = true;
            return CompressBlock_High(srcIn, dstIn, srcSize, highLevel, compressOpts, srcWindowBase, numThreads);
        }

        compressOpts ??= GetDefaultCompressOpts(level);
        if (srcWindowBase == null)
        {
            srcWindowBase = srcIn;
        }

        using var coder = new LzCoder { LastChunkType = -1, CodecId = codecId, NumThreads = numThreads };
        Fast.Compressor.SetupEncoder(coder, srcSize, level, compressOpts, srcWindowBase, srcIn);
        return CompressInternal(coder, srcIn, dstIn, srcSize, srcWindowBase);
    }

    // ================================================================
    //  GetDefaultCompressOpts
    // ================================================================

    /// <summary>
    /// Returns the default <see cref="CompressOptions"/> for the given compression
    /// <paramref name="level"/>.
    /// </summary>
    /// <param name="level">Compression level (0-9).</param>
    /// <returns>A new <see cref="CompressOptions"/> instance with defaults for the specified level.</returns>
    public static CompressOptions GetDefaultCompressOpts(int level)
    {
        return new CompressOptions
        {
            SeekChunkLen = StreamLZConstants.ChunkSize,
            SpaceSpeedTradeoffBytes = 256, // default speed/ratio tradeoff (1/256 scale)
            MaxLocalDictionarySize = 4 * 1024 * 1024, // 4 MB
        };
    }

    // ================================================================
    //  CompressInternal -- orchestrates block splitting and LRM
    // ================================================================

    /// <summary>
    /// For self-contained streams, appends the first 8 source bytes of each
    /// chunk (except the first) as a suffix. The parallel decompressor uses
    /// this table to restore boundary bytes after independent decompression.
    /// </summary>
    private static int AppendSelfContainedPrefixTable(
        byte* srcIn, int srcSize, byte* dst)
    {
        int numChunks = (srcSize + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize;
        int written = 0;
        for (int i = 1; i < numChunks; i++)
        {
            Buffer.MemoryCopy(srcIn + i * StreamLZConstants.ChunkSize, dst, 8, 8);
            dst += 8;
            written += 8;
        }
        return written;
    }

    /// <summary>
    /// Main compression loop. Orchestrates match finding, block compression
    /// dispatch, and self-contained prefix accumulation.
    /// </summary>
    /// <param name="coder">The configured LZ coder with codec, level, and options.</param>
    /// <param name="srcIn">Pointer to the source data.</param>
    /// <param name="dst">Pointer to the destination buffer.</param>
    /// <param name="srcSize">Size of the source data in bytes.</param>
    /// <param name="srcWindowBase">Base of the dictionary window for match references.</param>
    /// <returns>Total number of compressed bytes written.</returns>
    [SkipLocalsInit]
    internal static int CompressInternal(
        LzCoder coder, byte* srcIn, byte* dst, int srcSize,
        byte* srcWindowBase)
    {
        byte* destinationStart = dst;

        using var lztemp = new LzTemp();

        if (srcWindowBase == null || coder.Options!.SeekChunkReset != 0)
        {
            srcWindowBase = srcIn;
        }

        // Self-contained parallel compress: each chunk is independent, so we can
        // do match finding + compression for all chunks in parallel.
        // Only for levels 5+ which use hash-based match finding + optimal parser.
        if (coder.Options!.SelfContained && coder.NumThreads > 1 && srcSize > StreamLZConstants.ChunkSize
            && coder.CompressionLevel >= 5)
            return CompressInternalParallelSC(coder, srcIn, dst, srcSize, destinationStart);

        if (coder.CompressionLevel >= 5)
        {
            int totalWindow = (int)(srcIn + srcSize - srcWindowBase);
            const int MinLocalDictionaryFallback = 64 * 1024 * 1024; // 64 MB
            int localDictSize = Math.Max(coder.Options.MaxLocalDictionarySize, MinLocalDictionaryFallback);

            // Single-round: copy dict+source into a compact managed array
            int dictSize = Math.Min((int)(srcIn - srcWindowBase), localDictSize - srcSize);
            if (dictSize < 0) dictSize = 0;
            if (coder.Options.DictionarySize > 0)
            {
                dictSize = Math.Min(dictSize, coder.Options.DictionarySize);
            }

            int compactLen = dictSize + srcSize;
            byte[] matchSrcArr = lztemp.GetMatchSrcBuffer(compactLen);
            byte* dictBase = srcIn - dictSize;
            fixed (byte* pArr = matchSrcArr)
                Buffer.MemoryCopy(dictBase, pArr, compactLen, compactLen);

            var mls = ManagedMatchLenStorage.Create(srcSize + 1, 8.0f);
            mls.WindowBaseOffset = dictSize;
            mls.RoundStartPos = (int)(srcIn - srcWindowBase);

            MatchFinder.FindMatchesHashBased(matchSrcArr, compactLen, mls, 4, dictSize);

            byte* dictBasePtr = srcIn - dictSize;
            int n = CompressBlocks(coder, lztemp, srcIn, dst, srcSize,
                dictBasePtr, srcWindowBase, mls);
            dst += n;
        }
        else
        {
            int n = CompressBlocks(coder, lztemp, srcIn, dst, srcSize,
                srcWindowBase, srcWindowBase);
            dst += n;
        }

        // Self-contained: store prefix bytes after all rounds complete.
        if (coder.Options!.SelfContained)
        {
            dst += AppendSelfContainedPrefixTable(srcIn, srcSize, dst);
        }

        return (int)(dst - destinationStart);
    }

    // ================================================================
    //  Self-contained parallel compress (match finding + compression)
    // ================================================================

    /// <summary>
    /// Fully parallel self-contained compression. Each 256KB chunk gets its own
    /// match finder and compressor running in parallel — no LRM, no multi-round.
    /// </summary>
    [SkipLocalsInit]
    private static int CompressInternalParallelSC(
        LzCoder coder, byte* srcIn, byte* dst, int srcSize, byte* destinationStart)
    {
        int numChunks = (srcSize + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize;
        var results = new BlockResult[numChunks];
        nint srcL = (nint)srcIn;

        Parallel.For(0, numChunks,
            new ParallelOptions { MaxDegreeOfParallelism = coder.NumThreads },
            () =>
            {
                var origPriority = Thread.CurrentThread.Priority;
                // Lower worker thread priority to avoid starving the UI/main thread during parallel compression.
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                return (Coder: coder.CloneForThread(), Temp: new LzTemp(), OrigPriority: origPriority);
            },
            (i, _, threadState) =>
            {
                var (threadCoder, threadLzTemp, _) = threadState;
                byte* blockSrc = (byte*)srcL + i * StreamLZConstants.ChunkSize;
                int blockSize = Math.Min(srcSize - i * StreamLZConstants.ChunkSize, StreamLZConstants.ChunkSize);
                int bufsizeNeeded = GetCompressBound(blockSize);
                byte[] tmpBuf = ArrayPool<byte>.Shared.Rent(bufsizeNeeded + StreamLZConstants.CompressBufferPadding);

                // Per-chunk match finding: compact array, no dictionary across chunks
                byte[] matchSrcArr = ArrayPool<byte>.Shared.Rent(blockSize);
                fixed (byte* pArr = matchSrcArr)
                    Buffer.MemoryCopy(blockSrc, pArr, blockSize, blockSize);

                var mls = ManagedMatchLenStorage.Create(blockSize + 1, 8.0f);
                mls.WindowBaseOffset = 0;
                mls.RoundStartPos = 0; // SC chunks are independent; MLS indices are 0-based
                MatchFinder.FindMatchesHashBased(matchSrcArr, blockSize, mls, 4, 0);
                ArrayPool<byte>.Shared.Return(matchSrcArr);

                fixed (byte* pTmp = tmpBuf)
                {
                    byte* tmpDst = pTmp;
                    bool keyframe = true; // every SC chunk is a keyframe

                    if (AreAllBytesEqual(blockSrc, blockSize))
                    {
                        byte* dstBlk = WriteBlockHdr(tmpDst, threadCoder.CompressorFileId,
                            threadCoder.Options!.GenerateChunkHeaderChecksum, keyframe, uncompressed: false, selfContained: true);
                        byte* end = WriteMemsetChunkHeader(dstBlk, blockSrc[0]);
                        results[i] = new BlockResult { TmpBuf = tmpBuf, TotalBytes = (int)(end - tmpDst) };
                    }
                    else
                    {
                        byte* dstBlk = WriteBlockHdr(tmpDst, threadCoder.CompressorFileId,
                            threadCoder.Options!.GenerateChunkHeaderChecksum, keyframe, uncompressed: false, selfContained: true);
                        byte* dstQh = WriteChunkHeader(dstBlk, (uint)(blockSize - 1));

                        float cost = StreamLZConstants.InvalidCost;
                        // startPos=0: each SC chunk is independent; ensures initialCopyBytes=8
                        // to prevent Mode 0 delta literal cascade corruption.
                        int chunkCompressedSize = CompressChunk(threadCoder, threadLzTemp, mls, blockSrc, blockSize,
                            dstQh, tmpDst + bufsizeNeeded, 0, &cost);

                        float memsetCost = (blockSize * CostCoefficients.Current.MemsetPerByte + CostCoefficients.Current.MemsetBase)
                            * threadCoder.SpeedTradeoff + blockSize + StreamLZConstants.ChunkHeaderSize;

                        if (chunkCompressedSize < 0 || chunkCompressedSize >= blockSize || cost > memsetCost)
                        {
                            tmpDst = pTmp;
                            byte* uncHdr = WriteBlockHdr(tmpDst, threadCoder.CompressorFileId,
                                crc: false, keyframe, uncompressed: true, selfContained: true);
                            Buffer.MemoryCopy(blockSrc, uncHdr, blockSize, blockSize);
                            results[i] = new BlockResult { TmpBuf = tmpBuf, TotalBytes = (int)(uncHdr + blockSize - tmpDst) };
                        }
                        else
                        {
                            WriteChunkHeader(dstBlk, (uint)(chunkCompressedSize - 1));
                            results[i] = new BlockResult { TmpBuf = tmpBuf, TotalBytes = (int)(dstQh + chunkCompressedSize - tmpDst) };
                        }
                    }
                }

                return threadState;
            },
            threadState =>
            {
                Thread.CurrentThread.Priority = threadState.OrigPriority;
                threadState.Temp.Dispose();
            });

        // Assemble results sequentially and return pooled buffers
        byte* dstCur = dst;
        for (int i = 0; i < numChunks; i++)
        {
            ref var r = ref results[i];
            fixed (byte* pBuf = r.TmpBuf)
                Buffer.MemoryCopy(pBuf, dstCur, r.TotalBytes, r.TotalBytes);
            dstCur += r.TotalBytes;
            ArrayPool<byte>.Shared.Return(r.TmpBuf);
        }

        // Append first-8-byte prefix table at the end
        dstCur += AppendSelfContainedPrefixTable((byte*)srcL, srcSize, dstCur);

        return (int)(dstCur - destinationStart);
    }

    // ================================================================
    //  CompressBlocks -- iterates over 256KB blocks
    // ================================================================

    /// <summary>
    /// Splits data into 256KB blocks, writes block headers, and compresses each
    /// chunk.
    /// When <see cref="LzCoder.NumThreads"/> &gt; 1, blocks are compressed in parallel.
    /// </summary>
    /// <param name="coder">The configured LZ coder.</param>
    /// <param name="lztemp">Scratch memory for LZ operations (reused across blocks in serial mode).</param>
    /// <param name="src">Pointer to the source data for this round.</param>
    /// <param name="dst">Pointer to the destination buffer.</param>
    /// <param name="srcSize">Size of the source data in bytes.</param>
    /// <param name="dictBase">Base of the dictionary (for keyframe detection).</param>
    /// <param name="windowBase">Window base pointer used for offset calculations.</param>
    /// <param name="mls">Pre-computed match storage from the match finder, or <c>null</c>.</param>
    /// <returns>Total compressed size in bytes for all blocks.</returns>
    [SkipLocalsInit]
    internal static int CompressBlocks(
        LzCoder coder, LzTemp lztemp,
        byte* src, byte* dst, int srcSize,
        byte* dictBase, byte* windowBase,
        ManagedMatchLenStorage? mls = null)
    {
        int numBlocks = (srcSize + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize;
        // Fast levels (< 5) use the hasher directly — not thread-safe, must run serial
        if (numBlocks <= 1 || coder.NumThreads <= 1 || mls == null)
        {
            return CompressBlocksSerial(coder, lztemp, src, dst, srcSize, dictBase, windowBase, mls);
        }

        return CompressBlocksParallel(coder, src, dst, srcSize, dictBase, windowBase, mls, numBlocks);
    }

    /// <summary>
    /// Compresses a single 256KB block: writes the block header, handles memset/uncompressed
    /// fallback, and compresses the chunk. Returns the total number of bytes written
    /// to <paramref name="dstBase"/>.
    /// </summary>
    /// <param name="coder">The LZ coder (may be per-thread clone).</param>
    /// <param name="lztemp">Scratch memory for LZ operations.</param>
    /// <param name="mls">Pre-computed match storage, or <c>null</c>.</param>
    /// <param name="blockSrc">Pointer to the source data for this block.</param>
    /// <param name="blockSize">Size of the block in bytes.</param>
    /// <param name="dstBase">Pointer to the destination buffer for this block.</param>
    /// <param name="dictBase">Base of the dictionary (for keyframe detection).</param>
    /// <param name="windowBase">Window base pointer used for offset calculations.</param>
    /// <returns>Total bytes written (header + compressed/uncompressed data).</returns>
    [SkipLocalsInit]
    private static int CompressOneBlock(
        LzCoder coder, LzTemp lztemp, ManagedMatchLenStorage? mls,
        byte* blockSrc, int blockSize, byte* dstBase,
        byte* dictBase, byte* windowBase)
    {
        int bufsizeNeeded = GetCompressBound(blockSize);
        bool sc = coder.Options!.SelfContained;
        bool keyframe = sc || (blockSrc == dictBase);

        byte* dst = dstBase;
        byte* dstBlk = WriteBlockHdr(dst, coder.CompressorFileId,
            coder.Options.GenerateChunkHeaderChecksum, keyframe, uncompressed: false, selfContained: sc);

        if (AreAllBytesEqual(blockSrc, blockSize))
        {
            byte* end = WriteMemsetChunkHeader(dstBlk, blockSrc[0]);
            return (int)(end - dstBase);
        }

        byte* dstQh = WriteChunkHeader(dstBlk, (uint)(blockSize - 1));
        float cost = StreamLZConstants.InvalidCost;
        int offset = (int)(blockSrc - windowBase);
        int chunkCompressedSize = CompressChunk(coder, lztemp, mls, blockSrc, blockSize,
            dstQh, dstBase + bufsizeNeeded, offset, &cost);

        float memsetCost = (blockSize * CostCoefficients.Current.MemsetPerByte + CostCoefficients.Current.MemsetBase)
            * coder.SpeedTradeoff + blockSize + StreamLZConstants.ChunkHeaderSize;

        if (chunkCompressedSize < 0 || chunkCompressedSize >= blockSize || cost > memsetCost)
        {
            // Fall back to uncompressed
            dst = dstBase;
            byte* uncHdr = WriteBlockHdr(dst, coder.CompressorFileId, crc: false, keyframe,
                uncompressed: true, selfContained: sc);
            Buffer.MemoryCopy(blockSrc, uncHdr, blockSize, blockSize);
            return (int)(uncHdr + blockSize - dstBase);
        }

        WriteChunkHeader(dstBlk, (uint)(chunkCompressedSize - 1));
        return (int)(dstQh + chunkCompressedSize - dstBase);
    }

    /// <summary>
    /// Single-threaded block compression path. Iterates over 256KB blocks sequentially,
    /// writing block headers and compressing each chunk via <see cref="CompressOneBlock"/>.
    /// </summary>
    [SkipLocalsInit]
    private static int CompressBlocksSerial(
        LzCoder coder, LzTemp lztemp,
        byte* src, byte* dst, int srcSize,
        byte* dictBase, byte* windowBase,
        ManagedMatchLenStorage? mls)
    {
        byte* destinationStart = dst;
        byte* srcEnd = src + srcSize;

        while (src < srcEnd)
        {
            int roundBytes = Math.Min((int)(srcEnd - src), StreamLZConstants.ChunkSize);
            int written = CompressOneBlock(coder, lztemp, mls, src, roundBytes, dst, dictBase, windowBase);
            dst += written;
            src += roundBytes;
        }

        return (int)(dst - destinationStart);
    }

    /// <summary>
    /// Parallel block compression using <see cref="Parallel.For(int, int, Action{int})"/>. Each block gets its own
    /// thread-local <see cref="LzTemp"/> and cloned <see cref="LzCoder"/>. Results are assembled
    /// sequentially into the output buffer after all blocks complete.
    /// </summary>
    /// <remarks>
    /// <paramref name="mls"/> must be read-only during parallel execution. Match finding
    /// is completed before this method is called, so the storage is only read (never
    /// mutated) by the parallel body lambdas.
    /// </remarks>
    [SkipLocalsInit]
    private static int CompressBlocksParallel(
        LzCoder coder, byte* src, byte* dst, int srcSize,
        byte* dictBase, byte* windowBase,
        ManagedMatchLenStorage? mls, int numBlocks)
    {
        var results = new BlockResult[numBlocks];

        // Capture raw pointers as nint for lambda capture. Safe because the caller's
        // fixed block (in Compress/CompressBlock) pins the source buffer for the entire
        // parallel operation lifetime.
        nint srcL = (nint)src;
        nint dictBaseL = (nint)dictBase;
        nint windowBaseL = (nint)windowBase;

        Parallel.For(0, numBlocks,
            new ParallelOptions { MaxDegreeOfParallelism = coder.NumThreads },
            // Thread-local init: each thread gets its own LzCoder clone + LzTemp
            () =>
            {
                var origPriority = Thread.CurrentThread.Priority;
                // Lower worker thread priority to avoid starving the UI/main thread during parallel compression.
                Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                return (Coder: coder.CloneForThread(), Temp: new LzTemp(), OrigPriority: origPriority);
            },
            // Body: compress block i using shared CompressOneBlock helper
            (i, _, threadState) =>
            {
                var (threadCoder, threadLzTemp, _) = threadState;
                byte* blockSrc = (byte*)srcL + i * StreamLZConstants.ChunkSize;
                int blockSize = Math.Min(srcSize - i * StreamLZConstants.ChunkSize, StreamLZConstants.ChunkSize);
                int bufsizeNeeded = GetCompressBound(blockSize);
                byte[] tmpBuf = ArrayPool<byte>.Shared.Rent(bufsizeNeeded + StreamLZConstants.CompressBufferPadding); // room for header + data

                fixed (byte* pTmp = tmpBuf)
                {
                    int written = CompressOneBlock(
                        threadCoder, threadLzTemp, mls,
                        blockSrc, blockSize, pTmp,
                        (byte*)dictBaseL, (byte*)windowBaseL);
                    results[i] = new BlockResult { TmpBuf = tmpBuf, TotalBytes = written };
                }

                return threadState;
            },
            // Thread-local finalize: restore priority and dispose LzTemp
            threadState =>
            {
                Thread.CurrentThread.Priority = threadState.OrigPriority;
                threadState.Temp.Dispose();
            });

        // Assemble results sequentially into dst
        byte* dstCur = dst;
        for (int i = 0; i < numBlocks; i++)
        {
            ref var r = ref results[i];
            fixed (byte* pBuf = r.TmpBuf)
                Buffer.MemoryCopy(pBuf, dstCur, r.TotalBytes, r.TotalBytes);
            dstCur += r.TotalBytes;
            ArrayPool<byte>.Shared.Return(r.TmpBuf);
        }

        return (int)(dstCur - dst);
    }

    // ================================================================
    //  CompressChunk
    // ================================================================

    /// <summary>
    /// Compresses a single chunk (up to sub-chunk-size bytes at a time),
    /// choosing between LZ, memset, and plain Huffman.
    /// Compresses a single chunk of data.
    /// </summary>
    /// <param name="coder">The configured LZ coder with codec, level, and speed tradeoff settings.</param>
    /// <param name="lztemp">Scratch memory for LZ operations.</param>
    /// <param name="mls">Pre-computed match storage from the match finder, or <c>null</c>.</param>
    /// <param name="src">Pointer to the source data for this chunk.</param>
    /// <param name="srcSize">Size of the source data in bytes.</param>
    /// <param name="dst">Pointer to the destination buffer.</param>
    /// <param name="dstEnd">Pointer to the end of the destination buffer (bounds check).</param>
    /// <param name="offset">Offset of <paramref name="src"/> from the window base, for match position tracking.</param>
    /// <param name="costPtr">Receives the total compression cost (speed + size) of the chunk.</param>
    /// <returns>Number of compressed bytes written, or -1 on failure.</returns>
    [SkipLocalsInit]
    internal static int CompressChunk(
        LzCoder coder, LzTemp lztemp, ManagedMatchLenStorage? mls,
        byte* src, int srcSize,
        byte* dst, byte* dstEnd, int offset, float* costPtr)
    {
        byte* destinationStart = dst;
        byte* sourceStart = src;
        byte* srcEnd2 = src + srcSize;
        float totalCost = 0;

        while (src < srcEnd2)
        {
            int roundBytes = Math.Min((int)(srcEnd2 - src), coder.SubChunkSize);

            float memsetCost = (roundBytes * CostCoefficients.Current.MemsetPerByte + CostCoefficients.Current.MemsetBase)
                * coder.SpeedTradeoff + roundBytes + 3;

            if (roundBytes >= 32)
            {
                if (AreAllBytesEqual(src, roundBytes))
                {
                    float msCost = StreamLZConstants.InvalidCost;
                    int n = EntropyEncoder.EncodeArrayU8(dst, dstEnd, src, roundBytes,
                        coder.EntropyOptions, coder.SpeedTradeoff, &msCost, 0, null);
                    src += roundBytes;
                    dst += n;
                    totalCost += msCost;
                }
                else
                {
                    float lzCost = StreamLZConstants.InvalidCost;
                    int chunkType = -1;
                    int n;

                    if (coder.CodecId == (int)CodecType.High)
                    {
                        n = High.Compressor.DoCompress(coder, lztemp, mls, src, roundBytes,
                            dst + 3, dstEnd, offset + (int)(src - sourceStart), &chunkType, &lzCost);
                    }
                    else if (coder.CodecId == (int)CodecType.Fast ||
                             coder.CodecId == (int)CodecType.Turbo)
                    {
                        n = Fast.Compressor.DoCompress(coder, lztemp, mls, src, roundBytes,
                            dst + 3, dstEnd, offset + (int)(src - sourceStart), &chunkType, &lzCost);
                    }
                    else
                    {
                        *costPtr = StreamLZConstants.InvalidCost;
                        return -1;
                    }
                    lzCost += 3;

                    // Optionally try plain Huffman
                    int plainHuffN = 0;
                    float plainHuffCost = StreamLZConstants.InvalidCost;
                    byte[]? plainHuffBuf = null;

                    if (coder.CheckPlainHuffman)
                    {
                        plainHuffCost = Math.Min(memsetCost, lzCost);
                        int plainHuffDstSize = (roundBytes >> 4) + roundBytes + 256;
                        plainHuffBuf = ArrayPool<byte>.Shared.Rent(plainHuffDstSize);
                    }

                    try
                    {
                        if (plainHuffBuf != null)
                        {
                            fixed (byte* pHuff = plainHuffBuf)
                            {
                                plainHuffN = EntropyEncoder.EncodeArrayU8(pHuff, pHuff + plainHuffBuf.Length,
                                    src, roundBytes, coder.EntropyOptions, coder.SpeedTradeoff,
                                    &plainHuffCost, coder.CompressionLevel, null);
                            }

                            if (plainHuffN < 0 || plainHuffN >= roundBytes)
                            {
                                plainHuffCost = StreamLZConstants.InvalidCost;
                            }
                        }

                        if (lzCost < memsetCost && lzCost <= plainHuffCost && n >= 0 && n < roundBytes)
                        {
                            // Write LZ chunk: 3-byte header then n compressed bytes
                            uint innerHdr = (uint)n | (uint)chunkType << StreamLZConstants.SubChunkTypeShift | StreamLZConstants.ChunkHeaderCompressedFlag;
                            dst = WriteBE24(dst, innerHdr) + n;
                            totalCost += lzCost;
                        }
                        else if (memsetCost <= plainHuffCost)
                        {
                            // Uncompressed fallback
                            WriteBE24(dst, (uint)roundBytes | StreamLZConstants.ChunkHeaderCompressedFlag);
                            Buffer.MemoryCopy(src, dst + 3, roundBytes, roundBytes);
                            dst += 3 + roundBytes;
                            totalCost += memsetCost;
                        }
                        else
                        {
                            // Plain Huffman was best
                            fixed (byte* pHuff = plainHuffBuf)
                                Buffer.MemoryCopy(pHuff, dst, dstEnd - dst, plainHuffN);
                            dst += plainHuffN;
                            totalCost += plainHuffCost;
                        }
                    }
                    finally
                    {
                        if (plainHuffBuf != null)
                        {
                            ArrayPool<byte>.Shared.Return(plainHuffBuf);
                        }
                    }
                }
            }
            else
            {
                // Too small to compress -- store raw
                WriteBE24(dst, (uint)roundBytes | StreamLZConstants.ChunkHeaderCompressedFlag);
                Buffer.MemoryCopy(src, dst + 3, roundBytes, roundBytes);
                dst += 3 + roundBytes;
                totalCost += memsetCost;
            }

            src += roundBytes;
        }

        *costPtr = totalCost;
        return (int)(dst - destinationStart);
    }

}
