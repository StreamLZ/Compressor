//! [phase 9] Hash-chain match finder (used by all levels except BT4).
//!
//! Port of src/StreamLZ/Compression/MatchFinding/MatchHasher.cs. Fibonacci-multiplier
//! hashing (0x9E3779B97F4A7C15), 25-bit position + 7-bit collision tag per entry,
//! cache-aware preload insert.
