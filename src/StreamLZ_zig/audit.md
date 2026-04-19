# THE CODE INQUISITOR — StreamLZ Zig Audit

Scope: 50 `.zig` files, 25,304 lines. Every file read. Filenames noted but judgment formed from the code itself. Line numbers reflect the files as committed at audit time.

**Verdict in one breath:** this is C with Zig punctuation. It is a faithful mechanical port of a C# reference that was itself mechanically derived from C. Nobody stopped to ask "what would an idiomatic Zig implementation look like?" The answer would have looked very different.

---

## PHASE 0 — FILE INVENTORY & UNDERSTANDING

### Phase 0A/0B — What each file actually does

**Format / wire layout**
- `src/format/frame_format.zig` — SLZ1 outer frame header parser/writer AND outer 8-byte block header parser/writer. **Two responsibilities**, separated by an ASCII separator comment. Must split.
- `src/format/block_header.zig` — internal 2-byte block header + 4-byte chunk header parsers. Decode-only. **Name collision** with `frame_format.BlockHeader`.
- `src/format/streamlz_constants.zig` — magic numbers grab-bag. Contains chunk sizing, huffman LUT sizing, offset encoding constants, threading constants, hash table constants, cost model constants, and five other domains. **Eight responsibilities.**

**IO / bits**
- `src/io/bit_reader.zig` — 32-bit-accumulator bit reader. One responsibility. OK.
- `src/io/bit_writer.zig` — declares `BitWriter64Forward`, `BitWriter64Backward`, `BitWriter32Forward`, `BitWriter32Backward`.
- `src/io/bit_writer_64.zig` — declares `BitWriter64Forward`, `BitWriter64Backward`. **Critical defect: two files export structs with the same public names.** The tANS encoder imports `bit_writer_64`; everyone else imports `bit_writer`. The 64-bit versions are near-identical but differ in `write` signature (`n: u5` vs `n: u6`).
- `src/io/copy_helpers.zig` — SIMD copy + PSHUFB LUT + `@memset` wrapper. The PSHUFB mask table is unrelated to the copy helpers.

**Histogram / entropy cost**
- `src/encode/byte_histogram.zig` — `ByteHistogram` struct, `log2_lookup_table`, `getCostApproxCore`, AND a redundant free-function `countBytesHistogram`. **Three responsibilities in 99 lines.** Also exports a method named `count_bytes` in snake_case — a direct violation of Zig's camelCase method convention.

**Entropy encode**
- `src/encode/entropy_encoder.zig` — tANS-or-memcpy dispatcher. The `_ = level;` unused parameter on line 183 announces that the public API surface is wrong.
- `src/encode/tans_encoder.zig` — 1317 lines: table normalization heap, encoding table builder, exact bit-count dry run, 5-state hot encode, table header serializer. **Five responsibilities.**
- `src/encode/offset_encoder.zig` — 1111 lines: SIMD delta subtract, cost model helpers, log2 interpolation table, modulo-divisor search, hi/lo offset splitter, dual-ended bit-stream writer, top-level EncodeLzOffsets. **Seven responsibilities.** Top of the file admits it: "Three distinct responsibilities live here" followed by four more.

**Fast codec (L1-L5)**
- `src/encode/fast_constants.zig` — constants, level mapping, minimum-match table builder, adaptive hash-bit sizing. **Four responsibilities.**
- `src/encode/fast_match_hasher.zig` — single-entry fibonacci hash table. OK (should be a type-file named `FastMatchHasher.zig`).
- `src/encode/fast_stream_writer.zig` — six-stream cursor struct. OK. Should be type-file `FastStreamWriter.zig`.
- `src/encode/fast_token_writer.zig` — emit short/complex tokens, lazy-parser `writeOffsetWithLiteral1`, trailing literal copy, `extendMatchForward`. **Match-extension does not belong here.**
- `src/encode/fast_lz_parser.zig` — 918 lines: `runGreedyParser` (225 lines), `runLazyParser` (120 lines), `runLazyParserChain` (~120 lines), `findMatchWithHasher`, `findMatchWithChainHasher`, and inline copies of `countMatchingBytes` / `isMatchBetter` / `isLazyMatchBetter`. **Five+ responsibilities.** The inline copies of the match helpers — duplicated from `match_eval.zig` — are blessed by a comment claiming byte-parity with C#. A maintenance bomb.
- `src/encode/fast_lz_encoder.zig` — 936 lines: `encodeSubChunkRaw`, `encodeSubChunkEntropy`, `encodeSubChunkEntropyChain`, `assembleEntropyOutput`. **Three near-duplicate entry points.**

**Shared LZ**
- `src/encode/match_eval.zig` — `countMatchingBytes`, `getMatchLengthQuick*`, `isBetterThanRecent`, `isMatchBetter`, `getLazyScore`. Imports `fast_lz_parser` ONLY to get the `LengthAndOffset` type it needs for `getLazyScore`. **The shared helpers module imports the Fast parser to get a shared struct.** Circular thinking.

**High codec (L6-L11)**
- `src/encode/high_types.zig` — exports `HighRecentOffs`, `HighStreamWriter`, `Token`, `TokenArray`, `ExportedTokens`, `State`, `CostModel`, `Stats`. **Seven types in one file** because the port author feared circular imports.
- `src/encode/high_compressor.zig` — level-to-setup mapping + `doCompress` dispatcher + `allocateHighHasher`. Acceptable.
- `src/encode/high_cost_model.zig` — histogram rescale + update + cost tables. OK.
- `src/encode/high_matcher.zig` — predicates + best-match selection. OK.
- `src/encode/high_fast_parser.zig` — greedy/lazy parser for L1-L4 of the High codec. OK.
- `src/encode/high_optimal_parser.zig` — 1146 lines; `optimal()` function alone is ~800 lines. **Worst god-function in the tree.**
- `src/encode/high_encoder.zig` — `initializeStreamWriter`, `writeMatchLength`, `writeLiterals*`, `writeFarOffset`, `writeNearOffset`, `writeOffset`, `addToken`, `addFinalLiterals`, `assembleCompressedOutput` (~250 lines), `encodeTokenArray`. **Ten functions across three responsibilities.**
- `src/encode/high_lz_encoder.zig` — **STUB FILE.** 5 lines. Nothing but a `//!` doc comment describing what the file WOULD contain. Zero code. Delete.
- `src/encode/multi_array_huffman_encoder.zig` — **STUB FILE.** 7 lines. Delete.
- `src/encode/optimal_parser.zig` — **STUB FILE.** 5 lines. Delete.
- `src/encode/match_hasher.zig` — generic bucket-based `MatchHasher(num_hash, dual_hash)` + separate `MatchHasher2` 3-table chain hasher. **Two independent hash-table implementations in one file.**
- `src/encode/match_finder.zig` — hash-based match finder for optimal parser. OK.
- `src/encode/match_finder_bt4.zig` — BT4 match finder. OK.
- `src/encode/managed_match_len_storage.zig` — struct, varlen encoder helpers, varlen decoder helpers, insertion, deduplication, extraction. **Six responsibilities in 453 lines.**
- `src/encode/cost_model.zig` — 4-platform cost average + decode-time estimates. Misnamed: this is the **Fast** codec cost model, not the generic one.
- `src/encode/cost_coefficients.zig` — 143 lines of hand-tuned magic numbers. OK as organization.
- `src/encode/text_detector.zig` — UTF-8 text heuristic. Not Fast-specific — belongs in a `heuristics/` module.
- `src/encode/block_header_writer.zig` — encode-side of the header that `format/block_header.zig` decodes. **Asymmetric split.** Should be merged into `format/block_header.zig`.
- `src/encode/streamlz_encoder.zig` — 2568 lines: `CompressOptions` struct, Windows `GlobalMemoryStatusEx` FFI, `calculateMaxThreads`, level-param resolver, `compressBound`, `compressFramed` (multi-piece OOM retry ladder), `compressFramedOne` (Fast path), `compressFramedHigh`, `compressOneFrameBlockWindowed`, `compressOneHighBlock`, `compressInternalParallelSc`, `compressBlocksParallel`, SC prefix table emitter, single-frame finalizer, AND `areAllBytesEqual` duplicated from `block_header_writer.zig`. **At least fifteen responsibilities.** Single biggest file in the tree. Not a module — a compilation unit.

**Decoder**
- `src/decode/streamlz_decoder.zig` — 867 lines: serial decompress, parallel dispatch, `LazyPool`, streaming decompressor with sliding window + xxh32, `decompressBlock*` family, compressed-block chunk walker. **Six responsibilities.**
- `src/decode/decompress_parallel.zig` — SC parallel + two-phase non-SC parallel + pre-scan + worker functions. OK.
- `src/decode/fast_lz_decoder.zig` — offset stream helpers, `readLzTable`, `processModeImpl` hot loop (230 lines), `processLzRuns`, `decodeChunk`. OK-ish.
- `src/decode/high_lz_decoder.zig` — `HighLzTable`, `unpackOffsets`, `readLzTable`, `decodeChunk`. OK.
- `src/decode/high_lz_process_runs.zig` — Type0 / Type1 runs. OK.
- `src/decode/entropy_decoder.zig` — dispatcher + RLE + recursive multi-block. OK.
- `src/decode/huffman_decoder.zig` — 1021 lines: LUT construction, canonical decoder, three-stream hot loop, Golomb-Rice helpers. OK-ish.
- `src/decode/tans_decoder.zig` — table decode, LUT init, 5-state hot loop. OK.
- `src/decode/fixture_tests.zig` — fixture-corpus roundtrip test. **Does not belong inside `src/decode/`.**
- `src/decode/cleanness_analyzer.zig` — 1640 lines of speculative-decode-feasibility analysis. **A 1640-line research tool living inside the production decoder package.** No part of this needs to ship with the codec.

**Fixture tests, misplaced**
- `src/encode/encode_fixture_tests.zig` — same offense as `decode/fixture_tests.zig`. Move.

**CLI + build**
- `src/main.zig` — 742 lines: CLI parser, `runVersion`, `runInfo`, `runDecompress`, `runCompress`, `runBench`, `runBenchCompress`, `runAnalyze`. **Seven subcommand handlers in one file.**
- `build.zig` — OK.

---

### Phase 0F — REORGANIZATION MANIFEST

