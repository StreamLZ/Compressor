//! [phase 10] tANS encoder (freq normalization + 5-state machine).
//!
//! Port of src/StreamLZ/Compression/Entropy/TansEncoder.cs. Heap-based
//! frequency normalization to a power-of-two sum, per-symbol state table
//! construction, 5-state interleaved encode that matches the decoder in
//! `decode/tans_decoder.zig`.
