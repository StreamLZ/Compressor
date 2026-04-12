//! [phase 10] Byte histogram + compressed histogram serializer.
//!
//! Port of src/StreamLZ/Compression/ByteHistogram.cs. Collects per-symbol
//! frequencies and writes them in the RLE/delta-encoded form that the
//! entropy decoder parses.
