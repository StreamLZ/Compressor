// LzDecoder.cs — Entry points and types for the High LZ decoder.

using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Decompression.High;

/// <summary>
/// High-format LZ decoder. Processes HighLzTable streams (cmd, offs, lit, len)
/// to reconstruct decompressed data by copying literals and performing
/// backward-reference match copies.
/// </summary>
internal static unsafe partial class LzDecoder
{
    /// <summary>
    /// Cold error exit — outlined so the JIT keeps error-path code out of the
    /// hot instruction stream, improving I-cache density and branch prediction.
    /// </summary>
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static bool LzError() => false;

    // ----------------------------------------------------------------
    //  Pre-resolved LZ token — packed to 16 bytes (4 per cache line).
    //  One cache-line read loads 4 future match addresses for prefetch.
    // ----------------------------------------------------------------

    /// <summary>
    /// Pre-resolved LZ token. The offset carousel, long-literal and long-match
    /// lengths are fully resolved during the lightweight resolve pass so the
    /// execute pass can focus on copying and prefetching.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct LzToken
    {
        /// <summary>Cumulative output position at the start of this token (before literals).</summary>
        public int DstPos;
        /// <summary>Resolved match offset (negative — points backwards into output buffer).</summary>
        public int Offset;
        /// <summary>Literal byte count (resolved from lenStream if cmd litlen == 3).</summary>
        public int LitLen;
        /// <summary>Match byte count (includes +2 base for short matches).</summary>
        public int MatchLen;
    }

    /// <summary>
    /// Number of tokens to look ahead for match-source software prefetch.
    /// Sweep on Arrow Lake (enwik8 High L9): 0→883, 16→1015, 32→1109,
    /// 48→1223, 64→1255, 96→1272, 128→1306, 192→1207 MB/s.
    /// Plateau at 64-128, regression at 192. 128 chosen as best median.
    /// </summary>
    private const int PrefetchAhead = 128;

    // ----------------------------------------------------------------
    //  High_CopyWholeMatch
    // ----------------------------------------------------------------

    /// <summary>
    /// Copies a whole-block match from a previous position in the output buffer.
    /// Used when an entire chunk is a repeat of earlier data.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void CopyWholeMatch(byte* dst, uint offset, nint length)
    {
        nint i = 0;
        byte* src = dst - offset;
        if (offset >= 8)
        {
            for (; i + 8 <= length; i += 8)
            {
                *(ulong*)(dst + i) = *(ulong*)(src + i);
            }
        }
        for (; i < length; i++)
        {
            dst[i] = src[i];
        }
    }

    // ----------------------------------------------------------------
    //  High_ReadLzTable helpers
    // ----------------------------------------------------------------

    /// <summary>
    /// Combines scaled offset arrays: offs[i] = scale * offs[i] - lowBits[i].
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CombineScaledOffsetArrays(int* offsStream, nint offsStreamSize, int scale, byte* lowBits)
    {
        for (nint i = 0; i != offsStreamSize; i++)
        {
            offsStream[i] = scale * offsStream[i] - lowBits[i];
        }
    }

    /// <summary>
    /// Rotate left (C _rotl intrinsic equivalent).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint RotateLeft(uint value, int count)
    {
        return (value << count) | (value >> (32 - count));
    }

    // ----------------------------------------------------------------
    //  High_UnpackOffsets
    //
    //  Unpacks the packed 8-bit offset and length streams into 32-bit.
    // ----------------------------------------------------------------

