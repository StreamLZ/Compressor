// HuffmanDecoder.CodeLengths.cs — Golomb-Rice decoding, code-length table reading, and LUT construction.

using System.Buffers.Binary;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Decompression.Entropy;

internal static unsafe partial class HuffmanDecoder
{
    #region Golomb-Rice decoding

    /// <summary>
    /// Decodes Golomb-Rice run-lengths from a bit stream.
    /// Uses the KRiceCodeBits2Value/KRiceCodeBits2Len lookup tables for fast byte-at-a-time decoding.
    /// </summary>
    [SkipLocalsInit]
    public static bool DecodeGolombRiceLengths(byte* dst, int size, ref BitReader2 br)
    {
        byte* p = br.P;
        byte* pEnd = br.PEnd;
        byte* dstEnd = dst + size;

        if (p >= pEnd)
        {
            return false;
        }

        int count = -(int)br.Bitpos;
        uint v = (uint)(*p++ & (255 >> (int)br.Bitpos));

        for (; ; )
        {
            if (v == 0)
            {
                count += 8;
            }
            else
            {
                uint x = KRiceCodeBits2Value[(int)v];
                *(uint*)&dst[0] = (uint)count + (x & 0x0f0f0f0fu);
                *(uint*)&dst[4] = (x >> 4) & 0x0f0f0f0fu;
                dst += KRiceCodeBits2Len[(int)v];
                if (dst >= dstEnd)
                {
                    break;
                }
                count = (int)(x >> 28);
            }
            if (p >= pEnd)
            {
                return false;
            }
            v = *p++;
        }

        // Went too far, step back
        if (dst > dstEnd)
        {
            int n = (int)(dst - dstEnd);
            do { v &= (v - 1); } while (--n != 0);
        }

        // Step back if byte not finished
        int bitpos = 0;
        if ((v & 1) == 0)
        {
            p--;
            int q = BitOperations.TrailingZeroCount(v);
            bitpos = 8 - q;
        }

        br.P = p;
        br.Bitpos = (uint)bitpos;
        return true;
    }

    /// <summary>
    /// Decodes additional Golomb-Rice precision bits and merges them into the length array.
    /// Handles 1, 2, or 3 extra bits per symbol using SIMD-style bit unpacking.
    /// </summary>
    [SkipLocalsInit]
    public static bool DecodeGolombRiceBits(byte* dst, int size, int bitcount, ref BitReader2 br)
    {
        if (bitcount == 0)
        {
            return true;
        }

        byte* dstEnd = dst + size;
        byte* p = br.P;
        int bitpos = (int)br.Bitpos;

        uint bitsRequired = (uint)(bitpos + bitcount * size);
        uint bytesRequired = (bitsRequired + 7) >> 3;
        if (bytesRequired > (uint)(br.PEnd - p))
        {
            return false;
        }

        br.P = p + (bitsRequired >> 3);
        br.Bitpos = bitsRequired & 7;

        // Save bytes past end (may overwrite temporarily).
        // Buffer padding requirement: callers must ensure 8 bytes are writable
        // past the logical end of dst, because the SIMD bit-unpacking loop below
        // writes 8 bytes at a time and may overshoot by up to 7 bytes.
        ulong bak = *(ulong*)dstEnd;

        if (bitcount < 2)
        {
            // bitcount == 1
            do
            {
                ulong bits = (byte)(BinaryPrimitives.ReverseEndianness(*(uint*)p) >> (24 - bitpos));
                p += 1;
                bits = (bits | (bits << 28)) & 0xF0000000Ful;
                bits = (bits | (bits << 14)) & 0x3000300030003ul;
                bits = (bits | (bits << 7)) & 0x0101010101010101ul;
                *(ulong*)dst = *(ulong*)dst * 2 + BinaryPrimitives.ReverseEndianness(bits);
                dst += 8;
            } while (dst < dstEnd);
        }
        else if (bitcount == 2)
        {
            do
            {
                ulong bits = (ushort)(BinaryPrimitives.ReverseEndianness(*(uint*)p) >> (16 - bitpos));
                p += 2;
                bits = (bits | (bits << 24)) & 0xFF000000FFul;
                bits = (bits | (bits << 12)) & 0xF000F000F000Ful;
                bits = (bits | (bits << 6)) & 0x0303030303030303ul;
                *(ulong*)dst = *(ulong*)dst * 4 + BinaryPrimitives.ReverseEndianness(bits);
                dst += 8;
            } while (dst < dstEnd);
        }
        else
        {
            // bitcount == 3
            do
            {
                ulong bits = (uint)((BinaryPrimitives.ReverseEndianness(*(uint*)p) >> (8 - bitpos)) & 0xffffff);
                p += 3;
                bits = (bits | (bits << 20)) & 0xFFF00000FFFul;
                bits = (bits | (bits << 10)) & 0x3F003F003F003Ful;
                bits = (bits | (bits << 5)) & 0x0707070707070707ul;
                *(ulong*)dst = *(ulong*)dst * 8 + BinaryPrimitives.ReverseEndianness(bits);
                dst += 8;
            } while (dst < dstEnd);
        }

        *(ulong*)dstEnd = bak;
        return true;
    }

