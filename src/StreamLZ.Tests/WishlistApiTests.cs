using System;
using System.IO;
using StreamLZ;
using Xunit;

namespace StreamLZ.Tests;

public class WishlistApiTests
{
    // ── CompressFile useContentChecksum ──

    [Fact]
    public void CompressFile_WithChecksum_DecompressFile_RoundTrip()
    {
        string inputPath = Path.GetTempFileName();
        string compressedPath = Path.GetTempFileName();
        string outputPath = Path.GetTempFileName();
        try
        {
            byte[] data = new byte[100_000];
            new Random(42).NextBytes(data);
            File.WriteAllBytes(inputPath, data);

            Slz.CompressFile(inputPath, compressedPath, useContentChecksum: true);
            Slz.DecompressFile(compressedPath, outputPath);

            byte[] restored = File.ReadAllBytes(outputPath);
            Assert.Equal(data, restored);
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(compressedPath);
            File.Delete(outputPath);
        }
    }

    [Fact]
    public void CompressFile_WithChecksum_ProducesLargerOutput()
    {
        string inputPath = Path.GetTempFileName();
        string withPath = Path.GetTempFileName();
        string withoutPath = Path.GetTempFileName();
        try
        {
            byte[] data = new byte[100_000];
            new Random(42).NextBytes(data);
            File.WriteAllBytes(inputPath, data);

            Slz.CompressFile(inputPath, withoutPath, useContentChecksum: false);
            Slz.CompressFile(inputPath, withPath, useContentChecksum: true);

            long withoutSize = new FileInfo(withoutPath).Length;
            long withSize = new FileInfo(withPath).Length;

            // Checksum adds 4 bytes (XXH32)
            Assert.True(withSize > withoutSize,
                $"Expected checksum output ({withSize}) to be larger than non-checksum ({withoutSize})");
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(withPath);
            File.Delete(withoutPath);
        }
    }

    // ── CompressFramed / DecompressFramed ──

    [Fact]
    public void CompressFramed_OutputIsSLZ1Frame()
    {
        byte[] data = new byte[1000];
        new Random(42).NextBytes(data);
        byte[] compressed = Slz.CompressFramed(data);

        // SLZ1 magic stored as little-endian uint 0x534C5A31 = bytes "1ZLS" in memory
        Assert.True(compressed.Length >= 10);
        Assert.Equal((byte)'1', compressed[0]);
        Assert.Equal((byte)'Z', compressed[1]);
        Assert.Equal((byte)'L', compressed[2]);
        Assert.Equal((byte)'S', compressed[3]);
    }

    [Fact]
    public void DecompressFramed_InvalidData_Throws()
    {
        byte[] garbage = new byte[] { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
        Assert.ThrowsAny<Exception>(() => Slz.DecompressFramed(garbage));
    }

    [Fact]
    public void CompressFramed_SmallData_RoundTrips()
    {
        // Test with very small inputs that may hit edge cases
        for (int size = 1; size <= 32; size++)
        {
            byte[] data = new byte[size];
            new Random(size).NextBytes(data);
            byte[] compressed = Slz.CompressFramed(data);
            byte[] restored = Slz.DecompressFramed(compressed);
            Assert.Equal(data, restored);
        }
    }

    // ── Level clamping ──

    [Fact]
    public void Compress_LevelOutOfRange_ClampedNotThrown()
    {
        byte[] data = new byte[1000];
        new Random(42).NextBytes(data);

        // Should not throw — levels are clamped
        byte[] low = Slz.CompressFramed(data, level: -5);
        byte[] high = Slz.CompressFramed(data, level: 100);

        Assert.True(low.Length > 0);
        Assert.True(high.Length > 0);

        // Both should round-trip
        Assert.Equal(data, Slz.DecompressFramed(low));
        Assert.Equal(data, Slz.DecompressFramed(high));
    }
}
