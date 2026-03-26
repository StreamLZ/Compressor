// ComparisonBenchmark.cs — Compare StreamLZ against LZ4, Snappy, and Zstd.

using System.Diagnostics;
using StreamLZ;
using K4os.Compression.LZ4;
using Snappier;
using ZstdSharp;

namespace StreamLZ.Cli;

internal static class ComparisonBenchmark
{
    internal record BenchResult(string Name, int CompressedSize, double CompressMBps, double DecompressMBps);

    internal static void Run(byte[] src, int runs)
    {
        Console.WriteLine($"Input: {src.Length:N0} bytes ({src.Length / 1024.0 / 1024.0:F2} MB)");
        Console.WriteLine($"Runs: {runs} (median reported)");
        Console.WriteLine();

        var results = new List<BenchResult>();

        // StreamLZ levels
        foreach (int level in new[] { 1, 3, 5, 6, 8, 11 })
        {
            var r = BenchStreamLZ(src, level, runs);
            results.Add(r);
        }

        // LZ4
        foreach (var (name, lz4Level) in new[] {
            ("LZ4 Fast", LZ4Level.L00_FAST),
            ("LZ4 Default", LZ4Level.L03_HC),
            ("LZ4 Max", LZ4Level.L12_MAX) })
        {
            results.Add(BenchLZ4(src, name, lz4Level, runs));
        }

        // Snappy
        results.Add(BenchSnappy(src, runs));

        // Zstd
        foreach (var (name, zstdLevel) in new[] {
            ("Zstd 1", 1),
            ("Zstd 3", 3),
            ("Zstd 9", 9),
            ("Zstd 19", 19) })
        {
            results.Add(BenchZstd(src, name, zstdLevel, runs));
        }

        // Print table
        Console.WriteLine();
        Console.WriteLine($"{"Compressor",-18} {"Size",12} {"Ratio",8} {"Compress",12} {"Decompress",12}");
        Console.WriteLine(new string('─', 66));
        foreach (var r in results)
        {
            double ratio = (double)r.CompressedSize / src.Length * 100;
            Console.WriteLine($"{r.Name,-18} {r.CompressedSize,12:N0} {ratio,7:F1}% {r.CompressMBps,10:F1} MB/s {r.DecompressMBps,10:F1} MB/s");
        }
    }

    private static BenchResult BenchStreamLZ(byte[] src, int level, int runs)
    {
        string name = $"SLZ L{level}";

        // Warmup
        byte[] compressed = Slz.Compress(src, level);

        // Compress
        long[] times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            compressed = Slz.Compress(src, level);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double compMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        // Decompress warmup
        byte[] decompressed = new byte[src.Length + Slz.SafeSpace];
        Slz.Decompress(compressed, decompressed, src.Length);

        // Decompress
        times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            Slz.Decompress(compressed, decompressed, src.Length);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double decompMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        Console.WriteLine($"  {name}: {compressed.Length:N0} bytes, compress {compMbps:F1} MB/s, decompress {decompMbps:F1} MB/s");
        return new BenchResult(name, compressed.Length, compMbps, decompMbps);
    }

    private static BenchResult BenchLZ4(byte[] src, string name, LZ4Level lz4Level, int runs)
    {
        // Warmup
        int bound = LZ4Codec.MaximumOutputSize(src.Length);
        byte[] compressed = new byte[bound];
        int compSize = LZ4Codec.Encode(src, compressed, lz4Level);

        // Compress
        long[] times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            compSize = LZ4Codec.Encode(src, compressed, lz4Level);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double compMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        // Decompress warmup
        byte[] decompressed = new byte[src.Length];
        LZ4Codec.Decode(compressed, 0, compSize, decompressed, 0, src.Length);

        // Decompress
        times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            LZ4Codec.Decode(compressed, 0, compSize, decompressed, 0, src.Length);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double decompMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        Console.WriteLine($"  {name}: {compSize:N0} bytes, compress {compMbps:F1} MB/s, decompress {decompMbps:F1} MB/s");
        return new BenchResult(name, compSize, compMbps, decompMbps);
    }

    private static BenchResult BenchSnappy(byte[] src, int runs)
    {
        string name = "Snappy";

        // Warmup
        byte[] compressed = Snappy.CompressToArray(src);

        // Compress
        long[] times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            compressed = Snappy.CompressToArray(src);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double compMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        // Decompress warmup
        byte[] decompressed = Snappy.DecompressToArray(compressed);

        // Decompress
        times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            decompressed = Snappy.DecompressToArray(compressed);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double decompMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        Console.WriteLine($"  {name}: {compressed.Length:N0} bytes, compress {compMbps:F1} MB/s, decompress {decompMbps:F1} MB/s");
        return new BenchResult(name, compressed.Length, compMbps, decompMbps);
    }

    private static BenchResult BenchZstd(byte[] src, string name, int zstdLevel, int runs)
    {
        using var compressor = new Compressor(zstdLevel);
        using var decompressor = new Decompressor();

        // Warmup
        byte[] compressed = compressor.Wrap(src).ToArray();

        // Compress
        long[] times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            compressed = compressor.Wrap(src).ToArray();
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double compMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        // Decompress warmup
        byte[] decompressed = decompressor.Unwrap(compressed).ToArray();

        // Decompress
        times = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            decompressed = decompressor.Unwrap(compressed).ToArray();
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
        }
        Array.Sort(times);
        double decompMbps = (double)src.Length / (times[runs / 2] / 1000.0) / (1024 * 1024);

        Console.WriteLine($"  {name}: {compressed.Length:N0} bytes, compress {compMbps:F1} MB/s, decompress {decompMbps:F1} MB/s");
        return new BenchResult(name, compressed.Length, compMbps, decompMbps);
    }
}
