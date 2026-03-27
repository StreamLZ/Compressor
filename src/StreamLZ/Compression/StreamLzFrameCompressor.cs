// StreamLzFrameCompressor.cs — Stream-based framed compression with sliding window.

using System.Buffers;
using StreamLZ.Common;
using StreamLZ.Compression;

namespace StreamLZ;

/// <summary>
/// Stream-based compressor that wraps StreamLZ block compression in the SLZ1 frame format.
/// Uses a sliding window so blocks can reference data from previous blocks, giving
/// better compression ratio than self-contained mode while supporting files of any size.
/// </summary>
internal static class StreamLzFrameCompressor
{
    /// <summary>
    /// Compresses data from <paramref name="input"/> to <paramref name="output"/> using the SLZ1 frame format.
    /// Each block can reference up to <paramref name="windowSize"/> bytes of previously compressed data
    /// for better compression ratio.
    /// </summary>
    /// <param name="input">Source stream to read uncompressed data from.</param>
    /// <param name="output">Destination stream to write compressed data to.</param>
    /// <param name="codec">Compression codec (Fast or High).</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="contentSize">Known content size for the frame header, or -1 if unknown.</param>
    /// <param name="useContentChecksum">Whether to write an XXH32 content checksum after the last block.</param>
    /// <param name="windowSize">Sliding window size in bytes (default 4MB, max 1GB). Larger values
    /// improve ratio but use more memory. Both compressor and decompressor need this much memory.</param>
    /// <param name="selfContained">When true, each chunk is independently decompressible (enables parallel decompression).</param>
    /// <returns>Total number of compressed bytes written to <paramref name="output"/>.</returns>
    public static long Compress(Stream input, Stream output,
        CodecType codec = CodecType.High, int level = 4,
        long contentSize = -1, bool useContentChecksum = false,
        int windowSize = FrameConstants.DefaultWindowSize,
        bool selfContained = false)
    {
        int blockSize = FrameConstants.DefaultBlockSize;
        windowSize = Math.Clamp(windowSize, blockSize, FrameConstants.MaxWindowSize);

        // Write frame header
        Span<byte> headerBuf = stackalloc byte[FrameConstants.MaxHeaderSize];
        int headerSize = FrameSerializer.WriteHeader(headerBuf, (int)codec, level,
            blockSize, contentSize, useContentChecksum);
        output.Write(headerBuf[..headerSize]);
        long totalWritten = headerSize;

        // Incremental XXH32 checksum over all uncompressed data (if enabled)
        System.IO.Hashing.XxHash32? contentHasher = useContentChecksum ? new() : null;

        int numThreads = StreamLZCompressor.CalculateMaxThreads(
            contentSize > 0 ? (int)Math.Min(contentSize, int.MaxValue) : 100_000_000, level);

        // Large-chunk path: read many chunks, compress as one block using the
        // parallel in-memory API. Each block is independently decompressible.
        // Used for self-contained levels (L6-L8) and all Fast levels (L1-L5).
        // Non-SC High levels (L9-L11) need cross-chunk references and use the
        // serial path below.
        bool useLargeChunks = selfContained || codec == CodecType.Fast;

        if (useLargeChunks)
        {
            int chunkSize = Math.Min(numThreads * StreamLZConstants.ChunkSize * 4, 256 * 1024 * 1024);
            // Double-buffered: read next chunk while compressing current one.
            byte[][] srcBufs = [
                ArrayPool<byte>.Shared.Rent(chunkSize),
                ArrayPool<byte>.Shared.Rent(chunkSize)
            ];
            int compressBound = StreamLZCompressor.GetCompressBound(chunkSize);
            byte[] dstBuf = ArrayPool<byte>.Shared.Rent(compressBound + StreamLZConstants.CompressBufferPadding);
            byte[] blockHeaderBuf = new byte[8];

            Task<int>? pendingReadTask = null;
            try
            {
                int currentBuf = 0;
                // Kick off first read
                int bytesRead = ReadFully(input, srcBufs[0], 0, chunkSize);

                while (bytesRead > 0)
                {
                    int currentBytes = bytesRead;
                    int compressBuf = currentBuf;
                    int nextBuf = 1 - currentBuf;

                    // Hash uncompressed data for content checksum
                    contentHasher?.Append(srcBufs[compressBuf].AsSpan(0, currentBytes));

                    // Start reading the next chunk in background while we compress
                    pendingReadTask = Task.Run(() => ReadFully(input, srcBufs[nextBuf], 0, chunkSize));

                    // Compress current chunk
                    int compressedSize;
                    unsafe
                    {
                        fixed (byte* pSrc = srcBufs[compressBuf])
                        fixed (byte* pDst = dstBuf)
                        {
                            compressedSize = StreamLZCompressor.Compress(
                                pSrc, currentBytes, pDst, compressBound,
                                codec, level, numThreads,
                                selfContained: selfContained, twoPhase: false);
                        }
                    }

                    // Write compressed output (sequential, no overlap needed —
                    // write is fast relative to compress)
                    if (compressedSize > 0 && compressedSize < currentBytes)
                    {
                        FrameSerializer.WriteBlockHeader(blockHeaderBuf, compressedSize, currentBytes, isUncompressed: false);
                        output.Write(blockHeaderBuf);
                        output.Write(dstBuf, 0, compressedSize);
                        totalWritten += 8 + compressedSize;
                    }
                    else
                    {
                        FrameSerializer.WriteBlockHeader(blockHeaderBuf, currentBytes, currentBytes, isUncompressed: true);
                        output.Write(blockHeaderBuf);
                        output.Write(srcBufs[compressBuf], 0, currentBytes);
                        totalWritten += 8 + currentBytes;
                    }

                    // Wait for the background read to complete
                    bytesRead = pendingReadTask.GetAwaiter().GetResult();
                    pendingReadTask = null;
                    currentBuf = nextBuf;
                }

                byte[] endMark = new byte[4];
                FrameSerializer.WriteEndMark(endMark);
                output.Write(endMark, 0, 4);
                totalWritten += 4;

                // Write XXH32 content checksum if enabled
                if (contentHasher != null)
                {
                    Span<byte> checksumBuf = stackalloc byte[4];
                    contentHasher.GetHashAndReset(checksumBuf);
                    output.Write(checksumBuf);
                    totalWritten += 4;
                }

                return totalWritten;
            }
            finally
            {
                // Wait for background read to finish before returning buffers to the pool
                if (pendingReadTask != null)
                {
                    try { pendingReadTask.GetAwaiter().GetResult(); } catch { /* already handling an exception */ }
                }
                ArrayPool<byte>.Shared.Return(srcBufs[0]);
                ArrayPool<byte>.Shared.Return(srcBufs[1]);
                ArrayPool<byte>.Shared.Return(dstBuf);
            }
        }

        // Serial path for non-SC High levels (L9-L11): one block at a time with
        // sliding window for cross-block dictionary references.
        {
            int windowBufSize = windowSize + blockSize;
            byte[] windowBuf = ArrayPool<byte>.Shared.Rent(windowBufSize);
            int compressBound = StreamLZCompressor.GetCompressBound(blockSize);
            byte[] compressedBuf = ArrayPool<byte>.Shared.Rent(compressBound + StreamLZConstants.CompressBufferPadding);
            byte[] blockHeaderBuf = new byte[8];

            try
            {
                int dictBytes = 0;

                while (true)
                {
                    int blockBytes = ReadFully(input, windowBuf, dictBytes, blockSize);
                    if (blockBytes == 0)
                        break;

                    // Hash uncompressed data for content checksum
                    contentHasher?.Append(windowBuf.AsSpan(dictBytes, blockBytes));

                    int compressedSize;
                    unsafe
                    {
                        fixed (byte* pWindow = windowBuf)
                        fixed (byte* pCompressed = compressedBuf)
                        {
                            compressedSize = StreamLZCompressor.CompressBlock(
                                (int)codec, pWindow + dictBytes, pCompressed, blockBytes, level,
                                compressOpts: null, srcWindowBase: pWindow);
                        }
                    }

                    if (compressedSize > 0 && compressedSize < blockBytes)
                    {
                        FrameSerializer.WriteBlockHeader(blockHeaderBuf, compressedSize, blockBytes, isUncompressed: false);
                        output.Write(blockHeaderBuf);
                        output.Write(compressedBuf, 0, compressedSize);
                        totalWritten += 8 + compressedSize;
                    }
                    else
                    {
                        FrameSerializer.WriteBlockHeader(blockHeaderBuf, blockBytes, blockBytes, isUncompressed: true);
                        output.Write(blockHeaderBuf);
                        output.Write(windowBuf, dictBytes, blockBytes);
                        totalWritten += 8 + blockBytes;
                    }

                    int totalUsed = dictBytes + blockBytes;
                    if (totalUsed > windowSize)
                    {
                        int keep = windowSize;
                        int discard = totalUsed - keep;
                        Buffer.BlockCopy(windowBuf, discard, windowBuf, 0, keep);
                        dictBytes = keep;
                    }
                    else
                    {
                        dictBytes = totalUsed;
                    }
                }

                FrameSerializer.WriteEndMark(blockHeaderBuf);
                output.Write(blockHeaderBuf, 0, 4);
                totalWritten += 4;

                // Write XXH32 content checksum if enabled
                if (contentHasher != null)
                {
                    Span<byte> checksumBuf = stackalloc byte[4];
                    contentHasher.GetHashAndReset(checksumBuf);
                    output.Write(checksumBuf);
                    totalWritten += 4;
                }

                return totalWritten;
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(windowBuf);
                ArrayPool<byte>.Shared.Return(compressedBuf);
            }
        }
    }

