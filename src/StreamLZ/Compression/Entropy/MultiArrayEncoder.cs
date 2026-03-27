using System.Buffers.Binary;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;
using static StreamLZ.Compression.CompressUtils;

namespace StreamLZ.Compression.Entropy;

/// <summary>
/// Multi-array entropy encoder.
/// Supports both simple multi-array encoding (independent sub-arrays) and
/// advanced multi-array encoding (histogram clustering with interval splitting).
/// </summary>
internal static unsafe class MultiArrayEncoder
{
    #region Constants and types

    private const int MaxBitLength = 11;

    // EntropyOptions enum is defined in Compression/CompressTypes.cs (top-level type).

    /// <summary>
    /// Histogram with a precomputed total count and temp field for clustering.
    /// </summary>
    private struct HistoAndCount
    {
        public ByteHistogram Histo;
        public int Sum;
        public int Temp;
    }

    /// <summary>
    /// Per-symbol bit cost profile in units of 1/256 bits.
    /// </summary>
    private unsafe struct BitProfile
    {
        public fixed ushort Bits[256];
    }

    /// <summary>
    /// Describes a contiguous range of bytes within an input array
    /// that is assigned to a particular histogram cluster.
    /// </summary>
    private struct ArrRange
    {
        public int CharIdx;
        public int CharCount;
        public int BestHisto;

        public ArrRange(int charIdx, int charCount, int histo)
        {
            CharIdx = charIdx;
            CharCount = charCount;
            BestHisto = histo;
        }
    }

    /// <summary>
    /// Delegate type for cost estimation functions used by histogram reduction.
    /// </summary>
    /// <param name="histo">Histogram to evaluate.</param>
    /// <param name="histoSum">Total count in histogram.</param>
    /// <returns>Approximate cost in bits.</returns>
    internal delegate uint GetCostFunc(ByteHistogram* histo, int histoSum);

    /// <summary>
    /// Delegate for encoding a sub-array with compact header.
    /// This must be provided by the caller's entropy infrastructure.
    /// </summary>
    /// <param name="dst">Destination buffer.</param>
    /// <param name="dstEnd">End of destination buffer.</param>
    /// <param name="src">Source data.</param>
    /// <param name="srcSize">Source size.</param>
    /// <param name="opts">Encoding options.</param>
    /// <param name="speedTradeoff">Speed tradeoff factor.</param>
        /// <param name="costPtr">In/out cost.</param>
    /// <param name="level">Compression level.</param>
    /// <param name="histoPtr">Optional histogram output.</param>
    /// <returns>Compressed size, or -1 on failure.</returns>
    internal delegate int EncodeArrayFunc(byte* dst, byte* dstEnd, byte* src, int srcSize,
                                        int opts, float speedTradeoff,
                                        float* costPtr, int level, ByteHistogram* histoPtr);

    #endregion

    #region Helpers

    /// <summary>
    /// Counts byte occurrences into a ByteHistogram.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void CountBytesHistogram(byte* src, int size, ByteHistogram* histo)
    {
        Unsafe.InitBlockUnaligned(histo, 0, (uint)sizeof(ByteHistogram));
        for (int i = 0; i < size; i++)
        {
            histo->Count[src[i]]++;
        }
    }

    private static void SubtractHisto(ByteHistogram* dst, ByteHistogram* a, ByteHistogram* b)
    {
        for (int i = 0; i < 256; i++)
        {
            dst->Count[i] = a->Count[i] - b->Count[i];
        }
    }

    private static void AddHistogram(ByteHistogram* d, ByteHistogram* a, ByteHistogram* b)
    {
        for (int i = 0; i < 256; i++)
        {
            d->Count[i] = a->Count[i] + b->Count[i];
        }
    }

    private static void AddHistogram(ref HistoAndCount dst, ref HistoAndCount src)
    {
        dst.Sum += src.Sum;
        AddHistogram((ByteHistogram*)Unsafe.AsPointer(ref dst.Histo),
                     (ByteHistogram*)Unsafe.AsPointer(ref dst.Histo),
                     (ByteHistogram*)Unsafe.AsPointer(ref src.Histo));
    }

    #endregion

    #region Approximate bit cost

