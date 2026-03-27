// OptimalParser.cs — Greedy stats pass, state-update helpers, and DP optimal parser for the High compressor.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    private static int CollectStatistics(float* costPtr, int* chunkTypePtr, Stats* stats,
        byte* destination, byte* destinationEnd,
        int minMatchLen,
        LzCoder lzcoder, LengthAndOffset* matchTable,
        byte* source, int sourceLength, int startPos, byte* windowBase,
        LzTemp lztemp)
    {
        *stats = default;

        HighRecentOffs recent = HighRecentOffs.Create();
        HighStreamWriter writer = default;
        InitializeStreamWriter(ref writer, lztemp, sourceLength, source, lzcoder.EncodeFlags);

        int initialCopyBytes = (startPos == 0) ? 8 : 0;
        int pos = initialCopyBytes, lastPos = initialCopyBytes;
        var opts = lzcoder.Options!;
        int dictSize = opts.DictionarySize > 0 && opts.DictionarySize <= StreamLZConstants.MaxDictionarySize
            ? opts.DictionarySize : StreamLZConstants.MaxDictionarySize;

        while (pos < sourceLength - 16)
        {
            LengthAndOffset m0 = GetBestMatch(&matchTable[4 * pos], &recent, &source[pos], &source[sourceLength - 8],
                minMatchLen, pos - lastPos, windowBase, dictSize);
            if (m0.Length == 0)
            {
                pos++;
                continue;
            }

            // Lazy matching: try pos+1, pos+2
            while (pos + 1 < sourceLength - 16)
            {
                LengthAndOffset m1 = GetBestMatch(&matchTable[4 * (pos + 1)], &recent, &source[pos + 1], &source[sourceLength - 8],
                    minMatchLen, pos + 1 - lastPos, windowBase, dictSize);

                if (m1.Length != 0 && MatchUtils.GetLazyScore(m1, m0) > 0)
                {
                    pos++;
                    m0 = m1;
                }
                else
                {
                    if (pos + 2 >= sourceLength - 16)
                    {
                        break;
                    }
                    LengthAndOffset m2 = GetBestMatch(&matchTable[4 * (pos + 2)], &recent, &source[pos + 2], &source[sourceLength - 8],
                        minMatchLen, pos + 2 - lastPos, windowBase, dictSize);
                    if (m2.Length != 0 && MatchUtils.GetLazyScore(m2, m0) > 3)
                    {
                        pos += 2;
                        m0 = m2;
                    }
                    else
                    {
                        break;
                    }
                }
            }

            if (pos - lastPos == 0 && m0.Offset == 0 && recent.Offs[4] == recent.Offs[5])
            {
                m0.Offset = -1;
            }

            AddToken(ref writer, ref recent, source + lastPos, pos - lastPos, m0.Length, m0.Offset,
                doRecent: true, doSubtract: true);
            pos += m0.Length;
            lastPos = pos;
        }

        AddFinalLiterals(ref writer, source + lastPos, source + sourceLength, doSubtract: true);

        // Use a clone with reduced options to avoid mutating the caller's LzCoder.
        // CloneForThread copies all fields; we only need to override two.
        using var reducedCoder = lzcoder.CloneForThread();
        reducedCoder.EntropyOptions &= ~(int)EntropyOptions.AllowMultiArray;
        reducedCoder.CompressionLevel = 4;
        return AssembleCompressedOutput(costPtr, chunkTypePtr, stats, destination, destinationEnd, reducedCoder, lztemp, ref writer, startPos);
    }

    /// <summary>
    /// Try to improve state <paramref name="stateIdx"/> with a new path.
    /// <paramref name="isRecent"/> controls whether the offset is a recent-offset index or a raw offset.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static bool UpdateState(int stateIdx, int bits, int literalRunLength, int matchLength, int recent, int prevState,
        int qrm, State* states, bool isRecent)
    {
        State* st = &states[stateIdx];
        if (bits < st->BestBitCount)
        {
            st->BestBitCount = bits;
            st->LitLen = literalRunLength;
            st->MatchLen = matchLength;

            int r0 = states[prevState].RecentOffs0;
            int r1 = states[prevState].RecentOffs1;
            int r2 = states[prevState].RecentOffs2;

            if (isRecent)
            {
                Debug.Assert(recent >= 0 && recent <= 2);
                if (recent == 0)
                {
                    st->RecentOffs0 = r0;
                    st->RecentOffs1 = r1;
                    st->RecentOffs2 = r2;
                }
                else if (recent == 1)
                {
                    st->RecentOffs0 = r1;
                    st->RecentOffs1 = r0;
                    st->RecentOffs2 = r2;
                }
                else
                {
                    st->RecentOffs0 = r2;
                    st->RecentOffs1 = r0;
                    st->RecentOffs2 = r1;
                }
            }
            else
            {
                st->RecentOffs0 = recent;
                st->RecentOffs1 = r0;
                st->RecentOffs2 = r1;
            }
            st->QuickRecentMatchLenLitLen = qrm;
            st->PrevState = prevState;
            return true;
        }
        return false;
    }

    /// <summary>
    /// Update the stateWidth-wide state band (multi-state DP).
    /// </summary>
    private static void UpdateStatesZ(int pos, int bits, int literalRunLength, int matchLength, int recent, int prevState,
        State* states, byte* source, int offset, int stateWidth, ref CostModel costModel, int* litindexes, bool isRecent)
    {
        int afterMatch = pos + matchLength;
        UpdateState(afterMatch * stateWidth, bits, literalRunLength, matchLength, recent, prevState, 0, states, isRecent);
        for (int jj = 1; jj < stateWidth; jj++)
        {
            bits += (int)BitsForLiteral(source, afterMatch + jj - 1, offset, ref costModel, jj - 1);
            if (UpdateState((afterMatch + jj) * stateWidth + jj, bits, literalRunLength, matchLength, recent, prevState, 0, states, isRecent) && jj == stateWidth - 1)
            {
                litindexes[afterMatch + jj] = jj;
            }
        }
    }

    /// <summary>
    /// Optimal parser entry point. Performs multiple outer iterations of:
    ///   1) Build cost model from stats
    ///   2) Run forward DP to find cheapest parse
    ///   3) Back-trace to extract tokens
    ///   4) Encode tokens and check if cost improved
    /// </summary>
    [SkipLocalsInit]
    public static int Optimal(LzCoder lzcoder, LzTemp lztemp,
        ManagedMatchLenStorage? mls,
        byte* source, int srcSize,
        byte* destination, byte* destinationEnd, int startPos,
        int* chunkTypePtr, float* costPtr,
        ExportedTokens? exportedTokens = null)
    {
        *chunkTypePtr = 0;
        if (srcSize <= 128)
        {
            return -1;
        }

        int stateWidth = (lzcoder.CompressionLevel >= 8) ? 2 : 1;
        int fourOrEight = (lzcoder.CompressionLevel >= 6) ? 8 : 4;

        var opts2 = lzcoder.Options!;
        int dictSize = opts2.DictionarySize > 0 && opts2.DictionarySize <= StreamLZConstants.MaxDictionarySize
            ? opts2.DictionarySize : StreamLZConstants.MaxDictionarySize;

        bool sc = opts2.SelfContained;
        int scPosInChunk = startPos & (StreamLZConstants.ChunkSize - 1);
        int initialCopyBytes = (startPos == 0) ? 8 : 0;
        byte* srcEndSafe = source + srcSize - 8;
        int minMatchLength = Math.Max(opts2.MinMatchLength, 4);
        int lengthLongEnoughThres = 1 << Math.Min(8, lzcoder.CompressionLevel);

        // windowBase = source for the optimal parser (matches are relative to current chunk)
        byte* windowBase = source;

        // Reuse LAO buffer across chunks to avoid LOH pressure
        var laoManaged = lztemp.GetLaoBuffer(4 * srcSize);
        if (mls != null)
        {
            // MLS index = startPos relative to the round start (MLS indices are 0-based from round start)
            int mlsStart = startPos - mls.RoundStartPos;
            MatchFinder.ExtractLaoFromMls(mls, mlsStart, srcSize, laoManaged, 4);
        }

        // Self-contained: filter out matches that cross chunk boundaries, compacting valid entries
        if (sc)
        {
            int posInChunk = startPos & (StreamLZConstants.ChunkSize - 1);
            for (int pos = 0; pos < srcSize; pos++)
            {
                int baseIdx = 4 * pos;
                int maxBack = posInChunk + pos;
                int dst = 0;
                for (int j = 0; j < 4; j++)
                {
                    if (laoManaged[baseIdx + j].Length == 0)
                    {
                        break;
                    }
                    if (laoManaged[baseIdx + j].Offset <= maxBack)
                    {
                        if (dst != j)
                        {
                            laoManaged[baseIdx + dst] = laoManaged[baseIdx + j];
                        }
                        dst++;
                    }
                }
                for (int j = dst; j < 4; j++)
                {
                    laoManaged[baseIdx + j] = default;
                }
            }
        }

        // Token arrays
        TokenArray lzTokenArray;
        lzTokenArray.Capacity = srcSize / 2 + 8;
        lzTokenArray.Size = 0;
        byte[] tok2Buf = lztemp.LzToken2Scratch.Allocate(sizeof(Token) * lzTokenArray.Capacity);

        int tokensCapacity = 4096 + 8;
        byte[] tokBuf = lztemp.LzTokenScratch.Allocate(sizeof(Token) * tokensCapacity);
        Token* tokensBegin;

        int stateAllocSize = sizeof(State) * stateWidth * (srcSize + 1);
        byte[] stateBuf = lztemp.States.Allocate(stateAllocSize);

        int tmpChunkType;
        CostModel costModel = default;

        int[]? litindexesArr = null;
        int* litindexes = null;

        if (stateWidth > 1)
        {
            litindexesArr = lztemp.GetLitIndexesBuffer(srcSize + 1);
        }

        int outerLoopIndex = 0;

        // Pin all arrays for the entire function to avoid dangling pointers
        fixed (LengthAndOffset* pLaoPin = laoManaged)
        fixed (byte* pTok2Pin = tok2Buf)
        fixed (byte* pTokPin = tokBuf)
        fixed (byte* pStatePin = stateBuf)
        {
            LengthAndOffset* matchTable = pLaoPin;
            lzTokenArray.Data = (Token*)pTok2Pin;
            tokensBegin = (Token*)pTokPin;
            State* states = (State*)pStatePin;
            byte* tmpDst = pStatePin;
            byte* tmpDstEnd = tmpDst + lztemp.States.Size;

            Stats stats = default, tmpStats;

            float cost = StreamLZConstants.InvalidCost;
            int nFirst = CollectStatistics(&cost, chunkTypePtr, &stats,
                destination, destinationEnd,
                minMatchLength,
                lzcoder, matchTable, source, srcSize,
                startPos, windowBase, lztemp);
            if (nFirst >= srcSize)
            {
                return -1;
            }

            float bestCost = cost;
            int bestLength = nFirst;

            // Try min_match_length = 3 for level >= 7
            if (lzcoder.CompressionLevel >= 7 && opts2.MinMatchLength <= 3)
            {
                cost = StreamLZConstants.InvalidCost;
                int tmpCT;
                tmpStats = default;
                int n = CollectStatistics(&cost, &tmpCT, &tmpStats,
                    tmpDst, tmpDstEnd,
                    3, lzcoder, matchTable, source, srcSize,
                    startPos, windowBase, lztemp);
                if (cost < bestCost && n < srcSize)
                {
                    *chunkTypePtr = tmpCT;
                    Buffer.MemoryCopy(tmpDst, destination, destinationEnd - destination, n);
                    bestCost = cost;
                    bestLength = n;
                    minMatchLength = 3;
                    stats = tmpStats;
                }
            }

            // Try min_match_length = 8
            if (opts2.MinMatchLength < 8)
            {
                cost = StreamLZConstants.InvalidCost;
                int tmpCT;
                tmpStats = default;
                int n = CollectStatistics(&cost, &tmpCT, &tmpStats,
                    tmpDst, tmpDstEnd,
                    8, lzcoder, matchTable, source, srcSize,
                    startPos, windowBase, lztemp);
                if (cost < bestCost && n < srcSize)
                {
                    *chunkTypePtr = tmpCT;
                    Buffer.MemoryCopy(tmpDst, destination, destinationEnd - destination, n);
                    bestCost = cost;
                    bestLength = n;
                    stats = tmpStats;
                }
            }

            if (lzcoder.CompressionLevel >= 7)
            {
                minMatchLength = Math.Max(opts2.MinMatchLength, 3);
            }
            tmpDst = (byte*)pStatePin;
            tmpDstEnd = tmpDst + lztemp.States.Size;

            // Allocate match scratch outside all loops to avoid stack overflow (CA2014)
            LengthAndOffset* matchArr = stackalloc LengthAndOffset[8];
            int* matchFoundOffsetBits = stackalloc int[8];

            fixed (int* pLitIdx = litindexesArr)
            {
                litindexes = pLitIdx;

                for (; ; )
                {
                    costModel.ChunkType = *chunkTypePtr;
                    costModel.SubOrCopyMask = (*chunkTypePtr != 1) ? -1 : 0;

                    if (lzcoder.LastChunkType < 0)
                    {
                        RescaleStats(ref stats);
                    }
                    else
                    {
                        // Retrieve previous stats from scratch
                        fixed (byte* pPrev = lzcoder.SymbolStatisticsScratch.Buffer)
                        {
                            Stats* h2 = (Stats*)pPrev;
                            RescaleAddStats(ref stats, ref *h2, lzcoder.LastChunkType == *chunkTypePtr);
                        }
                    }

                    costModel.OffsEncodeType = stats.OffsEncodeType;
                    MakeCostModel(ref stats, ref costModel);

                    for (int i = 0; i <= stateWidth * srcSize; i++)
                    {
                        states[i].BestBitCount = int.MaxValue;
                    }

                    int finalLzOffset = -1;
                    int lastRecent0 = 0;
                    lzTokenArray.Size = 0;
                    int chunkStart = initialCopyBytes;

                    // Initial state
                    states[stateWidth * chunkStart].Initialize();

                    while (chunkStart < srcSize - 16)
                    {
                        int litBitsSincePrev = 0;
                        int prevOffset = chunkStart;

                        int chunkEnd = chunkStart + MaxBytesPerRound;
                        if (chunkEnd >= srcSize - 32)
                        {
                            chunkEnd = srcSize - 16;
                        }

                        int maxOffset = chunkStart + MinBytesPerRound;
                        if (maxOffset >= srcSize - 32)
                        {
                            maxOffset = srcSize - 16;
                        }

                        int bitsForEncodingOffset8 = (int)BitsForOffset(ref costModel, 8);

                        // stateWidth > 1 initialization
                        if (stateWidth > 1)
                        {
                            for (int i = 1; i < stateWidth; i++)
                            {
                                for (int j = 0; j < stateWidth; j++)
                                {
                                    states[stateWidth * (chunkStart + i) + j].BestBitCount = int.MaxValue;
                                }
                            }

                            for (int j = 1; j < stateWidth; j++)
                            {
                                states[stateWidth * chunkStart + j].BestBitCount = int.MaxValue;
                            }

                            if (maxOffset - chunkStart > stateWidth)
                            {
                                for (int i = 1; i < stateWidth; i++)
                                {
                                    states[(chunkStart + i) * stateWidth + i] = states[(chunkStart + i - 1) * stateWidth + i - 1];
                                    states[(chunkStart + i) * stateWidth + i].BestBitCount +=
                                        (int)BitsForLiteral(source, chunkStart + i - 1, states[chunkStart * stateWidth].RecentOffs0, ref costModel, i - 1);
                                }
                                litindexes[chunkStart + stateWidth - 1] = stateWidth - 1;
                            }
                            else
                            {
                                chunkStart = srcSize - 16;
                            }
                        }

                        // ── Phase 1: Forward cost propagation ──
                        // Walk forward through positions, evaluating all matches and
                        // literal-run options, propagating minimum-cost states via DP.
                        for (int pos = chunkStart; maxOffset <= chunkEnd; pos++)
                        {
                            if (pos == srcSize - 16)
                            {
                                maxOffset = pos;
                                break;
                            }

                            byte* srcCur = &source[pos];
                            uint u32AtCur = *(uint*)srcCur;

                            if (stateWidth == 1)
                            {
                                if (pos != prevOffset)
                                {
                                    litBitsSincePrev += (int)BitsForLiteral(source, pos - 1, states[prevOffset].RecentOffs0, ref costModel, pos - prevOffset - 1);
                                    int curbits = states[pos].BestBitCount;
                                    if (curbits != int.MaxValue)
                                    {
                                        int prevbits = states[prevOffset].BestBitCount + litBitsSincePrev;
                                        if (curbits < prevbits + (int)BitsForLiteralLength(ref costModel, pos - prevOffset))
                                        {
                                            prevOffset = pos;
                                            litBitsSincePrev = 0;
                                            if (pos >= maxOffset)
                                            {
                                                maxOffset = pos;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                            else // stateWidth > 1
                            {
                                if (pos >= maxOffset)
                                {
                                    int tmpCurOffset = 0;
                                    int bestBits = 0x7FFFFFFF;
                                    for (int i = 0; i < stateWidth; i++)
                                    {
                                        if (states[stateWidth * pos + i].BestBitCount < bestBits)
                                        {
                                            bestBits = states[stateWidth * pos + i].BestBitCount;
                                            tmpCurOffset = pos - ((i != stateWidth - 1) ? i : litindexes[pos]);
                                        }
                                    }
                                    if (tmpCurOffset >= maxOffset)
                                    {
                                        maxOffset = tmpCurOffset;
                                        break;
                                    }
                                }
                                State* cur = &states[stateWidth * pos + stateWidth - 1];
                                if (cur->BestBitCount != 0x7FFFFFFF)
                                {
                                    int bits2 = cur->BestBitCount + (int)BitsForLiteral(source, pos, cur->RecentOffs0, ref costModel, litindexes[pos]);
                                    if (bits2 < cur[stateWidth].BestBitCount)
                                    {
                                        cur[stateWidth] = *cur;
                                        cur[stateWidth].BestBitCount = bits2;
                                        litindexes[pos + 1] = litindexes[pos] + 1;
                                    }
                                }
                            }

                            // Extract matches from the match table
                            int numMatch = 0;
                            int scMaxBack = sc ? (scPosInChunk + pos) : int.MaxValue;

                            for (int laoIndex = 0; laoIndex < 4; laoIndex++)
                            {
                                uint laoMl = (uint)matchTable[4 * pos + laoIndex].Length;
                                uint laoOffs = (uint)matchTable[4 * pos + laoIndex].Offset;
                                if (laoMl < (uint)minMatchLength)
                                {
                                    break;
                                }
                                laoMl = Math.Min(laoMl, (uint)(srcEndSafe - srcCur));
                                if (laoOffs >= (uint)dictSize)
                                {
                                    continue;
                                }
                                if ((int)laoOffs > scMaxBack)
                                {
                                    continue;
                                }

                                if (laoOffs < 8)
                                {
                                    uint tt = laoOffs;
                                    do laoOffs += tt; while (laoOffs < 8);
                                    if (laoOffs > (uint)(srcCur - windowBase))
                                    {
                                        continue;
                                    }
                                    if ((int)laoOffs > scMaxBack)
                                    {
                                        continue;
                                    }
                                    laoMl = (uint)MatchUtils.GetMatchLengthQuickMin4(srcCur, (int)laoOffs, srcEndSafe, u32AtCur);
                                    if (laoMl < (uint)minMatchLength)
                                    {
                                        continue;
                                    }
                                }

                                if (CheckMatchValidLength(laoMl, laoOffs))
                                {
                                    matchArr[numMatch].Length = (int)laoMl;
                                    matchArr[numMatch].Offset = (int)laoOffs;
                                    matchFoundOffsetBits[numMatch++] = (int)BitsForOffset(ref costModel, laoOffs);
                                }
                            }

                            // Also always check offset 8
                            int length = (8 <= scMaxBack) ? MatchUtils.GetMatchLengthQuickMin3(srcCur, 8, srcEndSafe, u32AtCur) : 0;
                            if (length >= minMatchLength)
                            {
                                matchArr[numMatch].Length = length;
                                matchArr[numMatch].Offset = 8;
                                matchFoundOffsetBits[numMatch++] = bitsForEncodingOffset8;
                            }

                            int bestLengthSoFar = 0;
                            int litsSincePrev = pos - prevOffset;
                            int bestBitsY = 0x7FFFFFFF;

                            // For each literal-run length
                            for (int lazy = 0; lazy <= fourOrEight; lazy++)
                            {
                                int literalRunLength, totalBits, prevState;

                                if (stateWidth == 1)
                                {
                                    literalRunLength = (lazy == fourOrEight && litsSincePrev > fourOrEight) ? litsSincePrev : lazy;
                                    if (pos - literalRunLength < chunkStart)
                                    {
                                        break;
                                    }
                                    prevState = pos - literalRunLength;
                                    totalBits = states[prevState].BestBitCount;
                                    if (totalBits == int.MaxValue)
                                    {
                                        continue;
                                    }
                                    totalBits += (literalRunLength == litsSincePrev)
                                        ? litBitsSincePrev
                                        : (int)BitsForLiterals(source, pos - literalRunLength, literalRunLength, states[prevState].RecentOffs0, ref costModel, 0);
                                }
                                else
                                {
                                    if (lazy < stateWidth)
                                    {
                                        prevState = stateWidth * pos + lazy;
                                        totalBits = states[prevState].BestBitCount;
                                        if (totalBits == int.MaxValue)
                                        {
                                            continue;
                                        }
                                        literalRunLength = (lazy == stateWidth - 1) ? litindexes[pos] : lazy;
                                    }
                                    else
                                    {
                                        literalRunLength = lazy - 1;
                                        if (pos - literalRunLength < chunkStart)
                                        {
                                            break;
                                        }
                                        prevState = stateWidth * (pos - literalRunLength);
                                        totalBits = states[prevState].BestBitCount;
                                        if (totalBits == int.MaxValue)
                                        {
                                            continue;
                                        }
                                        totalBits += (int)BitsForLiterals(source, pos - literalRunLength, literalRunLength, states[prevState].RecentOffs0, ref costModel, 0);
                                    }
                                }

                                int lengthField = literalRunLength;
                                if (literalRunLength >= 3)
                                {
                                    lengthField = 3;
                                    totalBits += (int)BitsForLiteralLength(ref costModel, literalRunLength);
                                }

                                int recentBestLength = 0;

                                // For each recent offset
                                for (int ridx = 0; ridx < RecentOffsetCount; ridx++)
                                {
                                    int offs = states[prevState].GetRecentOffs(ridx);
                                    if (offs > scMaxBack)
                                    {
                                        continue;
                                    }
                                    int recentMatchLength = MatchUtils.GetMatchLengthQuick(srcCur, offs, srcEndSafe, u32AtCur);
                                    if (recentMatchLength <= recentBestLength)
                                    {
                                        continue;
                                    }
                                    recentBestLength = recentMatchLength;
                                    maxOffset = Math.Max(maxOffset, pos + recentMatchLength);
                                    int fullBits = totalBits + BitsForToken(ref costModel, recentMatchLength, pos - literalRunLength, ridx, lengthField);
                                    UpdateStatesZ(pos, fullBits, literalRunLength, recentMatchLength, ridx, prevState, states, source, offs, stateWidth, ref costModel, litindexes, isRecent: true);

                                    if (recentMatchLength > 2 && recentMatchLength < lengthLongEnoughThres)
                                    {
                                        for (int trialMatchLength = 2; trialMatchLength < recentMatchLength; trialMatchLength++)
                                        {
                                            UpdateStatesZ(pos, totalBits + BitsForToken(ref costModel, trialMatchLength, pos - literalRunLength, ridx, lengthField),
                                                literalRunLength, trialMatchLength, ridx, prevState, states, source, offs, stateWidth, ref costModel, litindexes, isRecent: true);
                                        }
                                    }

                                    // Check for recent0 match after 1-2 literals
                                    if (pos + recentMatchLength + 4 < srcSize - 16)
                                    {
                                        for (int numLazy = 1; numLazy <= 2; numLazy++)
                                        {
                                            int trialMatchLength = MatchUtils.GetMatchLengthMin2(srcCur + recentMatchLength + numLazy, offs, srcEndSafe);
                                            if (trialMatchLength != 0)
                                            {
                                                int cost2 = fullBits +
                                                    (int)BitsForLiterals(source, pos + recentMatchLength, numLazy, offs, ref costModel, 0) +
                                                    BitsForToken(ref costModel, trialMatchLength, pos + recentMatchLength, 0, numLazy);
                                                maxOffset = Math.Max(maxOffset, pos + recentMatchLength + trialMatchLength + numLazy);
                                                UpdateState((pos + recentMatchLength + trialMatchLength + numLazy) * stateWidth,
                                                    cost2, literalRunLength, recentMatchLength, ridx, prevState, numLazy | (trialMatchLength << 8), states, isRecent: true);
                                                break;
                                            }
                                        }
                                    }
                                }

                                bestLengthSoFar = Math.Max(bestLengthSoFar, recentBestLength);
                                if (bestLengthSoFar >= lengthLongEnoughThres)
                                {
                                    break;
                                }

                                if (totalBits < bestBitsY)
                                {
                                    bestBitsY = totalBits;

                                    // For each match entry
                                    for (int matchidx = 0; matchidx < numMatch; matchidx++)
                                    {
                                        int maxMatchLength = matchArr[matchidx].Length;
                                        int moffs = matchArr[matchidx].Offset;
                                        if (maxMatchLength <= recentBestLength)
                                        {
                                            break;
                                        }
                                        int afterMatch = pos + maxMatchLength;
                                        bestLengthSoFar = Math.Max(bestLengthSoFar, maxMatchLength);
                                        maxOffset = Math.Max(maxOffset, afterMatch);
                                        int bitsWithOfflen = totalBits + matchFoundOffsetBits[matchidx];
                                        int fullBits = bitsWithOfflen + BitsForToken(ref costModel, maxMatchLength, pos - literalRunLength, RecentOffsetCount, lengthField);

                                        UpdateStatesZ(pos, fullBits, literalRunLength, maxMatchLength, moffs, prevState, states, source, moffs, stateWidth, ref costModel, litindexes, isRecent: false);

                                        if (maxMatchLength > minMatchLength && maxMatchLength < lengthLongEnoughThres)
                                        {
                                            for (int trialMatchLength = minMatchLength; trialMatchLength < maxMatchLength; trialMatchLength++)
                                            {
                                                UpdateStatesZ(pos, bitsWithOfflen + BitsForToken(ref costModel, trialMatchLength, pos - literalRunLength, RecentOffsetCount, lengthField),
                                                    literalRunLength, trialMatchLength, moffs, prevState, states, source, moffs, stateWidth, ref costModel, litindexes, isRecent: false);
                                            }
                                        }

                                        // Check for recent0 match after 1-2 literals
                                        if (afterMatch + 4 < srcSize - 16)
                                        {
                                            for (int numLazy = 1; numLazy <= 2; numLazy++)
                                            {
                                                int trialMatchLength = MatchUtils.GetMatchLengthMin2(srcCur + maxMatchLength + numLazy, moffs, srcEndSafe);
                                                if (trialMatchLength != 0)
                                                {
                                                    int cost2 = fullBits +
                                                        (int)BitsForLiterals(source, afterMatch, numLazy, moffs, ref costModel, 0) +
                                                        BitsForToken(ref costModel, trialMatchLength, afterMatch, 0, numLazy);
                                                    maxOffset = Math.Max(maxOffset, afterMatch + trialMatchLength + numLazy);
                                                    UpdateState((afterMatch + trialMatchLength + numLazy) * stateWidth,
                                                        cost2, literalRunLength, maxMatchLength, moffs, prevState, numLazy | (trialMatchLength << 8), states, isRecent: false);
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Length is long enough to skip
                            if (bestLengthSoFar >= lengthLongEnoughThres)
                            {
                                int currentEnd = bestLengthSoFar + pos;
                                if (maxOffset == currentEnd)
                                {
                                    maxOffset = prevOffset = currentEnd;
                                    break;
                                }
                                if (stateWidth == 1)
                                {
                                    litBitsSincePrev = 0;
                                    prevOffset = currentEnd;
                                }
                                else
                                {
                                    int recentOffs = states[currentEnd * stateWidth].RecentOffs0;
                                    for (int i = 1; i < stateWidth; i++)
                                    {
                                        states[(currentEnd + i) * stateWidth + i] = states[(currentEnd + i - 1) * stateWidth + i - 1];
                                        states[(currentEnd + i) * stateWidth + i].BestBitCount +=
                                            (int)BitsForLiteral(source, currentEnd + i - 1, recentOffs, ref costModel, i - 1);
                                    }
                                    litindexes[currentEnd + stateWidth - 1] = stateWidth - 1;
                                }
                                pos = currentEnd - 1;
                            }
                        } // for (maxOffset <= chunkEnd)

                        int lastStateIndex = stateWidth * maxOffset;
                        bool reachedEnd = maxOffset >= srcSize - 18;

                        if (reachedEnd)
                        {
                            int bestBits = int.MaxValue;
                            if (stateWidth == 1)
                            {
                                for (int finalOffs = Math.Max(chunkStart, prevOffset - 8); finalOffs < srcSize; finalOffs++)
                                {
                                    int bits = states[finalOffs].BestBitCount;
                                    if (bits != int.MaxValue)
                                    {
                                        bits += (int)BitsForLiterals(source, finalOffs, srcSize - finalOffs, states[finalOffs].RecentOffs0, ref costModel, 0);
                                        if (bits < bestBits)
                                        {
                                            bestBits = bits;
                                            finalLzOffset = finalOffs;
                                            lastStateIndex = finalOffs;
                                        }
                                    }
                                }
                            }
                            else
                            {
                                for (int finalOffs = Math.Max(chunkStart, maxOffset - 8); finalOffs < srcSize; finalOffs++)
                                {
                                    for (int idx = 0; idx < stateWidth; idx++)
                                    {
                                        int bits = states[stateWidth * finalOffs + idx].BestBitCount;
                                        if (bits != int.MaxValue)
                                        {
                                            int litidx = (idx == stateWidth - 1) ? litindexes[finalOffs] : idx;
                                            int offs = finalOffs - litidx;
                                            if (offs >= chunkStart)
                                            {
                                                bits += (int)BitsForLiterals(source, finalOffs, srcSize - finalOffs, states[stateWidth * finalOffs + idx].RecentOffs0, ref costModel, litidx);
                                                if (bits < bestBits)
                                                {
                                                    bestBits = bits;
                                                    finalLzOffset = offs;
                                                    lastStateIndex = stateWidth * finalOffs + idx;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            maxOffset = finalLzOffset;
                            lastRecent0 = states[lastStateIndex].RecentOffs0;
                        }

                        // ── Phase 2: Backward token extraction ──
                        // Walk backward through the state chain to recover the
                        // optimal sequence of (literal-run, match) tokens.
                        int outoffs = maxOffset;
                        int numTokens = 0;
                        State* stateCur = &states[lastStateIndex];
                        State* statePrev;

                        while (outoffs != chunkStart)
                        {
                            uint qrm = (uint)stateCur->QuickRecentMatchLenLitLen;
                            if (qrm != 0)
                            {
                                outoffs = outoffs - (int)(qrm >> 8) - (int)((byte)qrm);
                                Debug.Assert(numTokens < tokensCapacity);
                                tokensBegin[numTokens].RecentOffset0 = stateCur->RecentOffs0;
                                tokensBegin[numTokens].Offset = 0;
                                tokensBegin[numTokens].MatchLen = (int)(qrm >> 8);
                                tokensBegin[numTokens].LitLen = (byte)qrm;
                                numTokens++;
                            }
                            outoffs = outoffs - stateCur->LitLen - stateCur->MatchLen;
                            statePrev = &states[stateCur->PrevState];
                            int recent0 = stateCur->RecentOffs0;
                            int recentIndex = GetRecentOffsetIndex(ref *statePrev, recent0);
                            Debug.Assert(numTokens < tokensCapacity);
                            tokensBegin[numTokens].RecentOffset0 = statePrev->RecentOffs0;
                            tokensBegin[numTokens].LitLen = stateCur->LitLen;
                            tokensBegin[numTokens].MatchLen = stateCur->MatchLen;
                            tokensBegin[numTokens].Offset = (recentIndex >= 0) ? -recentIndex : recent0;
                            numTokens++;
                            stateCur = statePrev;
                        }

                        // Reverse the token array
                        for (int lo = 0, hi = numTokens - 1; lo < hi; lo++, hi--)
                        {
                            Token tmp = tokensBegin[lo];
                            tokensBegin[lo] = tokensBegin[hi];
                            tokensBegin[hi] = tmp;
                        }

                        Buffer.MemoryCopy(tokensBegin, lzTokenArray.Data + lzTokenArray.Size,
                            sizeof(Token) * numTokens, sizeof(Token) * numTokens);
                        lzTokenArray.Size += numTokens;

                        if (reachedEnd)
                        {
                            break;
                        }

                        // ── Phase 3: Statistics update ──
                        // Accumulate token/literal/offset histograms from this chunk
                        // so the next chunk's cost model reflects the data seen so far.
                        UpdateStats(ref stats, source, chunkStart, tokensBegin, numTokens);
                        MakeCostModel(ref stats, ref costModel);
                        chunkStart = maxOffset;
                    } // while (chunkStart < srcSize - 16)

                    // Export tokens + stats if requested (two-phase mode)
                    if (exportedTokens != null && outerLoopIndex == 0)
                    {
                        exportedTokens.Tokens = new Token[lzTokenArray.Size];
                        for (int t = 0; t < lzTokenArray.Size; t++)
                        {
                            exportedTokens.Tokens[t] = lzTokenArray.Data[t];
                        }
                        exportedTokens.Count = lzTokenArray.Size;
                        exportedTokens.ChunkType = *chunkTypePtr;
                    }

                    // Encode the full token array
                    cost = StreamLZConstants.InvalidCost;
                    int nEnc = EncodeTokenArray(lztemp, &cost, &tmpChunkType,
                        source, srcSize, tmpDst, tmpDstEnd,
                        startPos, lzcoder, ref lzTokenArray, &stats);
                    if (cost >= bestCost)
                    {
                        break;
                    }

                    *chunkTypePtr = tmpChunkType;
                    bestCost = cost;
                    bestLength = nEnc;
                    Buffer.MemoryCopy(tmpDst, destination, destinationEnd - destination, nEnc);

                    if (lzcoder.CompressionLevel < 8 || outerLoopIndex != 0 || costModel.ChunkType == tmpChunkType)
                    {
                        byte[] ksArr = lzcoder.SymbolStatisticsScratch.Allocate(sizeof(Stats));
                        fixed (byte* pKs = ksArr)
                        {
                            *(Stats*)pKs = stats;
                        }
                        lzcoder.LastChunkType = tmpChunkType;
                        break;
                    }

                    lzcoder.LastChunkType = -1;
                    outerLoopIndex = 1;
                } // for (;;) outer loop
            } // fixed (litindexes)

            *costPtr = bestCost;
            return bestLength;
        } // fixed (pinned arrays)
    }
}
