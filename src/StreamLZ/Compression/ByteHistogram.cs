using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StreamLZ.Compression;

/// <summary>
/// 256-bin byte histogram with utility methods.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct ByteHistogram
{
    /// <summary>Per-byte-value frequency counts (256 entries, one per possible byte value).</summary>
    public fixed uint Count[256];

    /// <summary>
    /// Count the frequency of each byte value in <paramref name="src"/> into this histogram.
    /// Clears the histogram first.
    /// </summary>
    public void CountBytes(ReadOnlySpan<byte> src)
    {
        fixed (uint* c = Count)
        {
            new Span<byte>(c, 256 * sizeof(uint)).Clear();
            for (int i = 0; i < src.Length; i++)
            {
                c[src[i]]++;
            }
        }
    }

    /// <summary>
    /// Count the frequency of each byte value in the buffer at <paramref name="source"/>
    /// with length <paramref name="length"/>.
    /// Clears the histogram first.
    /// </summary>
    public void CountBytes(byte* source, int length)
    {
        fixed (uint* c = Count)
        {
            new Span<byte>(c, 256 * sizeof(uint)).Clear();
            for (int i = 0; i < length; i++)
            {
                c[source[i]]++;
            }
        }
    }

    /// <summary>
    /// Returns the sum of all 256 counts.
    /// </summary>
    public uint GetSum()
    {
        fixed (uint* c = Count)
        {
            uint sum = 0;
            for (int i = 0; i < 256; i++)
            {
                sum += c[i];
            }
            return sum;
        }
    }

    /// <summary>
    /// Computes an approximate cost (in bits, fixed-point) using the log2 lookup table.
    /// </summary>
    /// <param name="histoSum">Pre-computed sum of all histogram counts.</param>
    /// <param name="log2Table">
    /// Pointer to the Log2LookupTable (4097 entries).
    /// </param>
    public uint GetCostApprox(int histoSum, uint* log2Table)
    {
        fixed (uint* histo = Count)
        {
            return GetCostApproxCore(histo, 256, histoSum, log2Table);
        }
    }

    /// <summary>
    /// Core implementation of GetHistoCostApprox, operating on a raw uint* histogram.
    /// </summary>
    internal static uint GetCostApproxCore(uint* histo, int arrSize, int histoSum, uint* log2Table)
    {
        if (histoSum <= 1)
        {
            return 40;
        }

        int factor = (int)(0x40000000u / (uint)histoSum);
        uint zerosRun = 0, nonzeroEntries = 0;
        uint bitUsageZ = 0, bitUsage = 0;
        ulong bitUsageF = 0;

        for (int i = 0; i < arrSize; i++)
        {
            uint v = histo[i];
            if (v == 0)
            {
                zerosRun++;
                continue;
            }
            nonzeroEntries++;
            if (zerosRun != 0)
            {
                bitUsageZ += 2 * (uint)BitOperations.Log2(zerosRun + 1) + 1;
                zerosRun = 0;
            }
            else
            {
                bitUsageZ += 1;
            }
            bitUsage += (uint)BitOperations.Log2(v) * 2 + 1;
            uint log2Index = (uint)((long)factor * v) >> 18;
            Debug.Assert(log2Index <= 4096, $"log2Table index {log2Index} exceeds maximum of 4096");
            log2Index = Math.Min(log2Index, 4096);
            bitUsageF += v * (ulong)log2Table[log2Index];
        }

        if (nonzeroEntries == 1)
        {
            return 6 * 8;
        }

        bitUsageZ += 2 * (uint)BitOperations.Log2(zerosRun + 1) + 1;
        bitUsageZ = Math.Min(bitUsageZ, 8 * nonzeroEntries);

        return (uint)(bitUsageF >> 12) + bitUsage + bitUsageZ + 5 * 8;
    }
}

/// <summary>
/// Miscellaneous utility constants and helpers used throughout the compressor.
/// </summary>
internal static class CompressUtils
{
    /// <summary>
    /// Rounds <paramref name="x"/> up to the next byte boundary: (x + 7) &gt;&gt; 3.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int BitsUp(int x) => (x + 7) >> 3;

    /// <summary>
    /// Rounds <paramref name="x"/> up to the next byte boundary: (x + 7) &gt;&gt; 3.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static uint BitsUp(uint x) => (x + 7) >> 3;

}
