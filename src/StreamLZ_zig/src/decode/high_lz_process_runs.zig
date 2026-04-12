//! [phase 5] High decoder hot loop — phase-2 LZ reconstruction.
//!
//! Port of src/StreamLZ/Decompression/High/LzDecoder.ProcessLzRuns.cs.
//! Tight literal-run + match-copy loop with 128-token-ahead prefetch.
//! Literal copies via `wildCopy16`; match copies use `copy64` once the
//! overlap is non-trivial.
