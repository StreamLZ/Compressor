// EntropyEncoder.cs — Entropy encoding, cost estimation, and bitstream writing.
// Shared by High and Fast compressors.

using System.Numerics;
using System.Runtime.CompilerServices;
using StreamLZ.Common;

namespace StreamLZ.Compression.Entropy;

/// <summary>
/// Entropy encoding, cost estimation, and bitstream writing functions shared by
/// High and Fast compressors.
/// </summary>
internal static class EntropyEncoder
{
    /// <summary>Encode a byte array using memcpy (identity) encoding.</summary>
    public static unsafe int EncodeArrayU8_Memcpy(byte* dst, byte* dstEnd, byte* src, int count)
    {
        if (dst + count + 3 > dstEnd)
        {
            return -1;
        }
        // Header: 3-byte big-endian size (chunkType=0, memcpy mode)
        // Matches High_DecodeBytes: srcSize = (src[0]<<16) | (src[1]<<8) | src[2]
        dst[0] = (byte)(count >> 16);
        dst[1] = (byte)(count >> 8);
        dst[2] = (byte)count;
        dst += 3;
        Buffer.MemoryCopy(src, dst, dstEnd - dst, count);
        return count + 3;
    }

    /// <summary>Encode a byte array with pre-computed histogram. Tries tANS then falls back to memcpy.</summary>
    public static unsafe int EncodeArrayU8WithHisto(byte* dst, byte* dstEnd,
        byte* src, int count, HistoU8 histo,
        int entropyOpts, float speedTradeoff,
        float* cost, int level)
    {
        HistoU8 histoCopy = histo;
        return EncodeArrayU8Core(dst, dstEnd, src, count, &histoCopy,
            entropyOpts, speedTradeoff, cost, level);
    }

    /// <summary>Encode a byte array (build histo internally). Tries tANS then falls back to memcpy.</summary>
    public static unsafe int EncodeArrayU8(byte* dst, byte* dstEnd,
        byte* src, int count,
        int entropyOpts, float speedTradeoff,
        float* cost, int level, HistoU8* histoOut)
    {
        if (count <= 32)
        {
            if (histoOut != null)
            {
                CountBytesHistoU8(src, count, histoOut);
            }
            *cost = count + 3;
            return EncodeArrayU8_Memcpy(dst, dstEnd, src, count);
        }

        HistoU8 histo;
        CountBytesHistoU8(src, count, &histo);
        if (histoOut != null)
        {
            *histoOut = histo;
        }

        return EncodeArrayU8Core(dst, dstEnd, src, count, &histo,
            entropyOpts, speedTradeoff, cost, level);
    }

    /// <summary>Encode then convert to compact chunk header if possible.</summary>
    public static unsafe int EncodeArrayU8CompactHeader(byte* dst, byte* dstEnd,
        byte* src, int count,
        int entropyOpts, float speedTradeoff,
        float* cost, int level, HistoU8* histoOut)
    {
        int n = EncodeArrayU8(dst, dstEnd, src, count, entropyOpts, speedTradeoff, cost, level, histoOut);
        return n >= 0 ? MakeCompactChunkHdr(dst, n, cost) : -1;
    }

    /// <summary>
    /// Core encoding: tries tANS (if allowed), falls back to memcpy.
    /// Writes a complete chunk (header + data) to dst.
    /// </summary>
    private static unsafe int EncodeArrayU8Core(byte* dst, byte* dstEnd,
        byte* src, int count, HistoU8* histo,
        int entropyOpts, float speedTradeoff,
        float* cost, int level)
    {
        if (count <= 32)
        {
            *cost = count + 3;
            return EncodeArrayU8_Memcpy(dst, dstEnd, src, count);
        }

        float memcpyCost = count + 3;

        // Try tANS if allowed
        if ((entropyOpts & (int)EntropyOptions.AllowTANS) != 0)
        {
            // Reserve 5 bytes for non-compact header, encode tANS data after
            if (dstEnd - dst > 5)
            {
                float tansCost = memcpyCost;
                int tansN = TansEncoder.EncodeArrayU8_tANS(dst + 5, dstEnd, src, count,
                    (HistoU8*)histo, speedTradeoff, &tansCost);

                if (tansN > 0 && tansN < count && tansCost < memcpyCost)
                {
                    // Write 5-byte non-compact header (chunkType=1 = tANS)
                    WriteNonCompactChunkHeader(dst, 1, tansN, count);
                    *cost = tansCost;
                    return 5 + tansN;
                }
            }
        }

        // Fall back to memcpy
        *cost = memcpyCost;
        return EncodeArrayU8_Memcpy(dst, dstEnd, src, count);
    }

