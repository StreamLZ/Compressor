using System.Buffers.Binary;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static StreamLZ.Compression.CompressUtils;

namespace StreamLZ.Compression.Entropy;

/// <summary>
/// tANS (Tabled Asymmetric Numeral System) entropy encoder.
/// Provides 5-state interleaved encoding with forward/backward bit streams,
/// frequency table normalization, and table serialization.
/// </summary>
/// <remarks>
/// Based on Jarek Duda's Asymmetric Numeral Systems (ANS) family of entropy coders.
/// Reference: J. Duda, "Asymmetric numeral systems: entropy coding combining speed of
/// Huffman coding with compression rate of arithmetic coding" (arXiv:1311.2540, 2013).
/// The table construction and interleaved state machine follow the tANS variant
/// described in Yann Collet's Finite State Entropy (FSE) implementation.
/// </remarks>
internal static unsafe class TansEncoder
{
    #region Constants

    #endregion

    // BitWriter64Forward and BitWriter64Backward are defined in Compression/BitWriter.cs (top-level types).

    #region TansEncEntry

    /// <summary>
    /// Encoding table entry for a single symbol in the tANS encoder.
    /// </summary>
    private struct TansEncEntry
    {
        public ushort* NextState;
        public ushort Thres;
        public byte NumBits;
    }

    #endregion

    #region Log factor tables

    /// <summary>
    /// Log factor table for incrementing a symbol weight: log(1 + 1/value).
    /// Used during frequency normalization heap adjustment.
    /// </summary>
    private static ReadOnlySpan<float> LogFactorUpTable =>
    [
        0.000000f, 0.693147f, 0.405465f, 0.287682f, 0.223144f, 0.182322f, 0.154151f, 0.133531f,
        0.117783f, 0.105361f, 0.095310f, 0.087011f, 0.080043f, 0.074108f, 0.068993f, 0.064539f,
        0.060625f, 0.057158f, 0.054067f, 0.051293f, 0.048790f, 0.046520f, 0.044452f, 0.042560f,
        0.040822f, 0.039221f, 0.037740f, 0.036368f, 0.035091f, 0.033902f, 0.032790f, 0.031749f
    ];

