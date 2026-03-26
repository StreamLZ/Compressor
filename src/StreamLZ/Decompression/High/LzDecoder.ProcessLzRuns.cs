// LzDecoder.ProcessLzRuns.cs — Resolve and Execute passes for the High LZ decoder.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Decompression.High;

internal static unsafe partial class LzDecoder
{
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
    private static void ExecuteTokens_Type1(
        LzToken* tokens,
        int tokenCount,
        byte* dst,
        byte* litStream)
    {
        // SAFETY: Copy operations (Copy64, WildCopy16) may write up to 15 bytes past the
        // logical end of each literal/match run. Callers must provide SafeSpace (64 bytes)
        // of writable padding past the output buffer end. This padding requirement is
        // enforced at the public API boundary (Slz.Decompress validates buffer size).
        byte* dstBase = dst;

        for (int i = 0; i < tokenCount; i++)
        {
            // Prefetch match source for a future token.
            // tokens[prefetchIndex].DstPos + LitLen gives the output position at match start.
            // Adding Offset (negative) gives the match source address in the output buffer.
            int prefetchIndex = i + PrefetchAhead;
            if (prefetchIndex < tokenCount)
            {
                Sse.Prefetch0(dstBase + tokens[prefetchIndex].DstPos + tokens[prefetchIndex].LitLen + tokens[prefetchIndex].Offset);
            }

            int literalLength = tokens[i].LitLen;
            int matchLength = tokens[i].MatchLen;
            int offset = tokens[i].Offset;

            // Copy literals (raw, no delta) — cascading 8-byte copies
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

            // Copy match — offset is negative, matchSource points back into output
            byte* matchSource = dst + offset;
            CopyHelpers.Copy64(dst, matchSource);
            CopyHelpers.Copy64(dst + 8, matchSource + 8);
            if (matchLength > 16)
            {
                CopyHelpers.WildCopy16(dst + 16, matchSource + 16, dst + matchLength);
            }
            dst += matchLength;
        }
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

            // Copy literals with delta add
            CopyHelpers.Copy64Add(dst, litStream, &dst[lastOffset]);
            if (literalLength > 8)
            {
                CopyHelpers.Copy64Add(dst + 8, litStream + 8, &dst[lastOffset + 8]);
                if (literalLength > 16)
                {
                    CopyHelpers.Copy64Add(dst + 16, litStream + 16, &dst[lastOffset + 16]);
                    if (literalLength > 24)
                    {
                        do
                        {
                            CopyHelpers.Copy64Add(dst + 24, litStream + 24, &dst[lastOffset + 24]);
                            literalLength -= 8;
                            dst += 8;
                            litStream += 8;
                        } while (literalLength > 24);
                    }
                }
            }
            dst += literalLength;
            litStream += literalLength;

            // Rotate recent offsets
            offset = recentOffsets[offsetIndex + 3];
            recentOffsets[offsetIndex + 3] = recentOffsets[offsetIndex + 2];
            recentOffsets[offsetIndex + 2] = recentOffsets[offsetIndex + 1];
            recentOffsets[offsetIndex + 1] = recentOffsets[offsetIndex + 0];
            recentOffsets[3] = offset;
            lastOffset = offset;

            // Advance offsStream only when offsetIndex == 3 (new offset used)
            // (offsetIndex + 1) & 4 is 4 when offsetIndex==3, else 0 — advances by one int.
            offsStream = (int*)((nint)offsStream + ((offsetIndex + 1) & 4));

            matchSource = dst + offset;
            if (matchLength != 15)
            {
                CopyHelpers.Copy64(dst, matchSource);
                CopyHelpers.Copy64(dst + 8, matchSource + 8);
                dst += matchLength + 2;
            }
            else
            {
                // Long match: read extra length from lenStream
                matchLength = (uint)(14 + *lenStream++);
                CopyHelpers.Copy64(dst, matchSource);
                CopyHelpers.Copy64(dst + 8, matchSource + 8);
                CopyHelpers.WildCopy16(dst + 16, matchSource + 16, dst + matchLength);
                dst += matchLength;
            }
        }

        // Verify all streams consumed correctly
        if (offsStream != offsStreamEnd || lenStream != lenStreamEnd)
        {
            return LzError();
        }

        uint trailingLiteralCount = (uint)(dstEnd - dst);
        if (trailingLiteralCount != (uint)(litStreamEnd - litStream))
        {
            return LzError();
        }

        // Copy remaining literals with delta add
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
                int resolved = ResolveTokens(lzTable, tokens, out int* offsStreamFinal, out int* lenStreamFinal);
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
                ExecuteTokens_Type1(tokens, resolved, dst, litStream);

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

        // Copy remaining trailing literals (raw)
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
