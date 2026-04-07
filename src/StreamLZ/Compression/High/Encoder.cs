// Encoder.cs — Stream init, token writing, and array encoding for the High compressor.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    // The HighStreamWriter writes to 7 separate output streams (literals, delta-literals,
    // tokens, near offsets, far offsets, run-lengths, overflow lengths). Each stream is a
    // contiguous region within a single allocation. This split-stream layout is critical:
    // the decoder reads each stream sequentially, giving perfect L1 cache behavior.
    // Interleaving them into a single stream would cause random access patterns.
    internal static void InitializeStreamWriter(ref HighStreamWriter writer, LzTemp lztemp, int sourceLength, byte* srcBase, int encodeFlags)
    {
        writer.SrcPtr = srcBase;
        writer.SrcLen = sourceLength;

        // Capacity estimates are generous worst-cases (all-literals, all-matches, etc.).
        // Over-allocating is fine — this is scratch memory reused across chunks.
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
            writer.LiteralsStart = writer.Literals = p; p += literalCapacity;
            writer.DeltaLiteralsStart = writer.DeltaLiterals = p; p += literalCapacity;
            writer.TokensStart = writer.Tokens = p; p += tokenCapacity;
            writer.NearOffsets = writer.NearOffsetsStart = p; p += u8OffsetCapacity;
            // Align to 4
            p = (byte*)(((nuint)p + 3) & ~(nuint)3);
            writer.FarOffsets = writer.FarOffsetsStart = (uint*)p; p += u32OffsetCapacity * 4;
            writer.LiteralRunLengths = writer.LiteralRunLengthsStart = p; p += runLength8Capacity;
            p = (byte*)(((nuint)p + 3) & ~(nuint)3);
            writer.OverflowLengths = writer.OverflowLengthsStart = (uint*)p;
        }

        writer.Recent0 = StreamLZConstants.InitialRecentOffset;
        writer.EncodeFlags = encodeFlags;
    }

    // Match length encoding: the command byte has a 4-bit matchLen field (bits 5:2).
    // Values 0-14 encode lengths 2-16 inline. Value 15 is a sentinel that signals
    // "read the real length from the run-length stream." Lengths >= 255+17 overflow
    // into a separate 32-bit stream to keep the u8 run-length stream compact.
    // Returns the matchLen contribution to the command byte, pre-shifted to bits 5:2.
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int WriteMatchLength(ref HighStreamWriter writer, int matchLength)
    {
        int mlToken = matchLength - 2;
        if (mlToken >= 15)
        {
            mlToken = 15;
            if (matchLength >= 255 + 17)
            {
                *writer.LiteralRunLengths++ = 255;
                *writer.OverflowLengths++ = (uint)(matchLength - 255 - 17);
            }
            else
            {
                *writer.LiteralRunLengths++ = (byte)(matchLength - 17);
            }
        }
        return mlToken << 2;
    }

    private static void WriteLiteralsLong(ref HighStreamWriter writer, byte* p, nint len, bool doSubtract)
    {
        if (doSubtract)
        {
            OffsetEncoder.SubtractBytesUnsafe(writer.DeltaLiterals, p, (nuint)len, (nuint)(-writer.Recent0));
            writer.DeltaLiterals += len;
        }

        byte* d = writer.Literals;
        byte* dEnd = d + len;
        do
        {
            *(uint*)d = *(uint*)p;
            d += 4; p += 4;
        } while (d < dEnd);
        writer.Literals = dEnd;

        if (len >= 258)
        {
            *writer.LiteralRunLengths++ = 255;
            *writer.OverflowLengths++ = (uint)(len - 258);
        }
        else
        {
            *writer.LiteralRunLengths++ = (byte)(len - 3);
        }
    }

    // Literal length encoding mirrors match length: the command byte has a 2-bit litLen
    // field (bits 1:0). Values 0-2 encode lengths 0-2 inline. Value 3 is a sentinel
    // meaning "read from the run-length stream." This method returns the litLen bits
    // for the command byte (0, 1, 2, or 3).
    //
    // Short literals (<= 8 bytes) are copied with a single 8-byte unaligned write,
    // which may overshoot but is safe because the literal buffer has headroom.
    // The run-length byte is speculatively written and the pointer conditionally advanced
    // to avoid a branch on the common len < 3 case.
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

        // Branchless run-length write: always write (len - 3), but only advance the
        // pointer when len >= 3. When len < 3, the written byte is harmlessly overwritten
        // by the next call. This saves a branch on every short-literal token.
        byte* lrl8 = writer.LiteralRunLengths;
        *lrl8 = (byte)(len - 3);
        writer.LiteralRunLengths = (len >= 3) ? lrl8 + 1 : lrl8;

        byte* ll = writer.Literals;
        *(ulong*)ll = *(ulong*)p;
        writer.Literals = ll + len;

        if (doSubtract)
        {
            byte* sl = writer.DeltaLiterals;
            for (nint i = 0; i < len; i++)
            {
                sl[i] = (byte)(p[i] - p[i - writer.Recent0]);
            }
            writer.DeltaLiterals = sl + len;
        }
        return (int)Math.Min(len, 3);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteFarOffset(ref HighStreamWriter writer, uint offset)
    {
        int bsr = (int)(uint)BitOperations.Log2(offset - (uint)StreamLZConstants.LowOffsetEncodingLimit);
        *writer.NearOffsets++ = (byte)(bsr | StreamLZConstants.HighOffsetMarker);
        *writer.FarOffsets++ = offset;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteNearOffset(ref HighStreamWriter writer, uint offset)
    {
        int bsr = (int)(uint)BitOperations.Log2(offset + StreamLZConstants.OffsetBiasConstant);
        *writer.NearOffsets++ = (byte)(((offset - 8) & 0xF) | (uint)(16 * (bsr - 9)));
        *writer.FarOffsets++ = offset;
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

    // AddToken assembles one command byte from three fields: litLen (bits 1:0),
    // matchLen (bits 5:2), and offsetIndex (bits 7:6). The command byte is written
    // last because WriteLiterals and WriteMatchLength may emit overflow bytes to
    // their respective side streams, and the token byte must reflect whether those
    // overflows occurred (litLen==3 or matchLen==15 sentinels).
    //
    // offsOrRecent > 0 means "new offset" (index 3 in the decoder's carousel);
    // offsOrRecent <= 0 means "reuse recent offset" at index -offsOrRecent (0, 1, or 2).
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
            Buffer.MemoryCopy(p, writer.Literals, len, len);
            writer.Literals += len;
            if (doSubtract)
            {
                OffsetEncoder.SubtractBytes(writer.DeltaLiterals, p, (nuint)len, (nuint)(-writer.Recent0));
                writer.DeltaLiterals += len;
            }
        }
    }

    // AssembleCompressedOutput entropy-encodes each of the 5 sub-streams (literals, tokens,
    // offsets, run-lengths, overflow-bits) and concatenates them into the final compressed
    // output. It also decides between raw literals (Type1) and delta-coded literals (Type0)
    // based on estimated entropy cost, and falls back to memcpy if compression doesn't help.
    // Returns sourceLength (uncompressed) if compression is not worthwhile.
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

        int numLits = (int)(writer.Literals - writer.LiteralsStart);
        float litCost = StreamLZConstants.InvalidCost;
        float memcpyCost = numLits + 3;

        if (numLits < 32 || level <= -4)
        {
            *chunkTypePtr = 1;
            int n = EntropyEncoder.EncodeArrayU8_Memcpy(dst, destinationEnd, writer.LiteralsStart, numLits);
            if (n < 0)
            {
                return sourceLength;
            }
            dst += n;
            litCost = memcpyCost;
        }
        else
        {
            ByteHistogram litsHisto, litsubHisto;
            bool hasLitsub = writer.DeltaLiterals != writer.DeltaLiteralsStart;

            EntropyEncoder.CountBytesHistogram(writer.LiteralsStart, numLits, &litsHisto);
            if (hasLitsub)
            {
                EntropyEncoder.CountBytesHistogram(writer.DeltaLiteralsStart, numLits, &litsubHisto);
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
                    litN = EntropyEncoder.EncodeArrayU8WithHisto(dst, destinationEnd, writer.DeltaLiteralsStart, numLits,
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
                int n = EntropyEncoder.EncodeArrayU8WithHisto(dst, destinationEnd, writer.LiteralsStart, numLits,
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
            writer.NearOffsetsStart, writer.FarOffsetsStart,
            (int)(writer.NearOffsets - writer.NearOffsetsStart),
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
        int lrl8N = EntropyEncoder.EncodeArrayU8(dst, destinationEnd, writer.LiteralRunLengthsStart,
            (int)(writer.LiteralRunLengths - writer.LiteralRunLengthsStart),
            lzcoder.EntropyOptions, lzcoder.SpeedTradeoff,
            &lrl8Cost, level, stats != null ? &stats->MatchLenHisto : null);
        if (lrl8N < 0)
        {
            return sourceLength;
        }
        dst += lrl8N;

        int lrlNum = (int)(writer.LiteralRunLengths - writer.LiteralRunLengthsStart);
        int offsNum = (int)(writer.NearOffsets - writer.NearOffsetsStart);
        int tokNum = (int)(writer.Tokens - writer.TokensStart);
        int required = Math.Max(lrlNum, offsNum) + lrlNum + numLits + 4 * lrlNum + 6 * offsNum + tokNum + 16;
        required = Math.Max(Math.Max(required, 2 * numLits), numLits + 2 * tokNum) + StreamLZConstants.EntropyScratchSize;
        int scratchAvailable = StreamLZConstants.CalculateScratchSize(sourceLength);
        if (required > scratchAvailable)
        {
            Debug.Assert(required <= scratchAvailable);
            return sourceLength;
        }

        int bitsN = EntropyEncoder.WriteLzOffsetBits(dst, destinationEnd, writer.NearOffsetsStart, writer.FarOffsetsStart,
            offsNum, offsEncodeType,
            writer.OverflowLengthsStart, (int)(writer.OverflowLengths - writer.OverflowLengthsStart),
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
        *costPtr = (float)((CostCoefficients.Current.LengthBase + lrlNum * CostCoefficients.Current.LengthU8PerItem + (int)(writer.OverflowLengths - writer.OverflowLengthsStart) * CostCoefficients.Current.LengthU32PerItem) *
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
