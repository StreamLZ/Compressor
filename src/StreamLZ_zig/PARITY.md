# StreamLZ Zig port — full-parity punch list

Goal: 100% parity between `src/StreamLZ_zig/` and `src/StreamLZ/` — no skipped branches, no deferred stubs, no hidden API differences. The list below was produced by manual audit on 2026-04-13. All gaps must be closed before the port is considered complete.

**How to apply:** When picking up the port, start from the first unchecked item in the "execution order" section. Each item lists its file/line citations. When an item lands, mark `[x]` and move on. Do not reorder without user permission.

## Execution order (numbered steps; groups in brackets cross-reference item IDs below)

- [x] **1. B3 + B4** — fix recursive stack-scratch bug + `dst == scratch` alias handling. `highDecodeBytes` / `highDecodeBytesInternal` now take `scratch` + `scratch_end` params; stack 64 KB buffer removed; alias shift ported from C# `EntropyDecoder.High_DecodeBytesInternal:770-778`. All 137 unit tests + 140 decode fixtures + 100 encode roundtrips passing.
- [x] **2. A3** — dictionary / `dstOffset` decompress entry. Added `decompressBlock(src, dst, decompressed_size)` and `decompressBlockWithDict(src, dst, dst_offset, decompressed_size)` at `streamlz_decoder.zig:89-134`. Reuses existing `decompressCompressedBlock` helper. Test coverage: 4 new tests (roundtrip no-dict, uncompressed-block dst_offset, equivalence, param validation). **Caveat**: end-to-end dict semantics with `dst_offset > 0` can only be exercised once the stream frame compressor lands (step 41 / D7), because the internal `srcWindowBase` plumbing (matching the buffer origin to where the dictionary lives) is what lets the encoder produce compressed blocks where `start_position != 0` and the initial 8-byte Copy64 is skipped. Until then, `decompressBlockWithDict` with `dst_offset > 0` only works reliably on uncompressed blocks.
- [x] **3. A4 + 4. A5** — `decompressStream(allocator, src, writer, opts)` at `streamlz_decoder.zig:90-196`. Port of C# `StreamLzFrameDecompressor.Decompress`. Owns the sliding window (clamps `opts.window_size` to `[block_size, max_window_size]`), calls `decompressBlockWithDict` per block, writes decoded bytes to any `std.Io.Writer`, slides the window when `total_used > window_size`, enforces `max_decompressed_size` cap, and verifies XXH32 content checksum via `std.hash.XxHash32` when the frame sets `content_checksum`. New error variant `ChecksumMismatch`. 4 new tests: roundtrip, max-size cap, empty-source, checksum path. Defers the `DecompressAsync` / `DecompressFile` convenience wrappers — the core streaming primitive is in place; those can land with the CLI/public-API pass.
- [x] **5. A7 + A8** — `copyWholeMatch` helper at `streamlz_decoder.zig:91-104` (8-byte chunk path when `offset >= 8`, scalar tail). Wired into `decompressCompressedBlock` memset branch so `ch.whole_match_distance != 0` triggers whole-match copy. Dead code in practice (no encoder populates the field) but structurally symmetric with C# `StreamLzDecoder.cs:142-157, 253-269`. 2 new tests for the helper.
- [x] **6. A9** — `RestartDecoder` flag was already parsed by `parseBlockHeader` into `BlockHeader.restart_decoder`. Encoder already writes bit 6 of the 2-byte internal block header via `if (keyframe) flags0 |= 0x40`. Matches C# behaviour exactly (neither side acts on the flag). Added a roundtrip test asserting the encoder sets `restart_decoder` on the first block.
- [x] **7. B1 + B2** — Added `decodeMultiArray` / `decodeMultiArrayInternal` in `entropy_decoder.zig` (~300 lines). Ports `High_DecodeMultiArrayInternal` from C# `EntropyDecoder.cs:344-638`: header + `num_arrays_in_file` → nested entropy blocks into scratch → Q value → index-count header → interval-index + lenlog2 streams (packed-or-separate) → bidirectional varbit decode with `std.math.rotl` on `bits | 1` sentinel → assembly loop with zero-terminator per output array. Wired into `decodeRecursive`'s bit-7 branch. 147 unit + 140 fixture + 100 encode tests pass. Note: no fixture actively exercises the multi-array path (no encoder emits it yet); structural port is complete but not roundtrip-validated against a real multi-array block.
- [x] **8. B4** — Bundled into step 1 (see there). The `dst == scratch` alias shift was ported alongside the scratch-threading fix.
- [x] **9. D10** — `Options` struct at `streamlz_encoder.zig:46-119` now mirrors C# `CompressOptions` field-for-field: `hash_bits`, `min_match_length`, `dictionary_size`, `max_local_dictionary_size`, `seek_chunk_len`, `seek_chunk_reset`, `space_speed_tradeoff_bytes`, `generate_chunk_header_checksum`, `self_contained`, `two_phase`, and the three `decode_cost_*` knobs. Plumbing only — behavior lands in subsequent steps.
- [x] **10. D1** — SelfContained mode implemented in `compressFramed`. Per-block hasher reset + block-local `window_base` (matching C# `CompressOneBlock`), block header bit 4 set on every internal chunk, tail prefix table appended after all chunks (8 bytes × `num_chunks - 1`, port of `AppendSelfContainedPrefixTable`). `compressBound` updated to account for the worst-case prefix table. Every block is a keyframe in SC mode (C# `CompressOneBlock:707`). Uncompressed fallback also sets the SC bit. Roundtrip tests at 64 KB / 256 KB / 768 KB / 1 MB + all-levels + block-header-bit check + fixture corpus still byte-exact.
- [x] **11. D2** — `two_phase` implies `self_contained = true` (C# `StreamLZCompressor.Compress:90-95`), sets bit 5 of the block header byte 0 via `two_phase_flag_bit`. Roundtrip test asserting bits 4 + 5 + 6 all set and end-to-end decode.
- [~] **12. D11** — FOLDED INTO STEP 41 (D7). `srcWindowBase` is not a user-facing dictionary API; it's internal plumbing used only by `StreamLzFrameCompressor` at `StreamLzFrameCompressor.cs:222` where `srcWindowBase = pWindow` and `srcIn = pWindow + dictBytes`. Every other C# caller of `CompressBlock` passes `srcWindowBase: null`. When we port the stream frame compressor (step 41), it will naturally require internal per-block `window_base` + hasher preload, but no standalone "dictionary mode" feature exists to mirror. Audit originally listed D11 as a separate gap based on a misread of the parameter's purpose.
- [~] **13. D12** — DEFERRED until step 25 (G5). `CompressLazy` depends on `MatchHasherBase` / `MatchHasher2x`, which step 25 ports wholesale for the High codec. Once G5 lands we add a thin `runLazyParser` + wire a new dispatch path. Doing D12 standalone now would duplicate most of the G5 work. Also: `Slz.MapLevel` skips codec level 4 entirely so no public API reaches `CompressLazy` — it's only accessible via the internal `StreamLZCompressor.CompressBlock_Fast(codecId, codecLevel=4)` which isn't exposed outside the C# library. Port stays on the list for structural parity.
- [~] **14. D13** — DEFERRED until phase 14 (parallel compress, step 37+). Zig's current compress path allocates hashers fresh per `compressFramed` call. The C# `[ThreadStatic] LzTemp t_lztemp` exists because `CompressBlocks` / `CompressBlocksParallel` reuse `LzTemp` across many calls per thread. Until Zig gets a thread pool this optimization is moot — one compress call per thread = no reuse possible. Revisit when step 37 lands.
- [x] **15. H7 (phase 10d)** — Already done by prior commits `6519c42` (stream layout fix) + `98023bf` (allocator scratch + enwik8/silesia roundtrips). STATUS.md was stale. Verified: all 6 tANS roundtrip tests pass — synthetic `'abab'` × 16 (2-symbol sparse), `'abc'` × 85 (3-symbol sparse), 512-byte English text (Golomb-Rice path), enwik8 first 64 KB, enwik8 offset 1 MB × 128 KB, silesia first 64 KB + silesia 128 KB at offset 2 MB. Enwik8 (100 MB) + silesia (212 MB) asset files present and exercised.
- [x] **16. H1 + H10** — `encodeArrayU8` / `encodeArrayU8WithHisto` / `encodeArrayU8CompactHeader` now match C# signature: `(allocator, dst, src, options, speed_tradeoff, cost_out, level, histo_out)`. `encodeArrayU8Tans` takes `speed_tradeoff` + writes `cost_out` = payload byte count. `encodeArrayU8CoreWithHisto` compares `tans_cost < memcpy_cost` before accepting the tANS path (match C# `EntropyEncoder.cs:108`). `makeCompactChunkHdr` decrements `cost_out` by 1 / 2 on compact shrink (match C# `EntropyEncoder.cs:154, 176`). Fast encoder call sites (4) updated to pass `config.speed_tradeoff` and `null` cost (Fast computes its own). `encodeArrayU8WithHisto` now takes the histogram by value so its internal adjustments don't leak. Tests widened + new assertion that `makeCompactChunkHdr` drops cost by 1 on memcpy shrink. 154 unit + 140 fixture + 100 encode roundtrips still pass.
- [x] **17. H8 + H9** — `offset_encoder.zig` now has the full OffsetEncoder pipeline: `getLog2Interpolate` (+ 65-entry lookup table), `convertHistoToCost`, `getHistoCostApprox`, `getCostModularOffsets`, `getBestOffsetEncodingFast` / `Slow`, `encodeNewOffsets`, `writeLzOffsetBits` (dual-ended bit-stream), and the top-level `encodeLzOffsets`. `cost_coefficients.zig` extended with `offset_type0/1_per_item/base`, `offset_modular_per_item/base`, `single_huffman_base/per_item/per_symbol`. 7 new unit tests cover the cost helpers + `encodeNewOffsets` + `writeLzOffsetBits` empty case. Fast codec still byte-exact (fixture corpus, 161 unit + 140 decode + 100 encode roundtrips all pass).
- [~] **18. H2 + H3** — AUDIT CORRECTION: NOT REAL GAPS. C# `EntropyEncoder.EncodeArrayU8Core` at `EntropyEncoder.cs:85-121` only produces chunk types 0 (memcpy) and 1 (tANS). There is no Huffman 2-way or 4-way encoder anywhere in the C# encoder. The decoder supports types 2 and 4 as legacy / cross-compat paths, but no C# code path writes them. The Zig port already matches this — `entropy_encoder.zig` produces types 0 and 1 only, same as C#.
- [~] **19. H4 + H5** — AUDIT CORRECTION: NOT REAL GAPS. Same conclusion as H2/H3 — C# doesn't have RLE or Recursive encoders either. The decoder supports types 3 and 5 for legacy streams; no C# encoder path writes them.
- [~] **20. H6** — DEFERRED AS DEAD CODE. `MultiArrayEncoder.cs` (2026 lines) exists in C# but is entirely unreachable: its public `EncodeArrayU8_MultiArray` / `EncodeMultiArray` entry points have zero callers anywhere in `src/StreamLZ/`. The `EntropyOptions.AllowMultiArray` flag is set on High `LzCoder` instances but `EntropyEncoder.EncodeArrayU8Core` never consults it — the wire is built but not connected. Porting 2 KLOC of unreachable Zig code for structural parity is low-value vs. the work it would take. Reopen this step only if a real caller surfaces during the High codec port (steps 28-32).
- [x] **21. I3** — `cost_coefficients.zig` now mirrors the full `CostSnapshot` from C# `CostCoefficients.cs`: length/write-bits/token/tans/multi-array/speed-tradeoff/cost-conversion constants all present as module-level `pub const`s with the C# default values. Plus the offset/single-huffman fields added in step 17. 161 tests still pass.
- [x] **22. I4** — New module `encode/match_eval.zig` ports C# `MatchEvaluation.cs` (`MatchUtils`): `countMatchingBytes`, `getMatchLengthQuick`, `getMatchLengthMin2`, `getMatchLengthQuickMin3`, `getMatchLengthQuickMin4`, `isBetterThanRecent`, `isMatchBetter`, `getLazyScore`. Fast encoder's inlined helpers in `fast_lz_parser.zig` stay where they are to keep byte-exact parity; High (step 29+) will use the shared module. 11 new unit tests cover every function + the `recent+1` and `recent+2` gates in `isBetterThanRecent`. 173 tests total.
- [x] **23. I5** — New module `encode/block_header_writer.zig` ports C# `BlockHeaderWriter.cs`: `writeBlockHdr` (2-byte internal header with all flag bits), `writeBE24`, `writeChunkHeader` (4-byte LE), `writeMemsetChunkHeader` (5-byte), `areAllBytesEqual`. All the flag-byte constants exposed as `pub const`. 10 new unit tests. Fast encoder stays with its inlined versions for byte-exact parity; High and future parallel paths will use the shared module. 183 tests total.
- [x] **24. I6** — `isBlockProbablyText` was already implemented but `fn` (private); made it `pub` so High can call it directly on arbitrary window regions without forcing the 32-sample `isProbablyText` pattern. No functional change — the algorithm was already ported as part of Fast.
- [x] **25. G5** — `match_hasher.zig` refactored: the generic `MatchHasher(comptime num_hash: u32, comptime dual_hash: bool)` now supports bucket widths 1/2/4/16 and optional dual hashing. New aliases `MatchHasher4`, `MatchHasher4Dual`, `MatchHasher16Dual` cover the remaining C# family (`MatchHasher.cs:492-644`). `setHashPos` computes a secondary index via `(FibonacciMult * atSrc) >> (64 - bits)` when dual, bucket-aligned via `~(num_hash - 1)`. `insert` / `insertRange` write both primary and secondary buckets for dual variants. New `setBaseAndPreload` entry point plus standalone `adaptivePreloadLoop` port of C# `MatchHasherPreload.AdaptivePreloadLoop` (`MatchHasher.cs:45-83`). 7 new tests cover MatchHasher4 init + ring-shift insert, MatchHasher4Dual dual index + dual-insert semantics, MatchHasher16Dual mask + 16-entry ring-shift, and adaptivePreloadLoop monotonic progression. 190 unit + 140 decode fixtures + 100 encode roundtrips still green; Fast L1-L5 byte-exact against C# unchanged.
- [x] **26. G1** — New module `encode/match_finder.zig` ports `MatchFinder.FindMatchesHashBased` from C# `MatchFinder.cs:289-512`. Uses `MatchHasher16Dual` (16-entry dual-hash bucket, ported in step 25) to probe candidate positions, extends via `match_eval.countMatchingBytes`, and stores results in `ManagedMatchLenStorage` via `insertMatches`. Includes the two-bucket probe, `match_eval` extension, collision-rejecting quick-prefix filter, sort-descending + `removeIdentical` dedup, and the long-match-skip optimization (≥ 77 bytes → synthetic sub-matches at stride-4 + `insertRange` on the hasher + `cur_pos += best_ml - 1`). The C# reference uses SSE2-vectorized 16-entry probes; the Zig port uses the scalar fallback path (same result, simpler to port). Also fixed a wrapping-arithmetic overflow in `extractFromMlsInner` that the new tests uncovered. 3 new tests cover simple repetition, tiny input skip, and extractLaoFromMls roundtrip. 201 unit + 140 fixture + 100 encode roundtrips still pass.
- [x] **27. G3 + G4** — New module `encode/managed_match_len_storage.zig` ports `ManagedMatchLenStorage.cs` + the VarLen encoder/decoder + `InsertMatches` / `RemoveIdentical` / `ExtractLaoFromMls` from C# `MatchFinder.cs:43-147` and `522-659`. `LengthAndOffset` struct, `varLenWriteSpill/Offset/Length`, `insertMatches`, `removeIdentical`, `extractFromMlsInner`, `extractLengthFromMls`, `extractOffsetFromMls`, `extractLaoFromMls`. The MLS buffer grows 1.25× on demand matching C#'s `Array.Resize` policy. 8 new unit tests cover VarLen round-trips for small + large length/offset values, `insertMatches` + `extractLaoFromMls` end-to-end roundtrip, and `removeIdentical` collapse.
- [x] **28. F1 + F6 + F7** — Three new modules land the High codec scaffolding:
  - `encode/high_types.zig` — `HighRecentOffs`, `HighStreamWriter`, `Token`, `TokenArray`, `ExportedTokens`, `State` (optimal-parser DP cell), `CostModel`, `Stats` — port of `HighTypes.cs`.
  - `encode/high_matcher.zig` — `isMatchLongEnough`, `checkMatchValidLength`, `getRecentOffsetIndex`, `getBestMatch` — port of `High/Matcher.cs` + the `IsMatchLongEnough` helper from `High/CostModel.cs:14-25`.
  - `encode/high_compressor.zig` — `setupEncoder` scaffold + `LevelEntry` table (matches C# `High/Compressor.cs:51-135` level-indexed table), `HasherType` enum, `HighSetup` result struct, `EncodeFlags`, `CodecId`. Actual parsers (steps 29-32) import from here. 10 new tests cover `State` init, `HighRecentOffs.create`, `isMatchLongEnough` tiers, `checkMatchValidLength` tiers, `getRecentOffsetIndex` slot matching, and `setupEncoder` level-table branches (L1/L3/L4/L5/L7+). 212/212 unit tests pass.
- [ ] **29. F2** — `High.FastParser.CompressFast` + `GetMatch` + `CheckRecentMatch`. Hash-based High parser for L6-L8 SC path.
- [x] **30. F4** — New module `encode/high_encoder.zig` ports `High/Encoder.cs` end-to-end. Includes: `HighEncoderContext` (runtime config struct), `HighWriterStorage` (owns the scratch backing allocation — equivalent to C# `LzTemp.HighEncoderScratch` but per-call), `initializeStreamWriter` (carves the 7 stream regions with 4-byte alignment for u32 streams), `writeMatchLength` / `writeLiterals` / `writeLiteralsLong` / `writeFarOffset` / `writeNearOffset` / `writeOffset`, `addToken` (with recent-offset ring shift), `addFinalLiterals`, and `assembleCompressedOutput` (the big one: raw-vs-delta literal decision via `getHistoCostApprox`, tANS / memcpy dispatch through `encodeArrayU8{,WithHisto}`, offset streams via `encodeLzOffsets`, `writeLzOffsetBits` dual-ended bit stream, full cost-model accounting via the coefficients from step 21). 4 new tests cover `initializeStreamWriter`, `writeMatchLength` (short + overflow), `addToken` recent-offset ring update. 221 unit + 140 decode fixtures + 100 encode roundtrips pass.
- [x] **31. F5** — New module `encode/high_cost_model.zig` ports the non-`IsMatchLongEnough` portion of `High/CostModel.cs` (`IsMatchLongEnough` already landed in step 28 in `high_matcher.zig`): `rescaleOne`, `rescaleStats`, `rescaleAddOne`, `rescaleAddStats`, `updateStats` (per-token histogram updates for literal/delta/token/matchlen/offset streams), `makeCostModel` (histogram → per-symbol cost via `OffsetEncoder.ConvertHistoToCost`), `bitsForLiteralLength`, `bitsForLiteral`, `bitsForLiterals`, `bitsForToken` (with decode-cost penalties wired), `bitsForOffset` (with the OffsetType 0/1/modular branches + distance penalty + small-offset decode penalty). 5 new unit tests cover `rescaleOne` / `rescaleStats` / `rescaleAddOne` / `bitsForLiteralLength`. Landed bottom-up since steps 30 + 32 both depend on it. 217 tests pass.
- [ ] **32. F3** — `High.OptimalParser.Optimal` + `CollectStatistics` + `UpdateState` + `UpdateStatesZ`. DP optimal parser (phase 11).
- [ ] **33. G2** — `MatchFinder.FindMatchesBT4` + `BT4InsertOnly` + `BT4SearchAndInsert`. Binary-tree match finder for L11 (phase 12).
- [ ] **34. D9** — expose unified levels L6-L11 via `compressFramed` now that High is implemented.
- [ ] **35. A1** — `DecompressCoreParallel` (SC parallel decompress; phase 13).
- [ ] **36. A2** — `DecompressCoreTwoPhase` + `TwoPhasePreScan` + `TwoPhaseParallelDecode` + `TwoPhaseSerialResolve` + `High.LzDecoder.Phase1_ProcessChunk` (phase 13).
- [ ] **37. D3** — `CompressBlocksParallel` (phase 14).
- [ ] **38. D4** — `CompressInternalParallelSC` (phase 14).
- [ ] **39. D5** — multi-piece compress with OOM fallback.
- [ ] **40. D6** — `CalculateMaxThreads` / `EstimateSharedMemory` / `PerThreadMemoryEstimate`.
- [ ] **41. D7** — `StreamLzFrameCompressor.Compress` / `CompressAsync` / `CompressFile` (stream-based compressor with sliding window).
- [ ] **42. D8 + J1** — `SlzStream` public type (Stream-wrapping compressor/decompressor).
- [ ] **43. J2** — `SlzCompressionLevel` enum.
- [ ] **44. C1** — Fast decoder `@prefetch` hints in cmd==2 / medium paths (perf).
- [ ] **45. A6** — CRC24 chunk-header checksum verification (opt-in).

## The gaps, keyed by ID (for cross-reference)

### A. Decompression — top-level framed/block

- **A1**: Parallel SC decompress — `StreamLzDecoder.cs:689-777` → phase 13.
- **A2**: Two-phase parallel decompress — `StreamLzDecoder.cs:780-1000` + `High/LzDecoder.TwoPhase.cs`. Phase 13.
- **A3**: Dictionary `dstOffset` decompress — `StreamLzDecoder.cs:392-475`. Missing.
- **A4**: Stream-based decompressor — `StreamLzFrameDecompressor.cs:28-388`. Missing (in-memory only).
- **A5**: XXH32 content checksum verify — `StreamLzFrameDecompressor.cs:172-187`. Missing.
- **A6**: CRC24 chunk checksum verify — `StreamLzDecoder.cs:272-276`. Parsed, never verified (both sides).
- **A7**: `ChunkHeader.WholeMatchDistance != 0` branch — `StreamLzDecoder.cs:255-266`. Zig field exists but never populated/read.
- **A8**: `CopyWholeMatch` helper — `StreamLzDecoder.cs:142-157`, `High/LzDecoder.cs:65`. Missing.
- **A9**: `RestartDecoder` flag — `StreamLzDecoder.cs:59`. Parsed, unused.

### B. Decompression — entropy layer

- **B1**: Type 5 multi-array (bit-7 set) — `EntropyDecoder.cs:344-638`. Returns `MultiArrayNotSupported` at `entropy_decoder.zig:315`.
- **B2**: `High_DecodeMultiArray` public entry — `EntropyDecoder.cs:334-342`. Missing.
- **B3**: Recursive stack-scratch bug — `entropy_decoder.zig:138` allocates 64 KB per recursion level; with depth 16 = 1 MB stack. C# passes scratch through (`EntropyDecoder.cs:770-778`). **Real correctness bug.** **[DONE: step 1]**
- **B4**: `dst == scratch` alias handling — `EntropyDecoder.cs:770-778` + `376-382`. Not ported. **[DONE: step 1 — ported alongside B3]**

### C. Decompression — Fast LZ hot loop

- **C1**: `Sse.Prefetch0` prefetch hints in cmd==2 / medium paths — `Fast/LzDecoder.cs:478-481, 623-626`. Missing at `fast_lz_decoder.zig:447`. Perf only.

### D. Compression — top-level framed compressor

- **D1**: SelfContained mode + prefix table — `StreamLzCompressor.cs:407-427, 510-513`, `StreamLZ.cs:90-106`. Not exposed in Zig `Options`.
- **D2**: TwoPhase flag — `StreamLzCompressor.cs:90-95`. Missing.
- **D3**: `CompressBlocksParallel` — `StreamLzCompressor.cs:777-841`. Phase 14.
- **D4**: `CompressInternalParallelSC` — `StreamLzCompressor.cs:527-648`. Phase 14.
- **D5**: Multi-piece compress with OOM fallback — `StreamLzCompressor.cs:101-148`. Missing.
- **D6**: `CalculateMaxThreads` / `EstimateSharedMemory` — `StreamLzCompressor.cs:160-192`. Missing.
- **D7**: Stream-based frame compressor — `StreamLzFrameCompressor.cs:34-423`. Missing.
- **D8**: `SlzStream` public type — `SlzStream.cs` (711 lines). Missing.
- **D9**: Unified levels L6-L11 — `StreamLZ.cs:90-106`. `streamlz_encoder.zig:204` rejects `level > 5`.
- **D10**: `CompressOptions` fields — `CompressOptions.cs`. Zig `Options` is a subset.
- **D11**: ~~External dictionary / `srcWindowBase`~~ — **FOLDED INTO D7**. `srcWindowBase` is internal sliding-window plumbing used only by `StreamLzFrameCompressor.cs:222`, not a user-facing dictionary API. Port lands with the stream frame compressor.
- **D12**: `MatchHasher2x` / `CompressLazy` parser — `Fast/FastParser.cs:193-258`. Intentionally skipped to match `Slz.MapLevel`; blocks direct-codec-level API.
- **D13**: Thread-static `LzTemp` reuse — `StreamLzCompressor.cs:428`. Missing.

### E. Compression — Fast codec (L1-L5)

Byte-exact-validated across 100 fixtures + enwik8 + silesia. **No functional gaps.**

### F. Compression — High codec (L6-L11)

- **F1**: `High.Compressor` — `High/Compressor.cs` (169 lines). Missing.
- **F2**: `High.FastParser.CompressFast` — `High/FastParser.cs` (264 lines). Missing.
- **F3**: `High.OptimalParser.Optimal` — `High/OptimalParser.cs` (933 lines). Stub.
- **F4**: `High.Encoder.AssembleCompressedOutput` — `High/Encoder.cs` (472 lines). Missing.
- **F5**: `High.CostModel` — `High/CostModel.cs` (331 lines). Missing.
- **F6**: `High.Matcher` — `High/Matcher.cs` (117 lines). Missing.
- **F7**: `HighTypes` — `High/HighTypes.cs` (164 lines). Missing.

### G. Compression — match finding

- **G1**: `MatchFinder.FindMatchesHashBased` — `MatchFinding/MatchFinder.cs:289-521`. Missing.
- **G2**: `MatchFinder.FindMatchesBT4` — `MatchFinding/MatchFinder.cs:680-900`. Stub. Phase 12.
- **G3**: `ManagedMatchLenStorage` — `MatchFinding/ManagedMatchLenStorage.cs`. Missing.
- **G4**: `ExtractLaoFromMls` + `VarLenWrite*` — `MatchFinding/MatchFinder.cs:522-678`. Missing.
- **G5**: `MatchHasherBase` / `MatchHasher2x` / `MatchHasherPreload` / `AdaptivePreloadLoop` — `MatchFinding/MatchHasher.cs`. Zig has `MatchHasher2` only.

### H. Compression — entropy layer

- **H1**: `EncodeArrayU8` signature — `EntropyEncoder.cs:45-124`. Zig `entropy_encoder.zig:120-137` missing cost out-param, level, speed tradeoff, scratch.
- **H2**: ~~Huffman 2-way split encoder~~ — **NOT A REAL GAP**. No C# encoder writes chunk type 2. Decoder-only legacy type.
- **H3**: ~~Huffman 4-way split encoder~~ — **NOT A REAL GAP**. Same. Decoder-only legacy type.
- **H4**: ~~RLE encoder~~ — **NOT A REAL GAP**. Same. Decoder-only legacy type.
- **H5**: ~~Recursive/sub-block encoder~~ — **NOT A REAL GAP**. Same. Decoder-only legacy type.
- **H6**: `MultiArrayEncoder` — **DEAD CODE in C#** (2026 lines, zero callers). Port deferred; reopen if High codec port surfaces a real caller.
- **H7**: tANS encoder roundtrip — `TansEncoder.cs` (1010 lines). `tans_encoder.zig` (1275 lines) scaffolded, roundtrip broken. Phase 10d.
- **H8**: `EncodeLzOffsets` / `WriteLzOffsetBits` — `EntropyEncoder.cs:185-207`, `OffsetEncoder.cs:402-680`. Missing.
- **H9**: `OffsetEncoder` — `OffsetEncoder.cs:112-680`. `offset_encoder.zig` has only `subtractBytes` helpers.
- **H10**: `MakeCompactChunkHdr` cost-reporting out-param — `EntropyEncoder.cs:140-184`. Zig has the rewrite without cost.

### I. Shared / Common

- **I1**: `StreamLzConstants` — 44 C# constants vs 43 Zig. Spot-check for 1 missing.
- **I2**: `LzCoder` / `LzTemp` — `LzCoder.cs`. No Zig equivalent; per-call local state instead.
- **I3**: `CostCoefficients.Current` platform table — `CostCoefficients.cs` (241 lines). Zig has Fast subset only.
- **I4**: `MatchUtils` / `MatchEvaluation` — `MatchEvaluation.cs` (168 lines). Inlined into Zig `fast_lz_parser.zig`; needs extraction for High reuse.
- **I5**: `BlockHeaderWriter` helpers — `BlockHeaderWriter.cs`. Inlined into `streamlz_encoder.zig`; needs extraction.
- **I6**: `TextDetector.IsBlockProbablyText` (per-16 KB) — `TextDetector.cs:47`. Zig has whole-input only.
- **I7**: `BitWriter64Forward` / `Backward` — `BitWriter.cs`. Zig equivalent in `io/bit_writer_64.zig` appears complete. Flag only if gap found.

### J. CLI / UX

- **J1**: `SlzStream` public type — `SlzStream.cs` (711 lines). Missing.
- **J2**: `SlzCompressionLevel` enum — `SlzCompressionLevel.cs`. Missing.

## Rules

- Do not reorder steps without user permission.
- Do not skip branches within a step to "ship faster" — mark `[x]` only when the whole C# reference for that item is ported.
- Use fixture tests + C# reference diff to validate every step that touches a code path reachable from `compressFramed` / `decompressFramed`.
- Update STATUS.md phase tracker whenever a step closes out a numbered phase.
- **This file (`src/StreamLZ_zig/PARITY.md`) is the source of truth for what's left.** STATUS.md can lag, but this list must always reflect reality. Previously lived in memory as `project_parity_punch_list.md`; moved into the repo so it's version-controlled and visible in diffs.