    #endregion

    #region Huff_ConvertToRanges

    /// <summary>
    /// Converts symbol code-length metadata into contiguous symbol ranges.
    /// Used by both Huffman and TANS table construction.
    /// </summary>
    public static int Huff_ConvertToRanges(HuffRange* range, int numSymbols, int P,
                                           byte* symlen, ref BitReaderState bits)
    {
        int numRanges = P >> 1;
        int symIdx = 0;

        // Start with space?
        if ((P & 1) != 0)
        {
            BitReader_Refill(ref bits);
            int v = *symlen++;
            if (v >= 8)
            {
                throw new InvalidDataException("Huff_ConvertToRanges: initial space code length >= 8");
            }
            symIdx = BitReader_ReadBitsNoRefill(ref bits, v + 1) + (1 << (v + 1)) - 1;
        }

        int symsUsed = 0;

        for (int i = 0; i < numRanges; i++)
        {
            BitReader_Refill(ref bits);
            int v = symlen[0];
            if (v >= 9)
            {
                throw new InvalidDataException("Huff_ConvertToRanges: range symbol count code length >= 9");
            }
            int num = BitReader_ReadBitsNoRefillZero(ref bits, v) + (1 << v);
            v = symlen[1];
            if (v >= 8)
            {
                throw new InvalidDataException("Huff_ConvertToRanges: range space code length >= 8");
            }
            int space = BitReader_ReadBitsNoRefill(ref bits, v + 1) + (1 << (v + 1)) - 1;
            range[i].Symbol = (ushort)symIdx;
            range[i].Num = (ushort)num;
            symsUsed += num;
            symIdx += num + space;
            symlen += 2;
        }

        if (symIdx >= 256 || symsUsed >= numSymbols || symIdx + numSymbols - symsUsed > 256)
        {
            throw new InvalidDataException("Huff_ConvertToRanges: symbol index or symbol count out of valid range");
        }

        range[numRanges].Symbol = (ushort)symIdx;
        range[numRanges].Num = (ushort)(numSymbols - symsUsed);

        return numRanges + 1;
    }

    #endregion

    #region Huff_ReadCodeLengths (Old path)

