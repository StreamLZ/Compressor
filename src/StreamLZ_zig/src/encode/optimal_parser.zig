//! [phase 11] Dynamic-programming optimal parser.
//!
//! Port of src/StreamLZ/Compression/High/OptimalParser.cs. State:
//! `(position, recent-offset index)`; transitions emit literal or match.
//! Uses fixed-point costs (CostScaleFactor = 32) against `cost_model.zig`.
