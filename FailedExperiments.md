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

#### Branchless match length resolve in ResolveTokens

**Change:** Replace `if (matchLength != 15)` branch with speculative read +
conditional move, matching the pattern already used for literal lengths.

**Result:** -3% regression (1648 → 1593 MB/s). The `matchLength == 15` branch
is well-predicted (long matches are rare, ~5% of tokens), so it's effectively
free. The speculative read adds overhead (unconditional `*lenStream` load)
without saving mispredictions.

**Disposition:** Reverted. Only unpredictable branches benefit from branchless
conversion. Well-predicted branches (>90% one direction) are free.

#### Fast decoder offset bounds check removal

**Change:** Remove `if (dst + recentOffs < dstStart) return null` from the
Fast decoder's short token path.

**Result:** +1% (noise). Unlike the `dst >= dstEnd` check which was poorly
predicted (variable dst advance), the offset check is well-predicted (always
passes on valid data).

**Disposition:** Kept for safety.

#### Move off32Stream/off32StreamEnd to FastLzTable struct

**Change:** Read off32Stream and off32StreamEnd from `lz->` struct pointer
in medium/long paths instead of caching in local variables, hoping to free
two registers for the short-token hot path.

**Result:** No change in ASM. JIT disasm confirmed the JIT was already NOT
keeping off32 in registers during the short token path — it was already
spilling them to the stack. Moving to the struct just relocated the spill.
The newDist spill (`[rsp+0x08]`) and dstSafeEnd-on-stack remained identical.

**Disposition:** Reverted. JIT register allocator was already optimal for
these values.

#### Remove off32 prefetch to reduce register pressure

**Change:** Remove `Sse.Prefetch0(dstBegin - off32Stream[3])` from
medium/long match paths, hoping that eliminating the `off32Stream[3]`
read would let the JIT free the off32Stream register sooner.

**Result:** Made things worse. JIT disasm showed a NEW dstStart spill
(`mov [rsp+0x88], r9`) at the short token entry that didn't exist before.
Code grew from 1025 to 1047 bytes. The JIT's global register allocator
reshuffled in a suboptimal way when the prefetch constraint was removed.

**Disposition:** Reverted. The off32 prefetch was actually helping the
register allocator find a better allocation by constraining its choices.

---

## Zig L9 decompress micro-optimizations (2026-04-14)

