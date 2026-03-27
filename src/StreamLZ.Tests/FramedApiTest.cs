using StreamLZ;
using Xunit;

namespace StreamLZ.Tests;

public class FramedApiTest
{
    [Fact]
    public void CompressFramed_DecompressFramed_RoundTrip()
    {
        byte[] original = System.Text.Encoding.UTF8.GetBytes(
            string.Concat(System.Linq.Enumerable.Repeat("Hello, StreamLZ framed API! ", 1000)));

        byte[] compressed = Slz.CompressFramed(original);
        byte[] restored = Slz.DecompressFramed(compressed);

        Assert.Equal(original, restored);
    }

    [Fact]
    public void CompressFramed_DecompressFramed_Empty()
    {
        byte[] compressed = Slz.CompressFramed([]);
        byte[] restored = Slz.DecompressFramed(compressed);
        Assert.Empty(restored);
    }

    [Fact]
    public void CompressFramed_DecompressFramed_AllLevels()
    {
        byte[] original = new byte[100_000];
        new System.Random(42).NextBytes(original);

        for (int level = 1; level <= 11; level++)
        {
            byte[] compressed = Slz.CompressFramed(original, level);
            byte[] restored = Slz.DecompressFramed(compressed);
            Assert.Equal(original, restored);
        }
    }

    [Fact]
    public void CompressFramed_DecompressFramed_Enwik8()
    {
        string path = System.IO.Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "assets", "enwik8.txt");
        if (!System.IO.File.Exists(path)) return;

        byte[] original = System.IO.File.ReadAllBytes(path);
        byte[] compressed = Slz.CompressFramed(original);
        byte[] restored = Slz.DecompressFramed(compressed);

        Assert.Equal(original.Length, restored.Length);
        Assert.Equal(original, restored);
    }
}
