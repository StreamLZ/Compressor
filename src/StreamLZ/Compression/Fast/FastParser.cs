// FastParser.cs — Greedy and lazy match parsers for the Fast compressor (levels 0-6).

using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// Greedy and lazy match parsers for the Fast compressor.
/// The greedy parser (levels 0-5) uses <see cref="FastMatchHasher{T}"/> directly.
/// The lazy parser (levels 4-6) uses <see cref="MatchHasherBase"/> or <see cref="MatchHasher2"/>
/// with one or two steps of lazy evaluation.
/// </summary>
internal static unsafe class FastParser
{
    // ────────────────────────────────────────────────────────────────
    //  Greedy parser (FastMatchHasher<T>)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Greedy match parser using a simple hash table. Processes one match at a time
    /// without lazy evaluation. The <paramref name="level"/> controls skip factor
    /// and match rehashing behavior.
    /// </summary>
    /// <param name="level">Compression level controlling skip factor and rehashing.</param>
    /// <param name="writer">Stream writer that receives literal and match token output.</param>
    /// <param name="hasher">Fast hash table used for match lookup.</param>
    /// <param name="sourceCursor">Pointer to the current read position in the source block.</param>
    /// <param name="safeSourceEnd">Pointer to the safe-to-read boundary (sourceEnd minus guard bytes).</param>
    /// <param name="sourceEnd">Pointer past the end of the source block.</param>
    /// <param name="recentOffset">Most recent match offset, updated on each match emitted.</param>
    /// <param name="dictionarySize">Maximum allowed match offset in bytes.</param>
    /// <param name="minimumMatchLengthTable">Table mapping offset magnitude to minimum match length.</param>
    /// <param name="minimumMatchLength">Global minimum match length threshold.</param>
    /// <param name="sourceBlock">Pointer to the start of the source block.</param>
    /// <param name="blockBasePosition">Base position of the block within the overall stream.</param>
    private static void RunGreedyParser<T>(int level, ref FastStreamWriter writer,
        FastMatchHasher<T> hasher, byte* sourceCursor, byte* safeSourceEnd, byte* sourceEnd,
        ref nint recentOffset, int dictionarySize, uint* minimumMatchLengthTable, int minimumMatchLength,
        byte* sourceBlock, long blockBasePosition)
        where T : unmanaged, INumberBase<T>
    {
        byte* matchEnd = null;
        long hasherBaseAdjustment = hasher.SrcBaseOffset - blockBasePosition;
        ulong hashMultiplier = hasher.HashMult;
        T[] hashTable = hasher.HashTable;
        int hashShift = 64 - hasher.HashBits;
        int offsetOrRecent;

        int skipFactor = (level <= -3) ? 3 : (level <= 1) ? 4 : 5;
        int skipAccumulator = 1 << skipFactor;
        nint currentOffset = 0;

        byte* literalStart = sourceCursor;
        if (sourceCursor < safeSourceEnd - 5)
        {
            for (;;)
            {
                uint bytesAtCursor = *(uint*)sourceCursor;
                int hashIndex = (int)(*(ulong*)sourceCursor * hashMultiplier >> hashShift);
                uint hashValue = uint.CreateTruncating(hashTable[hashIndex]);
                hashTable[hashIndex] = T.CreateTruncating((long)(sourceCursor - sourceBlock) - hasherBaseAdjustment);

                uint xorValue = bytesAtCursor ^ *(uint*)(sourceCursor + recentOffset);
                bool foundMatch = false;

                if ((xorValue & 0xffffff00) == 0)
                {
                    // 1 byte literal and at least 3 recent match
                    sourceCursor += 1;
                    offsetOrRecent = 0;
                    int hashIndex2 = (int)(*(ulong*)sourceCursor * hashMultiplier >> hashShift);
                    hashTable[hashIndex2] = T.CreateTruncating((long)(sourceCursor - sourceBlock) - hasherBaseAdjustment);
                    currentOffset = recentOffset;
                    matchEnd = Encoder.ExtendMatchForward(sourceCursor + 3, safeSourceEnd, currentOffset);
                    foundMatch = true;
                }
                else
                {
                    // Compute offset as (current position - stored position), truncated to the
                    // hash entry width (ushort or uint depending on T).
                    offsetOrRecent = (int)uint.CreateTruncating(T.CreateTruncating((long)(sourceCursor - sourceBlock) - hasherBaseAdjustment) - T.CreateTruncating(hashValue));

                    if ((uint)(offsetOrRecent - 8) < (uint)(dictionarySize - 8)
                        && offsetOrRecent <= (int)(sourceCursor - sourceBlock)
                        && bytesAtCursor == *(uint*)&sourceCursor[-offsetOrRecent])
                    {
                        matchEnd = Encoder.ExtendMatchForward(sourceCursor + 4, safeSourceEnd, -offsetOrRecent);
                        if (matchEnd - sourceCursor >= (int)minimumMatchLengthTable[31 - BitOperations.Log2((uint)offsetOrRecent)])
                        {
                            currentOffset = -offsetOrRecent;
                            foundMatch = true;
                        }
                    }

                    if (!foundMatch && bytesAtCursor == *(uint*)(sourceCursor - 8))
                    {
                        offsetOrRecent = 8;
                        currentOffset = -8;
                        matchEnd = Encoder.ExtendMatchForward(sourceCursor + 4, safeSourceEnd, currentOffset);
                        foundMatch = true;
                    }

                    if (!foundMatch && level >= 2 && (xorValue & 0xffff) == 0)
                    {
                        // 2 or 3 byte recent match
                        offsetOrRecent = 0;
                        currentOffset = recentOffset;
                        matchEnd = sourceCursor + ((xorValue & 0xffffff) == 0 ? 3 : 2);
                        foundMatch = true;
                    }
                }

                if (!foundMatch)
                {
                    if (safeSourceEnd - 5 - sourceCursor <= (skipAccumulator >> skipFactor))
                        break;
                    byte* nextCursor = sourceCursor + (skipAccumulator >> skipFactor);

                    if (level >= -2)
                        skipAccumulator++;
                    else
                        skipAccumulator = Math.Min(skipAccumulator + (int)((sourceCursor - literalStart) >> 1), 296);

                    sourceCursor = nextCursor;
                    continue;
                }
                // Extend match backward into the literal run
                while (sourceCursor > literalStart && (nint)(sourceBlock - sourceCursor) + (nint)hasherBaseAdjustment < currentOffset &&
                       sourceCursor[-1] == sourceCursor[currentOffset - 1])
                    sourceCursor--;

                int matchLength = (int)(matchEnd - sourceCursor);
                Encoder.WriteOffset(ref writer, matchLength,
                    (int)(sourceCursor - literalStart), offsetOrRecent, recentOffset, literalStart);

                literalStart = sourceCursor = matchEnd;
                skipAccumulator = 1 << skipFactor;
                recentOffset = currentOffset;
                if (sourceCursor >= safeSourceEnd - 5)
                    break;
                if (level >= 2)
                {
                    byte* matchStart = sourceCursor - matchLength;
                    for (int i = 1; i < matchLength; i *= 2)
                    {
                        int hi = (int)(*(ulong*)(i + matchStart) * hashMultiplier >> hashShift);
                        hashTable[hi] = T.CreateTruncating((long)(i + matchStart - sourceBlock) - hasherBaseAdjustment);
                    }
                }
            }
        }
        Encoder.CopyTrailingLiterals(ref writer, literalStart, sourceEnd, recentOffset);
    }

