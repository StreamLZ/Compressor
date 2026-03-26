// OffsetEncoder.cs -- Offset encoding functions for StreamLZ compression.

using System.Buffers;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;
using static StreamLZ.Compression.CompressUtils;

namespace StreamLZ.Compression.Entropy;

/// <summary>
/// Encodes LZ match offsets for StreamLZ-format compressed streams.
/// </summary>
internal static unsafe class OffsetEncoder
{
    // ----------------------------------------------------------------
    //  SubtractBytes / SubtractBytesUnsafe -- delta-encode literals
    // ----------------------------------------------------------------

    /// <summary>
    /// Byte-wise subtraction: <c>dst[i] = src[i] - src[i + negOffset]</c>.
    /// Safe version that handles any length exactly.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    [SkipLocalsInit]
    public static void SubtractBytes(byte* dst, byte* src, nuint len, nuint negOffset)
    {
        if (Vector128.IsHardwareAccelerated)
        {
            while (len >= 16)
            {
                var a = Vector128.Load(src);
                var b = Vector128.Load(src + negOffset);
                Vector128.Store(a - b, dst);
                src += 16;
                dst += 16;
                len -= 16;
            }
        }

        while (len > 0)
        {
            dst[0] = (byte)(src[0] - src[negOffset]);
            src++;
            dst++;
            len--;
        }
    }

    /// <summary>
    /// Byte-wise subtraction: <c>dst[i] = src[i] - src[i + negOffset]</c>.
    /// Unsafe version that may read/write past the end (up to 15 extra bytes).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    [SkipLocalsInit]
    public static void SubtractBytesUnsafe(byte* dst, byte* src, nuint len, nuint negOffset)
    {
        if (Vector128.IsHardwareAccelerated)
        {
            if (len > 8)
            {
                nuint loops = (len + 7) / 16;
                do
                {
                    var a = Vector128.Load(src);
                    var b = Vector128.Load(src + negOffset);
                    Vector128.Store(a - b, dst);
                    src += 16;
                    dst += 16;
                } while (--loops != 0);
            }

            // Final 8-byte tail: scalar subtraction (8 bytes is below Vector128 width,
            // and there's no cross-platform 64-bit vector load)
            for (nuint i = 0; i < 8; i++)
                dst[i] = (byte)(src[i] - src[i + negOffset]);
        }
        else
        {
            // Scalar fallback
            for (nuint i = 0; i < len; i++)
            {
                dst[i] = (byte)(src[i] - src[i + negOffset]);
            }
        }
    }

    // ----------------------------------------------------------------
    //  Histogram cost helpers
    // ----------------------------------------------------------------

    // Log2 interpolation lookup table
    private static ReadOnlySpan<ushort> Log2Lookup =>
    [
        0, 183, 364, 541, 716, 889, 1059, 1227, 1392, 1555, 1716, 1874,
        2031, 2186, 2338, 2489, 2637, 2784, 2929, 3072, 3214, 3354, 3492,
        3629, 3764, 3897, 4029, 4160, 4289, 4417, 4543, 4668, 4792, 4914,
        5036, 5156, 5274, 5392, 5509, 5624, 5738, 5851, 5963, 6074, 6184,
        6293, 6401, 6508, 6614, 6719, 6823, 6926, 7029, 7130, 7231, 7330,
        7429, 7527, 7625, 7721, 7817, 7912, 8006, 8099, 8192,
    ];

    /// <summary>
    /// Interpolated log2 approximation.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static int GetLog2Interpolate(uint x)
    {
        int idx = (int)(x >> 26);
        int lo = Log2Lookup[idx];
        int hi = Log2Lookup[idx + 1];
        return lo + (int)((((x >> 10) & 0xFFFF) * (uint)(hi - lo) + 0x8000) >> 16);
    }

