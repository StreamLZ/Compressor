# Failed Experiments

This document catalogs optimization attempts that did not pan out. Recording
what *didn't* work is as valuable as recording what did — it prevents future
contributors from re-investigating dead ends, and documents the reasoning
behind why certain approaches were rejected.

## Guiding Priorities

StreamLZ prioritizes, in order:

1. **Decompress speed** — the dominant use case. An extra 10% compress time is
   usually invisible; an extra 10% decompress time is always felt.
2. **Compression ratio** — users of L6+ explicitly chose higher ratio over speed.
   A 0.1pp ratio loss for a 10% compress speedup is generally not worth it.
3. **Compress speed** — important but not at the expense of ratio or decomp.

Experiments are evaluated against these priorities. A "neutral" result on
decompress speed and ratio means the change isn't worth merging even if it
improves compress speed.

---

## zstd-inspired BT4 Optimizations (2026-04-09)

After reviewing the zstd BT4 implementation (`lib/compress/zstd_opt.c` and
`zstd_lazy.c`), we identified seven differences from our BT4 match finder and
tested each. **None produced a net win.**

### Test methodology

For each change:
- Run unit tests (392 tests must pass)
- Benchmark L8 on enwik9 (1 GB text)
- Benchmark L8 on silesia_all.tar (212 MB mixed)
- Benchmark L11 on silesia_all.tar (highest-ratio, non-SC path)
- Compare byte counts (not just percentages) to detect sub-percent changes
- Compress speed matters less than ratio/decomp speed per our priorities

### Baselines (v1.4.0, BT4 unchanged)

| Test | Ratio | Compress | Decompress |
|------|-------|----------|------------|
| L8 enwik9 | 27.3% (272,661,464) | 27.2 MB/s | 10,445 MB/s |
| L8 silesia | 26.3% (55,937,491) | 24.2 MB/s | 8,481 MB/s |
| L11 silesia | 24.2% (51,495,905) | 3.0 MB/s | 1,325 MB/s |

### Experiment #5: Hash finalization — shift instead of rotate

**Change:** Replace `RotateLeft(hash * 0x9E3779B9, 16) & mask` with
`(hash * 0x9E3779B9) >> (32 - bits)`. This is Knuth's standard multiplicative
hash finalization and is what zstd uses.

**Rationale:** Right-shift preserves the highest-entropy bits from the multiply;
rotate-and-mask is slightly worse for smaller hash table sizes.

**Result:** Neutral.

| Test | Ratio | Compress | Decompress |
|------|-------|----------|------------|
| L8 enwik9 | 27.3% (272,660,578) | 27.5 MB/s | 10,770 MB/s |
| L8 silesia | 26.3% (55,936,690) | 24.3 MB/s | 8,030 MB/s |
| L11 silesia | 24.2% (51,497,907) | 3.1 MB/s | 1,339 MB/s |

**Analysis:** Byte counts differ by ~1KB (different hash distribution finds
marginally different matches), but the ratio rounds to the same percentage.
Speed is within noise. The tree walk dominates — entry point hash quality
doesn't matter much once you're walking ordered nodes.

### Experiment #1: Cyclic tree buffer

**Change:** Cap tree size to `1 << MaxBtLog` entries and access via `pos & btMask`.
Add `btLow = pos - btSize + 1` cutoff to stop searches at recycled slots.
Tested at `MaxBtLog = 22` (4M entries) and `24` (16M entries).

**Rationale:** zstd uses a cyclic buffer sized to the window. For large inputs,
our `new int[srcSize+1]` for left/right arrays uses significantly more memory
than needed (for enwik9 L11: ~512MB for tree arrays).

**Result:** Bad for ratio. Reverted.

| Test | MaxBtLog=22 | MaxBtLog=24 | Baseline |
|------|-------------|-------------|----------|
| L11 silesia ratio | 24.6% | 24.3% | 24.2% |
| L11 silesia compress | 4.5 MB/s | 3.4 MB/s | 3.0 MB/s |

**Analysis:** Compress is faster (smaller tree = better cache locality), but
ratio regresses. L11 genuinely benefits from the full 64MB dictionary — any
window cap less than that loses real matches. For L8 SC (1MB groups), the tree
is already small and cyclic doesn't help. There's no window size that helps L11
without hurting ratio.

### Experiment #4: Raise long match skip threshold (77 → 192)

**Change:** Only trigger the stride-4 skip for matches ≥192 bytes instead of ≥77.

**Rationale:** zstd's threshold is 384. At 77, we may be prematurely skipping
positions where the tree would find distinct better matches.

**Result:** Marginal ratio gain, compress slowdown, decomp unchanged.

| Test | Ratio delta | Compress delta | Decomp delta |
|------|-------------|----------------|--------------|
| L8 enwik9 | −226KB (−0.08%) | −6% | +1% (noise) |
| L11 silesia | −127KB (−0.25%) | 0% | +1.5% (noise) |

**Analysis:** The ratio improvement is real but tiny (0.08% on L8 enwik9). The
L8 compress regression is larger in magnitude than the ratio gain. Decomp
unchanged because match finder choices don't affect the decoder. Not worth it
given our priorities. **Stashed for potential future tuning** if we find a
sweet spot between 77 and 192 that doesn't cost compress speed.

