# StreamLZ WASM Decompressor — Optimization Ideas

## Current State (April 2026)
- **5,369 lines** of hand-coded WAT in `slz-decompress.wat`
- **25.5KB** compiled WASM binary
- **87 globals**, **65 functions**
- Performance: L1 1.3 GB/s, L6 530 MB/s (5.1 GB/s parallel), L9 610 MB/s
- All levels L1-L11 working, SIMD128, parallel L6-L8

## Key Files
- `slz-decompress.wat` — the entire WASM decompressor (5369 lines)
- `slz.mjs` — universal JS API (Node + browser)
- `slz-worker.js` — universal Web Worker for parallel decompression
- `build.sh` — `wat2wasm` build script
- `test.mjs` — low-level WASM tests (26 tests)
- `test-api.mjs` — API-level tests (13 tests + benchmarks)

---

## Idea 1: Extract Inline Bit Reader Refills into Shared Functions

**Impact:** ~200 lines removed, ~1KB smaller WASM
**Difficulty:** Easy
**Risk:** Low (pure refactor)

### Problem
The High LZ decoder (`$high_decode_chunk_lz`, line 4524) has ~15 inline refill
loops for the bidirectional bitstream readers (bitsA forward, bitsB backward).
Each loop is 6 lines of WAT like:

```wat
(block $refA (loop $rA
  (br_if $refA (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
  (br_if $refA (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
  (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
    (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
  (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
  (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
  (br $rA)))
```

Grep for these: `grep -c "refA\|refB\|rLA\|rLB\|rTA\|rTB" slz-decompress.wat` → 72 matches.

### Solution
These bit readers use LOCAL variables (`$bitsA_bits`, `$bitsA_bitpos`, `$bitsA_p`),
which can't be passed to/from functions efficiently in WASM (no pass-by-reference).

**Option A:** Store bitsA/bitsB state at fixed memory addresses (like BR at 0x30),
add `$hlz_refill_a` and `$hlz_refill_b` functions that read/write from those addresses.
Each call site becomes a single `(call $hlz_refill_a)` instead of 6 lines.
Downside: memory load/store overhead on the hot path.

**Option B:** Use a WASM multi-value return or just accept the duplication for the
hot paths (offset unpacking, ReadLength) and only extract the cold-path refills.

### Lines affected
- `$high_decode_chunk_lz` (line 4524): the bitsA/bitsB refill loops at lines
  ~4640-4780 (offset unpacking) and ~4960-5100 (u32 length stream)
- `$tans_decode` (line 3594): forward/backward refill in the 5-state loop

---

## Idea 2: Remove Debug Scaffolding

**Impact:** ~50 lines removed, ~200 bytes smaller
**Difficulty:** Trivial
**Risk:** None

### What to remove
1. `$TRACE` and `$TRACE2` mutable globals (lines 26-27)
2. `getTrace`/`getTrace2` exports (lines 28-29)
3. `$DBG_COUNTER` global (line 535) and any `(i32.store (global.get $DBG_COUNTER) ...)`
4. All `(global.set $TRACE ...)` stores — grep: `grep -n "global.set.*TRACE" slz-decompress.wat`
5. All `(i32.store (i32.const 0xD4)...)` debug stores for lastOffset tracking —
   wait, 0xD4 is actually USED for delta mode lastOffset. Keep that.
6. Test-only exports: `getVersion`, `getFlags`, `getCodec`, `getLevel`, `getBlockSize`,
   `getContentSize`, `getHeaderSize`, `getDictId`, `getBlockDecompSize`,
   `getBlockIsUncompressed`, `getEntDecodedSize`, `br_*` exports (lines 65-506)

**Note:** The JS API (`slz.mjs`) reads `getTrace()` for error messages. If removing
TRACE, update `getError()` in slz.mjs to return generic messages, or keep TRACE but
remove TRACE2 and DBG_COUNTER.

### Conservative approach
Keep `$TRACE` + `getTrace` (used by error messages). Remove everything else.

---

## Idea 3: Replace Byte-at-a-Time Reads with i32.load + Mask

