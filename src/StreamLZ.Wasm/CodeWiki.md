# StreamLZ WASM Decompressor — Code Wiki

Reference guide for developers working on the hand-coded WAT decompressor.

## Architecture Overview

The decompressor is a single WASM module built from 12 WAT source files under `wat/`. The build script (`build.sh`) concatenates them and compiles with `wat2wasm`. The JS API (`slz.mjs`) handles memory management, parallel dispatch, and environment detection.

```
Compressed data (SLZ1 frame)
  │
  ▼
slz.mjs: decompress()
  ├─ Single-thread: WASM decompress(inputLen)
  │    └─ parseFrameHeader → block loop → decode_block
  │         └─ per 256KB chunk: StreamLZ header → chunk header → sub-chunks
  │              ├─ Fast codec (L1-L5): fast_decode_chunk → process_lz_runs → process_mode
  │              └─ High codec (L6-L11): high_decode_chunk_lz
  │                   └─ ReadLzTable → UnpackOffsets → ResolveTokens → ExecuteTokens
  └─ Parallel (L6-L8 SC): WorkerPool → per-chunk decompressChunk via SharedArrayBuffer
```

## Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `000-module.wat` | ~100 | Module declaration, memory, globals, constants, getter exports |
| `010-frame.wat` | ~175 | `parseFrameHeader`, `parseBlockHeader` |
| `020-bitreader.wat` | ~230 | Forward/backward MSB-first bit readers (BR at 0x30, BR2 at 0x40) |
| `030-copy.wat` | ~165 | `copy64`, `copy128`, `wildcopy16`, `match_copy`, `read_be24`, `decode_far_offsets` |
| `040-entropy.wat` | ~460 | `high_decode_bytes` (dispatcher), `high_decode_recursive`, `high_decode_rle` |
| `050-huffman.wat` | ~930 | Huffman old (gamma) + new (Golomb-Rice) code-length readers, 11-bit LUT builder, bit-reversal, 3-stream parallel decode |
| `060-tans.wat` | ~820 | tANS sparse + GR table builders, 4-way interleaved LUT, 5-state forward/backward decode |
| `070-golomb-rice.wat` | ~520 | GR length/bit decoders, fluff reader, `huff_convert_to_ranges`, `tans_decode_table_gr` |
| `080-fast-lz.wat` | ~710 | Fast LZ: `fast_decode_chunk`, `process_lz_runs`, `process_mode` (short/medium/long token dispatch) |
| `090-high-lz.wat` | ~780 | High LZ: `high_decode_chunk_lz` (ReadLzTable + UnpackOffsets + ResolveTokens + Execute) |
| `100-decompress.wat` | ~340 | Top-level exports: `decompress`, `decompressChunk`, `decode_block` |
| `900-data.wat` | 1 | Module closing paren |

## Memory Layout

```
Address Range          Size    Purpose
─────────────────────────────────────────────────────────��
0x00000000..0x000000FF   256B  Header globals, parsed fields, fixed-address state
0x00100000..0x003FFFFF   ~3MB  Scratch region (LUTs, entropy buffers, HLZ working space)
0x00400000..             var   INPUT_BASE — compressed data placed here by JS
(dynamic)                var   OUTPUT_BASE — set by JS right after input
```

Memory starts at 128 pages (8MB) and grows on demand via `memory.grow` up to 4GB max.

### Fixed-Address State (0x00..0xFF)

| Address | Name | Used By |
|---------|------|---------|
| 0x00-0x1F | Header fields | `parseFrameHeader` (version, flags, codec, level, blockSize, contentSize) |
| 0x20-0x24 | Block info | `parseBlockHeader` (decompSize, isUncompressed) |
| 0x30-0x3C | BR forward | Bit reader: p, pEnd, bits, bitPos |
| 0x40-0x4C | BR2 backward | Backward bit reader: p, pEnd, bits, bitPos |
| 0x50 | ENT_DECODED_SIZE | Last entropy decode output size |
| 0x60-0x98 | FastLzTable | Stream pointers: lit, cmd, len, off16, off32, cmd2 |
| 0x9C | savedDist | Fast LZ recent offset (persisted across 64KB iterations) |
| 0xC0-0xC8 | GR BitReader2 | Golomb-Rice decoder: p, pEnd, bitPos |
| 0xD0 | SC dstStart | Per-chunk destination start (SC mode) or block start (non-SC) |
| 0xD4 | lastOffset | High LZ delta mode: previous token's match offset |

### Scratch Region (0x00100000+)

| Address | Global | Size | Purpose |
|---------|--------|------|---------|
| 0x00100100 | LUT_BASE | — | Base for lookup tables |
| 0x00101100 | DECODE_SCRATCH | 256KB | Fast decoder entropy stream output |
| 0x00141100 | OFF32_SCRATCH | 256KB | Fast decoder far offset backing |
| 0x00200000 | HUFF_LUT_LEN | 8KB | Huffman forward + reverse LUTs (4 tables) |
| 0x00202540 | (data segment) | 48B | CodePrefixOrg |
| 0x00203000 | (data segment) | 1.3KB | Golomb-Rice value + length tables |
| 0x00210000 | TANS_DATA | 1.5KB | tANS frequency data |
| 0x00210600 | TANS_LUT | 32KB | tANS 4-way interleaved LUT |
| 0x00220000 | TANS_GR_RICE | 1KB | tANS Golomb-Rice scratch |
| 0x00228000 | (inline) | 2KB | u32 length stream buffer |
| 0x00230000 | HLZ_TABLE | 32B | High LZ stream pointers (lit, cmd, offs, len) |
| 0x00230020 | HLZ_SCRATCH | 256KB | High LZ entropy decode scratch |
| 0x00270020 | HLZ_OFFS_BUF | 512KB | High LZ unpacked offsets |
| 0x002E0000 | (inline) | var | lowBits save area for offset scaling |
| 0x002F0020 | HLZ_LEN_BUF | 512KB | High LZ unpacked lengths |
| 0x00370020 | HLZ_TOKEN_BUF | 512KB | High LZ resolved token array |

