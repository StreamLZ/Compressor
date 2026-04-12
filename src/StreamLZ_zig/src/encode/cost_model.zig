//! [phase 11] Per-token entropy cost model.
//!
//! Port of src/StreamLZ/Compression/High/CostModel.cs + CostCoefficients.cs.
//! Precomputed log2 table (4097 entries), fixed-point (CostScaleFactor = 32)
//! per-token cost estimation used by `optimal_parser.zig`.
