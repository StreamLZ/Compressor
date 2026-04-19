# StreamLZ Zig — Rename Audit

Codebase scan for naming convention violations and unclear identifiers.
Going open-source — public API names matter.

**Result: the codebase is already well-named.** All public functions
are camelCase, all types are PascalCase, all constants are snake_case.
No snake_case function violations found. The items below are polish.

---

## FILE RENAMES (PascalCase for single-struct files)

Per Zig convention, a file that exports one primary struct should be
named after that struct. Rename when touching the file — don't do a
bulk rename commit.

| Current | Struct | Rename to |
|---------|--------|-----------|
| `io/bit_reader.zig` | `BitReader` | `BitReader.zig` |
| `encode/byte_histogram.zig` | `ByteHistogram` | `ByteHistogram.zig` |
| `encode/fast_stream_writer.zig` | `FastStreamWriter` | `FastStreamWriter.zig` |
| `encode/fast_match_hasher.zig` | `FastMatchHasher` | `FastMatchHasher.zig` |
| `encode/managed_match_len_storage.zig` | `ManagedMatchLenStorage` | `ManagedMatchLenStorage.zig` |

Note: most files export multiple items or are module-style (constants,
free functions). Those stay snake_case per convention.

---

## UNCLEAR NAMES — HIGH (confusing or misleading)

### `bh` for block header results

Used in `streamlz_decoder.zig`, `main.zig`, `cleanness_analyzer.zig`.
Two-letter abbreviation for a heavily-used struct in public decoder
logic.

**Current:** `const bh = frame.parseBlockHeader(...)`
**Suggested:** `block_hdr`

### `cs` for content size

Used in `main.zig` via optional binding: `if (hdr.content_size) |cs|`.
Hard to spot in context.

**Suggested:** Keep — Zig idiom for short optional bindings. The type
and context make it clear.

---

## UNCLEAR NAMES — MEDIUM (inconsistent across files)

### Position/offset variable naming

The same concept is named differently across files:

| Concept | Variants seen |
|---------|---------------|
| Source cursor position | `src_pos`, `scan_pos`, `pos`, `src_offset` |
| Destination offset | `dst_off`, `dst_offset`, `dst_off_inout` |
| File position | `file_pos_running`, `file_pos_base`, `running_dst_off` |

**Recommendation:** standardize to `src_pos` / `dst_off` (short form)
or `src_position` / `dst_offset` (long form) — pick one and use it
everywhere. Current mix is fine for locals but confusing when reading
across files.

### `allocator_opt` parameter name

`decompressFramedInner` and related functions use `allocator_opt` for
`?std.mem.Allocator`. The `_opt` suffix is unusual in Zig — the `?`
type already signals optionality.

**Suggested:** Leave as-is. Renaming to `allocator` would shadow the
non-optional version in callers. The `_opt` suffix disambiguates.

---

## UNCLEAR NAMES — LOW (abbreviations in algorithm code)

### Single-letter variables in heap operations (tans_encoder.zig)

`t`, `u`, `h` in `heapMake`, `heapPush`, `heapPop`. Standard for
heap algorithms — renaming would make the code longer without adding
clarity for anyone who knows the algorithm.

**Recommendation:** Leave as-is.

### `w` for FastStreamWriter

Used throughout `fast_lz_encoder.zig` and `fast_lz_parser.zig`.
Short but consistent — every `w` in these files is a writer.

**Recommendation:** Leave as-is.

### `lz` for FastLzTable

Used in decoder files. Short but unambiguous in context.

**Recommendation:** Leave as-is.

---

## NO ACTION NEEDED

- All `pub fn` names are camelCase ✓
- All `pub const TypeName = struct` are PascalCase ✓
- All `pub const constant_name` are snake_case ✓
- No negated booleans (`not_found`, `no_match`) ✓
- No Hungarian prefixes ✓
- No misleading function names found ✓
