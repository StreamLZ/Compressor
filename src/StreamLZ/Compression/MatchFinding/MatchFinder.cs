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
    public static void FindMatchesHashBased(
        byte[] srcBase, int srcSize, ManagedMatchLenStorage mls,
        int maxNumMatches, int preloadSize)
    {
        var hasher = new MatchHasher16Dual();

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
            uint u32ToScanFor = Unsafe.ReadUnaligned<uint>(ref srcBase[curPos]);

            int cur1 = hasher.HashEntryPtrNextIndex;
            int cur2 = hasher.HashEntry2PtrNextIndex;
            uint curHashTag = hasher.CurrentHashTag;

            if (curPos + 8 < srcSizeSafe)
            {
                hasher.SetHashPosPrefetch(srcBase, curPos + 8);
            }
            hasher.SetHashPos(srcBase, curPos + 1);

            int numMatch = 0;

            uint[] hashTable = hasher.HashTable;

            // Process both hash buckets (primary and dual)
            int hashCurIdx = cur1;
            for (int pass = 0; pass < 2; pass++)
            {
                int bestMl = 0;

                // Check 16 hash entries in groups of 4 using SSE2 where available
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

                            // Compute all 4 rounds upfront (vectorised HASHROUND)
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

                            // Combine into single 16-bit mask
                            uint matchingOffsets = (uint)Sse2.MoveMask(
                                Sse2.PackSignedSaturate(
                                    Sse2.PackSignedSaturate(m0, m1),
                                    Sse2.PackSignedSaturate(m2, m3)).AsByte());

                            // Process only the matching entries using BSF
                            while (matchingOffsets != 0)
                            {
                                int bit = BitOperations.TrailingZeroCount(matchingOffsets);
                                matchingOffsets &= matchingOffsets - 1;
                                uint offset = offsets[bit];
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

            hasher.Insert(cur1, cur2, MatchHasherBase.MakeHashValue(curHashTag, (uint)curPos));

            if (numMatch > 0)
            {
                // Sort matches (longest first, then by offset ascending)
                var matchSlice = match.Slice(0, numMatch);
                matchSlice.Sort();
                numMatch = RemoveIdentical(matchSlice, numMatch);

                int pos = curPos - preloadSize;
                InsertMatches(mls, pos, match, Math.Min(maxNumMatches, numMatch));

                int bestMlTotal = match[0].Length;

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
}
