# StreamLZ

High-performance LZ compression library for .NET with streaming support.

## Features

- **Up to 11.8 GB/s decompress** (level 8, enwik9), **down to 22.2% ratio** (level 11, enwik9)
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

| Level | Codec | Matcher | Parallel Compress | Parallel Decompress | Notes |
|-------|-------|---------|:-----------------:|:-------------------:|-------|
| 1 | Fast | Hash | | | Fastest compress |
| 2 | Fast | Hash | | | |
| 3 | Fast | Hash | | | |
| 4 | Fast | Hash | | | |
| 5 | Fast | Hash | | | Best Fast ratio |
| **6** | **High SC** | **Hash** | :white_check_mark: | :white_check_mark: | **Recommended default** |
| 7 | High SC | Hash | :white_check_mark: | :white_check_mark: | |
| 8 | High SC | **BT4** | :white_check_mark: | :white_check_mark: | Best SC ratio |
| 9 | High | Hash | | partial | Sliding window |
| 10 | High | Hash | | partial | |
| 11 | High | **BT4** | | partial | Maximum ratio |

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

// Async (uses serial compression path — prefer sync overloads for max throughput)
await Slz.CompressFileAsync("input.txt", "output.slz", cancellationToken: ct);
await Slz.DecompressFileAsync("output.slz", "restored.txt", cancellationToken: ct);

// With content checksum for integrity verification
Slz.CompressFile("input.txt", "output.slz", useContentChecksum: true);

