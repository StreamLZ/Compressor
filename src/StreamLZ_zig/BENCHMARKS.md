# Decompress benchmarks

Intel Ultra 9 285K (Arrow Lake-S), 24 cores, Windows 11.
Zig 0.15.2 `ReleaseFast -Dcpu=native`. C# ReleaseFast via `StreamLZ.Cli -db -r 10`.
Single-threaded decompress only. All numbers are pure decompress (no I/O):
`streamlz bench` loads the source into memory once, warms up with one untimed
decode, then takes the best of N timed runs via `std.time.Timer`.

## After Phase 7 (`@Vector(16, u8)` / `@Vector(8, u8)` copy helpers)

| fixture | level | decomp size | Zig best MB/s | C# median MB/s | Zig / C# |
|---|---|---:|---:|---:|---:|
| silesia_all.tar | L1  | 212,797,440 | **6,906** | 6,477 | **1.07×** |
| silesia_all.tar | L5  | 212,797,440 | **5,614** | 5,494 | **1.02×** |
| silesia_all.tar | L9  | 212,797,440 |     932 | 1,593 | 0.58× |
| silesia_all.tar | L11 | 212,797,440 |     872 | 1,212 | 0.72× |
| enwik8.txt      | L1  | 100,000,000 | **6,203** | 5,794 | **1.07×** |
| enwik8.txt      | L5  | 100,000,000 | **4,842** | 4,770 | **1.02×** |
| enwik8.txt      | L9  | 100,000,000 |     574 | 1,821 | 0.32× |
| enwik8.txt      | L11 | 100,000,000 |     552 |   903 | 0.61× |

### Phase 7 takeaways

1. **L1/L5 (Fast codec) are at or ahead of C#.** The `@Vector(16, u8)` ×4
   unroll in `copy64Bytes` and the load-store-load-store `wildCopy16` hot
   loop are enough to match the C# SSE2 reference. The initial 12× gap in
   the first baseline was a measurement artifact — I was including file
   I/O in the Zig wall-clock, while C#'s `-db` reports pure decompress.

2. **L9/L11 (High codec) are at 0.3–0.7×.** This is a genuine optimization
   gap in the High decoder hot loop (`processLzRuns Type1` and the Type0
   delta-literal single-pass). The C# reference uses:
   - `Sse.Prefetch0(matchSource)` N=128 tokens ahead (Phase 7b todo)
   - A cascading `Copy64` literal pattern (unconditional + if > 8 + if > 16)
     that saves branches on the ~80% short-literal case (Phase 7b todo)
   - `AggressiveOptimization` / `SkipLocalsInit` attributes on the hot
     methods (Zig equivalents: `@branchHint`, `@prefetch`, manual unroll)

3. **enwik8 L9 is the worst** at 0.32×. Highly skewed English text hits
   the long-match / long-literal paths more frequently, amplifying the
   cascade-copy and prefetch differences.

## Baseline (before any Phase 7 work — wall-clock including I/O)

Kept for history. These were masked by file I/O and the numbers are not
directly comparable to the section above.

| fixture | level | Zig wall MB/s | C# MB/s |
|---|---|---:|---:|
| silesia_all L1  | 514 | 6,518 |
| silesia_all L5  | 487 | 5,576 |
| silesia_all L9  | 370 | 1,593 |
| silesia_all L11 | 349 | 1,218 |
| enwik8 L1       | 416 | 5,931 |
| enwik8 L5       | 484 | 4,874 |
| enwik8 L9       | 291 | 1,845 |
| enwik8 L11      | 283 |   921 |

## Phase 7b targets (future)

1. **Match-source prefetch** in `high_lz_process_runs.zig` — add
   `@prefetch(match_src_ahead, .read, .low_locality)` at token N+128 in the
   execute pass. Should land most of the enwik8 L9 gap.
2. **Cascading literal copy** — replace the straight-line literal loop
   with the short-case-unrolled pattern from `ExecuteTokens_Type1` in the
   C# reference.
3. **`@branchHint(.likely)`** on the short-token path in `processLzRunsType0`
   to push the I-cache weight onto the common case.
