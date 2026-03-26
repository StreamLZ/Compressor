namespace StreamLZ.Compression;

/// <summary>
/// Flags controlling which entropy coding modes the encoder may use.
/// </summary>
/// <remarks>
/// <para>Common flag combinations used by the compressor:</para>
/// <list type="bullet">
///   <item><description>
///     <c>AllowTANS | AllowMultiArray | AllowRLE</c> — mask cleared by High compressor at
///     levels -3 through 0 to disable these modes for speed.
///   </description></item>
///   <item><description>
///     <c>AllowTANS | AllowMultiArray</c> — mask cleared by High compressor at levels 1-2.
///   </description></item>
///   <item><description>
///     <c>AllowTANS | AllowMultiArrayAdvanced</c> — mask cleared by High compressor at level 3+.
///   </description></item>
/// </list>
/// <para>
/// Not all 256 combinations are valid in practice. <c>AllowMultiArrayAdvanced</c> is only
/// meaningful when <c>AllowMultiArray</c> is also set. Code that temporarily disables
/// <c>AllowMultiArray</c> (e.g., in <c>High.Compressor</c>) saves and
/// restores the original value to avoid permanent mutation.
/// </para>
/// </remarks>
[Flags]
internal enum EntropyOptions
{
    /// <summary>Allow tANS (asymmetric numeral system) encoding.</summary>
    AllowTANS = 0x01,
    /// <summary>Allow entropy-coded RLE command streams.</summary>
    AllowRLEEntropy = 0x02,
    /// <summary>Allow 4-way split Huffman encoding.</summary>
    AllowDoubleHuffman = 0x04,
    /// <summary>Allow run-length encoding.</summary>
    AllowRLE = 0x08,
    /// <summary>Allow simple multi-array encoding.</summary>
    AllowMultiArray = 0x10,
    /// <summary>Allow the newer Golomb-Rice coded Huffman table format.</summary>
    SupportsNewHuffman = 0x20,
    /// <summary>Allow advanced multi-array encoding with histogram clustering.</summary>
    AllowMultiArrayAdvanced = 0x40,
    /// <summary>Allow short memset blocks.</summary>
    SupportsShortMemset = 0x80,
}
