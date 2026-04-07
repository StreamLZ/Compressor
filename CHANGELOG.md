# Changelog

## [1.3.0]

### Performance
- BT4 binary tree match finder for L8 and L11. Finds higher-quality
  matches than hash chains by walking a sorted suffix tree.
  - L8 (SC): -0.2pp ratio on silesia, +19% faster decompress (9.2 → 11.0 GB/s).
  - L11: -1.7pp ratio on enwik8 (27.2% → 25.5%), compress ~4x slower.
  - L6-L7 and L9-L10 unchanged (hash-based, BT4 tested but rejected).
- Optimized BT4: pinned arrays, 8-byte XOR+TZCNT match extension,
  prefetch for tree child nodes.

## [1.2.1]

### Fixed
- Fix OOM in framed compressor when compressing small inputs. Buffer
  allocation now capped to actual input size instead of scaling to
  full thread count × memory budget. All 392 unit tests pass.

## [1.2.0]

### Performance
- AVX2 vectorize delta literal copy in High decoder: +12% decompress
  on mixed data (silesia L6: 10.7 GB/s → 11.9 GB/s on warm runs).
- AVX2 vectorize raw literal copy and non-overlapping match copy in
  High decoder (32 bytes per iteration, up from 8).
- AVX2 vectorize delta literal encoding in compressor (SubtractBytes).
- Updated benchmark tables in README with correct median precision.

### Changed
- **Breaking**: Reorder `maxDecompressedSize` before `CancellationToken`
  on `DecompressStream`, `DecompressStreamAsync`, `DecompressFile`,
  `DecompressFileAsync`, and `StreamLzFrameDecompressor.Decompress/Async`
  to comply with CA1068 (CancellationToken must be last parameter).
- All build warnings resolved (CS1573 missing XML param tags, CA1068,
  CA1508).
- CLI `-bc` comparison benchmark uses fast Span-based decompress path.
- CLI benchmark median uses full-precision timing (was truncating to
  integer milliseconds).

## [1.1.0]

### Fixed
- Fix CLI `-b` benchmark crash on L9-L11 files larger than ~400MB.
  The benchmark used the raw `Compress`/`Decompress` API, which on OOM
  silently fell back to self-contained blocks, losing sliding window
  context and producing incorrect ratios. The public framed APIs
  (`CompressFile`, `DecompressFile`, `CompressFramed`) were never
  affected. CLI now uses the framed API for correct results at all sizes.
- Fix double-offset bug in new fast-path `DecompressFramed` that caused
  crashes on multi-block framed data (second block onwards).

### Performance
- Add zero-copy fast-path for `DecompressFramed(ReadOnlySpan, Span)`:
  parses frame/block headers in-place and calls the block decompressor
  directly without MemoryStream or buffer copies. Restores full
  benchmark speed for framed API consumers.
- CLI `-b` and `-bc` benchmarks now use framed compress (correct sliding
  window) with fast-path framed decompress (no allocation overhead).

### Changed
- CLI `-b` benchmark switched from raw to framed API. Compression ratios
  for L9-L11 on large files are now correct (enwik9 L9: was 29.9%
  incorrect, now 24.2% correct).
- README: document threading model per level, add Parallel Compress /
  Parallel Decompress columns to all benchmark tables, fix headline stats.

## [1.0.9]

### Fixed
- Stream compressor now matches raw API speed and ratio. L9 stream
  was 3x slower with 6% worse ratio due to 256KB read size (now uses
  full window) and missing thread count (now uses all cores).
- Memory-budget-based sizing: data per thread scales to fill 60% of
  system RAM while keeping all cores busy. Handles files of any size
  without manual tuning.
- Frame decompressor supports blocks of any size (removed dead
  large-block code path that broke cross-block dictionary references).
- CLI `-d` decompress now handles L9+ sliding-window streams correctly.

## [1.0.8]

