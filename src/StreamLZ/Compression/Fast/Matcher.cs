// Matcher.cs — Match finding and comparison helpers for the Fast compressor.

using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// Match finding and comparison utilities for the Fast compressor.
/// Provides hash-table-based match finding for greedy/lazy levels
/// and match-candidate evaluation for the optimal parser.
/// </summary>
internal static unsafe class Matcher
{
    // ────────────────────────────────────────────────────────────────
    //  Match comparison heuristics
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Returns true if a hash-table match of <paramref name="matchLength"/> at
    /// <paramref name="matchOffset"/> is better than using the recent offset
    /// which gives <paramref name="recentMatchLength"/> bytes.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsBetterThanRecentMatch(int recentMatchLength, int matchLength, int matchOffset)
    {
        return recentMatchLength < 2
            || (recentMatchLength + 1 < matchLength && (recentMatchLength + 4 < matchLength || matchOffset < 65536));
    }

    /// <summary>
    /// Returns true if a match of (<paramref name="matchLength"/>, <paramref name="matchOffset"/>)
    /// is better than the current best (<paramref name="bestMatchLength"/>, <paramref name="bestOffset"/>).
    /// Considers the near/far offset boundary at 64 KB.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsMatchBetter(int matchLength, int matchOffset, int bestMatchLength, int bestOffset)
    {
        if (matchLength == bestMatchLength)
            return matchOffset < bestOffset;
        if ((matchOffset <= 0xffff) == (bestOffset <= 0xffff))
            return matchLength > bestMatchLength;
        if (bestOffset <= 0xffff)
            return matchLength > bestMatchLength + 5;
        return matchLength >= bestMatchLength - 5;
    }

    /// <summary>
    /// Returns true if the lazy match <paramref name="candidate"/> is worth taking
    /// over the current match <paramref name="current"/>, given the step distance.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsLazyMatchBetter(LengthAndOffset candidate, LengthAndOffset current, int step)
    {
        int bitsCandidate = (candidate.Offset > 0) ? (candidate.Offset > 0xffff ? 32 : 16) : 0;
        int bitsCurrent = (current.Offset > 0) ? (current.Offset > 0xffff ? 32 : 16) : 0;
        return 5 * (candidate.Length - current.Length) - 5 - (bitsCandidate - bitsCurrent) > step * 4;
    }

