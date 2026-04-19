# StreamLZ Zig — Source Layout

```
format/   Wire format: frame headers, block headers, constants, sidecar format
io/       Bit-level readers/writers, SIMD copy helpers
decode/   Decompression: Fast (L1-5), High (L6-11), parallel dispatch
encode/   Compression:   Fast (L1-5), High (L6-11), entropy coding
platform/ OS-specific: memory query (thread budget sizing)
```

**Two codecs:**
- **Fast** (levels 1-5) — greedy/lazy parser, raw or entropy-coded literals
- **High** (levels 6-11) — optimal DP parser, full entropy coding

**Entry points:**
- CLI: `main.zig`
- Library: `streamlz.zig` (re-exports `compressFramed` / `decompressFramed`)

See `../STRUCTURE.md` for the phase roadmap and full file map.
