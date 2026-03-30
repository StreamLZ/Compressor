using System;
using System.Diagnostics;
using System.IO;
using StreamLZ;
using StreamLZ.Common;
using StreamLZ.Compression;

namespace StreamLZ.Tests;

/// <summary>
/// Standalone fuzz harness that survives crashes.
/// Writes progress to a watermark file before each decompress attempt.
/// If the process crashes, the watermark file contains the exact crashing level+iteration.
///
/// Usage from test: dotnet test --filter "DisplayName~FuzzHarness_Level"
/// Or run the static method directly.
/// </summary>
public static class FuzzHarness
{
    private static readonly string WatermarkPath = Path.Combine(Path.GetTempPath(), "slz-fuzz-watermark.txt");
    private static readonly string CrashDir = Path.Combine(Path.GetTempPath(), "slz-fuzz-crashes");

    public static unsafe int RunLevel(int level, int iterations)
    {
        Directory.CreateDirectory(CrashDir);

        // Generate valid source and compressed data
        byte[] source = new byte[65536];
        var rng = new Random(42 + level);
        for (int i = 0; i < source.Length; i++)
            source[i] = (byte)(rng.Next(26) + 'a');

        int bound = StreamLZCompressor.GetCompressBound(source.Length);
        byte[] validCompressed = new byte[bound];
        int compSize;
        fixed (byte* pSrc = source)
        fixed (byte* pDst = validCompressed)
        {
            var mapped = Slz.MapLevel(level);
            compSize = StreamLZCompressor.Compress(
                pSrc, source.Length, pDst, validCompressed.Length,
                mapped.Codec, mapped.CodecLevel, numThreads: 1,
                selfContained: mapped.SelfContained);
        }

        byte[] compressed = new byte[compSize];
        Array.Copy(validCompressed, compressed, compSize);

        byte[] output = new byte[source.Length + Slz.SafeSpace + 256];
        int crashes = 0, rejects = 0, successes = 0;
        var mutRng = new Random(123 + level);

        // To skip ahead: set skipTo > 0. The RNG must still advance for skipped
        // iterations, so we run the mutation logic but skip the decompress.
        int skipTo = 0;

        for (int iter = 0; iter < iterations; iter++)
        {
            byte[] mutated = (byte[])compressed.Clone();
            int mutationType = mutRng.Next(6);

            switch (mutationType)
            {
                case 0:
                {
                    int flips = mutRng.Next(1, 8);
                    for (int f = 0; f < flips; f++)
                    {
                        int pos = mutRng.Next(mutated.Length);
                        mutated[pos] ^= (byte)(1 << mutRng.Next(8));
                    }
                    break;
                }
                case 1:
                {
                    int pos = mutRng.Next(mutated.Length);
                    int len = mutRng.Next(1, Math.Min(32, mutated.Length - pos));
                    Array.Clear(mutated, pos, len);
                    break;
                }
                case 2:
                {
                    int count = mutRng.Next(1, 8);
                    for (int c = 0; c < count; c++)
                        mutated[mutRng.Next(mutated.Length)] = 0xFF;
                    break;
                }
                case 3:
                {
                    int newLen = mutRng.Next(2, mutated.Length);
                    Array.Resize(ref mutated, newLen);
                    break;
                }
                case 4:
                {
                    int pos = mutRng.Next(mutated.Length - 4);
                    int len = mutRng.Next(1, Math.Min(16, mutated.Length - pos - 1));
                    int dst = mutRng.Next(mutated.Length - len);
                    Array.Copy(mutated, pos, mutated, dst, len);
                    break;
                }
                case 5:
                {
                    int len = Math.Min(4, mutated.Length);
                    for (int b = 0; b < len; b++)
                        mutated[b] = (byte)mutRng.Next(256);
                    break;
                }
            }

            if (iter < skipTo) continue;

            // Write watermark BEFORE attempting decompress.
            if (iter % 100 == 0)
            {
                File.WriteAllText(WatermarkPath, $"L{level} iter={iter}");
            }

            if (iter % 10000 == 0)
            {
                Console.Error.WriteLine($"L{level} iter={iter} ok={successes} reject={rejects}");
                Console.Error.Flush();
            }

            try
            {
                bool ok = Slz.TryDecompress(mutated, output, source.Length, out int written);
                if (ok) successes++;
                else rejects++;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
            {
                rejects++;
            }
            // AccessViolationException kills the process.
            // The watermark file will contain the last written iteration.
        }

        Console.WriteLine($"L{level}: {iterations} iters — {successes} ok, {rejects} rejected, {crashes} crashes");
        return crashes;
    }
}
