//! [phase 10] Multi-stream canonical Huffman encoder.
//!
//! Port of src/StreamLZ/Compression/Entropy/MultiArrayEncoder.cs (2K+ LOC,
//! the biggest single file in the C# tree). Splits input into multiple sub-
//! streams to reduce correlation, builds per-stream frequency tables and
//! canonical Huffman trees, and packs output as a 3- or 4-stream parallel
//! layout that the decoder's forward + forward-mid + backward readers consume.
