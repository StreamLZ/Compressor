using System;
using System.IO;
using StreamLZ;
using StreamLZ.Compression;
using StreamLZ.Decompression;
using Xunit;

namespace StreamLZ.Tests;

/// <summary>
/// Verifies that the stream API produces identical compression ratio to the
/// raw API, and tests edge cases at format boundaries.
/// </summary>
public unsafe class ParityAndEdgeCaseTests
{
    // ── Stream vs Raw parity ──

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void StreamApi_MatchesRawApi_Ratio(int level)
    {
        byte[] source = new byte[512 * 1024]; // 512KB — multiple chunks
        new Random(42).NextBytes(source);

        // Raw API
        int rawCompBound = StreamLZCompressor.GetCompressBound(source.Length);
        byte[] rawCompressed = new byte[rawCompBound];
        int rawCompSize;
        var mapped = Slz.MapLevel(level);
        fixed (byte* pSrc = source)
        fixed (byte* pDst = rawCompressed)
        {
            rawCompSize = StreamLZCompressor.Compress(
                pSrc, source.Length, pDst, rawCompressed.Length,
                mapped.Codec, mapped.CodecLevel, numThreads: 1,
                selfContained: mapped.SelfContained);
        }

        // Stream API
        byte[] streamCompressed;
        using (var input = new MemoryStream(source))
        using (var output = new MemoryStream())
        {
            Slz.CompressStream(input, output, level);
            streamCompressed = output.ToArray();
        }

        // Ratio should be within 5% (frame overhead accounts for small difference)
        double rawRatio = (double)rawCompSize / source.Length;
        double streamRatio = (double)streamCompressed.Length / source.Length;
        double ratioDiff = Math.Abs(rawRatio - streamRatio);

        Assert.True(ratioDiff < 0.05,
            $"L{level}: raw ratio {rawRatio:P1} vs stream ratio {streamRatio:P1} — differ by {ratioDiff:P1}");

        // Stream output must decompress correctly
        byte[] decompressed;
        using (var input = new MemoryStream(streamCompressed))
        using (var output = new MemoryStream())
        {
            Slz.DecompressStream(input, output);
            decompressed = output.ToArray();
        }
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }

    // ── Edge cases ──

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_OneByte(int level)
    {
        byte[] source = [0x42];
        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source, decompressed);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_EmptyInput(int level)
    {
        byte[] source = [];
        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source, decompressed);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_ExactlyHalfChunk(int level)
    {
        // Exactly 128KB — half an internal chunk
        byte[] source = new byte[128 * 1024];
        new Random(66).NextBytes(source);

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_ExactlyOneChunk(int level)
    {
        // Exactly 256KB = one internal chunk, no boundary crossing
        byte[] source = new byte[256 * 1024];
        new Random(77).NextBytes(source);

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_ChunkBoundaryPlusOne(int level)
    {
        // 256KB + 1 byte — forces exactly two chunks
        byte[] source = new byte[256 * 1024 + 1];
        new Random(88).NextBytes(source);

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_IncompressibleData(int level)
    {
        // Purely random data — should not crash, output may be larger than input
        byte[] source = new byte[128 * 1024];
        new Random(int.MaxValue).NextBytes(source);

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_AllZeros(int level)
    {
        // Maximally compressible — tests RLE and extreme ratio paths
        byte[] source = new byte[1024 * 1024]; // 1MB of zeros

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));

        // Should compress extremely well
        Assert.True(compressed.Length < source.Length / 10,
            $"Expected >90% compression on all-zeros, got {compressed.Length}/{source.Length}");
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void EdgeCase_RepeatingPattern(int level)
    {
        // Short repeating pattern — tests match offset handling
        byte[] source = new byte[512 * 1024];
        byte[] pattern = "ABCDEFGHIJKLMNOP"u8.ToArray();
        for (int i = 0; i < source.Length; i++)
            source[i] = pattern[i % pattern.Length];

        byte[] compressed = Slz.CompressFramed(source, level);
        byte[] decompressed = Slz.DecompressFramed(compressed);
        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed));
    }
}