    /// <summary>Write a 5-byte non-compact chunk header for compressed data.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static unsafe void WriteNonCompactChunkHeader(byte* dst, int chunkType, int compressedSize, int decompressedSize)
    {
        uint dstMinus1 = (uint)(decompressedSize - 1);
        dst[0] = (byte)(((uint)chunkType << 4) | ((dstMinus1 >> 14) & 0xF));
        uint bits = (uint)compressedSize | ((dstMinus1 & 0x3FFF) << 18);
        dst[1] = (byte)(bits >> 24);
        dst[2] = (byte)(bits >> 16);
        dst[3] = (byte)(bits >> 8);
        dst[4] = (byte)bits;
    }

    /// <summary>
    /// Try to convert a 5-byte non-compact header to a 3-byte compact header.
    /// Saves 2 bytes when both srcSize and delta fit in 10 bits.
    /// </summary>
    private static unsafe int MakeCompactChunkHdr(byte* dst, int totalN, float* costPtr)
    {
        int chunkType = (dst[0] >> 4) & 7;
        if (chunkType == 0)
        {
            // Memcpy: try compact 2-byte header (saves 1 byte)
            int srcSize = (dst[0] << 16) | (dst[1] << 8) | dst[2];
            if (srcSize <= 0xFFF)
            {
                ushort hdr = (ushort)(0x8000 | srcSize);
                byte h0 = (byte)(hdr >> 8), h1 = (byte)hdr;
                Buffer.MemoryCopy(dst + 3, dst + 2, srcSize, srcSize);
                dst[0] = h0;
                dst[1] = h1;
                *costPtr -= 1;
                return totalN - 1;
            }
        }
        else
        {
            // Compressed: try compact 3-byte header (saves 2 bytes)
            uint bits5 = (uint)((dst[1] << 24) | (dst[2] << 16) | (dst[3] << 8) | dst[4]);
            int srcSize = (int)(bits5 & 0x3ffff);
            int dstSize = (int)(((bits5 >> 18) | ((uint)dst[0] << 14)) & 0x3FFFF) + 1;
            int delta = dstSize - srcSize - 1;

            if (srcSize <= 0x3FF && delta <= 0x3FF)
            {
                uint bits3 = (uint)srcSize | ((uint)delta << 10) | ((uint)chunkType << 20) | (1u << 23);
                byte b0 = (byte)(bits3 >> 16);
                byte b1 = (byte)(bits3 >> 8);
                byte b2 = (byte)bits3;
                Buffer.MemoryCopy(dst + 5, dst + 3, srcSize, srcSize);
                dst[0] = b0;
                dst[1] = b1;
                dst[2] = b2;
                *costPtr -= 2;
                return totalN - 2;
            }
        }

        return totalN;
    }

    /// <summary>Encode LZ offsets using the real OffsetEncoder pipeline.</summary>
    public static unsafe int EncodeLzOffsets(byte* dst, byte* dstEnd,
        byte* u8Offs, uint* u32Offs, int offsCount,
        int entropyOpts, float speedTradeoff,
        float* cost, int minMatchLen, bool useOffsetModuloCoding,
        int* offsEncodeType, int level,
        HistoU8* histoOut, HistoU8* histoLoOut)
    {
        return OffsetEncoder.EncodeLzOffsets(dst, dstEnd, u8Offs, u32Offs, offsCount,
            entropyOpts, speedTradeoff, cost, minMatchLen, useOffsetModuloCoding,
            offsEncodeType, level, histoOut, histoLoOut);
    }

    /// <summary>Write LZ offset extra bits via the real OffsetEncoder implementation.</summary>
    public static unsafe int WriteLzOffsetBits(byte* dst, byte* dstEnd,
        byte* u8Offs, uint* u32Offs, int offsCount, int offsEncodeType,
        uint* u32Len, int u32LenCount,
        int flagIgnoreU32Length)
    {
        return OffsetEncoder.WriteLzOffsetBits(dst, dstEnd,
            u8Offs, u32Offs, offsCount, offsEncodeType,
            u32Len, u32LenCount, flagIgnoreU32Length);
    }

    /// <summary>Count byte-value histogram.</summary>
    public static unsafe void CountBytesHistoU8(byte* src, int count, HistoU8* histo)
    {
        for (int i = 0; i < 256; i++)
        {
            histo->Count[i] = 0;
        }
        for (int i = 0; i < count; i++)
        {
            histo->Count[src[i]]++;
        }
    }

    /// <summary>Compute hash bits based on source length and level.</summary>
    public static int GetHashBits(int srcLen, int level, CompressOptions copts,
                                   int minLowLevelBits, int maxLowLevelBits, int minHighLevelBits, int maxHighLevelBits)
    {
        if (copts.HashBits > 0)
        {
            return copts.HashBits;
        }
        int bits = BitOperations.Log2((uint)Math.Max(srcLen, 1)) + 1;
        bits = Math.Clamp(bits, minLowLevelBits, level >= 5 ? maxHighLevelBits : level >= 3 ? minHighLevelBits : maxLowLevelBits);
        return bits;
    }
}