After the big wins (`c_allocator` for token fallback, register-resident
recent-offset LIFO, 16-byte SIMD literal copies, prefetch-safe + tail
loop split) brought Zig L9 100MB enwik8 decompress from 868 → 2143 MB/s
(beating C# 1850 by ~16%), we tried these incremental tweaks looking for
more. **None of them moved the needle.**

VTune was the tool throughout — Hotspots collection at 1000 Hz,
function-level CPU breakdown, and source/asm view for register
allocation analysis.

### ❌ Token cursor refactor

**Change:** Replace `tokens[token_index] = ...; token_index += 1;` with
`tokens_cur[0] = ...; tokens_cur += 1;` and compute the count via
pointer subtraction at return. Hypothesis: removes the separate index
counter that VTune saw spilled to stack as `[rbp]`.

**Result:** ~2111 MB/s mean (vs ~2143 baseline) — **slight regression**
within noise. VTune disasm showed LLVM **still** spilled an internal
byte-offset counter to `[rbp]` after the refactor. The compiler's
canonicalization defeated the source change.

**Lesson:** "use a pointer instead of an index" doesn't translate to
register-level savings when the function has many other live values.
The compiler decides where to spill, not the source.

### ❌ SIMD `@shuffle` to pack ros into one XMM (table version)

**Change:** Hold `ro3`, `ro4`, `ro5`, `new_off` in a single
`@Vector(4, i32)` and do the LIFO shuffle as one `@shuffle` with a
per-`oi` mask indexed from a comptime table.

**Result:** **Did not compile** — Zig 0.15 requires the `@shuffle` mask
to be `comptime`-known. Runtime mask indexing is not supported.

### ❌ Comptime PSHUFD switch (4 cases, one mask per case)

**Change:** Workaround for the previous failure: use a 4-case
`switch (offset_index)` where each case has its own comptime mask:
```zig
ro_vec = switch (offset_index) {
    0 => @shuffle(i32, ro_with_new, undefined, [_]i32{ 0, 1, 2, 0 }),
    1 => @shuffle(i32, ro_with_new, undefined, [_]i32{ 1, 0, 2, 0 }),
    2 => @shuffle(i32, ro_with_new, undefined, [_]i32{ 2, 0, 1, 0 }),
    else => @shuffle(i32, ro_with_new, undefined, [_]i32{ 3, 0, 1, 0 }),
};
const picked: i32 = ro_vec[0];
```

**Result:** ~2039 MB/s mean (vs ~2143 baseline) — **regression of ~5%**.
Roundtrip valid. The XMM lane extract (`ro_vec[0]`) plus the case
dispatch overhead (each case is a separate basic block branched into)
beat out the GPR savings.

**Why:** The 4-case switch over an XMM-producing branch generates
something close to a jump table on XMM operands. Picking the resulting
`picked` requires a `MOVD r32, xmm` extract which is ~3-cycle latency.
Vs the CMOV chain which is ~3-4 cycles of integer dependency. The
shuffle path adds latency without removing any.

**Lesson:** SIMD only wins when the data flows through the vector unit
for multiple operations. If you immediately extract back to GPR (as we
do for `picked`, which then feeds the integer LzToken store), the
GPR↔XMM transit eats the savings. SIMD shuffles want to stay in the
vector unit end-to-end.

**Workarounds (not yet tried):**
- Inline assembly to emit `PSHUFB` directly (escapes Zig's type system,
  unclear if the integer↔XMM transit can be avoided)

### ❌ Conditional 16-byte SIMD copy for Fast short-token match (L1/L5)

**Context:** VTune Hotspots on L1 100 MB enwik8 showed `writeInt`
(inlined into `copy64`) at ~63% of CPU — same dominant pattern as the
L9 path before we switched it to `copy16`. The L9 fix yielded +3%
wall-time. We hoped the same trick would help L1/L5.

**Hypothesis:** Replace the 2× `copy64` (16 bytes via 8-byte stores) in
the short-token match copy with 1× `copy16` (16 bytes via SIMD store).
The SIMD load is atomic, so we need offset ≥ 16 to avoid reading the
not-yet-written destination region. Branch on offset:

```zig
if (recent_offs <= -16) {  // back-distance >= 16, safe
    @branchHint(.likely);
    copy.copy16(dst, match_ptr);
} else {
    copy.copy64(dst, match_ptr);
    copy.copy64(dst + 8, match_ptr + 8);
}
```

**Result:** ~3% regression on L1 (6132 → 5950 MB/s) and similar on L5.

**Why VTune showed `writeInt` collapse but wall time got slower:**
- VTune confirmed `writeInt` time dropped from ~683ms → ~46ms (-93%).
- A new hotspot `storeV16` appeared at ~139ms (the SIMD store from
  `copy16`).
- Total CPU time dropped, but wall time got slightly worse.

Best explanation: the per-token branch cost (~1-2 cycles for the
compare + conditional jump) exactly offsets the per-token uop savings
(2 µops fewer per token from the wider store), AND the additional code
in the inner loop body increases DSB / icache pressure, slightly
hurting steady-state IPC.

**Lesson:** A profiler showing a hotspot collapse doesn't mean the
total time will improve. The new code path has its own overhead, and
in tight inner loops the branch cost competes directly with the
instruction savings. This is different from the L9 case where the
inner loop already had MORE branches (the conditional on lit_len > 8
etc.) so adding one more was relatively cheaper.

**Workaround (not tried):** Split the Fast decoder into two
specialized variants (one for streams known to have all offsets >= 16,
one for the general case) selected by a per-block flag set by the
encoder. Adds encoder complexity for a small expected gain.

**Disposition:** Reverted. L1-L5 stay at C# parity (within ±1% on the
regression benchmark), which is the goal anyway.

### ❌ 16-byte SIMD copies for Fast medium-match path (L5)

