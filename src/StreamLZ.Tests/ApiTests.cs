using System;
using System.IO;
using System.IO.Compression;
using System.Threading.Tasks;
using StreamLZ;
using Xunit;

namespace StreamLZ.Tests;

public class ApiTests
{
    // ── CompressFile checksum ──

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

        byte[] low = Slz.CompressFramed(data, level: -5);
        byte[] high = Slz.CompressFramed(data, level: 100);

        Assert.True(low.Length > 0);
        Assert.True(high.Length > 0);

        Assert.Equal(data, Slz.DecompressFramed(low));
        Assert.Equal(data, Slz.DecompressFramed(high));
    }

    // ── SlzStreamOptions + checksum ──

    [Fact]
    public void SlzStream_WithOptions_RoundTrips()
    {
        byte[] data = new byte[100_000];
        new Random(42).NextBytes(data);

        var options = new SlzStreamOptions
        {
            Level = 3,
            LeaveOpen = false,
            UseContentChecksum = true
        };

        byte[] compressed;
        using (var output = new MemoryStream())
        {
            using (var slz = new SlzStream(output, CompressionMode.Compress, options))
            {
                slz.Write(data);
            }
            compressed = output.ToArray();
        }

        byte[] restored;
        using (var input = new MemoryStream(compressed))
        using (var slz = new SlzStream(input, CompressionMode.Decompress))
        using (var output = new MemoryStream())
        {
            slz.CopyTo(output);
            restored = output.ToArray();
        }

        Assert.Equal(data, restored);
    }

    [Fact]
    public void SlzStream_WithChecksum_ProducesLargerOutput()
    {
        byte[] data = new byte[100_000];
        new Random(42).NextBytes(data);

        byte[] withChecksum, withoutChecksum;

        using (var output = new MemoryStream())
        {
            using (var slz = new SlzStream(output, CompressionMode.Compress, new SlzStreamOptions { UseContentChecksum = true }))
                slz.Write(data);
            withChecksum = output.ToArray();
        }

        using (var output = new MemoryStream())
        {
            using (var slz = new SlzStream(output, CompressionMode.Compress))
                slz.Write(data);
            withoutChecksum = output.ToArray();
        }

        Assert.True(withChecksum.Length > withoutChecksum.Length,
            $"Checksum output ({withChecksum.Length}) should be larger than non-checksum ({withoutChecksum.Length})");
    }

    // ── IAsyncDisposable ──

    [Fact]
    public async Task SlzStream_AwaitUsing_Works()
    {
        byte[] data = new byte[50_000];
        new Random(42).NextBytes(data);

        byte[] compressed;
        using (var output = new MemoryStream())
        {
            await using (var slz = new SlzStream(output, CompressionMode.Compress, leaveOpen: true))
            {
                slz.Write(data);
            }
            compressed = output.ToArray();
        }

        Assert.True(compressed.Length > 0);

        byte[] restored;
        using (var input = new MemoryStream(compressed))
        await using (var slz = new SlzStream(input, CompressionMode.Decompress))
        using (var output = new MemoryStream())
        {
            slz.CopyTo(output);
            restored = output.ToArray();
        }

        Assert.Equal(data, restored);
    }

    // ── Async file methods ──

    [Fact]
    public async Task CompressFileAsync_DecompressFileAsync_RoundTrip()
    {
        string inputPath = Path.GetTempFileName();
        string compressedPath = Path.GetTempFileName();
        string outputPath = Path.GetTempFileName();
        try
        {
            byte[] data = new byte[100_000];
            new Random(42).NextBytes(data);
            File.WriteAllBytes(inputPath, data);

            await Slz.CompressFileAsync(inputPath, compressedPath);
            await Slz.DecompressFileAsync(compressedPath, outputPath);

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

    // ── TryDecompress ──

    [Fact]
    public void TryDecompress_ValidData_ReturnsTrue()
    {
        byte[] data = new byte[10_000];
        new Random(42).NextBytes(data);
        byte[] compressed = Slz.Compress(data);

        byte[] output = new byte[data.Length + Slz.SafeSpace];
        bool ok = Slz.TryDecompress(compressed, output, data.Length, out int written);

        Assert.True(ok);
        Assert.Equal(data.Length, written);
        Assert.Equal(data, output.AsSpan(0, written).ToArray());
    }

    [Fact]
    public void TryDecompress_InvalidData_ReturnsFalse()
    {
        byte[] garbage = new byte[] { 0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
        byte[] output = new byte[1000 + Slz.SafeSpace];
        bool ok = Slz.TryDecompress(garbage, output, 1000, out int written);

        Assert.False(ok);
        Assert.Equal(0, written);
    }

    [Fact]
    public void TryDecompress_BufferTooSmall_ReturnsFalse()
    {
        byte[] data = new byte[1000];
        new Random(42).NextBytes(data);
        byte[] compressed = Slz.Compress(data);

        byte[] output = new byte[10];
        bool ok = Slz.TryDecompress(compressed, output, data.Length, out int written);

        Assert.False(ok);
    }

    // ── IsValidFrame ──

    [Fact]
    public void IsValidFrame_Span_ValidData()
    {
        byte[] data = new byte[1000];
        new Random(42).NextBytes(data);
        byte[] framed = Slz.CompressFramed(data);

        Assert.True(Slz.IsValidFrame(framed));
    }

    [Fact]
    public void IsValidFrame_Span_InvalidData()
    {
        Assert.False(Slz.IsValidFrame(new byte[] { 0x00, 0x01, 0x02, 0x03 }));
        Assert.False(Slz.IsValidFrame(ReadOnlySpan<byte>.Empty));
    }

    [Fact]
    public void IsValidFrame_Stream_ValidData()
    {
        byte[] data = new byte[1000];
        new Random(42).NextBytes(data);
        byte[] framed = Slz.CompressFramed(data);

        using var stream = new MemoryStream(framed);
        Assert.True(Slz.IsValidFrame(stream));
        Assert.Equal(0, stream.Position);
    }

    [Fact]
    public void IsValidFrame_Stream_InvalidData()
    {
        using var stream = new MemoryStream(new byte[] { 0x00, 0x01, 0x02, 0x03 });
        Assert.False(Slz.IsValidFrame(stream));
    }

    // ── SlzCompressionLevel enum ──

    [Fact]
    public void Compress_WithEnum_MatchesIntLevel()
    {
        byte[] data = new byte[10_000];
        new Random(42).NextBytes(data);

        byte[] fromInt = Slz.Compress(data, 9);
        byte[] fromEnum = Slz.Compress(data, SlzCompressionLevel.High);

        Assert.Equal(fromInt, fromEnum);
    }

    [Fact]
    public void CompressFramed_WithEnum_RoundTrips()
    {
        byte[] data = new byte[10_000];
        new Random(42).NextBytes(data);

        byte[] compressed = Slz.CompressFramed(data, SlzCompressionLevel.Fast);
        byte[] restored = Slz.DecompressFramed(compressed);

        Assert.Equal(data, restored);
    }
}