    /// <summary>
    /// Converts a histogram to approximate entropy cost per symbol.
    /// </summary>
    public static void ConvertHistoToCost(HistoU8* src, uint* dst, int extra, int maxSymbolCount = 255)
    {
        uint histoSum = 0;
        for (int i = 0; i < 256; i++)
        {
            histoSum += src->Count[i];
        }

        int totalCount = 256 + 4 * (int)histoSum;
        int bits = 32 - (int)BitOperations.Log2((uint)totalCount);
        int baseCost = (bits << 13) - GetLog2Interpolate((uint)totalCount << bits);
        int sumOfBits = 0;

        for (int i = 0; i < 256; i++)
        {
            int count = (int)(src->Count[i] * 4 + 1);
            bits = 32 - (int)BitOperations.Log2((uint)count);
            int bp = (32 * ((bits << 13) - GetLog2Interpolate((uint)count << bits) - baseCost)) >> 13;
            sumOfBits += count * bp;
            dst[i] = (uint)(bp + extra);
        }

        if (sumOfBits > maxSymbolCount * totalCount)
        {
            for (int i = 0; i < 256; i++)
            {
                dst[i] = (uint)(8 * 32 + extra);
            }
        }
    }

    // The full Log2LookupTable is 4097 entries.  We generate it at class init time
    // The table maps x -> 4096 * log2(4096/x).
    internal static readonly uint[] Log2LookupTable = BuildLog2LookupTable();

    private static uint[] BuildLog2LookupTable()
    {
        var table = new uint[StreamLZConstants.Log2LookupTableSize];
        table[0] = 0;
        for (int i = 1; i <= 4096; i++)
        {
            table[i] = (uint)(4096.0 * Math.Log2(4096.0 / i));
        }
        return table;
    }

    /// <summary>
    /// Approximate entropy cost of a uint* histogram array.
    /// Delegates to <see cref="HistoU8.GetCostApproxCore"/> when called with a
    /// <see cref="HistoU8"/> pointer.
    /// </summary>
    internal static uint GetHistoCostApprox(uint* histo, int arrSize, int histoSum)
    {
        fixed (uint* log2Table = Log2LookupTable)
        {
            return HistoU8.GetCostApproxCore(histo, arrSize, histoSum, log2Table);
        }
    }

    /// <summary>
    /// Approximate entropy cost of a <see cref="HistoU8"/>.
    /// </summary>
    internal static uint GetHistoCostApprox(HistoU8* h, int histoSum)
    {
        fixed (uint* log2Table = Log2LookupTable)
        {
            return h->GetCostApprox(histoSum, log2Table);
        }
    }

    // ----------------------------------------------------------------
    //  GetCostModularOffsets -- cost estimate for a given encoding type
    // ----------------------------------------------------------------

    /// <summary>
    /// Computes the approximate cost of encoding an offset array with the
    /// given <paramref name="offsEncodeType"/>.
    /// </summary>
    [SkipLocalsInit]
    internal static float GetCostModularOffsets(
        uint offsEncodeType, uint* u32Offs, int offsCount,
        float speedTradeoff)
    {
        Span<uint> lowHisto = stackalloc uint[128];
        lowHisto.Clear();

        HistoU8 highHisto = default;

        uint bitsForData = 0;
        for (int i = 0; i < offsCount; i++)
        {
            uint offset = u32Offs[i];
            uint ohi = offset / offsEncodeType;
            uint olo = offset % offsEncodeType;
            uint extraBitCount = (uint)(BitOperations.Log2(ohi + 8) - 3);
            uint highSymbol = 8 * extraBitCount | (((ohi + 8) >> (int)extraBitCount) ^ 8);
            bitsForData += extraBitCount;
            highHisto.Count[highSymbol]++;
            lowHisto[(int)olo]++;
        }

        uint highHistoSum = highHisto.GetSum();
        fixed (uint* log2Table = Log2LookupTable)
        {
            float cost = BitsUp(highHisto.GetCostApprox((int)highHistoSum, log2Table)) + BitsUp(bitsForData);

            if (offsEncodeType > 1)
            {
                cost += (offsCount * CostCoefficients.Current.OffsetModularPerItem + CostCoefficients.Current.OffsetModularBase) * speedTradeoff;
                fixed (uint* pLow = lowHisto)
                    cost += BitsUp(GetHistoCostApprox(pLow, 128, offsCount));
                cost += (CostCoefficients.Current.SingleHuffmanBase + offsCount * CostCoefficients.Current.SingleHuffmanPerItem + 128 * CostCoefficients.Current.SingleHuffmanPerSymbol) * speedTradeoff;
            }

            return cost;
        }
    }