    /// <summary>
    /// Log factor table for decrementing a symbol weight: log(1 - 1/value).
    /// Used during frequency normalization heap adjustment.
    /// </summary>
    private static ReadOnlySpan<float> LogFactorDownTable =>
    [
        0.000000f, 0.000000f, -0.693147f, -0.405465f, -0.287682f, -0.223144f, -0.182322f, -0.154151f,
        -0.133531f, -0.117783f, -0.105361f, -0.095310f, -0.087011f, -0.080043f, -0.074108f, -0.068993f,
        -0.064539f, -0.060625f, -0.057158f, -0.054067f, -0.051293f, -0.048790f, -0.046520f, -0.044452f,
        -0.042560f, -0.040822f, -0.039221f, -0.037740f, -0.036368f, -0.035091f, -0.033902f, -0.032790f
    ];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float Tans_GetLogFactorUp(int value)
    {
        if (value >= 32)
        {
            return (1.0f / value) - (1.0f / value) * (1.0f / value) * 0.5f;
        }
        return LogFactorUpTable[value];
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float Tans_GetLogFactorDown(int value)
    {
        if (value >= 32)
        {
            return -(1.0f / value) - (1.0f / value) * (1.0f / value) * 0.5f;
        }
        return LogFactorDownTable[value];
    }

    #endregion

    #region Helpers

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint DoubleToUintRoundPow2(double v)
    {
        uint u = (uint)v;
        return u + (v * v > (double)u * (u + 1) ? 1u : 0u);
    }

    /// <summary>
    /// ilog2 with rounding: Log2(v) adjusted by whether v is closer to the next power of 2.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int Ilog2Round(uint v)
    {
        if (v == 0)
        {
            return 0;
        }
        int bsr = BitOperations.Log2(v);
        // Round up if v > 1.5 * 2^(bsr-1) approximately
        uint lower = 1u << bsr;
        uint upper = lower << 1;
        return (v - lower >= upper - v) ? bsr + 1 : bsr;
    }

    #endregion

    #region GetBitsForArraysOfRice

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint GetBitsForArraysOfRice(uint* arr, int arrSize, int k)
    {
        uint result = 0;
        for (int i = 0; i < arrSize; i++)
        {
            if (arr[i] != 0)
            {
                result += arr[i] * (uint)(k + 1 + 2 * BitOperations.Log2((uint)((i >> k) + 1)));
            }
        }
        return result;
    }

    #endregion

    #region Tans_EncodeTable

    /// <summary>
    /// Encodes the tANS frequency table into the bit stream.
    /// Two formats: Golomb-Rice coded for many symbols, sparse explicit for &lt;= 7 symbols.
    /// </summary>
    /// <remarks>
    /// This method references external helpers (EncodeSymRange, WriteNumSymRange,
    /// WriteManyRiceCodes, WriteSymRangeLowBits) that must be provided by the caller's
    /// entropy infrastructure. They are declared here as static extern stubs.
    /// These would be implemented in a shared EntropyEncoder class.
    /// For now, the encode-table logic handles both code paths.
    /// </remarks>
    [SkipLocalsInit]
    private static void Tans_EncodeTable(ref BitWriter64Forward bits, int logTableBits, uint* lookup, int histoSize, int usedSymbols)
    {
        if (usedSymbols > 7)
        {
            bits.WriteNoFlush(1, 1);

            uint* arrZ = stackalloc uint[128];
            Unsafe.InitBlockUnaligned(arrZ, 0, 128 * sizeof(uint));
            int* ranges = stackalloc int[257];
            int* rangeCur = ranges;
            int* arrX = stackalloc int[256];
            int* arrY = stackalloc int[32];
            byte* arrW = stackalloc byte[256];
            byte* srRice = stackalloc byte[256];
            byte* srBits = stackalloc byte[256];
            byte* srBitcount = stackalloc byte[256];

            int pos = 0;
            while (pos < histoSize && lookup[pos] == 0)
            {
                pos++;
            }
            *rangeCur++ = pos;

            int average = 6, v, usedSyms = 0, arrXCount = 0, arrYCount = 0;
            while (pos < histoSize)
            {
                int posStart = pos;
                while (pos < histoSize && (v = (int)lookup[pos]) != 0)
                {
                    v--;
                    int averageDiv4 = average >> 2;
                    int limit = 2 * averageDiv4;
                    int u = v > limit ? v : 2 * (v - averageDiv4) ^ ((v - averageDiv4) >> 31);
                    arrX[arrXCount++] = u;
                    if (u >= 0x80)
                    {
                        arrY[arrYCount++] = u;
                    }
                    else
                    {
                        arrZ[u]++;
                    }
                    if (v < limit)
                    {
                        limit = v;
                    }
                    pos++;
                    usedSyms++;
                    average += limit - averageDiv4;
                }
                *rangeCur++ = pos - posStart;

                posStart = pos;
                while (pos < histoSize && lookup[pos] == 0)
                {
                    pos++;
                }
                *rangeCur++ = pos - posStart;
            }

            rangeCur[-1] += 256 - pos;

            int bestScore = int.MaxValue;
            int Q = 0;
            for (int tq = 0; tq < 8; tq++)
            {
                int score = (int)GetBitsForArraysOfRice(arrZ, 128, tq);
                for (int i = 0; i < arrYCount; i++)
                {
                    score += tq + 2 * BitOperations.Log2((uint)((arrY[i] >> tq) + 1)) + 1;
                }

                if (score < bestScore)
                {
                    bestScore = score;
                    Q = tq;
                }
            }

            int numSymrange = EncodeSymRange(srRice, srBits, srBitcount, usedSyms, ranges, (int)(rangeCur - ranges));
            bits.WriteNoFlush((uint)((usedSyms - 1) + (Q << 8)), 11);

            BitWriter64Forward bitst = bits;
            WriteNumSymRange(ref bitst, numSymrange, usedSyms);

            for (int i = 0; i < arrXCount; i++)
            {
                uint x = (uint)(arrX[i] + (1 << Q));
                int nb = BitOperations.Log2(x >> Q);
                arrW[i] = (byte)nb;
                arrX[i] = (int)(x & ((1u << (Q + nb)) - 1));
            }

            WriteManyRiceCodes(ref bitst, arrW, arrXCount);
            WriteManyRiceCodes(ref bitst, srRice, numSymrange);
            WriteSymRangeLowBits(ref bitst, srBits, srBitcount, numSymrange);
            bits = bitst;

            for (int i = 0; i < arrXCount; i++)
            {
                if (Q + arrW[i] != 0)
                {
                    bits.Write((uint)arrX[i], Q + arrW[i]);
                }
            }
        }
        else
        {
            bits.WriteNoFlush(0, 1);
            bits.WriteNoFlush((uint)(usedSymbols - 2), 3);

            uint* sympos = stackalloc uint[8];
            uint* symposEnd = sympos;
            for (int i = 0; i < histoSize; i++)
            {
                if (lookup[i] != 0)
                {
                    *symposEnd++ = (uint)i | (lookup[i] << 16);
                }
            }
            SimpleSort(sympos, symposEnd);

            int deltaBits = 1;
            for (int i = 0, p = 0; i < usedSymbols - 1; i++)
            {
                int sv = (int)(sympos[i] >> 16);
                int nb = sv - p != 0 ? BitOperations.Log2((uint)(sv - p)) + 1 : 0;
                deltaBits = Math.Max(deltaBits, nb);
                p = sv;
            }
            bits.WriteNoFlush((uint)deltaBits, BitOperations.Log2((uint)logTableBits) + 1);

            for (int i = 0, p = 0; i < usedSymbols - 1; i++)
            {
                int sv = (int)(sympos[i] >> 16);
                bits.Write((uint)((uint)(sv - p) + ((uint)(byte)sympos[i] << deltaBits)), deltaBits + 8);
                p = sv;
            }
            bits.Write((byte)sympos[usedSymbols - 1], 8);
        }
    }

    #endregion

    #region EncodeSymRange / WriteNumSymRange / WriteManyRiceCodes / WriteSymRangeLowBits

    /// <summary>
    /// Encodes symbol ranges into rice/bits/bitcount arrays for table serialization.
    /// </summary>
    [SkipLocalsInit]
    private static int EncodeSymRange(byte* rice, byte* bits, byte* bitcount,
                                      int usedSyms, int* range, int numrange)
    {
        if (usedSyms >= 256)
        {
            return 0;
        }
        int which = (*range == 0) ? 1 : 0;
        int num = ((*range != 0) ? 1 : 0) + 2 * ((numrange - 3) / 2);
        range += (*range == 0) ? 1 : 0;
        for (int i = 0; i < num; i++)
        {
            int v = range[i];
            int ebit = ~which++ & 1;
            v += (1 << ebit) - 1;
            int nb = (int)BitOperations.Log2((uint)(v >> ebit));
            rice[i] = (byte)nb;
            nb += ebit;
            bits[i] = (byte)(v & ((1 << nb) - 1));
            bitcount[i] = (byte)nb;
        }
        return num;
    }

    /// <summary>
    /// Writes the number of symbol ranges using truncated binary coding.
    /// </summary>
    private static void WriteNumSymRange(ref BitWriter64Forward bits, int numSymrange, int usedSyms)
    {
        if (usedSyms == 256)
        {
            return;
        }

        int x = Math.Min(usedSyms, 257 - usedSyms);
        int nb = (int)BitOperations.Log2((uint)(2 * x - 1)) + 1;
        int @base = (1 << nb) - 2 * x;
        if (numSymrange >= @base)
        {
            bits.Write((uint)(numSymrange + @base), nb);
        }
        else
        {
            bits.Write((uint)numSymrange, nb - 1);
        }
    }

    /// <summary>
    /// Writes multiple unary rice codes (v zero bits followed by a 1 bit each).
    /// </summary>
    private static void WriteManyRiceCodes(ref BitWriter64Forward bits, byte* data, int num)
    {
        BitWriter64Forward tmp = bits;
        for (int i = 0; i != num; i++)
        {
            uint v = data[i];
            for (; v >= 24; v -= 24)
            {
                tmp.Write(0, 24);
            }
            tmp.Write(1, (int)v + 1);
        }
        bits = tmp;
    }

    /// <summary>
    /// Writes the low-order bits of each symbol range entry.
    /// </summary>
    private static void WriteSymRangeLowBits(ref BitWriter64Forward bits, byte* data, byte* bitcount, int num)
    {
        BitWriter64Forward tmp = bits;
        for (int i = 0; i != num; i++)
        {
            tmp.Write(data[i], bitcount[i]);
        }
        bits = tmp;
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

    #region Heap operations

    private struct HeapEntry : IComparable<HeapEntry>
    {
        public int Index;
        public float Score;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public readonly int CompareTo(HeapEntry other) => Score.CompareTo(other.Score);
    }


    #endregion

    #region Tans_NormalizeCounts

    /// <summary>
    /// Normalizes histogram counts so they sum to L (a power of 2).
    /// Uses a heap to greedily adjust weights to minimize KL divergence.
    /// </summary>
    [SkipLocalsInit]
    private static int Tans_NormalizeCounts(uint* lookup, uint L, HistoU8* histo, int histoSum, int numSyms)
    {
        int symsUsed = 0;
        double multiplier = (double)L / (double)histoSum;
        uint weightSum = 0;
        for (int i = 0; i < numSyms; i++)
        {
            uint h = histo->Count[i];
            uint u = 0;
            if (h != 0)
            {
                u = DoubleToUintRoundPow2(h * multiplier);
                weightSum += u;
                symsUsed++;
            }
            lookup[i] = u;
        }
        if (weightSum == L)
        {
            return symsUsed;
        }

        HeapEntry* heap = stackalloc HeapEntry[256];
        HeapEntry* heapCur = heap;
        int diff = (int)(L - weightSum);

        if (diff < 0)
        {
            for (int i = 0; i < numSyms; i++)
            {
                if (lookup[i] > 1)
                {
                    heapCur->Index = i;
                    heapCur->Score = histo->Count[i] * Tans_GetLogFactorDown((int)lookup[i]);
                    heapCur++;
                }
            }
        }
        else
        {
            for (int i = 0; i < numSyms; i++)
            {
                if (histo->Count[i] != 0)
                {
                    heapCur->Index = i;
                    heapCur->Score = histo->Count[i] * Tans_GetLogFactorUp((int)lookup[i]);
                    heapCur++;
                }
            }
        }

        MaxHeap<HeapEntry>.MakeHeap(heap, heapCur);

        if (diff < 0)
        {
            do
            {
                Debug.Assert(heap != heapCur);
                int index = heap->Index;
                MaxHeap<HeapEntry>.PopHeap(heap, heapCur--);
                if (--lookup[index] > 1)
                {
                    heapCur->Index = index;
                    heapCur->Score = histo->Count[index] * Tans_GetLogFactorDown((int)lookup[index]);
                    MaxHeap<HeapEntry>.PushHeap(heap, ++heapCur);
                }
            } while (++diff != 0);
        }
        else
        {
            do
            {
                Debug.Assert(heap != heapCur);
                int index = heap->Index;
                MaxHeap<HeapEntry>.PopHeap(heap, heapCur--);
                lookup[index]++;
                heapCur->Index = index;
                heapCur->Score = histo->Count[index] * Tans_GetLogFactorUp((int)lookup[index]);
                MaxHeap<HeapEntry>.PushHeap(heap, ++heapCur);
            } while (--diff != 0);
        }
        return symsUsed;
    }

    #endregion

    #region Tans_InitTable

    /// <summary>
    /// Initializes the tANS encoding table from normalized weights.
    /// Distributes states across 4 interleaved pointer tracks.
    /// </summary>
    [SkipLocalsInit]
    private static void Tans_InitTable(TansEncEntry* te, ushort* teData, uint* weights, int weightsSize, int logTableBits)
    {
        uint L = 1u << logTableBits;

        uint ones = 0;
        for (int i = 0; i < weightsSize; i++)
        {
            ones += weights[i] == 1 ? 1u : 0u;
        }

        uint slotsLeftToAlloc = L - ones;
        uint sa = slotsLeftToAlloc >> 2;
        uint* pointers = stackalloc uint[4];
        pointers[0] = 0;
        uint sb = sa + ((slotsLeftToAlloc & 3) > 0 ? 1u : 0u);
        pointers[1] = sb;
        sb += sa + ((slotsLeftToAlloc & 3) > 1 ? 1u : 0u);
        pointers[2] = sb;
        sb += sa + ((slotsLeftToAlloc & 3) > 2 ? 1u : 0u);
        pointers[3] = sb;

        ushort* onesPtr = teData + slotsLeftToAlloc;
        int weightsSum = 0;

        for (int i = 0; i < weightsSize; i++, te++)
        {
            uint w = weights[i];
            if (w != 0)
            {
                if (w == 1)
                {
                    te->NumBits = (byte)logTableBits;
                    te->Thres = (ushort)(2 * L);
                    te->NextState = onesPtr - 1;
                    *onesPtr = (ushort)(L + (uint)(onesPtr - teData));
                    onesPtr++;
                }
                else
                {
                    int nb = BitOperations.Log2(w - 1) + 1;
                    te->NumBits = (byte)(logTableBits - nb);
                    te->Thres = (ushort)(2 * w << (logTableBits - nb));
                    ushort* otherPtr = teData + weightsSum;
                    te->NextState = otherPtr - w;
                    for (int j = 0; j < 4; j++)
                    {
                        int p = (int)pointers[j];
                        int Y = (int)((w + ((uint)(weightsSum - j - 1) & 3)) >> 2);
                        while (Y-- > 0)
                        {
                            *otherPtr++ = (ushort)(p++ + L);
                        }
                        pointers[j] = (uint)p;
                    }
                    weightsSum += (int)w;
                }
            }
            else
            {
                te->NextState = null;
            }
        }
    }

    #endregion

    #region Tans_GetEncodedBitCount

    /// <summary>
    /// Computes the exact number of forward and backward bits that the 5-state encoder will produce
    /// without actually writing any bits. Used to pre-calculate buffer sizes.
    /// </summary>
    [SkipLocalsInit]
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Tans_GetEncodedBitCount(TansEncEntry* te, byte* src, int srcSize, int logTableBits,
                                                 uint* forwardBitsPtr, uint* backwardBitsPtr)
    {
        Debug.Assert(srcSize >= 5, "Tans_GetEncodedBitCount requires srcSize >= 5");
        uint L = 1u << logTableBits;
        byte* srcEnd = src + srcSize - 5;
        uint state0 = srcEnd[0] | L;
        uint state1 = srcEnd[1] | L;
        uint state2 = srcEnd[2] | L;
        uint state3 = srcEnd[3] | L;
        uint state4 = srcEnd[4] | L;
        uint forwardBits = 0, backwardBits = 0;
        uint nb;
        int rounds = (srcSize - 5) / 10;
        TansEncEntry* t;
        srcEnd--;

        // Remainder: process last (srcSize-5)%10 symbols (tail of the 10-symbol cycle).
        // Cycle: states 4,3,2,1,0 to forwardBits, then 4,3,2,1,0 to backwardBits.
        int remainder = (srcSize - 5) % 10;
        for (int ri = 10 - remainder; ri < 10; ri++)
        {
            t = &te[*srcEnd--];
            uint sv;
            int si = ri % 5;
            switch (si)
            {
                case 0: sv = state4; break;
                case 1: sv = state3; break;
                case 2: sv = state2; break;
                case 3: sv = state1; break;
                default: sv = state0; break;
            }
            nb = (uint)t->NumBits + (sv >= t->Thres ? 1u : 0u);
            if (ri < 5)
                forwardBits += nb;
            else
                backwardBits += nb;
            uint newState = t->NextState[sv >> (int)nb];
            switch (si)
            {
                case 0: state4 = newState; break;
                case 1: state3 = newState; break;
                case 2: state2 = newState; break;
                case 3: state1 = newState; break;
                default: state0 = newState; break;
            }
        }

        while (rounds-- > 0)
        {
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state4 >= t->Thres ? 1u : 0u); forwardBits += nb; state4 = t->NextState[state4 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state3 >= t->Thres ? 1u : 0u); forwardBits += nb; state3 = t->NextState[state3 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state2 >= t->Thres ? 1u : 0u); forwardBits += nb; state2 = t->NextState[state2 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state1 >= t->Thres ? 1u : 0u); forwardBits += nb; state1 = t->NextState[state1 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state0 >= t->Thres ? 1u : 0u); forwardBits += nb; state0 = t->NextState[state0 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state4 >= t->Thres ? 1u : 0u); backwardBits += nb; state4 = t->NextState[state4 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state3 >= t->Thres ? 1u : 0u); backwardBits += nb; state3 = t->NextState[state3 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state2 >= t->Thres ? 1u : 0u); backwardBits += nb; state2 = t->NextState[state2 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state1 >= t->Thres ? 1u : 0u); backwardBits += nb; state1 = t->NextState[state1 >> (int)nb];
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state0 >= t->Thres ? 1u : 0u); backwardBits += nb; state0 = t->NextState[state0 >> (int)nb];
        }

        *forwardBitsPtr = forwardBits + 2 * (uint)logTableBits;
        *backwardBitsPtr = backwardBits + 3 * (uint)logTableBits;
    }

