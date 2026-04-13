# StreamLZ Zig Port — File Layout

This is the canonical map of where each piece of the port lives.
Update this alongside any file moves or renames.

**Conventions:**
- Long, explicit file names over abbreviations.
- Deep directory structure avoided — max depth `src/<area>/<file>`.
- `decode/` and `encode/` never import from each other.
- `format/` and `io/` are shared; they must not import `decode/` or `encode/`.
- Each file owns inline `test` blocks; `main.zig` aggregates them via `@import` in a root `test` block.

## Tree

```
src/StreamLZ_zig/
├── build.zig
├── build.zig.zon
├── STATUS.md                            session snapshot + phase tracker
├── STRUCTURE.md                         ← you are here
├── BENCHMARKS.md                        decompress perf numbers
├── scripts/
│   └── gen_fixtures.sh                  [phase 8] corpus generator via C# CLI
└── src/
    ├── main.zig                         CLI entry (arg parsing + dispatch)
    ├── cli.zig                          [planned] Subcommand handlers (info/decompress/compress)
    ├── streamlz.zig                     [planned phase X] Library root (re-exports for external consumers)
    │
    ├── format/                          # Wire format — "what the bytes mean"
    │   ├── streamlz_constants.zig       All magic numbers (port of StreamLzConstants.cs)
    │   ├── frame_format.zig             SLZ1 frame header + 8-byte frame block header + end mark
    │   └── block_header.zig             [phase 3b] Internal 2-byte block hdr + 4-byte chunk hdr
    │
    ├── io/                              # Low-level byte / bit primitives
    │   ├── bit_reader.zig               32-bit MSB bit reader (forward + backward refill)
    │   ├── bit_writer.zig               4 bit-writer variants (fwd/bwd × 32/64, older stub)
    │   ├── bit_writer_64.zig            [phase 10] 64-bit forward + backward bit writers
    │   └── copy_helpers.zig             copy64 / copy64Bytes / wildCopy16 / copy64Add
    │                                    (scalar now; @Vector in phase 7)
    │
    ├── decode/                          # Everything read-side
    │   ├── streamlz_decoder.zig         Top-level framed decompress + DecodeStep dispatcher
    │   ├── fast_lz_decoder.zig          [phase 3b] Fast codec LZ token-stream decoder (L1–5)
    │   ├── high_lz_decoder.zig          [phase 5] High codec LZ decoder, phase-1 entropy decode
    │   ├── high_lz_process_runs.zig     [phase 5] ProcessLzRuns hot loop (split for size)
    │   ├── entropy_decoder.zig          [phase 4] Entropy dispatcher + table reconstruction
    │   ├── huffman_decoder.zig          [phase 4] 11-bit LUT, 3-stream parallel canonical Huffman
    │   ├── tans_decoder.zig             [phase 6] 5-state interleaved tANS decoder
    │   └── fixture_tests.zig            [phase 8] exhaustive corpus roundtrip test
    │
    └── encode/                          # Everything write-side — Fast L1-L5 byte-exact with C#
        ├── streamlz_encoder.zig         [phase 9] Top-level framed compress + per-block/sub-chunk driver
        ├── fast_constants.zig           [phase 9] FastConstants + Slz.MapLevel compose + getHashBits + mmlt builder
        ├── fast_match_hasher.zig        [phase 9] FastMatchHasher(u16/u32) single-entry Fibonacci hash
        ├── fast_stream_writer.zig       [phase 9] 6-parallel-stream output buffer (raw + entropy)
        ├── fast_token_writer.zig        [phase 9] writeOffset / writeComplexOffset / writeOffsetWithLiteral1 / writeLengthValue / writeOffset32
        ├── fast_lz_parser.zig           [phase 9] Greedy + lazy-chain parsers (comptime level + comptime hash T)
        ├── fast_lz_encoder.zig          [phase 9/10] encodeSubChunkRaw / encodeSubChunkEntropy / encodeSubChunkEntropyChain + assembleEntropyOutput
        ├── text_detector.zig            [phase 10i] Text-probability heuristic → min-match-length bump
        ├── cost_model.zig               [phase 10i] Platform cost combination + decoding-time estimates
        ├── cost_coefficients.zig        [phase 10i] Memset-cost coefficients + speed-tradeoff scaling
        ├── byte_histogram.zig           [phase 10] ByteHistogram + getCostApproxCore (log2 LUT)
        ├── match_hasher.zig             [phase 9] MatchHasher2 chain hasher (L5 lazy)
        ├── entropy_encoder.zig          [phase 10] EncodeArrayU8 / EncodeArrayU8Memcpy (memcpy-only for Fast)
        ├── encode_fixture_tests.zig     [phase 9] corpus-driven encode → C# reference diff
        ├── high_lz_encoder.zig          [phase 11 STUB] High codec: token emitter
        ├── optimal_parser.zig           [phase 11 STUB] DP optimal parser
        ├── match_finder_bt4.zig         [phase 12 STUB] Binary-tree match finder for L11
        ├── multi_array_huffman_encoder.zig [phase 10 STUB] Multi-stream Huffman encoder
        ├── tans_encoder.zig             [phase 10d STUB] tANS encoder — roundtrip broken
        └── offset_encoder.zig           [phase 10 STUB] Offset variable-length coder
```

## Phases → files

| Phase | Goal | Files touched |
|-------|------|---------------|
| 0 | Foundation | `main.zig`, `build.zig`, `build.zig.zon` |
| 1 | Wire format + `info` CLI | `format/streamlz_constants.zig`, `format/frame_format.zig`, `main.zig` |
| 2 | Bit I/O | `io/bit_reader.zig`, `io/bit_writer.zig` |
| 3a | Decompress uncompressed path + CLI | `decode/streamlz_decoder.zig`, `io/copy_helpers.zig`, `main.zig` |
| 3b | Fast LZ decoder | `format/block_header.zig`, `decode/fast_lz_decoder.zig`, `decode/entropy_decoder.zig` (partial) |
| 4 | Huffman decoder | `decode/huffman_decoder.zig`, `decode/entropy_decoder.zig` |
| 5 | High LZ decoder | `decode/high_lz_decoder.zig`, `decode/high_lz_process_runs.zig` |
| 6 | tANS decoder | `decode/tans_decoder.zig` |
| 7 | Vectorize copies | `io/copy_helpers.zig` (@Vector pass) |
| 8 | Fixture corpus + exhaustive roundtrip | tests only |
| 9 | Fast encoder (L1-L5) byte-exact | `encode/{streamlz_encoder,fast_constants,fast_match_hasher,fast_stream_writer,fast_token_writer,fast_lz_parser,fast_lz_encoder,text_detector,cost_model,cost_coefficients,byte_histogram,match_hasher,entropy_encoder}.zig` |
| 10 | Huffman + tANS + offset encoders | `encode/multi_array_huffman_encoder.zig`, `encode/tans_encoder.zig`, `encode/offset_encoder.zig` (stubs — not needed for Fast parity, required for High) |
| 11 | High encoder + optimal parser | `encode/high_lz_encoder.zig`, `encode/optimal_parser.zig` |
| 12 | BT4 match finder | `encode/match_finder_bt4.zig` |
| 13 | Parallel decompress | parallelism added to `decode/streamlz_decoder.zig` |
| 14 | Parallel compress | parallelism added to `encode/streamlz_encoder.zig` |
