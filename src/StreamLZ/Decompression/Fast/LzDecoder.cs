// Fast/Turbo LZ decoder.
// Fast and Turbo use the same on-disk format (only the compressor differs).
// Decompression happens in two phases: first the LZ table is parsed
// from the bitstream, then the match-copy loop runs over two 64 KB chunks.

using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics.X86;
using StreamLZ.Common;

namespace StreamLZ.Decompression.Fast;

/// <summary>
/// Static decoder for Fast/Turbo LZ format.
/// All methods use unsafe pointer arithmetic for hot inner loops.
/// </summary>
internal static unsafe class LzDecoder
{
    /// <summary>Marker value in the off16 count field indicating entropy-coded offsets.</summary>
    const ushort EntropyCodedOff16Marker = 0xFFFF;

    /// <summary>Offsets at or above this threshold (12 MB) require a 4th byte in the far-offset encoding.</summary>
    const int LargeOffsetThreshold = StreamLZConstants.FastLargeOffsetThreshold;

    /// <summary>Length values above this threshold use a 2-byte extended encoding.</summary>
    const int ExtendedLengthThreshold = 251;

    // ─── Fast_DecodeFarOffsets ───────────────────────────────────────

    /// <summary>
    /// Decode far (32-bit) offsets from the source stream. Offsets &lt; 0xC00000
    /// are stored as 3 bytes; larger offsets use an extra byte.
    /// </summary>
    /// <returns>Number of source bytes consumed.</returns>
    /// <exception cref="InvalidDataException">Thrown when offset data is corrupt or truncated.</exception>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int DecodeFarOffsets(byte* src, byte* srcEnd, uint* output, uint outputSize, long offset)
    {
        byte* srcCur = src;

        if (offset < (LargeOffsetThreshold - 1))
        {
            for (uint i = 0; i != outputSize; i++)
            {
                if (srcEnd - srcCur < 3)
                {
                    throw new InvalidDataException("Fast far-offset stream truncated (small offset path).");
                }
                uint off = (uint)(srcCur[0] | srcCur[1] << 8 | srcCur[2] << 16);
                srcCur += 3;
                output[i] = off;
                if (off > (uint)offset)
                {
                    throw new InvalidDataException("Fast far-offset exceeds current output position (small offset path).");
                }
            }
            return (int)(srcCur - src);
        }

        for (uint i = 0; i != outputSize; i++)
        {
            if (srcEnd - srcCur < 3)
            {
                throw new InvalidDataException("Fast far-offset stream truncated (large offset path).");
            }
            uint off = (uint)(srcCur[0] | srcCur[1] << 8 | srcCur[2] << 16);
            srcCur += 3;

            if (off >= LargeOffsetThreshold)
            {
                if (srcCur == srcEnd)
                {
                    throw new InvalidDataException("Fast far-offset missing 4th byte for large offset.");
                }
                off += (uint)*srcCur++ << 22;
            }
            output[i] = off;
            if (off > (uint)offset)
            {
                throw new InvalidDataException("Fast far-offset exceeds current output position (large offset path).");
            }
        }
        return (int)(srcCur - src);
    }

    // ─── Fast_CombineOffs16 ─────────────────────────────────────────

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void CombineOffs16(ushort* dst, nuint size, byte* lo, byte* hi)
    {
        for (nuint i = 0; i != size; i++)
        {
            dst[i] = (ushort)(lo[i] + hi[i] * 256);
        }
    }

    // ─── Fast_ReadLzTable ────────────────────────────────────────────

