const cli = @import("cli.zig");

pub fn main() !void {
    try cli.run();
}

test {
    _ = @import("cli.zig");
    _ = @import("format/frame_format.zig");
    _ = @import("format/streamlz_constants.zig");
    _ = @import("format/block_header.zig");
    _ = @import("io/BitReader.zig");
    _ = @import("io/bit_writer.zig");
    _ = @import("io/copy_helpers.zig");
    _ = @import("io/ptr_math.zig");
    _ = @import("decode/streamlz_decoder.zig");
    _ = @import("decode/entropy/huffman_decoder.zig");
    _ = @import("decode/entropy/entropy_decoder.zig");
    _ = @import("decode/fast/fast_lz_decoder.zig");
    _ = @import("decode/high/high_lz_decoder.zig");
    _ = @import("decode/high/high_lz_token_executor.zig");
    _ = @import("decode/entropy/tans_decoder.zig");
    _ = @import("decode/decompress_parallel.zig");
    _ = @import("decode/fixture_tests.zig");
    _ = @import("encode/entropy/ByteHistogram.zig");
    _ = @import("encode/fast/fast_constants.zig");
    _ = @import("encode/entropy/tans_encoder.zig");
    _ = @import("encode/offset_encoder.zig");
    _ = @import("encode/entropy/entropy_encoder.zig");
    _ = @import("encode/fast/fast_match_hasher.zig");
    _ = @import("encode/match_hasher.zig");
    _ = @import("encode/text_detector.zig");
    _ = @import("encode/cost_coefficients.zig");
    _ = @import("encode/fast/fast_cost_model.zig");
    _ = @import("encode/fast/FastStreamWriter.zig");
    _ = @import("encode/fast/fast_token_writer.zig");
    _ = @import("encode/fast/fast_lz_parser.zig");
    _ = @import("encode/match_eval.zig");
    _ = @import("encode/high/managed_match_len_storage.zig");
    _ = @import("encode/high/match_finder.zig");
    _ = @import("encode/high/match_finder_bt4.zig");
    _ = @import("encode/high/high_types.zig");
    _ = @import("encode/high/high_matcher.zig");
    _ = @import("encode/high/high_cost_model.zig");
    _ = @import("encode/high/high_encoder.zig");
    _ = @import("encode/high/high_greedy_parser.zig");
    _ = @import("encode/high/high_optimal_parser.zig");
    _ = @import("encode/high/high_compressor.zig");
    _ = @import("encode/fast/fast_lz_encoder.zig");
    _ = @import("encode/streamlz_encoder.zig");
    _ = @import("encode/fast_framed.zig");
    _ = @import("encode/high_framed.zig");
    _ = @import("encode/compress_parallel.zig");
    _ = @import("encode/encode_fixture_tests.zig");
}
