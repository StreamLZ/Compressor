// StreamLZDecoder.cs — Main entry point for StreamLZ decompression.

using System.Buffers;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using StreamLZ.Decompression.Entropy;
namespace StreamLZ.Decompression;

/// <summary>
/// High-level StreamLZ decompressor supporting High, Fast, and Turbo formats.
/// </summary>
internal static unsafe class StreamLZDecoder
{
    /// <summary>
    /// The decompressor may write up to this many bytes past the end of the
    /// destination buffer. Callers must allocate at least this much extra space.
    /// </summary>
    public const int SafeSpace = 64;

    // ----------------------------------------------------------------
    //  ParseHeader — reads the 2-byte block header
    // ----------------------------------------------------------------

    /// <summary>
    /// Reads and validates the 2-byte StreamLZ block header, populating decoder type,
    /// checksum, and restart/uncompressed flags.
    /// </summary>
    /// <param name="hdr">Header structure to populate.</param>
    /// <param name="p">Pointer to the start of the header bytes.</param>
    /// <returns>Pointer advanced past the header, or <c>null</c> if the header is invalid.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte* ParseHeader(ref StreamLZHeader hdr, byte* p)
    {
        // Block header byte 0 bit layout:
        //   [3:0]  magic nibble (must be 0x5)
        //   [4]    SelfContained flag
        //   [5]    TwoPhase flag
        //   [6]    RestartDecoder flag
        //   [7]    Uncompressed flag
        // Block header byte 1 bit layout:
        //   [6:0]  DecoderType
        //   [7]    UseChecksums flag
        int b0 = p[0];
        if ((b0 & 0xF) != 0x5)
        {
            return null;
        }
        int b1 = p[1];
        hdr = new StreamLZHeader
        {
            TwoPhase = ((b0 >> 5) & 1) != 0,
            SelfContained = ((b0 >> 4) & 1) != 0,
            RestartDecoder = ((b0 >> 6) & 1) != 0,
            Uncompressed = ((b0 >> 7) & 1) != 0,
            DecoderType = (CodecType)(b1 & 0x7F),
            UseChecksums = (b1 >> 7) != 0,
        };

        // Accepted decoder types: High(0), Fast(1), Turbo(2).
        if (hdr.DecoderType != CodecType.High &&
            hdr.DecoderType != CodecType.Fast &&
            hdr.DecoderType != CodecType.Turbo)
        {
            return null;
        }

        return p + 2;
    }

    // ----------------------------------------------------------------
    //  ParseChunkHeader — reads the per-chunk header (High/Fast/Turbo)
    // ----------------------------------------------------------------

    /// <summary>
    /// Reads the per-chunk header used by High, Fast, and Turbo decoders.
    /// Extracts compressed size, flags, whole-match distance, and optional checksum.
    /// </summary>
    /// <param name="hdr">Chunk header structure to populate.</param>
    /// <param name="p">Pointer to the start of the chunk header bytes.</param>
    /// <param name="useChecksum">Whether a 3-byte checksum follows the header.</param>
    /// <returns>Pointer advanced past the header, or <c>null</c> if the header is invalid.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte* ParseChunkHeader(ref ChunkHeader hdr, byte* p, bool useChecksum)
    {
        // 4-byte little-endian chunk header:
        //   bits [ChunkSizeBits-1 : 0]  = compressed size minus 1
        //   bits [ChunkSizeBits+1 : ChunkSizeBits] = type (0=normal, 1=memset)
        //   remaining high bits = reserved (0)
        uint v = *(uint*)p;
        uint size = v & StreamLZConstants.ChunkSizeMask;
        uint type = (v >> StreamLZConstants.ChunkTypeShift) & 3;

        if (type == 0)
        {
            // Normal compressed chunk
            if (useChecksum)
            {
                hdr = new ChunkHeader
                {
                    CompressedSize = size + 1,
                    Checksum = (uint)((p[4] << 16) | (p[5] << 8) | p[6]),
                };
                return p + StreamLZConstants.ChunkHeaderSize + 3;
            }
            else
            {
                hdr = new ChunkHeader { CompressedSize = size + 1 };
                return p + StreamLZConstants.ChunkHeaderSize;
            }
        }
        if (type == 1)
        {
            // Memset chunk: byte at offset 4 is the fill value
            hdr = new ChunkHeader { Checksum = p[StreamLZConstants.ChunkHeaderSize] };
            return p + StreamLZConstants.ChunkHeaderSize + 1;
        }
        return null;
    }

