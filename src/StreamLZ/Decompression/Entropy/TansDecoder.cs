// TANS (Tabled Asymmetric Numeral System) decoding functions.

using System.Buffers.Binary;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StreamLZ.Decompression.Entropy;

/// <summary>
/// TANS (Tabled Asymmetric Numeral System) entropy decoder.
/// Handles table construction, LUT initialization, and 5-state interleaved decoding.
/// </summary>
internal static unsafe class TansDecoder
{
    #region Structs

    /// <summary>
    /// Intermediate table data produced by Tans_DecodeTable.
    /// A[] holds symbols with weight 1, B[] holds (symbol &lt;&lt; 16 | weight) for weight >= 2.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct TansData
    {
        public uint AUsed;
        public uint BUsed;
        public fixed byte A[256];
        public fixed uint B[256];
    }

    /// <summary>
    /// Single entry in the TANS decode LUT.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct TansLutEnt
    {
        public uint X;
        public byte BitsX;
        public byte Symbol;
        public ushort W;
    }

    /// <summary>
    /// Parameters for the 5-state interleaved TANS decoder.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct TansDecoderParams
    {
        public TansLutEnt* Lut;
        public byte* Dst;
        public byte* DstEnd;
        public byte* PositionF;
        public byte* PositionB;
        public uint BitsF;
        public uint BitsB;
        public int BitposF;
        public int BitposB;
        public uint State0;
        public uint State1;
        public uint State2;
        public uint State3;
        public uint State4;
    }

    #endregion

    #region SimpleSort

    /// <summary>
    /// Sorts a small pointer-delimited range using Span.Sort.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void SimpleSort<T>(T* p, T* pEnd) where T : unmanaged
    {
        int len = (int)(pEnd - p);
        if (len > 1)
        {
            new Span<T>(p, len).Sort();
        }
    }

    #endregion

    #region Tans_DecodeTable

    /// <summary>
    /// Decodes the TANS frequency table from a bit stream.
    /// Supports two formats: Golomb-Rice coded (bit=1) and sparse explicit (bit=0).
    /// Populates TansData with single-weight symbols (A) and multi-weight symbols (B).
    /// </summary>
    [SkipLocalsInit]
    public static bool Tans_DecodeTable(ref HuffmanDecoder.BitReaderState bits, int logTableBits, TansData* tansData)
    {
        // logTableBits must be in [8..12] range (from High_DecodeTans: logTableBits = ReadBits(2) + 8)
        if (logTableBits < 8 || logTableBits > 12)
        {
            return false;
        }

        HuffmanDecoder.BitReader_Refill(ref bits);

        if (HuffmanDecoder.BitReader_ReadBitNoRefill(ref bits) != 0)
        {
            int Q = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, 3);
            int numSymbols = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, 8) + 1;
            if (numSymbols < 2)
            {
                return false;
            }

            int fluff = HuffmanDecoder.BitReader_ReadFluff(ref bits, numSymbols);
            int totalRiceValues = fluff + numSymbols;

            byte* rice = stackalloc byte[512 + 16];

            HuffmanDecoder.BitReader2 br2;
            br2.P = bits.P - (uint)((24 - bits.Bitpos + 7) >> 3);
            br2.PEnd = bits.PEnd;
            br2.Bitpos = (uint)((bits.Bitpos - 24) & 7);

            if (!HuffmanDecoder.DecodeGolombRiceLengths(rice, totalRiceValues, ref br2))
            {
                return false;
            }

            Unsafe.InitBlockUnaligned(rice + totalRiceValues, 0, 16);

            // Switch back to other bitreader impl
            bits.Bitpos = 24;
            bits.P = br2.P;
            bits.Bits = 0;
            HuffmanDecoder.BitReader_Refill(ref bits);
            bits.Bits <<= (int)br2.Bitpos;
            bits.Bitpos += (int)br2.Bitpos;

            HuffmanDecoder.HuffRange* range = stackalloc HuffmanDecoder.HuffRange[133];
            fluff = HuffmanDecoder.Huff_ConvertToRanges(range, numSymbols, fluff, &rice[numSymbols], ref bits);
            if (fluff < 0)
            {
                return false;
            }

            HuffmanDecoder.BitReader_Refill(ref bits);