    /// <summary>
    /// Asynchronously compresses data from <paramref name="input"/> to <paramref name="output"/>
    /// <para><b>Limitation:</b> The async path always uses serial single-block compression
    /// (no parallel large-chunk mode, no read-ahead pipeline). For maximum throughput on
    /// large files, use the synchronous <see cref="Compress"/> method instead.</para>
    /// using the SLZ1 frame format with cancellation support.
    /// </summary>
    /// <param name="input">Source stream to read uncompressed data from.</param>
    /// <param name="output">Destination stream to write compressed data to.</param>
    /// <param name="codec">Compression codec (Fast or High).</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="contentSize">Known content size for the frame header, or -1 if unknown.</param>
    /// <param name="useContentChecksum">Whether to write an XXH32 content checksum after the last block.</param>
    /// <param name="windowSize">Sliding window size in bytes (default 4MB, max 1GB). Larger values
    /// improve ratio but use more memory. Both compressor and decompressor need this much memory.</param>
    /// <param name="selfContained">When true, each chunk is independently decompressible (enables parallel decompression).</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total number of compressed bytes written to <paramref name="output"/>.</returns>
    public static async Task<long> CompressAsync(Stream input, Stream output,
        CodecType codec = CodecType.High, int level = 4,
        long contentSize = -1, bool useContentChecksum = false,
        int windowSize = FrameConstants.DefaultWindowSize,
        bool selfContained = false,
        CancellationToken cancellationToken = default)
    {
        int blockSize = FrameConstants.DefaultBlockSize;
        windowSize = Math.Clamp(windowSize, blockSize, FrameConstants.MaxWindowSize);

        // Write frame header
        byte[] headerBuf = new byte[FrameConstants.MaxHeaderSize];
        int headerSize = FrameSerializer.WriteHeader(headerBuf, (int)codec, level,
            blockSize, contentSize, useContentChecksum);
        await output.WriteAsync(headerBuf.AsMemory(0, headerSize), cancellationToken).ConfigureAwait(false);
        long totalWritten = headerSize;

        int windowBufSize = windowSize + blockSize;
        byte[] windowBuf = ArrayPool<byte>.Shared.Rent(windowBufSize);
        int compressBound = StreamLZCompressor.GetCompressBound(blockSize);
        byte[] compressedBuf = ArrayPool<byte>.Shared.Rent(compressBound + StreamLZConstants.CompressBufferPadding);
        byte[] blockHeaderBuf = new byte[8];

        // Incremental XXH32 checksum over all uncompressed data (if enabled)
        System.IO.Hashing.XxHash32? contentHasher = useContentChecksum ? new() : null;

        try
        {
            int dictBytes = 0;

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();

                int blockBytes = await ReadFullyAsync(input, windowBuf, dictBytes, blockSize, cancellationToken).ConfigureAwait(false);
                if (blockBytes == 0)
                    break;

                // Hash uncompressed data for content checksum
                contentHasher?.Append(windowBuf.AsSpan(dictBytes, blockBytes));

                // Compression is CPU-bound — run synchronously on the current thread
                int compressedSize;
                CompressOptions? opts = selfContained ? StreamLZCompressor.GetDefaultCompressOpts(level) : null;
                if (opts != null) opts.SelfContained = true;
                unsafe
                {
                    fixed (byte* pWindow = windowBuf)
                    fixed (byte* pCompressed = compressedBuf)
                    {
                        byte* blockStart = pWindow + dictBytes;
                        byte* windowBase = pWindow;
                        compressedSize = StreamLZCompressor.CompressBlock(
                            (int)codec, blockStart, pCompressed, blockBytes, level,
                            compressOpts: opts, srcWindowBase: windowBase);
                    }
                }

                if (compressedSize > 0 && compressedSize < blockBytes)
                {
                    FrameSerializer.WriteBlockHeader(blockHeaderBuf, compressedSize, blockBytes, isUncompressed: false);
                    await output.WriteAsync(blockHeaderBuf, cancellationToken).ConfigureAwait(false);
                    await output.WriteAsync(compressedBuf.AsMemory(0, compressedSize), cancellationToken).ConfigureAwait(false);
                    totalWritten += 8 + compressedSize;
                }
                else
                {
                    FrameSerializer.WriteBlockHeader(blockHeaderBuf, blockBytes, blockBytes, isUncompressed: true);
                    await output.WriteAsync(blockHeaderBuf, cancellationToken).ConfigureAwait(false);
                    await output.WriteAsync(windowBuf.AsMemory(dictBytes, blockBytes), cancellationToken).ConfigureAwait(false);
                    totalWritten += 8 + blockBytes;
                }

                int totalUsed = dictBytes + blockBytes;
                if (totalUsed > windowSize)
                {
                    int keep = windowSize;
                    int discard = totalUsed - keep;
                    Buffer.BlockCopy(windowBuf, discard, windowBuf, 0, keep);
                    dictBytes = keep;
                }
                else
                {
                    dictBytes = totalUsed;
                }
            }

            FrameSerializer.WriteEndMark(blockHeaderBuf);
            await output.WriteAsync(blockHeaderBuf.AsMemory(0, 4), cancellationToken).ConfigureAwait(false);
            totalWritten += 4;

            // Write XXH32 content checksum if enabled
            if (contentHasher != null)
            {
                byte[] checksumBuf = new byte[4];
                contentHasher.GetHashAndReset(checksumBuf);
                await output.WriteAsync(checksumBuf, cancellationToken).ConfigureAwait(false);
                totalWritten += 4;
            }

            return totalWritten;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(windowBuf);
            ArrayPool<byte>.Shared.Return(compressedBuf);
        }
    }

    /// <summary>
    /// Compresses a file to another file using the SLZ1 frame format.
    /// </summary>
    public static long CompressFile(string inputPath, string outputPath,
        CodecType codec = CodecType.High, int level = 4)
    {
        const int ioBufSize = 1024 * 1024;
        using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, ioBufSize, FileOptions.SequentialScan);
        using var output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, ioBufSize, FileOptions.SequentialScan);
        return Compress(input, output, codec, level, contentSize: input.Length);
    }

    private static async Task<int> ReadFullyAsync(Stream stream, byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        int totalRead = 0;
        while (totalRead < count)
        {
            int bytesRead = await stream.ReadAsync(buffer.AsMemory(offset + totalRead, count - totalRead), cancellationToken).ConfigureAwait(false);
            if (bytesRead == 0)
                break;
            totalRead += bytesRead;
        }
        return totalRead;
    }

    /// <summary>
    /// Reads exactly <paramref name="count"/> bytes from the stream, or fewer at end of stream.
    /// </summary>
    private static int ReadFully(Stream stream, byte[] buffer, int offset, int count)
    {
        int totalRead = 0;
        while (totalRead < count)
        {
            int bytesRead = stream.Read(buffer, offset + totalRead, count - totalRead);
            if (bytesRead == 0)
                break;
            totalRead += bytesRead;
        }
        return totalRead;
    }
}
