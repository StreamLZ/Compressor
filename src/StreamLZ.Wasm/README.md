# StreamLZ WASM Decompressor

High-performance LZ decompression for the browser and Node.js. Hand-coded WebAssembly (WAT) with SIMD128 and automatic parallel decompression.

## Performance (enwik8 100MB)

| Level | Single-thread | Parallel (24-core) | Ratio |
|-------|--------------|-------------------|-------|
| L1 | 1.3 GB/s | — | 58.6% |
| L6 | 530 MB/s | **5.1 GB/s** | 33.7% |
| L9 | 610 MB/s | — | 27.4% |

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
- **Large files** — Dynamic memory growth up to 4GB via `memory.grow`
- **25KB WASM** — Entire decompressor in a single hand-coded WAT file
- **Zero dependencies** — No Emscripten, no Rust, no build tools required

## Browser Requirements

For parallel decompression (L6-L8), the page must be cross-origin isolated:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without these headers, decompression falls back to single-threaded mode.

## Building from Source

```bash
npm install -g wabt
bash build.sh
```

## Compressing Data

Use the .NET StreamLZ library to compress:

```bash
dotnet tool install -g slz
slz -l 6 input.bin output.slz
```

## License

MIT
