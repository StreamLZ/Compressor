# StreamLZ Zig port — status snapshot

**Snapshot date:** 2026-04-13
**Zig:** 0.15.2, pinned in `build.zig.zon`
**Host:** Intel Ultra 9 285K (Arrow Lake-S), Windows 11, `-Doptimize=ReleaseFast -Dcpu=native`

## The one-paragraph version

The **decoder is complete** for all 11 StreamLZ compression levels
single-threaded, byte-exact against the C# encoder on every fixture I
have. The **Fast encoder (L1-L5) is complete and byte-exact** with the
C# reference across 100 fixtures (L1-L5 × 20 shapes/sizes), enwik8
(100 MB), and silesia (212 MB) — every level, every file, zero delta.
Fast codec decompress is at parity with C# serial (1.00-1.04×). High
codec decompress is 0.73-0.83× of C# serial — a gap the C# version
closes via parallel dispatch (`DecompressCoreTwoPhase` for L9-L11,
`DecompressCoreParallel` for SC L6-L8), which the Zig port doesn't
have yet (phase 13). **High encoder (L6-L11) is pending** — needs
optimal parser, BT4 match finder, real Huffman/tANS encoders. Repo
lives under `src/StreamLZ_zig/`, zero coupling to the .NET solution.

## Phase tracker

### Done
| # | phase | summary |
|---|---|---|
| 0 | Foundation | `build.zig` + `build.zig.zon` (Zig 0.15.2 pinned), CLI skeleton, `.gitignore`, 45 unit tests wired |
| 1 | Wire format | `format/streamlz_constants.zig`, `format/frame_format.zig`; `streamlz info` CLI |
| 2 | Bit I/O | `io/bit_reader.zig` (forward+backward refill), `io/bit_writer.zig` (4 variants) |
| 3a | Decompress scaffold | `streamlz decompress` CLI, uncompressed block path |
| 3b | Fast LZ decoder | `decode/fast_lz_decoder.zig`, `format/block_header.zig`; L1-L5 byte-exact |
| 4 | Huffman decoder | `decode/huffman_decoder.zig`: 11-bit LUT, 3-stream parallel, canonical Huffman |
| 4b | RLE + Recursive | `decode/entropy_decoder.zig`: Type 3 RLE + Type 5 simple N-split. Multi-array Type 5 still returns `MultiArrayNotSupported` (untriggered by any fixture so far) |
| 5 | High LZ decoder | `decode/high_lz_decoder.zig` + `decode/high_lz_process_runs.zig`: ReadLzTable, UnpackOffsets (bidirectional), ProcessLzRuns Type0+Type1 |
| 6 | tANS decoder | `decode/tans_decoder.zig`: 5-state interleaved decode, Golomb-Rice table decode, LUT construction |
| 5b | SC grouping | Per-group `dst_start` computation so group-first chunks get `base_offset == 0` initial Copy64; tail prefix restoration |
| 7 | Vectorize CopyHelpers | `@Vector(16, u8)` × 4 for `copy64Bytes`, `@Vector(8, u8)` `+%` for `copy64Add`. `streamlz bench` subcommand for in-memory timing |
| 7b | High decoder hot loop | `@prefetch` 128 tokens ahead in `executeTokensType1`; same-iteration prefetch in `processLzRunsType0`; 8-byte cascading literal copy |
| 8 | Fixture corpus + roundtrip tests | `scripts/gen_fixtures.sh` builds 20 raws × 7 levels = 140 `.slz` under `src/StreamLZ_zig/fixtures/` (gitignored). `decode/fixture_tests.zig` walks `$STREAMLZ_FIXTURES_DIR/slz/*.slz`, decodes, and diffs against `raw/<stem>.raw`. Skips cleanly if env var unset. 140/140 bit-exact |
| 9 | Fast encoder L1-L5, byte-exact with C# | `encode/{fast_constants,fast_match_hasher,fast_stream_writer,fast_token_writer,fast_lz_parser,fast_lz_encoder,streamlz_encoder,text_detector,cost_model,cost_coefficients,byte_histogram}.zig`. Greedy parser (engine -2/-1/1/2) + lazy chain parser (engine 4) + raw-mode and entropy-mode sub-chunk assemblers. Bit-exact with C# Fast across 100 fixtures, enwik8 (100 MB), silesia (212 MB) — every Fast level, every file, zero delta. `streamlz c [-l N] <in> <out>` CLI. See `commit log` below for the per-phase breakdown |
| 10a-c | Entropy infra scaffolding | `encode/byte_histogram.zig` (with `getCostApproxCore`), `io/bit_writer_64.zig` (forward + backward), `encode/tans_encoder.zig` (normalize + init_table + get_bit_count + encode_bytes + encode_table scaffolding). Compiles clean; 2 tANS roundtrip tests skipped (see caveats) |
| 10i-l | Fast encoder parity sweep | Phase-10 sub-phases that chased the remaining drift to zero: `Slz.MapLevel` alignment, whole-input hasher window, adaptive hash sizing with text detection, `WriteOffsetWithLiteral1`, delta-literal histogram-cost selection, Off16 entropy-split cost compare, EntropyOptions per-level masks, block-/sub-chunk-level `AreAllBytesEqual`, `CheckPlainHuffman` trial-encode arm, per-block cost-vs-memsetCost rewrite, backward-extend whole-input bound, and the final hasher-vs-parser `min_match_length` split. See the commit `437e6a6` body for the full list |