    /// <summary>
    /// Unpacks packed 8-bit offset and length streams into 32-bit int arrays.
    /// Reads from a bidirectional bitstream (forward + backward readers).
    /// </summary>
    [SkipLocalsInit]
    public static bool UnpackOffsets(
        byte* src, byte* srcEnd,
        byte* packedOffsStream, byte* packedOffsStreamExtra, int packedOffsStreamSize,
        int multiDistScale,
        byte* packedLitlenStream, int packedLitlenStreamSize,
        int* offsStream, int* lenStream,
        bool excessFlag, int excessBytes)
    {
        if (packedOffsStreamSize < 0 || packedLitlenStreamSize < 0 || srcEnd <= src)
        {
            return false;
        }


        BitReader bitsA;
        BitReader bitsB;
        int n, i;
        int u32LenStreamSize = 0;

        // The side bitstream is consumed from both ends: forward-coded entries come
        // from bitsA, backward-coded entries come from bitsB. A valid stream makes
        // the two readers meet exactly once all offset/length extras are decoded.
        bitsA.BitPos = 24;
        bitsA.Bits = 0;
        bitsA.P = src;
        bitsA.PEnd = srcEnd;
        bitsA.Refill();

        bitsB.BitPos = 24;
        bitsB.Bits = 0;
        bitsB.P = srcEnd;
        bitsB.PEnd = src;
        bitsB.RefillBackwards();

        if (!excessFlag)
        {
            // Non-excess blocks start with the u32 length-stream count in the
            // backward reader before the alternating backward-coded payload.
            if (bitsB.Bits < 0x2000)
            {
                return false;
            }
            n = (int)System.Numerics.BitOperations.LeadingZeroCount(bitsB.Bits);
            bitsB.BitPos += n;
            bitsB.Bits <<= n;
            bitsB.RefillBackwards();
            n++;
            u32LenStreamSize = (int)(bitsB.Bits >> (32 - n)) - 1;
            bitsB.BitPos += n;
            bitsB.Bits <<= n;
            bitsB.RefillBackwards();
        }

        if (multiDistScale == 0)
        {
            // Traditional way of coding offsets
            byte* packedOffsStreamEnd = packedOffsStream + packedOffsStreamSize;
            while (packedOffsStream != packedOffsStreamEnd)
            {
                *offsStream++ = -(int)bitsA.ReadDistance(*packedOffsStream++);
                if (packedOffsStream == packedOffsStreamEnd)
                {
                    break;
                }
                *offsStream++ = -(int)bitsB.ReadDistanceBackward(*packedOffsStream++);
            }
        }
        else
        {
            // New way of coding offsets: the high bits of cmd give the number of
            // explicit low bits to read, while the low 3 bits select the bucket base.
            // nb == 0 is valid and means the bucket base fully determines the offset.
            int* offsStreamOrg = offsStream;
            byte* packedOffsStreamEnd = packedOffsStream + packedOffsStreamSize;
            uint cmd, offs;
            while (packedOffsStream != packedOffsStreamEnd)
            {
                cmd = *packedOffsStream++;
                int nb = (int)(cmd >> 3);
                if (nb > 26)
                {
                    return false;
                }
                offs = (uint)((8 + (cmd & 7)) << nb);
                if (nb > 0) offs |= bitsA.ReadMoreThan24Bits(nb);
                *offsStream++ = 8 - (int)offs;
                if (packedOffsStream == packedOffsStreamEnd)
                {
                    break;
                }
                cmd = *packedOffsStream++;
                nb = (int)(cmd >> 3);
                if (nb > 26)
                {
                    return false;
                }
                offs = (uint)((8 + (cmd & 7)) << nb);
                if (nb > 0) offs |= bitsB.ReadMoreThan24BitsB(nb);
                *offsStream++ = 8 - (int)offs;
            }
            if (multiDistScale != 1)
            {
                CombineScaledOffsetArrays(offsStreamOrg, (nint)(offsStream - offsStreamOrg), multiDistScale, packedOffsStreamExtra);
            }
        }

        // Decode u32 length stream — max count is ChunkSize (128KB) / 256 = 512
        const int MaxLengthStreamEntries = 512; // upper bound: one extended length per 256 bytes of output
        uint* u32LenStreamBuf = stackalloc uint[MaxLengthStreamEntries];
        if (u32LenStreamSize < 0 || u32LenStreamSize > MaxLengthStreamEntries)
        {
            return false;
        }

        uint* u32LenStream = u32LenStreamBuf;
        uint* u32LenStreamEnd = u32LenStreamBuf + u32LenStreamSize;
        for (i = 0; i + 1 < u32LenStreamSize; i += 2)
        {
            if (!bitsA.ReadLength(out u32LenStream[i]))
            {
                return false;
            }
            if (!bitsB.ReadLengthBackward(out u32LenStream[i + 1]))
            {
                return false;
            }
        }
        if (i < u32LenStreamSize)
        {
            if (!bitsA.ReadLength(out u32LenStream[i]))
            {
                return false;
            }
        }

        // Rewind each reader to the next unread byte before comparing pointers.
        // If they do not meet exactly, the packed side bitstream was malformed.
        bitsA.P -= (24 - bitsA.BitPos) >> 3;
        bitsB.P += (24 - bitsB.BitPos) >> 3;

        if (bitsA.P != bitsB.P)
        {
            return false;
        }

        // Unpack litlen stream: values < 255 are stored directly, 255 means overflow
        for (i = 0; i < packedLitlenStreamSize; i++)
        {
            uint v = packedLitlenStream[i];
            if (v == 255)
            {
                v = *u32LenStream++ + 255;
            }
            lenStream[i] = (int)(v + 3);
        }
        if (u32LenStream != u32LenStreamEnd)
        {
            return false;
        }

        return true;
    }

