// MatchFinder.cs -- Hash-based match finding for LZ compression.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Compression.MatchFinding;

// NOTE: LengthAndOffset is defined in LzMatch.cs (Compression namespace).
// NOTE: HashPos is defined in LzMatch.cs (Compression namespace).
// NOTE: ManagedMatchLenStorage is defined in ManagedMatchLenStorage.cs (same namespace).

// ────────────────────────────────────────────────────────────────
//  MatchFinder — static methods for hash-based match finding
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Contains static methods for hash-based match finding.
/// </summary>
internal static class MatchFinder
{
    // ────────────────────────────────────────────────────────────
    //  Variable-length encoding helpers
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Writes a variable-length encoded value using a split high/low scheme.
    /// The value is encoded as a sequence of "spill" bytes followed by a terminator byte.
    /// Each spill byte carries <paramref name="a"/> low bits of the remaining value
    /// (the low part), and the threshold <c>256 - (1 &lt;&lt; a)</c> values are reserved
    /// for terminators. The loop subtracts the threshold, writes the low
    /// <paramref name="a"/> bits, then right-shifts. When the remaining value fits
    /// below the threshold, it is written as a final byte offset by <c>(1 &lt;&lt; a)</c>,
    /// signalling the end of the sequence (the high part, encoded in unary by the
    /// number of spill bytes emitted).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int VarLenWriteSpill(byte[] dst, int dstPos, uint value, int a)
    {
        uint shifted = 1u << a;
        uint thres = 256u - shifted;
        while (value >= thres)
        {
            value -= thres;
            dst[dstPos++] = (byte)(value & (shifted - 1));
            value >>= a;
        }
        dst[dstPos++] = (byte)(value + shifted);
        return dstPos;
    }

    /// <summary>
    /// Writes a variable-length encoded offset value. Small offsets (below
    /// <c>65536 - (1 &lt;&lt; a)</c>) are written directly as two big-endian bytes.
    /// Larger offsets write the low <paramref name="a"/> bits as a 2-byte base,
    /// then delegate the remaining high bits to <see cref="VarLenWriteSpill"/>
    /// with precision parameter <paramref name="b"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int VarLenWriteOffset(byte[] dst, int dstPos, uint value, int a, int b)
    {
        uint shifted = 1u << a;
        uint thres = 65536u - shifted;
        if (value >= thres)
        {
            uint v = (value - thres) & (shifted - 1);
            dst[dstPos++] = (byte)(v >> 8);
            dst[dstPos++] = (byte)v;
            return VarLenWriteSpill(dst, dstPos, (value - thres) >> a, b);
        }
        else
        {
            uint v = value + shifted;
            dst[dstPos++] = (byte)(v >> 8);
            dst[dstPos++] = (byte)v;
            return dstPos;
        }
    }

    /// <summary>
    /// Writes a variable-length encoded length value. Small lengths (below
    /// <c>256 - (1 &lt;&lt; a)</c>) are written as a single byte. Larger lengths
    /// write the low <paramref name="a"/> bits as a 1-byte base, then delegate
    /// the remaining high bits to <see cref="VarLenWriteSpill"/> with precision
    /// parameter <paramref name="b"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int VarLenWriteLength(byte[] dst, int dstPos, uint value, int a, int b)
    {
        uint shifted = 1u << a;
        uint thres = 256u - shifted;
        if (value >= thres)
        {
            uint v = (value - thres) & (shifted - 1);
            dst[dstPos++] = (byte)v;
            return VarLenWriteSpill(dst, dstPos, (value - thres) >> a, b);
        }
        else
        {
            uint v = value + shifted;
            dst[dstPos++] = (byte)v;
            return dstPos;
        }
    }

