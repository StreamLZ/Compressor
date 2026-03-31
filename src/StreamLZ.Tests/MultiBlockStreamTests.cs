using System;
using System.IO;
using StreamLZ;
using StreamLZ.Common;
using Xunit;

namespace StreamLZ.Tests;

/// <summary>
/// Tests that the stream compressor/decompressor handles multi-block streams
/// correctly by forcing a small window size. This exercises cross-block
/// dictionary references without needing a huge file.
/// </summary>
public class MultiBlockStreamTests
{
    /// <summary>
    /// Compress 3MB with a 1MB window at L9 (non-SC, cross-block refs).
    /// Produces 3 blocks. Verifies round-trip integrity.
    /// </summary>
    [Theory]
    [InlineData(9, 3 * 1024 * 1024, 1 * 1024 * 1024)]
    [InlineData(9, 5 * 1024 * 1024, 1 * 1024 * 1024)]
    [InlineData(9, 2 * 1024 * 1024, 512 * 1024)]
    [InlineData(6, 3 * 1024 * 1024, 1 * 1024 * 1024)]
    [InlineData(1, 3 * 1024 * 1024, 1 * 1024 * 1024)]
    public void MultiBlock_RoundTrip(int level, int dataSize, int windowSize)
    {
        byte[] source = new byte[dataSize];
        new Random(42).NextBytes(source);

        var mapped = Slz.MapLevel(level);

        // Compress via stream API with small window
        byte[] compressed;
        using (var input = new MemoryStream(source))
        using (var output = new MemoryStream())
        {
            StreamLzFrameCompressor.Compress(input, output,
                mapped.Codec, mapped.CodecLevel,
                contentSize: source.Length,
                windowSize: windowSize,
                selfContained: mapped.SelfContained);
            compressed = output.ToArray();
        }

        // Decompress via stream API
        byte[] decompressed;
        using (var input = new MemoryStream(compressed))
        using (var output = new MemoryStream())
        {
            StreamLzFrameDecompressor.Decompress(input, output, windowSize: windowSize);
            decompressed = output.ToArray();
        }

        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed),
            "Multi-block round-trip mismatch");
    }

    /// <summary>
    /// Same test but with structured/repetitive data that benefits from
    /// cross-block dictionary references.
    /// </summary>
    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void MultiBlock_StructuredData_RoundTrip(int level)
    {
        // Repetitive CSV-like data — good for LZ matching
        int dataSize = 4 * 1024 * 1024;
        byte[] source = new byte[dataSize];
        var rng = new Random(99);
        int pos = 0;
        while (pos < dataSize)
        {
            string line = $"id={rng.Next(10000)},name=item_{rng.Next(100)},value={rng.Next(1000000)},tag=category_{rng.Next(20)}\n";
            int len = Math.Min(line.Length, dataSize - pos);
            System.Text.Encoding.ASCII.GetBytes(line, 0, len, source, pos);
            pos += len;
        }

        var mapped = Slz.MapLevel(level);
        int windowSize = 1 * 1024 * 1024;

        byte[] compressed;
        using (var input = new MemoryStream(source))
        using (var output = new MemoryStream())
        {
            StreamLzFrameCompressor.Compress(input, output,
                mapped.Codec, mapped.CodecLevel,
                contentSize: source.Length,
                windowSize: windowSize,
                selfContained: mapped.SelfContained);
            compressed = output.ToArray();
        }

        byte[] decompressed;
        using (var input = new MemoryStream(compressed))
        using (var output = new MemoryStream())
        {
            StreamLzFrameDecompressor.Decompress(input, output, windowSize: windowSize);
            decompressed = output.ToArray();
        }

        Assert.Equal(source.Length, decompressed.Length);
        Assert.True(source.AsSpan().SequenceEqual(decompressed),
            "Multi-block structured data round-trip mismatch");

        // Verify compression actually helped (structured data should compress well)
        Assert.True(compressed.Length < source.Length / 2,
            $"Expected >50% compression on structured data, got {compressed.Length}/{source.Length}");
    }
}
