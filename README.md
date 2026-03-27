# StreamLZ

High-performance LZ compression library for .NET with streaming support.

## Features

- **5.6 GB/s decompress** at level 1, **27% ratio** at level 11 (enwik8)
- **Single level scale** (1-11) — no codec selection needed
- **Streaming** — SLZ1 frame format supports files of any size
- **Sliding window** — cross-block match references for better ratio
- **Parallel compression** — automatic multi-threading
- **Zero allocations** on the hot path (pooled scratch buffers)
- **JIT warmup** — `Slz.WarmUp()` pre-compiles decompression hot paths

## Quick Start

```csharp
using StreamLZ;

// Simplest: compress and decompress byte arrays (SLZ1 framed, self-describing)
byte[] compressed = Slz.CompressFramed(data);
byte[] restored = Slz.DecompressFramed(compressed); // no size tracking needed

// Compress / decompress files
Slz.CompressFile("input.txt", "output.slz");
Slz.DecompressFile("output.slz", "restored.txt");

// Stream-based (any size)
Slz.CompressStream(input, output, level: 6);

// Named compression levels
byte[] fast = Slz.CompressFramed(data, SlzCompressionLevel.Fast);
byte[] max = Slz.CompressFramed(data, SlzCompressionLevel.Maximum);
```

## Compression Levels

| Level | Compress | Decompress | Ratio (enwik8) | Description |
|-------|----------|------------|----------------|-------------|
| 1 | 456 MB/s | 5.3 GB/s | 56.5% | Fastest |
| 2 | 278 MB/s | 5.6 GB/s | 53.9% | |
| 3 | 222 MB/s | 4.8 GB/s | 52.3% | |
| 4 | 155 MB/s | 4.5 GB/s | 48.4% | |
| 5 | 61 MB/s | 4.8 GB/s | 42.2% | |
| **6** | **58 MB/s** | **3.8 GB/s** | **33.7%** | **Default** |
| 7 | 42 MB/s | 3.8 GB/s | 33.6% | |
| 8 | 33 MB/s | 3.8 GB/s | 33.7% | |
| 9 | 6.0 MB/s | 1.4 GB/s | 27.4% | |
| 10 | 5.9 MB/s | 1.4 GB/s | 27.3% | |
| 11 | 5.7 MB/s | 1.4 GB/s | 27.3% | Maximum ratio |

## API

StreamLZ offers three API tiers. Choose based on your use case:

### Framed in-memory (simplest — self-describing round-trip)

Uses the SLZ1 frame format. Output includes size metadata so decompression
needs no external information. Best for storing/transmitting compressed blobs.

```csharp
byte[] compressed = Slz.CompressFramed(data);
byte[] restored = Slz.DecompressFramed(compressed);

// Named levels for readability
byte[] fast = Slz.CompressFramed(data, SlzCompressionLevel.Fast);
```

### Raw in-memory (zero-copy — caller manages buffers)

No framing. Caller must track the original size and provide output buffers
(including `Slz.SafeSpace` extra bytes for decompression). Best for hot paths
where you control the buffer lifecycle.

```csharp
int bound = Slz.GetCompressBound(data.Length);
byte[] dst = new byte[bound];
int compSize = Slz.Compress(data, dst, level: 3);

byte[] output = new byte[originalSize + Slz.SafeSpace];
Slz.Decompress(compressed, output, originalSize);

// Non-throwing variant for untrusted data
if (Slz.TryDecompress(compressed, output, originalSize, out int written))
    // success
```

**Important:** Raw and framed formats are not interchangeable. Data compressed
with `Compress` must be decompressed with `Decompress` (not `DecompressFramed`),
and vice versa.

### File and stream (any size, SLZ1 framed)

Uses the SLZ1 frame format with a sliding window for cross-block match references.
Supports files of any size with bounded memory usage.