// Limit compression threads (for server workloads)
Slz.CompressFile("input.txt", "output.slz", maxThreads: 4);
```

### SlzStream (streaming wrapper)

Similar to `GZipStream`, but with some differences: `Flush()` is a no-op
(data is flushed on `Dispose`), `WriteAsync` performs synchronous compression,
and compression is single-threaded (one block at a time).

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

### enwik9 (1 GB text, 3-run median)

| Compressor | Ratio | Compress | Decompress | Parallel Compress | Parallel Decompress |
|---|---|---|---|:-:|:-:|
| Snappy | 50.9% | 556 MB/s | 1,511 MB/s | | |
| LZ4 Fast | 50.9% | 532 MB/s | 4,258 MB/s | | |
| **SLZ L1** | **52.3%** | **336 MB/s** | **5,667 MB/s** | | |
| Zstd 1 | 35.7% | 468 MB/s | 1,160 MB/s | | |
| LZ4 Max | 37.2% | 25 MB/s | 4,477 MB/s | | |
| **SLZ L5** | **38.2%** | **65 MB/s** | **4,954 MB/s** | | |
| Zstd 3 | 31.2% | 318 MB/s | 1,223 MB/s | | |
| **SLZ L6** | **27.8%** | **57 MB/s** | **10,678 MB/s** | :white_check_mark: | :white_check_mark: |
| Zstd 9 | 27.2% | 71 MB/s | 1,415 MB/s | | |
| **SLZ L8** | **27.3%** | **26 MB/s** | **11,788 MB/s** | :white_check_mark: | :white_check_mark: |
| Zstd 19 | 23.5% | 2.2 MB/s | 1,334 MB/s | | |
| **SLZ L11** | **22.2%** | **1.5 MB/s** | **1,054 MB/s** | | **partial** |

### silesia (212 MB mixed, 3-run median)

| Compressor | Ratio | Compress | Decompress | Parallel Compress | Parallel Decompress |
|---|---|---|---|:-:|:-:|
| Snappy | 48.1% | 752 MB/s | 1,429 MB/s | | |
| LZ4 Fast | 47.4% | 695 MB/s | 4,510 MB/s | | |
| **SLZ L1** | **47.1%** | **440 MB/s** | **5,790 MB/s** | | |
| Zstd 1 | 34.5% | 567 MB/s | 1,390 MB/s | | |
| LZ4 Max | 36.3% | 17 MB/s | 4,832 MB/s | | |
| **SLZ L5** | **36.4%** | **77 MB/s** | **5,196 MB/s** | | |
| **SLZ L6** | **26.7%** | **62 MB/s** | **9,432 MB/s** | :white_check_mark: | :white_check_mark: |
| Zstd 9 | 27.9% | 81 MB/s | 1,515 MB/s | | |
| Zstd 19 | 24.9% | 3.2 MB/s | 1,052 MB/s | | |
| **SLZ L11** | **24.2%** | **3.0 MB/s** | **1,439 MB/s** | | **partial** |

*All benchmarks on Intel Arrow Lake-S (Ultra 9 285K), 24-core, .NET 10.
LZ4, Snappy, and Zstd are single-threaded. SLZ rows marked with checkmarks
use parallel compression and/or decompression — see the Parallel columns.*

## Choosing a Level

| Use case | Recommended | Why |
|----------|-------------|-----|
| Logging, IPC, hot caches | L1 | Fastest compress (300+ MB/s), 5+ GB/s decompress |
| Network transfer, databases | L5 or L6 | L5 is single-threaded; L6 adds parallel compress/decompress |
| General storage | **L6** (default) | Best balance: 27% ratio, 10+ GB/s parallel decompress |
| Maximum parallel ratio | L8 | BT4 match finder, slightly better ratio than L6 |
| Archival, cold storage | L11 | Best ratio (22%), accepts slow compress |

## Threading Model

StreamLZ uses different threading strategies depending on the compression level:

- **L1-L5 (Fast codec):** Single-threaded compress and decompress. The high decompress throughput (5+ GB/s) comes from the simple token format, not parallelism.
- **L6-L8 (High codec, self-contained):** Fully parallel. Chunks are grouped (4 × 256KB = 1MB per group) and each group is assigned to one thread. Within a group, chunks are compressed/decompressed sequentially with cross-chunk context, giving the match finder a larger search window. Between groups there are no references, preserving full parallelism across all available cores.
- **L9-L11 (High codec, sliding window):** Compression is single-threaded because chunks reference previous output via a sliding window. Decompression uses a batched two-phase approach that processes chunks in batches of `ProcessorCount` (e.g. 24 on a 24-core machine). For each batch:
  1. **Phase 1 (parallel):** `ReadLzTable` runs on all chunks in the batch simultaneously — this decodes the entropy streams (Huffman/tANS) and unpacks offsets, which is the most CPU-intensive part.
  2. **Phase 2 (serial):** `ProcessLzRuns` resolves tokens and copies literals/matches for each chunk in order, since match copies can reference output from earlier chunks.

  Then the next batch starts. This yields ~47% faster decompression than fully serial on a 24-core machine.

Compression thread count can be limited with the `maxThreads` parameter (e.g. for server workloads). Decompression threading is automatic and cannot be disabled.

## Thread Safety

- **`Slz` static methods** (`CompressFramed`, `DecompressFramed`, `CompressStream`, etc.): thread-safe. Multiple threads can compress/decompress concurrently.
- **`SlzStream`**: not thread-safe. Each instance must be used by one thread at a time, like `GZipStream`.

## Limitations

- **Async compression** (`CompressStreamAsync`, `CompressFileAsync`): uses the serial single-block path. No parallel large-chunk mode. Prefer the synchronous overloads for maximum throughput.
- **`SlzStream.Flush()`**: no-op. Data is accumulated until a full block is ready, then compressed and written. Call `Dispose()` to finalize and flush the last block.
- **`SlzStream.WriteAsync()`**: async-shaped but fully synchronous — both compression and any resulting inner-stream writes happen on the calling thread. Returns a completed task.
- **L11 memory**: single-threaded compression of large files (1GB+) uses ~6.5GB working set due to BT4 match finder arrays and 64MB sliding window dictionary. L9-L10 use hash-based matching and require less memory.
- **L6-L8 memory**: parallel compression uses memory proportional to thread count (each thread processes a 1MB group with its own match finder).
- **Breaking change in v1.4.0**: L6-L8 compressed output contains cross-chunk references within 4-chunk groups. Decompressors older than v1.4.0 cannot decode this data.

## License

MIT
