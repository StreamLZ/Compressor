// Matcher.cs — Greedy match finder and match validation for the High compressor.

using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static bool CheckMatchValidLength(uint matchLength, uint offset)
    {
        return (offset < StreamLZConstants.OffsetThreshold768KB) ||
               ((offset < StreamLZConstants.OffsetThreshold1_5MB) ? (matchLength >= 5) :
                (offset < StreamLZConstants.OffsetThreshold3MB) ? (matchLength >= 6) : (matchLength >= 8));
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int GetRecentOffsetIndex(ref State st, int offset)
    {
        if (offset == st.RecentOffs0)
        {
            return 0;
        }
        if (offset == st.RecentOffs1)
        {
            return 1;
        }
        if (offset == st.RecentOffs2)
        {
            return 2;
        }
        return -1;
    }

    private static LengthAndOffset GetBestMatch(LengthAndOffset* matches, HighRecentOffs* recents,
        byte* src, byte* srcEnd,
        int minMatchLen, int literalsSinceLastMatch,
        byte* windowBase, int maxMatchOffset)
    {
        uint m32 = *(uint*)src;
        int bestMl = 0, bestOffs = 0;

        int matchLen;
        if ((matchLen = MatchUtils.GetMatchLengthQuick(src, recents->Offs[4], srcEnd, m32)) > bestMl)
        { bestMl = matchLen; bestOffs = 0; }
        if ((matchLen = MatchUtils.GetMatchLengthQuick(src, recents->Offs[5], srcEnd, m32)) > bestMl)
        { bestMl = matchLen; bestOffs = -1; }
        if ((matchLen = MatchUtils.GetMatchLengthQuick(src, recents->Offs[6], srcEnd, m32)) > bestMl)
        { bestMl = matchLen; bestOffs = -2; }

        if (bestMl < 4)
        {
            if (literalsSinceLastMatch >= 56)
            {
                if (bestMl <= 2)
                {
                    bestMl = 0;
                }
                minMatchLen++;
            }

            uint bestMatchLength = 0, bestMatchOffset = 0;
            for (int i = 0; i < 4; i++)
            {
                uint matchLength = (uint)matches[i].Length;
                if (matchLength < (uint)minMatchLen)
                {
                    break;
                }
                if (matchLength > (uint)(srcEnd - src))
                {
                    matchLength = (uint)(srcEnd - src);
                    if (matchLength < (uint)minMatchLen)
                    {
                        break;
                    }
                }
                uint offset = (uint)matches[i].Offset;
                if (offset >= (uint)maxMatchOffset)
                {
                    continue;
                }

                if (offset < 8)
                {
                    uint tt = offset;
                    do offset += tt; while (offset < 8);
                    if (offset > (uint)(src - windowBase))
                    {
                        continue;
                    }
                    matchLength = (uint)MatchUtils.GetMatchLengthQuickMin3(src, (int)offset, srcEnd, m32);
                    if (matchLength < (uint)minMatchLen)
                    {
                        continue;
                    }
                }

                if (IsMatchLongEnough(matchLength, offset) && MatchUtils.IsMatchBetter(matchLength, offset, bestMatchLength, bestMatchOffset))
                {
                    bestMatchOffset = offset;
                    bestMatchLength = matchLength;
                }
            }

            if (MatchUtils.IsBetterThanRecent(bestMl, (int)bestMatchLength, (int)bestMatchOffset))
            {
                bestMl = (int)bestMatchLength;
                bestOffs = (int)bestMatchOffset;
            }
        }

        return new LengthAndOffset { Length = bestMl, Offset = bestOffs };
    }
}
