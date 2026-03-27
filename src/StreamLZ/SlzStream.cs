// SlzStream.cs — Stream wrapper for StreamLZ compression, matching GZipStream/BrotliStream API pattern.

using System.Buffers;
using System.Buffers.Binary;
using System.IO.Compression;
using System.IO.Hashing;
using System.Numerics;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;

namespace StreamLZ;

/// <summary>
/// Provides methods and properties for compressing and decompressing streams
/// using the StreamLZ algorithm, following the same pattern as
/// <see cref="GZipStream"/> and <see cref="System.IO.Compression.BrotliStream"/>.
/// </summary>
/// <remarks>
/// <para>
/// In <see cref="CompressionMode.Compress"/> mode, data written to this stream is
/// compressed block-by-block and forwarded to the underlying stream using the SLZ1
/// frame format. Each block is self-contained (no cross-block references).
/// Memory usage is bounded (~600 KB regardless of input size).
/// Call <see cref="Stream.Dispose()"/> to finalize the compressed output.
/// </para>
/// <para>
/// In <see cref="CompressionMode.Decompress"/> mode, reading from this stream
/// returns decompressed data from the underlying compressed stream, one block at a time.
/// Supports both self-contained and cross-block-referenced streams (all compression levels).
/// Memory usage is bounded by block size + window size.
/// </para>
/// </remarks>
public sealed class SlzStream : Stream, IAsyncDisposable
{
    private readonly Stream _innerStream;
    private readonly CompressionMode _mode;
    private readonly bool _leaveOpen;
    private readonly int _level;
    private readonly bool _useContentChecksum;
    private bool _disposed;

    // ── Compress state ──
    private byte[]? _compressInputBuf;   // accumulates uncompressed writes (one block)
    private int _compressInputPos;
    private byte[]? _compressOutputBuf;  // receives compressed block output
    private bool _frameHeaderWritten;
    private int _blockSize;
    private XxHash32? _compressContentHasher;

    // ── Decompress state ──
    private byte[]? _windowBuf;          // sliding window + current block output
    private int _dictBytes;              // how many dictionary bytes precede current output in _windowBuf
    private byte[]? _compressedReadBuf;  // compressed block read from inner stream
    private int _decompOffset;           // read cursor within current decompressed block (relative to _dictBytes)
    private int _decompLength;           // length of current decompressed block
    private bool _decompFinished;
    private bool _frameHeaderRead;
    private FrameFlags _frameFlags;
    private int _windowSize;
    private Memory<byte> _overReadMem;   // bytes over-read from frame header/block header
    private XxHash32? _contentHasher;    // checksum verifier (if frame has checksum flag)

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified mode and default compression level.
    /// </summary>
    public SlzStream(Stream stream, CompressionMode mode)
        : this(stream, mode, leaveOpen: false, level: Slz.DefaultLevel)
    {
    }

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified mode and leave-open behavior.
    /// </summary>
    public SlzStream(Stream stream, CompressionMode mode, bool leaveOpen)
        : this(stream, mode, leaveOpen, level: Slz.DefaultLevel)
    {
    }

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified compression level.
    /// </summary>
    /// <param name="stream">The stream to compress into or decompress from.</param>
    /// <param name="mode">Whether to compress or decompress.</param>
    /// <param name="leaveOpen">If true, the inner stream is not closed when this stream is disposed.</param>
    /// <param name="level">Compression level 1-11 (only used in Compress mode).</param>
    public SlzStream(Stream stream, CompressionMode mode, bool leaveOpen, int level)
    {
        ArgumentNullException.ThrowIfNull(stream);

        if (mode == CompressionMode.Compress && !stream.CanWrite)
            throw new ArgumentException("Stream must be writable for compression.", nameof(stream));
        if (mode == CompressionMode.Decompress && !stream.CanRead)
            throw new ArgumentException("Stream must be readable for decompression.", nameof(stream));

        _innerStream = stream;
        _mode = mode;
        _leaveOpen = leaveOpen;
        _level = Math.Clamp(level, 1, 11);
        _blockSize = FrameConstants.DefaultBlockSize;
        _windowSize = FrameConstants.DefaultWindowSize;
    }

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified options.
    /// </summary>
    /// <param name="stream">The underlying stream to compress into or decompress from.</param>
    /// <param name="mode">Whether to compress or decompress.</param>
    /// <param name="options">Configuration options including Level, BlockSize, WindowSize,
    /// UseContentChecksum, and LeaveOpen.</param>
    /// <remarks>
    /// In Decompress mode, <see cref="SlzStreamOptions.Level"/>,
    /// <see cref="SlzStreamOptions.BlockSize"/>, and
    /// <see cref="SlzStreamOptions.UseContentChecksum"/> are ignored — these values
    /// are determined by the frame header. Only <see cref="SlzStreamOptions.LeaveOpen"/>
    /// and <see cref="SlzStreamOptions.WindowSize"/> apply in Decompress mode.
    /// </remarks>
    public SlzStream(Stream stream, CompressionMode mode, SlzStreamOptions options)
        : this(stream, mode, (options ?? throw new ArgumentNullException(nameof(options))).LeaveOpen, options.Level)
    {
        _blockSize = options.BlockSize;
        _windowSize = options.WindowSize;
        _useContentChecksum = options.UseContentChecksum;
    }

