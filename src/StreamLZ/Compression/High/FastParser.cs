// FastParser.cs — High fast compressor (levels 1-4).
// Greedy/lazy hash-based match finder with High token encoding.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.High;

/// <summary>
/// High fast compressor (levels 1-4): greedy/lazy hash-based match finder.
/// Greedy/lazy hash-based match finder emitting into High's HighStreamWriter stream format.
/// </summary>
internal static unsafe class FastParser
{
    /// <summary>
    /// Checks if a recent offset produces a better match than the current best.
    /// High uses 3 recent offsets at indices 4, 5, 6.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CheckRecentMatch(byte* src, byte* srcEnd, uint u32,
        int* recentOffs, int idx, ref int bestMl, ref int bestOff)
    {
        int ml = MatchUtils.GetMatchLengthQuick(src, recentOffs[4 + idx], srcEnd, u32);
        if (ml > bestMl)
        {
            bestMl = ml;
            bestOff = idx;
        }
    }

    /// <summary>
    /// Gets the best match at the current position using hash table and recent offsets.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static LengthAndOffset GetMatch(byte* curPtr, byte* srcEndSafe,
        int* recentOffs, MatchHasherBase hasher, ReadOnlySpan<byte> srcSpan,
        int increment, int dictSize, int minMatchLength)
    {
        int hashPtr = hasher.HashEntryPtrNextIndex;
        int hash2Ptr = hasher.HashEntry2PtrNextIndex;
        uint hashTag = hasher.CurrentHashTag;
        uint hashPos = (uint)(hasher.SrcCurOffset - hasher.SrcBaseOffset);
        uint hashval = MatchHasherBase.MakeHashValue(hashTag, hashPos);

        // Prefetch for next position
        long nextOffset = hasher.SrcCurOffset + increment;
        if (nextOffset < srcSpan.Length - 8)
        {
            hasher.SetHashPosPrefetch(srcSpan, nextOffset);
        }
        else if (nextOffset < srcSpan.Length)
        {
            hasher.SetHashPos(srcSpan, nextOffset);
        }

        uint u32AtSrc = *(uint*)curPtr;

        // Check 3 recent offsets (High has 3, not 7)
        int recentMl = 0, recentOff = -1;
        CheckRecentMatch(curPtr, srcEndSafe, u32AtSrc, recentOffs, 0, ref recentMl, ref recentOff);
        CheckRecentMatch(curPtr, srcEndSafe, u32AtSrc, recentOffs, 1, ref recentMl, ref recentOff);
        CheckRecentMatch(curPtr, srcEndSafe, u32AtSrc, recentOffs, 2, ref recentMl, ref recentOff);

        int bestOffs = 0, bestMl = 0;

        // If we found a recent offset at least 4 bytes long then use it.
        if (recentMl >= 4)
        {
            hasher.Insert(hashPtr, hash2Ptr, hashval);
            bestOffs = -recentOff;
            bestMl = recentMl;
        }
        else
        {
            uint[] hashTable = hasher.HashTable;
            int numHash = hasher.NumHashEntries;
            bool dualHash = hasher.IsDualHash;

            int curHashIdx = hashPtr;
            for (; ; )
            {
                for (int hashidx = 0; hashidx < numHash; hashidx++)
                {
                    if ((hashTable[curHashIdx + hashidx] & StreamLZConstants.HashTagMask) == (hashTag & StreamLZConstants.HashTagMask))
                    {
                        int curOffs = (int)((hashPos - hashTable[curHashIdx + hashidx]) & StreamLZConstants.HashPositionMask);
                        if (curOffs < dictSize)
                        {
                            curOffs = Math.Max(curOffs, 8);
                            int curMl = MatchUtils.GetMatchLengthQuickMin4(curPtr, curOffs, srcEndSafe, u32AtSrc);
                            if (curMl >= minMatchLength
                                && Compressor.IsMatchLongEnough((uint)curMl, (uint)curOffs)
                                && MatchUtils.IsMatchBetter((uint)curMl, (uint)curOffs, (uint)bestMl, (uint)bestOffs))
                            {
                                bestOffs = curOffs;
                                bestMl = curMl;
                            }
                        }
                    }
                }
                if (!dualHash || curHashIdx == hash2Ptr)
                {
                    break;
                }
                curHashIdx = hash2Ptr;
            }
            hasher.Insert(hashPtr, hash2Ptr, hashval);
            if (!MatchUtils.IsBetterThanRecent(recentMl, bestMl, bestOffs))
            {
                bestOffs = -recentOff;
                bestMl = recentMl;
            }
        }

        return new LengthAndOffset { Length = bestMl, Offset = bestOffs };
    }

    /// <summary>
    /// Fast High compression with greedy/lazy matching.
    /// Greedy/lazy match-finding emitting via HighStreamWriter streams.
    /// </summary>
    [SkipLocalsInit]
    public static int CompressFast(LzCoder lzcoder, LzTemp lztemp,
        byte* src, int sourceLength, byte* dst, byte* destinationEnd,
        int startPos, int* chunkTypePtr, float* costPtr,
        int numLazy)
    {
        *chunkTypePtr = -1;
        if (sourceLength <= 128)
        {
            return sourceLength;
        }
        byte* srcEndSafe = src + sourceLength - 8;

        int dictSize = lzcoder.Options!.DictionarySize;
        dictSize = (dictSize <= 0) ? 0x40000000 : Math.Min(dictSize, 0x40000000);
        bool sc = lzcoder.Options.SelfContained;
        if (sc)
        {
            dictSize = Math.Min(dictSize, StreamLZConstants.ChunkSize); // cap to chunk size for self-contained
        }

        int minMatchLength = Math.Max(lzcoder.Options.MinMatchLength, 4);
        int initialCopyBytes = (startPos == 0) ? 8 : 0;
        int curPos = initialCopyBytes;

        // High uses 3 recent offsets at indices 4-6 (initialized to 8)
        Compressor.HighRecentOffs recent = Compressor.HighRecentOffs.Create();

        // Initialize HighStreamWriter streams
        Compressor.HighStreamWriter writer = default;
        Compressor.InitializeStreamWriter(ref writer, lztemp, sourceLength, src, lzcoder.EncodeFlags);

        int increment = 1, loopsSinceMatch = 0;
        int litStart = curPos;

        MatchHasherBase hasher = lzcoder.Hasher!;

        // Create a span covering from the window base to the end of our source.
        long srcOffsetFromBase = startPos;
        int spanLen = (int)(srcOffsetFromBase + sourceLength);
        byte* spanBase = src - srcOffsetFromBase;
        var fullSpan = new ReadOnlySpan<byte>(spanBase, spanLen);

        hasher.SetHashPos(fullSpan, srcOffsetFromBase + curPos);

        bool numHash1 = hasher.NumHashEntries == 1;

        while (curPos + increment < sourceLength - 16)
        {
            byte* curPtr = src + curPos;

            LengthAndOffset m = GetMatch(curPtr, srcEndSafe, recent.Offs,
                hasher, fullSpan, increment, dictSize, minMatchLength);

            if (m.Length == 0)
            {
                loopsSinceMatch++;
                curPos += increment;
                if (numHash1)
                {
                    increment = Math.Min((loopsSinceMatch >> 5) + 1, 12);
                }
                continue;
            }

            // Lazy evaluation
            if (numLazy >= 1)
            {
                while (curPos + 1 < sourceLength - 16)
                {
                    LengthAndOffset m1 = GetMatch(curPtr + 1, srcEndSafe, recent.Offs,
                        hasher, fullSpan, 1, dictSize, minMatchLength);
                    if (m1.Length != 0 && MatchUtils.GetLazyScore(m1, m) > 0)
                    {
                        curPos++;
                        curPtr++;
                        m = m1;
                    }
                    else
                    {
                        if (numLazy < 2 || curPos + 2 >= sourceLength - 16 || m.Length == 2)
                        {
                            break;
                        }
                        LengthAndOffset m2 = GetMatch(curPtr + 2, srcEndSafe, recent.Offs,
                            hasher, fullSpan, 1, dictSize, minMatchLength);
                        if (m2.Length != 0 && MatchUtils.GetLazyScore(m2, m) > 3)
                        {
                            curPos += 2;
                            curPtr += 2;
                            m = m2;
                        }
                        else
                        {
                            break;
                        }
                    }
                }
            }

            // Resolve actual offset from recent index
            int actualOffs = m.Offset;
            if (m.Offset <= 0)
            {
                // Avoid coding a recent0 right after a match (no literals in between)
                if (m.Offset == 0 && curPos == litStart)
                {
                    m.Offset = -1;
                }
                actualOffs = recent.Offs[-m.Offset + 4];
            }

            // Back-extend: grow match backwards while bytes match
            while (curPos > litStart && curPos + startPos >= actualOffs + 1
                && curPtr[-1] == curPtr[-actualOffs - 1])
            {
                curPos--;
                curPtr--;
                m.Length++;
            }

            // Emit token via HighStreamWriter streams
            Compressor.AddToken(ref writer, ref recent,
                src + litStart, curPos - litStart, m.Length, m.Offset,
                doRecent: true, doSubtract: true);

            hasher.InsertRange(fullSpan, srcOffsetFromBase + curPos, m.Length);
            loopsSinceMatch = 0;
            increment = 1;
            curPos += m.Length;
            litStart = curPos;
        }

        // Final trailing literals
        Compressor.AddFinalLiterals(ref writer, src + litStart, src + sourceLength, doSubtract: true);

        return Compressor.AssembleCompressedOutput(costPtr, chunkTypePtr, null, dst, destinationEnd,
            lzcoder, lztemp, ref writer, startPos);
    }
}