    #endregion

    #region Tans_EncodeBytes

    /// <summary>
    /// Encodes bytes using the 5-state interleaved tANS encoder.
    /// Writes to both forward and backward bit streams, then swaps them for the decoder
    /// (decoder reads backward first).
    /// </summary>
    [SkipLocalsInit]
    private static byte* Tans_EncodeBytes(byte* dst, byte* dstEnd, TansEncEntry* te,
                                           byte* src, int srcSize, int logTableBits,
                                           int forwardBitsPad, int backwardBitsPad)
    {
        BitWriter64Forward forwardBits = new(dst);
        BitWriter64Backward backwardBits = new(dstEnd);

        if ((forwardBitsPad & 7) != 0)
        {
            forwardBits.WriteNoFlush(0, 8 - (forwardBitsPad & 7));
        }

        if ((backwardBitsPad & 7) != 0)
        {
            backwardBits.WriteNoFlush(0, 8 - (backwardBitsPad & 7));
        }

        uint L = 1u << logTableBits;
        byte* srcEnd = src + srcSize - 5;
        uint state0 = srcEnd[0] | L;
        uint state1 = srcEnd[1] | L;
        uint state2 = srcEnd[2] | L;
        uint state3 = srcEnd[3] | L;
        uint state4 = srcEnd[4] | L;
        uint nb;
        int rounds = (srcSize - 5) / 10;
        TansEncEntry* t;
        srcEnd--;

        // Remainder: process the last (srcSize-5)%10 symbols before the main 10-at-a-time loop.
        // The 10-symbol cycle is: states 4,3,2,1,0 to forwardBits, then 4,3,2,1,0 to backwardBits.
        // The remainder enters at the TAIL of this cycle — case 9 = last 9, case 1 = last 1.
        // State order for positions 0..9: [4,3,2,1,0, 4,3,2,1,0]
        // Writer:                         [F,F,F,F,F, B,B,B,B,B]
        // Remainder R enters at position (10-R), so processes positions (10-R)..9.

        int remainder = (srcSize - 5) % 10;
        // Encode `remainder` symbols starting from position (10-remainder) in the cycle.
        // stateOrder[pos] gives which state variable to use at each cycle position.
        // Position 0=state4, 1=state3, 2=state2, 3=state1, 4=state0, 5=state4, ...
        for (int ri = 10 - remainder; ri < 10; ri++)
        {
            t = &te[*srcEnd--];
            // Select state by cycle position (mod 5): 4,3,2,1,0
            uint sv;
            int si = ri % 5;
            switch (si)
            {
                case 0: sv = state4; break;
                case 1: sv = state3; break;
                case 2: sv = state2; break;
                case 3: sv = state1; break;
                default: sv = state0; break;
            }
            nb = (uint)t->NumBits + (sv >= t->Thres ? 1u : 0u);
            // Positions 0-4 write to forwardBits, 5-9 write to backwardBits
            if (ri < 5)
                forwardBits.WriteNoFlush(sv & ((1u << (int)nb) - 1), (int)nb);
            else
                backwardBits.WriteNoFlush(sv & ((1u << (int)nb) - 1), (int)nb);
            uint newState = t->NextState[sv >> (int)nb];
            switch (si)
            {
                case 0: state4 = newState; break;
                case 1: state3 = newState; break;
                case 2: state2 = newState; break;
                case 3: state1 = newState; break;
                default: state0 = newState; break;
            }
        }
        if (remainder > 0)
        {
            backwardBits.Flush();
            forwardBits.Flush();
        }

        while (rounds-- > 0)
        {
            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state4 >= t->Thres ? 1u : 0u);
            forwardBits.WriteNoFlush(state4 & ((1u << (int)nb) - 1), (int)nb);
            state4 = t->NextState[state4 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state3 >= t->Thres ? 1u : 0u);
            forwardBits.WriteNoFlush(state3 & ((1u << (int)nb) - 1), (int)nb);
            state3 = t->NextState[state3 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state2 >= t->Thres ? 1u : 0u);
            forwardBits.WriteNoFlush(state2 & ((1u << (int)nb) - 1), (int)nb);
            state2 = t->NextState[state2 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state1 >= t->Thres ? 1u : 0u);
            forwardBits.WriteNoFlush(state1 & ((1u << (int)nb) - 1), (int)nb);
            state1 = t->NextState[state1 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state0 >= t->Thres ? 1u : 0u);
            forwardBits.WriteNoFlush(state0 & ((1u << (int)nb) - 1), (int)nb);
            state0 = t->NextState[state0 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state4 >= t->Thres ? 1u : 0u);
            backwardBits.WriteNoFlush(state4 & ((1u << (int)nb) - 1), (int)nb);
            state4 = t->NextState[state4 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state3 >= t->Thres ? 1u : 0u);
            backwardBits.WriteNoFlush(state3 & ((1u << (int)nb) - 1), (int)nb);
            state3 = t->NextState[state3 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state2 >= t->Thres ? 1u : 0u);
            backwardBits.WriteNoFlush(state2 & ((1u << (int)nb) - 1), (int)nb);
            state2 = t->NextState[state2 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state1 >= t->Thres ? 1u : 0u);
            backwardBits.WriteNoFlush(state1 & ((1u << (int)nb) - 1), (int)nb);
            state1 = t->NextState[state1 >> (int)nb];

            t = &te[*srcEnd--]; nb = (uint)t->NumBits + (state0 >= t->Thres ? 1u : 0u);
            backwardBits.WriteNoFlush(state0 & ((1u << (int)nb) - 1), (int)nb);
            state0 = t->NextState[state0 >> (int)nb];

            backwardBits.Flush();
            forwardBits.Flush();
        }

