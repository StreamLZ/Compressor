namespace StreamLZ.Common;

/// <summary>
/// Codec type identifiers for StreamLZ compression and decompression.
/// </summary>
internal enum CodecType
{
    /// <summary>High — general-purpose codec with optimal parsing and best ratio.</summary>
    High = 0,

    /// <summary>Fast — high-throughput codec with greedy/lazy parsing.</summary>
    Fast = 1,

    /// <summary>Turbo — speed-optimized variant of Fast (raw literals, no entropy coding).</summary>
    Turbo = 2,
}

/// <summary>
/// Header in front of each 256KB block.
/// </summary>
internal readonly struct StreamLZHeader
{
    /// <summary>Type of decoder used (e.g. 2 = High).</summary>
    public CodecType DecoderType { get; init; }

    /// <summary>Whether to restart the decoder.</summary>
    public bool RestartDecoder { get; init; }

    /// <summary>Whether this block is uncompressed.</summary>
    public bool Uncompressed { get; init; }

    /// <summary>Whether this block uses checksums.</summary>
    public bool UseChecksums { get; init; }

    /// <summary>
    /// Whether each chunk is self-contained (no cross-chunk LZ references).
    /// Enables parallel decompression of individual chunks.
    /// </summary>
    public bool SelfContained { get; init; }

    /// <summary>
    /// Whether this block uses two-phase encoding (self-contained + cross-chunk patches).
    /// </summary>
    public bool TwoPhase { get; init; }
}

/// <summary>
/// Additional header in front of each 256KB chunk.
/// </summary>
internal readonly struct ChunkHeader
{
    /// <summary>
    /// Compressed size of this chunk. 0 means a special chunk (e.g. memset).
    /// </summary>
    public uint CompressedSize { get; init; }

    /// <summary>If checksums are enabled, holds the checksum.</summary>
    public uint Checksum { get; init; }

    /// <summary>Whether the whole block matched a previous block.</summary>
    public uint WholeMatchDistance { get; init; }
}
