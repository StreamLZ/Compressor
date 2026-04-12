//! [phase 5] High codec LZ decoder — phase-1 entropy decode side.
//!
//! Port of src/StreamLZ/Decompression/High/LzDecoder.cs. Reads the
//! entropy-encoded cmd/offset/literal/length streams into a HighLzTable
//! in the scratch buffer; the actual LZ reconstruction lives in
//! `high_lz_process_runs.zig`.