        // Write final states
        backwardBits.WriteNoFlush(state4 & (L - 1), logTableBits);
        backwardBits.WriteNoFlush(state2 & (L - 1), logTableBits);
        backwardBits.WriteNoFlush(state0 & (L - 1), logTableBits);
        forwardBits.WriteNoFlush(state3 & (L - 1), logTableBits);
        forwardBits.WriteNoFlush(state1 & (L - 1), logTableBits);
        backwardBits.Flush();
        forwardBits.Flush();

        Debug.Assert(backwardBits.Pos == 63);
        Debug.Assert(forwardBits.Pos == 63);

        // The decoder reads backward first, so we must swap:
        // Written as FORWARD....BACKWARD but saved as BACKWARD....FORWARD.
        long forwardBytes = forwardBits.Position - dst;
        long backwardBytes = dstEnd - backwardBits.Position;

        // Guard against stack overflow: use heap allocation for large backward streams.
        if (backwardBytes <= 4096)
        {
            byte* temp = stackalloc byte[(int)backwardBytes];
            Buffer.MemoryCopy(backwardBits.Position, temp, backwardBytes, backwardBytes);
            Buffer.MemoryCopy(dst, dst + backwardBytes, forwardBytes, forwardBytes);
            Buffer.MemoryCopy(temp, dst, backwardBytes, backwardBytes);
        }
        else
        {
            byte[] rentedTemp = System.Buffers.ArrayPool<byte>.Shared.Rent((int)backwardBytes);
            fixed (byte* temp = rentedTemp)
            {
                Buffer.MemoryCopy(backwardBits.Position, temp, backwardBytes, backwardBytes);
                Buffer.MemoryCopy(dst, dst + backwardBytes, forwardBytes, forwardBytes);
                Buffer.MemoryCopy(temp, dst, backwardBytes, backwardBytes);
            }
            System.Buffers.ArrayPool<byte>.Shared.Return(rentedTemp);
        }

