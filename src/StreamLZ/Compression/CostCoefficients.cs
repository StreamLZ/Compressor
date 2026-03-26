// CostCoefficients.cs -- Configurable cost model coefficients for StreamLZ compression.
// All values are empirically-derived timing constants that control which encoding mode
// the compressor selects in marginal cases. They do NOT affect the wire format or decompressor.
// Load from an optional StreamLZ.ini file to tune for your target hardware without rebuilding.
//
// Default values were found via sweep and random walk on Intel Arrow Lake-S (Ultra 9 285K),
// optimizing for compression ratio across enwik8 and silesia corpora at High L9.
// See sweep_findings.md for methodology and data.

using System.Diagnostics;
using System.Globalization;

namespace StreamLZ.Compression;

/// <summary>
/// Immutable snapshot of all timing/cost coefficients used by the StreamLZ compressor's cost model.
/// Created once, then atomically swapped into <see cref="CostCoefficients.Current"/>.
/// </summary>
internal sealed record CostSnapshot
{
    // Offset encoding timing
    public float OffsetType0PerItem { get; init; } = 8.85935f;
    public float OffsetType0Base { get; init; } = 44.0563f;
    public float OffsetType1PerItem { get; init; } = 6.75172f;
    public float OffsetType1Base { get; init; } = 76.0104f;
    public float OffsetModularPerItem { get; init; } = 0.978096f;
    public float OffsetModularBase { get; init; } = 52.0707f;
    public float SingleHuffmanBase { get; init; } = 2149.44f;
    public float SingleHuffmanPerItem { get; init; } = 3.12304f;
    public float SingleHuffmanPerSymbol { get; init; } = 25.279f;

    // Length encoding timing
    public float LengthU8PerItem { get; init; } = 0.756596f;
    public float LengthBase { get; init; } = 36.9445f;
    public float LengthU32PerItem { get; init; } = 33.0755f;

    // Write-bits timing models
    public float HighWriteBitsBase { get; init; } = 187.647f;
    public float HighWriteBitsPerSrcByte { get; init; } = 0.437702f;
    public float HighWriteBitsPerToken { get; init; } = 18.6782f;
    public float HighWriteBitsPerLrl { get; init; } = 11.1832f;

    // Token and literal mode costs
    public float TokenEncodingPerToken { get; init; } = 2.75565f;
    public float MultiArrayOverhead { get; init; } = 5299.54f;
    public float LitSubTimeCost { get; init; } = 0.19282f;
    public float LamSubTimeCost { get; init; } = 0.815096f;
    public float LitSub3TimeCost { get; init; } = 2.24116f;
    public float LitSubFTimeCost { get; init; } = 6.19838f;
    public float O1TimeCost { get; init; } = 10.1537f;

    // Memset cost
    public float MemsetPerByte { get; init; } = 0.161208f;
    public float MemsetBase { get; init; } = 56.6145f;

    // Literal subtraction cost
    public float HighLitSubExtraCostPerLit { get; init; } = 0.310262f;

    // tANS encoding cost
    public float TansBase { get; init; } = 1015.7f;
    public float TansPerSrcByte { get; init; } = 2.93114f;
    public float TansPerUsedSymbol { get; init; } = 73.1277f;
    public float TansPerTableEntry { get; init; } = 1.65052f;

    // Multi-array encoding cost
    public float MultiArrayPerIndex { get; init; } = 78.1526f;
    public float MultiArrayPerInputByte { get; init; } = 0.306832f;
    public float MultiArraySingleHuffmanApprox { get; init; } = 42.3518f;
    public ushort MultiArrayIncompressibleThreshold { get; init; } = 2011;

    // Speed tradeoff scaling
    public float SpeedTradeoffFactor1 { get; init; } = 0.0036609f;
    public float SpeedTradeoffFactor2 { get; init; } = 0.0095397f;

    // Cost conversion factor
    public float CostToBitsFactor { get; init; } = 0.130525f;

    // Multi-array base cost factor
    public float MultiArrayBaseCostFactor { get; init; } = 54.234f;

