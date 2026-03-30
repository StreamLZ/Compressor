# Changelog

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
