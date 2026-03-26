using System.Buffers;
using System.Threading;

namespace StreamLZ.Common;

/// <summary>
/// Decoder state for StreamLZ decompression.
/// </summary>
internal sealed class StreamLZDecoderState : IDisposable
{
    /// <summary>
    /// Number of source (compressed) bytes consumed after a decode step.
    /// </summary>
    public int SourceBytesConsumed { get; set; }

    /// <summary>
    /// Number of destination (decompressed) bytes produced after a decode step.
    /// </summary>
    public int DestinationBytesProduced { get; set; }

    /// <summary>
    /// Scratch buffer that holds intermediate state between decode phase 1 and 2.
    /// </summary>
    public byte[]? Scratch;

    /// <summary>Size of the scratch buffer.</summary>
    public int ScratchSize;

    /// <summary>Parsed block header.</summary>
    public StreamLZHeader Header;

    /// <summary>
    /// Creates a new decoder state with the default scratch buffer size.
    /// Uses <see cref="ArrayPool{T}"/> to avoid LOH allocation (scratch is 442KB).
    /// </summary>
    public StreamLZDecoderState()
    {
        ScratchSize = StreamLZConstants.ScratchSize;
        Scratch = ArrayPool<byte>.Shared.Rent(ScratchSize);
    }

    /// <summary>
    /// Returns the Scratch buffer to the shared ArrayPool.
    /// </summary>
    public void Dispose()
    {
        byte[]? scratch = Interlocked.Exchange(ref Scratch, null);
        if (scratch is null)
        {
            return;
        }
        ArrayPool<byte>.Shared.Return(scratch);
    }
}