    // ────────────────────────────────────────────────────────────
    //  MatchLenStorage insertion
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Inserts one or more matches into the <see cref="ManagedMatchLenStorage"/>
    /// at the given source offset.
    /// </summary>
    public static void InsertMatches(ManagedMatchLenStorage mls, int atOffset, Span<LengthAndOffset> lao, int numLao)
    {
        if (numLao == 0)
        {
            return;
        }

        mls.Offset2Pos[atOffset] = mls.ByteBufferUse;

        int neededBytes = mls.ByteBufferUse + 16 * numLao + 2;
        if (neededBytes >= mls.ByteBuffer.Length)
        {
            int newSize = Math.Max(neededBytes, mls.ByteBuffer.Length + (mls.ByteBuffer.Length >> 2));
            Array.Resize(ref mls.ByteBuffer, newSize);
        }

        int pos = mls.ByteBufferUse;
        byte[] buf = mls.ByteBuffer;

        for (int i = 0; i < numLao && lao[i].Length != 0; i++)
        {
            Debug.Assert(lao[i].Offset != 0);
            pos = VarLenWriteLength(buf, pos, (uint)lao[i].Length, 1, 3);
            pos = VarLenWriteOffset(buf, pos, (uint)lao[i].Offset, 13, 7);
        }
        pos = VarLenWriteLength(buf, pos, 0, 1, 3);

        mls.ByteBufferUse = pos;
    }
    // ────────────────────────────────────────────────────────────
    //  RemoveIdentical — dedup matches with the same length
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Removes entries with duplicate lengths from a sorted match array.
    /// </summary>
    private static int RemoveIdentical(Span<LengthAndOffset> matches, int count)
    {
        Debug.Assert(count > 0);
        int p = 0;
        // Skip until we find the first duplicate
        while (p < count - 1 && matches[p].Length != matches[p + 1].Length)
        {
            p++;
        }
        if (p < count - 1)
        {
            int dst = p;
            for (int r = p + 2; r < count; r++)
            {
                if (matches[dst].Length != matches[r].Length)
                {
                    matches[++dst] = matches[r];
                }
            }
            count = dst + 1;
        }
        return count;
    }

    // ────────────────────────────────────────────────────────────
    //  CountMatchingBytes
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Counts the number of matching bytes between <c>src[pos..pendIdx]</c>
    /// and <c>src[pos - offset..pendIdx - offset]</c>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int CountMatchingBytes(byte[] src, int pos, int pendIdx, int offset)
    {
        int len = 0;
        while (pendIdx - (pos + len) >= 4)
        {
            uint a = Unsafe.ReadUnaligned<uint>(ref src[pos + len]);
            uint b = Unsafe.ReadUnaligned<uint>(ref src[pos + len - offset]);
            if (a != b)
            {
                return len + (BitOperations.TrailingZeroCount(a ^ b) >> 3);
            }
            len += 4;
        }
        while (pos + len < pendIdx && src[pos + len] == src[pos + len - offset])
        {
            len++;
        }
        return len;
    }

