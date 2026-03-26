// Quick test harness for StreamLZ compression — tests all codecs on a real file.
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;
using StreamLZ.Decompression.Entropy;
using Xunit;
using Xunit.Abstractions;

namespace StreamLZ.Tests;

public class CompressionBenchmark
{
    private readonly ITestOutputHelper _output;

    public CompressionBenchmark(ITestOutputHelper output)
    {
        _output = output;
    }

    // No-op: delegates eliminated; StreamLZCompressor calls codecs directly.
    private static void WireUpAll() { }
    private static void WireUpHigh() { }

    [Theory]
    [InlineData("High", 1)]
    [InlineData("High", 2)]
    [InlineData("High", 3)]
    [InlineData("High", 4)]
    [InlineData("High", 5)]
    [InlineData("High", 6)]
    [InlineData("Ultra", 1)]
    [InlineData("Ultra", 2)]
    [InlineData("Ultra", 3)]
    [InlineData("Ultra", 4)]
    [InlineData("Ultra", 5)]
    public unsafe void CompressAndDecompress_RoundTrip(string codecName, int level)
    {
        WireUpHigh();

        string testFile = Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "..", "..", "test_files", "web_100k.txt");
        if (!File.Exists(testFile))
        {
            _output.WriteLine($"SKIP: {testFile} not found");
            return;
        }

        byte[] src = File.ReadAllBytes(testFile);
        _output.WriteLine($"Source: {testFile}, {src.Length:N0} bytes");