    /// <summary>
    /// Parse the compressed Fast LZ table out of <paramref name="src"/>.
    /// Populates <paramref name="lz"/> with stream pointers into scratch memory.
    /// </summary>
    /// <param name="mode">0 or 1 — selects Mode0 (delta-add literals) vs Mode1 (raw literals).</param>
    /// <param name="src">Start of compressed LZ data.</param>
    /// <param name="srcEnd">End of compressed LZ data.</param>
    /// <param name="dst">Destination buffer (first 8 bytes written when offset==0).</param>
    /// <param name="dstSize">Size of current chunk destination.</param>
    /// <param name="offset">Byte offset of dst from the start of the decompressed output.</param>
    /// <param name="scratch">Scratch memory for decoded sub-streams.</param>
    /// <param name="scratchEnd">End of scratch memory.</param>
    /// <param name="lz">Output table to populate.</param>
    /// <param name="decodeBytesFunc">
    /// Delegate to <c>High_DecodeBytes</c> (avoids circular dependency).
    /// Signature: (byte** out, byte* src, byte* srcEnd, int* decodedCount, long maxSize,
    ///             bool force, byte* scratch, byte* scratchEnd) => int bytes consumed, or -1.
    /// </param>
    /// <returns><c>true</c> on success.</returns>
    [SkipLocalsInit]
    public static bool ReadLzTable(
        int mode,
        byte* src, byte* srcEnd,
        byte* dst, int dstSize, long offset,
        byte* scratch, byte* scratchEnd,
        FastLzTable* lz,
        delegate* managed<byte**, byte*, byte*, int*, int, bool, byte*, byte*, int> decodeBytesFunc)
    {
        byte* outPtr;
        int decodeCount, n;
        uint tmp, off32Size2, off32Size1;

        if (mode > 1)
        {
            return false;
        }

        if (dstSize <= 0 || srcEnd <= src)
        {
            return false;
        }

        if (srcEnd - src < 10)
        {
            return false;
        }

        // When offset == 0, copy the first 8 literal bytes directly.
        if (offset == 0)
        {
            CopyHelpers.Copy64(dst, src);
            dst += 8;
            src += 8;
        }

        // ── Decode literal stream ──
        outPtr = scratch;
        n = decodeBytesFunc(&outPtr, src, srcEnd, &decodeCount,
            (int)Math.Min(scratchEnd - scratch, dstSize), false, scratch, scratchEnd);
        src += n;
        lz->LiteralStream.Start = outPtr;
        lz->LiteralStream.End = outPtr + decodeCount;
        scratch += decodeCount;

        // ── Decode flag / command stream ──
        outPtr = scratch;
        n = decodeBytesFunc(&outPtr, src, srcEnd, &decodeCount,
            (int)Math.Min(scratchEnd - scratch, dstSize), false, scratch, scratchEnd);
        src += n;
        lz->CommandStream.Start = outPtr;
        lz->CommandStream.End = outPtr + decodeCount;
        scratch += decodeCount;

        lz->CommandStream2OffsetEnd = (uint)decodeCount;
        if (dstSize <= 0x10000)
        {
            lz->CommandStream2Offset = (uint)decodeCount;
        }
        else
        {
            if (srcEnd - src < 2)
            {
                return false;
            }
            lz->CommandStream2Offset = *(ushort*)src;
            src += 2;
            if (lz->CommandStream2Offset > lz->CommandStream2OffsetEnd)
            {
                return false;
            }
        }

        // ── Decode off16 stream ──
        if (srcEnd - src < 2)
        {
            return false;
        }

        int off16Count = *(ushort*)src;
        if (off16Count == EntropyCodedOff16Marker)
        {
            // off16 is entropy coded — decode hi and lo halves
            byte* off16Hi;
            byte* off16Lo;
            int off16LoCount, off16HiCount;
            src += 2;

            off16Hi = scratch;
            n = decodeBytesFunc(&off16Hi, src, srcEnd, &off16HiCount,
                (int)Math.Min(scratchEnd - scratch, dstSize >> 1), false, scratch, scratchEnd);
            src += n;
            scratch += off16HiCount;

            off16Lo = scratch;
            n = decodeBytesFunc(&off16Lo, src, srcEnd, &off16LoCount,
                (int)Math.Min(scratchEnd - scratch, dstSize >> 1), false, scratch, scratchEnd);
            src += n;
            scratch += off16LoCount;

            if (off16LoCount != off16HiCount)
            {
                return false;
            }

            scratch = CopyHelpers.AlignPointer(scratch, 2);
            lz->Offset16Stream.Start = (ushort*)scratch;
            if (scratch + off16LoCount * 2 > scratchEnd)
            {
                return false;
            }
            scratch += off16LoCount * 2;
            lz->Offset16Stream.End = (ushort*)scratch;
            CombineOffs16((ushort*)lz->Offset16Stream.Start, (nuint)off16LoCount, off16Lo, off16Hi);
        }
        else
        {
            if (srcEnd - src < 2 + off16Count * 2)
            {
                return false;
            }
            lz->Offset16Stream.Start = (ushort*)(src + 2);
            src += 2 + off16Count * 2;
            lz->Offset16Stream.End = (ushort*)src;
        }

        // ── Decode off32 stream sizes ──
        if (srcEnd - src < 3)
        {
            return false;
        }
        tmp = (uint)(src[0] | src[1] << 8 | src[2] << 16);
        src += 3;

        if (tmp != 0)
        {
            off32Size1 = tmp >> 12;
            off32Size2 = tmp & 0xFFF;
            if (off32Size1 == 4095)
            {
                if (srcEnd - src < 2)
                {
                    return false;
                }
                off32Size1 = *(ushort*)src;
                src += 2;
            }
            if (off32Size2 == 4095)
            {
                if (srcEnd - src < 2)
                {
                    return false;
                }
                off32Size2 = *(ushort*)src;
                src += 2;
            }
            lz->Offset32Count1 = off32Size1;
            lz->Offset32Count2 = off32Size2;

            if (scratch + 4 * (off32Size2 + off32Size1) + 64 > scratchEnd)
            {
                return false;
            }

            scratch = CopyHelpers.AlignPointer(scratch, 4);

            lz->Offset32BackingStream1 = (uint*)scratch;
            scratch += off32Size1 * 4;
            // Store dummy bytes after for prefetcher safety.
            ((ulong*)scratch)[0] = 0;
            ((ulong*)scratch)[1] = 0;
            ((ulong*)scratch)[2] = 0;
            ((ulong*)scratch)[3] = 0;
            scratch += 32;

            lz->Offset32BackingStream2 = (uint*)scratch;
            scratch += off32Size2 * 4;
            // Store dummy bytes after for prefetcher safety.
            ((ulong*)scratch)[0] = 0;
            ((ulong*)scratch)[1] = 0;
            ((ulong*)scratch)[2] = 0;
            ((ulong*)scratch)[3] = 0;
            scratch += 32;

            n = DecodeFarOffsets(src, srcEnd, lz->Offset32BackingStream1, lz->Offset32Count1, offset);
            src += n;

            n = DecodeFarOffsets(src, srcEnd, lz->Offset32BackingStream2, lz->Offset32Count2, offset + 0x10000);
            src += n;
        }
        else
        {
            if (scratchEnd - scratch < 32)
            {
                return false;
            }
            lz->Offset32Count1 = 0;
            lz->Offset32Count2 = 0;
            lz->Offset32BackingStream1 = (uint*)scratch;
            lz->Offset32BackingStream2 = (uint*)scratch;
            // Store dummy bytes after for prefetcher safety.
            ((ulong*)scratch)[0] = 0;
            ((ulong*)scratch)[1] = 0;
            ((ulong*)scratch)[2] = 0;
            ((ulong*)scratch)[3] = 0;
        }

        lz->LengthStream = src;
        return true;
    }