### Experiment #2: Offset-aware match replacement

**Change:** When the 4-slot match buffer is full, replace using a score of
`length * 4 - log2(offset)` instead of just replacing the shortest match.
A longer match must be ~4 bytes longer per doubling of offset distance to
justify keeping it over a closer, shorter match.

**Rationale:** zstd uses this heuristic in `ZSTD_DUBT_findBestMatch` — shorter
offsets encode cheaper, so match selection should prefer them at equal length.

**Result:** Neutral.

| Test | Ratio delta | Compress delta |
|------|-------------|----------------|
| L8 enwik9 | −6.6KB (noise) | 0% |
| L11 silesia | −4.6KB (noise) | +7% |

**Analysis:** Our optimal parser already accounts for offset cost when
selecting matches. Pre-filtering at the match finder level doesn't give the
parser new information — it just limits what the parser can see, and the parser
was doing the right thing with the unfiltered set.

### Experiment #3: matchEndIdx position skipping

**Change:** Track the farthest endpoint of any match found. For positions
between `pos+1` and `matchEndIdx - 8`, do insert-only at `maxDepth/4` instead
of a full search+insert.

**Rationale:** zstd uses `nextToUpdate` skipping based on match endpoints to
avoid re-searching positions already covered by known matches.

**Result:** Bad for ratio. Reverted.

| Test | Ratio | Compress delta |
|------|-------|----------------|
| L8 enwik9 | 28.0% (was 27.3%) | +10% |
| L11 silesia | 25.4% (was 24.2%) | +17% |

**Analysis:** The "covered" positions still benefit from having their own
match sets. Skipping them loses matches that the optimal parser would have used
to find better parses. +0.7-1.2pp ratio regression is unacceptable.

### Experiment #6: DUBT deferred sorting (simplified)

**Change:** Reduce the `maxDepth` passed to `BT4InsertOnly` to 2 (from the
normal 96-128), making preload and long-match-skip inserts very cheap.

**Rationale:** zstd's DUBT (Deferred Unsorted Binary Tree) inserts catch-up
positions with chain-like O(1) inserts and sorts them on-demand during search.
The full DUBT is complex; we tested a simplified approximation.

**Result:** Bad for ratio. Reverted.

| Test | Ratio | Compress delta |
|------|-------|----------------|
| L8 enwik9 | 27.4% (was 27.3%) | +6% |
| L11 silesia | 24.5% (was 24.2%) | +30% |

**Analysis:** Shallow inserts degrade the tree's structural quality. Later
search walks encounter poorly-ordered nodes and can't find matches that a
well-maintained tree would have surfaced. The full DUBT algorithm avoids this
by sorting on-demand, but implementing that correctly is significant complexity.

### Experiment #7: Branch prediction (not implemented)

**Rationale:** zstd has a compile-time option `ZSTD_C_PREDICT` that uses the
previous position's tree children to predict branch direction and skip the
first match extension. It is **disabled by default** in zstd.

**Decision:** Not implemented. zstd's own developers don't think it's worth
enabling, and we already have SSE prefetch which addresses the cache-miss
pain point at tree nodes.

---

## Conclusions from the zstd Experiment

1. **Our BT4 is already well-tuned** for our use case. No easy wins were
   available by copying zstd's choices.