**Impact:** ~30 lines shorter, slightly faster parsing
**Difficulty:** Easy
**Risk:** Low (must handle alignment — WASM allows unaligned loads)

### Current pattern (3-byte big-endian sub-chunk header, ~8 occurrences)
```wat
;; Line 1331-1333 in $decode_block
(local.set $subHdr
  (i32.or
    (i32.or
      (i32.shl (i32.load8_u (local.get $src)) (i32.const 16))
      (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
    (i32.load8_u (i32.add (local.get $src) (i32.const 2)))))
```

### Replacement
```wat
(local.set $subHdr
  (i32.and
    (call $huff_bswap32 (i32.load (local.get $src)))  ;; load 4 bytes LE, bswap to BE
    (i32.const 0xFFFFFF)))                              ;; mask to 3 bytes
```

Or even simpler — `$huff_bswap32` already exists (line 2731). One load + bswap + mask
vs three loads + two shifts + two ORs.

### Also applies to
- `$decode_far_offsets` 3-byte offset reads (lines 1038-1039, 1067-1068)
- Entropy block header parsing in `$high_decode_bytes` (lines 585-587, 623-625)
- The `$high_decode_chunk_lz` offset scaling byte read

---

## Idea 4: Use `memory.copy` for Literal Runs

**Impact:** Faster decompression for data with long literal runs
**Difficulty:** Easy
**Risk:** None

### Current: Fast decoder trailing literal copy (line ~2143)
```wat
;; Byte-at-a-time with copy64 for >= 8
(if (i32.ge_s (local.get $remaining) (i32.const 8))
  (then (call $copy64 ...) ...)
  (else (i32.store8 ...) ...)
)
```

### Replacement
```wat
(memory.copy (local.get $dstCur) (local.get $litStream) (local.get $remaining))
```

`memory.copy` is a bulk memory instruction (WASM spec) that engines optimize to
native memcpy/memmove. For runs > 32 bytes it's significantly faster than loops.

### Where to apply
- Fast decoder trailing literal copy in `$process_mode` (line ~2130)
- Fast decoder long literal run (cmd==0) raw path (line ~1998)
- High decoder trailing literal copy in `$high_decode_chunk_lz` (line ~5302)
- High decoder raw literal copy could use `memory.copy` instead of `$wildcopy16`
  for litLen > 64 (note: `$wildcopy16` may overshoot by up to 15 bytes, but
  `memory.copy` is exact)

---

## Idea 5: Merge Short-Token Literal Copy Paths (Fast Decoder)

**Impact:** Slightly faster L1 short tokens (~90% of commands)
**Difficulty:** Medium
**Risk:** Low

### Current (line ~1888-1920)
The Fast decoder short token has:
- Delta mode: byte-at-a-time loop adding `dst[recentOffs]`
- Raw mode: `copy64` for litLen >= 1, else nothing

For raw mode, litLen is 0-7 bytes. A single `copy64` already covers this safely
(writes 8 bytes, only advances by litLen). The branch between delta/raw is
`(if (local.get $isDelta) ...)`.

### Optimization
For raw mode: replace the branch + copy64 with `v128.load/v128.store` (copy128).
Since short token match already uses copy128 for offset >= 16, and the literal
source (litStream) never overlaps dst, a single 16-byte copy is always safe.

```wat
;; Before (2 branches + copy64):
(if (local.get $isDelta) (then ...) (else (if litLen >= 1 (then copy64))))

;; After (1 branch for delta, unconditional copy128 for raw):
(if (local.get $isDelta) (then ..byte loop..) (else (call $copy128 dst litStream)))
```

---

## Idea 6: Pre-compile WebAssembly.Module for Workers

**Impact:** Faster worker pool initialization
**Difficulty:** Easy
**Risk:** None

### Current (`slz.mjs` WorkerPool.init, line ~140)
Each worker receives `wasmBytes` (raw bytes) and calls `WebAssembly.instantiate(bytes)`
independently. With 24 workers, the WASM module is compiled 24 times.