    // ─── ProcessMode (unified Mode0 / Mode1) ───────────────────────

    /// <summary>
    /// Process one chunk of Fast LZ commands.
    /// When <paramref name="isDelta"/> is true, literal copies use COPY_64_ADD
    /// (delta literals: dst = lit + prev_match_byte). Otherwise literals are
    /// copied raw.
    /// </summary>
    [SkipLocalsInit]
    public static byte* ProcessMode(
        bool isDelta,
        byte* dst, nuint dstSize, byte* dstPtrEnd, byte* dstStart,
        byte* srcEnd, FastLzTable* lz, int* savedDist, nuint startOff)
    {
        byte* dstEnd = dst + dstSize;
        byte* cmdStream = lz->CommandStream.Start;
        byte* cmdStreamEnd = lz->CommandStream.End;
        byte* lengthStream = lz->LengthStream;
        byte* litStream = lz->LiteralStream.Start;
        byte* litStreamEnd = lz->LiteralStream.End;
        ushort* off16Stream = lz->Offset16Stream.Start;
        ushort* off16StreamEnd = lz->Offset16Stream.End;
        uint* off32Stream = lz->Offset32Stream.Start;
        uint* off32StreamEnd = lz->Offset32Stream.End;
        nint recentOffs = *savedDist;
        byte* match;
        nint length;
        byte* dstBegin = dst;

        dst += startOff;

        while (cmdStream < cmdStreamEnd)
        {
            // Command byte encoding:
            //   cmd >= 24:  Short token — packed [useNewOff:1][matchLen:4][litLen:3]
            //   cmd 3..23:  Medium match with off32 — length = cmd + 5
            //   cmd 0:      Long literal run (length from length stream + 64)
            //   cmd 1:      Long match with off16 (length from length stream + 91)
            //   cmd 2:      Long match with off32 (length from length stream + 29)
            nuint cmd = *cmdStream++;
            if (cmd >= 24)
            {
                // Short token: most frequent path (~90% of commands).
                // Bit 7 selects new vs recent offset; bits 6-3 = matchLen; bits 2-0 = litLen.
                nint newDist = *off16Stream;
                nuint useDistance = (cmd >> 7) - 1; // 0 = recent offset, 0xFFFF..FF = new offset
                nuint literalLength = cmd & 7;
                if (isDelta)
                {
                    CopyHelpers.Copy64Add(dst, litStream, &dst[recentOffs]);
                }
                else
                {
                    CopyHelpers.Copy64(dst, litStream);
                }
                dst += literalLength;
                litStream += literalLength;
                // Branchless offset select: XOR-mask swaps recentOffs with -newDist when useDistance != 0
                recentOffs ^= (nint)(useDistance & (nuint)(recentOffs ^ -newDist));
                off16Stream = (ushort*)((nuint)off16Stream + (useDistance & 2));
                match = dst + recentOffs;
                CopyHelpers.Copy64(dst, match);
                CopyHelpers.Copy64(dst + 8, match + 8);
                dst += (cmd >> 3) & 0xF;
            }
            else if (cmd > 2)
            {
                // Medium match: 32-bit far offset, length = cmd + 5 (range 8..28).
                length = (nint)cmd + 5;

                if (off32Stream == off32StreamEnd)
                {
                    return null;
                }
                match = dstBegin - *off32Stream++;
                recentOffs = (nint)(match - dst);

                if (dstEnd - dst < length)
                {
                    return null;
                }
                CopyHelpers.Copy64(dst, match);
                CopyHelpers.Copy64(dst + 8, match + 8);
                CopyHelpers.Copy64(dst + 16, match + 16);
                CopyHelpers.Copy64(dst + 24, match + 24);
                dst += length;
                // Prefetch the match source for an upcoming off32 token to hide DRAM latency.
                if (Sse.IsSupported)
                {
                    Sse.Prefetch0(dstBegin - off32Stream[3]);
                }
            }
            else if (cmd == 0)
            {
                // Long literal run: base length 64, extended via length stream.
                // Length encoding: if byte > 251, a 2-byte extension follows (value × 4).
                if (srcEnd - lengthStream == 0)
                {
                    return null;
                }
                length = *lengthStream;
                if (length > ExtendedLengthThreshold)
                {
                    if (srcEnd - lengthStream < 3)
                    {
                        return null;
                    }
                    length += (nint)(*(ushort*)(lengthStream + 1)) * 4;
                    lengthStream += 2;
                }
                lengthStream += 1;

                length += 64;
                if (dstEnd - dst < length ||
                    litStreamEnd - litStream < length)
                {
                    return null;
                }

                if (isDelta)
                {
                    do
                    {
                        CopyHelpers.Copy64Add(dst, litStream, &dst[recentOffs]);
                        CopyHelpers.Copy64Add(dst + 8, litStream + 8, &dst[recentOffs + 8]);
                        dst += 16;
                        litStream += 16;
                        length -= 16;
                    } while (length > 0);
                }
                else
                {
                    do
                    {
                        CopyHelpers.Copy64(dst, litStream);
                        CopyHelpers.Copy64(dst + 8, litStream + 8);
                        dst += 16;
                        litStream += 16;
                        length -= 16;
                    } while (length > 0);
                }
                // The 16-byte copy loop overshoots; length is now <= 0.
                // Adding negative length back corrects dst/litStream to exact positions.
                dst += length;
                litStream += length;
            }
            else if (cmd == 1)
            {
                // Long match with 16-bit offset: base length 91, extended via length stream.
                if (srcEnd - lengthStream == 0)
                {
                    return null;
                }
                length = *lengthStream;
                if (length > ExtendedLengthThreshold)
                {
                    if (srcEnd - lengthStream < 3)
                    {
                        return null;
                    }
                    length += (nint)(*(ushort*)(lengthStream + 1)) * 4;
                    lengthStream += 2;
                }
                lengthStream += 1;
                length += 91;

                if (off16Stream == off16StreamEnd)
                {
                    return null;
                }
                match = dst - *off16Stream++;
                recentOffs = (nint)(match - dst);
                do
                {
                    CopyHelpers.Copy64(dst, match);
                    CopyHelpers.Copy64(dst + 8, match + 8);
                    dst += 16;
                    match += 16;
                    length -= 16;
                } while (length > 0);
                dst += length;
            }
            else /* cmd == 2 */
            {
                // Long match with 32-bit offset: base length 29, extended via length stream.
                if (srcEnd - lengthStream == 0)
                {
                    return null;
                }
                length = *lengthStream;
                if (length > ExtendedLengthThreshold)
                {
                    if (srcEnd - lengthStream < 3)
                    {
                        return null;
                    }
                    length += (nint)(*(ushort*)(lengthStream + 1)) * 4;
                    lengthStream += 2;
                }
                lengthStream += 1;
                length += 29;
                if (off32Stream == off32StreamEnd)
                {
                    return null;
                }
                match = dstBegin - *off32Stream++;
                recentOffs = (nint)(match - dst);
                do
                {
                    CopyHelpers.Copy64(dst, match);
                    CopyHelpers.Copy64(dst + 8, match + 8);
                    dst += 16;
                    match += 16;
                    length -= 16;
                } while (length > 0);
                dst += length;
                if (Sse.IsSupported)
                {
                    Sse.Prefetch0(dstBegin - off32Stream[3]);
                }
            }
        }

        // Copy remaining literals
        length = (nint)(dstEnd - dst);
        if (isDelta)
        {
            if (length >= 8)
            {
                do
                {
                    CopyHelpers.Copy64Add(dst, litStream, &dst[recentOffs]);
                    dst += 8;
                    litStream += 8;
                    length -= 8;
                } while (length >= 8);
            }
            if (length > 0)
            {
                do
                {
                    *dst = (byte)(*litStream++ + dst[recentOffs]);
                    dst++;
                } while (--length != 0);
            }
        }
        else
        {
            if (length >= 8)
            {
                do
                {
                    CopyHelpers.Copy64(dst, litStream);
                    dst += 8;
                    litStream += 8;
                    length -= 8;
                } while (length >= 8);
            }
            if (length > 0)
            {
                do
                {
                    *dst++ = *litStream++;
                } while (--length != 0);
            }
        }

        *savedDist = (int)recentOffs;
        lz->LengthStream = lengthStream;
        lz->Offset16Stream.Start = off16Stream;
        lz->LiteralStream.Start = litStream;
        return lengthStream;
    }