    /// <summary>
    /// Counts matching characters from two positions until mismatch or end.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int CountMatchingCharacters(byte[] src, int srcIdx, int srcEndIdx, int matchIdx)
    {
        int sourceStart = srcIdx;
        if (srcEndIdx - srcIdx < 8)
        {
            while (srcIdx < srcEndIdx && src[srcIdx] == src[matchIdx])
            {
                srcIdx++;
                matchIdx++;
            }
            return srcIdx - sourceStart;
        }

        ulong a8 = Unsafe.ReadUnaligned<ulong>(ref src[srcIdx]);
        ulong b8 = Unsafe.ReadUnaligned<ulong>(ref src[matchIdx]);
        if (a8 != b8)
        {
            return 0;
        }
        srcIdx += 8;
        matchIdx += 8;

        while (srcEndIdx - srcIdx >= 4)
        {
            uint a = Unsafe.ReadUnaligned<uint>(ref src[srcIdx]);
            uint b = Unsafe.ReadUnaligned<uint>(ref src[matchIdx]);
            if (a != b)
            {
                return (srcIdx - sourceStart) + (BitOperations.TrailingZeroCount(a ^ b) >> 3);
            }
            srcIdx += 4;
            matchIdx += 4;
        }
        while (srcIdx < srcEndIdx && src[srcIdx] == src[matchIdx])
        {
            srcIdx++;
            matchIdx++;
        }
        return srcIdx - sourceStart;
    }
    // ────────────────────────────────────────────────────────────
    //  FindMatchesHashBased
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Finds matches using the 16-entry dual-hash table (<see cref="MatchHasher16Dual"/>).
    /// </summary>
    /// <param name="srcBase">Source data buffer.</param>
    /// <param name="srcSize">Size of the source data.</param>
    /// <param name="mls">Match storage to populate.</param>
    /// <param name="maxNumMatches">Maximum matches to keep per position.</param>
    /// <param name="preloadSize">Number of bytes already in the hash from a prior window.</param>
    // FindMatchesHashBased is the hot inner loop of the compressor. For each source position,
    // it probes a 16-entry dual-hash table for candidate matches, extends them, and stores
    // the best results. The dual-hash design (two independent 16-slot buckets per position)
    // reduces collision rates vs a single larger bucket, improving match quality at the same
    // memory cost.
    //
    // The loop is structured for throughput:
    //  - Hash computation for position curPos+1 is done BEFORE probing curPos's buckets,
    //    so the hash table loads for the next iteration can overlap with match extension work.
    //  - Prefetch for curPos+8 is issued early to warm the hash table entries 8 positions ahead.
    //  - SSE2 vectorized tag comparison checks all 16 entries in 4 rounds (4 entries each),
    //    reducing branch mispredictions vs scalar per-entry checks.
    //  - Long matches (>= 77 bytes) trigger a skip: the compressor inserts synthetic
    //    sub-matches at stride-4 positions and advances curPos past the match, avoiding
    //    redundant probing of positions that the optimal parser will never use.
    public static void FindMatchesHashBased(
        byte[] srcBase, int srcSize, ManagedMatchLenStorage mls,
        int maxNumMatches, int preloadSize)
    {
        var hasher = new MatchHasher16Dual();

        // Hash table size: 2^bits entries, clamped to [2^18, 2^24].
        // Larger tables reduce collisions but waste cache; 2^24 is the practical cap
        // (64 MB hash table at 4 bytes/entry) beyond which cache misses dominate.
        int bits = Math.Min(
            Math.Max(BitOperations.Log2((uint)Math.Max(Math.Min(srcSize, int.MaxValue), 2) - 1) + 1, 18),
            24);
        hasher.AllocateHash(bits, 0);
        hasher.SetBaseAndPreload(srcBase, 0, preloadSize, preloadSize);

        int srcOffset = preloadSize;
        hasher.SetHashPos(srcBase, srcOffset);

        int srcSafe4 = srcSize - 4;
        int srcSizeSafe = srcSize - 8;

        Span<LengthAndOffset> match = stackalloc LengthAndOffset[33];
        Span<uint> offsets = stackalloc uint[16];

        for (int curPos = preloadSize; curPos < srcSizeSafe; curPos++)
        {
            // Read the 4-byte prefix at curPos for fast rejection of hash collisions.
            uint u32ToScanFor = Unsafe.ReadUnaligned<uint>(ref srcBase[curPos]);

            // Capture this position's hash results (computed by the previous iteration's
            // SetHashPos call, or the initial call above for the first iteration).
            int cur1 = hasher.HashEntryPtrNextIndex;
            int cur2 = hasher.HashEntry2PtrNextIndex;
            uint curHashTag = hasher.CurrentHashTag;

            // Prefetch hash table entries for curPos+8: the hash computation touches two
            // cache lines (primary and dual bucket). Issuing prefetch 8 iterations ahead
            // gives the memory subsystem ~40-80 cycles to fetch before we need the data.
            if (curPos + 8 < srcSizeSafe)
            {
                hasher.SetHashPosPrefetch(srcBase, curPos + 8);
            }
            // Compute hash for curPos+1 now so its hash table entries begin loading
            // while we probe curPos's buckets below.
            hasher.SetHashPos(srcBase, curPos + 1);

            int numMatch = 0;

            uint[] hashTable = hasher.HashTable;

            // ── Probe both hash buckets for candidate matches ──
            // Two passes: primary bucket (cur1) then dual bucket (cur2). If both point
            // to the same bucket, the second pass is skipped via the break below.
            int hashCurIdx = cur1;
            for (int pass = 0; pass < 2; pass++)
            {
                int bestMl = 0;

                // SSE2 vectorized hash probe: processes 16 entries in 4 groups of 4.
                // Each hash entry stores [tag:6][position:26]. The SIMD code:
                //   1. Extracts the offset (curPos - storedPos) from the low 26 bits
                //   2. Checks the high 6-bit tag matches curHashTag
                //   3. Checks the offset is within MaxDictionarySize
                // All 16 results are packed into a single 16-bit mask via MoveMask.
                // This replaces 16 scalar branches with one bitmask + BSF loop.
                if (Sse2.IsSupported)
                {
                    unsafe
                    {
                        fixed (uint* hPtr = &hashTable[hashCurIdx])
                        fixed (uint* oPtr = offsets)
                        {
                            Vector128<int> vHashHigh = Vector128.Create((int)curHashTag);
                            Vector128<int> vMaxPos = Vector128.Create(curPos - 1);
                            Vector128<int> vMaxOffset = Vector128.Create(Math.Min(curPos, StreamLZConstants.MaxDictionarySize));
                            Vector128<int> vMask26 = Vector128.Create((int)StreamLZConstants.HashPositionMask);
                            Vector128<int> vOne = Vector128.Create(1);
                            Vector128<int> vZero = Vector128<int>.Zero;
                            Vector128<int> vHighMask = Vector128.Create(unchecked((int)StreamLZConstants.HashTagMask));

                            // All 4 rounds are unrolled rather than looped: each round loads
                            // 4 hash entries, computes offsets, and builds a match mask. Unrolling
                            // lets the CPU pipeline all 4 loads simultaneously (no loop-carried dependency).
                            Vector128<int> v0 = Sse2.LoadVector128((int*)(hPtr + 0));
                            Vector128<int> u0 = Sse2.Add(Sse2.And(Sse2.Subtract(vMaxPos, v0), vMask26), vOne);
                            Sse2.Store((int*)(oPtr + 0), u0);
                            Vector128<int> m0 = Sse2.CompareEqual(vZero,
                                Sse2.Or(Sse2.CompareGreaterThan(u0, vMaxOffset),
                                    Sse2.And(Sse2.Xor(v0, vHashHigh), vHighMask)));

                            Vector128<int> v1 = Sse2.LoadVector128((int*)(hPtr + 4));
                            Vector128<int> u1 = Sse2.Add(Sse2.And(Sse2.Subtract(vMaxPos, v1), vMask26), vOne);
                            Sse2.Store((int*)(oPtr + 4), u1);
                            Vector128<int> m1 = Sse2.CompareEqual(vZero,
                                Sse2.Or(Sse2.CompareGreaterThan(u1, vMaxOffset),
                                    Sse2.And(Sse2.Xor(v1, vHashHigh), vHighMask)));

                            Vector128<int> v2 = Sse2.LoadVector128((int*)(hPtr + 8));
                            Vector128<int> u2 = Sse2.Add(Sse2.And(Sse2.Subtract(vMaxPos, v2), vMask26), vOne);
                            Sse2.Store((int*)(oPtr + 8), u2);
                            Vector128<int> m2 = Sse2.CompareEqual(vZero,
                                Sse2.Or(Sse2.CompareGreaterThan(u2, vMaxOffset),
                                    Sse2.And(Sse2.Xor(v2, vHashHigh), vHighMask)));

                            Vector128<int> v3 = Sse2.LoadVector128((int*)(hPtr + 12));
                            Vector128<int> u3 = Sse2.Add(Sse2.And(Sse2.Subtract(vMaxPos, v3), vMask26), vOne);
                            Sse2.Store((int*)(oPtr + 12), u3);
                            Vector128<int> m3 = Sse2.CompareEqual(vZero,
                                Sse2.Or(Sse2.CompareGreaterThan(u3, vMaxOffset),
                                    Sse2.And(Sse2.Xor(v3, vHashHigh), vHighMask)));

                            // Pack 4x 32-bit masks into a 16-bit mask for BSF iteration below.
                            uint matchingOffsets = (uint)Sse2.MoveMask(
                                Sse2.PackSignedSaturate(
                                    Sse2.PackSignedSaturate(m0, m1),
                                    Sse2.PackSignedSaturate(m2, m3)).AsByte());

                            // Iterate only set bits (BSF + clear lowest): typically 0-3 candidates
                            // pass the tag+range filter, so this loop is very short.
                            while (matchingOffsets != 0)
                            {
                                int bit = BitOperations.TrailingZeroCount(matchingOffsets);
                                matchingOffsets &= matchingOffsets - 1;
                                uint offset = offsets[bit];
                                // Three-stage filter before expensive CountMatchingBytes:
                                //   1. Bounds check (curPos >= offset)
                                //   2. 4-byte prefix match (rejects ~99.6% of hash collisions)
                                //   3. Quick check at bestMl position (rejects candidates shorter
                                //      than the current best without a full scan)
                                if (curPos >= (int)offset &&
                                    Unsafe.ReadUnaligned<uint>(ref srcBase[curPos - (int)offset]) == u32ToScanFor &&
                                    (bestMl < 4 || (curPos + bestMl < srcSafe4 &&
                                     srcBase[curPos + bestMl] == srcBase[curPos + bestMl - (int)offset])))
                                {
                                    int ml = 4 + CountMatchingBytes(srcBase, curPos + 4, srcSafe4, (int)offset);
                                    if (ml > bestMl)
                                    {
                                        bestMl = ml;
                                        match[numMatch++].Set(ml, (int)offset);
                                    }
                                }
                            }
                        }
                    }
                }
                else
                {
                    // Scalar fallback
                    for (int i = 0; i < 16; i++)
                    {
                        uint entry = hashTable[hashCurIdx + i];
                        uint rawOffset = (uint)((curPos - 1 - (int)entry) & (int)StreamLZConstants.HashPositionMask) + 1;
                        bool highMatch = ((entry ^ curHashTag) & StreamLZConstants.HashTagMask) == 0;
                        bool inRange = rawOffset <= (uint)Math.Min(curPos, StreamLZConstants.MaxDictionarySize);

                        if (highMatch && inRange)
                        {
                            uint offset = rawOffset;
                            if (curPos >= (int)offset &&
                                Unsafe.ReadUnaligned<uint>(ref srcBase[curPos - (int)offset]) == u32ToScanFor &&
                                (bestMl < 4 || (curPos + bestMl < srcSafe4 &&
                                 srcBase[curPos + bestMl] == srcBase[curPos + bestMl - (int)offset])))
                            {
                                int ml = 4 + CountMatchingBytes(srcBase, curPos + 4, srcSafe4, (int)offset);
                                if (ml > bestMl)
                                {
                                    bestMl = ml;
                                    match[numMatch++].Set(ml, (int)offset);
                                }
                            }
                        }
                    }
                }

                if (hashCurIdx == cur2)
                {
                    break;
                }
                hashCurIdx = cur2;
            }

            // Insert curPos into both hash buckets AFTER probing, so we never match against ourselves.
            hasher.Insert(cur1, cur2, MatchHasherBase.MakeHashValue(curHashTag, (uint)curPos));

            if (numMatch > 0)
            {
                // Sort longest-first so the optimal parser sees the best matches first.
                // RemoveIdentical deduplicates entries with equal lengths (keeping the one
                // with the smallest offset, which is cheaper to encode).
                var matchSlice = match.Slice(0, numMatch);
                matchSlice.Sort();
                numMatch = RemoveIdentical(matchSlice, numMatch);

                int pos = curPos - preloadSize;
                InsertMatches(mls, pos, match, Math.Min(maxNumMatches, numMatch));

                int bestMlTotal = match[0].Length;

                // ── Long match skip optimization ──
                // When the best match is >= 77 bytes, the optimal parser will almost certainly
                // use it. Rather than probing every position inside the match (expensive and
                // wasteful), we insert synthetic sub-matches at stride-4 positions so the
                // parser has fallback options, then skip curPos ahead past the match.
                // InsertRange updates the hash table for skipped positions so future matches
                // can still reference bytes inside this long match.
                if (bestMlTotal >= 77)
                {
                    match[0].Length = bestMlTotal - 1;
                    Span<LengthAndOffset> singleMatch = match.Slice(0, 1);
                    InsertMatches(mls, pos + 1, singleMatch, 1);
                    for (int i = 4; i < bestMlTotal; i += 4)
                    {
                        match[0].Length = bestMlTotal - i;
                        InsertMatches(mls, pos + i, singleMatch, 1);
                    }
                    if (curPos + bestMlTotal < srcSizeSafe)
                    {
                        hasher.InsertRange(srcBase, curPos, bestMlTotal);
                    }
                    curPos += bestMlTotal - 1;
                }
            }
        }
    }

