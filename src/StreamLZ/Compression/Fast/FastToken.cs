// Types.cs — Shared types and constants for the Fast compressor.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// A single LZ token in the Fast parsed sequence: literal run + match.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct FastToken
{
    /// <summary>Number of literal bytes preceding this match.</summary>
    public int LiteralRunLength;
    /// <summary>Length of the match in bytes.</summary>
    public int MatchLength;
    /// <summary>Match offset (0 = use recent offset, &gt;0 = explicit offset).</summary>
    public int Offset;
}

/// <summary>
/// Constants for the Fast compressor.
/// </summary>
internal static class FastConstants
{
    /// <summary>Minimum source length for compression (shorter inputs are returned uncompressed).</summary>
    public const int MinSourceLength = 128;

    /// <summary>Number of initial literal bytes copied verbatim at the start of a chunk.</summary>
    public const int InitialCopyBytes = 8;

    /// <summary>Maximum size of the first sub-block within a chunk (64 KB).</summary>
    public const int Block1MaxSize = 0x10000;

    /// <summary>Threshold above which 32-bit offsets use a 4-byte encoding.
    /// Mirrors <see cref="Common.StreamLZConstants.FastLargeOffsetThreshold"/>.</summary>
    public const uint LargeOffsetThreshold = (uint)Common.StreamLZConstants.FastLargeOffsetThreshold;

    /// <summary>Marker value in the off16 count field indicating entropy-coded off16 streams.</summary>
    public const ushort EntropyCoded16Marker = 0xFFFF;

    /// <summary>Maximum match length that fits in a simple (non-complex) token.</summary>
    public const int SimpleTokenMaxMatchLength = 90;

    /// <summary>Maximum match length that fits in a near-offset complex token.</summary>
    public const int NearOffsetMaxMatchLength = 90;

    /// <summary>Default maximum dictionary size (1 GB).</summary>
    public const uint DefaultDictionarySize = 0x40000000;

    /// <summary>Speed tradeoff scale factor (1/256).</summary>
    public const float SpeedTradeoffScale = 1f / 256f;

    /// <summary>Speed factor for entropy-coded mode.</summary>
    public const float EntropySpeedFactor = 0.050000001f;

    /// <summary>Speed factor for raw-coded mode.</summary>
    public const float RawSpeedFactor = 0.14f;

    /// <summary>Maximum length value that fits in a single byte (extended encoding above this).</summary>
    public const uint MaxSingleByteLengthValue = 251;

    /// <summary>Base value subtracted in the extended length encoding formula.</summary>
    public const uint ExtendedLengthBase = 252;

    /// <summary>Mask for the low 2 bits of the length value in extended encoding.</summary>
    public const uint ExtendedLengthMask = 3;

    // ── Shared helpers ──

    /// <summary>
    /// Returns <paramref name="value"/> mod 7 for values greater than 7,
    /// or <paramref name="value"/> unchanged for values 7 or less.
    /// Used to determine how many literal bytes fit in a single token.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int LiteralRunSlotCount(int value)
    {
        return (value > 7) ? (value - 1) % 7 + 1 : value;
    }

    /// <summary>
    /// Returns the effective dictionary size from compression options,
    /// clamped to <see cref="DefaultDictionarySize"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static uint GetEffectiveDictionarySize(CompressOptions options)
    {
        return options.DictionarySize > 0 && options.DictionarySize <= (int)DefaultDictionarySize
            ? (uint)options.DictionarySize : DefaultDictionarySize;
    }
}
