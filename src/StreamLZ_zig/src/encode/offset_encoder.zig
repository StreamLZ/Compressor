//! [phase 10] Offset variable-length encoder (low + high ranges).
//!
//! Port of src/StreamLZ/Compression/Entropy/OffsetEncoder.cs. Encodes match
//! offsets using the nibble-packed low-range formula for offsets < ~16 MB
//! and a log2-based high-range path for larger offsets, matching
//! `io/bit_reader.zig::readDistance`.
