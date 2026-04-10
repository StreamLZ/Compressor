// LzDecoder.ProcessLzRuns.cs — Resolve and Execute passes for the High LZ decoder.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Decompression.High;

internal static unsafe partial class LzDecoder
{
    // Exact-length copy helpers used in the slow tail path near dstEnd.
    // These must NOT overshoot — unlike Copy64/WildCopy16 which may write
    // up to 15 bytes past the logical end. Separate methods to keep the
    // fast path free of per-byte branch overhead.

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CopyLiteralExact(byte* dst, byte* src, int length)
    {
        if (Vector256.IsHardwareAccelerated)
        {
            while (length >= 32)
            {
                Vector256.Load(src).Store(dst);
                dst += 32;
                src += 32;
                length -= 32;
            }
        }

        while (length >= 8)
        {
            CopyHelpers.Copy64(dst, src);
            dst += 8;
            src += 8;
            length -= 8;
        }

        while (length-- > 0)
        {
            *dst++ = *src++;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CopyLiteralAddExact(byte* dst, byte* src, byte* delta, int length)
    {
        if (Avx2.IsSupported)
        {
            while (length >= 32)
            {
                var vs = Vector256.Load(src);
                var vd = Vector256.Load(delta);
                Avx2.Add(vs, vd).Store(dst);
                dst += 32;
                src += 32;
                delta += 32;
                length -= 32;
            }
        }

        while (length >= 8)
        {
            CopyHelpers.Copy64Add(dst, src, delta);
            dst += 8;
            src += 8;
            delta += 8;
            length -= 8;
        }

        while (length-- > 0)
        {
            *dst++ = (byte)(*src++ + *delta++);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CopyMatchExact(byte* dst, byte* src, int length)
    {
        // Match copies read from the output buffer itself. The (dst - src) >= 32 guard
        // prevents SIMD loads from reading bytes we haven't written yet (overlapping copies).
        if (Vector256.IsHardwareAccelerated && (dst - src) >= 32)
        {
            while (length >= 32)
            {
                Vector256.Load(src).Store(dst);
                dst += 32;
                src += 32;
                length -= 32;
            }
        }

        while (length-- > 0)
        {
            *dst++ = *src++;
        }
    }

    // ================================================================
    //  Resolve pass — lightweight walk of cmd/offs/len streams.
    //  Resolves the offset carousel and long lengths into a flat token
    //  array. All input streams are sequential → guaranteed L1 hits.
    // ================================================================

    /// <summary>
    /// Resolves all tokens from the HighLzTable streams into a flat array.
    /// Handles the offset carousel rotation and long-length decoding.
    /// </summary>
    /// <returns>Number of tokens resolved, or -1 on stream validation error.</returns>
    [SkipLocalsInit]
    private static int ResolveTokens(
        HighLzTable* lzTable,
        LzToken* tokens,
        int dstSize,
        out int* offsStreamFinal,
        out int* lenStreamFinal)
    {
        byte* cmdStream = lzTable->CmdStream;
        byte* cmdStreamEnd = cmdStream + lzTable->CmdStreamSize;
        int* lenStream = lzTable->LenStream;
        int* offsStream = lzTable->OffsStream;

        // Carousel offsets: indices 3-5 hold the 3 most recent match offsets, initialized to -InitialRecentOffset (sentinel).
        int* recentOffsets = stackalloc int[7];
        recentOffsets[3] = -StreamLZConstants.InitialRecentOffset;
        recentOffsets[4] = -StreamLZConstants.InitialRecentOffset;
        recentOffsets[5] = -StreamLZConstants.InitialRecentOffset;

        int dstPos = 0;
        int tokenIndex = 0;

        while (cmdStream < cmdStreamEnd)
        {
            // Command byte layout: [offsIndex:2][matchLen:4][litLen:2]
            //   litLen 0-2 = inline literal count; 3 = read from length stream
            //   matchLen 0-14 = length + 2; 15 = read from length stream + 14
            //   offsIndex 0-2 = reuse recent offset [1st, 2nd, 3rd]; 3 = new offset from stream
            const int CmdLitLenMask = 0x3;
            const int CmdMatchLenShift = 2;
            const int CmdMatchLenMask = 0xF;
            const int CmdOffsIndexShift = 6;

            uint commandByte = *cmdStream++;
            uint literalLength = commandByte & CmdLitLenMask;
            uint offsetIndex = commandByte >> CmdOffsIndexShift;
            uint matchLength = (commandByte >> CmdMatchLenShift) & CmdMatchLenMask;

            // SAFETY: Speculative read — reads *lenStream unconditionally to enable branchless conditional.
            // On valid streams, lenStream always has entries remaining when literalLength == 3.
            // On corrupt streams, the read may overshoot by 1 element; the scratch buffer provides
            // sufficient padding to absorb this (ScratchSize includes headroom beyond stream data).
            uint speculativeLongLength = (uint)*lenStream;
            int* advancedLenStream = lenStream + 1;
            lenStream = (literalLength == 3) ? advancedLenStream : lenStream;
            literalLength = (literalLength == 3) ? speculativeLongLength : literalLength;

            // Offset carousel: 3-entry LRU of recent match offsets.
            // Slot 6 holds the new offset from the stream. The indexed slot is promoted to
            // position 3 (MRU), and the others shift down. This gives 2-bit encoding for
            // the 3 most recent offsets — a significant bitrate saving on structured data.
            // SAFETY: Speculative read — *offsStream is read unconditionally; only consumed
            // when offsetIndex == 3. Scratch buffer padding covers the 1-element overshoot.
            recentOffsets[6] = *offsStream;
            int offset = recentOffsets[offsetIndex + 3];
            recentOffsets[offsetIndex + 3] = recentOffsets[offsetIndex + 2];
            recentOffsets[offsetIndex + 2] = recentOffsets[offsetIndex + 1];
            recentOffsets[offsetIndex + 1] = recentOffsets[offsetIndex + 0];
            recentOffsets[3] = offset;

            // Branchless stream advance: (offsetIndex + 1) & 4 yields 4 (sizeof int) when
            // offsetIndex == 3, else 0. Avoids a branch on every token.
            offsStream = (int*)((nint)offsStream + ((offsetIndex + 1) & 4));

            // Resolve match length
            int actualMatchLen;
            if (matchLength != 15)
            {
                actualMatchLen = (int)matchLength + 2;
            }
            else
            {
                actualMatchLen = 14 + *lenStream++;
            }

            tokens[tokenIndex].DstPos = dstPos;
            tokens[tokenIndex].Offset = offset;
            tokens[tokenIndex].LitLen = (int)literalLength;
            tokens[tokenIndex].MatchLen = actualMatchLen;
            tokenIndex++;

            dstPos += (int)literalLength + actualMatchLen;

            // Reject if cumulative output exceeds declared chunk size.
            // Catches malicious length values before the execute pass copies bytes.
            if (dstPos > dstSize)
            {
                offsStreamFinal = offsStream;
                lenStreamFinal = lenStream;
                return -1;
            }
        }

        offsStreamFinal = offsStream;
        lenStreamFinal = lenStream;
        return tokenIndex;
    }

    // ================================================================
    //  Execute pass — Type 1 (raw literals)
    //  Walks the pre-resolved token array, issuing Sse.Prefetch0 for
    //  match sources PrefetchAhead tokens ahead. The token array is
    //  16 bytes/token → 4 per cache line, so one miss loads 4 future
    //  match source addresses.
    // ================================================================

    /// <summary>
    /// Executes Type1 (raw literal) LZ token copies with N-ahead match-source prefetch.
    /// This is Phase B of the two-phase decode: Phase A (ResolveTokens) pre-resolved all
    /// carousel offsets and lengths into a flat array. This phase walks the array doing
    /// memory copies, issuing Prefetch0 for a future token's match source address to hide
    /// DRAM latency (~60ns on modern hardware). The token struct is 16 bytes, so 4 tokens
    /// fit per cache line — reading tokens[i+N] also warms tokens[i+N+1..3] for free.
    /// </summary>
    [SkipLocalsInit]
    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    private static bool ExecuteTokens_Type1(
        LzToken* tokens,
        int tokenCount,
        byte* dst,
        byte* dstEnd,
        byte* dstStart,
        byte* litStream)
    {
        // Wide copy operations (Copy64, WildCopy16) may write up to 15 bytes past
        // the logical end of each run. In the parallel self-contained decompressor,
        // adjacent chunks share a contiguous output buffer — overshooting would
        // corrupt the next chunk's data. To avoid this without adding a branch to
        // every token in the hot loop, we split into two loops:
        //   1. Fast path: wide copies, no boundary check (vast majority of tokens)
        //   2. Slow tail: exact byte-by-byte copies (last few tokens near dstEnd)
        //
        // The split point is found via binary search on pre-resolved token positions.
        byte* dstBase = dst;
        byte* dstSafeEnd = dstEnd - StreamLZDecoder.SafeSpace;

        int safeTokenCount = tokenCount;
        if (tokenCount > 0)
        {
            int lastTokenEnd = tokens[tokenCount - 1].DstPos + tokens[tokenCount - 1].LitLen + tokens[tokenCount - 1].MatchLen;
            if (dstBase + lastTokenEnd > dstSafeEnd)
            {
                int lo = 0, hi = tokenCount;
                while (lo < hi)
                {
                    int mid = (lo + hi) >> 1;
                    int tokenEnd = tokens[mid].DstPos + tokens[mid].LitLen + tokens[mid].MatchLen;
                    if (dstBase + tokenEnd <= dstSafeEnd)
                        lo = mid + 1;
                    else
                        hi = mid;
                }
                safeTokenCount = lo;
            }
        }

        // Fast path — no boundary checks, wide copies
        int i;
        for (i = 0; i < safeTokenCount; i++)
        {
            int prefetchIndex = i + PrefetchAhead;
            if (prefetchIndex < tokenCount)
            {
                // Prefetch two cache lines: many matches span a line boundary, and
                // long matches (>64 bytes) benefit from the second line being warm.
                byte* prefetchAddr = dstBase + tokens[prefetchIndex].DstPos + tokens[prefetchIndex].LitLen + tokens[prefetchIndex].Offset;
                Sse.Prefetch0(prefetchAddr);
                Sse.Prefetch0(prefetchAddr + 64);
            }

            int literalLength = tokens[i].LitLen;
            int matchLength = tokens[i].MatchLen;
            int offset = tokens[i].Offset;

            // Cascading literal copy: most literals are <= 8 bytes (inline in the command token),
            // so the first Copy64 handles ~80% of cases with zero branches taken.
            // The nested ifs avoid a loop setup cost for the common short-literal path.
            // Only literals > 24 bytes fall through to the do/while loop.
            CopyHelpers.Copy64(dst, litStream);
            if (literalLength > 8)
            {
                CopyHelpers.Copy64(dst + 8, litStream + 8);
                if (literalLength > 16)
                {
                    CopyHelpers.Copy64(dst + 16, litStream + 16);
                    if (literalLength > 24)
                    {
                        byte* copyDst = dst;
                        byte* copySrc = litStream;
                        int remaining = literalLength;
                        do
                        {
                            CopyHelpers.Copy64(copyDst + 24, copySrc + 24);
                            remaining -= 8;
                            copyDst += 8;
                            copySrc += 8;
                        } while (remaining > 24);
                    }
                }
            }
            dst += literalLength;
            litStream += literalLength;

            // Match copy: offset is negative, so matchSource points back into already-decoded output.
            // Two unconditional Copy64 calls cover matches up to 16 bytes (the vast majority:
            // min match = 2, max inline match = 16). WildCopy16 handles the long-match tail
            // and may overshoot — safe because we're in the fast path (dst + matchLength < dstSafeEnd).
            byte* matchSource = dst + offset;
            if (matchSource < dstStart) return false;
            CopyHelpers.Copy64(dst, matchSource);
            CopyHelpers.Copy64(dst + 8, matchSource + 8);
            if (matchLength > 16)
            {
                CopyHelpers.WildCopy16(dst + 16, matchSource + 16, dst + matchLength);
            }
            dst += matchLength;
        }

        // Slow tail — exact copies, no overshoot
        for (; i < tokenCount; i++)
        {
            int literalLength = tokens[i].LitLen;
            int matchLength = tokens[i].MatchLen;
            int offset = tokens[i].Offset;

            CopyLiteralExact(dst, litStream, literalLength);
            dst += literalLength;
            litStream += literalLength;

            byte* slowMatch = dst + offset;
            if (slowMatch < dstStart) return false;
            CopyMatchExact(dst, slowMatch, matchLength);
            dst += matchLength;
        }

        return true;
    }

    // ----------------------------------------------------------------
    //  High_ProcessLzRuns_Type0
    //
    //  Mode 0: literals are delta-coded (added to the byte at last_offset).
    //  Note: may access memory out of bounds on invalid input.
    // ----------------------------------------------------------------

    /// <summary>
    /// Processes High LZ runs in Type 0 mode.
    /// Literals are delta-coded: each literal byte is added to the corresponding
    /// byte at <c>dst[last_offset]</c> to produce the output.
    /// </summary>
    [SkipLocalsInit]
    // Type0 is a single-pass decoder: it walks the command stream, resolving offsets and
    // lengths inline, then immediately copying literals and matches. This is simpler than
    // Type1's two-pass approach but cannot prefetch match sources ahead of time.
    // The delta-add literal transform (dst = litStream + dst[lastOffset]) makes prefetch
    // less valuable here because the literal copy itself touches the dst[lastOffset] cache
    // line, warming it for the next literal run.
    public static bool ProcessLzRuns_Type0(
        HighLzTable* lzTable,
        byte* dst,
        byte* dstEnd,
        byte* dstStart)
    {
        byte* cmdStream = lzTable->CmdStream;
        byte* cmdStreamEnd = cmdStream + lzTable->CmdStreamSize;
        int* lenStream = lzTable->LenStream;
        int* lenStreamEnd = lzTable->LenStream + lzTable->LenStreamSize;
        byte* litStream = lzTable->LitStream;
        byte* litStreamEnd = lzTable->LitStream + lzTable->LitStreamSize;
        int* offsStream = lzTable->OffsStream;
        int* offsStreamEnd = lzTable->OffsStream + lzTable->OffsStreamSize;
        byte* matchSource;
        int offset;
        byte* dstSafeEnd = dstEnd - StreamLZDecoder.SafeSpace;

        // recentOffsets[3..5] are the active recent offset slots.
        // Indices 0..2 are scratch space used during the rotation.
        int* recentOffsets = stackalloc int[7];
        int lastOffset;

        recentOffsets[3] = -StreamLZConstants.InitialRecentOffset;
        recentOffsets[4] = -StreamLZConstants.InitialRecentOffset;
        recentOffsets[5] = -StreamLZConstants.InitialRecentOffset;
        lastOffset = -StreamLZConstants.InitialRecentOffset;

        while (cmdStream < cmdStreamEnd)
        {
            // High command token: [7:6]=offsetIndex, [5:2]=matchLength, [1:0]=literalLength
            const int CmdLitLenMask = 0x3;
            const int CmdMatchLenShift = 2;
            const int CmdMatchLenMask = 0xF;
            const int CmdOffsIndexShift = 6;

            uint commandByte = *cmdStream++;
            uint literalLength = commandByte & CmdLitLenMask;
            uint offsetIndex = commandByte >> CmdOffsIndexShift;
            uint matchLength = (commandByte >> CmdMatchLenShift) & CmdMatchLenMask;

            // Branchless long-literal decode: speculatively read lenStream
            uint speculativeLongLength = (uint)*lenStream;
            int* advancedLenStream = lenStream + 1;

            lenStream = (literalLength == 3) ? advancedLenStream : lenStream;
            literalLength = (literalLength == 3) ? speculativeLongLength : literalLength;
            recentOffsets[6] = *offsStream;

            int literalLengthInt = (int)literalLength;

            // Save the previous lastOffset for literal delta decoding.
            // The encoder computes DeltaLiterals[i] = src[i] - src[i - Recent0] using the
            // PREVIOUS token's Recent0, then updates Recent0 after writing literals.
            // The decoder must match: use the old lastOffset for literals, then rotate.
            int litDeltaOffset = lastOffset;

            // Rotate recent offsets (updates lastOffset for the MATCH copy)
            offset = recentOffsets[offsetIndex + 3];
            recentOffsets[offsetIndex + 3] = recentOffsets[offsetIndex + 2];
            recentOffsets[offsetIndex + 2] = recentOffsets[offsetIndex + 1];
            recentOffsets[offsetIndex + 1] = recentOffsets[offsetIndex + 0];
            recentOffsets[3] = offset;
            lastOffset = offset;

            // Advance offsStream only when offsetIndex == 3 (new offset used)
            // (offsetIndex + 1) & 4 is 4 when offsetIndex==3, else 0 — advances by one int.
            offsStream = (int*)((nint)offsStream + ((offsetIndex + 1) & 4));

            // Prefetch match source: offset is known, literal copy hasn't started yet.
            // By the time literals are processed, this cache line should be in L1.
            if (Sse.IsSupported)
                Sse.Prefetch0(dst + literalLengthInt + offset);

            int actualMatchLength;
            if (matchLength != 15)
            {
                actualMatchLength = (int)matchLength + 2;
            }
            else
            {
                // Long match: read extra length from lenStream
                actualMatchLength = 14 + *lenStream++;
            }

            // Near the end of the output buffer, wide copies (Copy64, WildCopy16)
            // would overshoot into adjacent memory. Switch to exact byte-by-byte
            // copies for the last few tokens. This branch is almost never taken
            // (only the final ~64 bytes of a 256 KB chunk) so the predictor
            // eliminates it from the fast path.
            if (dst + literalLengthInt + actualMatchLength >= dstSafeEnd)
            {
                // Slow path: exact copies near the buffer boundary.
                if (dst + literalLengthInt + actualMatchLength > dstEnd)
                {
                    return LzError();
                }
                CopyLiteralAddExact(dst, litStream, &dst[litDeltaOffset], literalLengthInt);
                dst += literalLengthInt;
                litStream += literalLengthInt;

                matchSource = dst + offset;
                if (matchSource < dstStart) return LzError();
                CopyMatchExact(dst, matchSource, actualMatchLength);
            }
            else
            {
                // ── Fast path: wide copies with delta-add literals ──
                // Match bounds check is hoisted before literal copy to fail early on corrupt data.
                // The cascading Copy64Add pattern mirrors ExecuteTokens_Type1's literal copy:
                // nested ifs avoid loop overhead for the dominant short-literal case.
                matchSource = dst + literalLengthInt + offset;
                if (matchSource < dstStart) return LzError();

                CopyHelpers.Copy64Add(dst, litStream, &dst[litDeltaOffset]);
                if (literalLength > 8)
                {
                    CopyHelpers.Copy64Add(dst + 8, litStream + 8, &dst[litDeltaOffset + 8]);
                    if (literalLength > 16)
                    {
                        CopyHelpers.Copy64Add(dst + 16, litStream + 16, &dst[litDeltaOffset + 16]);
                        if (literalLength > 24)
                        {
                            do
                            {
                                CopyHelpers.Copy64Add(dst + 24, litStream + 24, &dst[litDeltaOffset + 24]);
                                literalLength -= 8;
                                dst += 8;
                                litStream += 8;
                            } while (literalLength > 24);
                        }
                    }
                }
                dst += literalLength;
                litStream += literalLength;

                // Match copy: two unconditional 8-byte copies cover matches up to 16 bytes.
                // WildCopy16 is only needed when matchLength == 15 (the long-match sentinel),
                // which means actualMatchLen >= 14 + lenStream value, potentially very long.
                matchSource = dst + offset;
                CopyHelpers.Copy64(dst, matchSource);
                CopyHelpers.Copy64(dst + 8, matchSource + 8);
                if (matchLength == 15)
                {
                    CopyHelpers.WildCopy16(dst + 16, matchSource + 16, dst + actualMatchLength);
                }
            }
            dst += actualMatchLength;
        }

        // ── Post-loop validation ──
        // All sub-streams must be fully consumed. Any leftover bytes indicate a malformed
        // bitstream or a bug in the command/offset/length resolution logic above.
        if (offsStream != offsStreamEnd || lenStream != lenStreamEnd)
        {
            return LzError();
        }

        // Trailing literals: bytes after the last match, not covered by any command token.
        // The remaining output space must exactly equal the remaining literal stream.
        uint trailingLiteralCount = (uint)(dstEnd - dst);
        if (trailingLiteralCount != (uint)(litStreamEnd - litStream))
        {
            return LzError();
        }

        // Copy trailing literals with delta-add (no SafeSpace concern — these are exact copies)
        if (trailingLiteralCount >= 8)
        {
            do
            {
                CopyHelpers.Copy64Add(dst, litStream, &dst[lastOffset]);
                dst += 8;
                litStream += 8;
                trailingLiteralCount -= 8;
            } while (trailingLiteralCount >= 8);
        }
        if (trailingLiteralCount > 0)
        {
            do
            {
                *dst = (byte)(*litStream++ + dst[lastOffset]);
                dst++;
            } while (--trailingLiteralCount != 0);
        }
        return true;
    }

    // ----------------------------------------------------------------
    //  High_ProcessLzRuns_Type1
    //
    //  Mode 1: literals are raw (straight copy, no delta).
    //  Two-pass approach: resolve tokens, then execute with prefetch.
    // ----------------------------------------------------------------

    /// <summary>
    /// Processes High LZ runs in Type 1 mode.
    /// Literals are raw bytes copied directly from the literal stream.
    /// Uses pre-resolved tokens with match-source prefetch to hide DRAM latency.
    /// </summary>
    [SkipLocalsInit]
    public static bool ProcessLzRuns_Type1(
        HighLzTable* lzTable,
        byte* dst,
        byte* dstEnd,
        byte* dstStart,
        byte* scratchFree,
        byte* scratchEnd)
    {
        byte* litStream = lzTable->LitStream;
        byte* litStreamEnd = lzTable->LitStream + lzTable->LitStreamSize;
        int* offsStreamEnd = lzTable->OffsStream + lzTable->OffsStreamSize;
        int* lenStreamEnd = lzTable->LenStream + lzTable->LenStreamSize;
        int tokenCount = lzTable->CmdStreamSize;

        if (tokenCount > 0)
        {
            nuint tokenBytes = (nuint)(tokenCount * sizeof(LzToken));
            bool useScratch = (scratchEnd - scratchFree) >= (nint)tokenBytes;
            LzToken* tokens = useScratch
                ? (LzToken*)scratchFree
                : (LzToken*)NativeMemory.Alloc(tokenBytes);
            try
            {
                // Phase A: Resolve all tokens (carousel, lengths) — all L1 hits
                int resolved = ResolveTokens(lzTable, tokens, (int)(dstEnd - dst), out int* offsStreamFinal, out int* lenStreamFinal);
                if (resolved < 0)
                {
                    return LzError();
                }

                // Verify offsStream and lenStream consumed exactly
                if (offsStreamFinal != offsStreamEnd || lenStreamFinal != lenStreamEnd)
                {
                    return LzError();
                }

                // Phase B: Execute with match-source prefetch
                if (!ExecuteTokens_Type1(tokens, resolved, dst, dstEnd, dstStart, litStream))
                {
                    return LzError();
                }

                // Advance pointers past all tokens
                if (resolved > 0)
                {
                    ref LzToken last = ref tokens[resolved - 1];
                    int totalAdvance = last.DstPos + last.LitLen + last.MatchLen;
                    dst += totalAdvance;
                    // litStream advances inside ExecuteTokens by sum of all LitLen
                    int totalLits = 0;
                    for (int i = 0; i < resolved; i++)
                    {
                        totalLits += tokens[i].LitLen;
                    }
                    litStream += totalLits;
                }
            }
            finally
            {
                if (!useScratch)
                {
                    NativeMemory.Free(tokens);
                }
            }
        }

        // Verify trailing literal length
        uint trailingLiteralCount = (uint)(dstEnd - dst);
        if (trailingLiteralCount != (uint)(litStreamEnd - litStream))
        {
            return LzError();
        }

        // ── Trailing literal copy (raw, no delta) ──
        // Three-tier copy: 64-byte blocks for bulk, 8-byte for medium, byte-by-byte for remainder.
        // This avoids overshoot — trailing literals extend to the exact end of the output buffer.
        if (trailingLiteralCount >= 64)
        {
            do
            {
                CopyHelpers.Copy64Bytes(dst, litStream);
                dst += 64;
                litStream += 64;
                trailingLiteralCount -= 64;
            } while (trailingLiteralCount >= 64);
        }
        if (trailingLiteralCount >= 8)
        {
            do
            {
                CopyHelpers.Copy64(dst, litStream);
                dst += 8;
                litStream += 8;
                trailingLiteralCount -= 8;
            } while (trailingLiteralCount >= 8);
        }
        if (trailingLiteralCount > 0)
        {
            do
            {
                *dst++ = *litStream++;
            } while (--trailingLiteralCount != 0);
        }
        return true;
    }

    // ----------------------------------------------------------------
    //  High_ProcessLzRuns — dispatcher
    // ----------------------------------------------------------------

    /// <summary>
    /// Dispatches LZ run processing to the correct Type handler.
    /// </summary>
    /// <param name="mode">0 = delta-coded literals (Type0), 1 = raw literals (Type1).</param>
    /// <param name="dst">Pointer to the start of this chunk's output region.</param>
    /// <param name="dstSize">Number of bytes to produce.</param>
    /// <param name="offset">Byte offset of <paramref name="dst"/> from the start of the overall output buffer.</param>
    /// <param name="lzTable">Pointer to the populated HighLzTable.</param>
    /// <param name="scratchFree">Pointer to available scratch memory for token array allocation.</param>
    /// <param name="scratchEnd">End of scratch memory region.</param>
    /// <returns><c>true</c> on success.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool ProcessLzRuns(int mode, byte* dst, int dstSize, int offset, HighLzTable* lzTable,
        byte* scratchFree = null, byte* scratchEnd = null)
    {
        if (dstSize <= 0 || offset < 0)
        {
            return false;
        }

        byte* dstEnd = dst + dstSize;

        if (mode == 1)
        {
            return ProcessLzRuns_Type1(lzTable, dst + (offset == 0 ? 8 : 0), dstEnd, dst - offset,
                scratchFree, scratchEnd);
        }

        if (mode == 0)
        {
            return ProcessLzRuns_Type0(lzTable, dst + (offset == 0 ? 8 : 0), dstEnd, dst - offset);
        }

        return false;
    }
}
