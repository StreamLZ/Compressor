namespace StreamLZ;

/// <summary>
/// Named compression level presets for use with StreamLZ.
/// These map to specific integer levels in the 1-11 range.
/// </summary>
[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1008", Justification = "Compression level 0 is not valid; the minimum is 1.")]
public enum SlzCompressionLevel
{
    /// <summary>Level 1: fastest compression, largest output.</summary>
    Fastest = 1,
    /// <summary>Level 3: fast compression with reasonable ratio.</summary>
    Fast = 3,
    /// <summary>Level 6: balanced speed and compression ratio (default).</summary>
    Default = 6,
    /// <summary>Level 9: high compression ratio, slower.</summary>
    High = 9,
    /// <summary>Level 11: maximum compression ratio, slowest.</summary>
    Maximum = 11
}