    // ────────────────────────────────────────────────────────────────
    //  Lazy parser (MatchHasherBase)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Lazy match parser using <see cref="MatchHasherBase"/>. Evaluates one or two
    /// positions ahead before committing to a match.
    /// </summary>
    /// <param name="level">Compression level controlling lazy evaluation depth.</param>
    /// <param name="writer">Stream writer that receives literal and match token output.</param>
    /// <param name="hasher">Match hasher used for match lookup.</param>
    /// <param name="sourceCursor">Pointer to the current read position in the source block.</param>
    /// <param name="safeSourceEnd">Pointer to the safe-to-read boundary (sourceEnd minus guard bytes).</param>
    /// <param name="sourceEnd">Pointer past the end of the source block.</param>
    /// <param name="recentOffset">Most recent match offset, updated on each match emitted.</param>
    /// <param name="dictionarySize">Maximum allowed match offset in bytes.</param>
    /// <param name="minimumMatchLengthTable">Table mapping offset magnitude to minimum match length.</param>
    /// <param name="minimumMatchLength">Global minimum match length threshold.</param>
    private static void RunLazyParser(int level, ref FastStreamWriter writer, MatchHasherBase hasher,
        byte* sourceCursor, byte* safeSourceEnd, byte* sourceEnd,
        ref nint recentOffset, int dictionarySize, uint* minimumMatchLengthTable, int minimumMatchLength)
    {
        byte* literalStart = sourceCursor;
        if (sourceCursor < safeSourceEnd - 5)
        {
            hasher.SetHashPos(sourceCursor);

            while (sourceCursor < safeSourceEnd - 5 - 1)
            {
                LengthAndOffset match = Matcher.FindMatchWithHasher(sourceCursor, safeSourceEnd, literalStart, recentOffset, hasher,
                    sourceCursor + 1, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                if (match.Length < 2)
                {
                    sourceCursor++;
                    continue;
                }
                while (sourceCursor + 1 < safeSourceEnd - 5)
                {
                    LengthAndOffset lazy1 = Matcher.FindMatchWithHasher(sourceCursor + 1, safeSourceEnd, literalStart, recentOffset, hasher,
                        sourceCursor + 2, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                    if (lazy1.Length >= 2 && Matcher.IsLazyMatchBetter(lazy1, match, 0))
                    {
                        sourceCursor += 1;
                        match = lazy1;
                    }
                    else
                    {
                        if (level <= 3 || sourceCursor + 2 > safeSourceEnd - 5 || match.Length == 2)
                            break;
                        LengthAndOffset lazy2 = Matcher.FindMatchWithHasher(sourceCursor + 2, safeSourceEnd, literalStart, recentOffset, hasher,
                            sourceCursor + 3, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                        if (lazy2.Length >= 2 && Matcher.IsLazyMatchBetter(lazy2, match, 1))
                        {
                            sourceCursor += 2;
                            match = lazy2;
                        }
                        else
                        {
                            break;
                        }
                    }
                }
                nint actualOffset = (match.Offset == 0) ? -recentOffset : match.Offset;

                // Extend match backward
                while (sourceCursor > literalStart && sourceCursor - hasher.SrcBase > actualOffset && sourceCursor[-1] == sourceCursor[-actualOffset - 1])
                {
                    sourceCursor--;
                    match.Length++;
                }

                Encoder.WriteOffsetWithLiteral1(ref writer, match.Length, (int)(sourceCursor - literalStart), match.Offset, recentOffset, literalStart);

                recentOffset = -actualOffset;
                sourceCursor += match.Length;
                literalStart = sourceCursor;

                if (sourceCursor >= safeSourceEnd - 5)
                    break;
                hasher.InsertRange(sourceCursor - match.Length, match.Length);
            }
        }
        Encoder.CopyTrailingLiterals(ref writer, literalStart, sourceEnd, recentOffset);
    }

    // ────────────────────────────────────────────────────────────────
    //  Lazy parser (MatchHasher2)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Lazy match parser using <see cref="MatchHasher2"/> with chain walking.
    /// </summary>
    /// <param name="level">Compression level controlling lazy evaluation depth.</param>
    /// <param name="writer">Stream writer that receives literal and match token output.</param>
    /// <param name="hasher">Chain-walking match hasher for improved match coverage.</param>
    /// <param name="sourceCursor">Pointer to the current read position in the source block.</param>
    /// <param name="safeSourceEnd">Pointer to the safe-to-read boundary (sourceEnd minus guard bytes).</param>
    /// <param name="sourceEnd">Pointer past the end of the source block.</param>
    /// <param name="recentOffset">Most recent match offset, updated on each match emitted.</param>
    /// <param name="dictionarySize">Maximum allowed match offset in bytes.</param>
    /// <param name="minimumMatchLengthTable">Table mapping offset magnitude to minimum match length.</param>
    /// <param name="minimumMatchLength">Global minimum match length threshold.</param>
    private static void RunLazyParserChainHasher(int level, ref FastStreamWriter writer, MatchHasher2 hasher,
        byte* sourceCursor, byte* safeSourceEnd, byte* sourceEnd,
        ref nint recentOffset, int dictionarySize, uint* minimumMatchLengthTable, int minimumMatchLength)
    {
        byte* literalStart = sourceCursor;
        if (sourceCursor < safeSourceEnd - 5)
        {
            hasher.SetHashPos(sourceCursor);

            while (sourceCursor < safeSourceEnd - 5 - 1)
            {
                LengthAndOffset match = Matcher.FindMatchWithChainHasher(sourceCursor, safeSourceEnd, literalStart, recentOffset, hasher,
                    sourceCursor + 1, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                if (match.Length < 2)
                {
                    sourceCursor++;
                    continue;
                }
                while (sourceCursor + 1 < safeSourceEnd - 5)
                {
                    LengthAndOffset lazy1 = Matcher.FindMatchWithChainHasher(sourceCursor + 1, safeSourceEnd, literalStart, recentOffset, hasher,
                        sourceCursor + 2, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                    if (lazy1.Length >= 2 && Matcher.IsLazyMatchBetter(lazy1, match, 0))
                    {
                        sourceCursor += 1;
                        match = lazy1;
                    }
                    else
                    {
                        if (level <= 3 || sourceCursor + 2 > safeSourceEnd - 5 || match.Length == 2)
                            break;
                        LengthAndOffset lazy2 = Matcher.FindMatchWithChainHasher(sourceCursor + 2, safeSourceEnd, literalStart, recentOffset, hasher,
                            sourceCursor + 3, dictionarySize, minimumMatchLength, minimumMatchLengthTable);
                        if (lazy2.Length >= 2 && Matcher.IsLazyMatchBetter(lazy2, match, 1))
                        {
                            sourceCursor += 2;
                            match = lazy2;
                        }
                        else
                        {
                            break;
                        }
                    }
                }
                nint actualOffset = (match.Offset == 0) ? -recentOffset : match.Offset;

                while (sourceCursor > literalStart && sourceCursor - hasher.SrcBase > actualOffset && sourceCursor[-1] == sourceCursor[-actualOffset - 1])
                {
                    sourceCursor--;
                    match.Length++;
                }

                Encoder.WriteOffsetWithLiteral1(ref writer, match.Length, (int)(sourceCursor - literalStart), match.Offset, recentOffset, literalStart);

                recentOffset = -actualOffset;
                sourceCursor += match.Length;
                literalStart = sourceCursor;

                if (sourceCursor >= safeSourceEnd - 5)
                    break;
                hasher.InsertRange(sourceCursor - match.Length, match.Length);
            }
        }
        Encoder.CopyTrailingLiterals(ref writer, literalStart, sourceEnd, recentOffset);
    }

    // ────────────────────────────────────────────────────────────────
    //  Block-level compression wrappers
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Compresses a source block using the greedy parser with <see cref="FastMatchHasher{T}"/>.
    /// Splits the source into up to two 64 KB sub-blocks.
    /// </summary>
    /// <param name="level">Compression level controlling skip factor and rehashing.</param>
    /// <param name="coder">Configured LZ coder with level, options, and hasher.</param>
    /// <param name="lztemp">Scratch buffers for entropy coding and output assembly.</param>
    /// <param name="source">Pointer to the source data.</param>
    /// <param name="sourceLength">Length of the source data in bytes.</param>
    /// <param name="destination">Pointer to the destination buffer for compressed output.</param>
    /// <param name="destinationEnd">Pointer past the end of the destination buffer.</param>
    /// <param name="startPosition">Offset of source from the window base.</param>
    /// <param name="chunkTypeOutput">Receives the selected chunk type.</param>
    /// <param name="costOutput">Receives the rate-distortion cost.</param>
    /// <returns>Number of compressed bytes written, or sourceLength if compression failed.</returns>
    public static int CompressGreedy<T>(int level, LzCoder coder, LzTemp lztemp,
        byte* source, int sourceLength, byte* destination, byte* destinationEnd, int startPosition, int* chunkTypeOutput, float* costOutput)
        where T : unmanaged, INumberBase<T>
    {
        *chunkTypeOutput = -1;
        *costOutput = StreamLZConstants.InvalidCost;
        if (sourceLength <= FastConstants.MinSourceLength)
            return sourceLength;

        bool useLiteralEntropyCoding = coder.UseLiteralEntropyCoding;

        var opts = coder.Options!;
        uint dictionarySize = FastConstants.GetEffectiveDictionarySize(opts);
        int minimumMatchLength = Math.Max(opts.MinMatchLength, 4);

        FastStreamWriter writer;
        FastStreamWriter.Initialize(&writer, sourceLength, source, useLiteralEntropyCoding && (level >= 0));
        try
        {
            uint* minimumMatchLengthTable = stackalloc uint[32];
            Matcher.BuildMinimumMatchLengthTable(minimumMatchLengthTable, minimumMatchLength, useLiteralEntropyCoding ? 10 : 14);
            int initialCopyBytes = (startPosition == 0) ? FastConstants.InitialCopyBytes : 0;

            if (!useLiteralEntropyCoding)
                writer.LiteralStart = writer.LiteralCursor = destination + 3 + initialCopyBytes;

            nint recentOffset = -8;
            var hasher = (FastMatchHasher<T>)coder.FastHasher!;

            for (int iteration = 0; iteration < 2; iteration++)
            {
                byte* sourceCursor;
                byte* blockEnd;

                if (iteration == 0)
                {
                    sourceCursor = source + initialCopyBytes;
                    blockEnd = source + writer.Block1Size;
                    writer.Block2StartOffset = 0;
                }
                else
                {
                    writer.TokenStream2Offset = (int)(writer.TokenCursor - writer.TokenStart);
                    if (writer.Block2Size == 0)
                        break;
                    sourceCursor = source + writer.Block1Size;
                    blockEnd = sourceCursor + writer.Block2Size;
                    writer.Block2StartOffset = writer.Block1Size;
                }
                writer.Offset32Count = 0;
                byte* safeEnd = blockEnd < source + sourceLength - 16 ? blockEnd : source + sourceLength - 16;
                RunGreedyParser(level, ref writer, hasher, sourceCursor, safeEnd, blockEnd,
                    ref recentOffset, (int)dictionarySize, minimumMatchLengthTable, minimumMatchLength,
                    source, startPosition);
                if (iteration == 0)
                    writer.Offset32CountBlock1 = writer.Offset32Count;
                else
                    writer.Offset32CountBlock2 = writer.Offset32Count;
            }
            int result = Encoder.AssembleCompressedOutput(costOutput, chunkTypeOutput, destination, destinationEnd, coder, lztemp, &writer, startPosition);
            return result;
        }
        finally
        {
            FastStreamWriter.FreeBuffers(&writer);
        }
    }

    /// <summary>
    /// Compresses a source block using the lazy parser with <see cref="MatchHasherBase"/>.
    /// </summary>
    /// <param name="level">Compression level controlling lazy evaluation depth.</param>
    /// <param name="coder">Configured LZ coder with level, options, and hasher.</param>
    /// <param name="lztemp">Scratch buffers for entropy coding and output assembly.</param>
    /// <param name="source">Pointer to the source data.</param>
    /// <param name="sourceLength">Length of the source data in bytes.</param>
    /// <param name="destination">Pointer to the destination buffer for compressed output.</param>
    /// <param name="destinationEnd">Pointer past the end of the destination buffer.</param>
    /// <param name="startPosition">Offset of source from the window base.</param>
    /// <param name="chunkTypeOutput">Receives the selected chunk type.</param>
    /// <param name="costOutput">Receives the rate-distortion cost.</param>
    /// <returns>Number of compressed bytes written, or sourceLength if compression failed.</returns>
    public static int CompressLazy(int level, LzCoder coder, LzTemp lztemp,
        byte* source, int sourceLength, byte* destination, byte* destinationEnd, int startPosition, int* chunkTypeOutput, float* costOutput)
    {
        *chunkTypeOutput = -1;
        *costOutput = StreamLZConstants.InvalidCost;
        if (sourceLength <= FastConstants.MinSourceLength)
            return sourceLength;

        bool useLiteralEntropyCoding = coder.UseLiteralEntropyCoding;

        var opts = coder.Options!;
        uint dictionarySize = FastConstants.GetEffectiveDictionarySize(opts);
        int minimumMatchLength = Math.Max(opts.MinMatchLength, 4);

        FastStreamWriter writer;
        FastStreamWriter.Initialize(&writer, sourceLength, source, useLiteralEntropyCoding && (level >= 0));
        try
        {
            uint* minimumMatchLengthTable = stackalloc uint[32];
            Matcher.BuildMinimumMatchLengthTable(minimumMatchLengthTable, minimumMatchLength, useLiteralEntropyCoding ? 10 : 14);
            int initialCopyBytes = (startPosition == 0) ? FastConstants.InitialCopyBytes : 0;

            if (!useLiteralEntropyCoding)
                writer.LiteralStart = writer.LiteralCursor = destination + 3 + initialCopyBytes;

            nint recentOffset = -8;
            var hasher = (MatchHasherBase)coder.Hasher!;

            for (int iteration = 0; iteration < 2; iteration++)
            {
                byte* sourceCursor;
                byte* blockEnd;

                if (iteration == 0)
                {
                    sourceCursor = source + initialCopyBytes;
                    blockEnd = source + writer.Block1Size;
                    writer.Block2StartOffset = 0;
                }
                else
                {
                    writer.TokenStream2Offset = (int)(writer.TokenCursor - writer.TokenStart);
                    if (writer.Block2Size == 0)
                        break;
                    sourceCursor = source + writer.Block1Size;
                    blockEnd = sourceCursor + writer.Block2Size;
                    writer.Block2StartOffset = writer.Block1Size;
                }
                writer.Offset32Count = 0;
                byte* safeEnd = blockEnd < source + sourceLength - 16 ? blockEnd : source + sourceLength - 16;
                RunLazyParser(level, ref writer, hasher, sourceCursor, safeEnd, blockEnd,
                    ref recentOffset, (int)dictionarySize, minimumMatchLengthTable, minimumMatchLength);
                if (iteration == 0)
                    writer.Offset32CountBlock1 = writer.Offset32Count;
                else
                    writer.Offset32CountBlock2 = writer.Offset32Count;
            }
            int result = Encoder.AssembleCompressedOutput(costOutput, chunkTypeOutput, destination, destinationEnd, coder, lztemp, &writer, startPosition);
            return result;
        }
        finally
        {
            FastStreamWriter.FreeBuffers(&writer);
        }
    }

    /// <summary>
    /// Compresses a source block using the lazy parser with <see cref="MatchHasher2"/>
    /// (chain walking for better match coverage).
    /// </summary>
    /// <param name="level">Compression level controlling lazy evaluation depth.</param>
    /// <param name="coder">Configured LZ coder with level, options, and hasher.</param>
    /// <param name="lztemp">Scratch buffers for entropy coding and output assembly.</param>
    /// <param name="source">Pointer to the source data.</param>
    /// <param name="sourceLength">Length of the source data in bytes.</param>
    /// <param name="destination">Pointer to the destination buffer for compressed output.</param>
    /// <param name="destinationEnd">Pointer past the end of the destination buffer.</param>
    /// <param name="startPosition">Offset of source from the window base.</param>
    /// <param name="chunkTypeOutput">Receives the selected chunk type.</param>
    /// <param name="costOutput">Receives the rate-distortion cost.</param>
    /// <returns>Number of compressed bytes written, or sourceLength if compression failed.</returns>
    public static int CompressLazyChainHasher(int level, LzCoder coder, LzTemp lztemp,
        byte* source, int sourceLength, byte* destination, byte* destinationEnd, int startPosition, int* chunkTypeOutput, float* costOutput)
    {
        *chunkTypeOutput = -1;
        *costOutput = StreamLZConstants.InvalidCost;
        if (sourceLength <= FastConstants.MinSourceLength)
            return sourceLength;

        bool useLiteralEntropyCoding = coder.UseLiteralEntropyCoding;

        var opts = coder.Options!;
        uint dictionarySize = FastConstants.GetEffectiveDictionarySize(opts);
        int minimumMatchLength = Math.Max(opts.MinMatchLength, 4);

        FastStreamWriter writer;
        FastStreamWriter.Initialize(&writer, sourceLength, source, useLiteralEntropyCoding && (level >= 0));
        try
        {
            uint* minimumMatchLengthTable = stackalloc uint[32];
            Matcher.BuildMinimumMatchLengthTable(minimumMatchLengthTable, minimumMatchLength, useLiteralEntropyCoding ? 10 : 14);
            int initialCopyBytes = (startPosition == 0) ? FastConstants.InitialCopyBytes : 0;

            if (!useLiteralEntropyCoding)
                writer.LiteralStart = writer.LiteralCursor = destination + 3 + initialCopyBytes;

            nint recentOffset = -8;
            var hasher = (MatchHasher2)coder.FastHasher!;

            for (int iteration = 0; iteration < 2; iteration++)
            {
                byte* sourceCursor;
                byte* blockEnd;

                if (iteration == 0)
                {
                    sourceCursor = source + initialCopyBytes;
                    blockEnd = source + writer.Block1Size;
                    writer.Block2StartOffset = 0;
                }
                else
                {
                    writer.TokenStream2Offset = (int)(writer.TokenCursor - writer.TokenStart);
                    if (writer.Block2Size == 0)
                        break;
                    sourceCursor = source + writer.Block1Size;
                    blockEnd = sourceCursor + writer.Block2Size;
                    writer.Block2StartOffset = writer.Block1Size;
                }
                writer.Offset32Count = 0;
                byte* safeEnd = blockEnd < source + sourceLength - 16 ? blockEnd : source + sourceLength - 16;
                RunLazyParserChainHasher(level, ref writer, hasher, sourceCursor, safeEnd, blockEnd,
                    ref recentOffset, (int)dictionarySize, minimumMatchLengthTable, minimumMatchLength);
                if (iteration == 0)
                    writer.Offset32CountBlock1 = writer.Offset32Count;
                else
                    writer.Offset32CountBlock2 = writer.Offset32Count;
            }
            int result = Encoder.AssembleCompressedOutput(costOutput, chunkTypeOutput, destination, destinationEnd, coder, lztemp, &writer, startPosition);
            return result;
        }
        finally
        {
            FastStreamWriter.FreeBuffers(&writer);
        }
    }
}
