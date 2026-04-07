# StreamLZ

High-performance LZ compression library for .NET with streaming support.

## Features

- **Up to 11.0 GB/s decompress** (level 8, silesia), **down to 25.5% ratio** (level 11, enwik8)
- **Simple level scale** (1-11) — higher = better ratio, slower
- **Streaming** — SLZ1 frame format supports files of any size
- **Sliding window** — cross-block match references for better ratio
- **Parallel compress and decompress** — automatic multi-threading at L6+ (see [Threading Model](#threading-model))
- **Async** — `CompressFileAsync`, `DecompressFileAsync`, `IAsyncDisposable` on `SlzStream`
- **Validation** — `TryDecompress` (non-throwing), `IsValidFrame`, content checksums
- **Zero allocations** on the hot path (pooled scratch buffers)
- **Native AOT and trimming** compatible
- Targets **net8.0** and **net10.0**

## Installation

```
dotnet add package StreamLZ
```

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

| Level | Codec | Matcher | Compress | Decompress | Ratio (enwik8) | Parallel Compress | Parallel Decompress |
|-------|-------|---------|----------|------------|----------------|:-----------------:|:-------------------:|
| 1 | Fast | Hash | 287 MB/s | 5.4 GB/s | 58.6% | | |
| 2 | Fast | Hash | 243 MB/s | 5.4 GB/s | 56.9% | | |
| 3 | Fast | Hash | 225 MB/s | 5.3 GB/s | 56.5% | | |
| 4 | Fast | Hash | 231 MB/s | 4.4 GB/s | 54.0% | | |
| 5 | Fast | Hash | 58 MB/s | 4.6 GB/s | 42.2% | | |
| **6** | **High SC** | **Hash** | **56 MB/s** | **5.7 GB/s** | **33.7%** | :white_check_mark: | :white_check_mark: |
| 7 | High SC | Hash | 39 MB/s | 5.8 GB/s | 33.6% | :white_check_mark: | :white_check_mark: |
| 8 | High SC | **BT4** | 32 MB/s | 5.8 GB/s | 33.4% | :white_check_mark: | :white_check_mark: |
| 9 | High | Hash | 6.0 MB/s | 1.3 GB/s | 27.4% | | partial |
| 10 | High | Hash | 5.8 MB/s | 1.3 GB/s | 27.2% | | partial |
| 11 | High | **BT4** | 1.3 MB/s | 1.1 GB/s | **25.5%** | | partial |

See [Threading Model](#threading-model) below for details on how parallelism works at each level.

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

| Compressor | Ratio | Compress | Decompress | Parallel Compress | Parallel Decompress |
|---|---|---|---|:-:|:-:|
| Snappy | 56.7% | 518 MB/s | 1,177 MB/s | | |
| LZ4 Fast | 57.3% | 484 MB/s | 4,335 MB/s | | |
| **SLZ L1** | **58.6%** | **288 MB/s** | **5,421 MB/s** | | |
| Zstd 1 | 40.7% | 422 MB/s | 1,072 MB/s | | |
| LZ4 Max | 41.9% | 23 MB/s | 4,335 MB/s | | |
| **SLZ L5** | **42.2%** | **59 MB/s** | **4,402 MB/s** | | |
| Zstd 3 | 35.5% | 282 MB/s | 1,289 MB/s | | |
| **SLZ L6** | **33.7%** | **55 MB/s** | **5,470 MB/s** | :white_check_mark: | :white_check_mark: |
| Zstd 9 | 31.1% | 65 MB/s | 1,223 MB/s | | |
| Zstd 19 | 26.9% | 2.1 MB/s | 926 MB/s | | |
| **SLZ L11** | **27.3%** | **5.5 MB/s** | **1,339 MB/s** | | **partial** |

### silesia (212 MB mixed, 3-run median)

| Compressor | Ratio | Compress | Decompress | Parallel Compress | Parallel Decompress |
|---|---|---|---|:-:|:-:|
| Snappy | 48.1% | 763 MB/s | 1,573 MB/s | | |
| LZ4 Fast | 47.4% | 717 MB/s | 4,510 MB/s | | |
| **SLZ L1** | **47.1%** | **421 MB/s** | **5,858 MB/s** | | |
| Zstd 1 | 34.5% | 561 MB/s | 1,074 MB/s | | |
| LZ4 Max | 36.3% | 17 MB/s | 4,832 MB/s | | |
| **SLZ L5** | **36.4%** | **79 MB/s** | **5,222 MB/s** | | |
| **SLZ L6** | **28.2%** | **73 MB/s** | **10,817 MB/s** | :white_check_mark: | :white_check_mark: |
| Zstd 9 | 27.9% | 88 MB/s | 1,121 MB/s | | |
| **SLZ L11** | **24.7%** | **7.5 MB/s** | **1,370 MB/s** | | **partial** |

*All benchmarks on Intel Arrow Lake-S (Ultra 9 285K), 24-core, .NET 10.*

## Threading Model

StreamLZ uses different threading strategies depending on the compression level:

- **L1-L5 (Fast codec):** Single-threaded compress and decompress. The high decompress throughput (5+ GB/s) comes from the simple token format, not parallelism.
- **L6-L8 (High codec, self-contained):** Fully parallel. Each 256KB chunk is compressed and decompressed independently across all available cores. This is why L6 decompresses at 5.3 GB/s despite using a more complex codec than L1.
- **L9-L11 (High codec, sliding window):** Compression is single-threaded because chunks reference previous output via a sliding window. Decompression uses a batched two-phase approach that processes chunks in batches of `ProcessorCount` (e.g. 24 on a 24-core machine). For each batch:
  1. **Phase 1 (parallel):** `ReadLzTable` runs on all chunks in the batch simultaneously — this decodes the entropy streams (Huffman/tANS) and unpacks offsets, which is the most CPU-intensive part.
  2. **Phase 2 (serial):** `ProcessLzRuns` resolves tokens and copies literals/matches for each chunk in order, since match copies can reference output from earlier chunks.

  Then the next batch starts. This yields ~47% faster decompression than fully serial on a 24-core machine.

Compression thread count can be limited with the `maxThreads` parameter (e.g. for server workloads). Decompression threading is automatic and cannot be disabled.

## License

MIT