    // ─── Fast_ProcessLzRuns ──────────────────────────────────────────

    /// <summary>
    /// Execute the Fast LZ match-copy loop over up to two 64 KB chunks.
    /// </summary>
    [SkipLocalsInit]
    public static bool ProcessLzRuns(
        int mode,
        byte* src, byte* srcEnd,
        byte* dst, nuint dstSize, ulong offset, byte* dstEnd,
        FastLzTable* lz)
    {
        if (dstSize == 0 || mode > 1)
        {
            return false;
        }

        byte* dstStart = dst - (nint)offset;
        int savedDist = -StreamLZConstants.InitialRecentOffset;
        byte* srcCur = null;

        for (int iteration = 0; iteration != 2; iteration++)
        {
            nuint dstSizeCur = dstSize;
            if (dstSizeCur > 0x10000)
            {
                dstSizeCur = 0x10000;
            }

            if (iteration == 0)
            {
                lz->Offset32Stream.Start = lz->Offset32BackingStream1;
                lz->Offset32Stream.End = lz->Offset32BackingStream1 + lz->Offset32Count1;
                lz->CommandStream.End = lz->CommandStream.Start + lz->CommandStream2Offset;
            }
            else
            {
                lz->Offset32Stream.Start = lz->Offset32BackingStream2;
                lz->Offset32Stream.End = lz->Offset32BackingStream2 + lz->Offset32Count2;
                lz->CommandStream.End = lz->CommandStream.Start + lz->CommandStream2OffsetEnd;
                lz->CommandStream.Start += lz->CommandStream2Offset;
            }

            srcCur = ProcessMode(mode == 0, dst, dstSizeCur, dstEnd, dstStart, srcEnd, lz, &savedDist,
                (offset == 0) && (iteration == 0) ? (nuint)8 : 0);
            if (srcCur == null)
            {
                return false;
            }

            dst += dstSizeCur;
            dstSize -= dstSizeCur;
            if (dstSize == 0)
            {
                break;
            }
        }

        if (srcCur != srcEnd)
        {
            return false;
        }

        return true;
    }

