//! [phase 3b] Fast codec LZ token-stream decoder (user levels 1–5).
//!
//! Port of src/StreamLZ/Decompression/Fast/LzDecoder.cs. Parses the
//! command-byte stream, resolves near/far offsets (via Offset16Stream /
//! Offset32Stream), copies literals from LiteralStream, and copies matches
//! with WildCopy16 / Copy64 from earlier in the output.