    // ────────────────────────────────────────────────────────────────
    //  Hash-based match finding (for greedy/lazy parsers)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Finds the best match at <paramref name="sourceCursor"/> using a <see cref="MatchHasherBase"/>
    /// (used by the lazy parser at user-facing level 4).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static LengthAndOffset FindMatchWithHasher(
        byte* sourceCursor, byte* safeSourceEnd, byte* literalStart,
        nint recentOffset, MatchHasherBase hasher,
        byte* nextCursorPtr, int dictionarySize, int minimumMatchLength, uint* minimumMatchLengthTable)
    {
        var hashPosition = hasher.GetHashPos(sourceCursor);
        uint bytesAtSource = *(uint*)sourceCursor;
        hasher.SetHashPosPrefetch(nextCursorPtr);

        uint xorValue = *(uint*)&sourceCursor[recentOffset] ^ bytesAtSource;
        if (xorValue == 0)
        {
            LengthAndOffset match;
            match.Length = 4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, -recentOffset);
            match.Offset = 0;
            hasher.Insert(hashPosition);
            return match;
        }
        uint recentMatchLength = (uint)(BitOperations.TrailingZeroCount(xorValue) >> 3);

        if (sourceCursor - literalStart >= 64)
        {
            if (recentMatchLength < 3)
                recentMatchLength = 0;
            minimumMatchLength += 1;
        }
        uint bestOffset = 0;
        uint bestMatchLength = (uint)(minimumMatchLength - 1);
        int numHash = hasher.NumHashEntries;
        bool dualHash = hasher.IsDualHash;
        uint[] hashTable = hasher.HashTable;

        int hashIndex = hashPosition.Ptr1Index;
        for (;;)
        {
            for (int entryIndex = 0; entryIndex < numHash; entryIndex++)
            {
                if ((hashTable[hashIndex + entryIndex] & 0xfc000000) == (hashPosition.Tag & 0xfc000000))
                {
                    uint candidateOffset = (hashPosition.Pos - hashTable[hashIndex + entryIndex]) & 0x3ffffff;
                    if (candidateOffset > 8 && candidateOffset < (uint)dictionarySize
                        && candidateOffset <= (uint)(sourceCursor - hasher.SrcBase)
                        && *(uint*)(sourceCursor - candidateOffset) == bytesAtSource)
                    {
                        uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, (nint)candidateOffset));
                        if (candidateLength > bestMatchLength
                            && candidateLength >= minimumMatchLengthTable[31 - BitOperations.Log2(candidateOffset)]
                            && IsMatchBetter((int)candidateLength, (int)candidateOffset, (int)bestMatchLength, (int)bestOffset))
                        {
                            bestOffset = candidateOffset;
                            bestMatchLength = candidateLength;
                        }
                    }
                }
            }
            if (!dualHash || hashIndex == hashPosition.Ptr2Index)
                break;
            hashIndex = hashPosition.Ptr2Index;
        }

        if (*(uint*)(sourceCursor - 8) == bytesAtSource)
        {
            uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, 8));
            if (candidateLength >= bestMatchLength && candidateLength >= (uint)minimumMatchLength)
            {
                bestMatchLength = candidateLength;
                bestOffset = 8;
            }
        }
        hasher.Insert(hashPosition);
        if (bestOffset == 0 || !IsBetterThanRecentMatch((int)recentMatchLength, (int)bestMatchLength, (int)bestOffset))
        {
            bestMatchLength = recentMatchLength;
            bestOffset = 0;
        }
        LengthAndOffset result;
        result.Length = (int)bestMatchLength;
        result.Offset = (int)bestOffset;
        return result;
    }

    /// <summary>
    /// Finds the best match at <paramref name="sourceCursor"/> using a <see cref="MatchHasher2"/>
    /// with chain walking (used by the lazy parser at user-facing level 6).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static LengthAndOffset FindMatchWithChainHasher(
        byte* sourceCursor, byte* safeSourceEnd, byte* literalStart,
        nint recentOffset, MatchHasher2 hasher,
        byte* nextCursorPtr, int dictionarySize, int minimumMatchLength, uint* minimumMatchLengthTable)
    {
        var hashPosition = hasher.GetHashPos(sourceCursor);
        uint bytesAtSource = *(uint*)sourceCursor;
        hasher.SetHashPosPrefetch(nextCursorPtr);

        uint xorValue = *(uint*)&sourceCursor[recentOffset] ^ bytesAtSource;
        if (xorValue == 0)
        {
            LengthAndOffset match;
            match.Length = 4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, -recentOffset);
            match.Offset = 0;
            hasher.Insert(hashPosition);
            return match;
        }
        uint recentMatchLength = (uint)(BitOperations.TrailingZeroCount(xorValue) >> 3);
        if (sourceCursor - literalStart >= 64)
        {
            if (recentMatchLength < 3)
                recentMatchLength = 0;
            minimumMatchLength += 1;
        }
        // Look in the short table (chain walking)
        uint bestMatchLength = 0, bestOffset = 0;
        uint[] firstHash = hasher.FirstHash;
        ushort[] nextHash = hasher.NextHash;
        uint[] longHash = hasher.LongHash;

        uint hashValue = firstHash[hashPosition.HashA];
        uint candidateOffset = hashPosition.Pos - hashValue;
        if (candidateOffset <= 0xffff)
        {
            if (candidateOffset != 0)
            {
                int maxChainSteps = 8;
                while (candidateOffset < (uint)dictionarySize)
                {
                    if (candidateOffset > 8)
                    {
                        if (candidateOffset <= (uint)(sourceCursor - hasher.SrcBase)
                            && *(uint*)(sourceCursor - candidateOffset) == bytesAtSource
                            && (bestMatchLength < 4 || (sourceCursor + bestMatchLength < safeSourceEnd && *(sourceCursor + bestMatchLength) == *(sourceCursor - candidateOffset + bestMatchLength))))
                        {
                            uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, (nint)candidateOffset));
                            if (candidateLength > bestMatchLength && candidateLength >= (uint)minimumMatchLength)
                            {
                                bestMatchLength = candidateLength;
                                bestOffset = candidateOffset;
                            }
                        }
                        if (--maxChainSteps == 0)
                            break;
                    }
                    uint previousOffset = candidateOffset;
                    hashValue = nextHash[(ushort)hashValue];
                    candidateOffset = (ushort)(hashPosition.Pos - hashValue);
                    if (candidateOffset <= previousOffset)
                        break;
                }
            }
        }
        else if (candidateOffset < (uint)dictionarySize
                 && candidateOffset <= (uint)(sourceCursor - hasher.SrcBase)
                 && *(uint*)(sourceCursor - candidateOffset) == bytesAtSource)
        {
            uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, (nint)candidateOffset));
            if (candidateLength > (uint)minimumMatchLength && candidateLength >= minimumMatchLengthTable[31 - BitOperations.Log2(candidateOffset)])
            {
                bestMatchLength = candidateLength;
                bestOffset = candidateOffset;
            }
        }
        // Look in the long table
        hashValue = longHash[hashPosition.HashB];
        if (((hashPosition.HashBTag ^ hashValue) & 0x3F) == 0)
        {
            candidateOffset = hashPosition.Pos - (hashValue >> 6);
            if (candidateOffset >= 8 && candidateOffset < (uint)dictionarySize
                && candidateOffset <= (uint)(sourceCursor - hasher.SrcBase)
                && *(uint*)(sourceCursor - candidateOffset) == bytesAtSource)
            {
                uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, (nint)candidateOffset));
                if (candidateLength >= minimumMatchLengthTable[31 - BitOperations.Log2(candidateOffset)]
                    && IsMatchBetter((int)candidateLength, (int)candidateOffset, (int)bestMatchLength, (int)bestOffset))
                {
                    bestMatchLength = candidateLength;
                    bestOffset = candidateOffset;
                }
            }
        }
        // Look at fixed offset 8
        if (*(uint*)(sourceCursor - 8) == bytesAtSource)
        {
            uint candidateLength = (uint)(4 + MatchUtils.CountMatchingBytes(sourceCursor + 4, safeSourceEnd, 8));
            if (candidateLength >= bestMatchLength && candidateLength >= (uint)minimumMatchLength)
            {
                bestMatchLength = candidateLength;
                bestOffset = 8;
            }
        }
        hasher.Insert(hashPosition);
        if (!IsBetterThanRecentMatch((int)recentMatchLength, (int)bestMatchLength, (int)bestOffset))
        {
            bestMatchLength = recentMatchLength;
            bestOffset = 0;
        }
        LengthAndOffset result;
        result.Length = (int)bestMatchLength;
        result.Offset = (int)bestOffset;
        return result;
    }

    /// <summary>
    /// Builds the minimum match length table indexed by <c>31 - Log2(offset)</c>.
    /// Near offsets require shorter matches; distant offsets require longer ones.
    /// </summary>
    public static void BuildMinimumMatchLengthTable(uint* table, int minimumMatchLength, int longOffsetThreshold)
    {
        // Table indexed by (31 - Log2(offset)), mapping offset magnitude to minimum match length:
        //   [0-9]   offsets > 4MB:    require 32-byte matches (effectively disabled)
        //   [10-11] offsets 1-4MB:    require 2*longOffsetThreshold - 6
        //   [12-15] offsets 64K-1MB:  require longOffsetThreshold
        //   [16-31] offsets < 64K:    require minimumMatchLength (typically 4)
        table[0] = table[1] = table[2] = table[3] = table[4] = table[5] = table[6] = table[7] = table[8] = table[9] = 32;
        table[10] = table[11] = (uint)(longOffsetThreshold * 2 - 6);
        table[12] = table[13] = table[14] = table[15] = (uint)longOffsetThreshold;
        table[16] = table[17] = table[18] = table[19] = table[20] = table[21] = table[22] = table[23] = (uint)minimumMatchLength;
        table[24] = table[25] = table[26] = table[27] = table[28] = table[29] = table[30] = table[31] = (uint)minimumMatchLength;
    }
}