    // ----------------------------------------------------------------
    //  GetBestOffsetEncodingFast / Slow
    // ----------------------------------------------------------------

    /// <summary>
    /// Finds the best offset modulo encoding divisor quickly by looking at the
    /// top-4 most common small offsets.
    /// </summary>
    [SkipLocalsInit]
    internal static int GetBestOffsetEncodingFast(
        uint* u32Offs, int offsCount, float speedTradeoff)
    {
        Span<uint> arr = stackalloc uint[129];
        for (int i = 0; i < 129; i++)
        {
            arr[i] = (uint)i;
        }

        for (int i = 0; i < offsCount; i++)
        {
            if (u32Offs[i] <= 128)
            {
                arr[(int)u32Offs[i]] += 256;
            }
        }

        // Sort descending
        arr.Sort((a, b) => b.CompareTo(a));

        float bestCost = GetCostModularOffsets(1, u32Offs, offsCount, speedTradeoff);
        int bestOffsEncodeType = 1;

        for (int i = 0; i < 4; i++)
        {
            uint offsEncodeType = (byte)arr[i];
            if (offsEncodeType > 1)
            {
                float cost = GetCostModularOffsets(offsEncodeType, u32Offs, offsCount, speedTradeoff);
                if (cost < bestCost)
                {
                    bestOffsEncodeType = (int)offsEncodeType;
                    bestCost = cost;
                }
            }
        }

        return bestOffsEncodeType;
    }

    /// <summary>
    /// Exhaustive search over all modulo divisors 1..128.
    /// </summary>
    internal static int GetBestOffsetEncodingSlow(
        uint* u32Offs, int offsCount, float speedTradeoff)
    {
        if (offsCount < 32)
        {
            return 1;
        }

        int bestOffsEncodeType = 0;
        float bestCost = StreamLZConstants.InvalidCost;

        for (uint offsEncodeType = 1; offsEncodeType <= 128; offsEncodeType++)
        {
            float cost = GetCostModularOffsets(offsEncodeType, u32Offs, offsCount, speedTradeoff);
            if (cost < bestCost)
            {
                bestOffsEncodeType = (int)offsEncodeType;
                bestCost = cost;
            }
        }

        return bestOffsEncodeType;
    }

    // ----------------------------------------------------------------
    //  EncodeNewOffsets -- re-encodes offsets with a modulo divisor
    // ----------------------------------------------------------------