    // ----------------------------------------------------------------
    //  High_ReadLzTable
    //
    //  Decodes the four sub-streams (lit, cmd, offs, len) from the
    //  compressed source into HighLzTable.
    // ----------------------------------------------------------------

    /// <summary>
    /// Reads and populates a <see cref="HighLzTable"/> from compressed source data.
    /// Decodes four sub-streams: literals, commands, packed offsets, and packed lengths,
    /// then unpacks offsets and lengths into their final 32-bit form.
    /// </summary>
    /// <param name="mode">LZ mode (must be 0 or 1).</param>
    /// <param name="src">Compressed source start.</param>
    /// <param name="srcEnd">Compressed source end.</param>
    /// <param name="dst">Destination buffer for this chunk.</param>
    /// <param name="dstSize">Size of the destination chunk.</param>
    /// <param name="offset">Byte offset from start of overall output.</param>
    /// <param name="scratch">Scratch buffer start (after HighLzTable).</param>
    /// <param name="scratchEnd">Scratch buffer end.</param>
    /// <param name="lztable">Output LZ table to populate.</param>
    /// <param name="decodeBytes">Delegate to the entropy byte decoder (High_DecodeBytes).</param>
    /// <returns><c>true</c> on success.</returns>
    [SkipLocalsInit]
    public static bool ReadLzTable(
        int mode,
        byte* src, byte* srcEnd,
        byte* dst, int dstSize, int offset,
        byte* scratch, byte* scratchEnd,
        HighLzTable* lztable,
        DecodeBytes decodeBytes)
    {
        byte* output;
        int decodeCount, n;

        if (mode > 1)
        {
            return false;
        }

        if (dstSize <= 0 || srcEnd <= src)
        {
            return false;
        }

        if (srcEnd - src < 13)
        {
            return false;
        }

        if (offset == 0)
        {
            CopyHelpers.Copy64(dst, src);
            dst += 8;
            src += 8;
        }

        if ((*src & 0x80) != 0)
        {
            byte flag = *src++;
            if ((flag & 0xc0) != 0x80)
            {
                return false; // reserved flag set
            }

            return false; // excess bytes not supported
        }

        // Disable no-copy optimization if source and dest overlap
        bool forceCopy = dst <= srcEnd && src <= dst + dstSize;

        // Decode lit stream, bounded by dstSize
        output = scratch;
        n = decodeBytes(&output, src, srcEnd, &decodeCount,
            (int)Math.Min(scratchEnd - scratch, dstSize),
            forceCopy, scratch, scratchEnd);
        src += n;
        lztable->LitStream = output;
        lztable->LitStreamSize = decodeCount;
        scratch += decodeCount;

        // Decode command stream, bounded by dstSize
        output = scratch;
        n = decodeBytes(&output, src, srcEnd, &decodeCount,
            (int)Math.Min(scratchEnd - scratch, dstSize),
            forceCopy, scratch, scratchEnd);
        src += n;
        lztable->CmdStream = output;
        lztable->CmdStreamSize = decodeCount;
        scratch += decodeCount;

        // Check minimum remaining bytes for offset decoding
        if (srcEnd - src < 3)
        {
            return false;
        }

        int offsScaling = 0;
        byte* packedOffsStreamExtra = null;

        if ((src[0] & 0x80) != 0)
        {
            // Uses the mode where distances are coded with 2 tables
            offsScaling = src[0] - 127;
            src++;

            byte* packedOffsStream = scratch;
            n = decodeBytes(&packedOffsStream, src, srcEnd, &lztable->OffsStreamSize,
                (int)Math.Min(scratchEnd - scratch, lztable->CmdStreamSize),
                false, scratch, scratchEnd);
            src += n;
            scratch += lztable->OffsStreamSize;

            if (offsScaling != 1)
            {
                packedOffsStreamExtra = scratch;
                n = decodeBytes(&packedOffsStreamExtra, src, srcEnd, &decodeCount,
                    (int)Math.Min(scratchEnd - scratch, lztable->OffsStreamSize),
                    false, scratch, scratchEnd);
                if (decodeCount != lztable->OffsStreamSize)
                {
                    return false;
                }
                src += n;
                scratch += decodeCount;
            }

            // Decode packed litlen stream, bounded by dstSize >> 2
            byte* packedLenStream = scratch;
            n = decodeBytes(&packedLenStream, src, srcEnd, &lztable->LenStreamSize,
                (int)Math.Min(scratchEnd - scratch, dstSize >> 2),
                false, scratch, scratchEnd);
            src += n;
            scratch += lztable->LenStreamSize;

            // Reserve memory for final dist stream (16-byte aligned)
            scratch = CopyHelpers.AlignPointer(scratch, 16);
            lztable->OffsStream = (int*)scratch;
            long offsBytes = (long)lztable->OffsStreamSize * 4;
            long lenBytes = (long)lztable->LenStreamSize * 4;
            if (offsBytes > scratchEnd - scratch || lenBytes > scratchEnd - scratch)
            {
                return false;
            }
            scratch += offsBytes;

            // Reserve memory for final len stream (16-byte aligned)
            scratch = CopyHelpers.AlignPointer(scratch, 16);
            lztable->LenStream = (int*)scratch;
            scratch += lenBytes;

            if (scratch + 64 > scratchEnd)
            {
                return false;
            }

            return UnpackOffsets(src, srcEnd, packedOffsStream, packedOffsStreamExtra,
                lztable->OffsStreamSize, offsScaling,
                packedLenStream, lztable->LenStreamSize,
                lztable->OffsStream, lztable->LenStream, false, 0);
        }
        else
        {
            // Decode packed offset stream, bounded by cmd stream size
            byte* packedOffsStream = scratch;
            n = decodeBytes(&packedOffsStream, src, srcEnd, &lztable->OffsStreamSize,
                (int)Math.Min(scratchEnd - scratch, lztable->CmdStreamSize),
                false, scratch, scratchEnd);
            src += n;
            scratch += lztable->OffsStreamSize;

            // Decode packed litlen stream, bounded by dstSize >> 2
            byte* packedLenStream = scratch;
            n = decodeBytes(&packedLenStream, src, srcEnd, &lztable->LenStreamSize,
                (int)Math.Min(scratchEnd - scratch, dstSize >> 2),
                false, scratch, scratchEnd);
            src += n;
            scratch += lztable->LenStreamSize;

            // Reserve memory for final dist stream (16-byte aligned)
            scratch = CopyHelpers.AlignPointer(scratch, 16);
            lztable->OffsStream = (int*)scratch;
            long offsBytes2 = (long)lztable->OffsStreamSize * 4;
            long lenBytes2 = (long)lztable->LenStreamSize * 4;
            if (offsBytes2 > scratchEnd - scratch || lenBytes2 > scratchEnd - scratch)
            {
                return false;
            }
            scratch += offsBytes2;

            // Reserve memory for final len stream (16-byte aligned)
            scratch = CopyHelpers.AlignPointer(scratch, 16);
            lztable->LenStream = (int*)scratch;
            scratch += lenBytes2;

            if (scratch + 64 > scratchEnd)
            {
                return false;
            }

            return UnpackOffsets(src, srcEnd, packedOffsStream, packedOffsStreamExtra,
                lztable->OffsStreamSize, offsScaling,
                packedLenStream, lztable->LenStreamSize,
                lztable->OffsStream, lztable->LenStream, false, 0);
        }
    }

