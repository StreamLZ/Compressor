# Changelog

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