    /// <summary>
    /// Reads Huffman code-length table using the "old" gamma-coded format.
    /// </summary>
    [SkipLocalsInit]
    public static int Huff_ReadCodeLengthsOld(ref BitReaderState bits, byte* syms, uint* codePrefix)
    {
        if (BitReader_ReadBitNoRefill(ref bits) != 0)
        {
            int sym = 0, codelen, numSymbols = 0;
            int avgBitsX4 = 32;
            int forcedBits = BitReader_ReadBitsNoRefill(ref bits, 2);

            uint thresForValidGammaBits = 1u << (31 - (int)(20u >> forcedBits));

            bool skipZeros = BitReader_ReadBit(ref bits) != 0;

            do
            {
                if (!skipZeros)
                {
                    // Run of zeros
                    if ((bits.Bits & 0xff000000u) == 0)
                    {
                        throw new InvalidDataException("Huff_ReadCodeLengthsOld: invalid gamma code in zero-run encoding");
                    }
                    sym += BitReader_ReadBitsNoRefill(ref bits, 2 * (CountLeadingZeros(bits.Bits) + 1)) - 2 + 1;
                    if (sym >= 256)
                    {
                        break;
                    }
                }
                skipZeros = false;

                BitReader_Refill(ref bits);

                // Read out the gamma value for the # of symbols
                if ((bits.Bits & 0xff000000u) == 0)
                {
                    throw new InvalidDataException("Huff_ReadCodeLengthsOld: invalid gamma code in symbol count encoding");
                }
                int n = BitReader_ReadBitsNoRefill(ref bits, 2 * (CountLeadingZeros(bits.Bits) + 1)) - 2 + 1;

                // Overflow?
                if (sym + n > 256)
                {
                    throw new InvalidDataException("Huff_ReadCodeLengthsOld: symbol count overflow (sym + n > 256)");
                }
                BitReader_Refill(ref bits);
                numSymbols += n;

                do
                {
                    if (bits.Bits < thresForValidGammaBits)
                    {
                        throw new InvalidDataException("Huff_ReadCodeLengthsOld: insufficient bits for gamma-coded code length");
                    }

                    int lz = CountLeadingZeros(bits.Bits);
                    int v = BitReader_ReadBitsNoRefill(ref bits, lz + forcedBits + 1) + ((lz - 1) << forcedBits);
                    codelen = (-(v & 1) ^ (v >> 1)) + ((avgBitsX4 + 2) >> 2);
                    if (codelen < 1 || codelen > 11)
                    {
                        throw new InvalidDataException($"Huff_ReadCodeLengthsOld: code length {codelen} out of valid range [1, 11]");
                    }
                    avgBitsX4 = codelen + ((3 * avgBitsX4 + 2) >> 2);
                    BitReader_Refill(ref bits);
                    syms[codePrefix[codelen]++] = (byte)sym++;
                } while (--n != 0);
            } while (sym != 256);

            if (!((sym == 256) && (numSymbols >= 2)))
                throw new InvalidDataException("Huff_ReadCodeLengthsOld: code length table did not decode exactly 256 symbols or has fewer than 2 symbols");
            return numSymbols;
        }
        else
        {
            // Sparse symbol encoding
            int numSymbols = BitReader_ReadBitsNoRefill(ref bits, 8);
            if (numSymbols == 0)
            {
                throw new InvalidDataException("Huff_ReadCodeLengthsOld: sparse encoding has zero symbols");
            }
            if (numSymbols == 1)
            {
                syms[0] = (byte)BitReader_ReadBitsNoRefill(ref bits, 8);
            }
            else
            {
                int codelenBits = BitReader_ReadBitsNoRefill(ref bits, 3);
                if (codelenBits > 4)
                {
                    throw new InvalidDataException("Huff_ReadCodeLengthsOld: sparse encoding code length bit width > 4");
                }
                for (int i = 0; i < numSymbols; i++)
                {
                    BitReader_Refill(ref bits);
                    int s = BitReader_ReadBitsNoRefill(ref bits, 8);
                    int codelen = BitReader_ReadBitsNoRefillZero(ref bits, codelenBits) + 1;
                    if (codelen > 11)
                    {
                        throw new InvalidDataException($"Huff_ReadCodeLengthsOld: sparse encoding code length {codelen} exceeds maximum of 11");
                    }
                    syms[codePrefix[codelen]++] = (byte)s;
                }
            }
            return numSymbols;
        }
    }

    #endregion

    #region Huff_ReadCodeLengths (New path)