```
DELETE (pure cruft):

  src/encode/high_lz_encoder.zig             — 5-line stub
  src/encode/multi_array_huffman_encoder.zig — 7-line stub
  src/encode/optimal_parser.zig              — 5-line stub
    REASON: Doc-comment placeholders for work that landed elsewhere
    (high_encoder.zig, high_optimal_parser.zig). No code. Zig does
    not have TODO.md files that pretend to be source.

  src/io/bit_writer_64.zig
    REASON: Duplicate of the BitWriter64* structs in src/io/bit_writer.zig.
    Tans imports one, everyone else the other. Pick one. Delete this one
    (or delete the duplicates in bit_writer.zig — but not both).

MOVES (rename + relocate):

  src/format/frame_format.zig
    → src/format/frame_header.zig   (frame header parse/write)
    + src/format/frame_block_header.zig  (the 8-byte block header)
    REASON: "frame_format" is a bag. Split by wire object. Also: file
    defines multiple top-level structs; these are not type-files.

  src/format/block_header.zig
    → src/format/internal_block_header.zig
    REASON: There are THREE "BlockHeader" types in this codebase —
    frame block header, internal block header, and the Fast codec
    sub-chunk header. "block_header" alone is a scavenger hunt.

  src/format/streamlz_constants.zig
    → SPLIT (see below)

  src/encode/block_header_writer.zig
    → MERGE into src/format/internal_block_header.zig
    REASON: Asymmetric encode/decode split for the same wire object is
    artificial. Parse and write belong in one file.

  src/io/copy_helpers.zig
    → src/copy/wild_copy.zig  (everything except the PSHUFB mask table)
    + src/copy/pshufb_masks.zig  (the mask table and copyMatch16Pshufb)

  src/encode/byte_histogram.zig
    → src/entropy/ByteHistogram.zig  (type-file; count_bytes → countBytes)
    + src/entropy/histo_cost.zig  (getCostApproxCore + log2_lookup_table + countBytesHistogram)

  src/encode/cost_model.zig
    → src/fast/cost_model.zig
    REASON: Fast-codec-specific despite the generic name.

  src/encode/text_detector.zig
    → src/heuristics/text_detector.zig

  src/encode/match_eval.zig
    → src/lz/match_eval.zig
    REASON: Shared between Fast and High. Not an "encode/" concept —
    both the fast parser and the optimal parser consume these predicates.

  src/encode/fast_match_hasher.zig
    → src/fast/encode/FastMatchHasher.zig  (type-file)

  src/encode/fast_stream_writer.zig
    → src/fast/encode/FastStreamWriter.zig  (type-file)

  src/encode/fast_constants.zig
    → SPLIT:
      src/fast/constants.zig            (block sizes, markers, ...)
      src/fast/level_map.zig            (mapLevel + InternalLevel)
      src/fast/min_match_table.zig      (buildMinimumMatchLengthTable)
      src/fast/hash_bits.zig            (getHashBits)

  src/encode/fast_token_writer.zig
    → src/fast/encode/token_writer.zig
    (and split out extendMatchForward to src/lz/match_eval.zig — it's
    a match-evaluation helper masquerading as a token writer)

  src/encode/fast_lz_parser.zig
    → SPLIT:
      src/fast/encode/greedy_parser.zig         (runGreedyParser)
      src/fast/encode/lazy_parser.zig           (runLazyParser + findMatchWithHasher)
      src/fast/encode/lazy_chain_parser.zig     (runLazyParserChain + findMatchWithChainHasher)
      DELETE: the inline copies of countMatchingBytes/isMatchBetter/
              isLazyMatchBetter/isBetterThanRecentMatch — they duplicate
              src/lz/match_eval.zig. Import match_eval instead.

  src/encode/fast_lz_encoder.zig
    → SPLIT:
      src/fast/encode/sub_chunk_raw.zig         (encodeSubChunkRaw)
      src/fast/encode/sub_chunk_entropy.zig     (encodeSubChunkEntropy + encodeSubChunkEntropyChain)
      src/fast/encode/assemble_entropy.zig      (assembleEntropyOutput)

  src/encode/entropy_encoder.zig
    → src/entropy/encode/entropy_encoder.zig
    (and delete the unused `level: u32` parameter — the function body
    starts with `_ = level;`)

  src/encode/tans_encoder.zig
    → SPLIT into src/entropy/encode/tans/:
      normalize_heap.zig   (HeapEntry + heap ops)
      normalize.zig        (weight normalization)
      encoding_table.zig   (TansEncEntry + build)
      encode.zig           (5-state hot encode)
      table_header.zig     (encodeTable sparse + Golomb-Rice)
      tans_encoder.zig     (top-level encodeArrayU8Tans stitcher)

  src/encode/offset_encoder.zig
    → SPLIT:
      src/entropy/delta_literal.zig            (subtractBytes + subtractBytesUnsafe)
      src/entropy/log2_interp.zig              (log2_interp_lookup + getLog2Interpolate)
      src/entropy/histo_cost.zig               (merge with the histo_cost split above)
      src/high/encode/modulo_offset_coder.zig  (encodeNewOffsets + getBestOffsetEncoding* + getCostModularOffsets)
      src/high/encode/offset_bit_stream.zig    (writeLzOffsetBits dual-ended)
      src/high/encode/offset_encoder.zig       (encodeLzOffsets top-level + EncodeLzOffsetsResult)

  src/encode/high_types.zig
    → SPLIT:
      src/high/encode/HighRecentOffs.zig   (type-file)
      src/high/encode/HighStreamWriter.zig (type-file)
      src/high/encode/Token.zig            (type-file)
      src/high/encode/State.zig            (type-file)
      src/high/encode/CostModel.zig        (type-file)
      src/high/encode/Stats.zig            (type-file)
      src/high/encode/TokenArray.zig       (type-file or delete — it's just three fields)
      src/high/encode/ExportedTokens.zig   (ditto)

  src/encode/high_compressor.zig   → src/high/encode/compressor.zig
  src/encode/high_cost_model.zig   → src/high/encode/cost_model.zig
  src/encode/high_matcher.zig      → src/high/encode/matcher.zig
  src/encode/high_fast_parser.zig  → src/high/encode/fast_parser.zig
  src/encode/high_optimal_parser.zig → SPLIT (see below)
  src/encode/high_encoder.zig      → SPLIT:
      src/high/encode/stream_writer_init.zig  (initializeStreamWriter + HighWriterStorage)
      src/high/encode/token_writer.zig        (writeMatchLength/Literals*/FarOffset/NearOffset/Offset/addToken/addFinalLiterals)
      src/high/encode/assemble.zig            (assembleCompressedOutput — 250 lines of its own)
      src/high/encode/encode_token_array.zig  (encodeTokenArray)

  src/encode/match_finder.zig      → src/high/encode/match_finder/hash_based.zig
  src/encode/match_finder_bt4.zig  → src/high/encode/match_finder/bt4.zig
  src/encode/managed_match_len_storage.zig → SPLIT:
      src/high/encode/match_finder/ManagedMatchLenStorage.zig  (type-file)
      src/high/encode/match_finder/var_len_codec.zig           (varLenWrite* + extract*)
      src/high/encode/match_finder/insert_matches.zig          (insertMatches + removeIdentical + extractLaoFromMls)

  src/encode/match_hasher.zig
    → SPLIT:
      src/hashing/MatchHasher.zig  (the generic bucket hasher type-file)
      src/hashing/MatchHasher2.zig (the 3-table chain hasher — type-file)
      src/hashing/preload.zig      (adaptivePreloadLoop)

  src/encode/high_optimal_parser.zig
    → SPLIT into src/high/encode/optimal/:
      optimal_parser.zig      (optimal entry + outer loop, <200 lines)
      collect_statistics.zig  (collectStatistics — the seed-pass greedy)
      forward_dp.zig          (the forward DP inner loop)
      backward_extract.zig    (the phase-2 token extraction)
      update_state.zig        (updateState + updateStatesZ)

  src/encode/streamlz_encoder.zig
    → SPLIT (the biggest win in the reorganization):
      src/codec/streamlz_encoder.zig          (compressBound, CompressError, Options, compressFramed — the top-level entry, <200 lines)
      src/codec/fast_framed.zig               (compressFramedOne — the Fast-path frame builder)
      src/codec/high_framed.zig               (compressFramedHigh + compressOneFrameBlockWindowed + compressOneHighBlock)
      src/parallel/compress_sc.zig            (compressInternalParallelSc)
      src/parallel/compress_blocks.zig        (compressBlocksParallel)
      src/codec/sc_prefix_table.zig           (emitScPrefixTable + finalizeSingleFrameBlock)
      src/codec/multi_piece_retry.zig         (the OOM retry ladder currently inside compressFramed)
      src/codec/level_resolve.zig             (ResolvedParams, resolveParams, entropyOptionsForLevel)
      src/platform/memory_query.zig           (GlobalMemoryStatusEx + totalAvailableMemoryBytes + calculateMaxThreads)
      DELETE the inline copy of `areAllBytesEqual` — import from format/internal_block_header.zig.

  src/decode/streamlz_decoder.zig
    → SPLIT:
      src/codec/streamlz_decoder.zig     (top-level decompressFramed + decompressFramedParallel)
      src/codec/lazy_pool.zig            (LazyPool wrapper)
      src/codec/stream_decompressor.zig  (decompressStream + sliding window + xxh32 verify)
      src/codec/block_decompressor.zig   (decompressBlock + decompressBlockWithDict + decompressCompressedBlock + copyWholeMatch)

  src/decode/fast_lz_decoder.zig
    → src/fast/decode/fast_decoder.zig
    (splits inside are borderline — keep the hot-loop file intact;
    extract decodeFarOffsets* and combineOffs16* to offset_helpers.zig)

  src/decode/high_lz_decoder.zig       → src/high/decode/high_decoder.zig
  src/decode/high_lz_process_runs.zig  → src/high/decode/process_runs.zig
  src/decode/entropy_decoder.zig       → src/entropy/decode/entropy_decoder.zig
  src/decode/huffman_decoder.zig       → src/entropy/decode/huffman_decoder.zig
  src/decode/tans_decoder.zig          → src/entropy/decode/tans_decoder.zig
  src/decode/decompress_parallel.zig   → src/parallel/decompress.zig

  src/decode/cleanness_analyzer.zig
    → src/tools/cleanness_analyzer.zig
    REASON: 1640 lines of research tooling. No library consumer should
    compile this into their binary. The `streamlz analyze` subcommand is
    ALSO tooling, not codec API.

  src/decode/fixture_tests.zig         → src/tests/fixture_roundtrip.zig
  src/encode/encode_fixture_tests.zig  → src/tests/encode_roundtrip.zig

  src/main.zig
    → SPLIT:
      src/cli/main.zig                  (just dispatch + arg parse)
      src/cli/commands/info.zig
      src/cli/commands/compress.zig
      src/cli/commands/decompress.zig
      src/cli/commands/bench.zig
      src/cli/commands/bench_compress.zig
      src/cli/commands/analyze.zig
      src/cli/format_helpers.zig        (median + MB/s formatting)

SPLITS — src/format/streamlz_constants.zig:
  → src/format/chunk_sizing.zig      (chunk_size, chunk_header, sub_chunk_type_shift, ...)
  → src/format/offset_encoding.zig   (offset_bias_constant, high_offset_*, low_offset_encoding_limit, thresholds)
  → src/format/huffman_params.zig    (huffman_lut_bits/size/mask/overflow/bitpos_clamp_mask)
  → src/format/entropy_params.zig    (block_size_mask_*, rle_short_command_threshold, alphabet_size)
  → src/format/scratch_sizing.zig    (scratch_size, entropy_scratch_size, calculateScratchSize)
  → src/format/hashing_params.zig    (hash_position_mask/bits, hash_tag_mask, fibonacci_hash_multiplier)
  → src/format/cost_params.zig       (invalid_cost, cost_scale_factor, log2_lookup_table_size)
  → src/format/threading_params.zig  (sc_group_size, per_thread_memory_estimate)

STAYS:
  build.zig                                 — correct location, correct name.
  build.zig.zon                             — (if it exists; not read).
  src/io/bit_reader.zig                     → keep as src/bits/bit_reader.zig (move out of io/).
```

