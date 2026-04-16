# StreamLZ — Zig port

Zig 0.15.2 port of [StreamLZ](https://github.com/StreamLZ/StreamLZ), a fast LZ77-family
compressor/decompressor. The port covers all 11 user compression levels (Fast L1-L5
and High L6-L11), maintains byte-exact wire-format compatibility with the C#
reference, and is the focal point for **decompress-side performance work** —
the project's primary goal is fast decompression on consumer x86 (Arrow Lake / Zen 4 / Zen 5),
not maximum compression ratio.

This file is the canonical state-of-the-port document. It supersedes the older
`STATUS.md` / `PARITY.md` / `BENCHMARKS.md` triple. Read this first.

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
```

The build defaults to `x86_64_v3` baseline (Haswell-and-later) for AMD/Intel
portability — earlier `-Dcpu=native` builds compiled with AVX-512 instructions
that crashed on Ryzen 3800x. Override with `-Dcpu=native` if you want
host-specific tuning.

The test suite passes **276/276** unit tests. The fixture suite (`fixture_tests` +
`encode_fixture_tests`) decodes 140 corpus files and round-trips 100 encode
fixtures byte-exact against the C# reference. The fixture corpus lives under
`fixtures/{raw,slz}` (gitignored); generate with `scripts/gen_fixtures.sh` and
set `STREAMLZ_FIXTURES_DIR=./fixtures` before `zig build test` to enable it.

> Known quirk: the test process occasionally exits with code 3 after all 276
> tests have already reported pass. The pass count is the source of truth;
> the exit-code anomaly is a Zig stdlib teardown issue not yet diagnosed.

---

## Benchmarks

Single host: Intel Core Ultra 9 285K (Arrow Lake-S), 24 cores, Windows 11. Both
implementations built with their respective release/optimize modes
(`-Doptimize=ReleaseFast` for Zig, `-c Release` for C#). Decompression runs use
each implementation's full parallel dispatch (24-thread pool); compress runs use
the same. C# decompress measured with `slz -db -r 30 <file>`; Zig decompress
with `streamlz bench <file> 30`. Compress measured with `slz -b -l N -r {3..5}`
and `streamlz benchc -l N -r {3..5}`. All numbers are MB/s referencing
**decompressed** byte size.

### Decompress (parallel, 24 cores)

#### enwik8 (100 MB English text)

| Level | Zig best | Zig mean | C# median | Zig mean / C# |
|-------|---------:|---------:|----------:|--------------:|
| L1    |    6,258 |    6,139 |     5,942 |       **+3%** |
| L3    |    6,003 |    5,899 |     5,822 |       **+1%** |
| L5    |    4,833 |    4,725 |     4,851 |           −3% |
| L9    |    2,121 |    2,084 |     1,810 |      **+15%** |
| L11   |    1,970 |    1,902 |     1,702 |      **+12%** |

#### silesia (200 MB mixed binary)

| Level | Zig best | Zig mean | C# median | Zig mean / C# |
|-------|---------:|---------:|----------:|--------------:|
| L1    |    6,947 |    6,693 |     6,471 |       **+3%** |
| L3    |    6,690 |    6,567 |     6,260 |       **+5%** |
| L5    |    5,704 |    5,615 |     5,593 |             0 |
| L9    |    2,306 |    2,230 |     2,225 |             0 |
| L11   |    2,267 |    2,215 |     2,231 |             0 |

**Read:** Fast (L1-L5) is at parity with C# and slightly ahead on text. High
(L9-L11) is at parity on silesia and noticeably ahead on text — Fast decoder
optimizations (CMOV LIFO swap, far-offset MOVDQU widening) directly transferred
to the High decoder's match-copy paths. Both Fast and High already use parallel
dispatch (`decompressCoreParallel` for L6-L8 SC, `decompressCoreTwoPhase` for
L9-L11). The tables above are from v1 `.slz` frames, where Fast L1-L5 fell
through to the serial path. **Fast L1-L4 now has its own parallel path** behind
a v2 frame-format change — see
[v2 parallel Fast L1-L4 decompress](#v2-parallel-fast-l1-l4-decompress--b1_json-large_100mbjson-926-mb)
below and [L1-L5 parallel decompress](#1-l1-l5-parallel-decompress).

### Compress (parallel, 24 cores)

#### enwik8 (100 MB English text)

| Level | Zig MB/s | C# MB/s | Zig / C# | Zig size  | C# size   |
|-------|---------:|--------:|---------:|----------:|----------:|
| L1    |     18.8 |    34.9 |  **−46%**| 58,632,393 | 58,632,393 |
| L3    |     17.3 |    38.7 |  **−55%**| 56,522,874 | 56,522,874 |
| L5    |     65.6 |    57.5 |  **+14%**| 42,178,862 | 42,178,862 |
| L9    |      7.7 |     6.1 |  **+26%**| 27,430,876 | 27,399,196 |
| L11   |      1.2 |     0.3 |   **4×** | 25,550,456 | 25,641,137 |

#### silesia (200 MB mixed binary)

| Level | Zig MB/s | C# MB/s | Zig / C# | Zig size   | C# size    |
|-------|---------:|--------:|---------:|-----------:|-----------:|
| L1    |     24.8 |    58.2 |  **−57%**| 100,270,195 | 100,270,195 |
| L3    |     23.5 |    53.5 |  **−56%**|  98,109,897 |  98,109,897 |
| L5    |     89.5 |    78.5 |  **+14%**|  77,477,582 |  77,477,582 |
| L9    |     11.9 |     9.8 |  **+21%**|  52,915,947 |  53,006,319 |
| L11   |      2.7 |     0.5 |  **5.4×**|  51,331,016 |  51,386,675 |

**Read:**
- L1/L3 compress is significantly slower than C# — the Zig Fast greedy parser
  (engine levels −2/−1/1/2) has not been hot-pathed yet. Both implementations
  produce **byte-exact identical output** at L1-L5; the throughput delta is
  pure encoder hot-loop work that hasn't been done.
- L5 onward (Fast greedy chain + High) is **faster than C#** — the Zig
  encoder's L5 chain parser was tuned alongside the decoder, and the High
  encoder benefits from the SIMD hash probe + dual-bucket prefetch landed in
  commit `1423ac0`.
- L9 +20-26%, L11 4-5× faster — these wins are driven by the same SIMD probe
  + 64-byte-aligned hash table optimization. L11 in particular: C# uses BT4
  but doesn't vectorize its candidate probe.
- L9-L11 size differences (~0.1-0.4%) are because **C# StreamLZ's High encoder
  is non-deterministic** between runs, so byte-exact parity isn't a reachable
  goal. Compressed sizes are equivalent in practice (sometimes Zig is smaller,
  sometimes C#).

### v2 parallel Fast L1-L4 decompress — B1_json `large_100mb.json` (92.6 MB)

The v2 frame format (commits `abe348c..37d6263`) emits a per-block closure
sidecar — match ops + literal bytes covering cross-sub-chunk references —
so the decoder can dispatch each sub-chunk independently across cores for
Fast L1-L4. Sidecar payload is delta+varint+literal-run-RLE compressed
(~5× smaller than the naive form). `streamlz benchc -l N -r 5` on
`large_100mb.json`:

| Level | Ratio | Zig compress | Zig parallel decompress | Round-trip |
|-------|------:|-------------:|------------------------:|:----------:|
| L1    | 51.5% |    18.9 MB/s |    16,088 MB/s (6 ms)   |   PASS     |
| L2    | 47.2% |    20.0 MB/s |    10,528 MB/s (9 ms)   |   PASS     |
| L3    | 47.1% |    19.6 MB/s |    10,900 MB/s (8 ms)   |   PASS     |
| L4    | 46.0% |    18.5 MB/s |     8,312 MB/s (11 ms)  |   PASS     |

**Read:** parallel Fast L1-L4 on 92.6 MB JSON runs at 8-16 GB/s end-to-end.
L1 is essentially DRAM-bandwidth-bound at 16 GB/s; later levels spend more
time in per-sub-chunk LZ resolve (denser match graphs) and drop back toward
the 8-10 GB/s band. Ratio climbs monotonically L1→L4 as expected for JSON.
Round-trip passes at every level. **L5 is still serial** — its lazy chain
parser produces ~10× more closure tokens per block than L1-L4, so emitting
a sidecar for every L5 block would dominate the compressed size; a
per-block trigger is the likely path forward.

---

## Architecture (file layout)

```
src/StreamLZ_zig/
  build.zig                       Zig 0.15.2 build, default -mcpu x86_64_v3
  build.zig.zon
  README.md                       (this file)
  FailedExperiments.md            (referenced — see Investigations)
  fixtures/{raw,slz}              fixture corpus (gitignored, run gen_fixtures.sh)
  scripts/gen_fixtures.sh
  src/
    main.zig                      CLI dispatcher: compress, decompress,
                                  bench, benchc, info, analyze
    format/
      streamlz_constants.zig      magic numbers, chunk sizes, table parameters
      frame_format.zig            SLZ1 outer frame + 8-byte block header
      block_header.zig            internal 2-byte block hdr + 4-byte chunk hdr
    io/
      bit_reader.zig              MSB-first bit reader, fwd + bwd refill
      bit_writer.zig              4 bit-writer variants
      bit_writer_64.zig           64-bit forward + backward bit writers
      copy_helpers.zig            copy64, copy16, copy16Add, wildCopy16
                                  (SIMD-backed via @Vector(16, u8))
    decode/
      streamlz_decoder.zig        framed decompress, parallel-dispatch entry,
                                  decompressStream + sliding window + XXH32
      decompress_parallel.zig     std.Thread.Pool dispatch for SC + two-phase
      fast_lz_decoder.zig         L1-L5 codec hot loop
      high_lz_decoder.zig         L6-L11 codec entry + readLzTable
      high_lz_process_runs.zig    L6-L11 token resolve (Type 0 + Type 1)
      entropy_decoder.zig         tANS / Huffman / RLE / recursive dispatch
      huffman_decoder.zig         canonical Huffman 11-bit LUT, 3-stream parallel
      tans_decoder.zig            tANS table decode + LUT init + 5-state decode
      cleanness_analyzer.zig      diagnostic-only DAG analyzer (see Investigations)
    encode/
      streamlz_encoder.zig        framed compress, Fast L1-L5 + compressFramedHigh
      fast_constants.zig          level mapping + min-match-length table
      fast_match_hasher.zig       single-entry Fibonacci hash
      fast_stream_writer.zig      6-stream output buffer
      fast_token_writer.zig       Fast cmd encoding helpers
      fast_lz_parser.zig          greedy + lazy chain parser
      fast_lz_encoder.zig         sub-chunk encoders (raw / entropy / chain)
      text_detector.zig           text-probability heuristic
      cost_model.zig              decode-time cost estimates
      cost_coefficients.zig       memset-cost + speed-tradeoff scaling
      byte_histogram.zig          ByteHistogram + getCostApproxCore
      match_hasher.zig            MatchHasher1/2x/4/4Dual/16Dual family
      match_eval.zig              countMatchingBytes / getLazyScore / etc.
      managed_match_len_storage.zig  MLS + VarLen codec
      match_finder.zig            hash-based finder (SIMD probe + dual prefetch)
      match_finder_bt4.zig        binary-tree finder for L11
      offset_encoder.zig          OffsetEncoder + writeLzOffsetBits
      entropy_encoder.zig         encodeArrayU8 + tANS + memcpy fallback
      tans_encoder.zig            tANS encoder
      high_types.zig              Token, State, Stats, CostModel, RecentOffs
      high_matcher.zig            isMatchLongEnough, recent-offset slot matching
      high_cost_model.zig         per-symbol cost calculation
      high_encoder.zig            HighEncoderContext, addToken, assemble output
      high_fast_parser.zig        greedy / 1-lazy / 2-lazy for L6-L8
      high_optimal_parser.zig     forward DP + backward extraction (L9+)
      high_compressor.zig         setupEncoder + level dispatch
```

The decode side has zero dependencies on the encode side; either can be vendored
independently.

---

## What's missing / incomplete

The port is functionally complete for both compress and decompress at all
levels. The remaining items are public-API surface, one performance
parity tweak, and one thread-dispatch gap.

### 1. L1-L5 parallel decompress

**L1-L4: landed** via a v2 frame-format change (commits `abe348c..37d6263`).
The encoder walks each frame block's LZ-token closure at compress time and
emits a sidecar listing every match op and literal byte whose effect crosses
a sub-chunk boundary (plus guard bytes for `copy64`/`copy16` overcopy at
chunk tails). The decoder reads the sidecar, applies it into `dst` in a
fast phase-1 pass, then dispatches each sub-chunk's Fast decoder on its own
thread in phase 2. Overcopy-corrupted positions are repaired by a second
phase-1 pass after phase-2 workers join.

Sidecar payload uses delta-encoded targets, LEB128 varints, and literal-run
RLE — roughly 5× smaller than the straight record-per-op form. See the
[B1_json benchmark](#v2-parallel-fast-l1-l4-decompress--b1_json-large_100mbjson-926-mb)
above for throughput + correctness.

**L5: still serial.** The lazy chain parser produces ~10× more closure
tokens per block than greedy L1-L4, so an always-on sidecar for L5 would
dominate file size. The likely path is a per-block opt-in trigger that
emits only when sub-chunk cross-references are dense enough to amortize
the sidecar cost — not yet implemented.

**Historical rationale** (still true for L5 and any future v1 content):
serial Fast decompress is already at the per-core ceiling — Arrow Lake
decodes L1 enwik8 at ~6.1 GB/s on a single thread, which is within ~3% of
C#'s parallel result. Parallelizing without a sidecar would require a
phase-1 analysis pass that costs more than the serial decode itself. See
`FailedExperiments.md` "Fast decoder: lookahead prefetch for next match"
and "Fast decoder: branched copy16 for short-token match copy" for cheap
optimizations that were ruled out.

**Status: L1-L4 landed; L5 open.**

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
  prefetch hints turned L9 enwik8 compress from 4.4 → 7.7 MB/s (+70%, beats C#
  by ~25%). L11 is now 4-5× faster than C#. See commit `1423ac0`.
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
`src/decode/cleanness_analyzer.zig`. It walks an `.slz` file's LZ tokens, builds
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

6. **`comptime mode: LiteralMode`** in `fast_lz_decoder.processModeImpl`
   generates two specialized functions (delta-literal vs raw-literal). Zig
   replacement for C#'s `ILiteralMode` interface trick. Unambiguous win for
   branch-free hot loops because there's only one callsite per specialization.

7. **Default build target `x86_64_v3`.** Set in `build.zig` so binaries are
   portable across modern Intel and AMD x86_64 hosts. AVX-512 instructions
   from `-mcpu=native` on Arrow Lake crashed earlier builds on Ryzen 3800x
   with `STATUS_ILLEGAL_INSTRUCTION`.

---

## License

Same as the upstream StreamLZ project (MIT).