2. **Different priorities lead to different designs.** zstd's optimizations
   that trade ratio for speed (#1, #3, #6) all fail our test because L8/L11
   users explicitly chose ratio over speed.

3. **The optimal parser makes match-finder-level filtering less impactful**
   (#2). Our parser already handles offset cost, so pre-filtering at the
   finder level doesn't help.

4. **Aggressive skip heuristics are traps.** (#3 matchEndIdx, #6 DUBT-lite)
   Tree quality needs to be maintained globally; shortcuts at preload or
   "covered" positions degrade later searches in non-obvious ways.

5. **None of these experiments could have improved decompress speed** —
   match finder changes only affect encoder decisions. Decompress speed
   improvements come from the decoder, the wire format, or parallelism
   (like the SC chunk grouping in v1.4.0 which took L6 enwik9 decomp from
   5.1 GB/s to 10.7 GB/s).

---

## Other Historical Failed Experiments

### Decode-cost penalties (2026-03)

**Attempted:** Added `DecodeCostPerToken`, `DecodeCostSmallOffset`,
`DecodeCostShortMatch` fields to `CostModel` and wired them into
`BitsForToken`/`BitsForOffset`. The idea was to penalize token/offset choices
that slow down the decoder, letting the compressor trade a bit of ratio for
faster decompression.

**Result:** No benefit. The BT4-induced decompress slowdown at L8/L11 comes
from higher entropy density (more bits per compressed byte), not from
specific token choices. No weighting of the penalty fields produced a
meaningful decompress speedup.

**Disposition:** Infrastructure left in place with zero weights. Could be
revisited if a better cost model emerges.

### CRC32C hash experiment

**Attempted:** Replace the Fibonacci multiply (`hash * 0x9E3779B9`) with
`Sse42.Crc32(0, value)` in the match hasher.

**Result:** Crashed. Hash value distribution and index extraction are tightly
coupled in the existing hasher — swapping the hash function breaks downstream
assumptions about which bits are entropy-rich.

**Disposition:** Reverted. Not worth the refactor for an uncertain gain.

### WASM HLZ bitreader refactor

**Attempted:** Convert 183 bitreader-related local variable references in the
WASM HLZ decoder to use explicit memory operations at fixed offsets, aiming
to simplify register allocation and reduce WAT file size.

**Result:** Address collision at 0xD4-0xE4 (save area overlapped new bitreader
state), and four additional refill blocks (rA4/rA5/rB4/rB5) were missed
during the mechanical conversion. The refactor produced incorrect output.

**Disposition:** Rolled back. The existing local-variable-based bitreader is
harder to read but correct.

### BT4 for L6-L7

**Attempted:** Use BT4 match finder at L6 and L7 (in addition to L8 where it
currently ships).

**Result:** BT4 finds more and longer matches, but ratio at L6-L7 did not
improve proportionally because the parser at those levels is too narrow
(fewer state widths, fewer literal run trials) to fully exploit the richer
match set. Decompress slowed down due to higher entropy density without a
ratio win to justify it.

**Disposition:** L6-L7 stayed on the hash-based match finder. BT4 is only
wired in at L8 (SC) and L11 (non-SC).

---

## Decompress Profiling Experiments (2026-04-10)

After profiling L11 decompress with dotnet-trace, we identified hotspots and
tested six micro-optimizations. Three were committed (+66% L11 decompress),
three were rejected.

### What worked (committed)

1. **Remove scratch buffer zeroing (+31%)** — The scratch buffer was zeroed
   before each chunk decode, but the decoder always overwrites it first.
   884KB × 381 chunks = 337MB of wasted writes per enwik8 L11 decompress.

2. **Dual cache-line prefetch (+18%)** — The existing single-line prefetch
   missed when matches spanned a cache line boundary. Adding `Prefetch0(addr+64)`
   warms the second line.

3. **Eliminate O(n) litLen sum loop (+7%)** — `ProcessLzRuns_Type1` ran a
   second pass over all tokens to sum literal lengths and advance `litStream`.
   Changed `ExecuteTokens_Type1` to take `ref byte* litStream` and write back
   the advanced pointer directly.

### What was tried and rejected

#### PrefetchNonTemporal for match source

**Change:** Replace `Sse.Prefetch0` with `Sse.PrefetchNonTemporal` for match
source prefetch, since match data is used once then discarded.

**Result:** -20% regression (1307 → 1045 MB/s). NTA bypasses L1, but the
match copy immediately needs the data in L1. Prefetch0 is correct.

#### Prefetch1 (L2-only) for match source

**Change:** Replace `Sse.Prefetch0` with `Sse.Prefetch1`.

**Result:** Neutral (1284 vs 1307 MB/s, within noise). L2 prefetch is slightly
worse than L1 but not significantly. No benefit over Prefetch0.

#### Triple cache-line prefetch

**Change:** Prefetch three lines (+0, +64, +128) instead of two.

**Result:** -7% regression (1541 → 1424 MB/s). The third line is almost always
wasted (few matches exceed 128 bytes), and the extra prefetch instruction
competes with useful work.

#### Dual-distance prefetch (i+128 and i+256)

**Change:** Issue a `Prefetch0` at `PrefetchAhead` (128) and a second
`Prefetch1` at `2*PrefetchAhead` (256) to warm data even earlier.

**Result:** -15% regression (1541 → 1107 MB/s). Too much prefetch traffic.
The memory subsystem is oversaturated with speculative loads.

#### Vector128 match copy with offset branch

**Change:** Use a single `Vector128.Load`/`Store` (16 bytes) for matches
with `offset <= -16`, falling back to two `Copy64` calls for small offsets
(8-15) where the copy would alias.

**Result:** -3% regression (1307 → 1272 MB/s). The added branch cost more
than the unified load/store saved. The JIT likely already fuses the two
`Copy64` calls into efficient code.

#### Precomputed PrefetchDelta in token struct

**Change:** Add a 5th field `PrefetchDelta = DstPos + LitLen + Offset` to
the `LzToken` struct (16→20 bytes). Saves 2 loads + 2 adds per iteration
in the prefetch computation.

**Result:** L11 enwik8 +2% (1541 → 1574 MB/s), but L8 enwik9 -6% (10441 →
9798 MB/s). The larger token struct (25% more memory) hurts the
bandwidth-sensitive L8 path more than the reduced arithmetic helps L11.

**Disposition:** Reverted. L8 regression outweighs L11 gain.

#### Removing bounds check in ExecuteTokens_Type1

**Change:** Remove `if (matchSource < dstStart) return false` from the
hot loop — the branch is always correctly predicted on valid data.

**Result:** Identical speed (1307 → 1288 MB/s, noise). The branch predictor
handles this at 100% accuracy, so removing it saves zero cycles. The check
is effectively free.

**Disposition:** Kept for safety — protects against corrupt input at no cost.