### Fix
In the main thread:
```js
const module = await WebAssembly.compile(wasmBytes);
```
Then pass the `Module` to each worker. Workers call:
```js
const instance = await WebAssembly.instantiate(module);  // instantiate from pre-compiled Module
```

`WebAssembly.Module` is transferable via `postMessage` in browsers and via
`workerData` in Node. Compilation happens once; instantiation is fast.

### Files affected
- `slz.mjs`: `WorkerPool.init()` — compile once, pass Module
- `slz-worker.js`: `init()` — accept Module instead of bytes

---

## Idea 7: Deduplicate Match-Copy Between Fast and High Decoders

**Impact:** ~60 lines removed
**Difficulty:** Easy
**Risk:** Low

### Pattern (appears 4 times)
```wat
;; Check offset >= 16 → SIMD wildcopy, else byte-at-a-time
(if (i32.ge_u (i32.sub (local.get $dst) (local.get $match)) (i32.const 16))
  (then (call $wildcopy16 ...))
  (else (byte loop...))
)
```

### Locations
1. Fast long match cmd==1 (line ~2086)
2. Fast long match cmd==2 (line ~2124)
3. High token match copy (line ~5276)
4. Fast medium match (line ~1966) — uses copy128/copy64 variant

### Solution
Extract a `$match_copy(dst, src, len)` function:
```wat
(func $match_copy (param $dst i32) (param $src i32) (param $len i32)
  (if (i32.ge_u (i32.sub (local.get $dst) (local.get $src)) (i32.const 16))
    (then (call $wildcopy16 (local.get $dst) (local.get $src)
            (i32.add (local.get $dst) (local.get $len))))
    (else ;; byte loop
      (local $i i32)
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $dst) (local.get $i))
          (i32.load8_u (i32.add (local.get $src) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    )
  )
)
```

---

## Idea 8: Unify Raw vs Delta Literal Paths (High Decoder)

**Impact:** ~30 lines removed, cleaner code
**Difficulty:** Medium
**Risk:** Low

### Current (`$high_decode_chunk_lz`, line ~5230)
Two separate loops:
```wat
(if (i32.eq (local.get $mode) (i32.const 1))
  (then ;; Raw: wildcopy16)
  (else ;; Delta: byte-at-a-time with dst[lastOffset] add)
)
```

### Unified approach
Use a delta mask: `$deltaMask = (mode == 0) ? 0xFF : 0x00`

```wat
;; Compute once before the token loop:
(local.set $deltaMask (i32.sub (i32.const 0) (i32.eqz (local.get $mode))))
;; deltaMask = 0xFFFFFFFF for mode 0, 0x00000000 for mode 1

;; In the literal copy (byte-at-a-time, required for delta anyway):
(i32.store8 (i32.add (local.get $dst) (local.get $i))
  (i32.add
    (i32.load8_u (i32.add (local.get $litStream) (local.get $i)))
    (i32.and
      (i32.load8_u (i32.add (i32.add (local.get $dst) (local.get $i)) (local.get $lastOffset)))
      (local.get $deltaMask))))
```

For raw mode (deltaMask=0): the `i32.and` zeroes the delta, so it's just `lit + 0 = lit`.
For delta mode (deltaMask=0xFF): it's `lit + dst[lastOffset]`.

**Tradeoff:** Raw mode can no longer use `$wildcopy16` — it falls back to byte-at-a-time.
This is slower for raw mode. Only worth it if code size matters more than raw-mode speed.

**Alternative:** Keep both paths but extract the byte loop into a shared function.

---

## Idea 9: Consolidate Memory Layout Constants

**Impact:** Cleaner code, easier to relocate work areas
**Difficulty:** Medium
**Risk:** Medium (address changes need careful testing)

### Current
87 globals define fixed addresses:
```wat
(global $HUFF_LUT_LEN i32 (i32.const 0x0C100000))
(global $HUFF_LUT_SYM i32 (i32.const 0x0C100810))
(global $HUFF_REV_LEN i32 (i32.const 0x0C101020))
...
(global $TANS_DATA    i32 (i32.const 0x0C110000))
(global $TANS_LUT     i32 (i32.const 0x0C110600))
...
(global $HLZ_SCRATCH  i32 (i32.const 0x0C130020))
```

