using System;
using System.IO;

/// <summary>
/// Read-only stream wrapper that reports progress via a callback after each read.
/// </summary>
internal sealed class ProgressStream(Stream inner, Action<long> onProgress) : Stream
{
    private long _totalRead;

    public override int Read(byte[] buffer, int offset, int count)
    {
        int n = inner.Read(buffer, offset, count);
        _totalRead += n;
        onProgress(_totalRead);
        return n;
    }

    public override int Read(Span<byte> buffer)
    {
        int n = inner.Read(buffer);
        _totalRead += n;
        onProgress(_totalRead);
        return n;
    }

    public override bool CanRead => true;
    public override bool CanSeek => inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length => inner.Length;
    public override long Position { get => inner.Position; set => inner.Position = value; }
    public override void Flush() => inner.Flush();
    public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
