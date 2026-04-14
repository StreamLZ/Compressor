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
have yet (phase 13). **High encoder (L6-L11) is functionally scaffolded
but not yet end-to-end byte-exact.** All big pieces landed — optimal
parser with Phase 1-3 DP + outer-loop re-run, fast parser (greedy /
1-lazy / 2-lazy), BT4 match finder, hash-based match finder, cost
model, assembleCompressedOutput, and a `compressFramedHigh` dispatcher
wiring L6-L11 through `compressFramed` with BT4/hash finder selection
per level. Tiny inputs and incompressible inputs round-trip cleanly
via the uncompressed / raw fallback paths. Full compressed-output
roundtrips at L9/L11 on repetitive input still hit one residual bug
(a multi-write composition desync inside `writeLzOffsetBits` that
surfaces in the decoder's match-length stream reader) — tracked as
step 34 part 3. Repo lives under `src/StreamLZ_zig/`, zero coupling
to the .NET solution.

## Phase tracker

### Done
| # | phase | summary |
|---|---|---|
| 0 | Foundation | `build.zig` + `build.zig.zon` (Zig 0.15.2 pinned), CLI skeleton, `.gitignore`, 45 unit tests wired |
| 1 | Wire format | `format/streamlz_constants.zig`, `format/frame_format.zig`; `streamlz info` CLI |
| 2 | Bit I/O | `io/bit_reader.zig` (forward+backward refill), `io/bit_writer.zig` (4 variants), `io/bit_writer_64.zig` (forward + backward with direct roundtrip coverage) |
| 3a | Decompress scaffold | `streamlz decompress` CLI, uncompressed block path |
| 3b | Fast LZ decoder | `decode/fast_lz_decoder.zig`, `format/block_header.zig`; L1-L5 byte-exact |
| 4 | Huffman decoder | `decode/huffman_decoder.zig`: 11-bit LUT, 3-stream parallel, canonical Huffman |
| 4b | RLE + Recursive | `decode/entropy_decoder.zig`: Type 3 RLE + Type 5 simple N-split + Type 5 multi-array |
| 5 | High LZ decoder | `decode/high_lz_decoder.zig` + `decode/high_lz_process_runs.zig`: ReadLzTable, UnpackOffsets (bidirectional), ProcessLzRuns Type0+Type1 |
| 6 | tANS decoder | `decode/tans_decoder.zig`: 5-state interleaved decode, Golomb-Rice table decode, LUT construction |
| 5b | SC grouping | Per-group `dst_start` computation so group-first chunks get `base_offset == 0` initial Copy64; tail prefix restoration |
| 7 | Vectorize CopyHelpers | `@Vector(16, u8)` × 4 for `copy64Bytes`, `@Vector(8, u8)` `+%` for `copy64Add`. `streamlz bench` subcommand for in-memory timing |
| 7b | High decoder hot loop | `@prefetch` 128 tokens ahead in `executeTokensType1`; same-iteration prefetch in `processLzRunsType0`; 8-byte cascading literal copy |
| 8 | Fixture corpus + roundtrip tests | `scripts/gen_fixtures.sh` builds 20 raws × 7 levels = 140 `.slz` under `src/StreamLZ_zig/fixtures/` (gitignored). `decode/fixture_tests.zig` walks `$STREAMLZ_FIXTURES_DIR/slz/*.slz`, decodes, and diffs against `raw/<stem>.raw`. Skips cleanly if env var unset. 140/140 bit-exact |
| 9 | Fast encoder L1-L5, byte-exact with C# | `encode/{fast_constants,fast_match_hasher,fast_stream_writer,fast_token_writer,fast_lz_parser,fast_lz_encoder,streamlz_encoder,text_detector,cost_model,cost_coefficients,byte_histogram}.zig`. Greedy parser (engine -2/-1/1/2) + lazy chain parser (engine 4) + raw-mode and entropy-mode sub-chunk assemblers. Bit-exact with C# Fast across 100 fixtures, enwik8 (100 MB), silesia (212 MB) — every Fast level, every file, zero delta. `streamlz c [-l N] <in> <out>` CLI |
| 10a-c | Entropy infra scaffolding | `encode/byte_histogram.zig` (with `getCostApproxCore`), `io/bit_writer_64.zig` (forward + backward), `encode/tans_encoder.zig` (normalize + init_table + get_bit_count + encode_bytes + encode_table) |
| 10d | tANS encoder roundtrip | Fixed by commits `6519c42` (stream layout) + `98023bf` (allocator scratch). All tANS roundtrip tests pass: `'abab'` × 16, `'abc'` × 85, 512-byte English text, enwik8 64 KB / 128 KB chunks, silesia 64 KB / 128 KB chunks |
| 10i-l | Fast encoder parity sweep | Phase-10 sub-phases that chased the remaining Fast drift to zero: `Slz.MapLevel` alignment, whole-input hasher window, adaptive hash sizing with text detection, `WriteOffsetWithLiteral1`, delta-literal histogram-cost selection, Off16 entropy-split cost compare, EntropyOptions per-level masks, block-/sub-chunk-level `AreAllBytesEqual`, `CheckPlainHuffman` trial-encode arm, per-block cost-vs-memsetCost rewrite, backward-extend whole-input bound, hasher-vs-parser `min_match_length` split. See `437e6a6` |
| 11 | High encoder port (steps 25-34) | Large chunk of the parity punch list. Landed modules: `encode/managed_match_len_storage.zig` (VarLen codec + match extraction), `encode/match_hasher.zig` extended to the full `MatchHasher1/2x/4/4Dual/16Dual` family with dual-hash buckets, `encode/match_finder.zig` (hash-based finder), `encode/match_finder_bt4.zig` (binary-tree finder for L11), `encode/high_types.zig` (`HighRecentOffs`, `HighStreamWriter`, `Token`, `State`, `Stats`, `CostModel`), `encode/high_matcher.zig` (`isMatchLongEnough`, recent-offset slot matching), `encode/high_cost_model.zig` (`updateStats`, `makeCostModel`, `bitsFor*`), `encode/high_encoder.zig` (`initializeStreamWriter`, `writeMatchLength/Literals/Offset`, `addToken`, `addFinalLiterals`, `assembleCompressedOutput`, `encodeTokenArray`), `encode/high_fast_parser.zig` (comptime-generic greedy / 1-lazy / 2-lazy parser for L1-L4), `encode/high_optimal_parser.zig` (Phase 1 forward DP + Phase 2 backward extraction + Phase 3 stats update + outer-loop re-run for L8+), `encode/high_compressor.zig` (`setupEncoder`, `HighHasher` tagged union, `doCompress` level dispatch). `encode/offset_encoder.zig` has `writeLzOffsetBits` / `encodeLzOffsets` for the shared offset bit stream; direct roundtrip tests cover both the legacy and modulo paths. Fixed a stale-constants bug that had local `offset_bias_constant = 8` shadowing the correct 760 — both sides now pull from `streamlz_constants` |
| 13-pt1 | compressFramedHigh wiring | `compressFramed` level range extended to 1-11; unified L6-L11 divert through `compressFramedHigh` which allocates MLS over the whole source, runs BT4 (codec level 9) or hash-based match finder, and iterates 256 KB blocks with the same 2-byte block header + 4-byte chunk header + sub-chunk loop shape as the Fast path. Each sub-chunk calls `doCompress`; raw-fallback and block-level cost-bail mirror Fast. Tiny inputs + incompressible inputs round-trip cleanly today |
| parity 1-11, 15 | Zig-port parity punch list | Decoder side: recursive scratch threading, dictionary/dstOffset entry, stream decompressor with sliding window + XXH32, `copyWholeMatch` + `whole_match_distance`, `RestartDecoder` flag wiring, Type 5 multi-array. Encoder side: full `CompressOptions` plumbing, SelfContained mode + prefix table (L1-L5 only so far), TwoPhase flag. See `PARITY.md` |

### Pending
| # | phase | notes |
|---|---|---|
| 13-pt2 | High encoder residual: length-stream composition bug | step 34 part 3. Compressed-output roundtrips at L9/L11 on repetitive input reach the decoder's match-length stream reader (`readLengthBackward`) and return `StreamMismatch`. Raw bit primitives (BitWriter64Forward/Backward ↔ BitReader) and the single-offset full-function `writeLzOffsetBits` roundtrip both pass, so the residual desync is in `writeLzOffsetBits`'s multi-write composition — the backward count header + alternating forward/backward offsets + alternating forward/backward u32 length overflows all sharing one buffer. Needs byte-level diffing against C# reference output for a known repetitive input |
| 13-pt3 | SC prefix table for High L6-L8 | L6-L8 are currently encoded as non-SC even though their `MapLevel` entry says `SC=true`. Once part 2 is green, add the SC flag + per-group prefix table emission (copy of the L1-L5 code path in `compressFramedHigh`) |
| 10-res | Residual entropy encoders | `encode/multi_array_huffman_encoder.zig` (2 KLOC in C#), Huffman 2/4-way split, RLE, recursive. Fast L1-L5 works without these because `EntropyOptions` clears `AllowTANS` / `AllowMultiArray` for Fast. The High codec's `assembleCompressedOutput` uses `encodeArrayU8` which falls through to memcpy-only today — compression ratios will lag C# L6-L11 until these encoders land, but functionality doesn't |
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
    streamlz_encoder.zig            top-level framed compress + Fast L1-L5 loop + compressFramedHigh for L6-L11
    fast_constants.zig              FastConstants + level mapping + min-match-length table builder
    fast_match_hasher.zig           FastMatchHasher(u16/u32) — single-entry Fibonacci hash
    fast_stream_writer.zig          6-parallel-stream output buffer (literal/delta/token/off16/off32/length)
    fast_token_writer.zig           writeOffset / writeComplexOffset / writeOffsetWithLiteral1 / writeLengthValue / writeOffset32
    fast_lz_parser.zig              Greedy + lazy chain parser (comptime level, comptime hash T)
    fast_lz_encoder.zig             Sub-chunk encoders: raw (L1/L2), entropy (L3/L4), entropy chain (L5) + assembleEntropyOutput
    text_detector.zig               Text-probability heuristic → triggers min-match-length bump
    cost_model.zig                  Platform cost combination + decoding-time estimates
    cost_coefficients.zig           Memset-cost coefficients + speed-tradeoff scaling
    byte_histogram.zig              ByteHistogram + getCostApproxCore (log2 lookup table)
    match_hasher.zig                MatchHasher family — MatchHasher1/2x/4/4Dual/16Dual + MatchHasher2 chain hasher
    match_eval.zig                  countMatchingBytes / getMatchLengthQuick / isMatchBetter / getLazyScore
    managed_match_len_storage.zig   MLS + VarLen codec + insertMatches + extractLaoFromMls + removeIdentical
    match_finder.zig                Hash-based match finder (findMatchesHashBased) for High L5-L10
    match_finder_bt4.zig            Binary-tree match finder (findMatchesBT4) for High L11
    offset_encoder.zig              OffsetEncoder: encodeLzOffsets + writeLzOffsetBits (legacy + modulo) + cost helpers
    entropy_encoder.zig             EncodeArrayU8 / EncodeArrayU8Memcpy / EncodeArrayU8WithHisto
    tans_encoder.zig                tANS encoder (normalize + init_table + encode_bytes + encode_table) — roundtrip proven
    high_types.zig                  HighRecentOffs, HighStreamWriter, Token, State, Stats, CostModel
    high_matcher.zig                isMatchLongEnough, checkMatchValidLength, getRecentOffsetIndex, getBestMatch
    high_cost_model.zig             updateStats, makeCostModel, rescale*, bitsForLiteral/Token/Offset/LiteralLength
    high_encoder.zig                HighEncoderContext, initializeStreamWriter, addToken, addFinalLiterals,
                                      writeMatchLength/Literals/Offset, assembleCompressedOutput, encodeTokenArray
    high_fast_parser.zig            Comptime-generic greedy / 1-lazy / 2-lazy parser for High L1-L4
    high_optimal_parser.zig         DP parser (Phase 1 forward / Phase 2 backward / Phase 3 stats / outer loop)
    high_compressor.zig             setupEncoder (level table) + HighHasher tagged union + doCompress dispatch
    encode_fixture_tests.zig        Zig encode → C# reference diff (byte-exact roundtrip, L1-L5)
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

- **High encoder compressed-output roundtrip on repetitive input**
  (step 34 part 3). Currently gated on a `writeLzOffsetBits`
  multi-write composition desync that surfaces in the decoder's
  match-length stream reader (`readLengthBackward` returns
  `StreamMismatch`). Tiny inputs and incompressible inputs round-trip
  via the raw/uncompressed fallback paths. Bit-level primitives are
  proven correct by direct unit tests (added in this session).
- **SC prefix table for High L6-L8** not yet emitted. L6-L8 are
  encoded as non-SC today; once step 34 part 3 is green, layer the
  SC flag + per-group prefix-table append on top of the Fast code
  path already in `compressFramed`.
- **High-codec entropy encoders** (Huffman 2/4-way, RLE, recursive,
  multi-array) not yet ported. `encodeArrayU8` falls through to
  memcpy-only for now, so L6-L11 will compress correctly but not as
  tightly as C# until these land.
- **L6-L8 parallel decode** not yet implemented (phase 13). Serial SC
  works correctly and at ~950 MB/s but C# in practice uses
  `DecompressCoreParallel` (~10 GB/s multi-threaded on silesia L6).
- **L9-L11 two-phase parallel decode** not yet implemented (phase 13).
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
40ac74f  PARITY.md: update step 34 entry with three-part progress breakdown
f090616  Zig io: add BitWriter64Backward + BitReader.initBackward roundtrip test
9d7735f  Zig encoder: fix stale offset_encoder constants (step 34 part 2)
1063c7f  Zig encoder: Phase 34 part 2 — L9 incompressible roundtrip
3eb5831  Zig encoder: Phase 34 part 2 diagnostics
1432c30  Zig encoder: Phase 34 (D9) — compressFramed wiring for L6-L11 (PARTIAL)
2fcfd5e  Zig encoder: Phase 33 (G2) — BT4 match finder for L11
a46ad4f  Zig encoder: Phase 32 (F3) — finish High optimal parser
f12c9d9  Zig encoder: High optimal parser scaffold (Phase 1 forward DP)
4dc8592  Zig encoder: High fast parser (greedy/lazy, L1-L4)
968be6a  Zig encoder: High stream writer + assembleCompressedOutput
aef8256  Zig encoder: High cost model + histogram stats
1f779e2  Zig encoder: High codec scaffolding (types + matcher + setup)
6c872cf  Zig encoder: FindMatchesHashBased + extract overflow fix
4d4e9cd  Zig encoder: ManagedMatchLenStorage + VarLen codec
10a6197  Zig encoder: extend MatchHasher family + adaptivePreloadLoop
f158fa3  Zig encoder: I-series prep modules for High codec port
456ce61  Zig encoder: port OffsetEncoder + extend cost coefficients
025d7ab  Zig: widen encodeArrayU8 signature + PARITY.md migration + docs cleanup
00e8724  Zig: stream decompressor + Type 5 multi-array + SC/TwoPhase encode modes
4d34320  Zig decoder: dictionary entry points + pass scratch through entropy decoder
409ca62  STATUS.md + STRUCTURE.md: Fast encoder L1-L5 byte-exact
437e6a6  Zig encoder: byte-exact parity with C# Fast L1-L5
5c9c934  Zig CLI: benchc subcommand for in-memory compress+decompress benchmarks
28df736  Zig encoder: restore +0% parity with C# Fast (Phase 10j fix)
... (earlier history in previous STATUS.md snapshot @ 409ca62)
```

Base (pre-decoder work): `4a0451a` (`Add concurrent access test verifying Slz thread safety`).

## Recommended next session entry points (in order)

The authoritative list of remaining parity gaps lives in
[`PARITY.md`](PARITY.md) — 45-step punch list with file/line citations.
Steps 1-33 are done. Step 34 (D9) is partial — part 1 (wiring) + part 2
(offset constants fix) committed; part 3 is the immediate next task.

1. **Step 34 part 3 — `writeLzOffsetBits` multi-write composition.**
   Residual desync surfaces as `StreamMismatch` in the decoder's
   `readLengthBackward` on compressed L9/L11 roundtrips. Bit-level
   primitives and the single-offset full-function path both pass —
   the bug is in how the count header + alternating forward/backward
   offsets + alternating forward/backward u32 length overflows share
   one buffer. Byte-level diff against C# reference output for a
   known repetitive input is the fastest path.

2. **Step 34 part 4 — SC prefix table for L6-L8.** L6-L8 are encoded
   as non-SC today. Once part 3 is green, lift the SC flag + prefix
   table emission from the Fast code path in `compressFramed` into
   `compressFramedHigh`.

3. **Steps 16-24 — residual entropy encoders.** Huffman 2/4-way, RLE,
   recursive, multi-array. Not blocking correctness of L6-L11 output
   (memcpy fallback works) but needed to reach C# ratio parity.

4. **Steps 35-38 — Parallel decompress + parallel compress** (phase
   13/14). Closes the 0.7-0.8× serial-decode gap on L6-L11.

5. **Step 41 — `StreamLzFrameCompressor` stream-based API.** Ports the
   sliding-window streaming compressor; also unlocks full dictionary
   semantics on the decode side.

## Unit test count

234 Zig unit tests passing, wired via `main.zig` test aggregator:

```
$ STREAMLZ_FIXTURES_DIR=./fixtures zig build test --summary all
Build Summary: 3/3 steps succeeded; 234/234 tests passed
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