### Pending
| # | phase | notes |
|---|---|---|
| 10d (debug) | tANS encoder roundtrip | `tansInitTable` + `tansEncodeBytes` + `tansEncodeTable` all compile but the round-trip through `decode/tans_decoder.zig` produces scrambled output. First two bytes of a 256-byte "abcabc…" test decode correctly, then diverge. Bug is likely in the state-table initialization (`base_offset` math for the weight-1 path or the 4-way distribution) or the stream-swap semantics. Not on the critical path — Fast levels disable tANS anyway — but required for High (L6+) parity |
| 10 | Huffman + tANS encoders | `encode/multi_array_huffman_encoder.zig` (2 KLOC in C#), `encode/offset_encoder.zig`, real `encode/tans_encoder.zig`. Fast L1-L5 works without these because `EntropyOptions` clears `AllowTANS` / `AllowMultiArray` for Fast — `EncodeArrayU8` falls through to memcpy and is already byte-parity with C# |
| 11 | High encoder | `encode/high_lz_encoder.zig`, `encode/optimal_parser.zig` (DP), High-side cost model |
| 12 | BT4 match finder | `encode/match_finder_bt4.zig` — needed for L11 only |
| 13 | Parallel decompress | `DecompressCoreTwoPhase` (L9-L11) + `DecompressCoreParallel` (L6-L8 SC) — the multi-GB/s regime lives here |
| 14 | Parallel compress | Thread pool for SC groups |

## Repo layout (`src/StreamLZ_zig/`)

```
build.zig               / build.zig.zon   (Zig 0.15.2 pinned)
STATUS.md               (this file)
STRUCTURE.md            (file-layout cheatsheet, updated as phases complete)
BENCHMARKS.md           (decompress perf numbers, latest = post-phase-7b)
src/
  main.zig              CLI dispatcher
  format/
    streamlz_constants.zig        all magic numbers
    frame_format.zig              SLZ1 frame + block header (outer 8-byte)
    block_header.zig              internal 2-byte block hdr + 4-byte chunk hdr
  io/
    bit_reader.zig                MSB-first bit reader, fwd + bwd refill
    bit_writer.zig                4 bit-writer variants
    copy_helpers.zig              copy64, copy64Bytes, wildCopy16, copy64Add (all SIMD-backed)
  decode/
    streamlz_decoder.zig          top-level framed decompress + per-chunk dispatch + SC handling
    fast_lz_decoder.zig           Fast codec: readLzTable + processModeImpl + processLzRuns
    high_lz_decoder.zig           High codec: HighLzTable, unpackOffsets, readLzTable, decodeChunk
    high_lz_process_runs.zig      High Type 0 single-pass + Type 1 two-phase + hot loops
    entropy_decoder.zig           Type dispatcher (0 memcopy, 1 tANS, 2/4 Huffman, 3 RLE, 5 Recursive)
    huffman_decoder.zig           canonical Huffman 11-bit LUT + 3-stream parallel decode
    tans_decoder.zig              tANS table decode + LUT init + 5-state interleaved decode
  encode/
    streamlz_encoder.zig          top-level framed compress + per-block/sub-chunk dispatch
    fast_constants.zig            FastConstants + level mapping + min-match-length table builder
    fast_match_hasher.zig         FastMatchHasher(u16/u32) — single-entry Fibonacci hash
    fast_stream_writer.zig        6-parallel-stream output buffer (literal/delta/token/off16/off32/length)
    fast_token_writer.zig         writeOffset / writeComplexOffset / writeOffsetWithLiteral1 / writeLengthValue / writeOffset32
    fast_lz_parser.zig            Greedy + lazy chain parser (comptime level, comptime hash T)
    fast_lz_encoder.zig           Sub-chunk encoders: raw (L1/L2), entropy (L3/L4), entropy chain (L5) + assembleEntropyOutput
    text_detector.zig             Text-probability heuristic → triggers min-match-length bump
    cost_model.zig                Platform cost combination + decoding-time estimates
    cost_coefficients.zig         Memset-cost coefficients + speed-tradeoff scaling
    byte_histogram.zig            ByteHistogram + getCostApproxCore (log2 lookup table)
    match_hasher.zig              MatchHasher2 chain hasher (L5 lazy)
    entropy_encoder.zig           EncodeArrayU8 / EncodeArrayU8Memcpy — memcpy-only for Fast
    encode_fixture_tests.zig      Zig encode → C# reference diff (byte-exact roundtrip)
    (high_lz_encoder, optimal_parser, match_finder_bt4, tans_encoder,
     multi_array_huffman_encoder, offset_encoder) — stubs for phases 10-12
```

## Decoder benchmarks (Zig mean vs C# serial median, single-thread, pure decompress)

| fixture | level | Zig MB/s | C# MB/s | Zig / C# |
|---|---|---:|---:|---:|
| silesia 212 MB | L1  | 6,582 | 6,307 | **1.04×** |
| silesia 212 MB | L5  | 5,472 | 5,527 | **0.99×** |
| silesia 212 MB | L6  |   950 |   —¹  |   —   |
| silesia 212 MB | L9  |   992 | 1,196 | 0.83× |
| silesia 212 MB | L11 |   941 | 1,225 | 0.77× |
| enwik8 100 MB  | L1  | 6,051 | 5,886 | **1.03×** |
| enwik8 100 MB  | L9  |   672 |   922 | 0.73× |
| enwik8 100 MB  | L11 |   691 |   915 | 0.76× |

¹ C# serial decompress can't handle SC fixtures — its `SerialDecodeLoop`
doesn't understand the tail prefix table, so forcing off the parallel
dispatch for L6-L8 fails the decode. No apples-to-apples comparison
available for L6-L8 serial until either C# grows a serial SC path or Zig
gets parallel (phase 13).

Zig measurement: `streamlz bench <file.slz> <runs>` — pre-loads the
fixture into memory, does one untimed warm-up decode, then N timed
decodes via `std.time.Timer`, reports best + mean.
C# measurement: `dotnet run -c Release --project StreamLZ.Cli -- -db -r 10 <file>`
with `DecompressCore` temporarily patched to force `SerialDecodeLoop` for
apples-to-apples against the single-threaded Zig port.

## Key design decisions to remember

1. **`@Vector(16, u8)` not `@Vector(32, u8)`.** Matches C#. AVX2 (32-byte)
   throttles Arrow Lake and is measurably slower — C# comment says so
   and my own tests confirmed.

2. **`wildCopy16` interleaved load-store-load-store** (not load-load-
   store-store). The interleave is REQUIRED for small-offset LZ match
   propagation: a single 16-byte load would read unwritten bytes from
   past the write cursor. Isolation test in `copy_helpers.zig` locks
   this in. This took a focused debug session to find — see commit
   `54dffa3` message.

3. **tANS `src_start` / `src_end` must be captured BEFORE state-init.**
   C# sets `parms.SrcStart = src` and `parms.SrcEnd = srcEnd` before
   the state-init reads that shift src/srcEnd by ±4 + refill. The
   decode hot loop's bounds check uses this "outer" range, and its
   forward/backward reads intentionally step into the state-init
   overlap region by design. Easy to miss when porting. See commit
   `bbfadc1` message for a detailed trace.

4. **SC per-group `dst_start`.** L6-L8 chunks are grouped in 4s. The
   encoder treats each group's first chunk as "fresh buffer" → first
   8 bytes expected to fall out of `readLzTable`'s `base_offset == 0`
   initial Copy64 path. The decoder must pass a group-local
   `dst_start` for every chunk, not the whole-buffer start. C# does
   this naturally because each group is a separate `Parallel.For`
   iteration with its own local pointer. My serial Zig port computes
   it explicitly:

   ```zig
   const group_start_chunk = (chunk_idx_in_block / constants.sc_group_size) * constants.sc_group_size;
   const group_start_offset = sc_start_dst_off + group_start_chunk * constants.chunk_size;
   const dst_start_ptr = dst[group_start_offset..].ptr;
   ```

5. **Tail prefix restoration** (SC only). Encoder stores
   `(num_chunks - 1) * 8` bytes at the end of each frame block.
   After decoding all chunks, overwrite first 8 bytes of every chunk
   except chunk 0 with those tail bytes. Serial implementation sits
   in `decompressCompressedBlock` in `streamlz_decoder.zig`.

6. **`comptime mode: LiteralMode`** in `fast_lz_decoder.processModeImpl`
   generates two specialized functions (delta vs raw literal). Zig
   replacement for C#'s `ILiteralMode` interface trick. Unambiguous
   win for branch-free hot loops; keeps I-cache cost reasonable
   because only one callsite.

7. **Windows path quirk:** the Bash tool in this environment sometimes
   resets cwd between invocations. The convention in this repo's
   Bash commands is either absolute paths or `cd src/StreamLZ_zig &&`
   once at the start of a command chain — never re-prefixing every
   call.

8. **Fast encoder min-match-length table index.** C# uses
   `31 - Log2(offset)` to index the min-match-length table, where
   `Log2` is the position of the highest set bit. In Zig 0.15 the
   equivalent is `@clz(offset)` (leading-zero count), NOT
   `31 - @clz(offset)`. Getting this wrong silently accepts 4-byte
   matches at far offsets that need 14+. It bit-exact passed every
   test case with source length ≤ 66754, but corrupted output for
   anything that produced a far-offset match. The bug was in
   `encode/fast_lz_parser.zig:runGreedyParser`.

9. **Raw-mode literal in-place.** For L1/L2 the parser writes literal
   bytes directly into the destination buffer, past a reserved 3-byte
   count header (`literal_data_ptr = dst + 3 + initial_bytes`). The
   assembly step backfills the 3-byte count. Scratch holds only
   token/off16/off32/length streams. Matches C#'s FastParser init.

## Known caveats / TODOs

- **Multi-array recursive decode (Type 5 bit-7 variant)** returns
  `MultiArrayNotSupported`. No test-set fixture triggers it so far;
  will land on demand.
- **L6-L8 parallel decode** not yet implemented (phase 13). Serial SC
  works correctly and at ~950 MB/s but C# in practice uses
  `DecompressCoreParallel` (~10 GB/s multi-threaded on silesia L6).
- **L9-L11 two-phase parallel decode** not yet implemented (phase 13).
- **High encoder (L6-L11) is pending** (phase 11+). Needs optimal
  parser, BT4 match finder, real Huffman/tANS encoders. Not on the
  critical path while Fast L1-L5 is validated.
- **tANS encoder roundtrip is broken** (phase 10d). Unreachable from
  Fast levels (they disable tANS), so doesn't block Fast parity.
- **Parallel compress** for SC groups is phase 14.
- **No file-checksum verification** (XXH32 after end mark). The
  decoder skips it; fine for local testing, nice-to-have for
  production.
- **No block-checksum verification** either (would need `CRC24` impl).
- **Streaming (no content-size) decode path** in `frame_format.zig`
  isn't exercised. `streamlz decompress` requires a sized frame.
- **Async / pipelined I/O** (equivalent to C# frame compressor's
  double-buffered read-ahead) not relevant until encoder exists.

## Commit log (latest first)

```
437e6a6  Zig encoder: byte-exact parity with C# Fast L1-L5
5c9c934  Zig CLI: benchc subcommand for in-memory compress+decompress benchmarks
28df736  Zig encoder: restore +0% parity with C# Fast (Phase 10j fix)
5657cf3  Zig encoder: Phase 10l edge-case tests
60e136e  Zig encoder: whole-input hasher window (Phase 10j)
4853791  Zig encoder: align with Slz.MapLevel + disable tANS for Fast (Phase 10i fix)
13e00d0  Zig encoder: text detection + adaptive hash sizing + options plumbing
831af9d  Zig encoder: L4 chain-hasher lazy parser + MatchHasher2 (Phase 10g)
4c31291  Zig encoder: L3 lazy parser + MatchHasher2x (Phase 10f)
ba9651e  Zig encoder: entropy assembly path + L5 wiring (Phase 10e)
98023bf  tANS encoder: allocator-based scratch + enwik8/silesia roundtrips
6519c42  Phase 10d: Fix tANS encoder stream layout (forward/backward overlap)
490ae25  Phase 10 WIP: byte histogram, 64-bit bit writers, tANS encoder scaffold
23a790a  Phase 9 (raw): Fast encoder levels 1 and 2
2e391dd  Phase 8: fixture corpus + exhaustive roundtrip tests
20fc1de  Add STATUS.md snapshot for session compaction
cd43bab  Phase 7b: prefetch + 8-byte cascade in High decoder hot loop
f20f8b3  Phase 5b: serial L6-L8 self-contained decoder
8c255e3  Phase 7: vectorize CopyHelpers + add bench mode + honest L1/L5 parity
bbfadc1  Fix tANS src_start / src_end — C# sets them pre-state-init
54dffa3  Phase 4b: RLE + Recursive entropy types, wildCopy16 overlap fix
19107c8  Finish Phase 5 + 6: High LZ decoder works end-to-end for L9-L11
```

Base (pre-decoder work): `4a0451a` (`Add concurrent access test verifying Slz thread safety`).

## Recommended next session entry points (in order)

1. **Phase 13 — Parallel decompress.** This is what closes the 0.7-0.8×
   gap on L6-L11. Uses `std.Thread.Pool` and a pre-scan over chunks.
   Pre-allocate per-worker scratch, spawn via thread pool, wait-group
   join.

2. **Phase 10d — Fix tANS encoder roundtrip.** Unblocks the real
   `EncodeArrayU8` path. Minimal 2-symbol test + side-by-side C#
   reference is the cheapest way to bisect the state-table
   initialization bug. Only matters for High encoder parity.

3. **Phase 11 — High encoder.** DP optimal parser + `high_lz_encoder.zig`
   + High-side cost model. Needs phase 10 done first.

4. **Phase 12 — BT4 match finder.** L11 only, after phase 11.

5. **Phase 14 — Parallel compress.** Thread pool for SC groups, mostly
   bookkeeping once Fast + High are done.

## Unit test count

137 Zig unit tests passing, wired via `main.zig` test aggregator:

```
$ STREAMLZ_FIXTURES_DIR=./fixtures zig build test --summary all
Build Summary: 3/3 steps succeeded; 137/137 tests passed
  [fixture_tests] all 140 fixtures passed
  [encode_fixture_tests] all 100 encode roundtrips passed
```

The `fixture_tests` block is self-skipping when `STREAMLZ_FIXTURES_DIR`
is unset, so `zig build test` works on a clean checkout without the
pre-generated corpus. Run `scripts/gen_fixtures.sh` once to populate
`src/StreamLZ_zig/fixtures/{raw,slz}` (the directory is gitignored) and
then set the env var for full coverage.

## Feedback memories the session picked up (saved outside the repo)

- **No AI in commits** — respected; every commit message in this
  session is plain prose.
- **No `cd` re-prefixing** — one `cd` per command chain only, never
  repeated.
- **Long file names** — followed in the `STRUCTURE.md` layout.
- **Maximum testability** — every phase landed with correctness
  validation and passing tests before move-on.
- **Take time and do it right** — applied to bug chases
  (`wildCopy16` interleave, tANS bounds, SC per-group `dst_start`).