```csharp
// Sync
Slz.CompressFile("input.txt", "output.slz");
Slz.DecompressFile("output.slz", "restored.txt");
Slz.CompressStream(input, output, level: 6);
Slz.DecompressStream(input, output);

// Async
await Slz.CompressFileAsync("input.txt", "output.slz", cancellationToken: ct);
await Slz.DecompressFileAsync("output.slz", "restored.txt", cancellationToken: ct);

// With content checksum for integrity verification
Slz.CompressFile("input.txt", "output.slz", useContentChecksum: true);

// Limit compression threads (for server workloads)
Slz.CompressFile("input.txt", "output.slz", maxThreads: 4);
```

### SlzStream (GZipStream-style wrapper)

```csharp
// Compress (supports await using for async disposal)
await using var compressStream = new SlzStream(outputStream, CompressionMode.Compress);
inputStream.CopyTo(compressStream);

// Decompress
await using var decompressStream = new SlzStream(inputStream, CompressionMode.Decompress);
decompressStream.CopyTo(outputStream);

// With options
var options = new SlzStreamOptions
{
    Level = 9,
    UseContentChecksum = true,
    LeaveOpen = true
};
await using var stream = new SlzStream(inner, CompressionMode.Compress, options);
```

**Note:** Disposing an `SlzStream` in compress mode without writing any data produces
no output. To get a valid empty SLZ1 stream, write at least one byte, or use
`CompressFramed(ReadOnlySpan<byte>.Empty)`.

### Validation

```csharp
bool valid = Slz.IsValidFrame(compressedData);
bool valid = Slz.IsValidFrame(stream); // rewinds if seekable
```

### JIT warmup (optional)

```csharp
// Called automatically on first use of Slz. Call explicitly at app
// startup to move the ~15ms JIT cost to a predictable point.
Slz.WarmUp();
```

## Comparison vs LZ4, Snappy, Zstd

### enwik8 (100 MB text, 3-run median)

| Compressor | Ratio | Compress | Decompress |
|---|---|---|---|
| Snappy | 56.7% | 497 MB/s | 1,306 MB/s |
| LZ4 Fast | 57.3% | 484 MB/s | 4,335 MB/s |
| **SLZ L1** | **58.6%** | **348 MB/s** | **5,961 MB/s** |
| Zstd 1 | 40.7% | 424 MB/s | 935 MB/s |
| LZ4 Max | 41.9% | 23 MB/s | 4,541 MB/s |
| **SLZ L5** | **42.2%** | **61 MB/s** | **4,768 MB/s** |
| **SLZ L6** | **33.7%** | **59 MB/s** | **3,815 MB/s** |
| Zstd 3 | 35.5% | 273 MB/s | 1,289 MB/s |
| Zstd 9 | 31.1% | 66 MB/s | 1,403 MB/s |
| **SLZ L11** | **27.3%** | **5.7 MB/s** | **1,467 MB/s** |
| Zstd 19 | 26.9% | 2.2 MB/s | 1,207 MB/s |

### silesia (212 MB mixed, 3-run median)

| Compressor | Ratio | Compress | Decompress |
|---|---|---|---|
| Snappy | 48.1% | 802 MB/s | 1,970 MB/s |
| LZ4 Fast | 47.4% | 712 MB/s | 4,510 MB/s |
| **SLZ L1** | **47.1%** | **533 MB/s** | **6,342 MB/s** |
| Zstd 1 | 34.5% | 575 MB/s | 1,309 MB/s |
| LZ4 Max | 36.3% | 17 MB/s | 4,832 MB/s |
| **SLZ L5** | **36.4%** | **82 MB/s** | **5,485 MB/s** |
| **SLZ L6** | **28.2%** | **86 MB/s** | **6,150 MB/s** |
| Zstd 9 | 27.9% | 91 MB/s | 1,318 MB/s |
| **SLZ L11** | **24.7%** | **7.7 MB/s** | **1,735 MB/s** |
| Zstd 19 | 24.9% | 3.5 MB/s | 1,215 MB/s |

*All benchmarks on Intel Arrow Lake-S (Ultra 9 285K), .NET 10, multi-threaded.*

## License

MIT