    /// <inheritdoc/>
    public override bool CanRead => _mode == CompressionMode.Decompress && !_disposed;

    /// <inheritdoc/>
    public override bool CanWrite => _mode == CompressionMode.Compress && !_disposed;

    /// <inheritdoc/>
    public override bool CanSeek => false;

    /// <inheritdoc/>
    public override long Length => throw new NotSupportedException();

    /// <inheritdoc/>
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    // ════════════════════════════════════════════════════════════════
    //  Compress path
    // ════════════════════════════════════════════════════════════════

    /// <inheritdoc/>
    public override void Write(byte[] buffer, int offset, int count)
    {
        ValidateBufferArguments(buffer, offset, count);
        Write(buffer.AsSpan(offset, count));
    }

    /// <inheritdoc/>
    public override void Write(ReadOnlySpan<byte> buffer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Compress)
            throw new InvalidOperationException("Cannot write to a decompression stream.");

        EnsureCompressBuffers();

        while (buffer.Length > 0)
        {
            int space = _blockSize - _compressInputPos;
            int toCopy = Math.Min(buffer.Length, space);
            buffer[..toCopy].CopyTo(_compressInputBuf.AsSpan(_compressInputPos));
            _compressInputPos += toCopy;
            buffer = buffer[toCopy..];

            if (_compressInputPos >= _blockSize)
                FlushBlock();
        }
    }

    /// <inheritdoc/>
    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        ValidateBufferArguments(buffer, offset, count);
        return WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    }

    /// <inheritdoc/>
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Compress)
            throw new InvalidOperationException("Cannot write to a decompression stream.");

        cancellationToken.ThrowIfCancellationRequested();

        // Compression is CPU-bound; do it synchronously then async-write the result.
        Write(buffer.Span);
        return ValueTask.CompletedTask;
    }

    /// <inheritdoc/>
    public override void Flush()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        // Don't flush a partial block here — that would start a new frame.
        // Partial block is flushed on Dispose.
    }

    /// <inheritdoc/>
    public override Task FlushAsync(CancellationToken cancellationToken)
    {
        Flush();
        return Task.CompletedTask;
    }

    private void EnsureCompressBuffers()
    {
        if (_compressInputBuf != null)
            return;

        _compressInputBuf = ArrayPool<byte>.Shared.Rent(_blockSize);
        int compBound = StreamLZCompressor.GetCompressBound(_blockSize);
        _compressOutputBuf = ArrayPool<byte>.Shared.Rent(compBound + StreamLZConstants.CompressBufferPadding);
        _compressInputPos = 0;

        if (_useContentChecksum)
            _compressContentHasher = new XxHash32();
    }

    private void EnsureFrameHeaderWritten()
    {
        if (_frameHeaderWritten)
            return;

        var mapped = Slz.MapLevel(_level);
        Span<byte> headerBuf = stackalloc byte[FrameConstants.MaxHeaderSize];
        int headerSize = FrameSerializer.WriteHeader(headerBuf, (int)mapped.Codec, mapped.CodecLevel, _blockSize,
            useContentChecksum: _useContentChecksum);
        _innerStream.Write(headerBuf[..headerSize]);
        _frameHeaderWritten = true;
    }

    private unsafe void FlushBlock()
    {
        if (_compressInputPos == 0)
            return;

        EnsureFrameHeaderWritten();

        var mapped = Slz.MapLevel(_level);
        int inputLen = _compressInputPos;

        // Hash uncompressed data for content checksum
        _compressContentHasher?.Append(_compressInputBuf.AsSpan(0, inputLen));

        int compBound = StreamLZCompressor.GetCompressBound(inputLen);

        if (_compressOutputBuf!.Length < compBound + StreamLZConstants.CompressBufferPadding)
        {
            ArrayPool<byte>.Shared.Return(_compressOutputBuf);
            _compressOutputBuf = ArrayPool<byte>.Shared.Rent(compBound + StreamLZConstants.CompressBufferPadding);
        }

        int compressedSize;
        fixed (byte* pSrc = _compressInputBuf)
        fixed (byte* pDst = _compressOutputBuf)
        {
            compressedSize = StreamLZCompressor.Compress(
                pSrc, inputLen, pDst, compBound,
                mapped.Codec, mapped.CodecLevel, selfContained: true);
        }

        Span<byte> blockHeader = stackalloc byte[8];
        if (compressedSize > 0 && compressedSize < inputLen)
        {
            FrameSerializer.WriteBlockHeader(blockHeader, compressedSize, inputLen, isUncompressed: false);
            _innerStream.Write(blockHeader);
            _innerStream.Write(_compressOutputBuf.AsSpan(0, compressedSize));
        }
        else
        {
            FrameSerializer.WriteBlockHeader(blockHeader, inputLen, inputLen, isUncompressed: true);
            _innerStream.Write(blockHeader);
            _innerStream.Write(_compressInputBuf.AsSpan(0, inputLen));
        }

        _compressInputPos = 0;
    }

    private void FinalizeCompress()
    {
        FlushBlock();

        if (_frameHeaderWritten)
        {
            Span<byte> endMark = stackalloc byte[4];
            FrameSerializer.WriteEndMark(endMark);
            _innerStream.Write(endMark);

            if (_compressContentHasher != null)
            {
                Span<byte> checksumBuf = stackalloc byte[4];
                _compressContentHasher.GetHashAndReset(checksumBuf);
                _innerStream.Write(checksumBuf);
            }
        }
    }

    /// <summary>
    /// Async version of <see cref="FinalizeCompress"/>. The CPU-bound compression
    /// stays synchronous; only the inner-stream writes are awaited.
    /// </summary>
    private async Task FinalizeCompressAsync()
    {
        FlushBlock();

        if (_frameHeaderWritten)
        {
            byte[] endMark = new byte[4];
            FrameSerializer.WriteEndMark(endMark);
            await _innerStream.WriteAsync(endMark).ConfigureAwait(false);

            if (_compressContentHasher != null)
            {
                byte[] checksumBuf = new byte[4];
                _compressContentHasher.GetHashAndReset(checksumBuf);
                await _innerStream.WriteAsync(checksumBuf).ConfigureAwait(false);
            }
        }
    }

    // ════════════════════════════════════════════════════════════════
    //  Decompress path
    // ════════════════════════════════════════════════════════════════

    /// <inheritdoc/>
    public override int Read(byte[] buffer, int offset, int count)
    {
        ValidateBufferArguments(buffer, offset, count);
        return Read(buffer.AsSpan(offset, count));
    }

    /// <inheritdoc/>
    public override int Read(Span<byte> buffer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Decompress)
            throw new InvalidOperationException("Cannot read from a compression stream.");

        if (buffer.Length == 0)
            return 0;

        // Serve from current decompressed block buffer
        if (_decompOffset < _decompLength)
        {
            int toCopy = Math.Min(buffer.Length, _decompLength - _decompOffset);
            _windowBuf.AsSpan(_dictBytes + _decompOffset, toCopy).CopyTo(buffer);
            _decompOffset += toCopy;
            return toCopy;
        }

        if (_decompFinished)
            return 0;

        // Decompress next block
        if (!DecompressNextBlock())
            return 0;

        int copy = Math.Min(buffer.Length, _decompLength - _decompOffset);
        _windowBuf.AsSpan(_dictBytes + _decompOffset, copy).CopyTo(buffer);
        _decompOffset += copy;
        return copy;
    }

    /// <inheritdoc/>
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        ValidateBufferArguments(buffer, offset, count);
        return ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    }

    /// <inheritdoc/>
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Decompress)
            throw new InvalidOperationException("Cannot read from a compression stream.");

        cancellationToken.ThrowIfCancellationRequested();

        // Decompression is CPU-bound; run synchronously.
        int bytesRead = Read(buffer.Span);
        return new ValueTask<int>(bytesRead);
    }

    private unsafe bool DecompressNextBlock()
    {
        if (!_frameHeaderRead)
        {
            ReadFrameHeader();
            _frameHeaderRead = true;
        }

        // Slide the window: retain up to _windowSize bytes of previously decoded output
        // so cross-block LZ back-references resolve correctly.
        SlideWindow();

        // Read 8-byte block header
        byte[] blockHeaderBuf = new byte[8];
        int headerRead = ReadFromInner(blockHeaderBuf.AsSpan(0, 8));

        if (headerRead >= 4 && BinaryPrimitives.ReadUInt32LittleEndian(blockHeaderBuf) == 0)
        {
            // End mark found. If we read more than 4 bytes, the extra bytes may be
            // the content checksum — push them back so VerifyContentChecksum can read them.
            int extraBytes = headerRead - 4;
            if (extraBytes > 0)
            {
                // Prepend to existing over-read buffer
                byte[] newOverRead = new byte[extraBytes + _overReadMem.Length];
                blockHeaderBuf.AsSpan(4, extraBytes).CopyTo(newOverRead);
                if (_overReadMem.Length > 0)
                    _overReadMem.Span.CopyTo(newOverRead.AsSpan(extraBytes));
                _overReadMem = newOverRead;
            }
            VerifyContentChecksum();
            _decompFinished = true;
            return false;
        }

        if (headerRead < 8)
        {
            _decompFinished = true;
            throw new InvalidDataException("Unexpected end of stream reading block header.");
        }

        if (!FrameSerializer.TryReadBlockHeader(blockHeaderBuf, out int compressedSize, out int decompressedSize, out bool isUncompressed))
            throw new InvalidDataException("Invalid block header.");

        if (compressedSize == 0)
        {
            VerifyContentChecksum();
            _decompFinished = true;
            return false;
        }

        if (decompressedSize > FrameConstants.MaxDecompressedBlockSize)
            throw new InvalidDataException($"Block decompressed size {decompressedSize} exceeds maximum.");

        // Ensure window buffer is large enough for dictionary + this block + SafeSpace
        int neededWindow = _dictBytes + decompressedSize + StreamLZDecoder.SafeSpace * 2;
        if (_windowBuf == null || _windowBuf.Length < neededWindow)
        {
            byte[]? oldBuf = _windowBuf;
            _windowBuf = ArrayPool<byte>.Shared.Rent(neededWindow);
            if (oldBuf != null)
            {
                // Copy dictionary context to new buffer
                oldBuf.AsSpan(0, _dictBytes).CopyTo(_windowBuf);
                ArrayPool<byte>.Shared.Return(oldBuf);
            }
        }

        if (isUncompressed)
        {
            if (ReadFromInner(_windowBuf.AsSpan(_dictBytes, decompressedSize)) < decompressedSize)
                throw new InvalidDataException("Unexpected end of stream in uncompressed block.");
        }
        else
        {
            // Ensure compressed read buffer is large enough
            int neededComp = compressedSize + StreamLZConstants.CompressBufferPadding;
            if (_compressedReadBuf == null || _compressedReadBuf.Length < neededComp)
            {
                if (_compressedReadBuf != null) ArrayPool<byte>.Shared.Return(_compressedReadBuf);
                _compressedReadBuf = ArrayPool<byte>.Shared.Rent(neededComp);
            }

            if (ReadFromInner(_compressedReadBuf.AsSpan(0, compressedSize)) < compressedSize)
                throw new InvalidDataException("Unexpected end of stream in compressed block.");

            fixed (byte* pWindow = _windowBuf)
            fixed (byte* pComp = _compressedReadBuf)
            {
                int result = StreamLZDecoder.Decompress(pComp, compressedSize, pWindow, decompressedSize, dstOffset: _dictBytes);
                if (result < 0)
                    throw new InvalidDataException("Block decompression failed.");
                decompressedSize = result;
            }
        }

        // Hash decompressed data for checksum verification
        _contentHasher?.Append(_windowBuf.AsSpan(_dictBytes, decompressedSize));

        _decompOffset = 0;
        _decompLength = decompressedSize;
        return true;
    }

    private void SlideWindow()
    {
        if (_decompLength == 0)
            return;

        int totalUsed = _dictBytes + _decompLength;
        if (totalUsed > _windowSize)
        {
            int keep = _windowSize;
            int discard = totalUsed - keep;
            Buffer.BlockCopy(_windowBuf!, discard, _windowBuf!, 0, keep);
            _dictBytes = keep;
        }
        else
        {
            _dictBytes = totalUsed;
        }
    }

    private void ReadFrameHeader()
    {
        byte[] headerBuf = new byte[FrameConstants.MaxHeaderSize];
        int bytesRead = ReadFromInner(headerBuf.AsSpan(0, FrameConstants.MaxHeaderSize));
        if (bytesRead < FrameConstants.MinHeaderSize)
            throw new InvalidDataException("StreamLZ frame header too short.");

        if (!FrameSerializer.TryReadHeader(headerBuf, out FrameHeader header))
            throw new InvalidDataException("Not a valid SLZ1 stream: expected magic bytes 'SLZ1'.");

        _blockSize = header.BlockSize;
        _frameFlags = header.Flags;
        _windowSize = Math.Clamp(_windowSize, _blockSize, FrameConstants.MaxWindowSize);

        if ((_frameFlags & FrameFlags.ContentChecksum) != 0)
            _contentHasher = new XxHash32();

        // Save over-read bytes for next read
        int overRead = bytesRead - header.HeaderSize;
        if (overRead > 0)
        {
            if (_innerStream.CanSeek)
            {
                _innerStream.Seek(-overRead, SeekOrigin.Current);
            }
            else
            {
                _overReadMem = new byte[overRead];
                headerBuf.AsSpan(header.HeaderSize, overRead).CopyTo(_overReadMem.Span);
            }
        }
    }

    private void VerifyContentChecksum()
    {
        if (_contentHasher == null)
            return;

        Span<byte> checksumBuf = stackalloc byte[4];
        if (ReadFromInner(checksumBuf) < 4)
            throw new InvalidDataException("Unexpected end of stream reading content checksum.");

        Span<byte> computed = stackalloc byte[4];
        _contentHasher.GetHashAndReset(computed);

        if (!computed.SequenceEqual(checksumBuf))
            throw new InvalidDataException("Content checksum mismatch: data may be corrupted.");
    }

    // ════════════════════════════════════════════════════════════════
    //  I/O helpers
    // ════════════════════════════════════════════════════════════════

    /// <summary>Reads from over-read buffer first, then from inner stream. Span overload.</summary>
    private int ReadFromInner(Span<byte> destination)
    {
        int totalRead = 0;
        if (_overReadMem.Length > 0)
        {
            int fromOverRead = Math.Min(destination.Length, _overReadMem.Length);
            _overReadMem.Span[..fromOverRead].CopyTo(destination);
            _overReadMem = _overReadMem[fromOverRead..];
            destination = destination[fromOverRead..];
            totalRead += fromOverRead;
        }
        while (destination.Length > 0)
        {
            int bytesRead = _innerStream.Read(destination);
            if (bytesRead == 0)
                break;
            destination = destination[bytesRead..];
            totalRead += bytesRead;
        }
        return totalRead;
    }

    /// <summary>Reads from over-read buffer first, then from inner stream. Array overload.</summary>
    private int ReadFromInner(Span<byte> buffer, int count)
    {
        return ReadFromInner(buffer[..count]);
    }

    // ════════════════════════════════════════════════════════════════
    //  Common
    // ════════════════════════════════════════════════════════════════

    /// <inheritdoc/>
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    /// <inheritdoc/>
    public override void SetLength(long value) => throw new NotSupportedException();

    /// <inheritdoc/>
    protected override void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                if (_mode == CompressionMode.Compress)
                    FinalizeCompress();

                if (_compressInputBuf != null) ArrayPool<byte>.Shared.Return(_compressInputBuf);
                if (_compressOutputBuf != null) ArrayPool<byte>.Shared.Return(_compressOutputBuf);
                if (_windowBuf != null) ArrayPool<byte>.Shared.Return(_windowBuf);
                if (_compressedReadBuf != null) ArrayPool<byte>.Shared.Return(_compressedReadBuf);

                if (!_leaveOpen)
                    _innerStream.Dispose();
            }
            _disposed = true;
        }
        base.Dispose(disposing);
    }

    /// <summary>
    /// Asynchronously disposes the stream, finalizing compression if needed and
    /// optionally disposing the inner stream.
    /// </summary>
    public override async ValueTask DisposeAsync()
    {
        if (!_disposed)
        {
            if (_mode == CompressionMode.Compress)
                await FinalizeCompressAsync().ConfigureAwait(false);

            if (_compressInputBuf != null) ArrayPool<byte>.Shared.Return(_compressInputBuf);
            if (_compressOutputBuf != null) ArrayPool<byte>.Shared.Return(_compressOutputBuf);
            if (_windowBuf != null) ArrayPool<byte>.Shared.Return(_windowBuf);
            if (_compressedReadBuf != null) ArrayPool<byte>.Shared.Return(_compressedReadBuf);

            if (!_leaveOpen)
                await _innerStream.DisposeAsync().ConfigureAwait(false);

            _disposed = true;
        }
        GC.SuppressFinalize(this);
        await base.DisposeAsync().ConfigureAwait(false);
    }
}

