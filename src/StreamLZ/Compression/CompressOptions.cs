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

    // ── Decode-cost penalties (in 32nds of a bit) ──
    // These bias the optimal parser toward matches that are cheaper to DECODE,
    // not just cheaper to ENCODE. Set via environment variables for tuning.

    /// <summary>Per-token fixed decode overhead penalty (32nds of a bit). Each token
    /// requires carousel rotation + entropy decode + branch. Default 0.</summary>
    public int DecodeCostPerToken { get; set; }

    /// <summary>Penalty for matches with offset &lt; 16 (byte-at-a-time copy instead
    /// of SIMD). Applied per match byte. In 32nds of a bit. Default 0.</summary>
    public int DecodeCostSmallOffset { get; set; }

    /// <summary>Penalty for very short matches (length 2-3) that barely justify
    /// the token overhead. In 32nds of a bit. Default 0.</summary>
    public int DecodeCostShortMatch { get; set; }
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