    /// <summary>
    /// Splits each offset into high (quotient) and low (remainder) parts using
    /// the given <paramref name="offsEncodeType"/> divisor.
    /// </summary>
    internal static void EncodeNewOffsets(
        uint* u32Offs, int offsCount,
        byte* u8OffsHi, byte* u8OffsLo,
        int* bitsType1Ptr, int offsEncodeType,
        byte* u8Offs, int* bitsType0Ptr)
    {
        int bitsType0 = 0, bitsType1 = 0;

        if (offsEncodeType == 1)
        {
            for (int i = 0; i < offsCount; i++)
            {
                bitsType0 += (u8Offs[i] >= StreamLZConstants.HighOffsetMarker)
                    ? u8Offs[i] - StreamLZConstants.HighOffsetCostAdjust
                    : (u8Offs[i] >> 4) + 5;

                uint hi = u32Offs[i];
                int extraBitCount = (int)BitOperations.Log2(hi + 8) - 3;
                u8OffsHi[i] = (byte)(8 * extraBitCount | (int)(((hi + 8) >> extraBitCount) ^ 8));
                bitsType1 += extraBitCount;
            }
        }
        else
        {
            for (int i = 0; i < offsCount; i++)
            {
                bitsType0 += (u8Offs[i] >= StreamLZConstants.HighOffsetMarker)
                    ? u8Offs[i] - StreamLZConstants.HighOffsetCostAdjust
                    : (u8Offs[i] >> 4) + 5;

                uint offs = u32Offs[i];
                uint lo = offs % (uint)offsEncodeType;
                uint hi = offs / (uint)offsEncodeType;
                int extraBitCount = (int)BitOperations.Log2(hi + 8) - 3;
                u8OffsHi[i] = (byte)(8 * extraBitCount | (int)(((hi + 8) >> extraBitCount) ^ 8));
                u8OffsLo[i] = (byte)lo;
                bitsType1 += extraBitCount;
            }
        }

        *bitsType0Ptr = bitsType0;
        *bitsType1Ptr = bitsType1;
    }

    // ----------------------------------------------------------------
    //  WriteLzOffsetBits -- writes packed raw offset bits to output
    //  Uses BitWriter64Forward / BitWriter64Backward from BitWriter.cs
    // ----------------------------------------------------------------

    /// <summary>
    /// Writes the variable-length offset bit fields into a dual-ended bitstream.
    /// </summary>
    /// <param name="dst">Start of output buffer.</param>
    /// <param name="dstEnd">End of output buffer.</param>
    /// <param name="u8Offs">Packed 1-byte offset descriptors.</param>
    /// <param name="u32Offs">Full 32-bit offsets.</param>
    /// <param name="offsCount">Number of offsets.</param>
    /// <param name="offsEncodeType">Offset modulo divisor (0 = legacy encoding).</param>
    /// <param name="u32Len">Lengths array for extended matches.</param>
    /// <param name="u32LenCount">Number of extended lengths.</param>
    /// <param name="flagIgnoreU32Length">If nonzero, skip writing the length header/data.</param>
    /// <returns>Number of bytes written, or -1 on overflow.</returns>
    [SkipLocalsInit]
    public static int WriteLzOffsetBits(
        byte* dst, byte* dstEnd,
        byte* u8Offs, uint* u32Offs, int offsCount,
        int offsEncodeType,
        uint* u32Len, int u32LenCount,
        int flagIgnoreU32Length)
    {
        if (dstEnd - dst <= 16)
        {
            return -1;
        }

        var f = new BitWriter64Forward(dst);
        var b = new BitWriter64Backward(dstEnd);

        // Write length-count header
        if (flagIgnoreU32Length == 0)
        {
            int nb = (int)BitOperations.Log2((uint)(u32LenCount + 1));
            b.Write(1, nb + 1);
            if (nb != 0)
            {
                b.Write((uint)(u32LenCount + 1 - (1 << nb)), nb);
            }
        }

        // Write offset bits
        if (offsEncodeType != 0)
        {
            for (int i = 0; i < offsCount; i++)
            {
                if (b.Position - f.Position <= 8)
                {
                    return -1;
                }

                uint nb = (uint)(u8Offs[i] >> 3);
                uint bits = ((1u << (int)nb) - 1) & (u32Offs[i] / (uint)offsEncodeType + 8);
                if ((i & 1) != 0)
                {
                    b.Write(bits, (int)nb);
                }
                else
                {
                    f.Write(bits, (int)nb);
                }
            }
        }
        else
        {
            for (int i = 0; i < offsCount; i++)
            {
                if (b.Position - f.Position <= 8)
                {
                    return -1;
                }

                uint nb;
                uint bits = u32Offs[i];
                if (u8Offs[i] < StreamLZConstants.HighOffsetMarker)
                {
                    nb = (uint)((u8Offs[i] >> 4) + 5);
                    bits = ((bits + StreamLZConstants.OffsetBiasConstant) >> 4) - (1u << (int)nb);
                }
                else
                {
                    nb = (uint)(u8Offs[i] - StreamLZConstants.HighOffsetCostAdjust);
                    bits = bits - (1u << (int)nb) - (uint)StreamLZConstants.LowOffsetEncodingLimit;
                }

                if ((i & 1) != 0)
                {
                    b.Write(bits, (int)nb);
                }
                else
                {
                    f.Write(bits, (int)nb);
                }
            }
        }

        // Write extended match lengths
        if (flagIgnoreU32Length == 0)
        {
            for (int i = 0; i < u32LenCount; i++)
            {
                if (b.Position - f.Position <= 8)
                {
                    return -1;
                }

                uint len = u32Len[i];
                int nb = (int)BitOperations.Log2((len >> 6) + 1);

                if ((i & 1) != 0)
                {
                    b.Write(1, nb + 1);
                    if (nb != 0)
                    {
                        b.Write((len >> 6) + 1 - (1u << nb), nb);
                    }
                    b.Write(len & 0x3F, 6);
                }
                else
                {
                    f.Write(1, nb + 1);
                    if (nb != 0)
                    {
                        f.Write((len >> 6) + 1 - (1u << nb), nb);
                    }
                    f.Write(len & 0x3F, 6);
                }
            }
        }

        byte* fp = f.GetFinalPtr();
        byte* bp = b.GetFinalPtr();

        if (bp - fp <= 8)
        {
            return -1;
        }

        // Move backward portion forward, adjacent to forward portion
        Buffer.MemoryCopy(bp, fp, dstEnd - fp, dstEnd - bp);
        return (int)(dstEnd - bp + fp - dst);
    }

