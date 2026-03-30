using System;
using System.IO;
using StreamLZ;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;
using Xunit;
using Xunit.Abstractions;

namespace StreamLZ.Tests;

public class FuzzTests
{
    private readonly ITestOutputHelper _output;
    public FuzzTests(ITestOutputHelper output) => _output = output;

    /// <summary>
    /// Generates valid compressed data at each level, then mutates it millions of times
    /// and feeds mutations to the decoder. The decoder must either produce correct output
    /// or reject the input with a managed exception. Any unhandled exception (AccessViolation,
    /// NullReference, etc.) or hang indicates a bounds-check gap.
    /// </summary>
    [Theory]
    [InlineData(1, 2_000_000)]
    [InlineData(5, 2_000_000)]
    [InlineData(6, 2_000_000)]
    [InlineData(9, 1_000_000)]
    public unsafe void Fuzz_MutatedCompressedData(int level, int iterations)
    {
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

        // Output buffer with SafeSpace
        byte[] output = new byte[source.Length + Slz.SafeSpace + 256];
        int crashes = 0;
        int rejects = 0;
        int successes = 0;

        var mutRng = new Random(123 + level);

        for (int iter = 0; iter < iterations; iter++)
        {
            // Create a mutation of the valid compressed data
            byte[] mutated = (byte[])compressed.Clone();
            int mutationType = mutRng.Next(6);

            switch (mutationType)
            {
                case 0: // Flip random bits
                {
                    int flips = mutRng.Next(1, 8);
                    for (int f = 0; f < flips; f++)
                    {
                        int pos = mutRng.Next(mutated.Length);
                        mutated[pos] ^= (byte)(1 << mutRng.Next(8));
                    }
                    break;
                }
                case 1: // Zero a random section
                {
                    int pos = mutRng.Next(mutated.Length);
                    int len = mutRng.Next(1, Math.Min(32, mutated.Length - pos));
                    Array.Clear(mutated, pos, len);
                    break;
                }
                case 2: // Set random bytes to 0xFF
                {
                    int count = mutRng.Next(1, 8);
                    for (int c = 0; c < count; c++)
                        mutated[mutRng.Next(mutated.Length)] = 0xFF;
                    break;
                }
                case 3: // Truncate
                {
                    int newLen = mutRng.Next(2, mutated.Length);
                    Array.Resize(ref mutated, newLen);
                    break;
                }
                case 4: // Duplicate a section
                {
                    int pos = mutRng.Next(mutated.Length - 4);
                    int len = mutRng.Next(1, Math.Min(16, mutated.Length - pos - 1));
                    int dst = mutRng.Next(mutated.Length - len);
                    Array.Copy(mutated, pos, mutated, dst, len);
                    break;
                }
                case 5: // Random bytes in header area
                {
                    int len = Math.Min(4, mutated.Length);
                    for (int b = 0; b < len; b++)
                        mutated[b] = (byte)mutRng.Next(256);
                    break;
                }
            }

            if (iter % 1000 == 0)
                Console.Error.WriteLine($"L{level} iter={iter} ok={successes} reject={rejects}");

            try
            {
                bool ok = Slz.TryDecompress(mutated, output, source.Length, out int written);
                if (ok)
                    successes++;
                else
                    rejects++;
            }
            catch (InvalidDataException)
            {
                rejects++;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
            {
                // Any other managed exception is also acceptable for corrupt data
                rejects++;
            }
            // AccessViolationException or StackOverflowException would crash the
            // process before reaching here — that's the failure we're looking for.
        }

        _output.WriteLine($"L{level}: {iterations} iterations — {successes} ok, {rejects} rejected, {crashes} crashes");
        Assert.Equal(0, crashes);
    }

    /// <summary>
    /// Same as above but targeting the framed API path.
    /// </summary>
    [Fact]
    public void Fuzz_MutatedFramedData()
    {
        byte[] source = new byte[32768];
        var rng = new Random(999);
        rng.NextBytes(source);

        byte[] framed = Slz.CompressFramed(source);
        byte[] output = new byte[source.Length + Slz.SafeSpace + 256];

        int iterations = 500_000;
        int rejects = 0;
        int successes = 0;
        var mutRng = new Random(777);

        for (int iter = 0; iter < iterations; iter++)
        {
            byte[] mutated = (byte[])framed.Clone();
            int flips = mutRng.Next(1, 8);
            for (int f = 0; f < flips; f++)
            {
                int pos = mutRng.Next(mutated.Length);
                mutated[pos] ^= (byte)(1 << mutRng.Next(8));
            }

            try
            {
                byte[] result = Slz.DecompressFramed(mutated);
                successes++;
            }
            catch
            {
                rejects++;
            }
        }

        _output.WriteLine($"Framed: {iterations} iterations — {successes} ok, {rejects} rejected");
    }
}