    // ----------------------------------------------------------------
    //  CopyWholeMatch
    // ----------------------------------------------------------------

    /// <summary>
    /// Copies a whole-match reference by reading <paramref name="length"/> bytes from
    /// <paramref name="offset"/> positions behind <paramref name="dst"/>. Uses 8-byte
    /// chunks when the offset is large enough to avoid overlap.
    /// </summary>
    /// <param name="dst">Destination pointer where bytes are written.</param>
    /// <param name="offset">Backward distance to the source data.</param>
    /// <param name="length">Number of bytes to copy.</param>
    private static void CopyWholeMatch(byte* dst, uint offset, int length)
    {
        int i = 0;
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
    //  DecodeStep — process one chunk
    // ----------------------------------------------------------------

    /// <summary>
    /// Processes a single chunk (block) of compressed data, dispatching to the
    /// appropriate decoder (High, Fast, or Turbo) based
    /// on the current header's decoder type.
    /// </summary>
    /// <param name="hdr">Current StreamLZ header; may be re-parsed at 256KB boundaries.</param>
    /// <param name="srcUsed">On return, the number of compressed bytes consumed (0 if insufficient input).</param>
    /// <param name="dstUsed">On return, the number of decompressed bytes produced.</param>
    /// <param name="scratch">Scratch buffer for decoder working memory.</param>
    /// <param name="scratchSize">Size in bytes of the scratch buffer.</param>
    /// <param name="dstStart">Pointer to the beginning of the full output buffer.</param>
    /// <param name="offset">Current write offset within the output buffer.</param>
    /// <param name="dstBytesLeftIn">Remaining decompressed bytes expected.</param>
    /// <param name="src">Pointer to the current position in the compressed input.</param>
    /// <param name="srcBytesLeft">Remaining compressed bytes available.</param>
    /// <returns><c>true</c> if the chunk was decoded successfully; <c>false</c> on error.</returns>
    private static bool DecodeStep(
        ref StreamLZHeader hdr,
        ref int srcUsed, ref int dstUsed,
        byte* scratch, int scratchSize,
        byte* dstStart, int offset, int dstBytesLeftIn,
        byte* src, int srcBytesLeft)
    {
        if (srcBytesLeft < 2)
        {
            return false;
        }
        if (dstBytesLeftIn <= 0)
        {
            return false;
        }

        byte* srcIn = src;
        byte* srcEnd = src + srcBytesLeft;
        ChunkHeader chunkHeader = default;

        // Parse header at every 256KB boundary
        if ((offset & (StreamLZConstants.ChunkSize - 1)) == 0)
        {
            byte* next = ParseHeader(ref hdr, src);
            if (next == null)
            {
                return false;
            }
            src = next;
        }

        int dstBytesLeft = (int)Math.Min(StreamLZConstants.ChunkSize, dstBytesLeftIn);

        if (hdr.Uncompressed)
        {
            if (srcEnd - src < dstBytesLeft)
            {
                srcUsed = 0;
                dstUsed = 0;
                return true;
            }
            Buffer.MemoryCopy(src, dstStart + offset, dstBytesLeft, dstBytesLeft);
            srcUsed = (int)(src - srcIn) + dstBytesLeft;
            dstUsed = dstBytesLeft;
            return true;
        }

        {
            byte* next = ParseChunkHeader(ref chunkHeader, src, hdr.UseChecksums);
            if (next == null)
            {
                return false;
            }
            src = next;
        }

        if (src > srcEnd)
        {
            return false;
        }

        // Too few bytes to make progress?
        if ((nuint)(srcEnd - src) < chunkHeader.CompressedSize)
        {
            srcUsed = 0;
            dstUsed = 0;
            return true;
        }

        if (chunkHeader.CompressedSize > (uint)dstBytesLeft)
        {
            return false;
        }

        if (chunkHeader.CompressedSize == 0)
        {
            if (chunkHeader.WholeMatchDistance != 0)
            {
                if (chunkHeader.WholeMatchDistance > (uint)offset)
                {
                    return false;
                }
                CopyWholeMatch(dstStart + offset, chunkHeader.WholeMatchDistance, dstBytesLeft);
            }
            else
            {
                new Span<byte>(dstStart + offset, dstBytesLeft).Fill((byte)chunkHeader.Checksum);
            }
            srcUsed = (int)(src - srcIn);
            dstUsed = dstBytesLeft;
            return true;
        }

        // CRC24 checksum: parsed from the stream but not verified.
        // The compressor writes a 3-byte checksum when GenerateChunkHeaderChecksum is
        // enabled (off by default).
        // TODO: implement CRC24 verification behind an opt-in flag once the algorithm
        // is confirmed. The checksum value is available in chunkHeader.Checksum.

        if (chunkHeader.CompressedSize == (uint)dstBytesLeft)
        {
            Buffer.MemoryCopy(src, dstStart + offset, dstBytesLeft, dstBytesLeft);
            srcUsed = (int)(src - srcIn) + dstBytesLeft;
            dstUsed = dstBytesLeft;
            return true;
        }

        byte* scratchEnd = scratch + scratchSize;
        int n;

        byte* lzBase = dstStart;

        switch (hdr.DecoderType)
        {
            case CodecType.High:
                n = High.LzDecoder.DecodeChunk(
                    dstStart + offset, dstStart + offset + dstBytesLeft, lzBase,
                    src, src + (int)chunkHeader.CompressedSize,
                    scratch, scratchEnd,
                    EntropyDecoder.High_DecodeBytes);
                break;

            case CodecType.Turbo: // Turbo uses the same wire format as Fast
            case CodecType.Fast:
                n = Fast.LzDecoder.DecodeChunk(
                    dstStart + offset, dstStart + offset + dstBytesLeft, lzBase,
                    src, src + (int)chunkHeader.CompressedSize,
                    scratch, scratchEnd,
                    &EntropyDecoder.High_DecodeBytes);
                break;

            default:
                return false;
        }

        if (n != (int)chunkHeader.CompressedSize)
        {
            return false;
        }

        srcUsed = (int)(src - srcIn) + n;
        dstUsed = dstBytesLeft;
        return true;
    }

    // ----------------------------------------------------------------
    //  Decompress — main public API
    // ----------------------------------------------------------------

    /// <summary>
    /// Decompresses StreamLZ-compressed data.
    /// </summary>
    /// <param name="source">Compressed source data.</param>
    /// <param name="destination">
    /// Destination buffer. Must be at least <paramref name="decompressedSize"/> + <see cref="SafeSpace"/> bytes.
    /// </param>
    /// <param name="decompressedSize">Expected decompressed size.</param>
    /// <returns>Number of bytes written to <paramref name="destination"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown when the compressed data is corrupt or invalid.</exception>
    public static int Decompress(ReadOnlySpan<byte> source, Span<byte> destination, int decompressedSize)
    {
        if (decompressedSize < 0 || (decompressedSize > 0 && source.Length < 2))
        {
            throw new InvalidDataException("StreamLZ Decompress: invalid decompressed size or source too short.");
        }

        int scratchSize = StreamLZConstants.ScratchSize;

        byte[] scratchArr = ArrayPool<byte>.Shared.Rent(scratchSize);

        try
        {
            fixed (byte* srcPtr = source)
            fixed (byte* dstPtr = destination)
            fixed (byte* scratchPtr = scratchArr)
            {
                new Span<byte>(scratchPtr, scratchSize).Clear();
                return DecompressCore(srcPtr, source.Length, dstPtr, decompressedSize, scratchPtr, scratchSize);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(scratchArr);
        }
    }

    /// <summary>
    /// Decompresses StreamLZ-compressed data using raw pointers.
    /// Caller must ensure <paramref name="dst"/> has at least
    /// <paramref name="dstLen"/> + <see cref="SafeSpace"/> bytes available.
    /// </summary>
    /// <param name="src">Pointer to the compressed source data.</param>
    /// <param name="srcLen">Length in bytes of the compressed source data.</param>
    /// <param name="dst">Pointer to the destination buffer for decompressed output.</param>
    /// <param name="dstLen">Expected decompressed size in bytes.</param>
    /// <returns>Number of bytes written to <paramref name="dst"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown when the compressed data is corrupt or invalid.</exception>
    public static int Decompress(byte* src, int srcLen, byte* dst, int dstLen)
    {
        return Decompress(src, srcLen, dst, dstLen, dstOffset: 0);
    }

    /// <summary>
    /// Decompresses with a pre-filled dictionary. The output buffer at <paramref name="dst"/>
    /// must contain <paramref name="dstOffset"/> bytes of dictionary data before the write
    /// position. LZ back-references can reach into this dictionary.
    /// </summary>
    /// <param name="src">Pointer to the compressed source data.</param>
    /// <param name="srcLen">Length in bytes of the compressed source data.</param>
    /// <param name="dst">Pointer to the output buffer (dictionary + output space).</param>
    /// <param name="dstLen">Number of bytes to decompress (NOT including dictionary).</param>
    /// <param name="dstOffset">Number of dictionary bytes already present at the start of <paramref name="dst"/>.</param>
    /// <returns>Number of decompressed bytes written (starting at <c>dst + dstOffset</c>).</returns>
    public static int Decompress(byte* src, int srcLen, byte* dst, int dstLen, int dstOffset)
    {
        if (dstLen < 0 || (dstLen > 0 && (srcLen < 2 || src == null || dst == null)))
        {
            throw new InvalidDataException("StreamLZ Decompress: invalid parameters (null pointers or insufficient source).");
        }

        int scratchSize = StreamLZConstants.ScratchSize;

        byte[] scratchArr = ArrayPool<byte>.Shared.Rent(scratchSize);
        try
        {
            fixed (byte* scratchPtr = scratchArr)
            {
                new Span<byte>(scratchPtr, scratchSize).Clear();
                if (dstOffset == 0)
                    return DecompressCore(src, srcLen, dst, dstLen, scratchPtr, scratchSize);
                // With dictionary: use SerialDecodeLoop directly, starting at the dictionary offset
                return SerialDecodeLoopWithOffset(src, srcLen, dst, dstLen, dstOffset, scratchPtr, scratchSize);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(scratchArr);
        }
    }

    // ----------------------------------------------------------------
    //  SerialDecodeLoop — shared serial chunk iteration
    // ----------------------------------------------------------------

    /// <summary>
    /// Serial decode loop shared by <see cref="DecompressCore"/> and
    /// <see cref="DecompressCoreFallback"/>. Repeatedly calls <see cref="DecodeStep"/>
    /// to process successive chunks until all expected output bytes are produced
    /// or an error occurs.
    /// </summary>
    /// <returns>
    /// Total number of decompressed bytes written (equal to <paramref name="dstLen"/> on
    /// success), or -1 if decompression fails or trailing compressed bytes remain.
    /// </returns>
    /// <summary>
    /// Serial decode with a dictionary offset. The output buffer has <paramref name="dstOffset"/>
    /// bytes of dictionary at the start. Decompresses <paramref name="dstLen"/> bytes starting
    /// at offset <paramref name="dstOffset"/> in the buffer.
    /// </summary>
    private static int SerialDecodeLoopWithOffset(byte* src, int srcLen, byte* dst, int dstLen,
                                                   int dstOffset, byte* scratch, int scratchSize)
    {
        StreamLZHeader hdr = default;
        int offset = dstOffset;
        int remaining = dstLen;
        int srcUsed = 0, dstUsed = 0;

        while (remaining > 0)
        {
            if (!DecodeStep(ref hdr, ref srcUsed, ref dstUsed,
                            scratch, scratchSize,
                            dst, offset, remaining,
                            src, srcLen))
            {
                throw new InvalidDataException("StreamLZ serial decode step failed.");
            }

            if (srcUsed == 0)
                throw new InvalidDataException("StreamLZ serial decode made no progress.");

            src += srcUsed;
            srcLen -= srcUsed;
            remaining -= dstUsed;
            offset += dstUsed;
        }

        if (srcLen != 0)
            throw new InvalidDataException($"StreamLZ decode: {srcLen} trailing compressed bytes.");

        return dstLen; // return only the decompressed bytes (not including dictionary)
    }

    private static int SerialDecodeLoop(byte* src, int srcLen, byte* dst, int dstLen,
                                        byte* scratch, int scratchSize)
    {
        return SerialDecodeLoopWithOffset(src, srcLen, dst, dstLen, 0, scratch, scratchSize);
    }

    /// <summary>
    /// Core decompression loop that routes to the best strategy (parallel
    /// self-contained, two-phase, or serial) and then falls through to the
    /// serial path when no parallel strategy applies.
    /// </summary>
    private static int DecompressCore(byte* src, int srcLen, byte* dst, int dstLen,
                                       byte* scratch, int scratchSize)
    {
        // Self-contained streams: dispatch to parallel decompressor.
        // Delta prefix bytes at the tail resolve Mode 0 inter-chunk dependency.
        if (srcLen >= 2)
        {
            StreamLZHeader peekHdr = default;
            byte* parseResult = ParseHeader(ref peekHdr, src);
            if (parseResult != null && peekHdr.SelfContained)
            {
                return DecompressCoreParallel(src, srcLen, dst, dstLen);
            }
        }

        // Two-phase parallel: High non-SC with multiple chunks
        if (srcLen >= 2)
        {
            StreamLZHeader peekHdr2 = default;
            byte* pr2 = ParseHeader(ref peekHdr2, src);
            if (pr2 != null && peekHdr2.DecoderType == CodecType.High && dstLen > StreamLZConstants.ChunkSize)
            {
                return DecompressCoreTwoPhase(src, srcLen, dst, dstLen);
            }
        }

        return SerialDecodeLoop(src, srcLen, dst, dstLen, scratch, scratchSize);
    }

    // ----------------------------------------------------------------
    //  DecompressCoreParallel — parallel chunk dispatch for self-contained streams
    // ----------------------------------------------------------------

    private struct ChunkScanInfo
    {
        public int SrcOffset;   // offset into compressed stream for this chunk's block header
        public int SrcSize;     // bytes of compressed data (block hdr + chunk hdr + payload)
        public int DstOffset;   // offset into output buffer
        public int DstSize;     // decompressed size of this chunk
    }

    // ----------------------------------------------------------------
    //  PreScanChunks — shared chunk boundary scanner
    // ----------------------------------------------------------------

    /// <summary>
    /// Walks the compressed stream to determine chunk boundaries, sizes,
    /// and decoder types. Used by both self-contained parallel and two-phase
    /// decompression paths.
    /// </summary>
    /// <param name="src">Pointer to the compressed source data.</param>
    /// <param name="srcLen">Length of compressed source data.</param>
    /// <param name="dstLen">Expected decompressed size.</param>
    /// <param name="chunks">List to populate with chunk scan results.</param>
    /// <param name="decoderType">
    /// On return, the decoder type seen. When <paramref name="requireUniformHighDecoder"/>
    /// is true, returns -2 if a non-High decoder is encountered or if decoder
    /// types are not uniform.
    /// </param>
    /// <param name="requireUniformHighDecoder">
    /// When true, only decoder type 2 (High) is accepted, and all
    /// chunks must use the same type. Returns -2 on mismatch to signal fallback.
    /// When false, all decoder types are accepted.
    /// </param>
    /// <returns>0 on success, -2 on decoder type mismatch (fallback).</returns>
    /// <exception cref="InvalidDataException">Thrown when chunk headers are corrupt.</exception>
    private static int PreScanChunks(
        byte* src, int srcLen, int dstLen,
        List<ChunkScanInfo> chunks, out CodecType decoderType,
        bool requireUniformHighDecoder)
    {
        decoderType = default;
        bool decoderTypeAssigned = false;
        byte* s = src;
        int dstOff = 0, dstRem = dstLen;

        while (dstRem > 0)
        {
            if (s >= src + srcLen)
            {
                throw new InvalidDataException("StreamLZ pre-scan ran past end of compressed source.");
            }
            int qSrcStart = (int)(s - src);
            byte* sBefore = s;

            StreamLZHeader blkHdr = default;
            byte* next = ParseHeader(ref blkHdr, s);
            if (next == null)
            {
                throw new InvalidDataException("StreamLZ pre-scan encountered invalid block header.");
            }
            s = next;

            bool isHigh = blkHdr.DecoderType == CodecType.High ||
                          blkHdr.DecoderType == CodecType.Fast;

            if (requireUniformHighDecoder)
            {
                // Only High (2) is supported for two-phase
                if (blkHdr.DecoderType != CodecType.High)
                {
                    return -2;
                }
                // All chunks must use the same decoder type
                if (!decoderTypeAssigned)
                {
                    decoderType = blkHdr.DecoderType;
                    decoderTypeAssigned = true;
                }
                else if (blkHdr.DecoderType != decoderType)
                {
                    return -2;
                }
            }
            else
            {
                decoderType = blkHdr.DecoderType;
            }

            int dstBytes = (int)Math.Min((uint)(isHigh ? StreamLZConstants.ChunkSize : 0x4000), (uint)dstRem);

            if (blkHdr.Uncompressed)
            {
                s += dstBytes;
            }
            else
            {
                ChunkHeader chunkHeader = default;
                byte* qNext = ParseChunkHeader(ref chunkHeader, s, blkHdr.UseChecksums);
                if (qNext == null)
                {
                    throw new InvalidDataException("StreamLZ pre-scan encountered invalid chunk header.");
                }
                s = qNext + (int)chunkHeader.CompressedSize;
            }

            int qSrcSize = (int)(s - sBefore);
            chunks.Add(new ChunkScanInfo
            {
                SrcOffset = qSrcStart,
                SrcSize = qSrcSize,
                DstOffset = dstOff,
                DstSize = dstBytes
            });

            dstOff += dstBytes;
            dstRem -= dstBytes;
        }

        return 0;
    }

    private static int DecompressCoreParallel(byte* src, int srcLen, byte* dst, int dstLen)
    {
        // Self-contained streams store (numChunks-1)*8 delta prefix bytes at the tail.
        // We need to count chunks first to know where the prefix table starts.

        // Phase 1: Count chunks by scanning headers over the full srcLen.
        // We don't know the prefix size yet, but the prefix bytes are inert —
        // the scan will stop when dstRem hits 0 and never read into the prefix area.
        var chunks = new List<ChunkScanInfo>((dstLen + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize);
        PreScanChunks(src, srcLen, dstLen, chunks, out _, requireUniformHighDecoder: false);

        int numChunks = chunks.Count;
        int prefixBytes = (numChunks - 1) * 8;
        if (prefixBytes > srcLen)
        {
            throw new InvalidDataException("StreamLZ self-contained prefix table exceeds source length.");
        }
        byte* prefixBase = src + srcLen - prefixBytes;

        // Phase 2: Parallel decompress
        int scratchSize = StreamLZConstants.ScratchSize;
        int error = 0;
        nint dstN = (nint)dst, srcN = (nint)src;

        Parallel.For(0, chunks.Count,
            new ParallelOptions { MaxDegreeOfParallelism = Environment.ProcessorCount },
            () => (nint)NativeMemory.AllocZeroed((nuint)scratchSize),
            (i, _, scratchNint) =>
            {
                var q = chunks[i];
                byte* localScratch = (byte*)scratchNint;
                // Clear scratch for reuse between chunks
                new Span<byte>(localScratch, scratchSize).Clear();
                StreamLZHeader hdr = default;
                int srcUsed = 0, dstUsed = 0;
                // Self-contained chunks decode with dstOffset = 0 because they must not
                // depend on earlier chunk output. The encoder appends a tail prefix table
                // for the first 8 bytes of chunks 1..N, which phase 3 restores below.
                bool ok = DecodeStep(ref hdr, ref srcUsed, ref dstUsed,
                    localScratch, scratchSize,
                    (byte*)dstN + q.DstOffset, 0, q.DstSize,
                    (byte*)srcN + q.SrcOffset, q.SrcSize);
                if (!ok || dstUsed != q.DstSize)
                {
                    Interlocked.Exchange(ref error, 1);
                }
                return scratchNint;
            },
            scratchNint => NativeMemory.Free((void*)scratchNint));

        if (error != 0)
        {
            throw new InvalidDataException("StreamLZ parallel decompression encountered an error in one or more chunks.");
        }

        // Phase 3: Restore first 8 bytes of each chunk (except #0) from the tail.
        // Chunk 0 keeps its inline prefix; later chunks borrow those bytes so they
        // can decode independently and then receive the real prefix here.
        for (int i = 0; i < numChunks - 1; i++)
        {
            var q = chunks[i + 1];
            Buffer.MemoryCopy(prefixBase + i * 8, dst + q.DstOffset, 8, 8);
        }

        return dstLen;
    }

    // ----------------------------------------------------------------
    //  DecompressCoreTwoPhase — parallel entropy decode + serial match resolve
    //  for non-self-contained High streams.
    // ----------------------------------------------------------------

    /// <summary>
    /// Phase 1 pre-scan: delegates to <see cref="PreScanChunks"/> with
    /// uniform High decoder enforcement.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int TwoPhasePreScan(
        byte* src, int srcLen, int dstLen,
        List<ChunkScanInfo> chunks, out CodecType decoderType)
    {
        return PreScanChunks(src, srcLen, dstLen, chunks, out decoderType, requireUniformHighDecoder: true);
    }

    /// <summary>
    /// Phase 2: parallel entropy decode (ReadLzTable) for one batch of chunks.
    /// Each chunk's header is parsed and dispatched to the appropriate
    /// Phase1_ProcessChunk, or handled as a special case (uncompressed,
    /// memset, whole-match, stored).
    /// On error, chunks processed before the failure may have already written partial
    /// output. Callers should treat the output buffer as undefined on error return.
    /// </summary>
    private static int TwoPhaseParallelDecode(
        List<ChunkScanInfo> chunks, int batchStart, int batchCount,
        CodecType decoderType, nint srcN, nint dstN,
        ChunkPhase1Result[] phase1Results, nint[] scratchPtrs, int scratchPerChunk)
    {
        Parallel.For(0, batchCount,
            new ParallelOptions { MaxDegreeOfParallelism = batchCount },
            j =>
            {
                int qi = batchStart + j;
                var q = chunks[qi];
                byte* localSrc = (byte*)srcN + q.SrcOffset;
                byte* localDst = (byte*)dstN + q.DstOffset;
                byte* localScratch = (byte*)scratchPtrs[j];

                StreamLZHeader hdr = default;
                byte* headerEnd = ParseHeader(ref hdr, localSrc);
                if (headerEnd == null) throw new InvalidDataException("StreamLZ two-phase parallel decode: invalid block header.");
                byte* payloadSrc = headerEnd;

                if (hdr.Uncompressed)
                {
                    Buffer.MemoryCopy(payloadSrc, localDst, q.DstSize, q.DstSize);
                    phase1Results[j].IsSpecial = true;
                    phase1Results[j].SubChunkCount = 0;
                    return;
                }

                ChunkHeader chunkHeader = default;
                byte* qSrc = ParseChunkHeader(ref chunkHeader, payloadSrc, hdr.UseChecksums);
                if (qSrc == null) throw new InvalidDataException("StreamLZ two-phase parallel decode: invalid chunk header.");

                if (chunkHeader.CompressedSize == 0)
                {
                    phase1Results[j].IsSpecial = true;
                    phase1Results[j].SubChunkCount = 0;
                    if (chunkHeader.WholeMatchDistance != 0)
                    {
                        phase1Results[j].IsWholeMatch = true;
                        phase1Results[j].WholeMatchDistance = chunkHeader.WholeMatchDistance;
                    }
                    else
                    {
                        new Span<byte>(localDst, q.DstSize).Fill((byte)chunkHeader.Checksum);
                    }
                    return;
                }

                if (chunkHeader.CompressedSize == (uint)q.DstSize)
                {
                    Buffer.MemoryCopy(qSrc, localDst, q.DstSize, q.DstSize);
                    phase1Results[j].IsSpecial = true;
                    phase1Results[j].SubChunkCount = 0;
                    return;
                }

                int n;
                n = High.LzDecoder.Phase1_ProcessChunk(
                    localDst, localDst + q.DstSize, (byte*)dstN,
                    qSrc, qSrc + (int)chunkHeader.CompressedSize,
                    localScratch, localScratch + scratchPerChunk,
                    EntropyDecoder.High_DecodeBytes,
                    ref phase1Results[j]);

            });

        return 0;
    }

    /// <summary>
    /// Phase 3: serial ProcessLzRuns for one batch of chunks, resolving
    /// match copies that depend on previously-decoded output. Also handles
    /// deferred whole-match copies.
    /// </summary>
    private static int TwoPhaseSerialResolve(
        List<ChunkScanInfo> chunks, int batchStart, int batchCount,
        CodecType decoderType, byte* dst,
        ChunkPhase1Result[] phase1Results, nint[] scratchPtrs, int scratchSize)
    {
        for (int j = 0; j < batchCount; j++)
        {
            ref ChunkPhase1Result r = ref phase1Results[j];
            int qi = batchStart + j;

            if (r.IsSpecial)
            {
                if (r.IsWholeMatch)
                {
                    var q = chunks[qi];
                    if (r.WholeMatchDistance > (uint)q.DstOffset)
                    {
                        throw new InvalidDataException("StreamLZ two-phase whole-match distance exceeds output offset.");
                    }
                    CopyWholeMatch(dst + q.DstOffset, r.WholeMatchDistance, q.DstSize);
                }
                continue;
            }

            for (int s = 0; s < r.SubChunkCount; s++)
            {
                ref SubChunkPhase1Result sub = ref (s == 0 ? ref r.Sub0 : ref r.Sub1);
                if (!sub.IsLz)
                {
                    continue;
                }

                byte* subDst = dst + sub.DstOffset;
                byte* subScratch = (byte*)scratchPtrs[j] + s * scratchSize;

                nint subScratchUsage = Math.Min(
                    StreamLZConstants.CalculateScratchSize(sub.DstSize),
                    scratchSize);
                bool lzOk = High.LzDecoder.ProcessLzRuns(
                    sub.Mode, subDst, sub.DstSize, sub.DstOffset,
                    (HighLzTable*)subScratch,
                    subScratch + subScratchUsage, subScratch + scratchSize);

                if (!lzOk)
                {
                    throw new InvalidDataException("StreamLZ two-phase ProcessLzRuns failed.");
                }
            }
        }

        return 0;
    }

    /// <summary>
    /// On error, chunks processed before the failure may have already written partial
    /// output. Callers should treat the output buffer as undefined on error return.
    /// </summary>
    private static int DecompressCoreTwoPhase(byte* src, int srcLen, byte* dst, int dstLen)
    {
        // Phase 1: Pre-scan chunk boundaries.
        var chunks = new List<ChunkScanInfo>((dstLen + StreamLZConstants.ChunkSize - 1) / StreamLZConstants.ChunkSize);
        int preScanResult = TwoPhasePreScan(src, srcLen, dstLen, chunks, out CodecType decoderType);
        if (preScanResult == -2)
        {
            return DecompressCoreFallback(src, srcLen, dst, dstLen);
        }

        int numChunks = chunks.Count;
        if (numChunks <= 1)
        {
            return DecompressCoreFallback(src, srcLen, dst, dstLen);
        }

        // Batched two-phase: process chunks in batches of batchSize.
        // Each batch: Phase 2 (parallel ReadLzTable) -> Phase 3 (serial ProcessLzRuns).
        // Scratch is reused across batches, limiting memory to batchSize x 2 x 442KB.
        int batchSize = Environment.ProcessorCount;
        int scratchSize = StreamLZConstants.ScratchSize;
        int scratchPerChunk = scratchSize * 2; // 2 sub-chunks per chunk

        var phase1Results = new ChunkPhase1Result[batchSize];
        nint[] scratchPtrs = new nint[batchSize];

        for (int i = 0; i < batchSize; i++)
        {
            scratchPtrs[i] = (nint)NativeMemory.AllocZeroed((nuint)scratchPerChunk);
        }

        try
        {
            nint srcN = (nint)src, dstN = (nint)dst;

            for (int batchStart = 0; batchStart < numChunks; batchStart += batchSize)
            {
                int batchEnd = Math.Min(batchStart + batchSize, numChunks);
                int batchCount = batchEnd - batchStart;

                // Clear Phase 2 results and scratch for this batch.
                for (int j = 0; j < batchCount; j++)
                {
                    phase1Results[j] = default;
                    new Span<byte>((byte*)scratchPtrs[j], scratchPerChunk).Clear();
                }

                // Phase 2: Parallel entropy decode for this batch.
                TwoPhaseParallelDecode(chunks, batchStart, batchCount,
                    decoderType, srcN, dstN, phase1Results, scratchPtrs, scratchPerChunk);

                // Phase 3: Serial ProcessLzRuns for this batch.
                TwoPhaseSerialResolve(chunks, batchStart, batchCount,
                    decoderType, dst, phase1Results, scratchPtrs, scratchSize);
            }

            return dstLen;
        }
        finally
        {
            for (int i = 0; i < batchSize; i++)
            {
                NativeMemory.Free((void*)scratchPtrs[i]);
            }
        }
    }

    /// <summary>
    /// Fallback to the standard serial decompression path.
    /// Used when two-phase cannot handle the stream (e.g., non-High, single chunk).
    /// </summary>
    private static int DecompressCoreFallback(byte* src, int srcLen, byte* dst, int dstLen)
    {
        int scratchSize = StreamLZConstants.ScratchSize;
        byte* scratch = (byte*)NativeMemory.AllocZeroed((nuint)scratchSize);
        try
        {
            return SerialDecodeLoop(src, srcLen, dst, dstLen, scratch, scratchSize);
        }
        finally
        {
            NativeMemory.Free(scratch);
        }
    }
}
