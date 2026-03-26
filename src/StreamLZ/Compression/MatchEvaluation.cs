using System.Numerics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Compression;

/// <summary>
/// Utility functions for LZ match evaluation. All methods are aggressively inlined.
/// </summary>
internal static class MatchUtils
{
    /// <summary>
    /// Counts the number of matching bytes starting at <paramref name="p"/>, comparing
    /// against <c>p - offset</c>, up to <paramref name="pEnd"/>.
    /// Uses <c>nint</c> for <paramref name="offset"/> to match pointer arithmetic width
    /// in unsafe code (avoids sign-extension on 64-bit and enables direct pointer subtraction).
    /// NoInlining: prevents register spilling when inlined into huge callers (Optimal).
    /// </summary>
    [MethodImpl(MethodImplOptions.NoInlining)]
    public static unsafe int CountMatchingBytes(byte* p, byte* pEnd, nint offset)
    {
        int len = 0;
        while (pEnd - p >= 8)
        {
            ulong a = *(ulong*)p;
            ulong b = *(ulong*)(p - offset);
            if (a != b)
            {
                return len + (BitOperations.TrailingZeroCount(a ^ b) >> 3);
            }
            p += 8;
            len += 8;
        }
        if (pEnd - p >= 4)
        {
            uint a = *(uint*)p;
            uint b = *(uint*)(p - offset);
            if (a != b)
            {
                return len + (BitOperations.TrailingZeroCount(a ^ b) >> 3);
            }
            p += 4;
            len += 4;
        }
        for (; p < pEnd; len++, p++)
        {
            if (*p != p[-offset])
            {
                break;
            }
        }
        return len;
    }

    /// <summary>
    /// Quick match length computation. Returns 0..3 for short partial matches
    /// or 4+ for full matches.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static unsafe int GetMatchLengthQuick(byte* src, int offset, byte* srcEnd, uint u32AtCur)
    {
        uint u32AtMatch = *(uint*)&src[-offset];
        if (u32AtCur == u32AtMatch)
        {
            return 4 + CountMatchingBytes(src + 4, srcEnd, offset);
        }
        else
        {
            uint xor = u32AtCur ^ u32AtMatch;
            if ((ushort)xor != 0)
            {
                return 0;
            }
            return 3 - ((xor & 0xFFFFFF) != 0 ? 1 : 0);
        }
    }

    /// <summary>
    /// Match length with minimum 2; returns 0 for single-byte matches.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static unsafe int GetMatchLengthMin2(byte* srcPtrCur, int offset, byte* srcPtrSafeEnd)
    {
        int len = CountMatchingBytes(srcPtrCur, srcPtrSafeEnd, offset);
        if (len == 1)
        {
            len = 0;
        }
        return len;
    }

    /// <summary>
    /// Match length with minimum 3. Returns 0 if the first 3 bytes differ,
    /// or 3+ otherwise.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static unsafe int GetMatchLengthQuickMin3(byte* srcPtrCur, int offset, byte* srcPtrSafeEnd, uint u32AtCur)
    {
        uint u32AtMatch = *(uint*)&srcPtrCur[-offset];
        if (u32AtCur == u32AtMatch)
        {
            return 4 + CountMatchingBytes(srcPtrCur + 4, srcPtrSafeEnd, offset);
        }
        else
        {
            return ((u32AtCur ^ u32AtMatch) & 0xFFFFFF) != 0 ? 0 : 3;
        }
    }

    /// <summary>
    /// Match length with minimum 4. Returns 0 if the first 4 bytes differ.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static unsafe int GetMatchLengthQuickMin4(byte* srcPtrCur, int offset, byte* srcPtrSafeEnd, uint u32AtCur)
    {
        uint u32AtMatch = *(uint*)&srcPtrCur[-offset];
        return (u32AtCur == u32AtMatch)
            ? 4 + CountMatchingBytes(srcPtrCur + 4, srcPtrSafeEnd, offset)
            : 0;
    }

    /// <summary>
    /// Returns true if a normal match of length <paramref name="matchLength"/> at offset
    /// <paramref name="offset"/> is better than a recent-offset match of length
    /// <paramref name="recentMatchLength"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsBetterThanRecent(int recentMatchLength, int matchLength, int offset)
    {
        return recentMatchLength < 2
            || (recentMatchLength + 1 < matchLength && (recentMatchLength + 2 < matchLength || offset < 1024) && (recentMatchLength + 3 < matchLength || offset < 65536));
    }

    /// <summary>
    /// Returns true if a match of (<paramref name="matchLength"/>, <paramref name="offset"/>)
    /// is better than the current best (<paramref name="bestMatchLength"/>, <paramref name="bestOffset"/>).
    /// Compares two matches using length-biased heuristic.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool IsMatchBetter(uint matchLength, uint offset, uint bestMatchLength, uint bestOffset)
    {
        if (matchLength < bestMatchLength)
        {
            return false;
        }
        if (matchLength == bestMatchLength)
        {
            return offset < bestOffset;
        }
        if (matchLength == bestMatchLength + 1)
        {
            return (offset >> 7) <= bestOffset;
        }
        return true;
    }

    /// <summary>
    /// Computes a score to decide whether a lazy match at position+1 is worth
    /// taking over the current match.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int GetLazyScore(LengthAndOffset a, LengthAndOffset b)
    {
        int bitsA = (a.Offset > 0) ? (int)BitOperations.Log2((uint)a.Offset) + 3 : 0;
        int bitsB = (b.Offset > 0) ? (int)BitOperations.Log2((uint)b.Offset) + 3 : 0;
        return 4 * (a.Length - b.Length) - 4 - (bitsA - bitsB);
    }

}