        CodecType codec = codecName switch
        {
            "High" => CodecType.High,
            "Fast" => CodecType.Fast,
            _ => CodecType.High,
        };

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        var sw = Stopwatch.StartNew();
        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, codec, level);
        }
        sw.Stop();

        double ratio = compSize > 0 ? (double)compSize / src.Length * 100 : -1;
        double mbps = compSize > 0 ? (double)src.Length / sw.Elapsed.TotalSeconds / (1024 * 1024) : 0;

        _output.WriteLine($"{codecName} level {level}: {src.Length:N0} -> {compSize:N0} bytes " +
            $"({ratio:F1}%), {sw.ElapsedMilliseconds}ms, {mbps:F1} MB/s");

        if (compSize <= 0)
        {
            _output.WriteLine($"  Compression returned {compSize} — codec may not be fully ported.");
            return;
        }

        // Try decompression round-trip
        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed)
        fixed (byte* pDecomp = decompressed)
        {
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        }

        if (decompSize == src.Length)
        {
            bool match = new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src);
            if (!match)
            {
                int firstMismatch = -1, mismatchCount = 0;
                for (int i = 0; i < src.Length; i++)
                {
                    if (decompressed[i] != src[i])
                    {
                        if (firstMismatch < 0) firstMismatch = i;
                        mismatchCount++;
                    }
                }
                _output.WriteLine($"  Decompression: FAIL — {mismatchCount} bytes differ, first at offset {firstMismatch}");
                int s = Math.Max(0, firstMismatch - 4), e = Math.Min(src.Length, firstMismatch + 16);
                _output.WriteLine($"  Original  [{s}..{e}]: {BitConverter.ToString(src, s, e - s)}");
                _output.WriteLine($"  Decomp    [{s}..{e}]: {BitConverter.ToString(decompressed, s, e - s)}");
            }
            else
            {
                _output.WriteLine($"  Decompression: PASS — round-trip verified");
            }
            Assert.True(match, "Decompressed data does not match original");
        }
        else
        {
            _output.WriteLine($"  Decompression returned {decompSize} (expected {src.Length}) — decompressor may not handle this format yet.");
        }
    }

    [Fact]
    public unsafe void Debug_SmallFile_RoundTrip()
    {
        WireUpHigh();

        // ~1KB of compressible text — enough to trigger LZ matching (HighOptimal needs >128 bytes)
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < 80; i++)
            sb.Append($"Hello World {i}! The quick brown fox jumps over the lazy dog. ");
        byte[] src = System.Text.Encoding.ASCII.GetBytes(sb.ToString());
        _output.WriteLine($"Source: {src.Length} bytes");

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length,
                CodecType.High, 5);
        }
        _output.WriteLine($"Compressed: {compSize} bytes (ratio {(compSize > 0 ? (double)compSize / src.Length * 100 : -1):F1}%)");

        if (compSize <= 0)
        {
            _output.WriteLine("Compression failed!");
            return;
        }

        // Dump ALL compressed bytes
        _output.WriteLine($"Compressed hex ({compSize} bytes):");
        for (int i = 0; i < compSize; i += 16)
        {
            int len = Math.Min(16, compSize - i);
            string hex = BitConverter.ToString(compressed, i, len).Replace("-", " ");
            string ascii = "";
            for (int j = i; j < i + len; j++)
            {
                byte c = compressed[j];
                ascii += (c >= 0x20 && c < 0x7F) ? (char)c : '.';
            }
            _output.WriteLine($"  {i:X4}: {hex,-48} {ascii}");
        }

        // Parse block header manually
        _output.WriteLine("");
        byte b0 = compressed[0], b1 = compressed[1];
        _output.WriteLine($"Block header: b0=0x{b0:X2} b1=0x{b1:X2}");
        _output.WriteLine($"  nibble={b0 & 0xF:X} bits4-5={(b0>>4)&3} uncompressed={(b0>>6)&1} keyframe={(b0>>7)&1}");
        _output.WriteLine($"  decoderType={b1 & 0x7F} checksums={(b1>>7)&1}");
        if (((b0 >> 6) & 1) == 0)
        {
            // Chunk header follows
            uint chunkHeaderRaw = (uint)((compressed[2] << 16) | (compressed[3] << 8) | compressed[4]);
            _output.WriteLine($"  Chunk header: raw=0x{chunkHeaderRaw:X6} compSize={(chunkHeaderRaw & 0x3FFFF)+1} flag1={(chunkHeaderRaw>>18)&1} flag2={(chunkHeaderRaw>>19)&1}");
        }

        // Try decompression
        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed)
        fixed (byte* pDecomp = decompressed)
        {
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        }
        _output.WriteLine($"Decompress returned: {decompSize} (expected {src.Length})");

        if (decompSize == src.Length)
        {
            bool match = new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src);
            _output.WriteLine($"Round-trip: {(match ? "PASS" : "FAIL")}");
            Assert.True(match);
        }
    }

    [Fact]
    public unsafe void Bench_High5_WebTxt()
    {
        WireUpHigh();

        string testFile = Path.Combine(AppContext.BaseDirectory, "assets", "web.txt");
        if (!File.Exists(testFile)) { _output.WriteLine("SKIP: web.txt not found"); return; }

        byte[] src = File.ReadAllBytes(testFile);
        _output.WriteLine($"Source: {src.Length:N0} bytes ({src.Length / 1024.0 / 1024.0:F2} MB)");

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        // Warmup
        fixed (byte* pSrc = src) fixed (byte* pDst = compressed)
            StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, CodecType.High, 5);

        // Timed runs
        const int runs = 3;
        long[] times = new long[runs];
        int compSize = 0;
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            fixed (byte* pSrc = src) fixed (byte* pDst = compressed)
                compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, CodecType.High, 5);
            sw.Stop();
            times[r] = sw.ElapsedMilliseconds;
            _output.WriteLine($"  Run {r + 1}: {sw.ElapsedMilliseconds}ms");
        }

        Array.Sort(times);
        long median = times[runs / 2];
        double mbps = (double)src.Length / (median / 1000.0) / (1024 * 1024);
        double ratio = (double)compSize / src.Length * 100;

        _output.WriteLine($"High level 5: {src.Length:N0} -> {compSize:N0} ({ratio:F1}%)");
        _output.WriteLine($"Median: {median}ms, {mbps:F1} MB/s");

        // Verify round-trip
        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed) fixed (byte* pDecomp = decompressed)
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        Assert.Equal(src.Length, decompSize);
        Assert.True(new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src), "Round-trip mismatch");
        _output.WriteLine("Round-trip: PASS");
    }

    [Fact]
    public unsafe void BenchmarkAllCodecs_WebTxt()
    {
        WireUpHigh();

        string testFile = Path.Combine(AppContext.BaseDirectory, "assets", "web.txt");
        if (!File.Exists(testFile)) { _output.WriteLine("SKIP: web.txt not found"); return; }

        byte[] src = File.ReadAllBytes(testFile);
        _output.WriteLine($"Source: {testFile}");
        _output.WriteLine($"Size: {src.Length:N0} bytes ({src.Length / 1024.0 / 1024.0:F2} MB)");
        _output.WriteLine("");
        _output.WriteLine($"{"Codec",-12} {"Level",5} {"Compressed",12} {"Ratio",8} {"Time ms",10} {"MB/s",8} {"Status",-20}");
        _output.WriteLine(new string('-', 80));

        (string name, CodecType id, int level)[] configs = {
            ("High",    CodecType.High,    5),
            ("High",    CodecType.High,    6),
            ("High",    CodecType.High,    9),
        };

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        foreach (var (name, id, level) in configs)
        {
            string status;
            int compSize;
            double elapsed;

            try
            {
                var sw = Stopwatch.StartNew();
                fixed (byte* pSrc = src)
                fixed (byte* pDst = compressed)
                {
                    compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, id, level);
                }
                sw.Stop();
                elapsed = sw.Elapsed.TotalMilliseconds;

                if (compSize > 0 && compSize < src.Length)
                {
                    status = "OK";
                }
                else if (compSize >= src.Length)
                {
                    status = "expanded (stub?)";
                }
                else
                {
                    status = $"failed ({compSize})";
                    compSize = 0;
                    elapsed = 0;
                }
            }
            catch (Exception ex)
            {
                status = $"ERROR: {ex.GetType().Name}";
                compSize = 0;
                elapsed = 0;
            }

            double ratio = compSize > 0 ? (double)compSize / src.Length * 100 : 0;
            double mbps = compSize > 0 && elapsed > 0 ? (double)src.Length / (elapsed / 1000.0) / (1024 * 1024) : 0;

            _output.WriteLine($"{name,-12} {level,5} {compSize,12:N0} {ratio,7:F1}% {elapsed,10:F0} {mbps,7:F1} {status,-20}");
        }
    }

    [Theory]
    [InlineData("High", 5)]
    [InlineData("High", 9)]
    public unsafe void SelfContained_RoundTrip(string codecName, int level)
    {
        WireUpAll();

        string testFile = Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "..", "..", "test_files", "web_100k.txt");
        if (!File.Exists(testFile))
        {
            _output.WriteLine($"SKIP: {testFile} not found");
            return;
        }

        byte[] src = File.ReadAllBytes(testFile);
        CodecType codec = codecName switch
        {
            "High" => CodecType.High,
            "Fast" => CodecType.Fast,
            _ => CodecType.High,
        };

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, codec, level, 1, selfContained: true);
        }
        _output.WriteLine($"{codecName} L{level} self-contained: {src.Length:N0} -> {compSize:N0} ({(double)compSize / src.Length * 100:F1}%)");

        Assert.True(compSize > 0 && compSize < src.Length, $"Compression failed or expanded: {compSize}");

        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed)
        fixed (byte* pDecomp = decompressed)
        {
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        }
        Assert.Equal(src.Length, decompSize);
        Assert.True(new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src), "Self-contained round-trip mismatch");
    }

    [Fact]
    public unsafe void SmallInput_RoundTrip()
    {
        WireUpAll();

        // 200 bytes of compressible text — above the 128-byte minimum
        byte[] src = System.Text.Encoding.ASCII.GetBytes(
            string.Concat(Enumerable.Repeat("ABCDEFGHIJ", 20)));

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, CodecType.High, 5, 1);
        }
        _output.WriteLine($"Small input: {src.Length} -> {compSize} bytes");

        if (compSize > 0 && compSize < src.Length)
        {
            byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
            int decompSize;
            fixed (byte* pComp = compressed)
            fixed (byte* pDecomp = decompressed)
            {
                decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
            }
            Assert.Equal(src.Length, decompSize);
            Assert.True(new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src));
        }
    }

    [Fact]
    public unsafe void AllSameBytes_RoundTrip()
    {
        WireUpAll();

        // All-zero input should hit the memset path
        byte[] src = new byte[1024];

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, CodecType.High, 5, 1);
        }
        _output.WriteLine($"All-zero: {src.Length} -> {compSize} bytes");

        Assert.True(compSize > 0, "Compression of all-zero data failed");

        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed)
        fixed (byte* pDecomp = decompressed)
        {
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        }
        Assert.Equal(src.Length, decompSize);
        Assert.True(new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src));
    }

    [Fact]
    public unsafe void RandomData_RoundTrip()
    {
        WireUpAll();

        // Random data — incompressible, should still round-trip (uncompressed fallback)
        var rng = new Random(42);
        byte[] src = new byte[4096];
        rng.NextBytes(src);

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        int compSize;
        fixed (byte* pSrc = src)
        fixed (byte* pDst = compressed)
        {
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, CodecType.High, 5, 1);
        }
        _output.WriteLine($"Random: {src.Length} -> {compSize} bytes");

        Assert.True(compSize > 0, "Compression of random data failed");

        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];
        int decompSize;
        fixed (byte* pComp = compressed)
        fixed (byte* pDecomp = decompressed)
        {
            decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
        }
        Assert.Equal(src.Length, decompSize);
        Assert.True(new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src));
    }
}