**Context:** After fixing L1 (lazy pool, +10%) and L6-L8 (SC scratch
bump, +185%), L5 was the only remaining level still slightly slower
than C# (-2%, ~4860 vs 4978 MB/s).

**Hypothesis:** L5 spends ~11% of CPU in the medium match branch
(`cmd > 2 && cmd < 24`) which uses 4× `copy64` (32 bytes via 4 8-byte
copies). Far offsets (from `off32_stream`) are always large → no
overlap concerns → safe to use 2× `copy16` (16-byte SIMD).

**Result:** L5 slightly **slower** (~4770 vs 4860 baseline). Even
though the medium-match copy itself was halved in instruction count,
the surrounding code (bounds checks, register allocation in the hot
loop) reorganized in a way that hurt the SHORT TOKEN path which is
~80% of CPU.

**Lesson:** Optimizing a cold path (11% of CPU) can hurt the hot path
through unintended register-allocation interactions. Profile after every
change — don't trust that "less code in branch X = faster overall."

**Disposition:** Reverted. L5 stays ~2% slower than C# (essentially
noise). All other levels (L1, L6-L11) match or beat C#.

### ❌ Pack `ro4` || `ro5` into a single `u64`

**Change:**
```zig
var ro45: u64 = (@as(u64, init_u32) << 32) | @as(u64, init_u32);
// per iter:
const ro4: i32 = @bitCast(@as(u32, @truncate(ro45)));
const ro5: i32 = @bitCast(@as(u32, @truncate(ro45 >> 32)));
// ... compute next_ro4, next_ro5 ...
ro45 = (@as(u64, @as(u32, @bitCast(next_ro5))) << 32) |
       @as(u64, @as(u32, @bitCast(next_ro4)));
```

Hypothesis: frees one GPR vs three separate i32 locals; the pack/unpack
via shifts is cheap.

**Result:** ~2121 MB/s mean (vs ~2143 baseline) — **slightly slower**.
The truncate/shift/or per iteration cost more than the GPR savings.
The CMOV chain was already working with 3 GPRs without spills, so
freeing one didn't help downstream.

**Lesson:** Pack-into-wider-int wins only when the loop is genuinely
register-pressured AND the unpack cost is amortized across many uses.
Reading each ro once per iteration means the unpack cost happens every
iteration with no amortization.

### ❌ 2× manual loop unroll for ILP

**Change:** Process two cmd bytes per loop iteration. Each token's body
kept intact (preserving `len_stream` and `offs_stream` consumption order)
but two of them per iteration. Hypothesis: the compiler can schedule the
two independent token bodies at IPC > 1 even though the recent-offset
LIFO update is serially dependent across iterations.

**Subtle bug on first attempt:** re-ordering `len_stream` reads across
the two tokens (e.g., reading `spec_long_b` before `aml_a` may have
advanced `len_stream`) caused `StreamMismatch` errors. Fix: process each
token's full body before starting the next.

**Result:** ~2055 MB/s mean (vs ~2143 baseline) — **regression of ~4%**.
Why:
1. The unrolled body is ~2× larger → falls out of the DSB (decoded uop
   cache, ~4K uops on Arrow Lake), forced into the legacy decoder.
2. Doubled register pressure → more spills.
3. The serial dep chain on the ros wasn't actually breakable — token B's
   pick still waits on token A's LIFO update.

**Lesson:** Manual unrolling helps when the loop body is small and the
dep chain is breakable. Ours is complex and serial — the CPU was already
doing as much OoO scheduling as it could.

### ❌ Bumping `scratch_per_chunk` to fit worst-case token array

**Change:** Increase per-worker scratch from `884 KB` (`scratch_size * 2`)
to `1.9 MB` (`scratch_size * 2 + 1 MB`) so the token array always fits
without falling back to the heap. Goal: eliminate the ~4% CPU spent in
libc `free_base` for the c_allocator fallback path.

**Result:** Total throughput **dropped from ~2143 to ~1985 MB/s (-7%)**.
VTune showed `executeTokensType1` went from 0.372s → 0.549s (+48%) due
to **L3 cache misses on the token reads**.

