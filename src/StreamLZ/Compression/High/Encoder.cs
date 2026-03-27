// Encoder.cs — Stream init, token writing, and array encoding for the High compressor.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    internal static void InitializeStreamWriter(ref HighStreamWriter writer, LzTemp lztemp, int sourceLength, byte* srcBase, int encodeFlags)
    {
        writer.SrcPtr = srcBase;
        writer.SrcLen = sourceLength;

        int literalCapacity = sourceLength + 8;
        int tokenCapacity = sourceLength / 2 + 8;
        int u8OffsetCapacity = sourceLength / 3;
        int u32OffsetCapacity = sourceLength / 3;
        int runLength8Capacity = sourceLength / 5;
        int runLength32Capacity = sourceLength / 256;

        int totalAlloc = literalCapacity * 2 + tokenCapacity + u8OffsetCapacity + u32OffsetCapacity * 4 + runLength8Capacity + runLength32Capacity * 4 + 256;
        byte[] buf = lztemp.HighEncoderScratch.Allocate(totalAlloc);

        fixed (byte* pBase = buf)
        {
            byte* p = pBase;
            writer.LitsStart = writer.Lits = p; p += literalCapacity;
            writer.SubLitsStart = writer.SubLits = p; p += literalCapacity;
            writer.TokensStart = writer.Tokens = p; p += tokenCapacity;
            writer.U8Offs = writer.U8OffsStart = p; p += u8OffsetCapacity;
            // Align to 4
            p = (byte*)(((nuint)p + 3) & ~(nuint)3);
            writer.U32Offs = writer.U32OffsStart = (uint*)p; p += u32OffsetCapacity * 4;
            writer.Lrl8 = writer.Lrl8Start = p; p += runLength8Capacity;
            p = (byte*)(((nuint)p + 3) & ~(nuint)3);
            writer.Len32 = writer.Len32Start = (uint*)p;
        }

        writer.Recent0 = StreamLZConstants.InitialRecentOffset;
        writer.EncodeFlags = encodeFlags;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int WriteMatchLength(ref HighStreamWriter writer, int matchLength)
    {
        int mlToken = matchLength - 2;
        if (mlToken >= 15)
        {
            mlToken = 15;
            if (matchLength >= 255 + 17)
            {
                *writer.Lrl8++ = 255;
                *writer.Len32++ = (uint)(matchLength - 255 - 17);
            }
            else
            {
                *writer.Lrl8++ = (byte)(matchLength - 17);
            }
        }
        return mlToken << 2;
    }

    private static void WriteLiteralsLong(ref HighStreamWriter writer, byte* p, nint len, bool doSubtract)
    {
        if (doSubtract)
        {
            OffsetEncoder.SubtractBytesUnsafe(writer.SubLits, p, (nuint)len, (nuint)(-writer.Recent0));
            writer.SubLits += len;
        }

        byte* d = writer.Lits;
        byte* dEnd = d + len;
        do
        {
            *(uint*)d = *(uint*)p;
            d += 4; p += 4;
        } while (d < dEnd);
        writer.Lits = dEnd;

        if (len >= 258)
        {
            *writer.Lrl8++ = 255;
            *writer.Len32++ = (uint)(len - 258);
        }
        else
        {
            *writer.Lrl8++ = (byte)(len - 3);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int WriteLiterals(ref HighStreamWriter writer, byte* p, nint len, bool doSubtract)
    {
        if (len == 0)
        {
            return 0;
        }

        if (len > 8)
        {
            WriteLiteralsLong(ref writer, p, len, doSubtract);
            return 3;
        }

        byte* lrl8 = writer.Lrl8;
        *lrl8 = (byte)(len - 3);
        writer.Lrl8 = (len >= 3) ? lrl8 + 1 : lrl8;

        byte* ll = writer.Lits;
        *(ulong*)ll = *(ulong*)p;
        writer.Lits = ll + len;

        if (doSubtract)
        {
            byte* sl = writer.SubLits;
            for (nint i = 0; i < len; i++)
            {
                sl[i] = (byte)(p[i] - p[i - writer.Recent0]);
            }
            writer.SubLits = sl + len;
        }
        return (int)Math.Min(len, 3);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteFarOffset(ref HighStreamWriter writer, uint offset)
    {
        int bsr = (int)(uint)BitOperations.Log2(offset - (uint)StreamLZConstants.LowOffsetEncodingLimit);
        *writer.U8Offs++ = (byte)(bsr | StreamLZConstants.HighOffsetMarker);
        *writer.U32Offs++ = offset;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteNearOffset(ref HighStreamWriter writer, uint offset)
    {
        int bsr = (int)(uint)BitOperations.Log2(offset + StreamLZConstants.OffsetBiasConstant);
        *writer.U8Offs++ = (byte)(((offset - 8) & 0xF) | (uint)(16 * (bsr - 9)));
        *writer.U32Offs++ = offset;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteOffset(ref HighStreamWriter writer, uint offset)
    {
        if (offset >= StreamLZConstants.HighOffsetThreshold)
        {
            WriteFarOffset(ref writer, offset);
        }
        else
        {
            WriteNearOffset(ref writer, offset);
        }
    }

    internal static void AddToken(ref HighStreamWriter writer, ref HighRecentOffs recent,
        byte* litstart, nint litlen, int matchlen, int offsOrRecent,
        bool doRecent, bool doSubtract)
    {
        int token = WriteLiterals(ref writer, litstart, litlen, doSubtract);
        token += WriteMatchLength(ref writer, matchlen);

        if (offsOrRecent > 0)
        {
            token += 3 << 6;
            if (doRecent)
            {
                recent.Offs[6] = recent.Offs[5];
                recent.Offs[5] = recent.Offs[4];
                recent.Offs[4] = offsOrRecent;
            }
            writer.Recent0 = offsOrRecent;
            WriteOffset(ref writer, (uint)offsOrRecent);
        }
        else
        {
            if (doRecent)
            {
                int idx = -offsOrRecent;
                Debug.Assert(idx >= 0 && idx <= 2);
                token += idx << 6;
                int v = recent.Offs[idx + 4];
                recent.Offs[idx + 4] = recent.Offs[idx + 3];
                recent.Offs[idx + 3] = recent.Offs[idx + 2];
                recent.Offs[4] = v;
                writer.Recent0 = v;
            }
        }
        *writer.Tokens++ = (byte)token;
    }

    internal static void AddFinalLiterals(ref HighStreamWriter writer, byte* p, byte* pend, bool doSubtract)
    {
        nint len = (nint)(pend - p);
        if (len > 0)
        {
            Buffer.MemoryCopy(p, writer.Lits, len, len);
            writer.Lits += len;
            if (doSubtract)
            {
                OffsetEncoder.SubtractBytes(writer.SubLits, p, (nuint)len, (nuint)(-writer.Recent0));
                writer.SubLits += len;
            }
        }
    }

    internal static int AssembleCompressedOutput(float* costPtr, int* chunkTypePtr, Stats* stats,
        byte* dst, byte* destinationEnd,
        LzCoder lzcoder, LzTemp lztemp,
        ref HighStreamWriter writer, int startPos)
    {
        byte* destinationStart = dst;

        if (stats != null)
        {
            *stats = default;
        }

        byte* source = writer.SrcPtr;
        int sourceLength = writer.SrcLen;

        int initialBytes = startPos == 0 ? 8 : 0;
        for (int i = 0; i < initialBytes; i++)
        {
            *dst++ = source[i];
        }

        int level = lzcoder.CompressionLevel;

        int flagIgnoreU32Length = 0;
        Debug.Assert((lzcoder.EncodeFlags & 1) == 0);

        int numLits = (int)(writer.Lits - writer.LitsStart);
        float litCost = StreamLZConstants.InvalidCost;
        float memcpyCost = numLits + 3;

        if (numLits < 32 || level <= -4)
        {
            *chunkTypePtr = 1;
            int n = EntropyEncoder.EncodeArrayU8_Memcpy(dst, destinationEnd, writer.LitsStart, numLits);
            if (n < 0)
            {
                return sourceLength;
            }
            dst += n;
            litCost = memcpyCost;
        }
        else
        {
            HistoU8 litsHisto, litsubHisto;
            bool hasLitsub = writer.SubLits != writer.SubLitsStart;

            EntropyEncoder.CountBytesHistoU8(writer.LitsStart, numLits, &litsHisto);
            if (hasLitsub)
            {
                EntropyEncoder.CountBytesHistoU8(writer.SubLitsStart, numLits, &litsubHisto);
            }
            else
            {
                litsubHisto = default;
            }

            if (stats != null)
            {
                stats->LitRaw = litsHisto;
                if (hasLitsub)
                {
                    stats->LitSub = litsubHisto;
                }
            }

            int litN = -1;
            bool skipNormalLit = false;

            if (hasLitsub)
            {
                float litsubExtraCost = numLits * CostCoefficients.Current.HighLitSubExtraCostPerLit * lzcoder.SpeedTradeoff;

                bool skipLitsub = level < 6 &&
                    OffsetEncoder.GetHistoCostApprox(&litsHisto, numLits) * CostCoefficients.Current.CostToBitsFactor <=
                    OffsetEncoder.GetHistoCostApprox(&litsubHisto, numLits) * CostCoefficients.Current.CostToBitsFactor + litsubExtraCost;

                if (!skipLitsub)
                {
                    *chunkTypePtr = 0;
                    float litsubCost = StreamLZConstants.InvalidCost;
                    litN = EntropyEncoder.EncodeArrayU8WithHisto(dst, destinationEnd, writer.SubLitsStart, numLits,
                        litsubHisto, lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
                        &litsubCost, level);
                    if (litN < 0)
                    {
                        return sourceLength;
                    }
                    litsubCost += litsubExtraCost;
                    if (litN > 0 && litN < numLits && litsubCost <= memcpyCost)
                    {
                        litCost = litsubCost;
                        if (level < 6)
                        {
                            skipNormalLit = true;
                        }
                    }
                }
            }

            if (!skipNormalLit)
            {
                int n = EntropyEncoder.EncodeArrayU8WithHisto(dst, destinationEnd, writer.LitsStart, numLits,
                    litsHisto, lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
                    &litCost, level);
                if (n > 0)
                {
                    litN = n;
                    *chunkTypePtr = 1;
                }
            }

            if (litN < 0)
            {
                return sourceLength;
            }
            dst += litN;
        }

        float tokenCost = StreamLZConstants.InvalidCost;
        int tokN = EntropyEncoder.EncodeArrayU8(dst, destinationEnd, writer.TokensStart,
            (int)(writer.Tokens - writer.TokensStart),
            lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
            &tokenCost, level, stats != null ? &stats->TokenHisto : null);
        if (tokN < 0)
        {
            return sourceLength;
        }
        dst += tokN;

        int offsEncodeType = 0;
        float offsCost = StreamLZConstants.InvalidCost;
        int offsN = EntropyEncoder.EncodeLzOffsets(dst, destinationEnd,
            writer.U8OffsStart, writer.U32OffsStart,
            (int)(writer.U8Offs - writer.U8OffsStart),
            lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
            &offsCost, 8, (lzcoder.EncodeFlags & 4) != 0, &offsEncodeType, level,
            stats != null ? &stats->OffsHisto : null,
            stats != null ? &stats->OffsLoHisto : null);
        if (offsN < 0)
        {
            return sourceLength;
        }
        dst += offsN;
        if (stats != null)
        {
            stats->OffsEncodeType = offsEncodeType;
        }

        float lrl8Cost = StreamLZConstants.InvalidCost;
        int lrl8N = EntropyEncoder.EncodeArrayU8(dst, destinationEnd, writer.Lrl8Start,
            (int)(writer.Lrl8 - writer.Lrl8Start),
            lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
            &lrl8Cost, level, stats != null ? &stats->MatchLenHisto : null);
        if (lrl8N < 0)
        {
            return sourceLength;
        }
        dst += lrl8N;

        int lrlNum = (int)(writer.Lrl8 - writer.Lrl8Start);
        int offsNum = (int)(writer.U8Offs - writer.U8OffsStart);
        int tokNum = (int)(writer.Tokens - writer.TokensStart);
        int required = Math.Max(lrlNum, offsNum) + lrlNum + numLits + 4 * lrlNum + 6 * offsNum + tokNum + 16;
        required = Math.Max(Math.Max(required, 2 * numLits), numLits + 2 * tokNum) + StreamLZConstants.EntropyScratchSize;
        int scratchAvailable = StreamLZConstants.CalculateScratchSize(sourceLength);
        if (required > scratchAvailable)
        {
            Debug.Assert(required <= scratchAvailable);
            return sourceLength;
        }

        int bitsN = EntropyEncoder.WriteLzOffsetBits(dst, destinationEnd, writer.U8OffsStart, writer.U32OffsStart,
            offsNum, offsEncodeType,
            writer.Len32Start, (int)(writer.Len32 - writer.Len32Start),
            flagIgnoreU32Length);
        if (bitsN < 0)
        {
            return sourceLength;
        }
        dst += bitsN;

        if (dst - destinationStart >= sourceLength)
        {
            return sourceLength;
        }

        float writeBitsCost = (CostCoefficients.Current.HighWriteBitsBase + sourceLength * CostCoefficients.Current.HighWriteBitsPerSrcByte + tokNum * CostCoefficients.Current.HighWriteBitsPerToken + lrlNum * CostCoefficients.Current.HighWriteBitsPerLrl) *
            lzcoder.SpeedTradeoff + (initialBytes + flagIgnoreU32Length + bitsN);
        float cost = tokenCost + litCost + offsCost + lrl8Cost + writeBitsCost;
        *costPtr = (float)((CostCoefficients.Current.LengthBase + lrlNum * CostCoefficients.Current.LengthU8PerItem + (int)(writer.Len32 - writer.Len32Start) * CostCoefficients.Current.LengthU32PerItem) *
            lzcoder.SpeedTradeoff) + cost;
        return (int)(dst - destinationStart);
    }

    private static int EncodeTokenArray(LzTemp lztemp, float* costPtr, int* chunkTypePtr,
        byte* src, int sourceLength,
        byte* dst, byte* destinationEnd, int startPos,
        LzCoder lzcoder, ref TokenArray tokarray, Stats* stat)
    {
        *costPtr = StreamLZConstants.InvalidCost;
        byte* srcEnd = src + sourceLength;
        int tokCount = tokarray.Size;
        if (tokCount == 0)
        {
            return sourceLength;
        }

        HighRecentOffs recent = HighRecentOffs.Create();
        HighStreamWriter writer = default;
        InitializeStreamWriter(ref writer, lztemp, sourceLength, src, lzcoder.EncodeFlags);

        fixed (byte* _pinScratch0 = lztemp.HighEncoderScratch.Buffer)
        {
            src += (startPos == 0) ? 8 : 0;

            for (int i = 0; i < tokCount; i++)
            {
                Token* tok = tokarray.Data + i;
                AddToken(ref writer, ref recent, src, tok->LitLen, tok->MatchLen, tok->Offset,
                    doRecent: true, doSubtract: true);
                src += tok->LitLen + tok->MatchLen;
            }
            AddFinalLiterals(ref writer, src, srcEnd, doSubtract: true);
            return AssembleCompressedOutput(costPtr, chunkTypePtr, stat, dst, destinationEnd, lzcoder, lztemp, ref writer, startPos);
        }
    }
}
