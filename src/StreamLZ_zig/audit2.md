# StreamLZ Zig — Fresh-Eyes Folder Audit

What a new open-source contributor sees when they open `src/` for the
first time. Focused on "what's confusing" — not what's wrong, but
what slows down understanding.

---

## HIGH — Blocks understanding of the architecture

### 1. Flat `encode/` directory (27 files, no hierarchy)

Fast-codec files, High-codec files, shared entropy code, match
finders, cost models, and test fixtures are all at the same level.
A newcomer can't tell which files belong to which codec.

**Option A:** Subdirectories — `encode/fast/`, `encode/high/`,
`encode/shared/`.
**Option B:** Leave flat but add a one-line `//! Used by: Fast L1-L5`
to every file header.

### 2. "Fast" vs "High" codec names aren't intuitive

"Fast" sounds like it's about speed. "High" sounds like it's about
quality. In reality:
- **Fast** = greedy/lazy parser, levels 1-5, fast compress + decompress
- **High** = optimal DP parser, levels 6-11, slower compress, same decompress

A newcomer sees `high_fast_parser.zig` and thinks "high-fast? so it's
fast AND high?"  It's actually "the greedy (fast) parser variant used
within the High codec."

**Fix:** Rename `high_fast_parser.zig` → `high_greedy_parser.zig`.
Add a one-liner to the top-level README: "Fast = greedy codec (L1-5),
High = optimal codec (L6-11)."

### 3. No public library API file

`main.zig` is the CLI entry point. There's no `lib.zig` or
`streamlz.zig` for library consumers. If someone wants to use this
as a Zig dependency, where do they call `compress()` / `decompress()`?

**Fix:** Create `src/streamlz.zig` that re-exports the public API:
```zig
pub const compress = @import("encode/streamlz_encoder.zig").compressFramed;
pub const decompress = @import("decode/streamlz_decoder.zig").decompressFramed;
pub const DecompressContext = @import("decode/streamlz_decoder.zig").DecompressContext;
```

### 4. Five match-finding files, unclear relationships

- `match_finder.zig` — hash-chain match finder (High codec)
- `match_finder_bt4.zig` — binary-tree match finder (High codec)
- `match_hasher.zig` — multi-bucket hash table (Fast L3-L5)
- `FastMatchHasher.zig` — single-entry hash (Fast L1-L2)
- `fast_lz_parser.zig` — has inline match helpers too

No file says which codec/level uses it. The naming doesn't reveal
the hierarchy.

**Fix:** Add `//! Used by: High optimal parser (L5+)` to each
file's header. Consider renaming `match_finder.zig` →
`high_match_finder.zig` and `match_finder_bt4.zig` →
`high_match_finder_bt4.zig`.

---

## MEDIUM — Slows down navigation

### 5. Unexplained abbreviations

| Abbreviation | Meaning | Where |
|---|---|---|
| tANS | tabled Asymmetric Numeral System | tans_encoder/decoder |
| BT4 | Binary Tree 4-way | match_finder_bt4 |
| PPOC | Parallel Producer/Consumer proof-of-concept | cleanness_analyzer |
| SC | Self-Contained (block format flag) | streamlz_encoder |
| MLS | Managed Match Length Storage | ManagedMatchLenStorage |

**Fix:** Add a glossary section to the README, or expand acronyms
in each file's header on first use.

### 6. "cleanness_analyzer" — non-standard term

"Cleanness" means "whether a byte's dependency chain stays within
one chunk." This is unique to StreamLZ — no compression textbook
uses this term. The file is 3000+ lines and does sidecar building,
DAG analysis, and partition statistics.

**Fix:** Rename to `parallel_sidecar_builder.zig` or
`cross_chunk_analyzer.zig`. Or at minimum, add a header line:
"Cleanness = all match sources resolve within the same chunk
(no cross-chunk dependencies)."

### 7. `cost_model.zig` vs `cost_coefficients.zig` vs `high_cost_model.zig`

Three cost-related files:
- `cost_model.zig` — Fast codec platform cost combination
- `cost_coefficients.zig` — empirical timing coefficients (shared)
- `high_cost_model.zig` — High codec statistics-based cost model

A newcomer doesn't know which one to read for which codec.

**Fix:** Rename `cost_model.zig` → `fast_cost_model.zig` (this was
already in auditBrief.md item 13). Add `//! Used by: Fast encoder`
headers.

### 8. `high_lz_process_runs.zig` — vague name

"Process runs" doesn't explain what it does. It's the inner loop
that executes LZ token sequences (literals + matches) for the High
decoder. Split from `high_lz_decoder.zig` for compilation reasons.

**Fix:** Rename to `high_lz_token_executor.zig` or add a header:
"Inner loop: applies literal-run + match-copy token sequences to
the output buffer. Type 0 = delta literals, Type 1 = raw literals."

### 9. Test files mixed with source

`fixture_tests.zig` and `encode_fixture_tests.zig` are in the same
directories as production code. They require env vars and external
fixture files to run.

**Fix:** Move to `tests/` directory, or at minimum mark clearly:
`//! Test-only module. Not compiled into the library.`

### 10. `parallel_decode_metadata.zig` in `format/`

The sidecar format is in `format/` but it's only used by the parallel
decoder. It's not part of the core SLZ1 wire format — it's an optional
block type.

**Fix:** Leave in `format/` (it IS a wire format definition), but add
to header: "Optional sidecar block. Written by the encoder for L1-L5
parallel decode. Absent in L6-L11 and older v1 frames."

### 11. No `src/README.md`

Opening `src/` shows 4 directories and `main.zig` with no explanation.
The STRUCTURE.md is one level up.

**Fix:** Create a 10-line `src/README.md`:
```
format/ — wire format (frame, block headers, constants)
io/     — bit readers/writers, SIMD copy helpers
decode/ — decompression (Fast L1-5, High L6-11, parallel)
encode/ — compression (Fast L1-5, High L6-11)
```

---

## LOW — Polish for open-source readability

### 12. PascalCase file names are now inconsistent

We just renamed 5 files to PascalCase (BitReader, ByteHistogram, etc.)
but the other 40+ files are snake_case. This creates a mixed convention.
Zig convention says PascalCase for single-struct files, but most Zig
projects (including the stdlib) use snake_case universally.

**Decision needed:** Pick one convention and apply it everywhere.
If PascalCase for single-struct files, identify and rename ALL of
them (there are more: `match_hasher.zig` exports `MatchHasher`,
`match_eval.zig` exports helpers not a struct, etc.). If snake_case
everywhere, revert the 5 renames.

### 13. `platform/` directory has one file

`platform/memory_query.zig` is alone in its directory. Looks like a
planned expansion that hasn't happened.

**Fix:** Either move to `encode/memory_query.zig` (it's only used
by the encoder) or leave it — it's fine if more platform code is
expected (e.g., Linux huge pages, ARM NEON detection).

### 14. Offset encoder integration unclear

`offset_encoder.zig` has extensive code for LZ offset encoding
strategies, but the Fast codec doesn't use it (emits raw off16/off32
directly). Only the High codec will use it.

**Fix:** Add to header: "Integrated by: High encoder
(`high_encoder.assembleCompressedOutput`). The Fast encoder bypasses
this module and emits raw offsets directly."