    // ────────────────────────────────────────────────────────────
    //  ExtractLaoFromMls — extract matches from compact storage
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Reads a variable-length integer from the MLS byte buffer (inner loop).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int ExtractFromMlsInner(byte[] src, ref int pos, int srcEnd, out int result, int a)
    {
        int sum = 0, bitpos = 0;
        result = 0;
        for (; ; )
        {
            if (pos >= srcEnd)
            {
                return -1;
            }
            int t = src[pos++] - (1 << a);
            if (t >= 0)
            {
                result = sum + (t << bitpos);
                return 0;
            }
            sum += (t + 256) << bitpos;
            bitpos += a;
        }
    }

    /// <summary>
    /// Reads a variable-length encoded length from the MLS byte buffer.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int ExtractLengthFromMls(byte[] src, ref int pos, int srcEnd, out int result, int a, int b)
    {
        result = 0;
        if (pos >= srcEnd)
        {
            return -1;
        }
        int t = src[pos++] - (1 << a);
        if (t < 0)
        {
            int inner;
            if (ExtractFromMlsInner(src, ref pos, srcEnd, out inner, b) < 0)
            {
                return -1;
            }
            result = t + (inner << a) + 256;
        }
        else
        {
            result = t;
        }
        return 0;
    }

    /// <summary>
    /// Reads a variable-length encoded offset from the MLS byte buffer.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int ExtractOffsetFromMls(byte[] src, ref int pos, int srcEnd, out int result, int a, int b)
    {
        result = 0;
        if (srcEnd - pos < 2)
        {
            return -1;
        }
        int t = (src[pos] << 8 | src[pos + 1]) - (1 << a);
        pos += 2;
        if (t < 0)
        {
            int inner;
            if (ExtractFromMlsInner(src, ref pos, srcEnd, out inner, b) < 0)
            {
                return -1;
            }
            result = t + (inner << a) + 65536;
        }
        else
        {
            result = t;
        }
        return 0;
    }