            uint L = 1u << logTableBits;
            byte* curRicePtr = rice;
            int average = 6;
            int somesum = 0;
            byte* tanstableA = tansData->A;
            uint* tanstableB = tansData->B;

            for (int ri = 0; ri < fluff; ri++)
            {
                int symbol = range[ri].Symbol;
                int num = range[ri].Num;
                do
                {
                    HuffmanDecoder.BitReader_Refill(ref bits);

                    int nextra = Q + *curRicePtr++;
                    if (nextra > 15)
                    {
                        return false;
                    }

                    int v = HuffmanDecoder.BitReader_ReadBitsNoRefillZero(ref bits, nextra) + (1 << nextra) - (1 << Q);

                    int averageDiv4 = average >> 2;
                    int limit = 2 * averageDiv4;
                    if (v <= limit)
                    {
                        v = averageDiv4 + (-(v & 1) ^ ((int)((uint)v >> 1)));
                    }
                    if (limit > v)
                    {
                        limit = v;
                    }
                    v += 1;
                    average += limit - averageDiv4;

                    *tanstableA = (byte)symbol;
                    *tanstableB = (uint)((symbol << 16) + v);
                    tanstableA += (v == 1) ? 1 : 0;
                    tanstableB += (v >= 2) ? 1 : 0;
                    somesum += v;
                    symbol += 1;
                } while (--num != 0);
            }

            tansData->AUsed = (uint)(tanstableA - tansData->A);
            tansData->BUsed = (uint)(tanstableB - tansData->B);

            if (somesum != (int)L)
            {
                return false;
            }

