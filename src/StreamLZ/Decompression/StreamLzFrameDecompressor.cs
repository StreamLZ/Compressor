// StreamLzFrameDecompressor.cs — Stream-based framed decompression with sliding window.

using System.Buffers;
using System.Buffers.Binary;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;

namespace StreamLZ;

/// <summary>
/// Stream-based decompressor that reads the SLZ1 frame format and produces uncompressed output.
/// Maintains a sliding window of decoded output so blocks can reference data from previous blocks.
/// </summary>
internal static class StreamLzFrameDecompressor
{
    /// <summary>
    /// Decompresses data from <paramref name="input"/> to <paramref name="output"/> using the SLZ1 frame format.
    /// </summary>
    /// <param name="input">Source stream containing SLZ1-framed compressed data.</param>
    /// <param name="output">Destination stream to write decompressed data to.</param>
    /// <param name="windowSize">Sliding window size for back-references (default 4MB, must match compressor).</param>
    /// <returns>Total number of decompressed bytes written to <paramref name="output"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown if the frame header is invalid or data is corrupt.</exception>
    public static long Decompress(Stream input, Stream output,
        int windowSize = FrameConstants.DefaultWindowSize)
    {
        // Read and parse frame header
        byte[] headerBuf = new byte[FrameConstants.MaxHeaderSize];
        int headerBytesRead = ReadFully(input, headerBuf, 0, FrameConstants.MaxHeaderSize);
        if (headerBytesRead < FrameConstants.MinHeaderSize)
            throw new InvalidDataException("StreamLZ frame header too short.");

        if (!FrameSerializer.TryReadHeader(headerBuf, out FrameHeader header))
            throw new InvalidDataException("Invalid StreamLZ frame header (bad magic number or version).");

        // Push back over-read bytes for non-seekable streams
        int overRead = headerBytesRead - header.HeaderSize;
        Memory<byte> overReadMem = Memory<byte>.Empty;
        if (overRead > 0)
        {
            if (input.CanSeek)
            {
                input.Seek(-overRead, SeekOrigin.Current);
            }
            else
            {
                overReadMem = new byte[overRead];
                headerBuf.AsSpan(header.HeaderSize, overRead).CopyTo(overReadMem.Span);
            }
        }

        int blockSize = header.BlockSize;
        windowSize = Math.Clamp(windowSize, blockSize, FrameConstants.MaxWindowSize);

        int initialCompBufSize = StreamLZCompressor.GetCompressBound(blockSize) + StreamLZConstants.CompressBufferPadding;
        // Double-buffered I/O for large blocks: read block N+1 while decompressing N,
        // write block N-1 while decompressing N. Two sets of compressed+decompressed buffers.
        byte[][] compBufs = [
            ArrayPool<byte>.Shared.Rent(initialCompBufSize),
            ArrayPool<byte>.Shared.Rent(initialCompBufSize)
        ];
        byte[][] decompBufs = [null!, null!]; // rented on first large block
        // Window buffer for small serial blocks (L9-L11 with cross-block references).
        int windowBufSize = windowSize + blockSize + StreamLZDecoder.SafeSpace * 2;
        byte[] windowBuf = ArrayPool<byte>.Shared.Rent(windowBufSize);
        byte[] blockHeaderBuf = new byte[8];
        Task? pendingWrite = null;

        // Incremental XXH32 checksum over all decompressed data (if frame has checksum flag)
        bool verifyChecksum = (header.Flags & FrameFlags.ContentChecksum) != 0;
        System.IO.Hashing.XxHash32? contentHasher = verifyChecksum ? new() : null;

        try
        {
            long totalDecompressed = 0;
            int dictBytes = 0;
            int currentBuf = 0;
            int pendingWriteSize = 0;
            int pendingWriteBuf = -1;
            int headerRead = 0;

            while (true)
            {
                headerRead = ReadWithOverRead(ref overReadMem, input, blockHeaderBuf, 0, 8);
                if (headerRead >= 4 && BinaryPrimitives.ReadUInt32LittleEndian(blockHeaderBuf) == 0)
                    break;
                if (headerRead < 8)
                    throw new InvalidDataException("Unexpected end of stream reading block header.");

                if (!FrameSerializer.TryReadBlockHeader(blockHeaderBuf, out int compressedSize, out int decompressedSize, out bool isUncompressed))
                    throw new InvalidDataException("Invalid block header.");

                if (compressedSize == 0)
                    break;

                // Guard against malicious streams claiming enormous block sizes.
                if (decompressedSize > FrameConstants.MaxDecompressedBlockSize)
                    throw new InvalidDataException($"Block decompressed size {decompressedSize} exceeds maximum {FrameConstants.MaxDecompressedBlockSize}.");
                if (compressedSize > FrameConstants.MaxDecompressedBlockSize)
                    throw new InvalidDataException($"Block compressed size {compressedSize} exceeds maximum {FrameConstants.MaxDecompressedBlockSize}.");

                bool isLargeBlock = decompressedSize > blockSize;

                if (isLargeBlock)
                {
                    // Ensure buffers are large enough for this block
                    int neededComp = compressedSize + StreamLZConstants.CompressBufferPadding;
                    if (neededComp > compBufs[currentBuf].Length)
                    {
                        ArrayPool<byte>.Shared.Return(compBufs[currentBuf]);
                        compBufs[currentBuf] = ArrayPool<byte>.Shared.Rent(neededComp);
                    }
                    int neededDecomp = decompressedSize + StreamLZDecoder.SafeSpace * 2;
                    if (decompBufs[currentBuf] == null || neededDecomp > decompBufs[currentBuf].Length)
                    {
                        if (decompBufs[currentBuf] != null) ArrayPool<byte>.Shared.Return(decompBufs[currentBuf]);
                        decompBufs[currentBuf] = ArrayPool<byte>.Shared.Rent(neededDecomp);
                    }

                    // Read compressed data into current buffer
                    if (isUncompressed)
                    {
                        if (ReadWithOverRead(ref overReadMem, input, decompBufs[currentBuf], 0, decompressedSize) < decompressedSize)
                            throw new InvalidDataException("Unexpected end of stream in uncompressed block.");
                    }
                    else
                    {
                        if (ReadWithOverRead(ref overReadMem, input, compBufs[currentBuf], 0, compressedSize) < compressedSize)
                            throw new InvalidDataException("Unexpected end of stream in compressed block.");

                        // Decompress while previous write completes in background
                        unsafe
                        {
                            fixed (byte* pDecomp = decompBufs[currentBuf])
                            fixed (byte* pCompressed = compBufs[currentBuf])
                            {
                                int result = StreamLZDecoder.Decompress(
                                    pCompressed, compressedSize,
                                    pDecomp, decompressedSize, dstOffset: 0);
                                if (result < 0)
                                    throw new InvalidDataException("Block decompression failed.");
                                decompressedSize = result;
                            }
                        }
                    }

                    // Wait for previous write to finish before starting a new one
                    if (pendingWrite != null)
                    {
                        pendingWrite.GetAwaiter().GetResult();
                        pendingWrite = null;
                    }

                    // Hash decompressed data before writing
                    contentHasher?.Append(decompBufs[currentBuf].AsSpan(0, decompressedSize));

                    // Start async write of current decompressed data
                    int writeSize = decompressedSize;
                    int writeBufIdx = currentBuf;
                    pendingWrite = Task.Run(() =>
                    {
                        // Write in 1MB chunks for optimal NVMe throughput
                        int offset = 0;
                        while (offset < writeSize)
                        {
                            int chunk = Math.Min(1024 * 1024, writeSize - offset);
                            output.Write(decompBufs[writeBufIdx], offset, chunk);
                            offset += chunk;
                        }
                    });
                    pendingWriteSize = writeSize;
                    pendingWriteBuf = writeBufIdx;

                    totalDecompressed += decompressedSize;
                    dictBytes = 0;
                    currentBuf = 1 - currentBuf; // swap to other buffer
                }
                else
                {
                    // Flush any pending large-block write before processing a serial block
                    if (pendingWrite != null)
                    {
                        pendingWrite.GetAwaiter().GetResult();
                        pendingWrite = null;
                    }

                    // Small serial block: decompress with sliding window dictionary context
                    if (isUncompressed)
                    {
                        if (ReadWithOverRead(ref overReadMem, input, windowBuf, dictBytes, decompressedSize) < decompressedSize)
                            throw new InvalidDataException("Unexpected end of stream in uncompressed block.");
                    }
                    else
                    {
                        if (ReadWithOverRead(ref overReadMem, input, compBufs[0], 0, compressedSize) < compressedSize)
                            throw new InvalidDataException("Unexpected end of stream in compressed block.");

                        unsafe
                        {
                            fixed (byte* pWindow = windowBuf)
                            fixed (byte* pCompressed = compBufs[0])
                            {
                                int result = StreamLZDecoder.Decompress(
                                    pCompressed, compressedSize,
                                    pWindow, decompressedSize, dstOffset: dictBytes);
                                if (result < 0)
                                    throw new InvalidDataException("Block decompression failed.");
                                decompressedSize = result;
                            }
                        }
                    }

                    // Hash decompressed data before writing
                    contentHasher?.Append(windowBuf.AsSpan(dictBytes, decompressedSize));

                    output.Write(windowBuf, dictBytes, decompressedSize);
                    totalDecompressed += decompressedSize;

                    // Slide the window
                    int totalUsed = dictBytes + decompressedSize;
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
            }

            // Flush any pending background write
            if (pendingWrite != null)
            {
                pendingWrite.GetAwaiter().GetResult();
            }

            // Verify XXH32 content checksum if present.
            // The checksum follows the 4-byte end mark. We read 8 bytes for the block header,
            // so the checksum may already be in blockHeaderBuf[4..8]. If not, read it now.
            if (verifyChecksum && contentHasher != null)
            {
                // If we only got the 4-byte end mark, read the remaining 4 checksum bytes
                if (headerRead < 8)
                {
                    if (ReadWithOverRead(ref overReadMem, input, blockHeaderBuf, 4, 4) < 4)
                        throw new InvalidDataException("Unexpected end of stream reading content checksum.");
                }

                Span<byte> computed = stackalloc byte[4];
                contentHasher.GetHashAndReset(computed);

                if (!computed.SequenceEqual(blockHeaderBuf.AsSpan(4, 4)))
                    throw new InvalidDataException("Content checksum mismatch: data may be corrupted.");
            }

            return totalDecompressed;
        }
        finally
        {
            // Observe pending write task to prevent unobserved exceptions
            if (pendingWrite != null)
            {
                try { pendingWrite.GetAwaiter().GetResult(); } catch { /* already handling an exception */ }
            }
            for (int i = 0; i < 2; i++)
            {
                ArrayPool<byte>.Shared.Return(compBufs[i]);
                if (decompBufs[i] != null) ArrayPool<byte>.Shared.Return(decompBufs[i]);
            }
            ArrayPool<byte>.Shared.Return(windowBuf);
        }
    }

    /// <summary>
    /// Asynchronously decompresses SLZ1-framed data with cancellation support.
    /// </summary>
    /// <param name="input">Source stream containing SLZ1-framed compressed data.</param>
    /// <param name="output">Destination stream to write decompressed data to.</param>
    /// <param name="windowSize">Sliding window size for back-references (default 4MB, must match compressor).</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total number of decompressed bytes written to <paramref name="output"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown if the frame header is invalid or data is corrupt.</exception>
    public static async Task<long> DecompressAsync(Stream input, Stream output,
        int windowSize = FrameConstants.DefaultWindowSize,
        CancellationToken cancellationToken = default)
    {
        byte[] headerBuf = new byte[FrameConstants.MaxHeaderSize];
        int headerBytesRead = await ReadFullyAsync(input, headerBuf, 0, FrameConstants.MaxHeaderSize, cancellationToken).ConfigureAwait(false);
        if (headerBytesRead < FrameConstants.MinHeaderSize)
            throw new InvalidDataException("StreamLZ frame header too short.");

        if (!FrameSerializer.TryReadHeader(headerBuf, out FrameHeader header))
            throw new InvalidDataException("Invalid StreamLZ frame header (bad magic number or version).");

        int overRead = headerBytesRead - header.HeaderSize;
        Memory<byte> overReadMem = Memory<byte>.Empty;
        if (overRead > 0)
        {
            if (input.CanSeek)
            {
                input.Seek(-overRead, SeekOrigin.Current);
            }
            else
            {
                overReadMem = new byte[overRead];
                headerBuf.AsSpan(header.HeaderSize, overRead).CopyTo(overReadMem.Span);
            }
        }

        int blockSize = header.BlockSize;
        windowSize = Math.Clamp(windowSize, blockSize, FrameConstants.MaxWindowSize);

        byte[] compressedBuf = ArrayPool<byte>.Shared.Rent(StreamLZCompressor.GetCompressBound(blockSize) + StreamLZConstants.CompressBufferPadding);
        // Window buffer for sliding-window dictionary context (matches sync path)
        int windowBufSize = windowSize + blockSize + StreamLZDecoder.SafeSpace * 2;
        byte[] windowBuf = ArrayPool<byte>.Shared.Rent(windowBufSize);
        byte[] blockHeaderBuf = new byte[8];

        // Incremental XXH32 checksum over all decompressed data (if frame has checksum flag)
        bool verifyChecksumAsync = (header.Flags & FrameFlags.ContentChecksum) != 0;
        System.IO.Hashing.XxHash32? asyncContentHasher = verifyChecksumAsync ? new() : null;

        try
        {
            long totalDecompressed = 0;
            int dictBytes = 0;

            // Consume any over-read bytes from the frame header into the first block header read.
            // After this, all subsequent reads go directly to the stream via ReadFullyAsync.
            int firstHeaderRead = 0;
            if (overReadMem.Length > 0)
            {
                int fromOverRead = Math.Min(8, overReadMem.Length);
                overReadMem.Span[..fromOverRead].CopyTo(blockHeaderBuf);
                firstHeaderRead = fromOverRead;
                overReadMem = overReadMem[fromOverRead..];
            }
            if (firstHeaderRead < 8)
            {
                firstHeaderRead += await ReadFullyAsync(input, blockHeaderBuf, firstHeaderRead, 8 - firstHeaderRead, cancellationToken).ConfigureAwait(false);
            }
            bool firstBlock = true;

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();

                int headerRead;
                if (firstBlock)
                {
                    headerRead = firstHeaderRead;
                    firstBlock = false;
                }
                else
                {
                    headerRead = await ReadFullyAsync(input, blockHeaderBuf, 0, 8, cancellationToken).ConfigureAwait(false);
                }

                if (headerRead >= 4 && BinaryPrimitives.ReadUInt32LittleEndian(blockHeaderBuf) == 0)
                    break;
                if (headerRead < 8)
                    throw new InvalidDataException("Unexpected end of stream reading block header.");

                if (!FrameSerializer.TryReadBlockHeader(blockHeaderBuf, out int compressedSize, out int decompressedSize, out bool isUncompressed))
                    throw new InvalidDataException("Invalid block header.");

                if (compressedSize == 0)
                    break;

                // Guard against malicious streams claiming enormous block sizes.
                if (decompressedSize > FrameConstants.MaxDecompressedBlockSize)
                    throw new InvalidDataException($"Block decompressed size {decompressedSize} exceeds maximum {FrameConstants.MaxDecompressedBlockSize}.");
                if (compressedSize > FrameConstants.MaxDecompressedBlockSize)
                    throw new InvalidDataException($"Block compressed size {compressedSize} exceeds maximum {FrameConstants.MaxDecompressedBlockSize}.");

                // Grow compressed buffer if needed
                int neededComp = compressedSize + StreamLZConstants.CompressBufferPadding;
                if (neededComp > compressedBuf.Length)
                {
                    ArrayPool<byte>.Shared.Return(compressedBuf);
                    compressedBuf = ArrayPool<byte>.Shared.Rent(neededComp);
                }

                if (isUncompressed)
                {
                    int readBytes = await ReadFullyAsync(input, windowBuf, dictBytes, decompressedSize, cancellationToken).ConfigureAwait(false);
                    if (readBytes < decompressedSize)
                        throw new InvalidDataException("Unexpected end of stream in uncompressed block.");
                }
                else
                {
                    int readBytes = await ReadFullyAsync(input, compressedBuf, 0, compressedSize, cancellationToken).ConfigureAwait(false);
                    if (readBytes < compressedSize)
                        throw new InvalidDataException("Unexpected end of stream in compressed block.");

                    unsafe
                    {
                        fixed (byte* pWindow = windowBuf)
                        fixed (byte* pCompressed = compressedBuf)
                        {
                            int result = StreamLZDecoder.Decompress(
                                pCompressed, compressedSize,
                                pWindow, decompressedSize, dstOffset: dictBytes);
                            if (result < 0)
                                throw new InvalidDataException("Block decompression failed.");
                            decompressedSize = result;
                        }
                    }
                }

                // Hash decompressed data before writing
                asyncContentHasher?.Append(windowBuf.AsSpan(dictBytes, decompressedSize));

                await output.WriteAsync(windowBuf.AsMemory(dictBytes, decompressedSize), cancellationToken).ConfigureAwait(false);
                totalDecompressed += decompressedSize;

                // Slide the window
                int totalUsed = dictBytes + decompressedSize;
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

            // Verify XXH32 content checksum if present
            if (verifyChecksumAsync && asyncContentHasher != null)
            {
                int checksumRead = await ReadFullyAsync(input, blockHeaderBuf, 0, 4, cancellationToken).ConfigureAwait(false);
                if (checksumRead < 4)
                    throw new InvalidDataException("Unexpected end of stream reading content checksum.");

                Span<byte> computed = stackalloc byte[4];
                asyncContentHasher.GetHashAndReset(computed);

                if (!computed.SequenceEqual(blockHeaderBuf.AsSpan(0, 4)))
                    throw new InvalidDataException("Content checksum mismatch: data may be corrupted.");
            }

            return totalDecompressed;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(compressedBuf);
            ArrayPool<byte>.Shared.Return(windowBuf);
        }
    }

    /// <summary>
    /// Decompresses a file to another file using the SLZ1 frame format.
    /// </summary>
    public static long DecompressFile(string inputPath, string outputPath)
    {
        const int ioBufSize = 1024 * 1024; // 1MB buffer for sequential I/O
        using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, ioBufSize, FileOptions.SequentialScan);
        using var output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, ioBufSize, FileOptions.SequentialScan);
        return Decompress(input, output);
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

    /// <summary>Reads from over-read buffer first, then from stream.</summary>
    private static int ReadWithOverRead(ref Memory<byte> overRead, Stream stream, byte[] buffer, int offset, int count)
    {
        int totalRead = 0;
        if (overRead.Length > 0)
        {
            int fromOverRead = Math.Min(count, overRead.Length);
            overRead.Span[..fromOverRead].CopyTo(buffer.AsSpan(offset));
            overRead = overRead[fromOverRead..];
            totalRead += fromOverRead;
        }
        while (totalRead < count)
        {
            int bytesRead = stream.Read(buffer, offset + totalRead, count - totalRead);
            if (bytesRead == 0)
                break;
            totalRead += bytesRead;
        }
        return totalRead;
    }

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
