namespace StreamLZ.Common;

/// <summary>
/// High LZ decode tables for the second phase of decompression.
/// </summary>
internal unsafe struct HighLzTable
{
    /// <summary>
    /// Stream of (literal, match) pairs. The flag byte contains
    /// the length of the match, the length of the literal, and whether
    /// to use a recent offset.
    /// </summary>
    public byte* CmdStream;

    /// <summary>Number of bytes in the command stream.</summary>
    public int CmdStreamSize;

    /// <summary>
    /// Holds the actual distances when not using a recent offset.
    /// </summary>
    public int* OffsStream;

    /// <summary>Number of entries in the offset stream.</summary>
    public int OffsStreamSize;

    /// <summary>
    /// Holds the sequence of literals. All literal copying happens from here.
    /// </summary>
    public byte* LitStream;

    /// <summary>Number of bytes in the literal stream.</summary>
    public int LitStreamSize;

    /// <summary>
    /// Holds lengths that do not fit in the flag stream.
    /// Both literal lengths and match lengths are stored here.
    /// </summary>
    public int* LenStream;

    /// <summary>Number of entries in the length stream.</summary>
    public int LenStreamSize;
}

/// <summary>
/// Phase 1 result for a single sub-chunk within a chunk.
/// Tracks whether the sub-chunk is LZ-compressed and its output location,
/// so Phase 2 can call ProcessLzRuns using the pre-decoded HighLzTable.
/// </summary>
internal unsafe struct SubChunkPhase1Result
{
    /// <summary>LZ mode: 0 = delta-coded literals, 1 = raw literals.</summary>
    public int Mode;

    /// <summary>Sub-chunk start offset within the full output buffer.</summary>
    public int DstOffset;

    /// <summary>Sub-chunk decompressed size in bytes.</summary>
    public int DstSize;

    /// <summary>True if this sub-chunk is LZ-compressed. False if entropy-only or stored.</summary>
    public bool IsLz;
}

/// <summary>
/// Phase 1 result for an entire chunk (1 or 2 sub-chunks).
/// </summary>
internal unsafe struct ChunkPhase1Result
{
    /// <summary>Phase 1 result for the first sub-chunk.</summary>
    public SubChunkPhase1Result Sub0;

    /// <summary>Phase 1 result for the second sub-chunk (if present).</summary>
    public SubChunkPhase1Result Sub1;

    /// <summary>Number of sub-chunks (1 or 2).</summary>
    public int SubChunkCount;

    /// <summary>True for uncompressed, memset, or whole-match chunks.</summary>
    public bool IsSpecial;

    /// <summary>True if this chunk is a whole-match reference to prior output.</summary>
    public bool IsWholeMatch;

    /// <summary>Whole-match backward distance (only valid when IsWholeMatch is true).</summary>
    public uint WholeMatchDistance;
}