    // ----------------------------------------------------------------
    //  DecodeBytes delegate — matches the High_DecodeBytes signature
    // ----------------------------------------------------------------

    /// <summary>
    /// Delegate matching the signature of High_DecodeBytes (the entropy decoder).
    /// Returns number of source bytes consumed, or -1 on error.
    /// </summary>
    /// <param name="output">Pointer to output pointer (may be redirected to source on memcopy mode).</param>
    /// <param name="src">Compressed source start.</param>
    /// <param name="srcEnd">Compressed source end.</param>
    /// <param name="decodedSize">Receives the number of bytes decoded.</param>
    /// <param name="outputSize">Maximum output size.</param>
    /// <param name="forceMemmove">If true, always copy to output buffer rather than aliasing source.</param>
    /// <param name="scratch">Scratch buffer start.</param>
    /// <param name="scratchEnd">Scratch buffer end.</param>
    public unsafe delegate int DecodeBytes(
        byte** output, byte* src, byte* srcEnd, int* decodedSize,
        int outputSize, bool forceMemmove, byte* scratch, byte* scratchEnd);

    // ----------------------------------------------------------------
    //  High_DecodeChunk
    //
    //  Decodes one 256KB chunk. Internally divided into up to two
    //  128KB sub-chunks that are compressed separately but share history.
    // ----------------------------------------------------------------