    /// <summary>
    /// Extracts <see cref="LengthAndOffset"/> arrays from a <see cref="ManagedMatchLenStorage"/>
    /// for a range of source offsets.
    /// </summary>
    /// <param name="mls">The match storage to read from.</param>
    /// <param name="start">Starting source offset.</param>
    /// <param name="srcSize">Number of offsets to process.</param>
    /// <param name="lao">Output array, sized <c>srcSize * numLaoPerOffs</c>.</param>
    /// <param name="numLaoPerOffs">Maximum matches per source offset.</param>
    public static void ExtractLaoFromMls(ManagedMatchLenStorage mls, int start, int srcSize,
                                          LengthAndOffset[] lao, int numLaoPerOffs)
    {
        if (start < 0 || start + srcSize > mls.Offset2Pos.Length)
        {
            throw new InvalidOperationException(
                $"ExtractLaoFromMls OOB: start={start} srcSize={srcSize} Offset2Pos.Length={mls.Offset2Pos.Length} RoundStartPos={mls.RoundStartPos}");
        }
        int laoIdx = 0;
        for (int s = srcSize; s > 0; s--, start++)
        {
            int pos = mls.Offset2Pos[start];
            if (pos != 0)
            {
                int curPos = pos;
                if (curPos < 0 || curPos + 32 > mls.ByteBuffer.Length)
                {
                    lao[laoIdx].Length = 0;
                    laoIdx += numLaoPerOffs;
                    continue;
                }
                int laoCur = laoIdx;
                for (int i = numLaoPerOffs; i > 0; i--, laoCur++)
                {
                    if (curPos + 32 > mls.ByteBuffer.Length)
                    {
                        break;
                    }
                    if (ExtractLengthFromMls(mls.ByteBuffer, ref curPos, curPos + 32,
                                              out lao[laoCur].Length, 1, 3) < 0)
                    {
                        break;
                    }
                    if (curPos + 32 > mls.ByteBuffer.Length)
                    {
                        break;
                    }
                    if (ExtractOffsetFromMls(mls.ByteBuffer, ref curPos, curPos + 32,
                                              out lao[laoCur].Offset, 13, 7) < 0)
                    {
                        break;
                    }
                }
            }
            else
            {
                lao[laoIdx].Length = 0;
            }
            laoIdx += numLaoPerOffs;
        }
    }

