using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using Xunit;

namespace StreamLZ.Tests;

/// <summary>
/// Wire format stability tests. These verify that the compressor produces
/// byte-identical output for known inputs, catching accidental format breaks.
///
/// To regenerate golden files after an intentional format change:
///   1. Delete all *.golden files from TestData/
///   2. Run the [Fact(Skip = ...)] GenerateGoldenFiles test manually
///   3. Commit the new golden files
/// </summary>
public class GoldenTests
{
    // ── Deterministic test inputs (constructed in code, no external files) ──

    /// <summary>Short ASCII string — tests minimum-size compression.</summary>
    private static byte[] HelloInput => Encoding.UTF8.GetBytes(
        "Hello, World! This is a test of the StreamLZ compression library. " +
        "Hello, World! This is a test of the StreamLZ compression library. " +
        "Hello, World! This is a test of the StreamLZ compression library. " +
        "Hello, World! This is a test of the StreamLZ compression library.");

    /// <summary>1 KB of zeros — tests memset/constant detection.</summary>
    private static byte[] ZerosInput => new byte[1024];

    /// <summary>
    /// 4 KB of deterministic pseudorandom data — tests general compression.
    /// Uses a fixed seed so the output is identical across runs and platforms.
    /// </summary>
    private static byte[] PseudoRandomInput
    {
        get
        {
            // Simple LCG with fixed seed for cross-platform determinism.
            // Do NOT use Random (implementation varies across .NET versions).
            var data = new byte[4096];
            uint state = 0xDEADBEEF;
            for (int i = 0; i < data.Length; i++)
            {
                state = state * 1103515245 + 12345;
                data[i] = (byte)(state >> 16);
            }
            return data;
        }
    }

    /// <summary>
    /// 8 KB of repetitive English text — tests dictionary matching.
    /// </summary>
    private static byte[] RepetitiveTextInput
    {
        get
        {
            var sb = new StringBuilder();
            string[] phrases =
            [
                "the quick brown fox jumps over the lazy dog ",
                "pack my box with five dozen liquor jugs ",
                "how vexingly quick daft zebras jump ",
                "the five boxing wizards jump quickly ",
            ];
            int idx = 0;
            while (sb.Length < 8192)
            {
                sb.Append(phrases[idx % phrases.Length]);
                idx++;
            }
            return Encoding.UTF8.GetBytes(sb.ToString(0, 8192));
        }
    }

    private static readonly (string Name, byte[] Data)[] TestCases =
    [
        ("hello", HelloInput),
        ("zeros", ZerosInput),
        ("pseudorandom", PseudoRandomInput),
        ("repetitive_text", RepetitiveTextInput),
    ];

    private static readonly int[] TestLevels = [1, 6, 9];

    // ── Golden file verification ──

    [Theory]
    [MemberData(nameof(GetGoldenTestCases))]
    public void CompressedOutput_MatchesGoldenFile(string name, int level)
    {
        var (_, data) = Array.Find(TestCases, t => t.Name == name);
        Assert.NotNull(data);

        byte[] compressed = Slz.Compress(data, level);
        byte[] golden = LoadGoldenFile($"{name}_L{level}.golden");

        Assert.True(compressed.Length == golden.Length,
            $"Size mismatch for {name} L{level}: got {compressed.Length}, expected {golden.Length}");
        Assert.True(compressed.AsSpan().SequenceEqual(golden),
            $"Content mismatch for {name} L{level} (same size {compressed.Length} but different bytes)");
    }

    [Theory]
    [MemberData(nameof(GetGoldenTestCases))]
    public void GoldenFile_DecompressesCorrectly(string name, int level)
    {
        var (_, data) = Array.Find(TestCases, t => t.Name == name);
        Assert.NotNull(data);

        byte[] golden = LoadGoldenFile($"{name}_L{level}.golden");

        byte[] output = new byte[data.Length + Slz.SafeSpace];
        int decompressed = Slz.Decompress(golden, output, data.Length);

        Assert.Equal(data.Length, decompressed);
        Assert.True(data.AsSpan().SequenceEqual(output.AsSpan(0, data.Length)),
            $"Decompressed output from golden file {name}_L{level} does not match original input");
    }

    public static TheoryData<string, int> GetGoldenTestCases()
    {
        var data = new TheoryData<string, int>();
        foreach (var (name, _) in TestCases)
        {
            foreach (int level in TestLevels)
            {
                data.Add(name, level);
            }
        }
        return data;
    }

    // ── Golden file generation (run manually to regenerate) ──

    [Fact(Skip = "Run manually to regenerate golden files: remove Skip, run, re-add Skip")]
    public void GenerateGoldenFiles()
    {
        string testDataDir = Path.Combine(GetProjectDir(), "TestData");
        Directory.CreateDirectory(testDataDir);

        foreach (var (name, data) in TestCases)
        {
            foreach (int level in TestLevels)
            {
                byte[] compressed = Slz.Compress(data, level);

                // Verify round-trip before saving
                byte[] output = new byte[data.Length + Slz.SafeSpace];
                int decompressed = Slz.Decompress(compressed, output, data.Length);
                Assert.Equal(data.Length, decompressed);
                Assert.True(data.AsSpan().SequenceEqual(output.AsSpan(0, data.Length)));

                string path = Path.Combine(testDataDir, $"{name}_L{level}.golden");
                File.WriteAllBytes(path, compressed);
            }
        }
    }

    // ── Helpers ──

    private static byte[] LoadGoldenFile(string resourceName)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "TestData", resourceName);
        if (!File.Exists(path))
            throw new FileNotFoundException($"Golden file not found: {path}");
        return File.ReadAllBytes(path);
    }

    private static string GetProjectDir([CallerFilePath] string? filePath = null)
    {
        return Path.GetDirectoryName(filePath)!;
    }
}