            return true;
        }
        else
        {
            // Sparse/explicit format
            bool* seen = stackalloc bool[256];
            Unsafe.InitBlockUnaligned(seen, 0, 256);

            uint L = 1u << logTableBits;
            int count = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, 3) + 1;
            int bitsPerSym = BitOperations.Log2((uint)logTableBits) + 1;
            int maxDeltaBits = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, bitsPerSym);

            if (maxDeltaBits == 0 || maxDeltaBits > logTableBits)
            {
                return false;
            }

            byte* tanstableA = tansData->A;
            uint* tanstableB = tansData->B;

            int weight = 0;
            int totalWeights = 0;

            do
            {
                HuffmanDecoder.BitReader_Refill(ref bits);

                int sym = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, 8);
                if (seen[sym])
                {
                    return false;
                }

                int delta = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, maxDeltaBits);
                weight += delta;

                if (weight == 0)
                {
                    return false;
                }

                seen[sym] = true;
                if (weight == 1)
                {
                    *tanstableA++ = (byte)sym;
                }
                else
                {
                    *tanstableB++ = (uint)((sym << 16) + weight);
                }

                totalWeights += weight;
            } while (--count != 0);

            HuffmanDecoder.BitReader_Refill(ref bits);

            int lastSym = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref bits, 8);
            if (seen[lastSym])
            {
                return false;
            }

            // Valid if totalWeights == L (exact) or L-1 (rounding). Difference > 1 means corrupt weights.
            if ((int)(L - (uint)totalWeights) < weight || (int)(L - (uint)totalWeights) <= 1)
            {
                return false;
            }

            *tanstableB++ = (uint)((lastSym << 16) + (L - (uint)totalWeights));

            tansData->AUsed = (uint)(tanstableA - tansData->A);
            tansData->BUsed = (uint)(tanstableB - tansData->B);

            SimpleSort(tansData->A, tanstableA);
            SimpleSort(tansData->B, tanstableB);
            return true;
        }
    }

    #endregion

    #region Tans_InitLut

    /// <summary>
    /// Initializes the TANS decode lookup table from the decoded frequency data.
    /// Distributes symbols across 4 interleaved tracks for SIMD-friendly decode:
    /// the 4-way interleave ensures that consecutive LUT entries map to different
    /// decode lanes, enabling parallel state updates during the 5-state decode loop.
    /// </summary>
    [SkipLocalsInit]
    public static void Tans_InitLut(TansData* tansData, int logTableBits, TansLutEnt* lut)
    {
        TansLutEnt** pointers = stackalloc TansLutEnt*[4];

        int L = 1 << logTableBits;
        int aUsed = (int)tansData->AUsed;

        uint slotsLeftToAlloc = (uint)(L - aUsed);

        uint sa = slotsLeftToAlloc >> 2;
        pointers[0] = lut;
        uint sb = sa + ((slotsLeftToAlloc & 3) > 0 ? 1u : 0u);
        pointers[1] = lut + sb;
        sb += sa + ((slotsLeftToAlloc & 3) > 1 ? 1u : 0u);
        pointers[2] = lut + sb;
        sb += sa + ((slotsLeftToAlloc & 3) > 2 ? 1u : 0u);
        pointers[3] = lut + sb;

        // Setup the single entries with weight=1
        {
            TansLutEnt* lutSingles = lut + slotsLeftToAlloc;
            TansLutEnt le;
            le.W = 0;
            le.BitsX = (byte)logTableBits;
            le.X = (uint)((1 << logTableBits) - 1);
            le.Symbol = 0;

            for (int i = 0; i < aUsed; i++)
            {
                lutSingles[i] = le;
                lutSingles[i].Symbol = tansData->A[i];
            }
        }

        // Setup the entries with weight >= 2
        int weightsSum = 0;
        for (int i = 0; i < (int)tansData->BUsed; i++)
        {
            int weight = (int)(tansData->B[i] & 0xffff);
            int symbol = (int)(tansData->B[i] >> 16);

            if (weight > 4)
            {
                uint symBits = (uint)BitOperations.Log2((uint)weight);
                int bitsPerSymbol = logTableBits - (int)symBits;
                TansLutEnt le;
                le.Symbol = (byte)symbol;
                le.BitsX = (byte)bitsPerSymbol;
                le.X = (uint)((1 << bitsPerSymbol) - 1);
                le.W = (ushort)((L - 1) & (weight << bitsPerSymbol));
                int whatToAdd = 1 << bitsPerSymbol;
                int upperSlotCount = (1 << (int)(symBits + 1)) - weight;

                for (int j = 0; j < 4; j++)
                {
                    TansLutEnt* dst = pointers[j];

                    int quarterWeight = (weight + ((weightsSum - j - 1) & 3)) >> 2;
                    if (upperSlotCount >= quarterWeight)
                    {
                        for (int n = quarterWeight; n != 0; n--)
                        {
                            *dst++ = le;
                            le.W += (ushort)whatToAdd;
                        }
                        upperSlotCount -= quarterWeight;
                    }
                    else
                    {
                        for (int n = upperSlotCount; n != 0; n--)
                        {
                            *dst++ = le;
                            le.W += (ushort)whatToAdd;
                        }
                        bitsPerSymbol--;

                        whatToAdd >>= 1;
                        le.BitsX = (byte)bitsPerSymbol;
                        le.W = 0;
                        le.X >>= 1;
                        for (int n = quarterWeight - upperSlotCount; n != 0; n--)
                        {
                            *dst++ = le;
                            le.W += (ushort)whatToAdd;
                        }
                        upperSlotCount = weight;
                    }

                    pointers[j] = dst;
                }
            }
            else
            {
                // weight <= 4
                uint bitsVal = (uint)(((1 << weight) - 1) << (weightsSum & 3));
                bitsVal |= (bitsVal >> 4);
                int n = weight, ww = weight;
                do
                {
                    uint idx = (uint)BitOperations.TrailingZeroCount(bitsVal);
                    bitsVal &= bitsVal - 1;
                    TansLutEnt* dst = pointers[idx]++;
                    dst->Symbol = (byte)symbol;
                    uint weightBits = (uint)BitOperations.Log2((uint)ww);
                    dst->BitsX = (byte)(logTableBits - (int)weightBits);
                    dst->X = (uint)((1 << (logTableBits - (int)weightBits)) - 1);
                    dst->W = (ushort)((L - 1) & (ww++ << (logTableBits - (int)weightBits)));
                } while (--n != 0);
            }

            weightsSum += weight;
        }
    }

    #endregion

    #region Tans_Decode

    /// <summary>
    /// Core 5-state interleaved TANS decoder.
    /// Alternates between forward and backward bit streams, decoding 10 symbols per outer iteration.
    /// </summary>
    [SkipLocalsInit]
    public static bool Tans_Decode(TansDecoderParams* parms)
    {
        TansLutEnt* lut = parms->Lut;
        TansLutEnt* e;
        byte* dst = parms->Dst;
        byte* dstEnd = parms->DstEnd;
        byte* ptrF = parms->PositionF;
        byte* ptrB = parms->PositionB;
        uint bitsF = parms->BitsF;
        uint bitsB = parms->BitsB;
        int bitposF = parms->BitposF;
        int bitposB = parms->BitposB;
        uint state0 = parms->State0;
        uint state1 = parms->State1;
        uint state2 = parms->State2;
        uint state3 = parms->State3;
        uint state4 = parms->State4;

        if (ptrF > ptrB)
        {
            return false;
        }

        if (dst < dstEnd)
        {
            for (; ; )
            {
                // TANS_FORWARD_BITS
                bitsF |= *(uint*)ptrF << bitposF;
                ptrF += (31 - bitposF) >> 3;
                bitposF |= 24;

                // TANS_FORWARD_ROUND(state_0)
                e = &lut[state0];
                *dst++ = e->Symbol;
                bitposF -= e->BitsX;
                state0 = (bitsF & e->X) + e->W;
                bitsF >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_FORWARD_ROUND(state_1)
                e = &lut[state1];
                *dst++ = e->Symbol;
                bitposF -= e->BitsX;
                state1 = (bitsF & e->X) + e->W;
                bitsF >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_FORWARD_BITS
                bitsF |= *(uint*)ptrF << bitposF;
                ptrF += (31 - bitposF) >> 3;
                bitposF |= 24;

                // TANS_FORWARD_ROUND(state_2)
                e = &lut[state2];
                *dst++ = e->Symbol;
                bitposF -= e->BitsX;
                state2 = (bitsF & e->X) + e->W;
                bitsF >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_FORWARD_ROUND(state_3)
                e = &lut[state3];
                *dst++ = e->Symbol;
                bitposF -= e->BitsX;
                state3 = (bitsF & e->X) + e->W;
                bitsF >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_FORWARD_BITS
                bitsF |= *(uint*)ptrF << bitposF;
                ptrF += (31 - bitposF) >> 3;
                bitposF |= 24;

                // TANS_FORWARD_ROUND(state_4)
                e = &lut[state4];
                *dst++ = e->Symbol;
                bitposF -= e->BitsX;
                state4 = (bitsF & e->X) + e->W;
                bitsF >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_BACKWARD_BITS
                bitsB |= BinaryPrimitives.ReverseEndianness(((uint*)ptrB)[-1]) << bitposB;
                ptrB -= (31 - bitposB) >> 3;
                bitposB |= 24;

                // TANS_BACKWARD_ROUND(state_0)
                e = &lut[state0];
                *dst++ = e->Symbol;
                bitposB -= e->BitsX;
                state0 = (bitsB & e->X) + e->W;
                bitsB >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_BACKWARD_ROUND(state_1)
                e = &lut[state1];
                *dst++ = e->Symbol;
                bitposB -= e->BitsX;
                state1 = (bitsB & e->X) + e->W;
                bitsB >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_BACKWARD_BITS
                bitsB |= BinaryPrimitives.ReverseEndianness(((uint*)ptrB)[-1]) << bitposB;
                ptrB -= (31 - bitposB) >> 3;
                bitposB |= 24;

                // TANS_BACKWARD_ROUND(state_2)
                e = &lut[state2];
                *dst++ = e->Symbol;
                bitposB -= e->BitsX;
                state2 = (bitsB & e->X) + e->W;
                bitsB >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_BACKWARD_ROUND(state_3)
                e = &lut[state3];
                *dst++ = e->Symbol;
                bitposB -= e->BitsX;
                state3 = (bitsB & e->X) + e->W;
                bitsB >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }

                // TANS_BACKWARD_BITS
                bitsB |= BinaryPrimitives.ReverseEndianness(((uint*)ptrB)[-1]) << bitposB;
                ptrB -= (31 - bitposB) >> 3;
                bitposB |= 24;

                // TANS_BACKWARD_ROUND(state_4)
                e = &lut[state4];
                *dst++ = e->Symbol;
                bitposB -= e->BitsX;
                state4 = (bitsB & e->X) + e->W;
                bitsB >>= e->BitsX;
                if (dst >= dstEnd)
                {
                    break;
                }
            }
        }

        if (ptrB - ptrF + (bitposF >> 3) + (bitposB >> 3) != 0)
        {
            return false;
        }

        uint statesOr = state0 | state1 | state2 | state3 | state4;
        if ((statesOr & ~0xFFu) != 0)
        {
            return false;
        }

        dstEnd[0] = (byte)state0;
        dstEnd[1] = (byte)state1;
        dstEnd[2] = (byte)state2;
        dstEnd[3] = (byte)state3;
        dstEnd[4] = (byte)state4;
        return true;
    }

    #endregion

    #region High_DecodeTans

    /// <summary>
    /// Top-level TANS block decoder.
    /// Reads the TANS table, builds the LUT, initializes 5 decoder states, then runs Tans_Decode.
    /// </summary>
    [SkipLocalsInit]
    public static int High_DecodeTans(byte* src, int srcSize, byte* dst, int dstSize,
                                      byte* scratch, byte* scratchEnd)
    {
        if (srcSize < 8 || dstSize < 5)
        {
            throw new InvalidDataException($"TANS source or destination too small (srcSize={srcSize}, dstSize={dstSize}; need srcSize>=8, dstSize>=5).");
        }

        byte* srcEnd = src + srcSize;

        HuffmanDecoder.BitReaderState br;
        TansData tansData;

        br.Bitpos = 24;
        br.Bits = 0;
        br.P = src;
        br.PEnd = srcEnd;
        HuffmanDecoder.BitReader_Refill(ref br);

        // Reserved bit
        if (HuffmanDecoder.BitReader_ReadBitNoRefill(ref br) != 0)
        {
            throw new InvalidDataException("TANS reserved bit is set; expected 0.");
        }

        int logTableBits = HuffmanDecoder.BitReader_ReadBitsNoRefill(ref br, 2) + 8;

        if (!Tans_DecodeTable(ref br, logTableBits, &tansData))
        {
            throw new InvalidDataException("TANS frequency table decode failed; stream data is corrupt.");
        }

        src = br.P - (24 - br.Bitpos) / 8;

        if (src >= srcEnd || srcEnd - src < 8)
        {
            throw new InvalidDataException("TANS bitstream too short after table decode; need at least 8 bytes for state initialization.");
        }

        uint lutSpaceRequired = (uint)(((sizeof(TansLutEnt) << logTableBits) + 15) & ~15);
        if (lutSpaceRequired > (uint)(scratchEnd - scratch))
        {
            throw new InvalidDataException($"TANS LUT requires {lutSpaceRequired} bytes of scratch space but only {(uint)(scratchEnd - scratch)} available.");
        }

        TansDecoderParams parms;
        parms.Dst = dst;
        parms.DstEnd = dst + dstSize - 5;

        // Align scratch to 16 bytes
        parms.Lut = (TansLutEnt*)(((nuint)scratch + 15) & ~(nuint)15);
        Tans_InitLut(&tansData, logTableBits, parms.Lut);

        // Read out the initial state
        uint lMask = (1u << logTableBits) - 1;
        uint bitsF = *(uint*)src;
        src += 4;
        uint bitsB = BinaryPrimitives.ReverseEndianness(*(uint*)(srcEnd - 4));
        srcEnd -= 4;
        uint bitposF = 32, bitposB = 32;

        // Read first two
        parms.State0 = bitsF & lMask;
        parms.State1 = bitsB & lMask;
        bitsF >>= logTableBits; bitposF -= (uint)logTableBits;
        bitsB >>= logTableBits; bitposB -= (uint)logTableBits;

        // Read next two
        parms.State2 = bitsF & lMask;
        parms.State3 = bitsB & lMask;
        bitsF >>= logTableBits; bitposF -= (uint)logTableBits;
        bitsB >>= logTableBits; bitposB -= (uint)logTableBits;

        // Refill more bits
        bitsF |= *(uint*)src << (int)bitposF;
        src += (31 - (int)bitposF) >> 3;
        bitposF |= 24;

        // Read final state variable
        parms.State4 = bitsF & lMask;
        bitsF >>= logTableBits; bitposF -= (uint)logTableBits;

        parms.BitsF = bitsF;
        parms.PositionF = src - (int)(bitposF >> 3);
        parms.BitposF = (int)(bitposF & 7);

        parms.BitsB = bitsB;
        parms.PositionB = srcEnd + (int)(bitposB >> 3);
        parms.BitposB = (int)(bitposB & 7);

        if (!Tans_Decode(&parms))
        {
            throw new InvalidDataException("TANS 5-state decode failed; bitstream pointers did not converge or final states are out of range.");
        }

        return srcSize;
    }

    #endregion
}