### Solution
Define a single `$WORK_BASE` global and use constant offsets:
```wat
(global $WORK_BASE i32 (i32.const 0x0C000000))

;; Then reference as:
;; Huffman LUT len = WORK_BASE + 0x100000
;; tANS data = WORK_BASE + 0x110000
;; etc.
```

Each reference becomes `(i32.add (global.get $WORK_BASE) (i32.const OFFSET))`.

**Benefits:**
- Relocating all work areas requires changing ONE global
- Fewer globals in the WASM binary
- Clearer documentation of the memory map

**Downsides:**
- Every address reference adds an `i32.add` instruction (slight code size increase)
- Data segments still use absolute addresses

---

## Idea 10: Add `decompress_chunk` Export

**Impact:** Simpler worker code, eliminates synthetic frame construction
**Difficulty:** Medium
**Risk:** Low

### Current
The parallel JS wrapper (`slz.mjs` / `slz-worker.js`) builds a synthetic SLZ1
frame around each chunk before calling `decompress()`:

```js
// slz-worker.js, line ~25
const frameSize = 18 + 8 + inputLen + 4;
// ... write frame header, block header, end mark ...
mem.set(input.subarray(...), inputBase + 26);
wasm.decompress(frameSize);
```

This is 30+ lines of frame construction per chunk, and copies the data twice
(shared buffer → synthetic frame → WASM input buffer).

### Solution
Export a `decompress_chunk` function from the WASM that takes:
- `srcOffset` — offset into the input buffer where the chunk's StreamLZ header starts
- `srcLen` — compressed chunk length (StreamLZ header + chunk header + sub-chunk data)
- `dstOffset` — offset into the output buffer
- `dstSize` — expected decompressed size

The function would call `$decode_block` directly, skipping frame/block header parsing.

```wat
(func (export "decompressChunk")
  (param $srcOffset i32) (param $srcLen i32)
  (param $dstOffset i32) (param $dstSize i32)
  (result i32)
  ;; src = INPUT_BASE + srcOffset
  ;; dst = OUTPUT_BASE + dstOffset
  ;; Call $decode_block(src, src+srcLen, dst, dstSize)
  ...
)
```

### Worker simplification
```js
// Before: 30 lines building synthetic frame
// After:
mem.set(chunkData, wasm.getInputBase());
wasm.decompressChunk(0, chunkData.length, outputOffset, dstSize);
output.set(mem.subarray(outputBase + outputOffset, ...), outputOffset);
```

Even better with shared memory: the worker reads directly from the shared input
buffer (already at the right offset) and writes to the shared output buffer.

---

## Architecture Reference

