# StreamLZ Zig — Practical Audit Brief

Response to `audit.md`. Focuses on changes that fix real bugs, reduce
real maintenance risk, or unlock real capability. Ignores cosmetic
reorganization that trades one navigation axis for another.

Context: this codebase is going open source. C# is legacy; Zig is
primary. The "mirrors C# line X" comments should be removed. Codec
evolution (new levels, format changes) is expected.

---

## DO NOW (correctness risk or active maintenance hazard)

### 1. Delete `bit_writer_64.zig` and reconcile the u5/u6 mismatch

Two files export `BitWriter64Forward` with different `write` signatures
(`n: u5` vs `n: u6`). `tans_encoder.zig` imports one; everything else
imports the other. Writing 32 bits through the u5 variant silently
truncates. This is the single most dangerous defect in the tree.

**Action:** Delete `bit_writer_64.zig`. Update `tans_encoder.zig` to
import `bit_writer.zig`. Verify the u6 width is correct for tANS
(it should be — tANS writes up to 32 bits per symbol).

### 2. Delete the three stub files

- `encode/high_lz_encoder.zig` (5 lines, no code)
- `encode/multi_array_huffman_encoder.zig` (7 lines, no code)
- `encode/optimal_parser.zig` (5 lines, no code)

They look like real modules to anyone browsing the tree. They aren't.

### 3. Merge duplicate match-eval helpers

`fast_lz_parser.zig` has inline copies of `countMatchingBytes`,
`isMatchBetter`, `isBetterThanRecentMatch`, `isLazyMatchBetter` that
duplicate `match_eval.zig`. The comment says "preserves byte-exact
parity with C#." If the two copies differ, one is buggy. If they
don't differ, delete the copies and import.

### 4. Convert hot-loop env-var debug prints to comptime flags

`fast_lz_parser.zig:238` and `fast_lz_encoder.zig:307` call
`std.process.hasEnvVarConstant` on every iteration of the encoder
hot loop. Even when the env var is unset, the lookup costs cycles
on every token. Replace with `comptime const trace = false;` so
the branch is eliminated at build time.

### 5. Fix `ByteHistogram.count_bytes` naming

The only snake_case method in the codebase. Rename to `countBytes`.
Delete the duplicate free function `countBytesHistogram`. Three
call sites.

### 6. Strip "mirrors C# line X" parity comments

The codebase is littered with comments pointing at C# source line
numbers (`high_optimal_parser.zig:1033-1047`, `streamlz_encoder.zig:
1183-1198`, `entropy_encoder.zig:469-474`, etc.). C# is now legacy.
These comments will rot. Delete them. If a comment explains a
non-obvious design decision, rewrite it to stand alone without the
C# reference.

### 7. Remove dead `_ = parameter;` suppressions

Seven instances across the tree. Each is either a parameter that
should be deleted (if truly unused) or a suppression that lies
(if the parameter IS used, like `dict_size` in
`high_optimal_parser.zig:311`). Audit each one individually.

---

## DO SOON (structural improvements, moderate effort)

### 7. Split Windows FFI out of `streamlz_encoder.zig`

`GlobalMemoryStatusEx` struct + extern fn + `totalAvailableMemoryBytes`
+ `calculateMaxThreads` don't belong in the compressor top file.
Move to `platform/memory_query.zig`. This is the single highest-value
split in the tree — the rest of `streamlz_encoder.zig` can stay as
one file for now.

### 8. Merge `encode/block_header_writer.zig` into `format/block_header.zig`

Encode-side and decode-side of the same 2-byte wire object are in
different directories. One file, both directions. Also eliminates the
duplicate `areAllBytesEqual` (which exists in both
`block_header_writer.zig` and `streamlz_encoder.zig`).

### 9. Add L5 parallel decode unit tests

The unit test suite (288 tests) doesn't exercise the L5 parallel
decode path with contiguous-slice dispatch + sidecar. The `benchc`
command tests it end-to-end, but a dedicated unit test with a small
L5-compressed buffer would catch regressions without needing the
full 100 MB enwik8 corpus. Test at worker_count=1 and worker_count=4
minimum.

### 10. Remove dead overcopy walker code

