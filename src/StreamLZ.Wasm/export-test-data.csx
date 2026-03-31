#!/usr/bin/env dotnet-script
#r "../StreamLZ/bin/Debug/net8.0/StreamLZ.dll"
#r "nuget: System.IO.Hashing, 9.0.4"

using System;
using System.IO;
using StreamLZ;

var dir = Path.Combine(Directory.GetCurrentDirectory(), "test-vectors");
Directory.CreateDirectory(dir);

void Export(string name, byte[] source, int level = 1)
{
    byte[] compressed = Slz.CompressFramed(source, level);
    byte[] decompressed = Slz.DecompressFramed(compressed);

    if (!source.AsSpan().SequenceEqual(decompressed))
        throw new Exception($"{name}: round-trip mismatch!");

    File.WriteAllBytes(Path.Combine(dir, $"{name}.slz"), compressed);
    File.WriteAllBytes(Path.Combine(dir, $"{name}.raw"), source);
    Console.WriteLine($"  {name}: {source.Length} -> {compressed.Length} bytes");
}

Console.WriteLine("Exporting test vectors...");

// 1. Repeating pattern 64KB
{
    byte[] src = new byte[64 * 1024];
    for (int i = 0; i < src.Length; i++) src[i] = (byte)(i & 0xFF);
    Export("pattern64k", src);
}

// 2. Single byte
Export("onebyte", new byte[] { 0x42 });

// 3. All zeros 1KB
Export("zeros1k", new byte[1024]);

// 4. Empty
Export("empty", Array.Empty<byte>());

// 5. Boundary crossing: 256KB + 1
{
    byte[] src = new byte[256 * 1024 + 1];
    new Random(88).NextBytes(src);
    Export("boundary", src);
}

// 6. Small text (structured data)
{
    byte[] src = System.Text.Encoding.UTF8.GetBytes(
        string.Join("\n", Enumerable.Range(0, 1000).Select(i => $"line {i}: the quick brown fox jumps over the lazy dog")));
    Export("text", src);
}

// 7. Random (incompressible) 4KB
{
    byte[] src = new byte[4096];
    new Random(42).NextBytes(src);
    Export("random4k", src);
}

Console.WriteLine("Done.");
