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
    /// <param name="progress">Optional progress reporter. Reports total decompressed bytes written after each block.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total number of decompressed bytes written to <paramref name="output"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown if the frame header is invalid or data is corrupt.</exception>
    public static long Decompress(Stream input, Stream output,
        int windowSize = FrameConstants.DefaultWindowSize,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default,
        long maxDecompressedSize = -1)
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
        byte[] compBuf = ArrayPool<byte>.Shared.Rent(initialCompBufSize);
        // Window buffer for sliding-window dictionary context across blocks.
        // Grows dynamically if a block is larger than the initial allocation.
        int windowBufSize = windowSize + blockSize + StreamLZDecoder.SafeSpace * 2;
        byte[] windowBuf = ArrayPool<byte>.Shared.Rent(windowBufSize);
        byte[] blockHeaderBuf = new byte[8];

        // Incremental XXH32 checksum over all decompressed data (if frame has checksum flag)
        bool verifyChecksum = (header.Flags & FrameFlags.ContentChecksum) != 0;
        System.IO.Hashing.XxHash32? contentHasher = verifyChecksum ? new() : null;

        try
        {
            long totalDecompressed = 0;
            int dictBytes = 0;
            int headerRead = 0;

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();

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

                {

                    // Grow buffers if this block is larger than initial allocation
                    int neededWindow = dictBytes + decompressedSize + StreamLZDecoder.SafeSpace * 2;
                    if (neededWindow > windowBuf.Length)
                    {
                        byte[] newWindow = ArrayPool<byte>.Shared.Rent(neededWindow);
                        Buffer.BlockCopy(windowBuf, 0, newWindow, 0, dictBytes);
                        ArrayPool<byte>.Shared.Return(windowBuf);
                        windowBuf = newWindow;
                    }
                    int neededComp = compressedSize + StreamLZConstants.CompressBufferPadding;
                    if (neededComp > compBuf.Length)
                    {
                        ArrayPool<byte>.Shared.Return(compBuf);
                        compBuf = ArrayPool<byte>.Shared.Rent(neededComp);
                    }

                    // Serial block: decompress with sliding window dictionary context
                    if (isUncompressed)
                    {
                        if (ReadWithOverRead(ref overReadMem, input, windowBuf, dictBytes, decompressedSize) < decompressedSize)
                            throw new InvalidDataException("Unexpected end of stream in uncompressed block.");
                    }
                    else
                    {
                        if (ReadWithOverRead(ref overReadMem, input, compBuf, 0, compressedSize) < compressedSize)
                            throw new InvalidDataException("Unexpected end of stream in compressed block.");

                        unsafe
                        {
                            fixed (byte* pWindow = windowBuf)
                            fixed (byte* pCompressed = compBuf)
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
                    if (maxDecompressedSize >= 0 && totalDecompressed > maxDecompressedSize)
                        throw new InvalidDataException($"Decompressed output ({totalDecompressed} bytes) exceeds limit of {maxDecompressedSize} bytes.");
                    progress?.Report(totalDecompressed);

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
            ArrayPool<byte>.Shared.Return(compBuf);
            ArrayPool<byte>.Shared.Return(windowBuf);
        }
    }

    /// <summary>
    /// Asynchronously decompresses SLZ1-framed data with cancellation support.
    /// </summary>
    /// <param name="input">Source stream containing SLZ1-framed compressed data.</param>
    /// <param name="output">Destination stream to write decompressed data to.</param>
    /// <param name="windowSize">Sliding window size for back-references (default 4MB, must match compressor).</param>
    /// <param name="progress">Optional progress reporter. Reports total decompressed bytes written after each block.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total number of decompressed bytes written to <paramref name="output"/>.</returns>
    /// <exception cref="InvalidDataException">Thrown if the frame header is invalid or data is corrupt.</exception>
    public static async Task<long> DecompressAsync(Stream input, Stream output,
        int windowSize = FrameConstants.DefaultWindowSize,
        IProgress<long>? progress = null,
        long maxDecompressedSize = -1,
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
                if (maxDecompressedSize >= 0 && totalDecompressed > maxDecompressedSize)
                    throw new InvalidDataException($"Decompressed output ({totalDecompressed} bytes) exceeds limit of {maxDecompressedSize} bytes.");
                progress?.Report(totalDecompressed);

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
