//! [phase 11] High codec token emitter.
//!
//! Port of src/StreamLZ/Compression/High/Encoder.cs + HighTypes.cs. Consumes
//! tokens from `optimal_parser.zig` (or High/FastParser) and emits the
//! entropy-fed cmd/offset/literal/length streams for the High decoder.
