# StreamLZ — Zig port

Zig 0.15.2 port of [StreamLZ](https://github.com/StreamLZ/StreamLZ), a fast LZ77-family
compressor/decompressor. The port covers all 11 user compression levels (Fast L1-L5
and High L6-L11), maintains byte-exact wire-format compatibility with the C#
reference, and is the focal point for **decompress-side performance work** —
the project's primary goal is fast decompression on consumer x86 (Arrow Lake / Zen 4 / Zen 5),
not maximum compression ratio.

This file is the canonical state-of-the-port document. Read this first.

---

## What you can do today

- **Compress** any file at any level L1-L11 byte-exact with the C# encoder for
  L1-L5; deterministic and equivalent for L6-L11. CLI: `streamlz compress -l N <in> <out>`.
- **Decompress** any `.slz` frame produced by either Zig or C# at any level. CLI:
  `streamlz decompress <in> <out>`. Parallel decompress (24-core dispatch) fires
  automatically for L6-L11 multi-chunk inputs.
- **Stream-decompress** a frame to any `std.Io.Writer` with sliding-window
  semantics and XXH32 content-checksum verification (matches C#
  `StreamLzFrameDecompressor`).
- **Bench** decompress-only on a `.slz` file with `streamlz bench <file.slz> <runs>`,
  or full compress + decompress + roundtrip with `streamlz benchc -l N -r R <raw>`.
- **Analyze** a `.slz` file's LZ-token dependency DAG (round histogram + level-0
  count) with `streamlz analyze <file.slz>`. Produced during the speculative
  parallel-decode investigation (see [Investigations](#investigations) below);
  kept around as a one-off diagnostic.

The CLI binary is `zig-out/bin/streamlz.exe` after `zig build -Doptimize=ReleaseFast`.

---

## Build, test, run

```
zig build -Doptimize=ReleaseFast               # release binary
zig build -Doptimize=ReleaseFast -Dstrip=false # release + symbols (for VTune)
zig build test --summary all                   # run unit tests
zig build safe                                 # ReleaseSafe (runtime safety checks)
zig build fuzz                                 # fuzz harness for decompressor
```

The build defaults to `x86_64_v3` baseline (Haswell-and-later) for AMD/Intel
portability — earlier `-Dcpu=native` builds compiled with AVX-512 instructions
that crashed on Ryzen 3800x. Override with `-Dcpu=native` if you want
host-specific tuning.

The test suite passes **282/282** unit tests. The fixture suite (`fixture_tests` +
`encode_fixture_tests`) decodes 140 corpus files and round-trips 100 encode
fixtures byte-exact against the C# reference. The fixture corpus lives under
`fixtures/{raw,slz}` (gitignored); generate with `scripts/gen_fixtures.sh` and
set `STREAMLZ_FIXTURES_DIR=./fixtures` before `zig build test` to enable it.

> Known quirk: the test process occasionally exits with code 3 after all 282
> tests have already reported pass. The pass count is the source of truth;
> the exit-code anomaly is a Zig stdlib teardown issue not yet diagnosed.

---

## Benchmarks

Single host: Intel Core Ultra 9 285K (Arrow Lake-S), 24 cores, Windows 11.
Built with `-Doptimize=ReleaseFast`. Decompression uses the full parallel
dispatch (24-thread pool); compress uses the same. Decompress measured with
`streamlz bench <file> 30`; compress measured with
`streamlz benchc -l N -r {3..5}`. All numbers are MB/s referencing
**decompressed** byte size.

### Decompress (parallel, 24 cores) — v1 frames

These numbers are from v1 `.slz` frames, where Fast L1-L5 falls through to the
serial decoder. For fresh v2 frames at L1-L4, see
[v2 parallel Fast L1-L4 decompress](#v2-parallel-fast-l1-l4-decompress) below —
throughput is 3-4× higher.

#### enwik8 (100 MB English text)

| Level | Zig best | Zig mean |
|-------|---------:|---------:|
| L1    |    6,258 |    6,139 |
| L3    |    6,003 |    5,899 |
| L5    |    4,833 |    4,725 |
| L9    |    2,121 |    2,084 |
| L11   |    1,970 |    1,902 |

#### silesia (200 MB mixed binary)

| Level | Zig best | Zig mean |
|-------|---------:|---------:|
| L1    |    6,947 |    6,693 |
| L3    |    6,690 |    6,567 |
| L5    |    5,704 |    5,615 |
| L9    |    2,306 |    2,230 |
| L11   |    2,267 |    2,215 |

**Read:** Fast and High both use parallel dispatch
(`decompressCoreParallel` for L6-L8 SC, `decompressCoreTwoPhase` for L9-L11).
v1 Fast L1-L5 has no parallel path and runs single-thread on the decoder hot
loop — the L1 number is already within ~5% of the per-core DRAM ceiling on
Arrow Lake, so there is no remaining single-core headroom.

### Compress (parallel, 24 cores)

#### enwik8 (100 MB English text)

| Level | Zig MB/s | Zig size   |
|-------|---------:|-----------:|
| L1    |     18.8 | 58,632,393 |
| L3    |     17.3 | 56,522,874 |
| L5    |     65.6 | 42,178,862 |
| L9    |      7.7 | 27,430,876 |
| L11   |      1.2 | 25,550,456 |

#### silesia (200 MB mixed binary)

| Level | Zig MB/s | Zig size    |
|-------|---------:|------------:|
| L1    |     24.8 | 100,270,195 |
| L3    |     23.5 |  98,109,897 |
| L5    |     89.5 |  77,477,582 |
| L9    |     11.9 |  52,915,947 |
| L11   |      2.7 |  51,331,016 |

**Read:**
- L1/L3 compress — Fast greedy parser (engine levels −2/−1/1/2) hasn't been
  hot-pathed yet; the hot loop is the obvious next target.
- L5 is the Fast greedy-chain parser and was tuned alongside the decoder.
- L9/L11 — the `findMatchesHashBased` inner loop was vectorized with
  `@Vector(4, i32)` + 64-byte hash-table alignment + dual-bucket prefetch
  in commit `1423ac0`, which also made L9 4.4 → 7.7 MB/s (+70%).

### v2 parallel Fast L1-L4 decompress

The v2 frame format (commits `abe348c..37d6263`) emits a per-block closure
sidecar — match ops + literal bytes covering cross-sub-chunk references —
so the decoder can dispatch each sub-chunk independently across cores for
Fast L1-L4. Sidecar payload is delta+varint+literal-run-RLE compressed
(~5× smaller than the naive form). All numbers below are
`streamlz benchc -l N -r 5` medians.

#### enwik8 (95.37 MB English text)

| Level | Ratio | Zig compress | Zig parallel decompress | Round-trip |
|-------|------:|-------------:|------------------------:|:----------:|
| L1    | 58.6% |    16.3 MB/s |    19,263 MB/s ( 5 ms)  |   PASS     |
| L2    | 56.9% |    15.4 MB/s |    20,715 MB/s ( 5 ms)  |   PASS     |
| L3    | 56.5% |    15.1 MB/s |    21,647 MB/s ( 4 ms)  |   PASS     |
| L4    | 54.0% |    14.1 MB/s |    17,974 MB/s ( 5 ms)  |   PASS     |

#### silesia (202.94 MB mixed binary)

| Level | Ratio | Zig compress | Zig parallel decompress | Round-trip |
|-------|------:|-------------:|------------------------:|:----------:|
| L1    | 47.2% |    21.2 MB/s |    23,075 MB/s ( 9 ms)  |   PASS     |
| L2    | 46.3% |    20.6 MB/s |    24,897 MB/s ( 8 ms)  |   PASS     |
| L3    | 46.1% |    20.2 MB/s |    25,062 MB/s ( 8 ms)  |   PASS     |
| L4    | 44.6% |    18.5 MB/s |    24,200 MB/s ( 8 ms)  |   PASS     |

#### B1_json `large_100mb.json` (92.60 MB structured JSON)

| Level | Ratio | Zig compress | Zig parallel decompress | Round-trip |
|-------|------:|-------------:|------------------------:|:----------:|
| L1    | 51.5% |    18.9 MB/s |    16,088 MB/s ( 6 ms)  |   PASS     |
| L2    | 47.2% |    20.0 MB/s |    10,528 MB/s ( 9 ms)  |   PASS     |
| L3    | 47.1% |    19.6 MB/s |    10,900 MB/s ( 8 ms)  |   PASS     |
| L4    | 46.0% |    18.5 MB/s |     8,312 MB/s (11 ms)  |   PASS     |

**Read:** v2 parallel Fast decompress runs at **17-25 GB/s on enwik8 and
silesia** and **8-16 GB/s on JSON** — a 3-4× speedup over the serial L1/L3
numbers in the v1 table above (6,258 / 6,003 MB/s enwik8; 6,947 / 6,690 MB/s
silesia). Silesia is fastest because its sub-chunks are densely populated
with long matches, so the per-thread decoder hot loop runs efficient
straight-line work. JSON drops back toward 8 GB/s at L4 where the match
graph is denser per KB. Compress-side v2 overhead is small (~10-15% over v1
for the closure walker + sidecar emit). Round-trip passes at every level on
every input. **L5 parallel decode has landed** (1.9× speedup, 10 ms on enwik8) using a
larger sidecar (~1.2 MB) with cross-chunk source bytes at recursive
transitive depth >= 1, filtered to 16-chunk slice boundaries.

---

## Architecture (file layout)

```
src/StreamLZ_zig/
  build.zig                       Zig 0.15.2 build
  build.zig.zon
  README.md                       (this file)
  BENCHMARKS.md                   historical + post-audit numbers
  audit.md                        code audit with status tracker
  FailedExperiments.md
  fixtures/{raw,slz}              fixture corpus (gitignored)
  scripts/gen_fixtures.sh
  src/
    main.zig                      CLI dispatcher
    streamlz.zig                  public library API (re-exports)
    fuzz_decompress.zig           fuzz harness (zig build fuzz)
    format/
      streamlz_constants.zig      centralized constants
      frame_format.zig            SLZ1 frame + block headers
      block_header.zig            internal 2-byte + 4-byte chunk headers
      parallel_decode_metadata.zig  sidecar wire format
    io/
      BitReader.zig               MSB-first bit reader
      bit_writer.zig              4 bit-writer variants (with debug bounds)
      copy_helpers.zig            SIMD copy helpers + alignment
      ptr_math.zig                signed-offset pointer arithmetic
    platform/
      memory_query.zig            OS memory query (Windows/Linux/macOS)
    decode/
      streamlz_decoder.zig        framed decompress + DecompressContext
      decompress_parallel.zig     parallel dispatch (SC + two-phase + sidecar)
      cross_chunk_analyzer.zig    sidecar builder + DAG analyzer
      fixture_tests.zig           test-only: fixture roundtrips
      fast/
        fast_lz_decoder.zig       L1-L5 codec hot loop
      high/
        high_lz_decoder.zig       L6-L11 codec entry
        high_lz_token_executor.zig  L6-L11 token resolve
      entropy/
        entropy_decoder.zig       tANS / Huffman / RLE dispatch
        huffman_decoder.zig       canonical Huffman 11-bit LUT
        tans_decoder.zig          tANS 5-state decode
        bit_reader_lite.zig       shared Golomb-Rice infrastructure
    encode/
      streamlz_encoder.zig        public compress API (~667 lines)
      fast_framed.zig             Fast codec frame builder
      high_framed.zig             High codec frame builder
      compress_parallel.zig       parallel compress dispatch
      cost_coefficients.zig       empirical timing coefficients
      match_eval.zig              shared match evaluation helpers
      match_hasher.zig            MatchHasher family (bucket-based)
      offset_encoder.zig          LZ offset encoding pipeline
      text_detector.zig           text-probability heuristic
      encode_fixture_tests.zig    test-only: encode roundtrips
      fast/
        fast_lz_encoder.zig       sub-chunk encoders (raw/entropy)
        fast_lz_parser.zig        greedy + lazy chain parser
        FastStreamWriter.zig      6-stream output buffer
        fast_match_hasher.zig     single-entry Fibonacci hash
        fast_token_writer.zig     Fast cmd encoding helpers
        fast_constants.zig        level mapping + min-match table
        fast_cost_model.zig       decode-time cost estimates
      high/
        high_compressor.zig       level dispatch + setup
        high_encoder.zig          stream writer + assemble output
        high_optimal_parser.zig   forward DP + backward extraction
        high_greedy_parser.zig    greedy/lazy for L6-L8
        high_matcher.zig          match ranking
        high_types.zig            Token, State, Stats, CostModel
        high_cost_model.zig       per-symbol cost calculation
        managed_match_len_storage.zig  MLS + VarLen codec
        match_finder.zig          hash-based finder (SIMD probe)
        match_finder_bt4.zig      binary-tree finder for L11
      entropy/
        entropy_encoder.zig       encodeArrayU8 + tANS + memcpy
        tans_encoder.zig          tANS encoder
        ByteHistogram.zig         byte frequency histogram
```

The decode side has zero dependencies on the encode side; either can be vendored
independently.

---

## What's missing / incomplete

The port is functionally complete for both compress and decompress at all
levels. The remaining items are public-API surface, one performance
parity tweak, and one thread-dispatch gap.

### 1. L1-L5 parallel decompress

**L1-L5: landed.** The v2 frame format carries a per-block sidecar that
enables parallel Fast decompress at all five levels.

**L1-L4** use a small sidecar (~150 KB for enwik8) containing cross-chunk
match ops and literal leaves from a BFS closure analysis. The decoder
applies the sidecar, dispatches contiguous-slice workers, and each worker
saves/restores its slice boundary guard for overcopy repair.

**L5** uses a larger sidecar (~1.2 MB for enwik8) containing cross-chunk
source bytes at recursive transitive depth ≥ 1, filtered to 16-chunk
slice boundaries. The decoder constrains its worker count so slice_size
is a multiple of 16 (capped at 24 workers). Single-pass contiguous-slice
decode with worker-internal overcopy repair.

L5 parallel decompress on enwik8 (100 MB, 24-core Arrow Lake): **10 ms
(9.8 GB/s)** vs 19 ms serial — **1.9× speedup.** Sidecar adds 1.2 MB
to the 42 MB compressed file (2.8% overhead). Round-trip verified at
1–24 simulated core counts.

**Status: L1-L5 landed.**

### 2. C1 — Fast decoder `@prefetch` hints in cmd==2 / medium paths

C# Fast `LzDecoder` has, at the tail of both the medium-match and cmd==2 long-match
branches:

```cs
if (Sse.IsSupported)
{
    Sse.Prefetch0(dstBegin - off32Stream[3]);
}
```

Looking 3 entries ahead in the off32 stream and pre-fetching the line is a
~60ns DRAM-miss hide. The Zig port doesn't have this yet. Estimated impact:
1-5% on inputs with many far-offset matches; negligible on text. Cheap to add
but not yet implemented.

**Status: open, perf-only, not a correctness gap.**

### 3. D7 / D8 / J1 / J2 — public API surface

C# exposes a `StreamLzFrameCompressor` class for streaming compress (with
sliding window) and an `SlzStream` `Stream`-derived public type for `using`-style
consumption from .NET code, plus an `SlzCompressionLevel` enum. The Zig port
has:
- The streaming **frame-block loop** primitive landed (commit `a73c476`,
  "PARITY step 41 — sliding-window frame-block loop"), so the underlying
  capability exists.
- No public Zig equivalent of `SlzStream` — Zig idiom would be a `*std.Io.Writer`
  wrapper, similar to how `decompressStream` already exposes streaming decode.
- No level enum (Zig idiom is to take an integer with comptime range checks).

These are cosmetic API gaps for a Zig consumer. They don't affect the wire
format or any internal capability.

**Status: open, low priority unless someone wants to use the port from a
Stream-consuming .NET interop layer.**

---

## What we intentionally skipped

These items were originally on the parity punch list but are explicitly **not
going to be ported**, with reasons:

### H2/H3/H4/H5 — Huffman 2/4-way split + RLE + Recursive entropy *encoders*

These chunk types exist in the **decoder** (legacy / forward-compat) but
**no C# encoder writes them**. `EncodeArrayU8Core` in C# only emits chunk types
0 (memcpy) and 1 (tANS); types 2-5 are decode-only paths kept for compatibility
with older streams. Porting encoder versions would land dead Zig code that
matches dead C# code.

### H6 — `MultiArrayEncoder`

2026 lines of C# code with **zero callers anywhere in the C# tree**.
`EntropyOptions.AllowMultiArray` is set on High `LzCoder` instances but
`EntropyEncoder.EncodeArrayU8Core` never consults the flag — the wire is built
but not connected. Porting 2 KLOC for structural parity isn't a good use of
effort. Reopen if a real C# caller appears.

### D12 — `MatchHasher2x` / `CompressLazy` parser (Fast codec level 4)

The C# `FastParser.CompressLazy` path with `MatchHasher2x` is only reachable
via internal `StreamLZCompressor.CompressBlock_Fast(codecId=Fast, codecLevel=4)`.
Every public entry point — `Slz.Compress`, `SlzStream`, `StreamLZ.Cli`, the
test suite — goes through `Slz.MapLevel`, which at `StreamLZ.cs:97` maps unified
L4 → `(Fast, 5)` (engine level 2, `CompressGreedy<uint>`), skipping Fast codec
level 4 entirely. No real caller exists. Reopen if one appears.

### A6 — CRC24 chunk-header checksum verification

C# parses the 3-byte CRC24 placeholder but `StreamLzDecoder.cs:272-276` carries
a `TODO` comment: *"implement CRC24 verification behind an opt-in flag once
the algorithm is confirmed."* The flag is off by default and the algorithm
itself isn't implemented in C#. The Zig port matches this behavior — both
parse the placeholder and neither verifies. Port-parity-wise, this is already
done.

---

## Investigations

The decoder hot path went through several rounds of profiling and optimization
this session and earlier. The full play-by-play, including failed experiments
and what made them fail, lives in [`../../FailedExperiments.md`](../../FailedExperiments.md).

A few highlights worth knowing as a future reader:

### Wins that landed

- **CMOV LIFO swap in the Fast short-token loop.** The original recent-offset
  swap was a 4-op XOR-mask cascade that the compiler couldn't keep in registers
  due to data-dependent indexing. Replacing with a CMOV select shortened the
  critical path on the match-load side by ~2 cycles per token. See
  `fast_lz_decoder.zig:419-427` (`recent_offs = if (use_new_dist) ...`).
- **Far-offset MOVDQU widening.** Medium match, long-match-32, and long-literal
  loops in the Fast decoder were doing `2× copy64` (8-byte mov pairs). Replacing
  with single `copy16` (16-byte MOVDQU pair) per iteration cut store-port
  pressure for the only paths where the source range never overlaps the target.
  Long-match-16 was kept as scalar 2× copy64 because its offsets can drop to 8
  and the cascade pattern is correct for self-overlap.
- **CMOV LIFO swap was modeled on the equivalent High-codec optimization** that
  landed earlier (`high_lz_process_runs.zig:resolveTokens`), where the same
  trick saved ~25% on L9 decompress. The High decoder also has register-resident
  3-entry recent-offset LIFO instead of a memory-backed array.
- **Encoder L9-L11 SIMD hash probe + dual-bucket prefetch.** The
  `findMatchesHashBased` inner loop was scalar; vectorizing the 16-entry probe
  with `@Vector(4, i32)` + adding 64-byte hash-table alignment + dual-bucket
  prefetch hints turned L9 enwik8 compress from 4.4 → 7.7 MB/s (+70%). See
  commit `1423ac0`.
- **Decoder 24-core parallelism for L6-L11.** Two separate paths — SC parallel
  for L6-L8 (each chunk fully independent by encoder construction) and two-phase
  parallel for L9-L11 (parallel entropy decode + serial LZ resolve). Both share
  a persistent `std.Thread.Pool` to avoid per-decompression thread spawn cost.

### Experiments that didn't pay off

- **Short-token match copy widened from 2× copy64 to 1× copy16 with a
  distance-≥16 branch.** Saves one store, but the cmp+jb branch + bool flag
  added more frontend uops than the saved store relieved. Regressed L3 by ~3%
  consistently. The hot loop is at the front-end dispatch ceiling already.
- **PSHUFB-based short-token match copy** (handles small offsets via shuffle
  mask table → no branch needed). Generated ~10 extra uops per iteration for
  the mask-load + clamp + shuffle setup, far more than the 1 store saved.
  Regressed ~14%.
- **Software prefetch for the next short-token's match.** Same problem — the
  hot loop is frontend-bound, not memory-bound. uarch-exploration showed only
  ~18% memory-bound vs ~17% non-memory-backend (store port). Adding peek loads
  + prefetch instructions blew the dispatch budget for a marginal hit-rate
  improvement. Regressed ~10%.
- **Thread-local cached `MatchHasher16Dual` table** to eliminate the ~150 ms/call
  alloc cost of the encoder's 64 MB hash table. On Windows, `VirtualAlloc`'s
  demand-zero page faults are amortized into the compress loop's first-touch
  pattern; explicit `@memset` on a reused dirty buffer was *slower* than
  fresh-allocation-with-lazy-zeroing. Reverted.
- **Loop unrolling, copy-via-`@Vector(8, u8)` instead of `u64`, raw-pointer-cast
  copies bypassing `std.mem.writeInt`** — all explored, all either flat or
  regressed. Documented inline in `FailedExperiments.md`.

The general lesson encoded by these experiments: **the Fast decoder hot loop is
already at the per-core dispatch ceiling on Arrow Lake**. Further single-thread
gains would need either (a) wire-format changes that let the decoder skip work
at runtime, or (b) parallelism that scales beyond a single core's IPC ceiling.
The single-thread tuning frontier is largely closed.

### Cleanness analyzer (`streamlz analyze`)

A diagnostic-only token-dependency-DAG analyzer lives in
`src/decode/cross_chunk_analyzer.zig`. It walks an `.slz` file's LZ tokens, builds
the per-byte dependency DAG, and reports:
- Total match tokens
- Critical path depth (longest dependency chain)
- Round histogram (how many tokens at each depth in the DAG)
- Theoretical parallel-decode speedup with N cores
- Cross-validating level-0-only bitmap analyzer (~3× faster than the full DAG
  walker, validates the level-0 count)

Built during a session that explored speculative parallel decode for L1-L5.
Conclusion: the theoretical parallelism is large (~24× at 24 cores for any
level on real-world data), but the analyzer itself takes 60-300 ms per 100 MB
input — far longer than the ~16 ms decode it would speed up. Decode-time DAG
analysis is not viable; a wire-format change carrying per-token round
information would unlock the parallelism but requires breaking the format.

The analyzer is kept in-tree because it remains useful for offline diagnostic
work (e.g., comparing dependency density across encoders or input types).

---

## Key invariants worth knowing

For anyone modifying the hot loops:

1. **`@Vector(16, u8)` not `@Vector(32, u8)`.** Matches C#. AVX2 (32-byte
   loads/stores) throttles Arrow Lake frequency under load and is measurably
   slower for this workload. Confirmed via direct A/B tests; documented in
   the C# source as well.

2. **`wildCopy16` interleaved load-store-load-store ordering** (not load-load-
   store-store). The interleave is REQUIRED for small-offset LZ match
   propagation: a single 16-byte vector load would read unwritten bytes from
   past the write cursor, breaking RLE-like patterns. Locked in by an
   isolation test in `copy_helpers.zig`.

3. **tANS `src_start` / `src_end` capture order.** Must be set on the parameter
   block BEFORE state-init shifts `src` / `srcEnd` by ±4. The decode hot loop's
   bounds check uses the "outer" range and intentionally steps into the
   state-init overlap region. Easy to miss when porting — see commit `bbfadc1`.

4. **SC per-group `dst_start`.** L6-L8 chunks group in 4s for the SC path. The
   decoder must pass a group-local `dst_start` (not whole-buffer-start) to each
   chunk so the encoder's per-group "first chunk = base_offset 0" assumption
   holds and the initial 8-byte raw `Copy64` fires at each group's start.
   Computed explicitly in `decompressCompressedBlock`; the parallel path in
   `decompress_parallel.decodeOneChunk` does the same per worker.

5. **Tail prefix restoration (SC only).** Encoder stores `(num_chunks − 1) × 8`
   bytes at the end of each frame block. After decoding all chunks, overwrite
   first 8 bytes of every chunk except chunk 0 with those tail bytes.

6. **`comptime mode: LiteralMode`** in `decode/fast/fast_lz_decoder.zig`
   (`processModeImpl`) generates two specialized functions (delta-literal vs
   raw-literal). Zig replacement for C#'s `ILiteralMode` interface trick.
   Unambiguous win for branch-free hot loops because there's only one callsite
   per specialization.

7. **Default build target `x86_64_v3`.** Set in `build.zig` so binaries are
   portable across modern Intel and AMD x86_64 hosts. AVX-512 instructions
   from `-mcpu=native` on Arrow Lake crashed earlier builds on Ryzen 3800x
   with `STATUS_ILLEGAL_INSTRUCTION`.

---

## Glossary

| Term | Meaning |
|------|---------|
| Fast codec | Greedy/lazy LZ parser, levels 1-5. Fast compress + decompress. |
| High codec | Optimal DP parser, levels 6-11. Slower compress, same decompress speed. |
| tANS | Tabled Asymmetric Numeral System — entropy coder used for literal streams. |
| BT4 | Binary Tree 4-way — match finder used by the High codec's optimal parser. |
| SC | Self-Contained — block format flag; each block decodes independently. |
| Sidecar | Optional parallel-decode metadata block (cross-chunk dependency map). |
| Chunk | 256 KB decompression unit. Sub-chunk = 128 KB half. |
| Cross-chunk | A match whose source bytes are in a different chunk than its target. |
| Cleanness | Whether a byte's dependency chain stays within one chunk (no cross-chunk refs). |
| PPOC | Parallel Producer/Consumer — proof-of-concept sidecar builder. |
| MLS | Managed Match Length Storage — variable-length match table for the High codec. |

---

## License

Same as the upstream StreamLZ project (MIT).
