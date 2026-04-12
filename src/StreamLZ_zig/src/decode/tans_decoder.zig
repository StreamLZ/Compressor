//! [phase 6] 5-state interleaved tANS decoder.
//!
//! Port of src/StreamLZ/Decompression/Entropy/TansDecoder.cs. Reconstructs
//! the normalized frequency table, builds next-state LUTs, and decodes with
//! 5 interleaved state machines to hide data dependencies.
