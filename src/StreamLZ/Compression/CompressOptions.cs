namespace StreamLZ.Compression;

/// <summary>
/// Encoder-side compression options.
/// </summary>
internal sealed class CompressOptions
{
    /// <summary>Minimum match length required for a match to be considered.</summary>
    public int MinMatchLength { get; set; }
    /// <summary>Number of bytes between seek-point resets.</summary>
    public int SeekChunkReset { get; set; }
    /// <summary>Seek chunk length for seekable compression.</summary>
    public int SeekChunkLen { get; set; }
    /// <summary>Maximum backward reference distance in bytes.</summary>
    public int DictionarySize { get; set; }
    /// <summary>Space-speed tradeoff parameter in bytes.</summary>
    public int SpaceSpeedTradeoffBytes { get; set; }
    /// <summary>Whether to generate chunk header checksums.</summary>
    public bool GenerateChunkHeaderChecksum { get; set; }
    /// <summary>Maximum local dictionary size for self-contained mode.</summary>
    public int MaxLocalDictionarySize { get; set; }
    /// <summary>Number of hash bits for the match finder.</summary>
    public int HashBits { get; set; }
    /// <summary>Whether each chunk is self-contained (enables parallel decompression).</summary>
    public bool SelfContained { get; set; }
    /// <summary>Whether to use two-phase compression (self-contained + cross-chunk patches).</summary>
    public bool TwoPhase { get; set; }
}

/// <summary>
/// A cross-chunk match patch for two-phase compression.
/// Records a position where a cross-chunk match can improve on the self-contained literal.
/// </summary>
internal readonly struct PatchEntry
{
    /// <summary>Absolute position in the output buffer.</summary>
    public int Position { get; init; }
    /// <summary>Backward offset (negative distance to match source).</summary>
    public int Offset { get; init; }
    /// <summary>Match length in bytes.</summary>
    public int Length { get; init; }
}