/// <summary>
/// Options for configuring an <see cref="SlzStream"/> instance.
/// </summary>
public class SlzStreamOptions
{
    /// <summary>If true, the inner stream is not closed when the SlzStream is disposed.</summary>
    public bool LeaveOpen { get; set; }
    /// <summary>Compression level 1-11 (only used in Compress mode). Default: 6.</summary>
    public int Level { get; set; } = Slz.DefaultLevel;
    /// <summary>When true, appends an XXH32 content checksum after the last block (Compress mode only).</summary>
    public bool UseContentChecksum { get; set; }

    private int _blockSize = FrameConstants.DefaultBlockSize;
    private int _windowSize = FrameConstants.DefaultWindowSize;

    /// <summary>Block size in bytes. Must be a power of 2 between 64KB and 4MB. Default: 256KB.</summary>
    public int BlockSize
    {
        get => _blockSize;
        set
        {
            if (!BitOperations.IsPow2(value) || value < 65536 || value > 4 * 1024 * 1024)
                throw new ArgumentOutOfRangeException(nameof(value),
                    $"BlockSize must be a power of 2 between 64KB and 4MB, got {value}.");
            _blockSize = value;
        }
    }

    /// <summary>Maximum compression threads. 0 = auto (one per core, limited by available memory). Default: 0.
    /// This property is used by <see cref="Slz.CompressStream(Stream, Stream, int, long, bool)"/>,
    /// <see cref="Slz.CompressFile(string, string, int, bool)"/>, and their async variants.
    /// <see cref="SlzStream"/> compresses one block at a time and does not use this value.</summary>
    public int MaxThreads { get; set; }

    /// <summary>Sliding window size in bytes. Must be between 64KB and 1GB. Default: 4MB.</summary>
    public int WindowSize
    {
        get => _windowSize;
        set
        {
            if (value < 65536 || value > 1073741824)
                throw new ArgumentOutOfRangeException(nameof(value),
                    $"WindowSize must be between 64KB and 1GB, got {value}.");
            _windowSize = value;
        }
    }
}