    /// <summary>
    /// Returns a new <see cref="CostSnapshot"/> with the named coefficient overridden.
    /// Returns <c>this</c> unchanged if <paramref name="key"/> is not recognized.
    /// </summary>
    internal CostSnapshot WithValue(string key, string val)
    {
        if (!float.TryParse(val, CultureInfo.InvariantCulture, out float parsedValue))
        {
            Trace.TraceWarning($"[CostCoefficients] Bad value for key '{key}': '{val}'");
            return this;
        }

        return key switch
        {
            "OffsetType0PerItem" => this with { OffsetType0PerItem = parsedValue },
            "OffsetType0Base" => this with { OffsetType0Base = parsedValue },
            "OffsetType1PerItem" => this with { OffsetType1PerItem = parsedValue },
            "OffsetType1Base" => this with { OffsetType1Base = parsedValue },
            "OffsetModularPerItem" => this with { OffsetModularPerItem = parsedValue },
            "OffsetModularBase" => this with { OffsetModularBase = parsedValue },
            "SingleHuffmanBase" => this with { SingleHuffmanBase = parsedValue },
            "SingleHuffmanPerItem" => this with { SingleHuffmanPerItem = parsedValue },
            "SingleHuffmanPerSymbol" => this with { SingleHuffmanPerSymbol = parsedValue },
            "LengthU8PerItem" => this with { LengthU8PerItem = parsedValue },
            "LengthBase" => this with { LengthBase = parsedValue },
            "LengthU32PerItem" => this with { LengthU32PerItem = parsedValue },
            "HighWriteBitsBase" => this with { HighWriteBitsBase = parsedValue },
            "HighWriteBitsPerSrcByte" => this with { HighWriteBitsPerSrcByte = parsedValue },
            "HighWriteBitsPerToken" => this with { HighWriteBitsPerToken = parsedValue },
            "HighWriteBitsPerLrl" => this with { HighWriteBitsPerLrl = parsedValue },
            "TokenEncodingPerToken" => this with { TokenEncodingPerToken = parsedValue },
            "MultiArrayOverhead" => this with { MultiArrayOverhead = parsedValue },
            "LitSubTimeCost" => this with { LitSubTimeCost = parsedValue },
            "LamSubTimeCost" => this with { LamSubTimeCost = parsedValue },
            "LitSub3TimeCost" => this with { LitSub3TimeCost = parsedValue },
            "LitSubFTimeCost" => this with { LitSubFTimeCost = parsedValue },
            "O1TimeCost" => this with { O1TimeCost = parsedValue },
            "MemsetPerByte" => this with { MemsetPerByte = parsedValue },
            "MemsetBase" => this with { MemsetBase = parsedValue },
            "HighLitSubExtraCostPerLit" => this with { HighLitSubExtraCostPerLit = parsedValue },
            "TansBase" => this with { TansBase = parsedValue },
            "TansPerSrcByte" => this with { TansPerSrcByte = parsedValue },
            "TansPerUsedSymbol" => this with { TansPerUsedSymbol = parsedValue },
            "TansPerTableEntry" => this with { TansPerTableEntry = parsedValue },
            "MultiArrayPerIndex" => this with { MultiArrayPerIndex = parsedValue },
            "MultiArrayPerInputByte" => this with { MultiArrayPerInputByte = parsedValue },
            "MultiArraySingleHuffmanApprox" => this with { MultiArraySingleHuffmanApprox = parsedValue },
            "MultiArrayIncompressibleThreshold" => this with { MultiArrayIncompressibleThreshold = (ushort)parsedValue },
            "SpeedTradeoffFactor1" => this with { SpeedTradeoffFactor1 = parsedValue },
            "SpeedTradeoffFactor2" => this with { SpeedTradeoffFactor2 = parsedValue },
            "CostToBitsFactor" => this with { CostToBitsFactor = parsedValue },
            "MultiArrayBaseCostFactor" => this with { MultiArrayBaseCostFactor = parsedValue },
            _ => WarnUnknownKey(key),
        };
    }

    private CostSnapshot WarnUnknownKey(string key)
    {
        Trace.TraceWarning($"[CostCoefficients] Unknown INI key: {key}");
        return this;
    }
}

/// <summary>
/// Holds all timing/cost coefficients used by the StreamLZ compressor's cost model.
/// Defaults are hardcoded; call <see cref="Load"/> to override from an INI file.
/// <para>
/// Callers access coefficients via <c>CostCoefficients.Current.PropertyName</c>.
/// <see cref="Current"/> is an immutable <see cref="CostSnapshot"/>.
/// <see cref="Load"/> atomically swaps the entire snapshot so compression threads
/// never see a half-updated set of coefficients.
/// </para>
/// </summary>
internal static class CostCoefficients
{
    /// <summary>
    /// The compiled-in defaults, captured once at startup.
    /// </summary>
    private static readonly CostSnapshot DefaultSnapshot = new();

    /// <summary>
    /// The active coefficient snapshot. Swapped atomically by <see cref="Load"/> and <see cref="Reset"/>.
    /// Volatile ensures readers always see the latest reference.
    /// </summary>
    private static volatile CostSnapshot _current = DefaultSnapshot;

    /// <summary>
    /// Gets or sets the current immutable snapshot of all coefficients.
    /// Setting this atomically replaces all coefficient values at once.
    /// </summary>
    public static CostSnapshot Current
    {
        get => _current;
        internal set => _current = value;
    }

    /// <summary>
    /// Restores all coefficients to their compiled-in default values.
    /// </summary>
    public static void Reset()
    {
        _current = DefaultSnapshot;
    }

    /// <summary>
    /// Loads coefficients from an INI file. Keys not present in the file retain
    /// their current values. The entire set is swapped atomically once parsing completes.
    /// Format: <c>[Section]</c> headers, <c>Key = Value</c> pairs, <c>;</c> comments.
    /// </summary>
    /// <param name="iniPath">Path to the INI file.</param>
    public static void Load(string? iniPath)
    {
        if (iniPath == null || !File.Exists(iniPath))
        {
            return;
        }

        // Start from current snapshot; apply each override immutably, then swap once.
        CostSnapshot snapshot = _current;

        foreach (string rawLine in File.ReadLines(iniPath))
        {
            string line = rawLine.Trim();
            if (line.Length == 0 || line[0] == ';' || line[0] == '#' || line[0] == '[')
            {
                continue;
            }

            int eq = line.IndexOf('=', StringComparison.Ordinal);
            if (eq < 0)
            {
                continue;
            }

            string key = line[..eq].Trim();
            string val = line[(eq + 1)..].Trim();

            // Strip inline comments
            int commentIdx = val.IndexOf(';', StringComparison.Ordinal);
            if (commentIdx >= 0)
            {
                val = val[..commentIdx].Trim();
            }
            commentIdx = val.IndexOf('#', StringComparison.Ordinal);
            if (commentIdx >= 0)
            {
                val = val[..commentIdx].Trim();
            }

            if (val.Length == 0)
            {
                continue;
            }

            snapshot = snapshot.WithValue(key, val);
        }

        // Atomic swap -- readers either see the old or new snapshot, never a mix.
        _current = snapshot;
    }
}