    // ────────────────────────────────────────────────────────────
    //  FindMatchesBT4 — Binary Tree match finder
    // ────────────────────────────────────────────────────────────

    /// <summary>
    /// Finds matches using a binary tree (BT4) match finder. Each position is
    /// inserted into a binary tree ordered by suffix content. The tree walk
    /// simultaneously searches for matches and inserts the new position.
    /// Produces higher-quality matches than hash chains (finds shorter-offset
    /// matches that hash chains miss when depth-limited), at the cost of
    /// slower insertion.
    /// </summary>
    /// <param name="srcBase">Source data buffer.</param>
    /// <param name="srcSize">Size of the source data.</param>
    /// <param name="mls">Match storage to populate.</param>
    /// <param name="maxNumMatches">Maximum matches to keep per position (up to 4).</param>
    /// <param name="preloadSize">Number of bytes already in the tree from a prior window.</param>
    /// <param name="maxDepth">Maximum tree traversal depth per position. Higher = better ratio, slower.
    /// Typical values: 32 (fast), 96 (normal), 256 (ultra).</param>
    public static void FindMatchesBT4(
        byte[] srcBase, int srcSize, ManagedMatchLenStorage mls,
        int maxNumMatches, int preloadSize, int maxDepth = 96)
    {
        if (srcSize < 8) return;

        // Hash table size: 2^bits, maps 4-byte prefix to most recent position
        int bits = Math.Min(
            Math.Max(BitOperations.Log2((uint)Math.Max(srcSize, 2) - 1) + 1, 16),
            24);
        int hashSize = 1 << bits;
        uint hashMask = (uint)(hashSize - 1);

        // head[hash] = most recent position with this 4-byte prefix (1-based, 0 = empty)
        int[] head = new int[hashSize];

        // Binary tree: left[pos] and right[pos] store child positions (1-based)
        // left[pos] = position with lexicographically smaller suffix
        // right[pos] = position with lexicographically larger suffix
        int treeSize = srcSize + 1;
        int[] left = GC.AllocateUninitializedArray<int>(treeSize);
        int[] right = GC.AllocateUninitializedArray<int>(treeSize);

        int srcSizeSafe = srcSize - 8;
        Span<LengthAndOffset> matches = stackalloc LengthAndOffset[maxNumMatches + 2];

        // Preload: insert positions [0..preloadSize) into the tree without storing matches
        for (int pos = 0; pos < preloadSize && pos < srcSizeSafe; pos++)
        {
            BT4InsertOnly(srcBase, pos, head, left, right, hashMask, maxDepth, srcSizeSafe);
        }

        // Main loop: for each position, search + insert simultaneously
        for (int pos = preloadSize; pos < srcSizeSafe; pos++)
        {
            int numMatch = BT4SearchAndInsert(srcBase, pos, head, left, right,
                hashMask, maxDepth, srcSizeSafe, matches, maxNumMatches);

            // Convert to MLS-relative position (subtract preloadSize, same as FindMatchesHashBased)
            int mlsPos = pos - preloadSize;

            if (numMatch > 0)
            {
                // Sort matches by length descending (longest first) for the optimal parser
                var matchSlice = matches.Slice(0, numMatch);
                matchSlice.Sort((a, b) => b.Length.CompareTo(a.Length));
                numMatch = RemoveIdentical(matchSlice, numMatch);
                InsertMatches(mls, mlsPos, matches, Math.Min(maxNumMatches, numMatch));
            }

            // Long match skip: for very long matches (>= 77 bytes), insert synthetic
            // sub-matches at stride-4 and skip ahead (same as FindMatchesHashBased)
            if (numMatch > 0 && matches[0].Length >= 77)
            {
                int skipLen = matches[0].Length;
                int skipOffset = matches[0].Offset;
                for (int skipPos = pos + 4; skipPos < pos + skipLen - 4 && skipPos < srcSizeSafe; skipPos += 4)
                {
                    BT4InsertOnly(srcBase, skipPos, head, left, right, hashMask, maxDepth / 4, srcSizeSafe);
                    int subLen = skipLen - (skipPos - pos);
                    if (subLen >= 4)
                    {
                        matches[0].Set(subLen, skipOffset);
                        InsertMatches(mls, skipPos - preloadSize, matches, 1);
                    }
                }
                pos += skipLen - 5;
            }
        }
    }