        return dst + forwardBytes + backwardBytes;
    }

    #endregion

    #region EncodeArrayU8_tANS

    // Combined worst-case stack usage of EncodeArrayU8_tANS and its callees:
    //   EncodeArrayU8_tANS:
    //     weights:      256 * 4  = 1,024 bytes
    //     table:        512      =   512 bytes
    //     te:           256 * sizeof(TansEncEntry) = 256 * 16 = 4,096 bytes (ptr + ushort + byte + padding)
    //     teData:       2048 * 2 = 4,096 bytes
    //   Tans_EncodeTable (usedSymbols > 7 path):
    //     arrZ:         128 * 4  =   512 bytes
    //     ranges:       257 * 4  = 1,028 bytes
    //     arrX:         256 * 4  = 1,024 bytes
    //     arrY:          32 * 4  =   128 bytes
    //     arrW:         256      =   256 bytes
    //     srRice:       256      =   256 bytes
    //     srBits:       256      =   256 bytes
    //     srBitcount:   256      =   256 bytes
    //   Tans_EncodeTable (usedSymbols <= 7 path):
    //     sympos:         8 * 4  =    32 bytes
    //   Tans_NormalizeCounts:
    //     heap:         256 * sizeof(HeapEntry) = 256 * 8 = 2,048 bytes
    //   Tans_InitTable:
    //     pointers:       4 * 4  =    16 bytes
    //   Tans_EncodeBytes:
    //     temp (swap):  up to 4,096 bytes (guarded; >4096 uses ArrayPool)
    //   ---------------------------------------------------------------
    //   Total worst case (usedSymbols > 7 path):  ~15,400 bytes (~15 KB)
    //   Total worst case (usedSymbols <= 7 path): ~12,080 bytes (~12 KB)
    /// <summary>
    /// Main tANS encode function. Encodes a byte array using 5-state interleaved tANS.
    /// Returns the compressed size, or -1 if tANS encoding is not beneficial.
    /// </summary>
    /// <param name="dst">Destination buffer for compressed data.</param>
    /// <param name="dstEnd">End of destination buffer.</param>
    /// <param name="src">Source bytes to encode.</param>
    /// <param name="srcSize">Number of source bytes.</param>
    /// <param name="histo">Pre-computed histogram of source bytes.</param>
    /// <param name="speedTradeoff">Speed vs compression tradeoff factor.</param>
    /// <param name="costPtr">In/out: best cost so far. Updated if tANS improves it.</param>
    /// <param name="log2LookupTable">
    /// Pointer to the Log2LookupTable[4097] used for approximate bit-cost computation.
    /// Must be provided by the caller from the shared entropy infrastructure.
    /// </param>
    /// <returns>Compressed size in bytes, or -1 if encoding is not beneficial.</returns>
    [SkipLocalsInit]
    public static int EncodeArrayU8_tANS(byte* dst, byte* dstEnd, byte* src, int srcSize,
                                          HistoU8* histo, float speedTradeoff,
                                          float* costPtr, uint* log2LookupTable)
    {
        if (srcSize < 32)
        {
            return -1;
        }

        byte* srcEnd = src + srcSize - 5;

        // Temporarily subtract the last 5 symbols from the histogram
        // (they are stored as initial states, not encoded via the table)
        histo->Count[srcEnd[0]]--;
        histo->Count[srcEnd[1]]--;
        histo->Count[srcEnd[2]]--;
        histo->Count[srcEnd[3]]--;
        histo->Count[srcEnd[4]]--;

        int logTableBits, weightsSize, usedSymbols;
        uint* weights = stackalloc uint[256];
        try
        {
            logTableBits = Math.Max(Math.Min(Ilog2Round((uint)(srcSize - 5)) - 2, 11), 8);

            weightsSize = 256;
            while (weightsSize > 0 && histo->Count[weightsSize - 1] == 0)
            {
                weightsSize--;
            }

            usedSymbols = Tans_NormalizeCounts(weights, 1u << logTableBits, histo, srcSize - 5, weightsSize);
        }
        finally
        {
            // Restore the histogram even if encoding throws
            histo->Count[srcEnd[0]]++;
            histo->Count[srcEnd[1]]++;
            histo->Count[srcEnd[2]]++;
            histo->Count[srcEnd[3]]++;
            histo->Count[srcEnd[4]]++;
        }

        if (usedSymbols <= 1)
        {
            return -1;
        }

        float cost = (CostCoefficients.Current.TansBase + (srcSize - 5) * CostCoefficients.Current.TansPerSrcByte + usedSymbols * CostCoefficients.Current.TansPerUsedSymbol + (1 << logTableBits) * CostCoefficients.Current.TansPerTableEntry) * speedTradeoff + 5;

        int costLeft = (int)(*costPtr - cost);
        if (costLeft < 4)
        {
            return -1;
        }

        // Zero out unused weight entries
        for (int i = weightsSize; i < 256; i++)
        {
            weights[i] = 0;
        }

        // Encode the table into a temp buffer
        byte* table = stackalloc byte[512];
        BitWriter64Forward bits = new(table);
        bits.WriteNoFlush((uint)(logTableBits - 8), 3);
        Tans_EncodeTable(ref bits, logTableBits, weights, weightsSize, usedSymbols);
        int tableSize = (int)(bits.GetFinalPtr() - table);

        // Approximate bit cost check using log2 lookup table
        ulong approxBitsFrac = 0;
        if (log2LookupTable != null)
        {
            for (int i = 0; i < weightsSize; i++)
            {
                if (weights[i] != 0)
                {
                    int lutIndex = (int)Math.Min((uint)(weights[i] << (13 - logTableBits)), (uint)(StreamLZConstants.Log2LookupTableSize - 1));
                    approxBitsFrac += (ulong)log2LookupTable[lutIndex] * histo->Count[i];
                }
            }
            if (tableSize + (int)(approxBitsFrac >> 16) >= costLeft)
            {
                return -1;
            }
        }

        // Build the encoding table
        TansEncEntry* te = stackalloc TansEncEntry[256];
        ushort* teData = stackalloc ushort[1 << 11];
        Tans_InitTable(te, teData, weights, weightsSize, logTableBits);

        // Compute exact encoded bit counts
        uint forwardBitsCount, backwardBitsCount;
        Tans_GetEncodedBitCount(te, src, srcSize, logTableBits, &forwardBitsCount, &backwardBitsCount);

        int payloadBytes = BitsUp((int)forwardBitsCount) + BitsUp((int)backwardBitsCount);

        // The 5-state tANS decoder reads 4 bytes from the front and 4 bytes from the back
        // for initial state initialization. If the encoded payload is smaller than 8 bytes,
        // these reads overlap or extend past the data boundary. Reject and fall back to memcpy.
        if (payloadBytes < 8)
        {
            return -1;
        }

        int totalSize = tableSize + payloadBytes;
        if (totalSize >= costLeft || totalSize + cost >= *costPtr)
        {
            return -1;
        }
        if (totalSize + 8 > dstEnd - dst)
        {
            return -1;
        }

        *costPtr = cost + totalSize;

        Buffer.MemoryCopy(table, dst, tableSize, tableSize);
        return (int)(Tans_EncodeBytes(dst + tableSize, dstEnd, te, src, srcSize, logTableBits,
                                       (int)forwardBitsCount, (int)backwardBitsCount) - dst);
    }

    /// <summary>
    /// Overload that does not require a log2 lookup table.
    /// Skips the approximate bit-cost early-exit check.
    /// </summary>
    [SkipLocalsInit]
    public static int EncodeArrayU8_tANS(byte* dst, byte* dstEnd, byte* src, int srcSize,
                                          HistoU8* histo, float speedTradeoff,
                                          float* costPtr)
    {
        return EncodeArrayU8_tANS(dst, dstEnd, src, srcSize, histo, speedTradeoff, costPtr, null);
    }

    #endregion
}