### Function Map (65 functions)
| Function | Line | Purpose |
|----------|------|---------|
| `$parseFrameHeader` | 104 | Parse SLZ1 frame header |
| `$parseBlockHeader` | 223 | Parse 8-byte block header |
| `$br_init/refill/read_*` | 303-484 | Forward/backward MSB-first bit readers |
| `$high_decode_bytes` | 541 | Entropy dispatcher (memcopy/Huffman/tANS/RLE/recursive) |
| `$high_decode_recursive` | 731 | Recursive entropy (type 5) |
| `$high_decode_rle` | 799 | RLE entropy (type 3) |
| `$copy64/$copy128/$wildcopy16` | 985-1005 | SIMD copy primitives |
| `$decode_far_offsets` | 1014 | Fast decoder 32-bit offset unpacking |
| `$decompress` | 1122 | Main entry: frame → blocks → chunks |
| `$decode_block` | 1202 | Block decoder: outer 256KB loop + inner 128KB sub-chunk loop |
| `$fast_decode_chunk` | 1485 | Fast LZ: ReadLzTable + ProcessLzRuns |
| `$process_lz_runs` | 1722 | Fast LZ: two 64KB iteration orchestrator |
| `$process_mode` | 1822 | Fast LZ: match-copy loop (short/medium/long tokens) |
| `$huff_read_code_lengths_old` | 2260 | Huffman OLD code-length reader (gamma) |
| `$huff_read_code_lengths_new` | 2463 | Huffman NEW code-length reader (Golomb-Rice) |
| `$huff_make_lut` | 2584 | Build 2048-entry Huffman forward LUT |
| `$huff_reverse_lut` | 2687 | Bit-reverse LUT for LSB-first 3-stream decode |
| `$huff_decode_3stream` | 2748 | 3-stream parallel Huffman decode |
| `$high_decode_huff` | 3001 | Huffman entry (types 2/4, old+new paths) |
| `$tans_decode_table_sparse` | 3171 | tANS sparse frequency table |
| `$tans_init_lut` | 3351 | tANS 4-way interleaved LUT build |
| `$tans_decode` | 3594 | tANS 5-state forward/backward decode |
| `$high_decode_tans` | 3817 | tANS entry (sparse + Golomb-Rice paths) |
| `$decode_golomb_rice_lengths` | 3980 | GR byte-at-a-time LUT decoder |
| `$decode_golomb_rice_bits` | 4077 | GR precision bit merge |
| `$br_read_fluff` | 4159 | Sub-256 symbol fluff reader |
| `$huff_convert_to_ranges` | 4211 | Symbol range builder from fluff+rice |
| `$tans_decode_table_gr` | 4310 | tANS Golomb-Rice frequency table |
| `$high_decode_chunk_lz` | 4524 | High LZ: ReadLzTable + UnpackOffsets + ResolveTokens + Execute |

### Memory Layout
```
0x00000000..0x000000FF  Header scratch, LZ table (0x60-0x98), bit readers (0x30-0x4F)
0x00000100..0x03FFFFFF  Input buffer (64MB default)
0x04000100..0x0BFFFFFF  Output buffer (128MB default, mutable via setOutputBase)
0x0C000100..0x0C001100  (unused, was old LUT_BASE)
0x0C001100..0x0C041100  DECODE_SCRATCH (Fast decoder entropy streams, 256KB)
0x0C041100..0x0C081100  OFF32_SCRATCH (Fast decoder far offsets, 256KB)
0x0C081100              RLE entropy-coded prefix scratch
0x0C100000..0x0C102040  Huffman forward+reverse LUTs (4 × 2064 bytes)
0x0C102040..0x0C102570  Huffman syms, prefix arrays
0x0C102540              CodePrefixOrg data segment (48 bytes)
0x0C103000              Golomb-Rice value table data segment (1024 bytes)
0x0C103400              Golomb-Rice length table data segment (256 bytes)
0x0C104000              Huffman NEW codelen scratch
0x0C110000..0x0C118600  tANS data (TansData + TansLut)
0x0C120000..0x0C120600  tANS GR scratch (rice + range)
0x0C128000              u32 length stream buffer (2048 bytes)
0x0C130000..0x0C130020  High LZ table (HighLzTable, 32 bytes)
0x0C130020..0x0C170020  High LZ scratch (entropy decode, 256KB)
0x0C170020..0x0C1F0020  High LZ unpacked offsets (512KB)
0x0C1E0000              lowBits save area for offset scaling
0x0C1F0020..0x0C270020  High LZ unpacked lengths (512KB)
0x0D000000+             Large file output (when > 128MB, via memory.grow)
```

### Key Variables at Fixed Addresses
```
0x30-0x3C  BR (forward bit reader): P, PEnd, Bits, BitPos
0x40-0x4C  BR2 (backward bit reader): P, PEnd, Bits, BitPos
0x50       ENT_DECODED_SIZE (last entropy decode output size)
0x60-0x98  FastLzTable: litStart/End, cmdStart/End, lenStream, off16Start/End,
           off32Start/End, off32Bk1/Bk2, off32Cnt1/Cnt2, cmd2Off/End
0x9C       savedDist (Fast LZ recent offset, persisted across 64KB iterations)
0xC0-0xC8  GR BitReader2: P, PEnd, Bitpos
0xD0       SC chunk dstStart (per-chunk for SC, block-start for non-SC)
0xD4       lastOffset (High LZ delta mode, previous token's match offset)
```