    /// <summary>
    /// Insert a position into the binary tree without searching for matches.
    /// Used for preloading dictionary positions.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void BT4InsertOnly(
        byte[] src, int pos, int[] head, int[] left, int[] right,
        uint hashMask, int maxDepth, int srcSafe)
    {
        BT4SearchAndInsert(src, pos, head, left, right, hashMask, maxDepth, srcSafe,
            Span<LengthAndOffset>.Empty, 0);
    }

    /// <summary>
    /// Simultaneously search the binary tree for matches at <paramref name="pos"/>
    /// and insert <paramref name="pos"/> into the tree. Returns the number of
    /// matches found (up to <paramref name="maxMatches"/>).
    /// </summary>
    /// <remarks>
    /// The binary tree is ordered by the full suffix content at each position.
    /// Walking down the tree, at each node we compare our suffix with the node's
    /// suffix. We go left if ours is smaller, right if larger. Each node we visit
    /// that matches at least 4 bytes is a match candidate. We insert ourselves
    /// by splitting the tree at the point where we stop (replacing a child pointer
    /// with ourselves and adopting the displaced subtrees as our children).
    /// </remarks>
    /// <summary>
    /// Simultaneously search the binary tree for matches at <paramref name="pos"/>
    /// and insert <paramref name="pos"/> into the tree. Returns the number of
    /// matches found (up to <paramref name="maxMatches"/>).
    /// </summary>
    /// <remarks>
    /// Uses the standard BT insertion algorithm from LZMA/zstd. The key insight:
    /// as we walk down the tree, we maintain two "dangling pointers" (leftNode, rightNode)
    /// that track where to attach the next child. At each node, if our suffix is smaller,
    /// the current node becomes our right child (via rightNode) and we descend left.
    /// If larger, the current node becomes our left child and we descend right.
    /// This simultaneously searches and inserts in O(depth) time.
    /// </remarks>
    private static unsafe int BT4SearchAndInsert(
        byte[] src, int pos, int[] head, int[] left, int[] right,
        uint hashMask, int maxDepth, int srcSafe,
        Span<LengthAndOffset> matches, int maxMatches)
    {
        uint hash = (uint)Unsafe.ReadUnaligned<uint>(ref src[pos]);
        hash = BitOperations.RotateLeft(hash * 0x9E3779B9u, 16);
        int hashIdx = (int)(hash & hashMask);

        int curMatch = head[hashIdx] - 1;
        head[hashIdx] = pos + 1;

        // Pin all arrays for the duration: eliminates managed bounds checks in the hot loop.
        fixed (byte* pSrc = src)
        fixed (int* pLeft = left)
        fixed (int* pRight = right)
        fixed (int* pHead = head)
        {
            int* leftNodePtr = pLeft + pos;
            int* rightNodePtr = pRight + pos;
            *leftNodePtr = 0;
            *rightNodePtr = 0;

            int matchLenLeft = 0;
            int matchLenRight = 0;
            int numFound = 0;
            int bestLen = 3;

            for (int depth = 0; depth < maxDepth && curMatch >= 0; depth++)
            {
                int commonLen = Math.Min(matchLenLeft, matchLenRight);
                int maxLen = Math.Min(srcSafe - pos, srcSafe - curMatch);
                if (maxLen <= commonLen) break;

                // Extend using raw pointers + 8-byte XOR + TZCNT
                byte* pA = pSrc + pos + commonLen;
                byte* pB = pSrc + curMatch + commonLen;
                int matchLen = commonLen;
                int remain = maxLen - commonLen;
                while (remain >= 8)
                {
                    ulong diff = *(ulong*)pA ^ *(ulong*)pB;
                    if (diff != 0)
                    {
                        matchLen += BitOperations.TrailingZeroCount(diff) >> 3;
                        goto doneExtend;
                    }
                    pA += 8; pB += 8;
                    matchLen += 8;
                    remain -= 8;
                }
                while (remain > 0 && *pA == *pB)
                {
                    pA++; pB++;
                    matchLen++;
                    remain--;
                }
                doneExtend:

                if (matchLen > bestLen)
                {
                    bestLen = matchLen;
                    if (numFound < maxMatches && matches.Length > 0)
                    {
                        matches[numFound++].Set(matchLen, pos - curMatch);
                    }
                    else if (numFound > 0 && matches.Length > 0)
                    {
                        // Replace shortest (linear scan — maxMatches is small, typically 4)
                        int worstIdx = 0;
                        for (int i = 1; i < numFound; i++)
                        {
                            if (matches[i].Length < matches[worstIdx].Length)
                                worstIdx = i;
                        }
                        if (matchLen > matches[worstIdx].Length)
                            matches[worstIdx].Set(matchLen, pos - curMatch);
                    }

                    if (matchLen >= maxLen)
                    {
                        *leftNodePtr = pLeft[curMatch];
                        *rightNodePtr = pRight[curMatch];
                        return numFound;
                    }
                }

                // Branch and prefetch next node's children
                if (pSrc[pos + matchLen] < pSrc[curMatch + matchLen])
                {
                    *rightNodePtr = curMatch + 1;
                    rightNodePtr = pLeft + curMatch;
                    matchLenRight = matchLen;
                    curMatch = pLeft[curMatch] - 1;
                    // Prefetch next node's tree entries
                    if (curMatch >= 0 && Sse.IsSupported)
                        Sse.Prefetch0(pLeft + curMatch);
                }
                else
                {
                    *leftNodePtr = curMatch + 1;
                    leftNodePtr = pRight + curMatch;
                    matchLenLeft = matchLen;
                    curMatch = pRight[curMatch] - 1;
                    if (curMatch >= 0 && Sse.IsSupported)
                        Sse.Prefetch0(pRight + curMatch);
                }
            }

            *leftNodePtr = 0;
            *rightNodePtr = 0;

            return numFound;
        }
    }
}