### Security
- Bounds-check `ParseHeader` and `ParseChunkHeader` before any pointer
  dereference. Truncated streams (e.g. incomplete network reads) no
  longer cause blind reads past the source buffer.
- Clamp self-contained prefix restoration to the actual chunk size,
  preventing writes past a chunk's logical boundary.

## [1.0.7]

### Security
- Fix silent failure in `ExecuteTokens_Type1`: corrupt match offsets
  now abort decompression instead of returning uninitialized pool
  memory in the output buffer.
- Add `maxDecompressedSize` to `DecompressStream`, `DecompressFile`,
  and async variants. Prevents multi-block decompression bombs that
  expand without limit (the framed byte[] API already had this).

## [1.0.6]

### Added
- `IProgress<long>` support on all stream and file APIs for progress
  reporting. Reports bytes consumed (compress) or produced (decompress)
  at block boundaries with zero hot-path overhead.
- `CancellationToken` support on synchronous `CompressStream`,
  `DecompressStream`, `CompressFile`, and `DecompressFile` methods
  (async methods already had it).
- Fuzz regression tests for known-bad inputs that previously crashed
  the decoder.

## [1.0.5]

### Security
- Fix process-killing crash when decompressing corrupt tANS-coded data.
  Corrupt chunk headers in self-contained streams could produce source
  pointers past the allocation, crashing the process via AccessViolation.
- Harden tANS entropy decoder: mask LUT state indices, bounds-check
  bitstream refill pointers, validate frequency table construction,
  and prevent stack buffer overflows in table decode.
- Fix integer overflow in High decoder scratch allocation
  (OffsStreamSize * 4 could wrap int32).
- Add decompression bomb protection: `DecompressFramed` now accepts
  `maxDecompressedSize` (default 1 GB) to reject frames claiming
  unreasonably large content sizes.

### Added
- Crash-resilient fuzz harness with file-based watermarking for
  precise crash localization.
- SECURITY.md: document safety guarantees and fuzz testing posture.

### Testing
- Fuzz-verified: 405 million mutations across L1/L5/L6/L9 and the
  framed API with zero crashes. No performance regression on enwik8.

## [1.0.4]

### Performance
- Remove sub-chunk pipelining in High decoder: serial path is 53% faster
  for L6 (3.8 → 5.6 GB/s on enwik8, 3.7 → 8.8 GB/s on silesia).
  Two-phase parallel decode for L9-11 retained (+37% benefit there).

### Changed
- Update package description and benchmark tables.

## [1.0.3]

### Security
- Harden High decoder against malicious input: validate cumulative token
  lengths in ResolveTokens, validate match offsets against buffer start
  in both Type0 and Type1 execute paths, fix SafeSpace boundary check in
  Type0 to account for total token footprint.

## [1.0.2]

### Security
- Add missing bounds check on 32-bit long match path (cmd == 2) in Fast
  decoder. The v1.0.1 fix covered short tokens and 16-bit long matches
  but missed the 32-bit long match path.
- Clamp pipelined scratch buffer size in TryDecodePipelined to prevent
  out-of-bounds access if CalculateScratchSize exceeds the allocation.

## [1.0.1]

### Security
- Harden Fast decoder against malicious input: bounds check in the short
  token path prevents cascading writes past SafeSpace; validate 16-bit
  match offsets against buffer start prevents out-of-bounds reads.

### Fixed
- Correct package description (6.0 GB/s decompress, was 5.6).
- Downgrade System.IO.Hashing to 9.0.4 for stable net8.0 compatibility.

### Changed
- Rename internal identifiers for clarity (ByteHistogram, DeltaLiterals,
  NearOffsets, FarOffsets, LiteralRunLengths, OverflowLengths).
- Replace magic numbers with named constants in block headers and
  sub-chunk type shifts.
- Make FrameFlags enum internal (wire-format detail).

## [1.0.0]

Initial release.