    /// <summary>
    /// Computes approximate bit cost (in 1/256 units) for a histogram using log2 lookup.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint GetApproxHistoBitsFrac(ByteHistogram* h, int histoSum, uint* log2Table)
    {
        if (histoSum <= 0)
        {
            return 0;
        }
        int factor = (int)(0x40000000u / (uint)histoSum);
        uint sum = 0;
        for (int i = 0; i < 256; i++)
        {
            uint c = h->Count[i];
            if (c != 0)
            {
                uint idx = (uint)(factor * c) >> 18;
                if (idx > 4096)
                {
                    idx = 4096;
                }
                uint bits = log2Table[idx] >> 4;
                uint maxBits = MaxBitLength * 256u;
                sum += c * Math.Min(maxBits, bits);
            }
        }
        return sum;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint GetApproxHistoBits(ByteHistogram* h, int histoSum, uint* log2Table)
    {
        return GetApproxHistoBitsFrac(h, histoSum, log2Table) >> 8;
    }

    private static void MakeHistoBitProfile(ByteHistogram* h, int histoSum, BitProfile* bp, uint* log2Table)
    {
        if (histoSum <= 0)
        {
            return;
        }
        int factor = (int)(0x40000000u / (uint)histoSum);
        for (int i = 0; i < 256; i++)
        {
            uint idx = (uint)(factor * h->Count[i]) >> 18;
            if (idx > 4096)
            {
                idx = 4096;
            }
            uint bits = log2Table[idx] >> 4;
            uint maxBits = MaxBitLength * 256u;
            bp->Bits[i] = (ushort)Math.Min(maxBits, bits);
        }
    }

    private static uint GetHistoBitUsageWithBitProfile(ByteHistogram* h, int histoSum, BitProfile* bp)
    {
        uint rv = 0;
        for (int i = 0; i < 256; i++)
        {
            rv += h->Count[i] * bp->Bits[i];
        }
        return rv;
    }

    #endregion

    #region Heap operations for histogram reduction

    private struct ReduceEntry : IComparable<ReduceEntry>
    {
        public float Value;
        public int CostInBits;
        public int IValue, JValue;
        public int ICount, JCount;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public readonly int CompareTo(ReduceEntry other) => Value.CompareTo(other.Value);
    }


    #endregion

    #region ReduceNumHistograms

    /// <summary>
    /// Merges histograms greedily using a max-heap on merge benefit,
    /// until the number of histograms is &lt;= maxCount or further merges are not beneficial.
    /// </summary>
    private static void ReduceNumHistograms(
        HistoAndCount* histos, ref int count,
        float A, float B, int maxCount,
        GetCostFunc getCost, uint* log2Table)
    {
        int n = count;

        // Compute initial costs
        for (int i = 0; i < n; i++)
        {
            ByteHistogram* hp = (ByteHistogram*)Unsafe.AsPointer(ref histos[i].Histo);
            histos[i].Temp = (int)getCost(hp, histos[i].Sum);
        }

        int entCount = n * (n - 1) / 2;
        ReduceEntry* ents = (ReduceEntry*)NativeMemory.Alloc((nuint)(entCount * sizeof(ReduceEntry)));
        try
        {
            ReduceEntry* bPtr = ents;

            ByteHistogram tempValues;

            for (int i = 0; i < n; i++)
            {
                for (int j = i + 1; j < n; j++)
                {
                    AddHistogram(&tempValues, (ByteHistogram*)Unsafe.AsPointer(ref histos[i].Histo),
                                 (ByteHistogram*)Unsafe.AsPointer(ref histos[j].Histo));

                    bPtr->CostInBits = (int)getCost(&tempValues, histos[i].Sum + histos[j].Sum);
                    bPtr->JValue = j;
                    bPtr->IValue = i;
                    bPtr->JCount = histos[j].Sum;
                    bPtr->ICount = histos[i].Sum;
                    bPtr->Value = (histos[j].Temp + histos[i].Temp - bPtr->CostInBits) * CostCoefficients.Current.CostToBitsFactor + A;
                    bPtr++;
                }
            }

            ReduceEntry* bFirst = ents;
            MaxHeap<ReduceEntry>.MakeHeap(bFirst, bPtr);

            while (bPtr != bFirst)
            {
                ReduceEntry cur = *bFirst;
                MaxHeap<ReduceEntry>.PopHeap(bFirst, bPtr--);

                ref HistoAndCount hi = ref histos[cur.IValue];
                ref HistoAndCount hj = ref histos[cur.JValue];

                if (hi.Sum == cur.ICount && hj.Sum == cur.JCount)
                {
                    if (cur.Value < B && n <= maxCount)
                    {
                        break;
                    }

                    AddHistogram(ref hi, ref hj);
                    hj.Sum = 0;
                    hj.Temp = 0;
                    hi.Temp = cur.CostInBits;
                    n--;
                }
                else
                {
                    if (hi.Sum != 0 && hj.Sum != 0)
                    {
                        AddHistogram(&tempValues, (ByteHistogram*)Unsafe.AsPointer(ref hi.Histo),
                                     (ByteHistogram*)Unsafe.AsPointer(ref hj.Histo));

                        bPtr->CostInBits = (int)getCost(&tempValues, hi.Sum + hj.Sum);
                        bPtr->JValue = cur.JValue;
                        bPtr->IValue = cur.IValue;
                        bPtr->JCount = hj.Sum;
                        bPtr->ICount = hi.Sum;
                        bPtr->Value = (hj.Temp + hi.Temp - bPtr->CostInBits) * CostCoefficients.Current.CostToBitsFactor + A;
                        MaxHeap<ReduceEntry>.PushHeap(bFirst, ++bPtr);
                    }
                }
            }

            // Compact: remove entries with Sum == 0
            int d = 0;
            for (int i = 0; i < count; i++)
            {
                if (histos[i].Sum != 0)
                {
                    if (i != d)
                    {
                        histos[d] = histos[i];
                    }
                    d++;
                }
            }
            count = n;
        }
        finally
        {
            NativeMemory.Free(ents);
        }
    }

    #endregion

    #region AdjustHistoWindow

    /// <summary>
    /// Slides a histogram window left or right to better match symbol distribution.
    /// Returns the adjusted start pointer.
    /// </summary>
    private static byte* AdjustHistoWindow(ByteHistogram* histo,
                                           byte* dataCur, int size,
                                           byte* dataStart, byte* dataEnd)
    {
        byte* dataCurEnd = dataCur + size;
        int moveLeftScore = (dataCur > dataStart)
            ? (int)(histo->Count[dataCur[-1]] - histo->Count[dataCurEnd[-1]])
            : -1;
        int moveRightScore = (dataCurEnd < dataEnd)
            ? (int)(histo->Count[dataCurEnd[0]] - histo->Count[dataCur[0]])
            : -1;

        if (moveRightScore >= moveLeftScore)
        {
            while (dataCurEnd < dataEnd &&
                   histo->Count[*dataCurEnd] >= histo->Count[*dataCur])
            {
                histo->Count[*dataCur]--;
                histo->Count[*dataCurEnd]++;
                dataCur++;
                dataCurEnd++;
            }
        }
        else
        {
            while (dataCur > dataStart &&
                   histo->Count[dataCur[-1]] > histo->Count[dataCurEnd[-1]])
            {
                histo->Count[dataCur[-1]]++;
                histo->Count[dataCurEnd[-1]]--;
                dataCur--;
                dataCurEnd--;
            }
        }
        return dataCur;
    }

    #endregion

    #region EncodeAdvMultiArray_BuildTable (SSE2)

    /// <summary>
    /// Builds the interval assignment table using SSE2 SIMD to find the best histogram
    /// for each byte position. Produces break masks and best-index arrays for backtracking.
    /// </summary>
    [SkipLocalsInit]
    private static void EncodeAdvMultiArray_BuildTable(
        ulong* breakMask, byte* bestIndexPtr,
        byte* ptrCur, byte* ptrEnd,
        ushort* intervalScores, ushort* bitsForSym,
        int numIntervalsUnused, int numU16,
        int prevScoreInt, int costPlus4096In)
    {
        if (Sse2.IsSupported)
        {
            Vector128<short> costPlus4096 = Vector128.Create((short)costPlus4096In);
            Vector128<short> prevScore = Vector128.Create((short)prevScoreInt);
            Vector128<short> bestScore;

            if (numU16 > 8)
            {
                while (ptrCur < ptrEnd)
                {
                    int i = 0;
                    ulong bits = 0;
                    ushort* bsym = &bitsForSym[numU16 * *ptrCur++];
                    bestScore = Vector128.Create(short.MaxValue);
                    do
                    {
                        Vector128<short> scoresSub = Sse2.Subtract(
                            Sse2.LoadVector128((short*)&intervalScores[i]), prevScore);
                        Vector128<short> scores = Sse2.Add(
                            Sse2.LoadVector128((short*)&bsym[i]),
                            Sse2.Min(scoresSub, costPlus4096));
                        Sse2.Store((short*)&intervalScores[i], scores);
                        bestScore = Sse2.Min(bestScore, scores);
                        bits |= (ulong)(uint)Sse2.MoveMask(
                            Sse2.PackSignedSaturate(
                                Sse2.CompareGreaterThan(scoresSub, costPlus4096),
                                Vector128<short>.Zero).AsByte()) << i;
                    } while ((i += 8) < numU16);

                    // Horizontal min across all lanes
                    bestScore = Sse2.Min(bestScore, Sse2.Shuffle(bestScore.AsInt32(), 0x4e).AsInt16());
                    bestScore = Sse2.Min(bestScore, Sse2.Shuffle(bestScore.AsInt32(), 0xb1).AsInt16());
                    bestScore = Sse2.Min(bestScore,
                        Sse2.ShuffleLow(Sse2.ShuffleHigh(bestScore, 0xb1), 0xb1));

                    // Find index of best score
                    int mask;
                    for (i = 0; (mask = Sse2.MoveMask(
                        Sse2.CompareEqual(Sse2.LoadVector128((short*)&intervalScores[i]), bestScore).AsByte())) == 0; i += 8) { }
                    int bestIndex = i + (BitOperations.TrailingZeroCount((uint)mask) >> 1);
                    *breakMask++ = bits;
                    *bestIndexPtr++ = (byte)bestIndex;
                    prevScore = bestScore;
                }
            }
            else
            {
                Vector128<short> scores = Sse2.LoadVector128((short*)intervalScores);
                while (ptrCur < ptrEnd)
                {
                    ushort* bsym = &bitsForSym[8 * *ptrCur++];
                    Vector128<short> scoresSub = Sse2.Subtract(scores, prevScore);
                    scores = Sse2.Add(
                        Sse2.LoadVector128((short*)bsym),
                        Sse2.Min(scoresSub, costPlus4096));
                    ulong bitsVal = (ulong)(uint)Sse2.MoveMask(
                        Sse2.PackSignedSaturate(
                            Sse2.CompareGreaterThan(scoresSub, costPlus4096),
                            Vector128.Create((short)0)).AsByte());
                    bestScore = Sse2.Min(scores, Sse2.Shuffle(scores.AsInt32(), 0x4e).AsInt16());
                    bestScore = Sse2.Min(bestScore, Sse2.Shuffle(bestScore.AsInt32(), 0xb1).AsInt16());
                    bestScore = Sse2.Min(bestScore,
                        Sse2.ShuffleLow(Sse2.ShuffleHigh(bestScore, 0xb1), 0xb1));
                    int bestIndex = BitOperations.TrailingZeroCount((uint)Sse2.MoveMask(
                        Sse2.CompareEqual(scores, bestScore).AsByte())) >> 1;
                    *breakMask++ = bitsVal;
                    *bestIndexPtr++ = (byte)bestIndex;
                    prevScore = bestScore;
                }
            }
        }
        else
        {
            // Scalar fallback
            while (ptrCur < ptrEnd)
            {
                ulong bits = 0;
                ushort* bsym = &bitsForSym[numU16 * *ptrCur++];
                int bestVal = short.MaxValue;
                int bestIdx = 0;

                for (int i = 0; i < numU16; i++)
                {
                    int scoreSub = intervalScores[i] - (short)prevScoreInt;
                    int costClamped = Math.Min(scoreSub, costPlus4096In);
                    int score = bsym[i] + costClamped;
                    intervalScores[i] = (ushort)score;
                    if (scoreSub > costPlus4096In)
                    {
                        bits |= 1ul << i;
                    }
                    if (score < bestVal)
                    {
                        bestVal = score;
                        bestIdx = i;
                    }
                }
                *breakMask++ = bits;
                *bestIndexPtr++ = (byte)bestIdx;
                prevScoreInt = bestVal;
            }
        }
    }

    #endregion

    #region GetMultiarrayLog2

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint GetMultiarrayLog2(uint v)
    {
        if (v == 0)
        {
            return 0;
        }
        uint b = (uint)BitOperations.Log2(v);
        // Approximate: (b << 13) + interpolation, shifted right by 5
        // Simplified without GetLog2Interpolate
        return (b << 13) >> 5;
    }

    #endregion

    #region GetBetterHisto

    /// <summary>
    /// Compares which of two histograms is a better fit for a block of source bytes.
    /// Returns positive if histo1 is worse than histo2 (i.e., should move bytes to histo2).
    /// </summary>
    private static int GetBetterHisto(byte* src, int srcSize,
                                      ByteHistogram* histo1, uint histo1Sum,
                                      ByteHistogram* histo2, uint histo2Sum,
                                      uint* log2Table)
    {
        int factor1 = histo1Sum > 0 ? (int)(0x40000000u / histo1Sum) : 0;
        int factor2 = histo2Sum > 0 ? (int)(0x40000000u / histo2Sum) : 0;
        int sum = 0;
        for (int i = 0; i < srcSize; i++)
        {
            uint idx1 = (uint)(factor1 * histo1->Count[src[i]]) >> 18;
            uint idx2 = (uint)(factor2 * histo2->Count[src[i]]) >> 18;
            if (idx1 > 4096)
            {
                idx1 = 4096;
            }
            if (idx2 > 4096)
            {
                idx2 = 4096;
            }
            uint bits1 = log2Table[idx1] >> 4;
            uint bits2 = log2Table[idx2] >> 4;
            uint max = MaxBitLength * 256u;
            sum += (int)Math.Min(max, bits1);
            sum -= (int)Math.Min(max, bits2);
        }
        return sum;
    }

    #endregion

    #region MoveBytesBetweenHistos

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void MoveBytesBetweenHistos(byte* src, int srcSize, ByteHistogram* from, ByteHistogram* to)
    {
        for (int i = 0; i < srcSize; i++)
        {
            byte v = src[i];
            from->Count[v]--;
            to->Count[v]++;
        }
    }

    #endregion

    #region OptimizeSplitBoundaries

    /// <summary>
    /// Fine-tunes split boundaries between adjacent histogram blocks by moving individual bytes.
    /// </summary>
    private static void OptimizeSplitBoundaries(byte* src, byte* srcEnd,
                                                 ByteHistogram* histos, uint* sizes, uint* offsets,
                                                 int numArrs)
    {
        ByteHistogram* h = histos + 1;
        for (int i = 1; i < numArrs; i++, h++)
        {
            byte* p = &src[offsets[i]];
            long scoreCur = sizes[i - 1] != 0
                ? (long)sizes[i - 1] * h->Count[p[-1]] - (long)sizes[i] * h[-1].Count[p[-1]]
                : 0;
            long scoreNxt = sizes[i] != 0
                ? (long)sizes[i] * h[-1].Count[p[0]] - (long)sizes[i - 1] * h->Count[p[0]]
                : 0;

            if (scoreCur > 0 && scoreCur > scoreNxt)
            {
                do
                {
                    int v = *--p;
                    h[-1].Count[v]--;
                    h->Count[v]++;
                    sizes[i - 1]--;
                    sizes[i]++;
                    offsets[i]--;
                } while (sizes[i - 1] != 0 &&
                         ((long)sizes[i - 1] * h->Count[p[-1]] - (long)sizes[i] * h[-1].Count[p[-1]]) > 0);
            }
            else if (scoreNxt > 0)
            {
                do
                {
                    int v = *p++;
                    h[-1].Count[v]++;
                    h->Count[v]--;
                    sizes[i - 1]++;
                    sizes[i]--;
                    offsets[i]++;
                } while (sizes[i] != 0 &&
                         ((long)sizes[i] * h[-1].Count[p[0]] - (long)sizes[i - 1] * h->Count[p[0]]) > 0);
            }
        }
    }

    #endregion

    #region IndexCount for sorting

    private struct IndexCount
    {
        public int Index;
        public int Count;
    }

    private static void SortIndexCountDescending(IndexCount* arr, int n)
    {
        // Simple insertion sort (n <= 63)
        for (int i = 1; i < n; i++)
        {
            IndexCount key = arr[i];
            int j = i - 1;
            while (j >= 0 && arr[j].Count < key.Count)
            {
                arr[j + 1] = arr[j];
                j--;
            }
            arr[j + 1] = key;
        }
    }

    #endregion

    #region MergeEntry

    private struct MergeEntry
    {
        public float Diff;
        public float CombinedCost;
        public int Left, Right;
    }

    #endregion

    #region MultiHistCandi

    private struct MultiHistCandi : IComparable<MultiHistCandi>
    {
        public int Savings;
        public int Idx;
        public int ExtendDirection;
        public ulong SizeAndOffs;
        public ulong SizeAndOffsOther;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public readonly int CompareTo(MultiHistCandi other) => Savings.CompareTo(other.Savings);
    }


    #endregion

    #region MultiArrayAddCandidate

    private static void MultiArrayAddCandidate(int idx, int arrayCount, ByteHistogram* histo,
                                                uint* chunkSizes, uint* chunkOffs,
                                                MultiHistCandi* mhs, int* numMhs,
                                                byte* src, int finetuneSize, int direction,
                                                uint* log2Table)
    {
        if (idx > 0)
        {
            int otherSize = (int)chunkSizes[idx - 1];
            if (otherSize >= 2 * finetuneSize && direction <= 0)
            {
                int gain = GetBetterHisto(&src[chunkOffs[idx] - (uint)finetuneSize], finetuneSize,
                                          &histo[idx], chunkSizes[idx],
                                          &histo[idx - 1], (uint)otherSize, log2Table);
                if (gain < 0)
                {
                    MultiHistCandi* m = &mhs[(*numMhs)++];
                    m->Savings = -gain;
                    m->ExtendDirection = 0;
                    m->Idx = idx;
                    m->SizeAndOffs = chunkSizes[idx] | ((ulong)chunkOffs[idx] << 32);
                    m->SizeAndOffsOther = chunkSizes[idx - 1] | ((ulong)chunkOffs[idx - 1] << 32);
                }
            }
        }
        if (idx < arrayCount - 1)
        {
            int otherSize = (int)chunkSizes[idx + 1];
            if (otherSize >= 2 * finetuneSize && direction >= 0)
            {
                int gain = GetBetterHisto(&src[chunkSizes[idx] + chunkOffs[idx]], finetuneSize,
                                          &histo[idx], chunkSizes[idx],
                                          &histo[idx + 1], (uint)otherSize, log2Table);
                if (gain < 0)
                {
                    MultiHistCandi* m = &mhs[(*numMhs)++];
                    m->Savings = -gain;
                    m->Idx = idx;
                    m->ExtendDirection = 1;
                    m->SizeAndOffs = chunkSizes[idx] | ((ulong)chunkOffs[idx] << 32);
                    m->SizeAndOffsOther = chunkSizes[idx + 1] | ((ulong)chunkOffs[idx + 1] << 32);
                }
            }
        }
    }

    #endregion

    #region MultiArrayDeleteJunk

    private static void MultiArrayDeleteJunk(MultiHistCandi* mhs, int* numMhs,
                                              uint* chunkSize, uint* chunkPos)
    {
        for (int pos = *numMhs; pos-- > 0;)
        {
            ref MultiHistCandi cur = ref mhs[pos];
            int idx = cur.Idx;
            int other = idx + (cur.ExtendDirection != 0 ? 1 : -1);
            if (cur.SizeAndOffs != (chunkSize[idx] | ((ulong)chunkPos[idx] << 32)) ||
                cur.SizeAndOffsOther != (chunkSize[other] | ((ulong)chunkPos[other] << 32)))
            {
                cur = mhs[--*numMhs];
            }
        }
    }

    #endregion

    #region EncodeMultiArray (top-level)

    /// <summary>
    /// Top-level multi-array encoder. Tries simple encoding first, then advanced if beneficial.
    /// Returns compressed size or -1 on failure.
    /// </summary>
    /// <param name="dst">Destination buffer.</param>
    /// <param name="dstEnd">End of destination buffer.</param>
    /// <param name="arrayData">Array of pointers to input arrays.</param>
    /// <param name="arrayLens">Array of input array lengths.</param>
    /// <param name="arrayCount">Number of input arrays.</param>
    /// <param name="opts">Encoding options.</param>
    /// <param name="speedTradeoff">Speed vs compression tradeoff.</param>
        /// <param name="costPtr">In/out: best cost. Updated on improvement.</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="encodeArray">Delegate for encoding individual sub-arrays.</param>
    /// <param name="getCostApprox">Approximate histogram cost function.</param>
    /// <param name="log2Table">Pointer to Log2LookupTable[4097].</param>
    /// <returns>Compressed size in bytes, or -1 on failure.</returns>
    [SkipLocalsInit]
    public static int EncodeMultiArray(byte* dst, byte* dstEnd,
                                       byte** arrayData, int* arrayLens, int arrayCount,
                                       int opts, float speedTradeoff,
                                       float* costPtr, int level,
                                       EncodeArrayFunc encodeArray,
                                       GetCostFunc getCostApprox,
                                       uint* log2Table)
    {
        if (level < 8)
        {
            opts &= ~(int)EntropyOptions.AllowMultiArrayAdvanced;
        }

        int n1 = EncodeSimpleMultiArray(dst, dstEnd, arrayData, arrayLens, arrayCount,
                                        opts, speedTradeoff, costPtr, level, encodeArray);

        int n2 = EncodeAdvMultiArray(dst, dstEnd, arrayData, arrayLens, arrayCount,
                                     opts, speedTradeoff, costPtr, level,
                                     encodeArray, getCostApprox, log2Table);

        return n2 >= 0 ? n2 : n1;
    }

    #endregion

    #region EncodeSimpleMultiArray

    /// <summary>
    /// Simple multi-array encoder: encodes each sub-array independently with a compact header.
    /// </summary>
    [SkipLocalsInit]
    private static int EncodeSimpleMultiArray(byte* dst, byte* dstEnd,
                                              byte** arrayData, int* arrayLens, int arrayCount,
                                              int opts, float speedTradeoff,
                                              float* costPtr, int level,
                                              EncodeArrayFunc encodeArray)
    {
        float cost = 1.0f;
        byte* destinationStart = dst;
        *dst++ = 0x80;

        for (int i = 0; i < arrayCount; i++)
        {
            float tmpCost = StreamLZConstants.InvalidCost;
            int n = encodeArray(dst, dstEnd, arrayData[i], arrayLens[i], opts,
                                speedTradeoff, &tmpCost, level, null);
            if (n < 0)
            {
                return -1;
            }
            dst += n;
            cost += tmpCost;
        }
        *costPtr = cost;
        return (int)(dst - destinationStart);
    }

    #endregion

    #region EncodeAdvMultiArray

    /// <summary>
    /// Advanced multi-array encoder with histogram clustering and interval splitting.
    /// Iteratively clusters input regions into optimal histograms, then encodes
    /// the interleaved interval index/length streams.
    /// </summary>
    [SkipLocalsInit]
    private static int EncodeAdvMultiArray(byte* dst, byte* dstEnd,
                                           byte** arrayData, int* arrayLens, int arrayCount,
                                           int opts, float speedTradeoff,
                                           float* costPtr, int level,
                                           EncodeArrayFunc encodeArray,
                                           GetCostFunc getCostApprox,
                                           uint* log2Table)
    {
        int totalInputBytes = 0, longestInputArray = 0;
        int maxArrs = (level == 9) ? 62 : Math.Max(Math.Min(1 << level, 32), 8);

        for (int i = 0; i < arrayCount; i++)
        {
            totalInputBytes += arrayLens[i];
            longestInputArray = Math.Max(longestInputArray, arrayLens[i]);
        }

        if (totalInputBytes < 96 || longestInputArray < 32)
        {
            return -1;
        }

        int bytesPerRandRegion = Math.Max(totalInputBytes / 100, 64);
        int numRandRegions = arrayCount + 1 + totalInputBytes / bytesPerRandRegion;

        // Allocate histogram array
        int histoCapacity = numRandRegions + 64;
        HistoAndCount* arrHisto = (HistoAndCount*)NativeMemory.AllocZeroed(
            (nuint)(histoCapacity * sizeof(HistoAndCount)));
        int arrHistoCount = 0;

        // Compute approximate histograms for random regions of the input
        uint rngState = 0xF309CC5E;
        for (int i = 0; i < arrayCount; i++)
        {
            int len = arrayLens[i];
            byte* dataStart = arrayData[i];
            byte* dataEndLocal = dataStart + len;
            byte* dataCur = dataStart;
            if (len < 16)
            {
                continue;
            }
            for (;;)
            {
                int numBytes = (bytesPerRandRegion >> 1) + (int)((ulong)rngState * (uint)bytesPerRandRegion >> 32);
                rngState = 69069 * rngState + 12345;
                numBytes = Math.Min(numBytes, (int)(dataEndLocal - dataCur));
                if (numBytes < 16)
                {
                    break;
                }

                ref HistoAndCount back = ref arrHisto[arrHistoCount++];
                int n = Math.Min(numBytes, 256);
                back.Sum = n;
                CountBytesHistogram(dataCur, n, (ByteHistogram*)Unsafe.AsPointer(ref back.Histo));

                byte* adjusted = AdjustHistoWindow((ByteHistogram*)Unsafe.AsPointer(ref back.Histo),
                                                   dataCur, n, dataStart, dataEndLocal);
                if (adjusted < dataCur)
                {
                    adjusted = dataCur;
                }
                dataCur = adjusted + numBytes;
            }
        }

        // Build initial good histograms via greedy selection
        int goodCapacity = 2 * maxArrs + 4;
        HistoAndCount* arrHistoGood = (HistoAndCount*)NativeMemory.AllocZeroed(
            (nuint)(goodCapacity * sizeof(HistoAndCount)));
        int goodCount = 0;

        BitProfile* arrBitProfile = (BitProfile*)NativeMemory.AllocZeroed(
            (nuint)((maxArrs + 4) * sizeof(BitProfile)));
        int bpCount = 0;

        // Create dummy histogram
        {
            ref HistoAndCount dummy = ref arrHistoGood[goodCount++];
            for (int i = 0; i < 256; i++)
            {
                dummy.Histo.Count[i] = 10;
            }
            dummy.Sum = 256 * 10;
            MakeHistoBitProfile((ByteHistogram*)Unsafe.AsPointer(ref dummy.Histo), dummy.Sum,
                               &arrBitProfile[bpCount++], log2Table);
        }

        int* arrBitUsage = (int*)NativeMemory.Alloc((nuint)(arrHistoCount * sizeof(int)));
        int* arrScore = (int*)NativeMemory.Alloc((nuint)(arrHistoCount * sizeof(int)));
        int* arrBestIdx = (int*)NativeMemory.Alloc((nuint)(arrHistoCount * sizeof(int)));

        for (int i = 0; i < arrHistoCount; i++)
        {
            arrBitUsage[i] = (int)GetApproxHistoBitsFrac(
                (ByteHistogram*)Unsafe.AsPointer(ref arrHisto[i].Histo), arrHisto[i].Sum, log2Table);
            arrScore[i] = int.MaxValue;
            arrBestIdx[i] = 0;
        }

        while (goodCount < 2 * maxArrs)
        {
            int highestCostSeen = 0;
            int worstIndex = 0;

            for (int j = 0; j < arrHistoCount; j++)
            {
                int bitUsage = (int)GetHistoBitUsageWithBitProfile(
                    (ByteHistogram*)Unsafe.AsPointer(ref arrHisto[j].Histo), arrHisto[j].Sum,
                    &arrBitProfile[bpCount - 1]);
                bitUsage -= arrBitUsage[j];
                if (bitUsage < arrScore[j])
                {
                    arrScore[j] = bitUsage;
                    arrBestIdx[j] = goodCount - 1;
                }
                if (arrScore[j] > highestCostSeen)
                {
                    highestCostSeen = arrScore[j];
                    worstIndex = j;
                }
            }
            if (highestCostSeen <= 256)
            {
                break;
            }

            arrHistoGood[goodCount++] = arrHisto[worstIndex];
            MakeHistoBitProfile(
                (ByteHistogram*)Unsafe.AsPointer(ref arrHistoGood[goodCount - 1].Histo),
                arrHistoGood[goodCount - 1].Sum,
                &arrBitProfile[bpCount++], log2Table);

            // Remove worst from array
            int lastIdx = arrHistoCount - 1;
            arrHisto[worstIndex] = arrHisto[lastIdx];
            arrBitUsage[worstIndex] = arrBitUsage[lastIdx];
            arrScore[worstIndex] = arrScore[lastIdx];
            arrBestIdx[worstIndex] = arrBestIdx[lastIdx];
            arrHistoCount--;
        }

        // Merge remaining histograms into their best-matching good histogram
        for (int j = 0; j < arrHistoCount; j++)
        {
            int bestIdxVal = arrBestIdx[j];
            AddHistogram(ref arrHistoGood[bestIdxVal], ref arrHisto[j]);
        }

        // Swap good -> main array
        NativeMemory.Free(arrHisto);
        arrHisto = arrHistoGood;
        arrHistoCount = goodCount;

        NativeMemory.Free(arrBitUsage);
        NativeMemory.Free(arrScore);
        NativeMemory.Free(arrBestIdx);

        if (arrHistoCount == 0)
        {
            NativeMemory.Free(arrHisto);
            NativeMemory.Free(arrBitProfile);
            return -1;
        }

        if (arrHistoCount > maxArrs)
        {
            ReduceNumHistograms(arrHisto, ref arrHistoCount, 2.0f, 0.0f, maxArrs,
                (ByteHistogram* h, int sum) => GetApproxHistoBits(h, sum, log2Table), log2Table);
        }

        if (arrHistoCount <= 1)
        {
            NativeMemory.Free(arrHisto);
            NativeMemory.Free(arrBitProfile);
            return -1;
        }

        int baseCost = (int)(speedTradeoff * CostCoefficients.Current.MultiArrayBaseCostFactor * 8.0f * 256.0f);
        int costThres = baseCost + 4096;

        // Null-initialize all pointers before the allocation sequence so that
        // the cleanup label (which calls NativeMemory.Free on each) is safe even
        // if an exception occurs partway through allocation. NativeMemory.Free
        // is a no-op for null pointers.
        ulong* arrBreaks = null;
        byte* arrBestIndex = null;
        ArrRange* pickedRanges = null;
        int* pickedRangeOffsets = null;
        int* pickedRangeCounts = null;

        // Allocate break/index arrays
        arrBreaks = (ulong*)NativeMemory.Alloc((nuint)(longestInputArray * sizeof(ulong)));
        arrBestIndex = (byte*)NativeMemory.Alloc((nuint)longestInputArray);

        // Picked ranges: store as flat array with per-array offsets
        int maxRangesPerArray = longestInputArray + 1;
        int maxTotalRanges = arrayCount * 64;  // enforced: encoding fails if exceeded
        pickedRanges = (ArrRange*)NativeMemory.AllocZeroed(
            (nuint)(maxTotalRanges * sizeof(ArrRange)));
        pickedRangeOffsets = (int*)NativeMemory.AllocZeroed((nuint)((arrayCount + 1) * sizeof(int)));
        pickedRangeCounts = (int*)NativeMemory.AllocZeroed((nuint)(arrayCount * sizeof(int)));

        int bpfSize = 0;
        int result = -1;

        int tempRangesCount = longestInputArray + 1;
        int tempRangesByteSize = tempRangesCount * sizeof(ArrRange);
        ArrRange* tempRangesHeap = (tempRangesByteSize > 4096)
            ? (ArrRange*)NativeMemory.Alloc((nuint)tempRangesByteSize)
            : null;

        try
        {

        ushort* intervalScores = stackalloc ushort[128];
        ArrRange* tempRanges;
        if (tempRangesHeap != null)
        {
            tempRanges = tempRangesHeap;
        }
        else
        {
            ArrRange* stackBuf = stackalloc ArrRange[tempRangesCount];
            tempRanges = stackBuf;
        }

        for (int iteration = 0; iteration < 3; iteration++)
        {
            // Rebuild bit profiles from current histograms
            bpfSize = arrHistoCount;
            int k = arrHistoCount;
            while (k-- > 0)
            {
                MakeHistoBitProfile(
                    (ByteHistogram*)Unsafe.AsPointer(ref arrHisto[k].Histo), arrHisto[k].Sum,
                    &arrBitProfile[k], log2Table);
                uint fracBits = GetHistoBitUsageWithBitProfile(
                    (ByteHistogram*)Unsafe.AsPointer(ref arrHisto[k].Histo), arrHisto[k].Sum,
                    &arrBitProfile[k]);
                if (fracBits >= (uint)CostCoefficients.Current.MultiArrayIncompressibleThreshold * (uint)arrHisto[k].Sum)
                {
                    arrBitProfile[k] = arrBitProfile[bpfSize - 1];
                    bpfSize--;
                }
            }

            // Add flat-distribution profile if room
            if (bpfSize < 0x3f)
            {
                BitProfile* bf = &arrBitProfile[bpfSize];
                for (int i = 0; i < 256; i++)
                {
                    bf->Bits[i] = CostCoefficients.Current.MultiArrayIncompressibleThreshold;
                }
                bpfSize++;
            }

            int bpfSizeRounded8 = (bpfSize + 7) & ~7;
            ushort* udat = (ushort*)NativeMemory.AllocZeroed(
                (nuint)(bpfSizeRounded8 * 256 * sizeof(ushort)));

            for (int i = 0; i < 256; i++)
            {
                for (int j = 0; j < bpfSize; j++)
                {
                    udat[i * bpfSizeRounded8 + j] = arrBitProfile[j].Bits[i];
                }
                for (int j = bpfSize; j < bpfSizeRounded8; j++)
                {
                    udat[i * bpfSizeRounded8 + j] = 14 * 256;
                }
            }

            // Reset histograms for re-accumulation
            arrHistoCount = bpfSize;
            for (int i = 0; i < bpfSize; i++)
            {
                Unsafe.InitBlockUnaligned(&arrHisto[i], 0, (uint)sizeof(HistoAndCount));
            }
            int breakCount = 0;

            for (int i = 0; i < arrayCount; i++)
            {
                int rangeLen = arrayLens[i];
                byte* rangePtr = arrayData[i];
                byte* rangePtrEnd = rangePtr + rangeLen;

                if (rangeLen == 0)
                {
                    if (iteration == 2)
                    {
                        pickedRangeCounts[i] = 0;
                    }
                    continue;
                }

                // Initialize first byte
                int bestIdxLocal = -1;
                ushort bestScoreLocal = 0x7fff;

                uint c = *rangePtr;
                for (int j = 0; j < bpfSize; j++)
                {
                    intervalScores[j] = udat[bpfSizeRounded8 * c + j];
                    if (intervalScores[j] < bestScoreLocal)
                    {
                        bestScoreLocal = intervalScores[j];
                        bestIdxLocal = j;
                    }
                }
                for (int j = bpfSize; j < bpfSizeRounded8; j++)
                {
                    intervalScores[j] = 14 * 256;
                }

                arrBreaks[0] = 0;
                arrBestIndex[0] = (byte)bestIdxLocal;

                EncodeAdvMultiArray_BuildTable(arrBreaks + 1, arrBestIndex + 1,
                                              rangePtr + 1, rangePtrEnd,
                                              intervalScores, udat,
                                              bpfSize, bpfSizeRounded8,
                                              bestScoreLocal, costThres);
                breakCount++;

                if (iteration == 2)
                {
                    // Final pass: record picked ranges
                    int rangeOffset = 0;
                    for (int q = 0; q < i; q++)
                    {
                        rangeOffset += pickedRangeCounts[q];
                    }

                    int bestBitIdx = arrBestIndex[rangeLen - 1];
                    ulong mask = 1ul << bestBitIdx;
                    int lastCharIdx = rangeLen;

                    // Reuse pre-allocated tempRanges buffer
                    int tempCount = 0;

                    for (int charIdx = rangeLen - 1; charIdx >= 0; charIdx--)
                    {
                        if ((arrBreaks[charIdx] & mask) != 0)
                        {
                            tempRanges[tempCount++] = new ArrRange(charIdx, lastCharIdx - charIdx, bestBitIdx);
                            lastCharIdx = charIdx;
                            bestBitIdx = arrBestIndex[charIdx - 1];
                            mask = 1ul << bestBitIdx;
                            breakCount++;
                        }
                    }
                    tempRanges[tempCount++] = new ArrRange(0, lastCharIdx, bestBitIdx);

                    // Reverse into picked ranges
                    pickedRangeCounts[i] = tempCount;
                    if (rangeOffset + tempCount > maxTotalRanges)
                    {
                        // Range count exceeded buffer capacity — fail encoding
                        NativeMemory.Free(udat);
                        result = -1;
                        return result;
                    }
                    for (int ri = 0; ri < tempCount; ri++)
                    {
                        pickedRanges[rangeOffset + ri] = tempRanges[tempCount - 1 - ri];
                    }
                }
                else
                {
                    // Iteration 0 or 1: accumulate histograms
                    int bestBitIdx = arrBestIndex[rangeLen - 1];
                    ulong mask = 1ul << bestBitIdx;
                    for (int charIdx = rangeLen - 1; charIdx >= 0; charIdx--)
                    {
                        arrHisto[bestBitIdx].Histo.Count[rangePtr[charIdx]]++;
                        arrHisto[bestBitIdx].Sum++;
                        if ((arrBreaks[charIdx] & mask) != 0)
                        {
                            bestBitIdx = arrBestIndex[charIdx - 1];
                            mask = 1ul << bestBitIdx;
                            breakCount++;
                        }
                    }
                }
            }

            NativeMemory.Free(udat);

            if (iteration == 2)
            {
                break;
            }

            // Remove empty histograms
            int d = 0;
            for (int i = 0; i < arrHistoCount; i++)
            {
                if (arrHisto[i].Sum != 0)
                {
                    if (i != d)
                    {
                        arrHisto[d] = arrHisto[i];
                    }
                    d++;
                }
            }
            arrHistoCount = d;

            if (arrHistoCount == 1)
            {
                result = -1;
                return result;
            }

            // Reduce via histogram merging
            float value = CostCoefficients.Current.MultiArraySingleHuffmanApprox * speedTradeoff;  // approximate GetTime_SingleHuffman
            ReduceNumHistograms(arrHisto, ref arrHistoCount, value, 0.0f, maxArrs,
                getCostApprox, log2Table);

            if (arrHistoCount == 1)
            {
                result = -1;
                return result;
            }

            costThres = Math.Max(baseCost + (int)GetMultiarrayLog2((uint)arrHistoCount + 1) +
                                 (int)GetMultiarrayLog2((uint)((totalInputBytes + breakCount - 1) / breakCount + 1)),
                                 14 * 256);
        }

        // Final encoding phase
        {
            // Sort histograms by usage count
            IndexCount* indexCount = stackalloc IndexCount[63];
            Unsafe.InitBlockUnaligned(indexCount, 0, (uint)(63 * sizeof(IndexCount)));
            for (int i = 0; i < bpfSize; i++)
            {
                indexCount[i].Index = i;
            }

            int totalIndexes = 0;
            for (int i = 0; i < arrayCount; i++)
            {
                totalIndexes += pickedRangeCounts[i];
            }

            int rangeOff = 0;
            for (int i = 0; i < arrayCount; i++)
            {
                for (int j = 0; j < pickedRangeCounts[i]; j++)
                {
                    Debug.Assert(rangeOff + j < maxTotalRanges);
                    indexCount[pickedRanges[rangeOff + j].BestHisto].Count++;
                }
                rangeOff += pickedRangeCounts[i];
            }
            SortIndexCountDescending(indexCount, bpfSize);

            int* ranks = stackalloc int[64];
            for (int i = 0; i < bpfSize; i++)
            {
                ranks[indexCount[i].Index] = i;
            }

            while (bpfSize > 0 && indexCount[bpfSize - 1].Count == 0)
            {
                bpfSize--;
            }

            if (bpfSize <= 1)
            {
                result = -1;
                return result;
            }

            // Allocate temp output buffer
            byte* tempOutput = (byte*)NativeMemory.Alloc((nuint)(totalInputBytes + 32));
            try
            {
            byte* tempDst = tempOutput;
            byte* tempDstEnd = tempDst + totalInputBytes + 32;

            int optsMod = opts & ~(int)EntropyOptions.AllowMultiArray;

            *tempDst++ = (byte)(bpfSize + 0x80);

            float costTotal = 1.0f;

            // Encode each histogram's data
            for (int hi = 0; hi < bpfSize; hi++)
            {
                // Gather all data for this histogram rank
                int gatherSize = 0;
                rangeOff = 0;
                for (int i = 0; i < arrayCount; i++)
                {
                    for (int j = 0; j < pickedRangeCounts[i]; j++)
                    {
                        Debug.Assert(rangeOff + j < maxTotalRanges);
                        if (ranks[pickedRanges[rangeOff + j].BestHisto] == hi)
                        {
                            gatherSize += pickedRanges[rangeOff + j].CharCount;
                        }
                    }
                    rangeOff += pickedRangeCounts[i];
                }

                byte* gatherBuf = (byte*)NativeMemory.Alloc((nuint)Math.Max(gatherSize, 1));
                try
                {
                byte* gp = gatherBuf;
                rangeOff = 0;
                for (int i = 0; i < arrayCount; i++)
                {
                    for (int j = 0; j < pickedRangeCounts[i]; j++)
                    {
                        Debug.Assert(rangeOff + j < maxTotalRanges);
                        if (ranks[pickedRanges[rangeOff + j].BestHisto] == hi)
                        {
                            int cc = pickedRanges[rangeOff + j].CharCount;
                            int ci = pickedRanges[rangeOff + j].CharIdx;
                            Buffer.MemoryCopy(arrayData[i] + ci, gp, cc, cc);
                            gp += cc;
                        }
                    }
                    rangeOff += pickedRangeCounts[i];
                }

                float curCost = StreamLZConstants.InvalidCost;
                int outLen = encodeArray(tempDst, tempDstEnd, gatherBuf, gatherSize,
                                         optsMod, speedTradeoff, &curCost, level, null);

                if (outLen < 0)
                {
                    result = -1;
                    return result;
                }
                tempDst += outLen;
                costTotal += curCost;
                if (costTotal >= *costPtr)
                {
                    result = -1;
                    return result;
                }
                }
                finally
                {
                    NativeMemory.Free(gatherBuf);
                }
            }

            // Write varbits length placeholder
            byte* varbitsLenPtr = tempDst;
            tempDst += 2;
            costTotal += 2.0f;

            if (6 * (arrayCount + totalIndexes) >= 0xc000)
            {
                result = -1;
                return result;
            }

            // Build interval index and length arrays
            int indexArraySize = arrayCount + totalIndexes;
            byte* arrIntervalIndexes = (byte*)NativeMemory.AllocZeroed((nuint)indexArraySize);
            byte* arrIntervalLenlog2 = (byte*)NativeMemory.AllocZeroed((nuint)totalIndexes);
            byte* arrayIndexesCombined = (byte*)NativeMemory.AllocZeroed((nuint)indexArraySize);
            try
            {
            int maxIntervalLenlog2 = 0;
            int totalLenlog2Bits = 0;

            int iiIdx = 0, ilIdx = 0, aicIdx = 0;
            rangeOff = 0;
            for (int arri = 0; arri < arrayCount; arri++)
            {
                for (int pri = 0; pri < pickedRangeCounts[arri]; pri++)
                {
                    ref ArrRange pr = ref pickedRanges[rangeOff + pri];
                    int intervalIndex = ranks[pr.BestHisto] + 1;
                    arrIntervalIndexes[iiIdx++] = (byte)intervalIndex;
                    int intervalLenlog2 = BitOperations.Log2((uint)pr.CharCount);
                    arrIntervalLenlog2[ilIdx++] = (byte)intervalLenlog2;
                    totalLenlog2Bits += intervalLenlog2;
                    maxIntervalLenlog2 = Math.Max(maxIntervalLenlog2, intervalLenlog2);
                    arrayIndexesCombined[aicIdx++] = (byte)(intervalIndex + intervalLenlog2 * 16);
                }
                arrIntervalIndexes[iiIdx++] = 0;
                arrayIndexesCombined[aicIdx++] = 0;
                rangeOff += pickedRangeCounts[arri];
            }

            byte* dstBase = tempDst;

            float curCost1 = StreamLZConstants.InvalidCost;
            int encSiz1 = encodeArray(tempDst, tempDstEnd, arrIntervalIndexes, iiIdx,
                                      optsMod, speedTradeoff, &curCost1, level, null);
            if (encSiz1 < 0)
            {
                result = -1;
                return result;
            }
            tempDst += encSiz1;

            float curCost2 = StreamLZConstants.InvalidCost;
            int encSiz2 = encodeArray(tempDst, tempDstEnd, arrIntervalLenlog2, ilIdx,
                                      optsMod, speedTradeoff, &curCost2, level, null);
            if (encSiz2 < 0)
            {
                result = -1;
                return result;
            }
            tempDst += encSiz2;

            bool uses4BitIndex = false;
            float curCost3 = curCost1 + curCost2;

            if (bpfSize <= 15 && maxIntervalLenlog2 <= 15)
            {
                int encSiz3 = encodeArray(dstBase, tempDstEnd, arrayIndexesCombined, aicIdx,
                                          optsMod, speedTradeoff, &curCost3, level, null);
                if (encSiz3 >= 0)
                {
                    tempDst = dstBase + encSiz3;
                    uses4BitIndex = true;
                }
            }
            costTotal += curCost3;

            int lengthOfVarbitsInBytes = 16 + BitsUp(totalLenlog2Bits);

            if (lengthOfVarbitsInBytes + costTotal >= *costPtr || lengthOfVarbitsInBytes > tempDstEnd - tempDst)
            {
                result = -1;
                return result;
            }

            // Write variable-length interval bits (forward/backward interleaved)
            BitWriter64Forward bitsf = new(tempDst);
            BitWriter64Backward bitsb = new(tempDstEnd);

            int flag = 0;
            rangeOff = 0;
            for (int arri = 0; arri < arrayCount; arri++)
            {
                for (int pri = 0; pri < pickedRangeCounts[arri]; pri++)
                {
                    ref ArrRange pa = ref pickedRanges[rangeOff + pri];
                    int intervalLenlog2 = BitOperations.Log2((uint)pa.CharCount);
                    uint v = (uint)pa.CharCount & ((1u << intervalLenlog2) - 1);
                    if (flag == 0)
                    {
                        bitsf.Write(v, intervalLenlog2);
                    }
                    else
                    {
                        bitsb.Write(v, intervalLenlog2);
                    }
                    flag ^= 1;
                }
                if (uses4BitIndex)
                {
                    flag ^= 1;
                }
                rangeOff += pickedRangeCounts[arri];
            }

            long forwardBytes = bitsf.GetFinalPtr() - tempDst;
            long backwardBytes = tempDstEnd - bitsb.GetFinalPtr();
            long allBytes = forwardBytes + backwardBytes;

            // Move backward data next to forward data
            Buffer.MemoryCopy(tempDstEnd - backwardBytes, tempDst + forwardBytes, backwardBytes, backwardBytes);

            *(ushort*)varbitsLenPtr = (ushort)(allBytes + (uses4BitIndex ? 0x8000 : 0));

            costTotal += (totalIndexes * CostCoefficients.Current.MultiArrayPerIndex + totalInputBytes * CostCoefficients.Current.MultiArrayPerInputByte) * speedTradeoff + allBytes;
            if (costTotal >= *costPtr)
            {
                result = -1;
                return result;
            }

            long rv = tempDst - tempOutput + allBytes;
            if (rv > dstEnd - dst)
            {
                result = -1;
                return result;
            }

            *costPtr = costTotal;
            Buffer.MemoryCopy(tempOutput, dst, rv, rv);
            result = (int)rv;
            }
            finally
            {
                NativeMemory.Free(arrIntervalIndexes);
                NativeMemory.Free(arrIntervalLenlog2);
                NativeMemory.Free(arrayIndexesCombined);
            }
            }
            finally
            {
                NativeMemory.Free(tempOutput);
            }
        }

        return result;
        }
        finally
        {
            NativeMemory.Free(tempRangesHeap);
            NativeMemory.Free(arrBreaks);
            NativeMemory.Free(arrBestIndex);
            NativeMemory.Free(pickedRanges);
            NativeMemory.Free(pickedRangeOffsets);
            NativeMemory.Free(pickedRangeCounts);
            NativeMemory.Free(arrHisto);
            NativeMemory.Free(arrBitProfile);
        }
    }

    #endregion

    #region EncodeMultiArray_Short

    /// <summary>
    /// Short multi-array encoder for small inputs (&lt; 1536 bytes).
    /// Finds the best binary split point, fine-tunes the boundary, then encodes both halves.
    /// </summary>
    [SkipLocalsInit]
    private static int EncodeMultiArray_Short(byte* dst, byte* dstEnd, byte* src, int srcSize,
                                              ByteHistogram* histo, int level, int opts,
                                              float speedTradeoff,
                                              float maxAllowedCost, float* costPtr,
                                              EncodeArrayFunc encodeArray,
                                              GetCostFunc getCostSingleHuffman,
                                              uint* log2Table)
    {
        float bestCost = StreamLZConstants.InvalidCost;  // Will be set by caller's cost function
        ByteHistogram histoL, histoR;
        ByteHistogram* bestHisto = stackalloc ByteHistogram[2];
        int bestSplit = 0;

        int nLoops = Math.Max(Math.Min((srcSize + 128) >> 8, 8), 1);
        for (int i = 0; i < nLoops; i++)
        {
            int splitPos = srcSize * (i + 1) / (nLoops + 1);
            CountBytesHistogram(src, splitPos, &histoL);
            SubtractHisto(&histoR, histo, &histoL);

            // Estimate cost for two halves (using approximate cost)
            float costL = (float)getCostSingleHuffman(&histoL, splitPos);
            float costR = (float)getCostSingleHuffman(&histoR, srcSize - splitPos);
            float cost = costL + costR + 6;

            if (cost < bestCost)
            {
                bestCost = cost;
                bestSplit = splitPos;
                bestHisto[0] = histoL;
                bestHisto[1] = histoR;
            }
        }
        if (bestSplit == 0)
        {
            return -1;
        }

        // Fine-tune split boundary
        int finetuneSize = 64;
        uint sizeL = (uint)bestSplit, sizeR = (uint)(srcSize - bestSplit);
        do
        {
            while (sizeR >= 2 * (uint)finetuneSize)
            {
                byte* p = &src[sizeL];
                if (GetBetterHisto(p, finetuneSize, &bestHisto[0], sizeL, &bestHisto[1], sizeR, log2Table) > 0)
                {
                    break;
                }
                sizeL += (uint)finetuneSize;
                sizeR -= (uint)finetuneSize;
                MoveBytesBetweenHistos(p, finetuneSize, &bestHisto[1], &bestHisto[0]);
            }

            while (sizeL >= 2 * (uint)finetuneSize)
            {
                byte* p = &src[sizeL - (uint)finetuneSize];
                if (GetBetterHisto(p, finetuneSize, &bestHisto[1], sizeR, &bestHisto[0], sizeL, log2Table) > 0)
                {
                    break;
                }
                sizeL -= (uint)finetuneSize;
                sizeR += (uint)finetuneSize;
                MoveBytesBetweenHistos(p, finetuneSize, &bestHisto[0], &bestHisto[1]);
            }
            finetuneSize >>= 2;
        } while (finetuneSize >= 16);

        uint* sizes = stackalloc uint[2];
        uint* offsets = stackalloc uint[2];
        sizes[0] = sizeL;
        sizes[1] = sizeR;
        offsets[0] = 0;
        offsets[1] = sizeL;
        OptimizeSplitBoundaries(src, src + srcSize, bestHisto, sizes, offsets, 2);

        if (sizes[0] < 32 || sizes[1] < 32)
        {
            return -1;
        }

        byte* temp = (byte*)NativeMemory.Alloc((nuint)srcSize);
        try
        {
            *temp = 2;
            int optsMod = opts & ~(int)EntropyOptions.AllowMultiArray;
            int resultVal = -1;

            float cost1 = StreamLZConstants.InvalidCost;
            int n1 = encodeArray(temp + 1, &temp[srcSize], src, (int)sizes[0],
                                 optsMod, speedTradeoff, &cost1, level, null);
            if (n1 >= 0)
            {
                byte* tmpDst = temp + 1 + n1;
                float cost2 = StreamLZConstants.InvalidCost;
                int n2 = encodeArray(tmpDst, &temp[srcSize], src + sizes[0], (int)sizes[1],
                                     optsMod, speedTradeoff, &cost2, level, null);
                if (n2 >= 0)
                {
                    float cost = cost1 + cost2 + 6;
                    int totalBytes = (int)(tmpDst + n2 - temp);
                    if (cost < maxAllowedCost && totalBytes <= dstEnd - dst)
                    {
                        resultVal = totalBytes;
                        *costPtr = cost;
                        Buffer.MemoryCopy(temp, dst, totalBytes, totalBytes);
                    }
                }
            }

            return resultVal;
        }
        finally
        {
            NativeMemory.Free(temp);
        }
    }

    #endregion

    #region EncodeMultiArray_Long

    /// <summary>
    /// Long multi-array encoder for large inputs (>= 1536 bytes).
    /// Splits input into many blocks, optimizes boundaries via heap-based greedy merging,
    /// then merges adjacent blocks when beneficial.
    /// </summary>
    [SkipLocalsInit]
    private static int EncodeMultiArray_Long(byte* dst, byte* dstEnd, byte* src, int srcSize,
                                             ByteHistogram* histo, int level, int opts,
                                             float speedTradeoff,
                                             float maxAllowedCost, float* costPtr,
                                             EncodeArrayFunc encodeArray,
                                             GetCostFunc getCostSingleHuffman,
                                             uint* log2Table)
    {
        int numBlksBase = (level == 9) ? 62 : Math.Max(Math.Min(1 << level, 32), 8);
        int numBlks = Math.Max(Math.Min(numBlksBase, (srcSize + 256) >> 9), 3);
        ByteHistogram* histos = (ByteHistogram*)NativeMemory.AllocZeroed((nuint)(numBlks * sizeof(ByteHistogram)));
        MultiHistCandi* mhs = null;

        try
        {

        int bytesPerBlk = srcSize / numBlks;
        uint* chunkPos = stackalloc uint[64];
        uint* chunkSize = stackalloc uint[64];

        for (int i = 0, pos = 0; i < numBlks; i++, pos += bytesPerBlk)
        {
            int size = (i == numBlks - 1) ? srcSize - pos : bytesPerBlk;
            chunkPos[i] = (uint)pos;
            chunkSize[i] = (uint)size;
            CountBytesHistogram(src + pos, size, &histos[i]);
        }

        int mhsCapacity = numBlks * 3;
        mhs = (MultiHistCandi*)NativeMemory.Alloc((nuint)(mhsCapacity * sizeof(MultiHistCandi)));

        int tune = 64;
        do
        {
            int numMhs = 0;
            for (int i = 0; i < numBlks; i++)
            {
                MultiArrayAddCandidate(i, numBlks, histos, chunkSize, chunkPos, mhs, &numMhs, src, tune, 0, log2Table);
            }

            MaxHeap<MultiHistCandi>.MakeHeap(mhs, mhs + numMhs);

            int maxLoops = numBlks * 2;

            while (numMhs > 0)
            {
                MultiHistCandi cur = *mhs;
                MaxHeap<MultiHistCandi>.PopHeap(mhs, mhs + numMhs--);

                int idx = cur.Idx;
                uint pos = chunkPos[idx];
                uint size = chunkSize[idx];
                int dir = cur.ExtendDirection != 0 ? 1 : -1;

                if (cur.SizeAndOffs != (size | ((ulong)pos << 32)) ||
                    cur.SizeAndOffsOther != (chunkSize[idx + dir] | ((ulong)chunkPos[idx + dir] << 32)))
                    continue;

                if (cur.ExtendDirection != 0)
                {
                    MoveBytesBetweenHistos(&src[pos + size], tune, &histos[idx + 1], &histos[idx]);
                    chunkSize[idx] += (uint)tune;
                    chunkSize[idx + 1] -= (uint)tune;
                    chunkPos[idx + 1] += (uint)tune;
                }
                else
                {
                    MoveBytesBetweenHistos(&src[pos - (uint)tune], tune, &histos[idx - 1], &histos[idx]);
                    chunkSize[idx] += (uint)tune;
                    chunkPos[idx] -= (uint)tune;
                    chunkSize[idx - 1] -= (uint)tune;
                }

                if (maxLoops-- == 0)
                {
                    break;
                }

                if (numMhs + 4 >= mhsCapacity)
                {
                    MultiArrayDeleteJunk(mhs, &numMhs, chunkSize, chunkPos);
                    MaxHeap<MultiHistCandi>.MakeHeap(mhs, mhs + numMhs);
                }

                int numMhsOrg = numMhs;
                MultiArrayAddCandidate(idx, numBlks, histos, chunkSize, chunkPos, mhs, &numMhs, src, tune, 0, log2Table);
                MultiArrayAddCandidate(idx + dir, numBlks, histos, chunkSize, chunkPos, mhs, &numMhs, src, tune, dir, log2Table);
                while (numMhsOrg < numMhs)
                {
                    MaxHeap<MultiHistCandi>.PushHeap(mhs, mhs + ++numMhsOrg);
                }
            }
            tune >>= 2;
        } while (tune >= 16);

        OptimizeSplitBoundaries(src, src + srcSize, histos, chunkSize, chunkPos, numBlks);

        // Greedy merge of adjacent blocks
        ByteHistogram tmpHist;
        float* scores = stackalloc float[64];

        MergeEntry* ents = stackalloc MergeEntry[63];
        MergeEntry* entsEnd = ents;
        MergeEntry* bestEnt = null;
        float bestScoreF = 0.0f;

        int prevI = -1;
        for (int i = 0; i < numBlks; i++)
        {
            int size = (int)chunkSize[i];
            if (size == 0)
            {
                continue;
            }

            scores[i] = (float)getCostSingleHuffman(&histos[i], size);

            if (prevI >= 0)
            {
                AddHistogram(&tmpHist, &histos[i], &histos[prevI]);
                float cost2 = (float)getCostSingleHuffman(&tmpHist, size + (int)chunkSize[prevI]);
                float diff = scores[i] + scores[prevI] - cost2;
                if (diff > 0.0f)
                {
                    entsEnd->Diff = diff;
                    entsEnd->CombinedCost = cost2;
                    entsEnd->Left = prevI;
                    entsEnd->Right = i;
                    if (diff > bestScoreF)
                    {
                        bestScoreF = diff;
                        bestEnt = entsEnd;
                    }
                    entsEnd++;
                }
            }
            prevI = i;
        }

        while (entsEnd != ents)
        {
            MergeEntry e = *bestEnt;
            *bestEnt = *--entsEnd;
            bestEnt = null;
            bestScoreF = 0;

            AddHistogram(&histos[e.Left], &histos[e.Left], &histos[e.Right]);
            chunkSize[e.Left] += chunkSize[e.Right];
            scores[e.Left] = e.CombinedCost;
            chunkPos[e.Right] = 0;
            chunkSize[e.Right] = 0;
            scores[e.Right] = 0;

            for (MergeEntry* ep = entsEnd; ep-- != ents;)
            {
                if (ep->Right == e.Left || ep->Left == e.Right)
                {
                    *ep = *--entsEnd;
                    if (bestEnt == entsEnd)
                    {
                        bestEnt = ep;
                    }
                }
                else if (ep->Diff > bestScoreF)
                {
                    bestScoreF = ep->Diff;
                    bestEnt = ep;
                }
            }

            // Insert new connections
            int left = e.Left;
            do left--; while (left >= 0 && chunkSize[left] == 0);
            if (left >= 0)
            {
                AddHistogram(&tmpHist, &histos[e.Left], &histos[left]);
                float cost2 = (float)getCostSingleHuffman(&tmpHist, (int)(chunkSize[e.Left] + chunkSize[left]));
                float diff = scores[e.Left] + scores[left] - cost2;
                if (diff > 0.0f)
                {
                    entsEnd->Diff = diff;
                    entsEnd->CombinedCost = cost2;
                    entsEnd->Left = left;
                    entsEnd->Right = e.Left;
                    if (diff > bestScoreF) { bestScoreF = diff; bestEnt = entsEnd; }
                    entsEnd++;
                }
            }

            int right = e.Right;
            do right++; while (right < numBlks && chunkSize[right] == 0);
            if (right < numBlks)
            {
                AddHistogram(&tmpHist, &histos[e.Left], &histos[right]);
                float cost2 = (float)getCostSingleHuffman(&tmpHist, (int)(chunkSize[e.Left] + chunkSize[right]));
                float diff = scores[e.Left] + scores[right] - cost2;
                if (diff > 0.0f)
                {
                    entsEnd->Diff = diff;
                    entsEnd->CombinedCost = cost2;
                    entsEnd->Left = e.Left;
                    entsEnd->Right = right;
                    if (diff > bestScoreF) { bestScoreF = diff; bestEnt = entsEnd; }
                    entsEnd++;
                }
            }
        }

        // Count remaining non-empty blocks
        int j = 0;
        for (int i = 0; i < numBlks; i++)
        {
            j += (chunkSize[i] != 0) ? 1 : 0;
        }

        int retval = -1;
        if (j != 1)
        {
            byte* tmpStart = (byte*)NativeMemory.Alloc((nuint)srcSize);
            try
            {
                byte* tmpEnd = tmpStart + srcSize;
                byte* tmp = tmpStart;

                *tmp++ = (byte)j;
                float cost = 6;

                bool failed = false;
                for (int i = 0; i < numBlks && !failed; i++)
                {
                    if (chunkSize[i] != 0)
                    {
                        float curCost = StreamLZConstants.InvalidCost;
                        int n = encodeArray(tmp, tmpEnd, src + chunkPos[i], (int)chunkSize[i],
                                            opts & ~(int)EntropyOptions.AllowMultiArray,
                                            speedTradeoff, &curCost, level, null);
                        if (n < 0)
                        {
                            failed = true;
                        }
                        else
                        {
                            tmp += n;
                            cost += curCost;
                        }
                    }
                }

                if (!failed && cost < maxAllowedCost && tmp - tmpStart <= dstEnd - dst)
                {
                    *costPtr = cost;
                    retval = (int)(tmp - tmpStart);
                    Buffer.MemoryCopy(tmpStart, dst, retval, retval);
                }
            }
            finally
            {
                NativeMemory.Free(tmpStart);
            }
        }

        return retval;

        }
        finally
        {
            NativeMemory.Free(mhs);
            NativeMemory.Free(histos);
        }
    }

    #endregion

    #region EncodeArrayU8_MultiArray

    /// <summary>
    /// Main entry point for multi-array encoding of a single byte array.
    /// Dispatches to short or long encoder based on size, then optionally tries advanced encoding.
    /// </summary>
    /// <param name="dst">Destination buffer.</param>
    /// <param name="dstEnd">End of destination buffer.</param>
    /// <param name="src">Source bytes.</param>
    /// <param name="srcSize">Source size.</param>
    /// <param name="histo">Pre-computed histogram of source bytes.</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="opts">Encoding option flags.</param>
    /// <param name="speedTradeoff">Speed vs compression tradeoff.</param>
        /// <param name="costThres">Cost threshold — do not exceed this.</param>
    /// <param name="costPtr">In/out: best cost achieved.</param>
    /// <param name="encodeArray">Delegate for sub-array encoding.</param>
    /// <param name="getCostSingleHuffman">Single Huffman cost estimator.</param>
    /// <param name="getCostApprox">Approximate histogram cost function.</param>
    /// <param name="log2Table">Pointer to Log2LookupTable[4097].</param>
    /// <returns>Compressed size in bytes, or -1 on failure.</returns>
    [SkipLocalsInit]
    public static int EncodeArrayU8_MultiArray(byte* dst, byte* dstEnd,
                                               byte* src, int srcSize,
                                               ByteHistogram* histo, int level, int opts,
                                               float speedTradeoff,
                                               float costThres, float* costPtr,
                                               EncodeArrayFunc encodeArray,
                                               GetCostFunc getCostSingleHuffman,
                                               GetCostFunc getCostApprox,
                                               uint* log2Table)
    {
        if (srcSize < 96)
        {
            return -1;
        }

        int n;
        if (srcSize < 1536)
        {
            n = EncodeMultiArray_Short(dst, dstEnd, src, srcSize, histo, level, opts,
                                       speedTradeoff, costThres, costPtr,
                                       encodeArray, getCostSingleHuffman, log2Table);
        }
        else
        {
            n = EncodeMultiArray_Long(dst, dstEnd, src, srcSize, histo, level, opts,
                                      speedTradeoff, costThres, costPtr,
                                      encodeArray, getCostSingleHuffman, log2Table);
        }

        if ((opts & (int)EntropyOptions.AllowMultiArrayAdvanced) != 0)
        {
            float cost = Math.Min(costThres, *costPtr) - 5;
            int nadv = EncodeAdvMultiArray(dst, dstEnd, &src, &srcSize, 1,
                                           opts, speedTradeoff, &cost, level,
                                           encodeArray, getCostApprox, log2Table);
            if (nadv > 0)
            {
                *costPtr = cost + 5;
                return nadv;
            }
        }
        return n;
    }

    #endregion
}
