// CostModel.cs — Platform cost combination and decompression timing estimates for the Fast compressor.

using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// Provides platform-weighted cost combination and decompression time estimates
/// for rate-distortion decisions in the Fast compressor.
/// </summary>
internal static class CostModel
{
    // ────────────────────────────────────────────────────────────────
    //  Platform cost combination (weighted average across 4 platforms)
    //
    //  Platform weights (0.762, 1.130, 1.310, 0.961) and all per-platform
    //  linear regression coefficients in the GetDecodingTime* methods are
    //  empirically tuned from decompression benchmarks across 4 hardware
    //  platforms. Do not round or simplify these values.
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Combines four platform-specific cost values into a single weighted average.
    /// When <paramref name="platforms"/> is 0 (default), returns the simple average.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static float CombinePlatformCosts(int platforms, float a, float b, float c, float d)
    {
        Debug.Assert((platforms & ~0xf) == 0, "platforms must use only bits 0-3");
        if ((platforms & 0xf) == 0)
            return (a + b + c + d) * 0.25f;
        int n = 0;
        float sum = 0;
        if ((platforms & 1) != 0) { sum += c * 0.762f; n++; }
        if ((platforms & 2) != 0) { sum += a * 1.130f; n++; }
        if ((platforms & 4) != 0) { sum += d * 1.310f; n++; }
        if ((platforms & 8) != 0) { sum += b * 0.961f; n++; }
        return sum / n;
    }

    /// <summary>
    /// Combines four platform costs with a common scalar multiplier.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static float CombinePlatformCostsScaled(int platforms, float value,
        float a, float b, float c, float d)
    {
        return CombinePlatformCosts(platforms, value * a, value * b, value * c, value * d);
    }

    /// <summary>
    /// Combines four platform costs with both a scalar multiplier and per-platform bias terms.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static float CombinePlatformCostsWithBias(int platforms, float value,
        float a, float b, float c, float d,
        float biasA, float biasB, float biasC, float biasD)
    {
        return CombinePlatformCosts(platforms,
            value * a + biasA, value * b + biasB, value * c + biasC, value * d + biasD);
    }

    // ────────────────────────────────────────────────────────────────
    //  Decompression time estimates
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Estimated decompression time for the offset16 stream.
    /// </summary>
    public static float GetDecodingTimeOffset16(int platforms, int count)
    {
        return CombinePlatformCostsWithBias(platforms, count,
            0.270f, 0.428f, 0.550f, 0.213f,
            24.0f, 53.0f, 62.0f, 33.0f);
    }

    /// <summary>
    /// Estimated decompression time for entropy-coded mode (literal entropy + token entropy).
    /// </summary>
    public static float GetDecodingTimeEntropyCoded(int platforms, int length, int tokenCount, int complexTokenCount)
    {
        return CombinePlatformCosts(platforms,
            200.0f + length * 0.363f + tokenCount * 5.393f + complexTokenCount * 29.655f,
            200.0f + length * 0.429f + tokenCount * 6.977f + complexTokenCount * 49.739f,
            200.0f + length * 0.538f + tokenCount * 8.676f + complexTokenCount * 69.864f,
            200.0f + length * 0.255f + tokenCount * 5.364f + complexTokenCount * 30.818f);
    }

    /// <summary>
    /// Estimated decompression time for raw-coded mode (memcpy literals + raw tokens).
    /// </summary>
    public static float GetDecodingTimeRawCoded(int platforms, int length, int tokenCount, int complexTokenCount, int literalCount)
    {
        return CombinePlatformCosts(platforms,
            200.0f + length * 0.371f + tokenCount * 5.259f + complexTokenCount * 25.474f + literalCount * 0.131f,
            200.0f + length * 0.414f + tokenCount * 6.678f + complexTokenCount * 62.007f + literalCount * 0.065f,
            200.0f + length * 0.562f + tokenCount * 8.190f + complexTokenCount * 75.523f + literalCount * 0.008f,
            200.0f + length * 0.272f + tokenCount * 5.018f + complexTokenCount * 29.297f + literalCount * 0.070f);
    }

    /// <summary>
    /// Estimated decompression time for the offset32 stream.
    /// </summary>
    public static float GetDecodingTimeOffset32(int platforms, int count)
    {
        return CombinePlatformCostsWithBias(platforms, count,
            1.285f, 3.369f, 2.446f, 1.032f,
            56.010f, 33.347f, 133.394f, 67.640f);
    }

}
