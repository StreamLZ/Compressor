using System;
using System.IO;
using StreamLZ;
using StreamLZ.Compression;
using Xunit;

namespace StreamLZ.Tests;

/// <summary>
/// Regression tests for specific fuzz inputs that previously crashed the process.
/// Each test generates the exact mutation that triggered a bug, then verifies
/// the decoder rejects it gracefully (no crash, no AccessViolation).
/// </summary>
public unsafe class FuzzRegressionTests
{
    /// <summary>
    /// Generates valid compressed data at the given level, then applies a specific
    /// deterministic mutation (same RNG seeds as the fuzz harness).
    /// </summary>
    private static byte[] GenerateFuzzInput(int level, int iteration)
    {
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

        // Advance the mutation RNG to the target iteration
        var mutRng = new Random(123 + level);
        byte[] mutated = null!;

        for (int iter = 0; iter <= iteration; iter++)
        {
            mutated = (byte[])compressed.Clone();
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
        }

        return mutated;
    }

    /// <summary>
    /// Asserts that a corrupt input is rejected gracefully — no crash.
    /// </summary>
    private static void AssertRejectsGracefully(byte[] mutated, int originalSize)
    {
        byte[] output = new byte[originalSize + Slz.SafeSpace + 256];

        // Must not crash. May return false or throw a managed exception.
        try
        {
            Slz.TryDecompress(mutated, output, originalSize, out _);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            // Any managed exception is acceptable for corrupt data
        }
        // If we reach here, no AccessViolation — test passes.
    }

    /// <summary>
    /// L6, seed 129, iteration 0: bit-flip mutation that caused PreScanChunks
    /// to compute chunk sizes past the source buffer, leading to AccessViolation
    /// in BitReader_Refill via the parallel decompress path.
    /// Fixed by: bounds check on CompressedSize in PreScanChunks.
    /// </summary>
    [Fact]
    public void Regression_L6_Iter0_PreScanChunksOOB()
    {
        byte[] mutated = GenerateFuzzInput(level: 6, iteration: 0);
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// L6, seed 129, iteration 1: second mutation variant.
    /// </summary>
    [Fact]
    public void Regression_L6_Iter1()
    {
        byte[] mutated = GenerateFuzzInput(level: 6, iteration: 1);
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// L6, seed 129, iteration 2: third mutation variant.
    /// </summary>
    [Fact]
    public void Regression_L6_Iter2()
    {
        byte[] mutated = GenerateFuzzInput(level: 6, iteration: 2);
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// Corrupt self-contained flag: flip the self-contained bit to exercise
    /// the parallel decompress path with data that expects serial decode.
    /// </summary>
    [Fact]
    public void Regression_L6_CorruptSelfContainedFlag()
    {
        byte[] mutated = GenerateFuzzInput(level: 6, iteration: 0);
        // Flip bit 5 of byte 0 (self-contained flag area in block header)
        if (mutated.Length > 0)
            mutated[0] ^= 0x20;
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// Truncated to just the header — decoder must not read past the buffer.
    /// </summary>
    [Fact]
    public void Regression_L6_TruncatedToHeader()
    {
        byte[] mutated = GenerateFuzzInput(level: 6, iteration: 0);
        Array.Resize(ref mutated, Math.Min(16, mutated.Length));
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// All zeros — exercises header parsing with invalid magic/format.
    /// </summary>
    [Fact]
    public void Regression_AllZeros()
    {
        byte[] mutated = new byte[1024];
        AssertRejectsGracefully(mutated, 65536);
    }

    /// <summary>
    /// All 0xFF — exercises header parsing with maximal field values.
    /// </summary>
    [Fact]
    public void Regression_AllOnes()
    {
        byte[] mutated = new byte[1024];
        Array.Fill(mutated, (byte)0xFF);
        AssertRejectsGracefully(mutated, 65536);
    }
}