    /// <summary>
    /// Attempts pipelined decoding of a 2-sub-chunk block: overlaps
    /// ReadLzTable of chunk 2 with ProcessLzRuns of chunk 1.
    /// Returns total source bytes consumed, 0 if pipelining is not possible
    /// (caller should fall back to sequential), or -1 on decompression error.
    /// </summary>
    [SkipLocalsInit]
    private static int TryDecodePipelined(
        byte* dst, byte* dstEnd, byte* dstStart,
        byte* src, byte* srcEnd,
        byte* scratch, byte* scratchEnd,
        DecodeBytes decodeBytes)
    {
        byte* srcIn = src;
        int dstCount1 = 0x20000;

        // Parse chunk 1 header
        if (srcEnd - src < 4)
        {
            return 0;
        }
        int chunkhdr1 = src[2] | (src[1] << 8) | (src[0] << 16);
        if ((chunkhdr1 & StreamLZConstants.ChunkHeaderCompressedFlag) == 0)
        {
            return 0; // entropy-only, can't pipeline
        }
        src += 3;
        int srcUsed1 = chunkhdr1 & 0x7FFFF;
        int mode1 = (chunkhdr1 >> StreamLZConstants.SubChunkTypeShift) & 0xF;
        if (srcEnd - src < srcUsed1 || srcUsed1 >= dstCount1)
        {
            return 0;
        }
        byte* src1Data = src;

        // Parse chunk 2 header
        byte* src2Hdr = src + srcUsed1;
        int dstCount2 = (int)(dstEnd - dst) - dstCount1;
        if (dstCount2 <= 0 || srcEnd - src2Hdr < 4)
        {
            return 0;
        }
        int chunkhdr2 = src2Hdr[2] | (src2Hdr[1] << 8) | (src2Hdr[0] << 16);
        if ((chunkhdr2 & StreamLZConstants.ChunkHeaderCompressedFlag) == 0)
        {
            return 0; // entropy-only, can't pipeline
        }
        int srcUsed2 = chunkhdr2 & 0x7FFFF;
        int mode2 = (chunkhdr2 >> StreamLZConstants.SubChunkTypeShift) & 0xF;
        byte* src2Data = src2Hdr + 3;
        if (srcEnd - src2Data < srcUsed2 || srcUsed2 >= dstCount2)
        {
            return 0;
        }

        // Compute scratch for chunk 1
        nint scratchUsage1 = Math.Min(
            StreamLZConstants.CalculateScratchSize(dstCount1),
            (int)(scratchEnd - scratch));
        if (scratchUsage1 < sizeof(HighLzTable))
        {
            return 0;
        }

        // ReadLzTable for chunk 1
        if (!ReadLzTable(mode1,
            src1Data, src1Data + srcUsed1,
            dst, dstCount1,
            (int)(dst - dstStart),
            scratch + sizeof(HighLzTable), scratch + scratchUsage1,
            (HighLzTable*)scratch,
            decodeBytes))
        {
            throw new InvalidDataException("High TryDecodePipelined: ReadLzTable failed for chunk 1.");
        }

        // Allocate second scratch and pipeline: ReadLzTable₂ || ProcessLzRuns₁
        byte* scratch2 = (byte*)NativeMemory.AllocZeroed(StreamLZConstants.ScratchSize);
        try
        {
            nint scratchUsage2 = Math.Min(
                StreamLZConstants.CalculateScratchSize(dstCount2),
                StreamLZConstants.ScratchSize);

            // Capture pointers as nint for lambda (C# can't capture pointer locals)
            nint capturedSrc2 = (nint)src2Data, capturedSrc2End = (nint)(src2Data + srcUsed2);
            nint capturedDst2 = (nint)(dst + dstCount1), capturedDstStart = (nint)dstStart;
            nint capturedScratch2 = (nint)scratch2, capturedScratch2End = (nint)(scratch2 + scratchUsage2);
            var capturedDecodeBytes = decodeBytes;
            int capturedMode2 = mode2, capturedDstCount2 = dstCount2;
            bool readOk = false;

            var readTask = Task.Run(() =>
            {
                readOk = ReadLzTable(capturedMode2,
                    (byte*)capturedSrc2, (byte*)capturedSrc2End,
                    (byte*)capturedDst2, capturedDstCount2,
                    (int)((byte*)capturedDst2 - (byte*)capturedDstStart),
                    (byte*)capturedScratch2 + sizeof(HighLzTable), (byte*)capturedScratch2End,
                    (HighLzTable*)(byte*)capturedScratch2,
                    capturedDecodeBytes);
            });

            // ProcessLzRuns₁ on main thread (overlapped with ReadLzTable₂)
            bool lzOk = ProcessLzRuns(mode1, dst, dstCount1, (int)(dst - dstStart), (HighLzTable*)scratch,
                scratch + scratchUsage1, scratchEnd);

            try { readTask.Wait(); }
            catch (AggregateException ex) { throw new InvalidDataException("High TryDecodePipelined: background ReadLzTable failed.", ex.InnerException ?? ex); }

            if (!lzOk || !readOk)
            {
                throw new InvalidDataException($"High TryDecodePipelined: {(lzOk ? "ReadLzTable" : "ProcessLzRuns")} failed for chunk {(lzOk ? 2 : 1)}.");
            }

            // ProcessLzRuns₂ on main thread
            if (!ProcessLzRuns(mode2, dst + dstCount1, dstCount2,
                    (int)(dst + dstCount1 - dstStart), (HighLzTable*)scratch2,
                    scratch2 + scratchUsage2, scratch2 + StreamLZConstants.ScratchSize))
            {
                throw new InvalidDataException("High TryDecodePipelined: ProcessLzRuns failed for chunk 2.");
            }

            return (int)(src2Data + srcUsed2 - srcIn);
        }
        finally
        {
            NativeMemory.Free(scratch2);
        }
    }