    // ─── Fast_DecodeChunk ──────────────────────────────────────────

    /// <summary>
    /// Decode a single Fast chunk (up to 128 KB chunks).
    /// </summary>
    /// <returns>Number of source bytes consumed.</returns>
    /// <exception cref="InvalidDataException">Thrown when the chunk data is corrupt.</exception>
    [SkipLocalsInit]
    public static int DecodeChunk(
        byte* dst, byte* dstEnd, byte* dstStart,
        byte* src, byte* srcEnd,
        byte* temp, byte* tempEnd,
        delegate* managed<byte**, byte*, byte*, int*, int, bool, byte*, byte*, int> decodeBytesFunc)
    {
        byte* srcIn = src;
        int mode, dstCount, srcUsed, writtenBytes;

        while (dstEnd - dst != 0)
        {
            dstCount = (int)(dstEnd - dst);
            if (dstCount > 0x20000)
            {
                dstCount = 0x20000;
            }
            if (srcEnd - src < 4)
            {
                throw new InvalidDataException("Fast chunk chunk header truncated.");
            }
            int chunkhdr = src[2] | src[1] << 8 | src[0] << 16;
            if ((chunkhdr & StreamLZConstants.ChunkHeaderCompressedFlag) == 0)
            {
                // Stored without any match copying.
                byte* outPtr = dst;
                srcUsed = decodeBytesFunc(&outPtr, src, srcEnd, &writtenBytes, dstCount, false, temp, tempEnd);
                if (writtenBytes != dstCount)
                {
                    throw new InvalidDataException("Fast chunk entropy-only chunk produced wrong byte count.");
                }
            }
            else
            {
                src += 3;
                srcUsed = chunkhdr & 0x7FFFF;
                mode = (chunkhdr >> StreamLZConstants.SubChunkTypeShift) & 0xF;
                if (srcEnd - src < srcUsed)
                {
                    throw new InvalidDataException("Fast chunk compressed chunk source data truncated.");
                }
                if (srcUsed < dstCount)
                {
                    int tempUsage = 2 * dstCount + 32;
                    if (tempUsage > StreamLZConstants.ChunkSize)
                    {
                        tempUsage = StreamLZConstants.ChunkSize;
                    }
                    if (!ReadLzTable(mode,
                                     src, src + srcUsed,
                                     dst, dstCount,
                                     dst - dstStart,
                                     temp + sizeof(FastLzTable), temp + tempUsage,
                                     (FastLzTable*)temp,
                                     decodeBytesFunc))
                    {
                        throw new InvalidDataException("Fast chunk ReadLzTable failed.");
                    }
                    if (!ProcessLzRuns(mode,
                                       src, src + srcUsed,
                                       dst, (nuint)dstCount,
                                       (ulong)(dst - dstStart), dstEnd,
                                       (FastLzTable*)temp))
                    {
                        throw new InvalidDataException("Fast chunk ProcessLzRuns failed.");
                    }
                }
                else if (srcUsed > dstCount || mode != 0)
                {
                    throw new InvalidDataException("Fast chunk stored chunk has invalid size or mode.");
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