## Codec Pipelines

### Fast Codec (L1-L5)

Each 256KB chunk contains up to two 128KB sub-chunks. Each sub-chunk is processed by:

1. **ReadLzTable** (`fast_decode_chunk`): Decode 5 entropy streams (literal, command, length, off16, off32) using the entropy dispatcher
2. **ProcessLzRuns** (`process_lz_runs`): Two 64KB iterations, each calling `process_mode`
3. **ProcessMode** (`process_mode`): Command dispatch loop:
   - **Short tokens** (cmd >= 24, ~90% of commands): litLen 0-7, matchLen 0-15, off16 offset. SIMD copy128 for literals, copy128/copy64 for matches. Fast-path loop for consecutive short tokens.
   - **Medium tokens** (cmd 3-23): matchLen = cmd+5, off32 offset. copy128+copy128 for match.
   - **Long tokens** (cmd 0-2): cmd=0 long literal, cmd=1 long match+off16, cmd=2 long match+off32.
   - **Delta mode** (mode 0): Literals coded as delta from previous match offset byte.

### High Codec (L6-L11)

Each 128KB sub-chunk is processed by `high_decode_chunk_lz`:

1. **ReadLzTable**: Decode 4 entropy streams (literal, command, packed offsets, packed litlens), plus optional extra offset stream for offset scaling
2. **UnpackOffsets**: Bidirectional bitstream (forward bitsA + backward bitsB) decoding `ReadDistance` (nb bits from cmd byte, base from cmd & 7) with offset scaling modes (0=raw, 1=standard, >1=scaled with lowBits)
3. **ResolveTokens**: Command byte `[offIdx:2][matchLen:4][litLen:2]` with offset carousel (3 recent offsets), matchLen/litLen overflow from length streams
4. **ExecuteTokens**: Copy literals (SIMD wildcopy16 for raw, byte-at-a-time for delta) + copy matches (`$match_copy` with SIMD/byte-at-a-time)

**Self-contained (SC) mode** (L6-L8): Each chunk is independently decompressible (offset=0 per chunk). Enables parallel decompression. SC prefix bytes (8 bytes per chunk) are restored after parallel decode.

**Non-SC mode** (L9-L11): Chunks reference cross-block data. dstStart = block start.

## Entropy Types

The entropy dispatcher (`high_decode_bytes`) handles 6 types:

| Type | Name | Description |
|------|------|-------------|
| 0 | Memcopy | Raw bytes, no compression |
| 1 | tANS | Asymmetric Numeral Systems (5-state interleaved) |
| 2 | Huffman 2-way | 3-stream parallel Huffman with 11-bit LUT |
| 3 | RLE | Run-length encoding with entropy-coded prefix |
| 4 | Huffman 4-way | Same as type 2 (different stream count marker) |
| 5 | Recursive | Entropy-within-entropy (re-enters dispatcher) |

Huffman has two code-length formats: OLD (gamma-coded, type 2/4 with flag) and NEW (Golomb-Rice coded, type 2/4 without flag). tANS has two table formats: sparse (bit=0) and Golomb-Rice (bit=1).

## JS API Internals

### slz.mjs

- **Environment detection**: Node vs browser, SharedArrayBuffer availability
- **getWasmModule()**: Compiles WASM once. Uses `compileStreaming` in browsers for faster cold start. Catches `CompileError` with a clear SIMD128 requirement message.
- **ensureCapacity()**: Places output right after input (256-byte aligned), grows memory on demand
- **scanFrame()**: Parses SLZ1 header + first block to determine codec, SC mode, and chunk boundaries
- **WorkerPool**: Dispatch-as-ready pattern — chunks start decompressing as workers come online. Pool size = min(coreCount, dispatchable chunks).
- **maxDecompressedSize**: Default 1GB guard against decompression bombs

### slz-worker.js

- Receives pre-compiled `WebAssembly.Module` (not raw bytes)
- Calls `decompressChunk(inputLen, dstSize)` directly (no synthetic frame)
- Grows memory on demand per chunk with OOM handling

## Build

```bash
bash build.sh   # concatenates wat/*.wat → slz-decompress.wat → wat2wasm → .wasm
```

The concatenated `slz-decompress.wat` is a build artifact (gitignored). Only `wat/*.wat` source files and `slz-decompress.wasm` (distributable) are committed.

Requires [wabt](https://github.com/WebAssembly/wabt) (`wat2wasm`).

## Testing

- `test.mjs`: 26 low-level WASM tests (frame parsing, bit readers, all codec levels, boundary cases)
- `test-api.mjs`: 13 API-level tests (single-thread + parallel) + benchmarks
- Test vectors in `test-vectors/` (gitignored, generated by `export-test-data.csx`)

## Performance (enwik8 100MB)

| Level | Single-thread | Parallel (24-core) |
|-------|--------------|-------------------|
| L1 | 1.22 GB/s | — |
| L6 | 530 MB/s | 5.4 GB/s |
| L9 | 560 MB/s | — |

Binary size: 25KB. Initial memory: 8MB (grows on demand).
