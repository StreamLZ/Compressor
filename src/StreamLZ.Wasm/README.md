# StreamLZ WASM Decompressor

High-performance LZ decompression for the browser and Node.js. Hand-coded WebAssembly (WAT) with SIMD128 and automatic parallel decompression.

## Performance (enwik8 100MB)

| Level | Single-thread | Parallel (24-core) | Ratio |
|-------|--------------|-------------------|-------|
| L1 | 1.18 GB/s | — | 58.6% |
| L6 | 530 MB/s | **5.4 GB/s** | 33.7% |
| L9 | 560 MB/s | — | 27.4% |

## Usage

```js
import { decompress, shutdown } from 'streamlz';

// Decompress (auto-detects level, auto-parallelizes L6-L8)
const decompressed = await decompress(compressedData);

// Force single-threaded
const result = await decompress(compressedData, { threads: 1 });

// Explicit thread count
const result = await decompress(compressedData, { threads: 8 });

// Clean up workers when done
shutdown();
```

## Features

- **All levels L1-L11** — Fast codec (L1-L5) and High codec (L6-L11)
- **SIMD128** — 16-byte vector copies for match and literal operations
- **Parallel L6-L8** — Self-contained chunks decompressed across Web Workers
- **Auto-detection** — Detects codec, SC mode, and hardware concurrency
- **Dynamic memory** — Starts at 8MB, grows on demand up to 4GB
- **25KB WASM** — Hand-coded WAT, no Emscripten or Rust
- **Zero dependencies** — No build tools required at runtime

## Browser Requirements

For parallel decompression (L6-L8), the page must be cross-origin isolated:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without these headers, decompression falls back to single-threaded mode.

## Performance Notes

- **Requires SIMD128 and bulk-memory** — supported in all modern browsers (Chrome 91+, Firefox 89+, Safari 16.4+). Older browsers will get a clear error message at load time.
- **Main thread blocking** — single-threaded decompression of large files (>10MB) can take tens of milliseconds. For UI-sensitive applications, run decompression in a Web Worker to avoid frame drops.
- **L6-L8 parallel** decompression already runs in workers and does not block the main thread.

## Building from Source

Requires [wabt](https://github.com/WebAssembly/wabt) (WebAssembly Binary Toolkit):

```bash
npm install -g wabt
bash build.sh
```

The build script concatenates the WAT source files under `wat/` and compiles to WASM:

```
wat/
  000-module.wat        — memory, globals, constants
  010-frame.wat         — frame/block header parsing
  020-bitreader.wat     — forward/backward bit readers
  030-copy.wat          — SIMD copy primitives
  040-entropy.wat       — entropy dispatcher, recursive, RLE
  050-huffman.wat       — Huffman decoder (old + new paths)
  060-tans.wat          — tANS decoder (sparse + Golomb-Rice)
  070-golomb-rice.wat   — Golomb-Rice decoders
  080-fast-lz.wat       — Fast codec (L1-L5)
  090-high-lz.wat       — High codec (L6-L11)
  100-decompress.wat    — top-level entry points
  900-data.wat          — module close
```

## Compressing Data

Use the .NET StreamLZ library to compress:

```bash
dotnet tool install -g slz
slz -l 6 input.bin output.slz
```

## License

MIT