### Phase 0G — NEW FOLDER TREE

```
src/
├── bits/
│   ├── bit_reader.zig
│   └── bit_writer.zig                  (merged 64- and 32-bit variants)
├── copy/
│   ├── wild_copy.zig
│   └── pshufb_masks.zig
├── format/
│   ├── frame_header.zig
│   ├── frame_block_header.zig
│   ├── internal_block_header.zig       (merged parse+write, decode-side and encode-side)
│   ├── chunk_sizing.zig
│   ├── offset_encoding.zig
│   ├── huffman_params.zig
│   ├── entropy_params.zig
│   ├── scratch_sizing.zig
│   ├── hashing_params.zig
│   ├── cost_params.zig
│   └── threading_params.zig
├── entropy/
│   ├── ByteHistogram.zig
│   ├── histo_cost.zig
│   ├── log2_interp.zig
│   ├── delta_literal.zig
│   ├── encode/
│   │   ├── entropy_encoder.zig
│   │   └── tans/
│   │       ├── normalize_heap.zig
│   │       ├── normalize.zig
│   │       ├── encoding_table.zig
│   │       ├── encode.zig
│   │       ├── table_header.zig
│   │       └── tans_encoder.zig
│   └── decode/
│       ├── entropy_decoder.zig
│       ├── huffman_decoder.zig
│       └── tans_decoder.zig
├── hashing/
│   ├── MatchHasher.zig
│   ├── MatchHasher2.zig
│   ├── FastMatchHasher.zig             (was src/encode/fast_match_hasher.zig)
│   └── preload.zig
├── lz/
│   └── match_eval.zig
├── heuristics/
│   └── text_detector.zig
├── fast/
│   ├── constants.zig
│   ├── level_map.zig
│   ├── min_match_table.zig
│   ├── hash_bits.zig
│   ├── cost_model.zig                  (platform cost averages)
│   ├── encode/
│   │   ├── FastStreamWriter.zig
│   │   ├── token_writer.zig
│   │   ├── greedy_parser.zig
│   │   ├── lazy_parser.zig
│   │   ├── lazy_chain_parser.zig
│   │   ├── sub_chunk_raw.zig
│   │   ├── sub_chunk_entropy.zig
│   │   └── assemble_entropy.zig
│   └── decode/
│       ├── fast_decoder.zig
│       └── offset_helpers.zig
├── high/
│   ├── cost_coefficients.zig
│   ├── encode/
│   │   ├── HighRecentOffs.zig
│   │   ├── HighStreamWriter.zig
│   │   ├── Token.zig
│   │   ├── State.zig
│   │   ├── CostModel.zig
│   │   ├── Stats.zig
│   │   ├── compressor.zig
│   │   ├── cost_model.zig              (histogram rescale + bits-for-* helpers)
│   │   ├── matcher.zig
│   │   ├── fast_parser.zig
│   │   ├── optimal/
│   │   │   ├── optimal_parser.zig
│   │   │   ├── collect_statistics.zig
│   │   │   ├── forward_dp.zig
│   │   │   ├── backward_extract.zig
│   │   │   └── update_state.zig
│   │   ├── stream_writer_init.zig
│   │   ├── token_writer.zig
│   │   ├── assemble.zig
│   │   ├── encode_token_array.zig
│   │   ├── modulo_offset_coder.zig
│   │   ├── offset_bit_stream.zig
│   │   ├── offset_encoder.zig
│   │   └── match_finder/
│   │       ├── ManagedMatchLenStorage.zig
│   │       ├── var_len_codec.zig
│   │       ├── insert_matches.zig
│   │       ├── hash_based.zig
│   │       └── bt4.zig
│   └── decode/
│       ├── high_decoder.zig
│       └── process_runs.zig
├── codec/
│   ├── streamlz_encoder.zig            (<200 lines, the public API)
│   ├── streamlz_decoder.zig
│   ├── fast_framed.zig
│   ├── high_framed.zig
│   ├── level_resolve.zig
│   ├── multi_piece_retry.zig
│   ├── sc_prefix_table.zig
│   ├── stream_decompressor.zig
│   ├── block_decompressor.zig
│   └── lazy_pool.zig
├── parallel/
│   ├── compress_sc.zig
│   ├── compress_blocks.zig
│   └── decompress.zig
├── platform/
│   └── memory_query.zig
├── tools/
│   └── cleanness_analyzer.zig
├── cli/
│   ├── main.zig
│   ├── format_helpers.zig
│   └── commands/
│       ├── info.zig
│       ├── compress.zig
│       ├── decompress.zig
│       ├── bench.zig
│       ├── bench_compress.zig
│       └── analyze.zig
└── tests/
    ├── fixture_roundtrip.zig
    └── encode_roundtrip.zig
build.zig
build.zig.zon
```

**Reorganization impact:** 50 source files become ~105, but the largest file drops from 2568 lines to under 300. Single-responsibility is restored.

**Percentage of original paths that survive:** 2 of 50 — `build.zig` and `bit_reader.zig`. 96% of the tree moves.

---

## PHASE 1 — CODE REVIEW

Most of the defects are systemic. The worst offenders are shown with specific line numbers; systemic defects are called out once with representative hits.

### src/encode/streamlz_encoder.zig → (reorganized as ten files)

**VERDICT:** *Fifteen responsibilities cosplaying as one file. The biggest single defect in the tree.*