    /// <summary>
    /// Decodes one 256KB chunk. Internally divided into 128KB sub-chunks
    /// that are compressed separately but share a common history.
    /// </summary>
    /// <param name="dst">Current write position in the output buffer.</param>
    /// <param name="dstEnd">End of the output region for this chunk.</param>
    /// <param name="dstStart">Start of the overall output buffer (for offset calculation).</param>
    /// <param name="src">Compressed source start.</param>
    /// <param name="srcEnd">Compressed source end.</param>
    /// <param name="scratch">Scratch buffer start.</param>
    /// <param name="scratchEnd">Scratch buffer end.</param>
    /// <param name="decodeBytes">Entropy decoder callback.</param>
    /// <returns>Number of source bytes consumed, or -1 on error.</returns>
    [SkipLocalsInit]
    public static int DecodeChunk(
        byte* dst, byte* dstEnd, byte* dstStart,
        byte* src, byte* srcEnd,
        byte* scratch, byte* scratchEnd,
        DecodeBytes decodeBytes)
    {
        byte* srcIn = src;
        int mode, dstCount, srcUsed, writtenBytes;

        while (dstEnd - dst != 0)
        {
            dstCount = (int)(dstEnd - dst);
            if (dstCount > 0x20000)
            {
                dstCount = 0x20000;
                // Pipelining (overlapping ReadLzTable of sub-chunk 2 with ProcessLzRuns
                // of sub-chunk 1 via Task.Run) was benchmarked and found to be a net
                // negative: Task.Run dispatch overhead exceeds the overlap benefit for
                // sub-chunks that decompress in <50μs. Sequential processing is faster.
            }
            if (srcEnd - src < 4)
            {
                throw new InvalidDataException("High DecodeChunk: source data truncated before sub-chunk header.");
            }

            int chunkhdr = src[2] | (src[1] << 8) | (src[0] << 16);
            if ((chunkhdr & StreamLZConstants.ChunkHeaderCompressedFlag) == 0)
            {
                // Stored as entropy without any match copying.
                byte* output = dst;
                srcUsed = decodeBytes(&output, src, srcEnd, &writtenBytes, dstCount, false, scratch, scratchEnd);
                if (writtenBytes != dstCount)
                {
                    throw new InvalidDataException($"High DecodeChunk: entropy decode failed (writtenBytes={writtenBytes}, expected={dstCount}).");
                }
            }
            else
            {
                src += 3;
                srcUsed = chunkhdr & 0x7FFFF;
                mode = (chunkhdr >> StreamLZConstants.SubChunkTypeShift) & 0xF;
                if (srcEnd - src < srcUsed)
                {
                    throw new InvalidDataException($"High DecodeChunk: source data truncated (need {srcUsed} bytes, have {(int)(srcEnd - src)}).");
                }
                if (srcUsed < dstCount)
                {
                    nint scratchUsage = Math.Min(
                        StreamLZConstants.CalculateScratchSize(dstCount),
                        (int)(scratchEnd - scratch));
                    if (scratchUsage < sizeof(HighLzTable))
                    {
                            throw new InvalidDataException("High DecodeChunk: scratch buffer too small for LZ table.");
                    }
                    if (!ReadLzTable(mode,
                        src, src + srcUsed,
                        dst, dstCount,
                        (int)(dst - dstStart),
                        scratch + sizeof(HighLzTable), scratch + scratchUsage,
                        (HighLzTable*)scratch,
                        decodeBytes))
                    {
                            throw new InvalidDataException("High DecodeChunk: ReadLzTable failed.");
                    }
                    if (!ProcessLzRuns(mode, dst, dstCount, (int)(dst - dstStart), (HighLzTable*)scratch,
                            scratch + scratchUsage, scratchEnd))
                    {
                            throw new InvalidDataException("High DecodeChunk: ProcessLzRuns failed.");
                    }
                }
                else if (srcUsed > dstCount || mode != 0)
                {
                    throw new InvalidDataException($"High DecodeChunk: invalid stored sub-chunk (srcUsed={srcUsed}, dstCount={dstCount}, mode={mode}).");
                }
                else
                {
                    Buffer.MemoryCopy(src, dst, dstCount, dstCount);
                }
            }
            src += srcUsed;
            dst += dstCount;
        }
        return (int)(src - srcIn);
    }
}