**Why:** scratch is allocated per worker, and we have 24 workers.
- Old: 24 × 884 KB = **21 MB** → fits comfortably in 36 MB L3
- New: 24 × 1.9 MB = **46 MB** → **overflows L3 by 28%**

Token reads from each worker's scratch went L3 → DRAM. The cache penalty
overwhelmed the 4% saved on `free_base`.

**Lesson:** Per-worker memory bumps must be evaluated against
**total L3** (`worker_count × per_worker_size`), not just per-worker
L1/L2. On a 24-core system, even 1 MB of per-worker overhead times 24 =
24 MB which is most of L3.

### Tweaks that compiled but didn't measurably move the needle

These are kept in the code (committed in `2055c2a`) because they make
the asm cleaner / safer even though wall-time was unchanged within noise:

1. **CMOV-chain rewrite of `switch (offset_index)` for `picked`.** The
   original compiled to a jump table with `jmp rbx` + a stack spill of
   one of the ros. The if-chain version emits `cmovb`/`cmovs`/`cmovnb`
   with no spills. Wall time unchanged because the BTB was predicting
   the indirect jump well.

2. **Branchless `offs_stream` advance** (`(oi + 1) & 4`). VTune flagged
   the `if (oi == 3) offs_stream += 1` branch at ~11% of `resolveTokens`.
   Replacing it with the bitmask advance produced cleaner asm. Wall time
   unchanged because LLVM was already CMOV-ing the original branch.

3. **`@branchHint(.unlikely / .likely / .cold)`** on the long-literal,
   long-match, and bounds-check paths. Improved code layout (cold paths
   moved out of hot region) but no measurable speedup.

4. **`std.debug.assert(offset_index <= 3)`**. Meant to tell LLVM the
   value is in {0,1,2,3}. LLVM was already inferring this from the
   `u8 → u32` widening on `cmd_stream[0]`. No measurable change.

### Things tried but not yet proven (worth revisiting)

- **Inline asm `PSHUFB` for ro shuffle**: bypass Zig's `@shuffle`
  comptime restriction and use SSSE3's runtime byte-shuffle directly.
  Could free 3 GPRs (ros → 1 XMM register). The expected win is small
  given the current asm is already CMOV-clean, but worth keeping in
  mind if more pressure shows up.

- **Two-tier ro storage** (small i16 fast path + i32 escape for large):
  empirically most LZ offsets in text are < 16 bits. Could pack 3 i16
  ros into one u64 with a flag bit per slot indicating "this slot needs
  a separate i32 escape word." Adds complexity. Worth it only if the
  fast path is taken > 95% of the time.

- **Vectorized cmd_stream parser**: process N command bytes at once
  with SSE/AVX2 bit ops to extract the lit_len/oi/match_len fields in
  parallel. Then sequentially apply the LIFO updates. Could give a 2-4×
  speedup on the decode portion if doable.

