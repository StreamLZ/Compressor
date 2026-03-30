using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using StreamLZ;
using Xunit;

namespace StreamLZ.Tests;

/// <summary>
/// Synchronous progress tracker that records reports immediately (no SynchronizationContext).
/// </summary>
#nullable enable
file class SyncProgress : IProgress<long>
{
    public long LastReported = -1;
    public int ReportCount;
    public Action? OnReport = null;

    public void Report(long value)
    {
        if (value <= LastReported)
            throw new Exception($"Progress went backwards: {value} <= {LastReported}");
        LastReported = value;
        Interlocked.Increment(ref ReportCount);
        OnReport?.Invoke();
    }
}

public class ProgressCancellationTests
{
    [Fact]
    public void CompressStream_ReportsProgress()
    {
        byte[] source = new byte[512 * 1024];
        new Random(42).NextBytes(source);

        var progress = new SyncProgress();

        using var input = new MemoryStream(source);
        using var output = new MemoryStream();
        Slz.CompressStream(input, output, progress: progress);

        Assert.True(progress.ReportCount > 0, "Progress should have been reported at least once");
        Assert.True(progress.LastReported > 0, "Last progress should be > 0");
    }

    [Fact]
    public void DecompressStream_ReportsProgress()
    {
        byte[] source = new byte[256 * 1024];
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        var progress = new SyncProgress();

        using var input = new MemoryStream(compressed);
        using var output = new MemoryStream();
        Slz.DecompressStream(input, output, progress: progress);

        Assert.True(progress.ReportCount > 0, "Progress should have been reported at least once");
    }

    [Fact]
    public void CompressStream_PreCancelledTokenThrows()
    {
        byte[] source = new byte[256 * 1024];
        new Random(42).NextBytes(source);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        using var input = new MemoryStream(source);
        using var output = new MemoryStream();

        Assert.Throws<OperationCanceledException>(() =>
            Slz.CompressStream(input, output, cancellationToken: cts.Token));
    }

    [Fact]
    public void DecompressStream_PreCancelledTokenThrows()
    {
        byte[] source = new byte[256 * 1024];
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        using var input = new MemoryStream(compressed);
        using var output = new MemoryStream();

        Assert.Throws<OperationCanceledException>(() =>
            Slz.DecompressStream(input, output, cancellationToken: cts.Token));
    }

    [Fact]
    public async Task CompressFileAsync_PreCancelledTokenThrows()
    {
        string inputPath = Path.GetTempFileName();
        string outputPath = Path.GetTempFileName();
        try
        {
            File.WriteAllBytes(inputPath, new byte[256 * 1024]);
            using var cts = new CancellationTokenSource();
            cts.Cancel();

            await Assert.ThrowsAsync<OperationCanceledException>(() =>
                Slz.CompressFileAsync(inputPath, outputPath, cancellationToken: cts.Token));
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(outputPath);
        }
    }

    [Fact]
    public void CompressFile_ReportsProgress()
    {
        string inputPath = Path.GetTempFileName();
        string outputPath = Path.GetTempFileName();
        try
        {
            byte[] data = new byte[512 * 1024];
            new Random(99).NextBytes(data);
            File.WriteAllBytes(inputPath, data);

            var progress = new SyncProgress();
            Slz.CompressFile(inputPath, outputPath, progress: progress);
            Assert.True(progress.ReportCount > 0);
        }
        finally
        {
            File.Delete(inputPath);
            File.Delete(outputPath);
        }
    }

    [Fact]
    public void DecompressFramed_MaxSizeRejectsOversizedFrame()
    {
        byte[] source = new byte[64 * 1024]; // 64KB
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        // Set limit to 1KB — decompression of 64KB should throw
        Assert.Throws<InvalidDataException>(() =>
            Slz.DecompressFramed(compressed, maxDecompressedSize: 1024));
    }

    [Fact]
    public void DecompressStream_MaxSizeRejectsOversizedOutput()
    {
        byte[] source = new byte[64 * 1024];
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        using var input = new MemoryStream(compressed);
        using var output = new MemoryStream();

        Assert.Throws<InvalidDataException>(() =>
            Slz.DecompressStream(input, output, maxDecompressedSize: 1024));
    }

    [Fact]
    public void DecompressStream_MaxSizeAllowsWithinLimit()
    {
        byte[] source = new byte[64 * 1024];
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        using var input = new MemoryStream(compressed);
        using var output = new MemoryStream();

        // 1MB limit — 64KB decompression should succeed
        long written = Slz.DecompressStream(input, output, maxDecompressedSize: 1024 * 1024);
        Assert.Equal(source.Length, written);
    }

    [Fact]
    public void DecompressStream_NoLimitByDefault()
    {
        byte[] source = new byte[64 * 1024];
        new Random(42).NextBytes(source);
        byte[] compressed = Slz.CompressFramed(source);

        using var input = new MemoryStream(compressed);
        using var output = new MemoryStream();

        // Default (-1) means no limit
        long written = Slz.DecompressStream(input, output);
        Assert.Equal(source.Length, written);
    }
}