The overcopy_leaves logic in `cleanness_analyzer.zig`
(`partitionFastSubChunk`'s `max_write_end` tracking) is no longer
used — the worker save/restore in `decompress_parallel.zig` handles
overcopy repair. The walker still computes `max_write_end` and
appends to `overcopy_leaves`, but `buildPpocSidecar` no longer
drains them into the sidecar. Either remove the dead computation
or gate it behind the diagnostic env vars.

### 11. Guard `computeTransitiveDepth` against stack overflow

The recursive depth computation via `producer_map` can recurse up
to chain-depth times. On enwik8 L5 the max depth is ~55 hops.
On pathological inputs it could be deeper. Convert to an iterative
loop with a fixed-size stack, or cap recursion depth at 255
(which the u8 depth field already implies).

---

## DO IF TOUCHING THE FILE ANYWAY (opportunistic)

### 12. Disambiguate `BlockHeader` name collision

`format/frame_format.zig` exports `BlockHeader` (the 8-byte outer
block header). `format/block_header.zig` exports `BlockHeader`
(the 2-byte internal header). Rename one — e.g., `FrameBlockHeader`
for the outer one.

### 13. Rename `cost_model.zig` to indicate it's Fast-specific

Currently `encode/cost_model.zig` is the Fast codec cost model.
`encode/high_cost_model.zig` is the High codec one. The asymmetric
naming suggests `cost_model.zig` is generic. Rename to
`fast_cost_model.zig` or move to a `fast/` subdirectory if one
exists.

### 14. PascalCase type-files

When modifying a file that's essentially one struct
(`FastMatchHasher`, `FastStreamWriter`, `ManagedMatchLenStorage`,
etc.), rename to `PascalCase.zig` per Zig convention. Don't do a
bulk rename commit — do it when you're already changing the file.

### 15. Narrow public error sets

`CompressError` and `DecompressError` union every sub-module's
errors. Callers see `HashBitsOutOfRange` from `decompressFramed`.
Going open source makes this more visible — external callers will
`catch` on these. Define narrow public sets and translate at the
module boundary.

---

## DON'T DO (from the original audit — disagree)

### The 50 -> 105 file reorganization

The proposed split takes `tans_encoder.zig` into 6 files,
`streamlz_constants.zig` into 8 files, and `main.zig` into 8 files.
This trades large-file navigation for deep-directory navigation.
The Zig stdlib keeps `std.compress.zstd` in one 3000-line file.
The principle: if understanding the tANS encoder requires opening
6 files, the split made it harder, not easier.

### The `src/{encode,decode}` -> domain-based restructure

Moving from `encode/fast_lz_parser.zig` to
`fast/encode/greedy_parser.zig` changes the axis from "this is
encoder code" to "this is Fast codec code." Neither is obviously
better. The churn (96% of paths change) is not justified.

### Replace all `[*]u8` with `[]u8`

The hot loops do `dst += length` pointer advance. Slices would add
bounds checks on every token. The raw pointers are intentional and
measured. Keep them in hot loops, use slices at API boundaries.

### Replace `extern struct` with `struct`

On x86_64 the layout is identical. No practical impact. Not worth
the audit effort to verify each one.

### Move `cleanness_analyzer.zig` to `tools/`

The original audit called this "1640 lines of research tooling."
It's now production code — `buildPpocSidecar` builds the L5
parallel-decode sidecar at compress time. It stays in `decode/`.

---

## THINGS THE ORIGINAL AUDIT MISSED

### A. Sidecar wire format version

The sidecar format semantics changed significantly (chunk-level
seeding, recursive depth, cross-16-chunk-boundary filtering). The
wire format version (`sidecar_version = 2`) was not bumped. A v2
sidecar from the old code has different content than v2 from the
new code. Consider bumping to version 3, or adding a feature flag
byte in the reserved header space.

### B. `compressBound` doesn't account for L5 sidecar

`compressBound` estimates the maximum compressed output size.
For L5, the sidecar adds ~1.2 MB. If the estimate is too tight,
the encoder silently drops the sidecar (the "out of output budget"
check at `streamlz_encoder.zig:923`). Verify that `compressBound`
includes sidecar headroom for L5.

### C. The README benchmark tables are stale

Multiple sessions of changes have shifted the numbers. The v2
parallel L1-L4 tables were from several commits ago. The L5
numbers are brand new. A single re-run of all benchmarks on the
same build would make the tables consistent.

### D. No silesia or JSON L5 parallel benchmarks

L5 parallel decode was validated on enwik8 only. The `large_100mb.json`
and `silesia_all.tar` corpora were tested at L1-L4 but not at L5.
A round-trip + benchmark run on both would confirm the sidecar
works on non-text data.

### E. Thread pool lifecycle

`LazyPool` in `streamlz_decoder.zig` creates a persistent
`std.Thread.Pool` on first use. The pool is never explicitly shut
down — it relies on process exit. For library consumers who
decompress once and want clean shutdown, there's no API to release
the pool. Low priority but worth noting.