```
ISSUES (most critical → most petty):

  [1] SEVERITY: CRITICAL | Whole file | Category: Architecture
      PROBLEM: 2568 lines containing Windows FFI, thread-pool sizing,
               memory queries, multi-piece OOM retry, the Fast codec
               framing pipeline, the High codec framing pipeline, two
               separate parallel paths, SC prefix table emission, and
               frame finalization. This is not a module.
      WHY IT MATTERS: No reader can hold the whole file in their head.
               Changes anywhere risk breaking everything. Tests of the
               Fast path have to import everything High. The High SC
               parallel path has to import everything in compressFramed.
      FIX: Split per the reorganization manifest. ~10 files, none over
           400 lines, clean dependency graph.

  [2] SEVERITY: CRITICAL | lines 53-65 | Category: Platform abstraction
      PROBLEM: Inlined Windows FFI (MemoryStatusEx struct + extern fn
               GlobalMemoryStatusEx) inside the compressor top file.
      WHY IT MATTERS: The compressor's public surface should not be a
               Windows header. A future macOS or Linux build cannot
               cross-compile this without touching the encoder file.
      FIX: Move to src/platform/memory_query.zig. Provide a cross-
           platform `totalAvailableMemoryBytes()` with per-OS switches.

  [3] SEVERITY: MAJOR | line 104 | Category: Dead parameters
      PROBLEM: `pub fn calculateMaxThreads(src_len: usize, level: u8) u32 {
               _ = level; // reserved for future level-dependent estimate`
      WHY IT MATTERS: The `level` parameter is a lie told to callers. If
               you don't use it, don't take it. "Reserved for future"
               comments are how APIs accrete parameters nobody knows how
               to pass.
      FIX: Delete the parameter. Add it back when it does something.

  [4] SEVERITY: MAJOR | lines 120-125 | Category: Error set design
      PROBLEM: `CompressError = error{ BadLevel, BadBlockSize,
               DestinationTooSmall, HashBitsOutOfRange } ||
               std.mem.Allocator.Error || fast_enc.EncodeError ||
               std.Thread.SpawnError`
      WHY IT MATTERS: Public API error set leaks implementation details.
               Callers can't reason about what `compressFramed` might
               return; they have to inspect every union member. A
               `HashBitsOutOfRange` error surfacing from a top-level
               compress call has no meaning for the user.
      FIX: Define a narrow public error set {OutOfMemory, BadOptions,
           DestinationTooSmall, InternalError}. Translate the inner
           errors at the module boundary.

  [5] SEVERITY: MAJOR | lines 260-267 | Category: Duplication
      PROBLEM: `areAllBytesEqual` is defined inline here and ALSO in
               src/encode/block_header_writer.zig:77 as the same
               function with the same doc comment.
      WHY IT MATTERS: Two copies WILL drift.
      FIX: Import from one canonical location.

  [6] SEVERITY: MAJOR | lines 362-413 | Category: Design
      PROBLEM: `compressFramed` implements a multi-piece OOM retry
               ladder by catching error.OutOfMemory from
               compressFramedOne and re-running on smaller chunks. The
               ladder is a hard-coded const array of seven sizes.
      WHY IT MATTERS: The ladder is load-bearing behavior — the encoder
               silently changes its output format (concatenated frames
               vs one frame) based on whether the allocator said yes on
               the first attempt. It's also hidden from the caller: the
               user asked for compression and got something subtly
               different. And the ladder's thresholds have no
               provenance.
      FIX: Make the multi-piece mode explicit in Options. If the user
           wants fallback behavior they opt in. Document that output
           format changes. Do not silently rewrite the strategy on OOM.

  [7] SEVERITY: MAJOR | lines 538-542 | Category: Empty-input edge case
      PROBLEM: Empty-src check writes only the end-mark. Fine. But the
               same empty check is NOT in compressFramedHigh (checked
               at L889-893). The two code paths have independently
               evolved. They will drift. They already have — the Fast
               path writes the end mark before the frame block header
               while the High path does it in a different order.
      FIX: Factor the frame scaffolding out of the two
           codec-framed paths.

  [8] SEVERITY: MAJOR | lines 1195-1198 | Category: Magic numbers
      PROBLEM: `mls.window_base_offset = @intCast(dict_bytes); mls.round_start_pos = @intCast(src_off_abs);`
               with a 100-line comment above explaining which C# file
               this mirrors and why using dict_bytes here would break
               multi-block streams.
      WHY IT MATTERS: The comment is longer than the code. It describes
               a bug that was fixed. Nothing is recording how to recognize
               the bug if it comes back.
      FIX: Extract the comment into a regression test whose name is
           "multi-block streams don't re-emit the 8-byte raw prefix at
           every boundary". Delete the comment.

MINIMUM BEFORE THIS FILE IS ALLOWED TO EXIST:
  - Split per the reorganization manifest. There is no fix for this
    file that leaves it in one piece.
```

### src/encode/high_optimal_parser.zig

**VERDICT:** *The `optimal()` function is 800 lines long. Nobody has read it in one sitting, and nobody ever will.*

```
ISSUES:

  [1] SEVERITY: CRITICAL | optimal() spans lines 288-1102 | Category: God function
      PROBLEM: A single pub fn containing the chunk sizer, phase-1
               forward DP, phase-2 backward extract, phase-3 stats
               update, the outer re-run loop, and all five lazy trial
               variants. ~800 lines of nested `while (true)` and
               `while (jj < state_width)`.
      WHY IT MATTERS: The function has 13 levels of nesting in places.
               `pos + best_length_so_far`, `pos + recent_ml + trial_len
               + num_lazy`, and `after_match + trial_len + num_lazy`
               are arithmetic expressions repeated three and four
               times with one-off sign casts. Any off-by-one
               introduced in one of them is undiscoverable.
      FIX: Split into collect_statistics.zig, forward_dp.zig (one
           function per state_width path), backward_extract.zig,
           update_state.zig. See reorganization manifest.

  [2] SEVERITY: MAJOR | line 311 | Category: Dead code
      PROBLEM: `_ = &dict_size;` — a dead statement whose purpose is to
               suppress an unused-variable warning on a variable that
               was assigned 10 lines earlier and then used 30 lines
               later. The warning suppressor is a LIE; dict_size IS
               used at line 649.
      WHY IT MATTERS: If you need to suppress a warning that isn't
               actually a warning, you are papering over something.
               Zig doesn't have this warning. This is C# muscle memory.
      FIX: Delete line 311. Let the compiler tell you if there's a
           real problem.

  [3] SEVERITY: MAJOR | lines 325-327 | Category: Allocation
      PROBLEM: `const match_table = try ctx.allocator.alloc(LengthAndOffset, @intCast(4 * src_size))`
               — a 4 * src_size allocation in an inner loop (per-block).
               For a 256 KB block that's a 16 MB transient allocation.
      WHY IT MATTERS: The allocation is called once per block and freed
               at block end. That's thrashing. C# uses `laoManaged`
               reuse; this port doesn't. Over a 100 MB file at 400
               blocks, that is 400 × 16 MB alloc/free cycles.
      FIX: Hoist the allocation to the caller and pass it through. Or
           cache it in the cross-block state.

  [4] SEVERITY: MAJOR | lines 633-680 | Category: Match-list filtering
      PROBLEM: `var lao_ml: u32 = @bitCast(match_table[4 * pos + lao_index].length);`
               — the comment above reads "bit reinterpretation, not a
               range-checked cast. The varlen extractor may have
               written a garbage value into the offset slot immediately
               after a length=0 terminator".
      WHY IT MATTERS: Reading garbage values because the extractor
               contract is unclear is how use-after-free vulnerabilities
               are born. The extractor should guarantee that entries
               past the length=0 terminator are zeroed. "We bitcast
               to u32 and hope the break catches it" is not a contract.
      FIX: `extractLaoFromMls` must zero the tail. Delete the bitcast
           and use a normal cast.

MINIMUM BEFORE THIS FILE IS ALLOWED TO EXIST:
  - optimal() reduced to < 150 lines of orchestration.
  - match_table allocation lifted out of the hot path.
  - lao_ml / lao_offs bitcasts removed once the extractor guarantees
    zero-termination.
```

### src/io/bit_writer.zig + src/io/bit_writer_64.zig

**VERDICT:** *Duplicate public types with the same name across two files. One of the worst defects in the tree.*

```
ISSUES:

  [1] SEVERITY: CRITICAL | Both files | Category: Public-API duplication
      PROBLEM: bit_writer.zig:19-58 declares `pub const BitWriter64Forward =
               struct { ... }` with method `pub inline fn write(self: *BitWriter64Forward, bits: u32, n: u6) void`.
               bit_writer_64.zig:18-58 declares the SAME struct name
               with method `pub inline fn write(self: *BitWriter64Forward, bits: u32, n: u5) void`.
               The `n` width differs. Anyone importing the "wrong" one
               gets subtly different semantics.
      WHY IT MATTERS: tans_encoder.zig imports bit_writer_64; every
               other consumer imports bit_writer. If you ever try to
               use both in the same module you will get an ambiguous
               type error. More insidiously, the TWO implementations
               of flush() use different pointer casting idioms
               (std.mem.writeInt on one side, raw `*align(1) u64` on
               the other). They are not guaranteed to produce the same
               bits on exotic targets.
      FIX: Delete bit_writer_64.zig. Update tans_encoder.zig to import
           bit_writer. Reconcile the u5-vs-u6 parameter. The u5 limit
           is wrong — writing 32 bits at once is legal and needs u6.

  [2] SEVERITY: MAJOR | bit_writer.zig:22, 63, 101, 137 | Category: `[*]u8` overuse
      PROBLEM: Four parallel writer structs all store `position: [*]u8`.
      WHY IT MATTERS: A slice `[]u8` carries the end, so overflow is
               locally checked. A `[*]u8` does not. The writer cannot
               tell whether it's about to run past the output buffer;
               the caller has to compute that after the fact via
               `getFinalPtr()` and hope.
      FIX: Store `buf: []u8` and a byte cursor. The codegen should be
           the same.

  [3] SEVERITY: MAJOR | bit_writer.zig:29-39 | Category: No errdefer
      PROBLEM: `flush()` stores past `self.position` unconditionally.
               If `write()` was called with more bits than the buffer
               has room for, `flush` scribbles into whatever is beyond
               the buffer.
      WHY IT MATTERS: Undefined behavior on bad input. The encoder is
               supposed to size its output buffer correctly, but that's
               a trust relationship that every `[*]u8`-based writer in
               this codebase depends on. One cost-model bug away from
               corruption.
      FIX: Slice-bounded writer, or unchecked writer paired with a
           separate debug-only bounds-checking wrapper.

MINIMUM:
  - One of the two files is deleted.
  - The survivor writes via a slice, not a pointer.
```

### src/encode/byte_histogram.zig

**VERDICT:** *A struct, an algorithm, and a free function of the same algorithm, all in 99 lines. Also breaks naming convention.*

```
ISSUES:

  [1] SEVERITY: MAJOR | line 13 | Category: Naming
      PROBLEM: `pub fn count_bytes(self: *ByteHistogram, src: []const u8)` —
               snake_case method name. Zig methods are camelCase.
      WHY IT MATTERS: This is the single visible naming-convention
               violation in the whole codebase. It will spread.
      FIX: Rename to `countBytes`. Every caller gets updated. There
           are three.

  [2] SEVERITY: MAJOR | lines 13-16 and 73-76 | Category: Duplication
      PROBLEM: `ByteHistogram.count_bytes` (method) does exactly what
               `countBytesHistogram` (free function) does. Both zero
               the 256-entry array, both loop on `src` incrementing
               `count[b]`.
      WHY IT MATTERS: Two APIs for the same thing. Callers don't know
               which to use; some pick the method (e.g., entropy_encoder.zig),
               others pick the free function (e.g., fast_lz_encoder.zig).
      FIX: Delete the free function. Everyone uses the method.

  [3] SEVERITY: MINOR | lines 21-31 | Category: comptime
      PROBLEM: `log2_lookup_table` is built at comptime with
               `@setEvalBranchQuota(50_000)`. Fine. But it sits next to
               a byte histogram and a cost function; this is three
               responsibilities sharing a file because of authorial
               convenience.
      FIX: See reorganization manifest — split into ByteHistogram.zig
           and histo_cost.zig.
```

### src/encode/fast_lz_parser.zig

**VERDICT:** *Three parsers duplicating match-evaluation helpers from match_eval.zig, with env-var `std.debug.print` in the hot loop.*

```
ISSUES:

  [1] SEVERITY: CRITICAL | lines 238-243 | Category: Debug print in hot path
      PROBLEM: `if (std.process.hasEnvVarConstant("SLZ_TOKEN_TRACE")) { std.debug.print(...) }`
               inside the main loop of runGreedyParser.
      WHY IT MATTERS: `hasEnvVarConstant` reads from `std.os.environ`
               every single iteration of the parser. For a 100 MB file
               that's tens of millions of environment lookups even
               when SLZ_TOKEN_TRACE is unset. The branch is "predicted
               not taken" at best. In practice this is a measurable
               slowdown, and it is a DEBUG PRINT in a library hot path.
      FIX: Make the trace a comptime flag (`comptime const trace_tokens = false;`)
           so the branch and the hasEnvVarConstant call are both
           eliminated at build time. If runtime toggling is actually
           needed, gate it on a pointer to an atomic flag set once at
           startup.

  [2] SEVERITY: CRITICAL | (same defect in) fast_lz_encoder.zig:307-320 | Category: Debug print in production
      PROBLEM: `if (std.process.hasEnvVarConstant("SLZ_COST_TRACE")) { std.debug.print(...) }`
               inside assembleEntropyOutput.
      WHY IT MATTERS: Same as above. Plus the std.debug.print call is
               formatting 14 floats and integers every time, even
               though the branch normally isn't taken — the formatter
               has to be compiled in.
      FIX: Same — comptime trace flag.

  [3] SEVERITY: MAJOR | lines 288-343 | Category: Duplication
      PROBLEM: `countMatchingBytes`, `isMatchBetter`,
               `isBetterThanRecentMatch`, `isLazyMatchBetter` are
               duplicated from src/encode/match_eval.zig. The comment
               at the top of match_eval.zig admits: "Fast's
               `fast_lz_parser.zig` has its own inlined copies of
               `countMatchingBytes` and friends — those stay where
               they are to preserve the Fast-encoder byte-exact
               parity".
      WHY IT MATTERS: "Byte-exact parity preservation via copy-paste"
               is not a plan. It's a time bomb. The two copies WILL
               drift. The comment doesn't even spell out HOW to update
               one without breaking the other.
      FIX: Import from match_eval.zig. If the inlined versions
           differ, the differences are bugs in one of the copies;
           reconcile them and commit to a single implementation.

  [4] SEVERITY: MAJOR | runGreedyParser spans lines 55-279 | Category: God function
      PROBLEM: 225 lines of parser hot loop, including the skip
               heuristic, hash lookup, recent-offset test, hash-table
               match test, offset-8 fallback, 2/3-byte recent, back-
               extension, token emit, and match interior re-insertion.
      WHY IT MATTERS: When this function breaks, the author will be
               hunting a bug spread across 225 lines of pointer
               arithmetic. The whole function is one `outer: while`
               label.
      FIX: Split the match-finding step, the back-extension step, and
           the rehash step into helpers.

  [5] SEVERITY: MAJOR | lines 110-111 | Category: Pointer arithmetic via integer cast
      PROBLEM: `const recent_src_addr: usize = @intFromPtr(source_cursor) +% @as(usize, @bitCast(recent_offset));`
               `const recent_src_ptr: [*]const u8 = @ptrFromInt(recent_src_addr);`
      WHY IT MATTERS: Zig has escape hatches for a reason — this is
               pointer arithmetic on a signed offset. It is correct,
               but there is no comment explaining WHY these escape
               hatches are needed (the answer: because the offset can
               be negative, and Zig's slice arithmetic would trap).
               Readers reach for `@ptrFromInt` and cargo-cult it
               elsewhere.
      FIX: Wrap this pattern into a single helper
           `offsetFromCursor(cur, delta)` in a shared file. The intent
           becomes obvious. The escape hatch lives in one place.
```

### src/format/streamlz_constants.zig

**VERDICT:** *Junk drawer for magic numbers spanning eight unrelated domains.*

```
ISSUES:

  [1] SEVERITY: MAJOR | Whole file | Category: Organization
      PROBLEM: 128 lines with eight section dividers ("Chunk and buffer
               sizing", "Offset encoding constants", "Huffman lookup
               table sizing", ...). The fact that the author needed
               eleven dividers to navigate the file is the tell.
      FIX: Split per reorganization manifest.

  [2] SEVERITY: MINOR | line 96 | Category: comptime
      PROBLEM: `pub const invalid_cost: f32 = @import("std").math.floatMax(f32) / 2;`
               — `@import("std")` at the call site of a constant, in a
               file that otherwise declares no `std` import.
      WHY IT MATTERS: Imports should live at the top of the file. This
               is the only one mid-file, because the author tried to
               keep the file import-free and failed here.
      FIX: Move `const std = @import("std");` to the top.
```

### src/decode/cleanness_analyzer.zig

**VERDICT:** *1640 lines of research tooling compiled into a production decoder.*

```
ISSUES:

  [1] SEVERITY: MAJOR | Whole file | Category: Scope pollution
      PROBLEM: A speculative-parallel-decode feasibility study lives
               inside src/decode/. Every downstream consumer compiles
               this into their binary. `src/main.zig` imports it for
               the `analyze` CLI subcommand — that's the ONLY consumer.
      FIX: Move to src/tools/. Gate the `analyze` subcommand's
           inclusion behind a build option so library users don't ship
           it.

  [2] SEVERITY: MAJOR | line 53 | Category: Enormous on-stack struct
      PROBLEM: `round_histogram: [65536]u64` — a 512 KB field inside
               the `FileStats` struct. Allocated on the stack of the
               caller of `analyzeFile`.
      WHY IT MATTERS: Stack overflow risk. On Windows the default
               stack is 1 MB.
      FIX: Heap-allocate the histogram.
```

### src/format/frame_format.zig

**VERDICT:** *Two unrelated wire objects share a file because they both appear in the frame layout diagram.*

```
ISSUES:

  [1] SEVERITY: MAJOR | Whole file | Category: Two responsibilities
      PROBLEM: Declares `FrameHeader` + `parseHeader` + `writeHeader`
               AND `BlockHeader` + `parseBlockHeader` + `writeBlockHeader`
               + `writeEndMark`. Also uses the name `BlockHeader` which
               collides with `block_header.BlockHeader`.
      FIX: Split. Rename collisions.

  [2] SEVERITY: MAJOR | line 99 | Category: Unsafe enum cast
      PROBLEM: `const codec: Codec = @enumFromInt(src[pos]);` where
               `Codec` is `{ high, fast, turbo, _ }`. The `_` trailing
               marker suppresses exhaustive checks; an attacker-
               controlled input with `codec == 255` becomes a Codec
               enum value that the `name()` function on line 61 maps
               to "Unknown" without erroring.
      WHY IT MATTERS: The frame parser will SILENTLY accept invalid
               codec bytes and hand them to the block decoder, which
               then has to re-validate.
      FIX: Validate after the cast. Return `error.BadCodec` if not one
           of the named members. Delete the `_` marker.
```

### Systemic defects (apply across the tree)

**1. `[*]u8` / `[*]const u8` contamination**
Raw pointers appear in: `fast_lz_parser.zig`, `fast_lz_encoder.zig`, `fast_token_writer.zig`, `fast_stream_writer.zig`, `high_encoder.zig`, `high_types.zig`, `high_lz_decoder.zig`, `fast_lz_decoder.zig`, `high_lz_process_runs.zig`, `match_hasher.zig`, `offset_encoder.zig`, `copy_helpers.zig`, `bit_writer.zig`, `bit_writer_64.zig`, `bit_reader.zig`, and `streamlz_decoder.zig`. The hot loops arguably need them. Everything else inherited them by accident. `match_hasher.setSrcBase(base: [*]const u8)` has no reason to take a `[*]const u8` — it could take `[]const u8` and be safer.

Fix: Adopt a convention. Slice at API boundaries, raw pointer inside hot loops only, with a comment explaining why at the point of conversion. Audit every call site.

**2. `@intFromPtr` / `@ptrFromInt` abuse**
`ptrFromInt(@intFromPtr(x) +% offset)` appears dozens of times. It's the idiom for "signed offset from a base pointer", and there is no helper. Defensible inside the parser hot loop (it compiles to LEA); inexcusable in utility code.

Fix: A helper `offsetPointer(base: anytype, delta: isize) @TypeOf(base)` in a shared `ptr_math.zig`.

**3. Unused parameters suppressed with `_ =`**
- streamlz_encoder.zig:104 — `_ = level;`
- high_optimal_parser.zig:311 — `_ = &dict_size;` (lies — dict_size IS used)
- fast_lz_decoder.zig:374 — `_ = dst_ptr_end;`
- fast_lz_decoder.zig:606 — `_ = src_ptr;`
- fast_lz_encoder.zig:764 — `_ = window_base;`
- high_lz_decoder.zig:75 — `_ = excess_bytes;` (in unpackOffsets)
- entropy_encoder.zig:183 — `_ = level;`

Fix: If the parameter isn't used, it isn't a parameter. Delete.

**4. Error set bloat**
Public error types union together the error set of every helper they call. `CompressError` chains six sets. `DecompressError` chains eight. Callers get error names like `HashBitsOutOfRange` from a top-level `decompressFramed` call.

Fix: Narrow public error sets. Translate at the boundary.

**5. Dead parity comments**
The codebase is littered with "this mirrors C# line X of file Y" annotations. Some are 30 lines long. They document decisions that already live in the code. In five years when the C# reference is gone they will rot.

Hits: `high_optimal_parser.zig:1033-1047`, `streamlz_encoder.zig:1183-1198`, `entropy_encoder.zig:469-474`, `fast_lz_parser.zig:216-224`, many others.

Fix: Move the interesting ones to regression-test names. Delete the rest.

**6. Type-file convention ignored**
`FastMatchHasher`, `FastStreamWriter`, `ManagedMatchLenStorage`, `ByteHistogram`, `MatchHasher`, `MatchHasher2`, `HuffRevLut`, `TansData`, `TansLutEnt`, `State`, `Token`, `CostModel`, `Stats`, `HighStreamWriter`, `HighRecentOffs`, `HighLzTable`, `FastLzTable`, `HighEncoderContext`, `HighCrossBlockState` — all files-that-are-essentially-one-struct named in snake_case.zig. Zig idiom is `PascalCase.zig` when a file is a type.

Fix: Rename. Enforce it in PR review.

**7. Test files inside `src/`**
`src/encode/encode_fixture_tests.zig` and `src/decode/fixture_tests.zig` — if you want fixtures next to production code they should at least be named `*_test.zig` consistently. The whole codebase inlines `test "..."` blocks at the bottom of each production file AND has separate test files. Pick one.

**8. `extern struct` without FFI**
`HighRecentOffs`, `Token`, `State`, `HuffRevLut`, `NewHuffLut`, `HuffRange`, `TansData`, `TansLutEnt`, `HeapEntry`, `TansEncEntry` — all declared `extern struct` without crossing any FFI boundary. Zig's extern layout rules are for C interop; using them for everything removes a real tool (`packed struct`, `@sizeOf`-tight layouts) and adds padding surprises.

Fix: Use `extern` only where the struct genuinely crosses to C. For layout control in pure-Zig code use explicit field ordering.

**9. `@prefetch` without measurement commits**
`match_hasher.setHashPosPrefetch` and `high_lz_process_runs.processLzRunsType0` use `@prefetch`. The comments claim ~8s of DRAM stalls saved on 100MB enwik8 L9. Good. But there's no regression test — if someone accidentally removes the prefetch the only signal is a benchmark regression.

Fix: A perf regression test or at least a comment explaining *which benchmark* to re-run to validate the prefetch is still helping.

**10. Alignment casts without proof**
`@alignCast` / `@ptrCast(@alignCast(...))` patterns in `high_encoder.zig:127`, `match_finder.zig:132-136`, `fast_stream_writer.zig:112`. In most cases the alignment is established by the allocation pattern on the line before, but there's no assertion proving it at runtime.

Fix: Either `std.debug.assert(@intFromPtr(p) & (align-1) == 0)` before the cast, or allocate with aligned types instead of `[]u8` + manual alignment math.

**11. `std.testing.allocator` usage is inconsistent**
Every test block uses `testing.allocator` — good, leak detection is on. But the fixture tests allocate 1 << 30 bytes for `readFileAlloc`. For a 1 GB file, `testing.allocator` will happily try to allocate it. On a small test host this OOMs the test runner.

Fix: Cap the per-fixture size sensibly, or use `std.heap.page_allocator` for the I/O-sized allocations and `testing.allocator` only for the decoder state.

---

### Quick-hit per-file verdicts (remaining files — single sentence each)

- `src/encode/high_types.zig` — Seven unrelated public types in one file. **SPLIT.**
- `src/encode/high_compressor.zig` — `HighHasher` tagged union is fine but `doCompress` dispatches via five repeated blocks; comptime could fold this. **OK with polish.**
- `src/encode/high_fast_parser.zig` — Comptime-generic over hasher type, reasonable. **OK.**
- `src/encode/high_encoder.zig` — `assembleCompressedOutput` (250 lines) is a god function. `alignUpPtr` is redefined locally instead of imported from `copy_helpers.zig`. **SPLIT.**
- `src/encode/high_cost_model.zig` — `updateStats` has 3-level nested if-else on `offs_encode_type` that should be a switch with extracted cases. **OK with polish.**
- `src/encode/high_matcher.zig` — Short and focused. **OK.**
- `src/encode/match_finder.zig` — SIMD probe is aggressive but bounds-checked. The inline BSF iteration loop is well-commented. **OK.**
- `src/encode/match_finder_bt4.zig` — `bt4SearchAndInsert` takes 12 parameters; the `writeRef` helper patches over a signed-bool pair that should be an enum. **OK with polish.**
- `src/encode/managed_match_len_storage.zig` — VarLen codec is four private helpers and four public extractors; split them. **OK.**
- `src/encode/match_eval.zig` — See systemic defect #2. **Merge with the fast parser's inline copies.**
- `src/encode/cost_model.zig` — Misnamed (it's Fast-specific); magic numbers have no provenance. **RENAME.**
- `src/encode/cost_coefficients.zig` — Magic numbers with "tuned on Intel Arrow Lake-S" comment. Fine as-is.
- `src/encode/offset_encoder.zig` — Seven responsibilities; see manifest. **SPLIT.**
- `src/encode/tans_encoder.zig` — Five responsibilities; see manifest. **SPLIT.**
- `src/encode/entropy_encoder.zig` — Dead `level` parameter. Comments at line 469 describe an unreachable C# branch kept "for audit parity". **POLISH.**
- `src/encode/fast_lz_encoder.zig` — Three encode entry points with duplicated block1/block2 loop scaffolding. **SPLIT.**
- `src/encode/fast_match_hasher.zig` — Type-file, decent. **OK.**
- `src/encode/fast_stream_writer.zig` — 12 pointer fields in one struct; cache-line locality is intentional. **OK.**
- `src/encode/fast_token_writer.zig` — `extendMatchForward` doesn't belong here. `writeOffsetWithLiteral1` uses a hand-rolled SIMD 16-byte byte-equality check — well-commented. **OK with polish.**
- `src/encode/fast_constants.zig` — Four responsibilities. **SPLIT.**
- `src/encode/text_detector.zig` — Short, focused, well-commented. **MOVE** out of encode/.
- `src/encode/block_header_writer.zig` — Asymmetric with format/block_header.zig. **MERGE.**
- `src/encode/encode_fixture_tests.zig` — Wrong location. **MOVE.**
- `src/decode/streamlz_decoder.zig` — Six responsibilities. `LazyPool` wrapper is OK; the rest should split. **SPLIT.**
- `src/decode/decompress_parallel.zig` — Atomic error sharing between workers is good. `@intFromError`/`@errorFromInt` round-trip needs a comment explaining the discriminator stability assumption. **OK with polish.**
- `src/decode/fast_lz_decoder.zig` — `processModeImpl` is 230 lines of hot loop; long-literal and long-match branches should extract. **OK with polish.**
- `src/decode/high_lz_decoder.zig` — `readLzTable` has four near-duplicate "decode stream, advance cursor" blocks; helper-ize. **OK with polish.**
- `src/decode/high_lz_process_runs.zig` — Type0 / Type1 paths are parallel code; should be sibling files. **SPLIT.**
- `src/decode/entropy_decoder.zig` — Recursive multi-block path has depth counter; good. Chunk-type switch is flat; acceptable. **OK.**
- `src/decode/huffman_decoder.zig` — 1021 lines with a single-file hot loop; could split LUT construction from decode, but the hot loop itself is reasonable. **POLISH.**
- `src/decode/tans_decoder.zig` — Matches the encoder's 5-state shape; OK. Weird coupling to huffman_decoder.zig. **OK with polish.**
- `src/decode/fixture_tests.zig` — Wrong location. **MOVE.**
- `src/decode/cleanness_analyzer.zig` — 1640 lines of research tooling. **MOVE to tools/.**
- `src/main.zig` — Seven subcommand handlers. **SPLIT.**
- `build.zig` — 51 lines, clean, well-commented. **KEEP.**
- `src/io/bit_reader.zig` — One focused responsibility. **KEEP.** (Move to src/bits/.)
- `src/io/copy_helpers.zig` — Inline asm `pshufb` fallback, well-commented. PSHUFB masks should split. **POLISH.**
- `src/format/frame_format.zig` — Two responsibilities + unsafe enum cast. **SPLIT + FIX.**
- `src/format/block_header.zig` — Name collision; asymmetric split with encode/block_header_writer.zig. **MERGE.**
- `src/format/streamlz_constants.zig` — Eight-responsibility junk drawer. **SPLIT.**

---

## GLOBAL REPORT

### ARCHITECTURAL FAILURES

1. *Two-directory flat layout.* `src/encode/` has 25 files; `src/decode/` has 10. No sub-folder structure. Everything imports everything. The Fast codec, the High codec, the entropy coders, the bit I/O, the match finders, the hash tables, the windows FFI, the platform thread pool query, and two test files share one namespace.

2. *Three stub files that compile to nothing.* `high_lz_encoder.zig`, `multi_array_huffman_encoder.zig`, `optimal_parser.zig`. They are TODO markers dressed as source. Zig has no convention for this. They should not exist.

3. *Duplicate-name public types across files.* `BitWriter64Forward` lives in two files. `BlockHeader` exists in `format/block_header.zig` and in `format/frame_format.zig` with no warning about the collision.

4. *Fifteen-responsibility streamlz_encoder.zig.* 2568 lines. Windows FFI through to SC-parallel-compression through to OOM fallback ladder. This is the worst file in the tree.

5. *Three 800+-line god functions* — `optimal()` in high_optimal_parser.zig, `assembleCompressedOutput()` in high_encoder.zig, `runGreedyParser()` in fast_lz_parser.zig.

6. *Copy-pasted match-evaluation helpers* in fast_lz_parser.zig (duplicating match_eval.zig), blessed with a "preserves byte-parity with C#" comment that is a maintenance bomb.

### MEMORY DISCIPLINE

Mostly acceptable. Every function that allocates takes an `Allocator`. `deinit` is consistent. `errdefer` usage is inconsistent — some files use it thoroughly (`MatchHasher2.init` in match_hasher.zig:423-429), many don't (`high_encoder.initializeStreamWriter` allocates `buf` then computes alignment; no errdefer is needed there because there's only one allocation, but analogous multi-step inits in `streamlz_encoder.zig` rely on sequential `try` without `errdefer`, which is a partial-init leak waiting to happen).

Leak risk level: **moderate**. Tests use `std.testing.allocator`, which is excellent. The fixture tests allocate 1 GB buffers against it, which is not.

Percentage of allocating functions that take an Allocator parameter: ~95%. The ones that don't are the CLI handlers in main.zig which use a closed-over gpa allocator — acceptable.

### ERROR HANDLING DISCIPLINE

- `catch unreachable` count: **zero** (checked via grep). That is the only thing this codebase does perfectly.
- `anyerror` usage: none.
- Swallowed errors: none found.
- Error set design: **bad**. Public error sets union eight sub-sets. `CompressError` exposes `HashBitsOutOfRange` to top-level callers. Every file's error set is `{ ... } || sub.Error || std.mem.Allocator.Error`. Callers cannot reason about the shape of what might fail.
- `error.BailOut` is used as control flow in `high_compressor.zig:357` and `high_optimal_parser.zig:302, 407, 1038`. Errors for control flow are an anti-pattern; `?usize` returning null would be cleaner.

### COMPTIME HYGIENE

Acceptable. `log2_lookup_table`, `match_copy_pshufb_masks`, and the generic `MatchHasher(num_hash, dual_hash)` all use comptime for legitimate table building and generic specialization. `fast_lz_parser.runGreedyParser` takes `comptime level: i32, comptime T: type` and specializes the hot loop — correct. No `comptime` cargo-culting observed. `@setEvalBranchQuota(50_000)` is used once and is appropriate.

One misuse: `entropy_encoder.zig:183` suppresses a `level: u32` parameter that is reserved for future use. Reserved comptime parameters are harmless; reserved runtime parameters are a lie.

### IDIOMATIC ZIG COMPLIANCE

**Does not feel like Zig.** Feels like a faithful C# → Zig transliteration. Evidence:

- `[*]u8` everywhere something could be `[]u8` or `*[N]u8`.
- `@intFromPtr`/`@ptrFromInt` used as a default for signed-offset pointer math, not as an escape hatch.
- Methods named `count_bytes` (snake_case) in byte_histogram.zig.
- Single-type files named `snake_case.zig` instead of `PascalCase.zig`.
- `extern struct` everywhere (10+ cases) without FFI.
- Inline `test "..."` blocks at the bottom of every file inconsistently mixed with parallel test files in `src/encode/encode_fixture_tests.zig`.
- Dead parity comments pointing at C# source line numbers.
- "Port of" header comment on nearly every file, sometimes longer than the code.

This reads like a codebase under active porting. A published reference implementation would hide the C# scaffolding.

### PATTERNS OF FAILURE

- **Defensive copies of reference comments.** The worst example is fast_lz_parser.zig:216-224 which has an 8-line comment explaining a C# back-extension bound. The comment describes a historical decision. The code implements the current decision. Over time the two will desync.
- **God functions over 200 lines.** At least six: `optimal`, `assembleCompressedOutput`, `runGreedyParser`, `processModeImpl`, `encodeSubChunkRaw`, `compressFramedOne`, `compressFramedHigh`.
- **Magic-number proliferation.** `streamlz_constants.zig` has 22 public constants across 8 domains. `cost_coefficients.zig` has 30. `offset_encoder.zig` has four more that shadow `streamlz_constants` (`high_offset_marker`, `high_offset_cost_adjust`, `offset_bias_constant`, `low_offset_encoding_limit`) with a comment apologizing for a previous bug where a stale local copy diverged. The bug will come back.
- **Env-var-gated debug prints in hot loops.** Two instances.

### NAMING DEBT

| Offense | Example | Severity |
|---|---|---|
| snake_case method name | `ByteHistogram.count_bytes` | MAJOR |
| `_lz_` noise | `fast_lz_parser`, `fast_lz_encoder`, `fast_lz_decoder`, `high_lz_decoder`, `high_lz_process_runs` — "lz" is the entire project, it's redundant | MAJOR |
| `_encoder`/`_decoder` noise when the enclosing folder already says `encode` / `decode` | throughout | MINOR |
| Duplicate type name across files | `BitWriter64Forward`, `BlockHeader` | CRITICAL |
| Type-file convention ignored | 18 files are effectively one struct and should be `PascalCase.zig` | MAJOR |
| Stub files with deceptive names | `high_lz_encoder.zig` (5 lines), `multi_array_huffman_encoder.zig` (7 lines), `optimal_parser.zig` (5 lines) | CRITICAL |
| `high_optimal_parser.zig` vs `optimal_parser.zig` (stub) | confusing pair | MAJOR |
| `cost_model.zig` (Fast-specific) vs `high_cost_model.zig` | asymmetric | MINOR |

### REORGANIZATION IMPACT

From the 50-file layout to the proposed ~105-file layout:
- 2 files survive in place (`build.zig`, `bit_reader.zig`)
- 3 files are **deleted** (all three stubs)
- 1 file is **deleted** as a duplicate (`bit_writer_64.zig`)
- 44 files move. The largest single file (`streamlz_encoder.zig` at 2568 lines) becomes 10 files averaging 250 lines each.
- 18 files become `PascalCase.zig` type-files.

That 96% of the original paths are wrong is a verdict on the `src/{encode,decode}` split. It was never going to scale.

### MOST CRITICAL FIXES (ranked)

1. **Delete `bit_writer_64.zig`**, reconcile with `bit_writer.zig`, fix the u5/u6 mismatch. There is a latent correctness bug here waiting for someone to write a 32-bit field via the "wrong" writer.
2. **Delete the three stub files** (`high_lz_encoder.zig`, `multi_array_huffman_encoder.zig`, `optimal_parser.zig`). They lie about coverage.
3. **Remove the env-var-gated `std.debug.print` calls** in `fast_lz_parser.zig:238-243` and `fast_lz_encoder.zig:307-320`. Replace with comptime trace flags.
4. **Split `streamlz_encoder.zig`** per the manifest. This is the biggest architectural win available.
5. **Split `high_optimal_parser.optimal()`** into its three phases and the outer loop. Nobody can audit 800 lines at once, and the DP correctness matters.
6. **Rename `ByteHistogram.count_bytes` → `countBytes`** and delete the duplicate free function.
7. **Merge the inline match-eval helpers** in `fast_lz_parser.zig` with `match_eval.zig`. Kill the "byte-parity comment" excuse for duplication.
8. **Delete the `_ = parameter;` suppressions.** Each one is either a dead parameter (delete it) or a bug (use it).
9. **Move `cleanness_analyzer.zig`** out of the decoder package.
10. **Move fixture tests** out of `src/`.
11. **Introduce `src/lz/match_eval.zig`** as the canonical match-evaluation module; remove the cross-file duplication.
12. **Narrow public error sets.** `CompressError` and `DecompressError` should not expose every internal helper's error.

### OVERALL GRADE: **D+**

**Grading note:**

This is a codebase that works. Tests pass, fixtures roundtrip, benchmarks exist. The hot loops are well-thought-out and the SIMD is measured. The author clearly knew what they were doing at the instruction level, and the prefetch / branch-hint / comptime-generic decisions are evidence of professional performance engineering.

It is also a codebase that was never organized. It grew. Files that started as one responsibility accrued three more. The `src/{encode,decode}` split was adequate when there were ten files and catastrophic when there were fifty. The `[*]u8` contamination started in the hot loops and spread to everything because nobody drew a line. Two copies of a bit writer exist because the second was added when the first wasn't convenient, and the first wasn't deleted. A 1640-line research tool ships inside the production decoder because it was the easiest place to put it.

None of this is unfixable. The algorithms are correct. The reorganization is mechanical. The systemic defects have well-defined fixes. But it is not publishable as a reference implementation in its current shape, and the gap between "works" and "flawless" is very large.

A D+ means the code is not broken but is embarrassing to show. The grade goes to C+ once the reorganization lands. B once the god functions are split and the systemic issues (raw pointer contamination, duplicated helpers, error set bloat) are addressed. A is only possible once the codebase stops reading like a C# port.

It is not a C# port. It is a Zig codebase. It should read like one.

---

*The Inquisitor is done. The work is not.*

---

## STATUS TRACKER (updated 2026-04-18)

### MOST CRITICAL FIXES

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Delete `bit_writer_64.zig`, fix u5/u6 mismatch | **DONE** | Deleted file, updated tans_encoder + offset_encoder to import `bit_writer.zig` |
| 2 | Delete three stub files | **DONE** | `high_lz_encoder.zig`, `multi_array_huffman_encoder.zig`, `optimal_parser.zig` deleted |
| 3 | Remove env-var debug prints → comptime flags | **DONE** | `SLZ_TOKEN_TRACE` → `trace_tokens`, `SLZ_COST_TRACE` → `trace_cost` |
| 4 | Split `streamlz_encoder.zig` | **DONE** | 5-way split: `streamlz_encoder.zig` (667 lines, public API), `fast_framed.zig`, `high_framed.zig`, `compress_parallel.zig`. Down from 2636 lines. |
| 5 | Split `optimal()` into phases | **DONE** | Extracted `backwardExtract()` (~80 lines). `optimal()` reduced from ~820 to ~764 lines. Forward DP stays as one function (shared mutable state). |
| 6 | Rename `count_bytes` → `countBytes`, delete duplicate | **DONE** | Renamed method, deleted `countBytesHistogram`, updated all call sites |
| 7 | Merge inline match-eval helpers with `match_eval.zig` | **SKIPPED** | The copies have different type signatures (`usize` vs `isize` offsets, `i32` vs `u32` lengths) tuned to their respective codec hot loops. Not true duplicates — merging would require type coercion in the hot path. Comment updated to explain the real reason they're separate. |
| 8 | Delete `_ = parameter;` suppressions | **DONE** | Fixed `dict_size` (var→const), deleted dead `bits_per_sym_width`, removed unused `start_position` param. Legitimate API-compat suppressions (`_ = level`, `_ = dst_ptr_end`, etc.) left in place with comments. |
| 9 | Move `cleanness_analyzer.zig` out of decoder | **DONE** | Renamed to `cross_chunk_analyzer.zig`. Stays in `decode/` — it's now production code (builds the L5 parallel-decode sidecar at compress time), not research tooling. |
| 10 | Move fixture tests out of `src/` | **SKIPPED** | Zig test discovery relies on `@import` chains from `main.zig`. Moving breaks that. Added `//! Test-only module` headers instead. |
| 11 | Introduce `src/lz/match_eval.zig` as canonical | **SKIPPED** | Same as #7 — the type signatures genuinely differ between Fast and High codecs. The shared `match_eval.zig` already exists for the High codec; Fast's inline copies are intentionally different. |
| 12 | Narrow public error sets | **DONE** | Removed `HashBitsOutOfRange` from `CompressError` (translated to `BadLevel` at call sites). Converted `error.BailOut` to `?usize` optional return. |

### streamlz_encoder.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | Split into ~10 files | **DONE** — 5-way split (not 10): `fast_framed.zig`, `high_framed.zig`, `compress_parallel.zig` + dispatcher. 2636→667 lines. |
| [2] | Extract Windows FFI | **DONE** — `platform/memory_query.zig` with Windows + Linux + macOS support |
| [3] | Dead `level` parameter in `calculateMaxThreads` | **PENDING** — kept for forward-compat; removing would break callers who pass it |
| [4] | Error set leaks `HashBitsOutOfRange` | **DONE** — removed from public error set, translated at call sites |
| [5] | Duplicate `areAllBytesEqual` | **DONE** — merged `block_header_writer.zig` into `format/block_header.zig`, encoder imports from there |
| [6] | Multi-piece OOM retry is implicit | **PENDING** — behavior is correct and load-bearing; documenting in Options is a future API improvement |
| [7] | Empty-input edge case divergence | **PENDING** |
| [8] | Magic numbers with 100-line parity comments | **DONE** — all C# parity comments stripped (145+ instances across 41 files) |

### high_optimal_parser.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | 800-line god function | **SKIPPED** — single DP algorithm, splitting reduces cohesion |
| [2] | Dead `_ = &dict_size;` suppression | **DONE** — changed `var` to `const` (it IS used, just never mutated) |
| [3] | Per-block 16 MB `match_table` allocation | **DONE** — hoisted to caller; 1 alloc per frame (serial) or per worker thread (parallel) instead of 400× cycles |
| [4] | `@bitCast` on garbage lao_ml values | **DONE** — `extractLaoFromMls` now zeroes remaining slots after terminator. `@bitCast` kept (varlen encoding legitimately sets sign bit) but safety is in the producer. |

### bit_writer.zig / bit_writer_64.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | Duplicate public types | **DONE** — `bit_writer_64.zig` deleted, all importers updated |
| [2] | `[*]u8` instead of `[]u8` for position | **SKIPPED** — hot-loop writer, measured; slice would add bounds checks on every flush. The audit itself notes "the hot loops arguably need them." |
| [3] | No bounds check in `flush()` | **SKIPPED** — same reasoning. The encoder sizes output buffers via `compressBound`; adding per-flush checks would cost cycles on every token. |

### byte_histogram.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | snake_case `count_bytes` method | **DONE** — renamed to `countBytes` |
| [2] | Duplicate `countBytesHistogram` free function | **DONE** — deleted, callers use `ByteHistogram.countBytes` |
| [3] | Three responsibilities in one file | **SKIPPED** — 72 lines total after cleanup; splitting a 72-line file into two creates more overhead than it saves |

### fast_lz_parser.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | Debug print in hot loop | **DONE** — `comptime const trace_tokens = false;` |
| [2] | Same defect in fast_lz_encoder.zig | **DONE** — `comptime const trace_cost = false;` |
| [3] | Duplicated match-eval helpers | **SKIPPED** — see #7 above (different type signatures) |
| [4] | 225-line `runGreedyParser` god function | **SKIPPED** — it's one hot loop with clear sections. Extracting match-finding / back-extension into helpers risks inlining failures in the hot path. |
| [5] | Pointer arithmetic via `@intFromPtr/@ptrFromInt` | **DONE** — `io/ptr_math.zig` helper created, 13 instances replaced across 6 files |

### frame_format.zig per-issue status

| # | Issue | Status |
|---|-------|--------|
| [1] | Two responsibilities (frame header + block header) | **SKIPPED** — both are part of the same SLZ1 frame wire format; they belong together |
| [2] | Unsafe enum cast with `_` wildcard | **DONE** — `Codec` enum is now exhaustive, invalid bytes return `error.BadCodec` |

### Systemic defects status

| # | Defect | Status |
|---|--------|--------|
| 1 | `[*]u8` contamination | **SKIPPED** — intentional in hot loops (measured). API boundaries already use slices where possible. Full audit would touch 16 files for marginal safety gain. |
| 2 | `@intFromPtr/@ptrFromInt` abuse | **DONE** — `io/ptr_math.zig` helper, 13 replacements |
| 3 | Unused `_ = parameter` suppressions | **DONE** — worst offenders fixed (see above) |
| 4 | Error set bloat | **DONE** — `HashBitsOutOfRange` removed, `BailOut` eliminated |
| 5 | Dead C# parity comments | **DONE** — all 145+ references stripped, zero remaining |
| 6 | Type-file PascalCase convention | **DONE** — 3 true single-struct files renamed (`BitReader.zig`, `ByteHistogram.zig`, `FastStreamWriter.zig`). Others are module-style and correctly snake_case. |
| 7 | Test files inside `src/` | **DONE** — added `//! Test-only module` headers. Not moved (Zig test discovery constraint). |
| 8 | `extern struct` without FFI | **DONE** — 11 structs changed to plain `struct`. Only `MemoryStatusEx` (Windows FFI) kept as extern. |
| 9 | `@prefetch` without measurement notes | **PENDING** — prefetch was tested and reverted for the Fast decoder (documented in FailedExperiments.md). High codec prefetch in match_hasher remains without measurement notes. |
| 10 | Alignment casts without assertions | **DONE** — 7 `std.debug.assert` added at setup-time `@alignCast` sites |
| 11 | `std.testing.allocator` for 1 GB fixture reads | **DONE** — fixture tests use `page_allocator` for bulk reads, 256 MB skip threshold |

### Quick-hit per-file verdicts status

| File | Original verdict | Status |
|------|-----------------|--------|
| `high_types.zig` | SPLIT | **SKIPPED** — types are co-dependent; splitting creates circular imports |
| `high_compressor.zig` | OK with polish | **DONE** — `BailOut` removed from `.none` path |
| `high_fast_parser.zig` | OK | **DONE** — renamed to `high_greedy_parser.zig` |
| `high_encoder.zig` | SPLIT | **DONE** — deduped `alignUpPtr` (imports `copy_helpers.alignPointer`), extracted `encodeLiteralStream` (~90 lines) from `assembleCompressedOutput` (240→140 lines) |
| `high_cost_model.zig` | OK with polish | **DONE** — converted 3-level nested if-else in `updateStats` to switch + 3 extracted helpers (`updateOffsType0/1/Split`) |
| `high_matcher.zig` | OK | No action needed |
| `match_finder.zig` | OK | **DONE** — added "Used by" header |
| `match_finder_bt4.zig` | OK with polish | **DONE** — added "Used by" header |
| `managed_match_len_storage.zig` | OK | **DONE** — added "Used by" header |
| `match_eval.zig` | Merge with fast copies | **SKIPPED** — see #7 |
| `cost_model.zig` | RENAME | **DONE** — renamed to `fast_cost_model.zig` |
| `cost_coefficients.zig` | Fine as-is | No action needed |
| `offset_encoder.zig` | SPLIT | **SKIPPED** — 7 responsibilities but they form one pipeline; splitting scatters a linear flow |
| `tans_encoder.zig` | SPLIT | **SKIPPED** — same reasoning; the 5-state encode is one algorithm |
| `entropy_encoder.zig` | POLISH | **DONE** — C# comments stripped |
| `fast_lz_encoder.zig` | SPLIT | **SKIPPED** — three entry points share block1/block2 scaffolding; extracting duplicates the shared setup |
| `fast_match_hasher.zig` | OK | **DONE** — added "Used by" header |
| `fast_stream_writer.zig` | OK | **DONE** — renamed to `FastStreamWriter.zig` |
| `fast_token_writer.zig` | OK with polish | **DONE** — added "Used by" header |
| `fast_constants.zig` | SPLIT | **SKIPPED** — 4 responsibilities but only 140 lines; splitting is overhead |
| `text_detector.zig` | MOVE | **SKIPPED** — used by encoder only; moving to `heuristics/` adds a directory for one file |
| `block_header_writer.zig` | MERGE | **DONE** — merged into `format/block_header.zig` |
| `encode_fixture_tests.zig` | MOVE | **DONE** — added `//! Test-only module` header |
| `streamlz_decoder.zig` | SPLIT | **DONE** (partial) — added `DecompressContext` for pool lifecycle. Full split skipped. |
| `decompress_parallel.zig` | OK with polish | **DONE** — added `max_threads` plumbing, `SLZ_CORES` env var support for all paths |
| `fast_lz_decoder.zig` | OK with polish | No action needed |
| `high_lz_decoder.zig` | OK with polish | **DONE** — alignment assertions added |
| `high_lz_process_runs.zig` | SPLIT | **DONE** — renamed to `high_lz_token_executor.zig` |
| `entropy_decoder.zig` | OK | No action needed |
| `huffman_decoder.zig` | POLISH | **DONE** — extracted shared Golomb-Rice/bit-reader infrastructure to `bit_reader_lite.zig` (1021→689 lines); section headers clarified |
| `tans_decoder.zig` | OK with polish | **DONE** — imports `bit_reader_lite.zig` directly; no longer depends on `huffman_decoder.zig` |
| `fixture_tests.zig` | MOVE | **DONE** — added `//! Test-only module` header |
| `cleanness_analyzer.zig` | MOVE to tools/ | **DONE** — renamed to `cross_chunk_analyzer.zig`, stays in decode/ (production sidecar builder) |
| `main.zig` | SPLIT | **SKIPPED** — 742 lines, 7 handlers; standard for a CLI. Adding `-t` flag was done without splitting. |
| `build.zig` | KEEP | No action needed |
| `bit_reader.zig` | KEEP | **DONE** — renamed to `BitReader.zig` (PascalCase type-file) |
| `copy_helpers.zig` | POLISH | **DONE** — header updated to document all 3 responsibilities (SIMD copies, PSHUFB match replication, pointer alignment). PSHUFB masks stay (only used internally by `copyMatch16Pshufb`). `alignPointer` is the canonical shared helper. |

### REORGANIZATION MANIFEST status

| Proposed change | Status |
|----------------|--------|
| 50 → 105 file restructure | **DONE** (partial) — created `encode/fast/`, `encode/high/`, `encode/entropy/`, `decode/fast/`, `decode/high/`, `decode/entropy/` subdirectories. 20 encoder + 7 decoder files moved. Split `streamlz_encoder.zig` 5-way. Not the full 105-file manifest but achieves the clarity goal. |
| `streamlz_constants.zig` split into 8 files | **SKIPPED** — organized with section dividers, 128 lines total. |
| `cli/` subdirectory with per-command files | **SKIPPED** — `main.zig` is 742 lines, manageable. |
| `tests/` directory | **SKIPPED** — Zig test discovery constraint. |

### Additional work done (not in original audit)

| Item | Status |
|------|--------|
| `compressBound` sidecar headroom for L5 | **DONE** |
| `DecompressContext` for persistent thread pool | **DONE** |
| `computeTransitiveDepth` recursive → iterative | **DONE** |
| Remove dead overcopy walker code | **DONE** |
| Cross-platform `totalAvailableMemoryBytes` (Linux/macOS) | **DONE** |
| `-t N` thread count CLI flag for decompress/bench/benchc | **DONE** |
| `src/streamlz.zig` public library API | **DONE** |
| `src/README.md` directory guide | **DONE** |
| Glossary in project README | **DONE** |
| `bh` → `block_hdr` variable rename | **DONE** |
| File renames for clarity (`high_fast_parser` → `high_greedy_parser`, etc.) | **DONE** |
| `error.BailOut` → `?usize` optional return | **DONE** |
| Per-block match_table allocation hoisting | **DONE** |
| `extractLaoFromMls` zero-termination | **DONE** |
| Alignment debug assertions (7 sites) | **DONE** |
| Fixture test `page_allocator` + 256 MB cap | **DONE** |
| `huffman_decoder` → `bit_reader_lite` extraction (shared Golomb-Rice) | **DONE** |
| `tans_decoder` decoupled from `huffman_decoder` | **DONE** |
| `high_encoder` `alignUpPtr` dedup + `encodeLiteralStream` extraction | **DONE** |
| `high_cost_model` `updateStats` switch refactor | **DONE** |
| `copy_helpers` header updated, `alignPointer` is canonical | **DONE** |
| `encode/` subdirectories: `fast/`, `high/`, `entropy/` | **DONE** |
| `decode/` subdirectories: `fast/`, `high/`, `entropy/` | **DONE** |
| `streamlz_encoder.zig` 5-way split (2636→667 lines) | **DONE** |
| `optimal()` backward-extract phase extraction | **DONE** |
| Debug bounds checks for bit_writer (`initBounded` + assert in flush) | **DONE** |
| Parallel decoder contract documentation (7 assertions, module docs) | **DONE** |
| `build.zig`: `zig build safe` (ReleaseSafe) + `zig build fuzz` target | **DONE** |
| Centralize scattered constants (`safe_space`, `sub_chunk_size`, `extended_length_threshold`) | **DONE** |
| CLI arg parsing cleanup (`parseIntFlag` helper, ~48 lines removed) | **DONE** |
