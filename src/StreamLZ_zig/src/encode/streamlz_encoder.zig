//! [phase 9] Top-level StreamLZ compress dispatcher.
//!
//! Port of src/StreamLZ/Compression/StreamLzCompressor.cs + StreamLzFrameCompressor.cs.
//! Chunks input into 256 KB blocks, picks codec based on level, and wraps the
//! output in SLZ1 frame format (via `format/frame_format.zig`).