- **AVX-512 `VPCOMPRESSD` / mask registers**: would help with branchless
  variable-length decode. **Not available on Arrow Lake** — Intel
  disabled AVX-512 on consumer Core Ultra chips (E-cores can't do it).
  Don't waste time exploring this path on consumer CPUs.

### Cache geometry reference (Intel Core Ultra 9 285K, Arrow Lake-S)

For future scratch-sizing / data-layout decisions:

| Level | Size | Per | Notes |
|---|---|---|---|
| L1d | 48 KB | per P-core | 12-way; covers ~768 cache lines |
| L1i | 32 KB | per P-core | 8-way |
| L2 | 2.5 MB | per P-core | DSB caches ~4K uops on top of this |
| L3 | 36 MB | shared by all 24 cores | the per-worker scratch sum lives here |
| DRAM | 32+ GB | host RAM | hundreds of cycles latency |

**Per-worker scratch budget rule of thumb**: `worker_count × per_worker_size
≤ L3 / 2` (leaving room for other working sets). For 24 workers and 36 MB
L3, that's ~750 KB per worker max. The current 884 KB is right at the
edge; the bumped 1.9 MB blew through it.

---

## Encoder: thread-local cached MatchHasher16Dual (High-codec L9-L11)

**Hypothesis**: `findMatchesHashBased` allocates a fresh 64 MB hash table
(`MatchHasher16Dual`) on every call via `alignedAlloc` + the hasher
resets via `@memset` on init. VTune showed ~150 ms/call in page-fault /
zeroing paths. Reusing the table across calls via a `threadlocal var`
with lazy init should cut that out entirely.

**What we tried**:
1. `threadlocal var cached_hasher: ?MatchHasher16Dual = null` + lazy init
   on first call, reset bit-width on reuse, `@memset` the table to 0.
   Result: **7.2 MB/s vs 7.5 MB/s baseline** (-4%).
2. Skip the `@memset` on reuse (the hasher's internal generation counter
   was supposed to invalidate stale entries — it doesn't, stale positions
   leak through). Result: **7.1 MB/s** AND corrupted output.

**Root cause**: On Windows, `VirtualAlloc` for a large buffer returns
demand-zero pages. The OS zeroes pages lazily on first touch, spreading
the cost across the compress loop's natural cache-miss latency. An
explicit `@memset` of a reused 64 MB buffer must traverse every cache
line up-front, stalling on DRAM writes, and it pollutes L3 before the
compress loop needs it. The "free" alloc was already cheaper than any
reuse strategy that needs to clear.

**Takeaway**: Don't reuse large scratch buffers on Windows without
benchmarking. `VirtualAlloc` + demand-zero is already an optimized
"amortized zeroing" path the OS provides for free. On Linux/glibc this
might look different (malloc pools reuse dirty memory), but on Win32 the
allocator's default behavior beats manual pooling for buffers > L3.

Reverted to `var hasher = try MatchHasher16Dual.init(allocator, bits, 0);
defer hasher.deinit();` on every call.

---

## Fast decoder: branched copy16 for short-token match copy

**Hypothesis**: The short-token hot loop emits 2× `copy64` (8-byte mov
pairs) for the match copy = 2 store uops per iteration. Replacing with
1× `copy16` (SSE MOVDQU) when `distance >= 16`, falling back to the
2× `copy64` cascade when `distance in [8,15]` (encoder min offset is 8),
would cut 1 store uop per iteration on the common path. With
store-throughput at ~1.5/cycle on Arrow Lake and 3 stores/iter, the
theoretical minimum is 2 cycles/iter — we observed 2.4, so ~20% left
on the table if we can eliminate one store.

**What we tried**:
```zig
if (@intFromPtr(dst) - @intFromPtr(match_ptr) >= 16) {
    copy.copy16(dst, match_ptr);
} else {
    copy.copy64(dst, match_ptr);
    copy.copy64(dst + 8, match_ptr + 8);
}
```

L3 bench enwik8 (50 runs):
- Baseline (2× copy64): 5923 best / 5730 mean MB/s
- Branched:             5664 best / 5540 mean MB/s  (**-3.3% mean**)

**Why it regressed**: The branch introduces `sub` + `cmp` + `jae` = 3
extra uops per iteration (on the hot path), offsetting the 1 store uop
saved. And the branch mispredicts whenever the distance distribution
shifts across chunks (file-dependent), adding ~10-cycle pipeline
flushes.

**The theoretical lever is real** (we are close to store-throughput
bound), but you can't get it via a dynamic branch on `distance`. To
actually collapse 2 stores into 1 would need either:
  (a) statically prove distance is always ≥ 16 for this path (encoder
      guarantee — not currently true, min is 8)
  (b) use PSHUFB-based pattern replication for the small-offset case,
      making copy16 always safe (LZ4-style repeat-byte table)

Option (b) is the standard trick but requires a mask lookup table and
one PSHUFB per short-token iter — more complex than the branch, may or
may not pay off on Arrow Lake. Not pursued in this session.

Also tried an unconditional `copy16` for the long-match 16-bit offset
loop (assumed min offset was larger). **Produced wrong output** — the
encoder does emit offsets in [8,15] on this path. Reverted. Keep the
2× copy64 cascade.

---

## Fast decoder: lookahead prefetch for next match

**Hypothesis**: VTune showed the short-token hot loop retiring at the
first match store (2.94s out of 6.5s total wall, ~45% of samples). The
store was parking there because it's waiting on the match *load*, which
is the only random-access load in the loop. A software prefetch of the
next iteration's match address — computed at the end of the current
iteration from a peek at `cmd_stream[0]` + `off16_stream[0]` — should
turn some L2/L3 stalls into L1 hits.

**What we tried**:
```zig
// at the tail of the short-token branch
if (@intFromPtr(cmd_stream) != @intFromPtr(cmd_stream_end)) {
    const peek_cmd: u32 = cmd_stream[0];
    const peek_new_dist: i64 = off16_stream[0];
    const peek_offs: i64 = if ((peek_cmd & 0x80) == 0)
        -peek_new_dist else recent_offs;
    const peek_addr: usize = @intFromPtr(dst) +% @as(usize, @bitCast(peek_offs));
    @prefetch(@as([*]const u8, @ptrFromInt(peek_addr)),
              .{ .rw = .read, .locality = 3 });
}
```

L3 bench enwik8 (100 runs):
- Baseline: 5888 best / 5745 mean
- With prefetch: **5328 best / 5200 mean** (−10%)

**Why it regressed**: Three culprits, all adding uops to a hot loop
that was already within ~20% of the theoretical frontend/store-port
ceiling.
1. The peek `cmd_stream[0]` and `off16_stream[0]` loads consume two
   load-port slots each iteration, even though they usually hit L1.
2. The `if (cmd_stream != cmd_stream_end)` guard mispredicts on the
   final iteration of each chunk (the branch direction flips once).
3. `@prefetch` itself is 1 uop on Arrow Lake (issues via the load
   port), adding throughput pressure.

Net uop add ≈ 6-8 per iteration. The hot loop was ~25 uops
pre-prefetch, so 25 → 32 uops is a 28% frontend-dispatch increase.
The L1/L2 hit conversion (~20% of match loads that *weren't* already
hot) doesn't recover that overhead.

**Takeaway**: Software prefetch only pays in loops that are
*memory-bound with idle frontend slots*. This decoder is
frontend/store-port-bound, so adding prefetch uops makes it slower, not
faster. To confirm the bottleneck, we'd need `vtune -collect
uarch-exploration` (needs admin) for the Top-Down breakdown — the
current `hotspots` PC sampling can't distinguish "parked waiting on
memory" from "parked waiting on dispatch slot."

Kept the match copy as 2× `copy64`.

---

## Fast decoder: `@prefetch` in medium-match / cmd==2 long-match paths (C1 parity)

**Date**: 2026-04-17

**What**: Added `@prefetch(dst_begin - off32_stream[3], .{.rw = .read, .locality = 3})`
at the tail of the medium-match (`cmd > 2`) and cmd==2 long-match paths, matching
the C# `Sse.Prefetch0(dstBegin - off32Stream[3])` lookahead. Fires after each
far-offset match copy, prefetching the source position of a match 3 entries ahead
in the off32 stream.

**Results** (24-core Arrow Lake, `benchc -r 10`):

| Corpus  | Level | Before (MB/s) | After (MB/s) | Change |
|---------|-------|--------------|-------------|--------|
| enwik8  | L1    | 16,679       | 17,861      | +7.1%  |
| enwik8  | L3    | 17,585       | 17,912      | +1.9%  |
| enwik8  | L5    | 9,627        | 9,447       | -1.9%  |
| silesia | L1    | 22,944       | 19,723      | -14%   |
| silesia | L3    | 24,169       | 21,342      | -12%   |
| silesia | L5    | 11,199       | 11,291      | +0.8%  |

**Why it failed**: Text (enwik8) has many large-offset matches whose source
positions are DRAM misses — the prefetch hides latency and helps. Binary/mixed
data (silesia) has mostly short-offset matches whose sources are already in
L1/L2 cache. The prefetch wastes frontend uops: the `off32_stream[3]` load,
the bounds check, and the prefetch instruction itself all cost cycles for zero
benefit on a frontend-bound decoder.

A conditional prefetch (only when `far > 65536`) might help, but the branch
itself adds frontend pressure. A text-vs-binary heuristic exists at compress
time (`text_detector.zig`) but the decoder has no access to it.

**Verdict**: Reverted. The C# prefetch may help on .NET's less-optimized hot
loop; the Zig decoder is tight enough that the overhead outweighs the benefit
on mixed workloads.

---

## Fast decoder: unconditional PSHUFB match copy for short-token path (2026-04-19)

**Context**: VTune uarch-exploration on L5 enwik8 (2000 runs, post-sidecar
optimization at 12.2 GB/s) showed `writeInt` (from `copy64`) as the
dominant clock consumer: 246.9B + 111.5B + 22.7B = 381B instructions,
225.6B cycles. The short-token match copy does 2× `copy64` (= 2 loads +
2 stores per token). `copyMatch16Pshufb` was identified in the previous
failed experiment (branched copy16) as "option (b)" — a branchless
PSHUFB-based approach that handles all distances without a branch.

**Change**: Replace the 2× `copy64` in the short-token match path with
a single `copyMatch16Pshufb(dst, match_ptr, distance)`. No branch on
distance — the PSHUFB mask table handles d=1..15 via pattern replication
and d>=16 via identity mask, all in one code path.

```zig
// Before: 2 loads + 2 stores
copy.copy64(dst, match_ptr);
copy.copy64(dst + 8, match_ptr + 8);

// After: 1 load + 1 PSHUFB + 1 store + 1 table load
const distance: usize = @intCast(-recent_offs);
copy.copyMatch16Pshufb(dst, match_ptr, distance);
```

**Results** (100 runs, enwik8):

| Level | Metric | Baseline | PSHUFB | Change |
|-------|--------|----------|--------|--------|
| L3 | best | 38,492 MB/s | 38,764 MB/s | +0.7% (noise) |
| L3 | mean | 33,203 MB/s | 32,486 MB/s | −2.2% |
| L5 | best | 12,932 MB/s | 12,776 MB/s | −1.2% |
| L5 | mean | 11,879 MB/s | 11,841 MB/s | −0.3% |

**Why it didn't help**: The PSHUFB approach saves 1 store µop per token
but adds: (1) a `neg` + `intCast` to compute distance from `recent_offs`,
(2) a `min` + `intCast` to clamp the mask index, (3) a table load from
`match_copy_pshufb_masks[idx]`, and (4) the PSHUFB instruction itself
(1 cycle latency, port 5). On Arrow Lake, the store port isn't the
bottleneck — the retirement width (6 µops/cycle) and OoO scheduling
already overlap the 2 stores with surrounding work. The extra ALU +
table-load µops offset the store-port savings exactly.

**Disposition**: Reverted. The 2× `copy64` short-token match copy is at
its optimization floor for the current wire format. The only path to
fewer stores would be an encoder guarantee that all offsets >= 16,
eliminating the overlap concern entirely (format change).

---

## Parallel worker output-region prefetch (2026-04-19)

**Context**: Same VTune session. `fastL14WorkerFn` showed CPI = 2.15
with 131.8B memory-bound slots and 99.2B L1D_PENDING.LOAD. Hypothesis:
workers stall on page faults and TLB misses when first touching their
output region in dst.

**Change 1 — Page-level write prefetch**: Before the sidecar scatter
and decode loop, walk the worker's output region in 4KB strides issuing
`@prefetch(.write, .locality=1)` to trigger demand-zero page faults
early.

**Result**: L5 best 12,768 MB/s (baseline 12,932) — slight regression.
L3 neutral.

**Why**: In a warm benchmark loop (100+ iterations), pages are already
mapped and cache-hot from the prior iteration. The prefetch loop adds
~25 instructions per worker per call for zero benefit. In a cold
single-shot scenario the prefetch might help, but benchmarks can't
measure that.

**Change 2 — Sidecar scatter prefetch**: Prefetch the next sidecar
literal's dst position while writing the current one, hiding the
read-for-ownership latency on scattered writes.

**Result**: L5 best 12,864 MB/s (baseline 12,932) — noise.

**Why**: Sidecar literal positions are sorted ascending, so sequential
access is already hardware-prefetcher friendly. The explicit prefetch
adds 1 µop per literal for zero benefit.

**Root cause of high CPI**: The 2.15 CPI in `fastL14WorkerFn` is
inherent to the parallel architecture — read-for-ownership traffic on
dst cache lines during sidecar scatter, and cross-worker false sharing
at chunk boundaries (the 64-byte guard save/restore). These are
fundamental costs of parallel decode, not fixable without a wire format
change.

**Disposition**: Both reverted. The parallel worker overhead is at its
floor for the current architecture.

---

## writeInt microarchitecture analysis (2026-04-19)

**Context**: After all optimization attempts, `writeInt` (mem.zig:1940,
inlined from `copy64` in copy_helpers.zig) remains the dominant hotspot
at 383.4B instructions / 226.6B cycles (CPI 0.59). This analysis
explains WHY it dominates and why further optimization is infeasible.

**VTune source-line breakdown** (uarch-exploration, L5 enwik8, 2000 runs):

| Counter | Value | Meaning |
|---------|-------|---------|
| L1 hit loads | 178.1B | 79.8% of loads hit L1 |
| L1 miss loads | 45.1B | 20.2% miss rate — match reads from random offsets |
| Split loads | 1.75B | 11.6% — unaligned 8-byte access crossing cache lines |
| Split stores | 1.72B | 11.6% — same cause |
| Store buffer full (XQ.FULL) | 0.84B | Negligible — NOT store-throughput limited |
| Memory-bound slots | 343.2B | 90% of writeInt's stall is load-latency |
| DSB uops | 435.8B | 99.8% from µop cache — no frontend issues |

**Key insight**: The high cycle count on `writeInt` is NOT from store
pressure. It's from **match-load latency** — `readInt` and `writeInt`
are on the same inlined `copy64` call, so VTune attributes the load
miss stall to the store instruction (IP skid from out-of-order
retirement). The 45.1B L1 misses at ~10-cycle L2 penalty = ~451B stall
cycles. OoO execution overlaps ~50% of this with other work, yielding
the observed 226.6B cycles.

**Why it can't be improved**:

1. **The L1 misses are fundamental to LZ decompression.** Match
   back-references point to arbitrary positions in the 100MB output
   buffer. A 48KB L1 cache can only hold ~0.048% of the buffer. The
   20.2% miss rate is actually good — it means 80% of matches
   reference recent output that's still in L1.

2. **Prefetch was already tried and failed.** Lookahead prefetch of the
   next match source address adds µops to the hot loop (peek at next
   cmd + off16, compute address, issue prefetch = ~6 µops). The loop
   is ~25 µops; adding 6 is a 24% frontend-dispatch increase that
   overwhelms any cache-hit conversion. See "Fast decoder: lookahead
   prefetch for next match" above.

3. **Store-forwarding works.** Only 9.6M store-forwards (negligible),
   meaning the load-store overlap in the `copy64` cascade is handled
   correctly by the CPU without penalty.

4. **Split accesses are unavoidable.** 11.6% split rate is the
   expected value for unaligned 8-byte accesses on random-aligned
   pointers (8/64 = 12.5% theoretical). Aligning `dst` or `match_ptr`
   would require padding that breaks the wire format.

5. **Store buffer is not full.** XQ.FULL = 0.84B means the store
   buffer has capacity. Reducing stores (e.g., PSHUFB 16→1 store)
   wouldn't help because the bottleneck isn't store throughput.

**Conclusion**: `writeInt` dominates the profile because LZ
decompression IS memory copies. The decoder is running at ~12.2 GB/s
on L5 parallel enwik8, which is ~500 MB/s per core. At 3.7 GHz and
8 bytes per `copy64`, that's ~0.93 copies/cycle — within 7% of the
1.0 stores/cycle theoretical throughput. The remaining gap is the L1
miss penalty on match loads, which cannot be hidden without a format
change (e.g., reordering matches to improve locality, at the cost of
compression ratio).