    // ----------------------------------------------------------------
    //  EncodeLzOffsets -- main offset encoding entry point
    // ----------------------------------------------------------------

    /// <summary>
    /// Encodes the LZ offset stream, choosing between legacy encoding and
    /// modulo-based encoding. Returns encoded byte count, or -1 on failure.
    /// </summary>
    /// <param name="dst">Output buffer start.</param>
    /// <param name="dstEnd">Output buffer end.</param>
    /// <param name="u8Offs">Packed 1-byte offset descriptors (may be overwritten).</param>
    /// <param name="u32Offs">Full 32-bit offsets.</param>
    /// <param name="offsCount">Number of offsets.</param>
    /// <param name="opts">Entropy encoding options.</param>
    /// <param name="speedTradeoff">Speed vs. ratio tradeoff factor.</param>
    /// <param name="costPtr">Receives the estimated cost of the chosen encoding.</param>
    /// <param name="minMatchLen">Minimum match length (8 = special fast path).</param>
    /// <param name="useOffsetModuloCoding">Whether to try modulo-based encoding.</param>
    /// <param name="offsEncodeTypePtr">Receives the chosen encoding type (0 = legacy).</param>
    /// <param name="level">Compression level.</param>
    /// <param name="histoPtr">Optional -- receives the high-byte histogram.</param>
    /// <param name="histoLoPtr">Optional -- receives the low-byte histogram.</param>
    /// <returns>Encoded byte count, or -1 on failure.</returns>
    [SkipLocalsInit]
    public static int EncodeLzOffsets(
        byte* dst, byte* dstEnd,
        byte* u8Offs, uint* u32Offs, int offsCount,
        int opts, float speedTradeoff,
        float* costPtr, int minMatchLen, bool useOffsetModuloCoding,
        int* offsEncodeTypePtr, int level,
        HistoU8* histoPtr, HistoU8* histoLoPtr)
    {
        int n = int.MaxValue;

        *costPtr = StreamLZConstants.InvalidCost;

        // Fast path for minMatchLen == 8: encode with plain array encoder
        if (minMatchLen == 8)
        {
            n = HighEntropyEncoder.EncodeArrayU8(dst, dstEnd, u8Offs, offsCount, opts,
                speedTradeoff, costPtr, level, histoPtr);
            if (n < 0)
            {
                return -1;
            }

            *costPtr += (offsCount * CostCoefficients.Current.OffsetType0PerItem + CostCoefficients.Current.OffsetType0Base) * speedTradeoff;
        }

        uint offsEncodeType = 0;

        if (useOffsetModuloCoding)
        {
            int tempSize = offsCount * 4 + 16;
            byte[] tempRented = ArrayPool<byte>.Shared.Rent(tempSize);
            try
            {
                fixed (byte* temp = tempRented)
                {
                    offsEncodeType = 1;
                    if (level >= 8)
                    {
                        offsEncodeType = (uint)GetBestOffsetEncodingSlow(
                            u32Offs, offsCount, speedTradeoff);
                    }
                    else if (level >= 4)
                    {
                        offsEncodeType = (uint)GetBestOffsetEncodingFast(
                            u32Offs, offsCount, speedTradeoff);
                    }

                    byte* u8OffsHi = temp;
                    byte* u8OffsLo = temp + offsCount;
                    byte* tmpDstStart = temp + offsCount * 2;
                    byte* tmpDstEnd = temp + offsCount * 4 + 16;

                    int bitsType1, bitsType0;
                    EncodeNewOffsets(u32Offs, offsCount, u8OffsHi, u8OffsLo,
                        &bitsType1, (int)offsEncodeType, u8Offs, &bitsType0);

                    byte* tmpDst = tmpDstStart;
                    *tmpDst++ = (byte)(offsEncodeType + 127);

                    HistoU8 histoBuf = default;
                    float cost = StreamLZConstants.InvalidCost;

                    int n1 = HighEntropyEncoder.EncodeArrayU8CompactHeader(tmpDst, tmpDstEnd,
                        u8OffsHi, offsCount, opts, speedTradeoff, &cost, level,
                        histoPtr != null ? &histoBuf : null);
                    if (n1 < 0)
                    {
                        return -1;
                    }
                    tmpDst += n1;

                    float costLo = 0.0f;
                    if (offsEncodeType > 1)
                    {
                        costLo = StreamLZConstants.InvalidCost;
                        n1 = HighEntropyEncoder.EncodeArrayU8CompactHeader(tmpDst, tmpDstEnd,
                            u8OffsLo, offsCount, opts, speedTradeoff, &costLo, level,
                            histoLoPtr);
                        if (n1 < 0)
                        {
                            return -1;
                        }
                        tmpDst += n1;
                    }

                    float ultraOffsetTime;
                    if (offsEncodeType == 1)
                    {
                        ultraOffsetTime = offsCount * CostCoefficients.Current.OffsetType0PerItem + CostCoefficients.Current.OffsetType0Base;
                    }
                    else
                    {
                        ultraOffsetTime = offsCount * CostCoefficients.Current.OffsetType1PerItem + CostCoefficients.Current.OffsetType1Base;
                        if (offsEncodeType > 1)
                        {
                            ultraOffsetTime += offsCount * CostCoefficients.Current.OffsetModularPerItem + CostCoefficients.Current.OffsetModularBase;
                        }
                    }
                    cost = cost + 1.0f + costLo + ultraOffsetTime * speedTradeoff;

                    if (BitsUp((uint)bitsType0) + *costPtr <= BitsUp((uint)bitsType1) + cost)
                    {
                        offsEncodeType = 0;
                    }
                    else
                    {
                        *costPtr = cost;
                        n = (int)(tmpDst - tmpDstStart);
                        Buffer.MemoryCopy(tmpDstStart, dst, dstEnd - dst, n);
                        Buffer.MemoryCopy(u8OffsHi, u8Offs, offsCount, offsCount);
                        if (histoPtr != null)
                        {
                            *histoPtr = histoBuf;
                        }
                    }
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(tempRented);
            }
        }

        *offsEncodeTypePtr = (int)offsEncodeType;
        return n;
    }
}
