// SlzStream.cs — Stream wrapper for StreamLZ compression, matching GZipStream/BrotliStream API pattern.

using System.IO.Compression;
using StreamLZ.Common;

namespace StreamLZ;

/// <summary>
/// Provides methods and properties for compressing and decompressing streams
/// using the StreamLZ algorithm, following the same pattern as
/// <see cref="GZipStream"/> and <see cref="System.IO.Compression.BrotliStream"/>.
/// </summary>
/// <remarks>
/// <para>
/// In <see cref="CompressionMode.Compress"/> mode, data written to this stream is
/// compressed and forwarded to the underlying stream. Call <see cref="Stream.Dispose()"/>
/// or <see cref="Flush"/> to finalize the compressed output.
/// </para>
/// <para>
/// In <see cref="CompressionMode.Decompress"/> mode, reading from this stream
/// returns decompressed data from the underlying compressed stream.
/// </para>
/// </remarks>
public sealed class SlzStream : Stream
{
    private readonly Stream _innerStream;
    private readonly CompressionMode _mode;
    private readonly bool _leaveOpen;
    private readonly int _level;
    private bool _disposed;

    // Compress state
    private readonly MemoryStream? _writeBuffer;

    // Decompress state
    private byte[]? _decompressedBuffer;
    private int _decompressedOffset;
    private int _decompressedLength;
    private bool _decompressFinished;

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified mode and default compression level.
    /// </summary>
    /// <param name="stream">The stream to compress into or decompress from.</param>
    /// <param name="mode">Whether to compress or decompress.</param>
    public SlzStream(Stream stream, CompressionMode mode)
        : this(stream, mode, leaveOpen: false, level: Slz.DefaultLevel)
    {
    }

    /// <summary>
    /// Initializes a new instance of <see cref="SlzStream"/> with the specified mode and leave-open behavior.
    /// </summary>
    /// <param name="stream">The stream to compress into or decompress from.</param>
    /// <param name="mode">Whether to compress or decompress.</param>
    /// <param name="leaveOpen">If true, the inner stream is not closed when this stream is disposed.</param>
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

        if (mode == CompressionMode.Compress)
        {
            _writeBuffer = new MemoryStream();
        }
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

    /// <inheritdoc/>
    public override void Write(byte[] buffer, int offset, int count)
    {
        ValidateBufferArguments(buffer, offset, count);
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Compress)
            throw new InvalidOperationException("Cannot write to a decompression stream.");

        _writeBuffer!.Write(buffer, offset, count);
    }

    /// <inheritdoc/>
    public override void Write(ReadOnlySpan<byte> buffer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_mode != CompressionMode.Compress)
            throw new InvalidOperationException("Cannot write to a decompression stream.");

        _writeBuffer!.Write(buffer);
    }

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

        // If we have buffered decompressed data, serve from there
        if (_decompressedOffset < _decompressedLength)
        {
            int toCopy = Math.Min(buffer.Length, _decompressedLength - _decompressedOffset);
            _decompressedBuffer.AsSpan(_decompressedOffset, toCopy).CopyTo(buffer);
            _decompressedOffset += toCopy;
            return toCopy;
        }

        if (_decompressFinished)
            return 0;

        // Need to decompress from the inner stream
        // Read the entire compressed stream into memory, decompress, buffer the result
        EnsureDecompressed();

        if (_decompressedOffset >= _decompressedLength)
            return 0;

        int copy = Math.Min(buffer.Length, _decompressedLength - _decompressedOffset);
        _decompressedBuffer.AsSpan(_decompressedOffset, copy).CopyTo(buffer);
        _decompressedOffset += copy;
        return copy;
    }

    /// <inheritdoc/>
    public override void Flush()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_mode == CompressionMode.Compress)
        {
            FlushCompressed();
        }
    }

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
                if (_mode == CompressionMode.Compress && _writeBuffer!.Length > 0)
                {
                    FlushCompressed();
                }

                _writeBuffer?.Dispose();

                if (!_leaveOpen)
                {
                    _innerStream.Dispose();
                }
            }
            _disposed = true;
        }
        base.Dispose(disposing);
    }

    private void FlushCompressed()
    {
        if (_writeBuffer!.Length == 0)
            return;

        byte[] uncompressed = _writeBuffer.ToArray();
        _writeBuffer.SetLength(0);

        Slz.CompressStream(
            new MemoryStream(uncompressed, writable: false),
            _innerStream,
            _level);
    }

    private void EnsureDecompressed()
    {
        if (_decompressFinished)
            return;

        using var decompressedStream = new MemoryStream();
        Slz.DecompressStream(_innerStream, decompressedStream);

        _decompressedBuffer = decompressedStream.ToArray();
        _decompressedLength = _decompressedBuffer.Length;
        _decompressedOffset = 0;
        _decompressFinished = true;
    }

}
