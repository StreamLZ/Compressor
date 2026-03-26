// CostModel.cs — Match validation, statistics helpers, and cost model for the High compressor.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static bool IsMatchLongEnough(uint matchLength, uint offset)
    {
        return matchLength switch
        {
            0 or 1 or 2 => false,
            3 => offset < StreamLZConstants.OffsetThreshold12KB,
            4 => offset < StreamLZConstants.OffsetThreshold96KB,
            5 => offset < StreamLZConstants.OffsetThreshold768KB,
            6 or 7 => offset < StreamLZConstants.OffsetThreshold3MB,
            _ => true,
        };
    }

    private static void RescaleOne(ref HistoU8 h)
    {
        for (int i = 0; i < 256; i++)
        {
            h.Count[i] = (h.Count[i] >> 4) + 1;
        }
    }

    private static void RescaleStats(ref Stats s)
    {
        RescaleOne(ref s.LitRaw);
        RescaleOne(ref s.LitSub);
        RescaleOne(ref s.OffsHisto);
        if (s.OffsEncodeType > 1)
        {
            RescaleOne(ref s.OffsLoHisto);
        }
        RescaleOne(ref s.TokenHisto);
        RescaleOne(ref s.MatchLenHisto);
    }

    private static void RescaleAddOne(ref HistoU8 h, ref HistoU8 t)
    {
        for (int i = 0; i < 256; i++)
        {
            h.Count[i] = ((h.Count[i] + t.Count[i]) >> 5) + 1;
        }
    }

    private static void RescaleAddStats(ref Stats s, ref Stats t, bool chunkTypeSame)
    {
        if (chunkTypeSame)
        {
            RescaleAddOne(ref s.LitRaw, ref t.LitRaw);
            RescaleAddOne(ref s.LitSub, ref t.LitSub);
        }
        else
        {
            RescaleOne(ref s.LitRaw);
            RescaleOne(ref s.LitSub);
        }
        RescaleAddOne(ref s.TokenHisto, ref t.TokenHisto);
        RescaleAddOne(ref s.MatchLenHisto, ref t.MatchLenHisto);
        if (s.OffsEncodeType == t.OffsEncodeType)
        {
            RescaleAddOne(ref s.OffsHisto, ref t.OffsHisto);
            if (s.OffsEncodeType > 1)
            {
                RescaleAddOne(ref s.OffsLoHisto, ref t.OffsLoHisto);
            }
        }
        else
        {
            s.OffsHisto = t.OffsHisto;
            s.OffsLoHisto = t.OffsLoHisto;
            s.OffsEncodeType = t.OffsEncodeType;
            RescaleOne(ref s.OffsHisto);
            if (s.OffsEncodeType > 1)
            {
                RescaleOne(ref s.OffsLoHisto);
            }
        }
    }

    private static void UpdateStats(ref Stats h, byte* src, int pos, Token* tokens, int numToken)
    {
        const int Increment = 2;

        for (int i = 0; i < numToken; i++)
        {
            Token* t = &tokens[i];
            int litlen = t->LitLen;
            int recent = t->RecentOffset0;

            for (int j = 0; j < litlen; j++)
            {
                byte b = src[pos + j];
                h.LitRaw.Count[b] += Increment;
                h.LitSub.Count[(byte)(b - src[pos + j - recent])] += Increment;
            }

            pos += litlen + t->MatchLen;

            int lengthField = litlen;
            if (litlen >= 3)
            {
                h.MatchLenHisto.Count[Math.Min(litlen - 3, 255)] += Increment;
                lengthField = 3;
            }

            if (t->MatchLen < 2)
            {
                Debug.Assert(t->MatchLen >= 2);
                continue;
            }

            uint offset = (uint)t->Offset;
            int recentField;
            if (t->Offset <= 0)
            {
                recentField = -(int)offset;
            }
            else
            {
                recentField = 3;
                if (h.OffsEncodeType == 0)
                {
                    if (offset >= StreamLZConstants.HighOffsetThreshold)
                    {
                        uint tv = (uint)BitOperations.Log2(offset - (uint)StreamLZConstants.LowOffsetEncodingLimit) | (uint)StreamLZConstants.HighOffsetMarker;
                        h.OffsHisto.Count[tv] += Increment;
                    }
                    else
                    {
                        uint tv = ((offset - 8) & 0xF) + 16 * ((uint)BitOperations.Log2(offset + StreamLZConstants.OffsetBiasConstant) - 9);
                        h.OffsHisto.Count[tv] += Increment;
                    }
                }
                else if (h.OffsEncodeType == 1)
                {
                    uint tv = (uint)BitOperations.Log2(offset + 8) - 3;
                    uint u = 8 * tv | (((offset + 8) >> (int)tv) ^ 8);
                    h.OffsHisto.Count[u] += Increment;
                }
                else
                {
                    uint offsetHigh = offset / (uint)h.OffsEncodeType;
                    uint offsetLow = offset % (uint)h.OffsEncodeType;
                    uint tv = (uint)BitOperations.Log2(offsetHigh + 8) - 3;
                    uint u = 8 * tv | (((offsetHigh + 8) >> (int)tv) ^ 8);
                    h.OffsHisto.Count[u] += Increment;
                    h.OffsLoHisto.Count[offsetLow] += Increment;
                }
            }

            int matchlenField = t->MatchLen - 2;
            if (t->MatchLen - 17 >= 0)
            {
                h.MatchLenHisto.Count[Math.Min(t->MatchLen - 17, 255)] += Increment;
                matchlenField = 15;
            }

            int tokenValue = (matchlenField << 2) + (recentField << 6) + lengthField;
            h.TokenHisto.Count[tokenValue] += Increment;
        }
    }

    private static void MakeCostModel(ref Stats h, ref CostModel costModel)
    {
        fixed (HistoU8* pOffs = &h.OffsHisto)
        fixed (uint* pOffsCost = costModel.OffsCost)
            OffsetEncoder.ConvertHistoToCost(pOffs, pOffsCost, 36);

        if (h.OffsEncodeType > 1)
        {
            fixed (HistoU8* pOffsLo = &h.OffsLoHisto)
            fixed (uint* pOffsLoCost = costModel.OffsLoCost)
                OffsetEncoder.ConvertHistoToCost(pOffsLo, pOffsLoCost, 0);
        }

        fixed (HistoU8* pToken = &h.TokenHisto)
        fixed (uint* pTokenCost = costModel.TokenCost)
            OffsetEncoder.ConvertHistoToCost(pToken, pTokenCost, 18);

        fixed (HistoU8* pMatchLen = &h.MatchLenHisto)
        fixed (uint* pMatchLenCost = costModel.MatchLenCost)
            OffsetEncoder.ConvertHistoToCost(pMatchLen, pMatchLenCost, 12);

        if (costModel.ChunkType == 1)
        {
            fixed (HistoU8* pLit = &h.LitRaw)
            fixed (uint* pLitCost = costModel.LitCost)
                OffsetEncoder.ConvertHistoToCost(pLit, pLitCost, 0);
        }
        else
        {
            fixed (HistoU8* pLit = &h.LitSub)
            fixed (uint* pLitCost = costModel.LitCost)
                OffsetEncoder.ConvertHistoToCost(pLit, pLitCost, 0);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint BitsForLiteralLength(ref CostModel costModel, int curLitlen)
    {
        if (curLitlen < 3)
        {
            return 0;
        }
        if (curLitlen - 3 >= 255)
        {
            int v = (int)(uint)BitOperations.Log2((uint)(((curLitlen - 3 - 255) >> 6) + 1));
            return costModel.MatchLenCost[255] + (uint)(32 * (2 * v + 7));
        }
        return costModel.MatchLenCost[curLitlen - 3];
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint BitsForLiteral(byte* src, int pos, int recent, ref CostModel costModel, int litidx)
    {
        byte* p = src + pos;
        return costModel.LitCost[(byte)(p[0] - (p[-recent] & costModel.SubOrCopyMask))];
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint BitsForLiterals(byte* src, int pos, int num, int recent, ref CostModel costModel, int litidx)
    {
        byte* p = src + pos;
        uint sum = 0;
        for (int i = 0; i < num; i++, p++)
        {
            sum += costModel.LitCost[(byte)(p[0] - (p[-recent] & costModel.SubOrCopyMask))];
        }
        return sum;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int BitsForToken(ref CostModel costModel, int curMatchLen, int cmdOffset, int recentField, int lengthField)
    {
        if (curMatchLen - 17 >= 0)
        {
            int bitsForMatchLen;
            if (curMatchLen - 17 >= 255)
            {
                int bitScanResult = (int)(uint)BitOperations.Log2((uint)(((curMatchLen - 17 - 255) >> 6) + 1));
                bitsForMatchLen = (int)costModel.MatchLenCost[255] + 32 * (2 * bitScanResult + 7);
            }
            else
            {
                bitsForMatchLen = (int)costModel.MatchLenCost[curMatchLen - 17];
            }
            return (int)costModel.TokenCost[(15 << 2) + (recentField << 6) + lengthField] + bitsForMatchLen;
        }
        return (int)costModel.TokenCost[((curMatchLen - 2) << 2) + (recentField << 6) + lengthField];
    }

    // Explicit distance penalty: nudge parser toward nearby matches when
    // entropy costs are similar. 16 units = 0.5 bit per offset bit above 16.
    private const uint OffsetDistancePenaltyThreshold = 16;
    private const uint OffsetDistancePenaltyMult = 16; // in 32nds of a bit

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint BitsForOffset(ref CostModel costModel, uint offset)
    {
        uint cost;
        if (costModel.OffsEncodeType == 0)
        {
            if (offset >= StreamLZConstants.HighOffsetThreshold)
            {
                uint t = (uint)BitOperations.Log2(offset - (uint)StreamLZConstants.LowOffsetEncodingLimit) | (uint)StreamLZConstants.HighOffsetMarker;
                uint u = t - (uint)StreamLZConstants.HighOffsetCostAdjust;
                cost = costModel.OffsCost[t] + 32 * u + 12;
            }
            else
            {
                uint t = ((offset - 8) & 0xF) + 16 * ((uint)BitOperations.Log2(offset + StreamLZConstants.OffsetBiasConstant) - 9);
                uint u = (t >> 4) + 5;
                cost = costModel.OffsCost[t] + 32 * u;
            }
        }
        else if (costModel.OffsEncodeType == 1)
        {
            uint t = (uint)BitOperations.Log2(offset + 8) - 3;
            uint u = 8 * t | (((offset + 8) >> (int)t) ^ 8);
            cost = costModel.OffsCost[u] + 32 * (u >> 3);
        }
        else
        {
            uint offsetHigh = offset / (uint)costModel.OffsEncodeType;
            uint offsetLow = offset % (uint)costModel.OffsEncodeType;
            uint t = (uint)BitOperations.Log2(offsetHigh + 8) - 3;
            uint u = 8 * t | (((offsetHigh + 8) >> (int)t) ^ 8);
            cost = costModel.OffsCost[u] + 32 * (u >> 3) + costModel.OffsLoCost[offsetLow];
        }

        // Distance penalty for far offsets
        uint offsetBits = (uint)BitOperations.Log2(offset + 1);
        if (offsetBits > OffsetDistancePenaltyThreshold)
        {
            cost += (offsetBits - OffsetDistancePenaltyThreshold) * OffsetDistancePenaltyMult;
        }

        return cost;
    }
}
