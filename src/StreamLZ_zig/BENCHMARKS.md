# Decompress benchmarks

Intel Ultra 9 285K (Arrow Lake-S), 24 cores, Windows 11.
Zig 0.15.2 `ReleaseFast -Dcpu=native`. C# ReleaseFast via `StreamLZ.Cli -db -r 10`.
**Single-threaded pure decompress** on both sides:

- Zig: `streamlz bench` loads the fixture into memory once, warms up with
  one untimed decode, then takes 30 timed runs via `std.time.Timer`.
  **mean** reported.
- C#: `StreamLZ.Cli -db -r 10`, **median** reported, with
  `StreamLzDecoder.DecompressCore` patched to always call `SerialDecodeLoop`
  (bypassing `DecompressCoreTwoPhase` and `DecompressCoreParallel`) so both
  are decoding on one thread.

## After Phase 7 (`@Vector(16, u8)` / `@Vector(8, u8)` copy helpers)

| fixture | level | decomp size | Zig mean MB/s | C# median MB/s | Zig / C# |
|---|---|---:|---:|---:|---:|
| silesia_all.tar | L1  | 212,797,440 | **6,575** | 6,357 | **1.03×** |
| silesia_all.tar | L5  | 212,797,440 | **5,516** | 5,524 | **1.00×** |
| silesia_all.tar | L9  | 212,797,440 |     925 | 1,192 | 0.78× |
| silesia_all.tar | L11 | 212,797,440 |     862 | 1,220 | 0.71× |
| enwik8.txt      | L1  | 100,000,000 | **6,051** | 5,886 | **1.03×** |
| enwik8.txt      | L5  | 100,000,000 | **4,833** | 4,762 | **1.01×** |
| enwik8.txt      | L9  | 100,000,000 |     564 |   890 | 0.63× |
| enwik8.txt      | L11 | 100,000,000 |     540 |   915 | 0.59× |

### Phase 7 takeaways

1. **L1/L5 (Fast codec): parity with C# single-threaded.** Within 1-3% on
   both fixtures. The `@Vector(16, u8)` × 4 unroll in `copy64Bytes` and the
   load-store-load-store `wildCopy16` hot loop match the C# SSE2 reference.

2. **L9/L11 (High codec): Zig is 0.59-0.78× of C# serial.** Real hot-loop
   optimization gap that needs more work. The C# reference has:
   - `Sse.Prefetch0(matchSource)` N=128 tokens ahead in the execute pass
   - A cascading `Copy64` literal pattern (`if > 8`, `if > 16`, `if > 24`)
     that saves branches on the 80% short-literal case
   - `AggressiveOptimization` on hot methods
   - Type 1's two-phase resolve/execute decouples carousel + length
     resolution from the copy hot loop

3. **enwik8 L9/L11 are the worst** (0.59-0.63×) — highly skewed English
   text stresses the long-match path where prefetch + cascading literal
   copy differences dominate.

## Notes on earlier numbers

The very first baseline in this file mistakenly compared Zig wall-clock
(read + decompress + write) against C#'s pure-decompress `-db`. That
showed a 12× L1 gap that didn't actually exist — both sides compute at
the same rate; the Zig number was dominated by file I/O. The second
update compared Zig `best` against C# `median` (still not apples-to-
apples). The table above uses Zig mean vs C# median, both serial.

## Phase 7b targets (future)

1. **Match-source prefetch** in `high_lz_process_runs.zig` via
   `@prefetch(addr, .read, .moderate_locality, .data)` in the Type 1
   execute pass, ~128 tokens ahead. Expected to close most of the enwik8
   L9 gap.
2. **Cascading literal copy** — replace the straight-line literal loop
   with the `copy64` / `if > 8 copy64` / `if > 16 copy64` pattern from
   the C# `ExecuteTokens_Type1` reference.
3. **`@branchHint(.likely)`** on the short-token path in
   `processLzRunsType0`.

## Phase 13 targets (future)

Parallel decompress brings L6-L8 (SC mode) and L9-L11 (TwoPhase mode)
into scope. On the reference hardware the C# decoder hits ~10 GB/s at
L6-L8 with 24-thread parallel SC, so there's a lot of headroom beyond
the single-threaded numbers above.
