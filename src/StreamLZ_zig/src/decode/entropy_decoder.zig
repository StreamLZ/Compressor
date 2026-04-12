//! [phase 4] Entropy-stream dispatcher + per-stream table reconstruction.
//!
//! Port of src/StreamLZ/Decompression/Entropy/EntropyDecoder.cs. Decides
//! whether each entropy block is Huffman or tANS, reconstructs the
//! decode tables, and hands off to `huffman_decoder.zig` or `tans_decoder.zig`.
