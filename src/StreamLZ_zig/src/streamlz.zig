//! StreamLZ public library API.
//!
//! Library consumers import this module:
//!   const slz = @import("streamlz");
//!   const n = try slz.compressFramed(allocator, src, dst, .{ .level = 3 });
//!   const m = try slz.decompressFramed(compressed, output);

pub const compressFramed = @import("encode/streamlz_encoder.zig").compressFramed;
pub const compressBound = @import("encode/streamlz_encoder.zig").compressBound;
pub const CompressOptions = @import("encode/streamlz_encoder.zig").CompressOptions;

pub const decompressFramed = @import("decode/streamlz_decoder.zig").decompressFramed;
pub const decompressFramedParallel = @import("decode/streamlz_decoder.zig").decompressFramedParallel;
pub const decompressFramedParallelThreaded = @import("decode/streamlz_decoder.zig").decompressFramedParallelThreaded;
pub const DecompressContext = @import("decode/streamlz_decoder.zig").DecompressContext;
pub const DecompressError = @import("decode/streamlz_decoder.zig").DecompressError;

pub const safe_space = @import("decode/streamlz_decoder.zig").safe_space;