    /// <summary>
    /// Reads Huffman code-length table using the "new" Golomb-Rice coded format.
    /// This is the more compact encoding used by newer StreamLZ versions.
    /// </summary>
    [SkipLocalsInit]
    public static int Huff_ReadCodeLengthsNew(ref BitReaderState bits, byte* syms, uint* codePrefix)
    {
        int forcedBits = BitReader_ReadBitsNoRefill(ref bits, 2);
        int numSymbols = BitReader_ReadBitsNoRefill(ref bits, 8) + 1;
        int fluff = BitReader_ReadFluff(ref bits, numSymbols);

        if (fluff < 0 || numSymbols + fluff > 512)
        {
            throw new InvalidDataException("Huff_ReadCodeLengthsNew: invalid fluff value or numSymbols + fluff exceeds 512");
        }

        byte* codeLen = stackalloc byte[512 + 16];

        BitReader2 br2;
        br2.Bitpos = (uint)((bits.Bitpos - 24) & 7);
        br2.PEnd = bits.PEnd;
        br2.P = bits.P - (uint)((24 - bits.Bitpos + 7) >> 3);

        if (!DecodeGolombRiceLengths(codeLen, numSymbols + fluff, ref br2))
        {
            throw new InvalidDataException("Huff_ReadCodeLengthsNew: Golomb-Rice length decoding failed");
        }

        Unsafe.InitBlockUnaligned(codeLen + (numSymbols + fluff), 0, 16);

        if (!DecodeGolombRiceBits(codeLen, numSymbols, forcedBits, ref br2))
        {
            throw new InvalidDataException("Huff_ReadCodeLengthsNew: Golomb-Rice precision bit decoding failed");
        }

        // Reset the bits decoder.
        bits.Bitpos = 24;
        bits.P = br2.P;
        bits.Bits = 0;
        BitReader_Refill(ref bits);
        bits.Bits <<= (int)br2.Bitpos;
        bits.Bitpos += (int)br2.Bitpos;

        // Apply filter (scalar path)
        {
            uint runningSum = 0x1e;
            for (int i = 0; i < numSymbols; i++)
            {
                int v = codeLen[i];
                v = -(v & 1) ^ (v >> 1);
                codeLen[i] = (byte)(v + (int)(runningSum >> 2) + 1);
                if (codeLen[i] < 1 || codeLen[i] > 11)
                {
                    throw new InvalidDataException($"Huff_ReadCodeLengthsNew: code length {codeLen[i]} at index {i} out of valid range [1, 11]");
                }
                runningSum = (uint)((int)runningSum + v);
            }
        }

        HuffRange* range = stackalloc HuffRange[128];
        int ranges = Huff_ConvertToRanges(range, numSymbols, fluff, &codeLen[numSymbols], ref bits);
        if (ranges <= 0)
        {
            throw new InvalidDataException("Huff_ReadCodeLengthsNew: symbol range conversion failed");
        }

        byte* cp = codeLen;
        for (int i = 0; i < ranges; i++)
        {
            int sym = range[i].Symbol;
            int n = range[i].Num;
            do
            {
                syms[codePrefix[*cp++]++] = (byte)sym++;
            } while (--n != 0);
        }

        return numSymbols;
    }

    #endregion

    #region Huff_MakeLut

    /// <summary>
    /// Fills a byte range with a given value (may overflow up to 16 bytes past the end).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void FillByteOverflow16(byte* dst, byte v, int n)
    {
        Unsafe.InitBlockUnaligned(dst, v, (uint)n);
    }

    /// <summary>
    /// Builds the forward-order Huffman LUT from canonical prefix sums and symbol arrays.
    /// </summary>
    public static bool Huff_MakeLut(uint* prefixOrg, uint* prefixCur, NewHuffLut* hufflut, byte* syms)
    {
        uint currslot = 0;
        for (uint i = 1; i < 11; i++)
        {
            uint start = prefixOrg[i];
            uint count = prefixCur[i] - start;
            if (count != 0)
            {
                uint stepsize = 1u << (int)(11 - i);
                uint numToSet = count << (int)(11 - i);
                if (currslot + numToSet > 2048)
                {
                    return false;
                }

                FillByteOverflow16(&hufflut->Bits2Len[currslot], (byte)i, (int)numToSet);

                byte* p = &hufflut->Bits2Sym[currslot];
                for (uint j = 0; j != count; j++, p += stepsize)
                {
                    FillByteOverflow16(p, syms[start + j], (int)stepsize);
                }

                currslot += numToSet;
            }
        }

        if (prefixCur[11] - prefixOrg[11] != 0)
        {
            uint numToSet = prefixCur[11] - prefixOrg[11];
            if (currslot + numToSet > 2048)
            {
                return false;
            }
            FillByteOverflow16(&hufflut->Bits2Len[currslot], 11, (int)numToSet);
            Buffer.MemoryCopy(&syms[prefixOrg[11]], &hufflut->Bits2Sym[currslot], numToSet, numToSet);
            currslot += numToSet;
        }

        return currslot == 2048;
    }

    #endregion
}
