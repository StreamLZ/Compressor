# SLZ1 Frame Format Specification

**Version:** 1
**Status:** Stable (backward-compatible changes only)
**Byte order:** Little-endian unless otherwise noted
**Notation:** `BSR(x)` denotes Bit Scan Reverse — the 0-based index of the most significant set bit, equivalent to `floor(log2(x))` for x > 0.

---

## Overview

SLZ1 is a framed container format for StreamLZ compressed data. It wraps one or more independently compressed blocks with a header describing the codec, level, and optional metadata. The frame format enables streaming compression/decompression of arbitrarily large data using a sliding window.

The design is similar in spirit to LZ4 frames and Zstandard frames: a magic number, a descriptor, a sequence of blocks, and an optional checksum.

---

## Frame Structure

```
┌──────────────────────┐
│    Frame Header       │  10-22 bytes
├──────────────────────┤
│    Block 0            │  8 bytes header + payload
├──────────────────────┤
│    Block 1            │  8 bytes header + payload
├──────────────────────┤
│    ...                │
├──────────────────────┤
│    End Mark           │  4 bytes (0x00000000)
├──────────────────────┤
│    Content Checksum   │  4 bytes (optional)
└──────────────────────┘
```

---

## Frame Header

**Minimum size:** 10 bytes (no optional fields)
**Maximum size:** 22 bytes (all optional fields present)

```
Offset  Size  Field
─────────────────────────────────────────
0       4     Magic number (0x53_4C_5A_31 = "SLZ1")
4       1     Version (must be 1; decoders must reject values > 1)
5       1     Flags (see below)
6       1     Codec ID
7       1     Compression level (1-9)
8       1     Block size (log2 encoding, see below)
9       1     Reserved (must be 0)
10      8     Content size (int64, present if flag bit 0 set)
18      4     Dictionary ID (uint32, present if flag bit 3 set)
```

### Flags (byte at offset 5)

| Bit | Name                 | Meaning                                           |
|-----|----------------------|---------------------------------------------------|
| 0   | ContentSizePresent   | 8-byte content size follows the fixed header       |
| 1   | ContentChecksum      | 4-byte XXH32 checksum after the end mark           |
| 2   | BlockChecksums       | 4-byte XXH32 checksum after each block payload     |
| 3   | DictionaryIdPresent  | 4-byte dictionary ID follows content size (if any) |
| 4-7 | Reserved             | Must be 0                                          |

### Codec ID (byte at offset 6)

| Value | Codec | Description                              |
|-------|-------|------------------------------------------|
| 0     | High  | High-ratio codec (optimal/lazy parsing)  |
| 1     | Fast  | Fast codec (greedy/lazy parsing)         |

### Block Size Encoding (byte at offset 8)

The block size is stored as `log2(blockSize) - 16`. To decode:

```
blockSize = 1 << (value + 16)
```

| Stored value | Block size |
|-------------|------------|
| 0           | 64 KB      |
| 1           | 128 KB     |
| 2           | 256 KB (default) |
| 3           | 512 KB     |
| 4           | 1 MB       |
| 5           | 2 MB       |
| 6           | 4 MB (maximum)   |

The block size must be a power of 2 in the range [64 KB, 4 MB].

---

## Block Header

Each block is preceded by an 8-byte header:

```
Offset  Size  Field
─────────────────────────────────────────
0       4     Compressed size (uint32)
4       4     Decompressed size (int32)
```

**Compressed size field:**
- Bit 31 (0x80000000): if set, the block is **uncompressed** (stored). The payload contains raw bytes with **no internal block header and no chunk headers** — the decompressor copies the payload directly to the output.
- Bits 0-30: compressed payload size in bytes.
- A value of 0x00000000 in the first 4 bytes is the **end mark** (no decompressed size follows).

> **Uncompressed block precedence:** When bit 31 is set in the block header, the entire payload is raw data. The internal block header (2-byte codec/flags) and chunk headers are **not present**. The internal block header's own `Uncompressed` flag (byte 0, bit 7) is a separate mechanism used within compressed blocks to signal that individual chunks within the block are stored uncompressed but still wrapped in the chunk header structure.

**Decompressed size field:**
- The number of bytes this block produces when decompressed.
- For the last block in a stream, this may be smaller than the frame's block size.

---

## End Mark

The end of the block sequence is signaled by 4 zero bytes:

```
00 00 00 00
```

This is distinguished from a valid block header because no valid block has a compressed size of 0.

---

## Content Checksum (optional)

If the `ContentChecksum` flag is set in the frame header, a 4-byte XXH32 checksum of the entire uncompressed content follows immediately after the end mark.

---

## Block Payload: Internal Block Header

Within each compressed block payload, a 2-byte **internal block header** describes the codec and flags for the block's chunks:

```
Byte 0 (bit layout):
  [3:0]  Magic nibble (must be 0x5)
  [4]    SelfContained flag
  [5]    TwoPhase flag
  [6]    RestartDecoder flag
  [7]    Uncompressed flag

Byte 1 (bit layout):
  [6:0]  DecoderType (0=High, 1=Fast, 2=Turbo)
  [7]    UseChecksums flag
```

### DecoderType values

| Value | Type  | Description                                    |
|-------|-------|------------------------------------------------|
| 0     | High  | 4-stream format (cmd, offs, lit, len)          |
| 1     | Fast  | 6-stream format (lit, deltalit, cmd, off16, off32, len) |
| 2     | Turbo | Same wire format as Fast                       |

### SelfContained flag

When set, each chunk within the block is independently decompressible with no cross-chunk LZ back-references. This enables parallel decompression. When clear, chunks may reference data decoded by earlier chunks within the same block.

---

## Chunk Structure

Each block is divided into one or more **chunks** of up to 256 KB (262,144 bytes). The chunk is the fundamental unit of compression.

### Chunk Header

Each chunk begins with a 4-byte little-endian header, optionally followed by a 3-byte checksum:

```
Bytes 0-3 (little-endian uint32):
  [ChunkSizeBits-1 : 0]  Compressed size minus 1
  [ChunkSizeBits+1 : ChunkSizeBits]  Type (0=normal, 1=memset)
  [31 : ChunkSizeBits+2]  Reserved (must be 0)
```

With the default `ChunkSizeBits = 18` (256 KB chunk):
- Bits [17:0] = compressed size minus 1 (0 .. 262,143)
- Bits [19:18] = type
- Bits [31:20] = reserved

**Type values:**

| Value | Meaning | Payload |
|-------|---------|---------|
| 0 | Normal | Compressed data follows |
| 1 | Memset | Byte at offset 4 is the fill value |

If the `UseChecksums` flag is set in the internal block header, 3 bytes of checksum follow the 4-byte header (bytes 4-6). This is the upper 24 bits of a CRC32 of the chunk's compressed payload (big-endian byte order).

**Chunk sizes:**
- Normal chunk: 4 bytes header (+ 3 bytes checksum if enabled) + compressed payload
- Memset chunk: 5 bytes total (4-byte header + 1-byte fill value)
- Uncompressed chunk: compressed size equals decompressed size; payload is raw bytes

---

## Codec Wire Formats

### Fast/Turbo Codec (6-stream format)

The Fast codec splits each chunk into up to two 64 KB sub-chunks, with six parallel byte streams:

| Stream      | Type     | Content                                         |
|-------------|----------|-------------------------------------------------|
| Cmd         | byte     | Flag/command tokens encoding literal+match pairs |
| Lit         | byte     | Raw literal bytes                                |
| DeltaLit    | byte     | Delta-coded literal bytes (optional)             |
| Off16       | uint16   | Near (16-bit) match offsets                      |
| Off32       | uint32   | Far (32-bit) match offsets                       |
| Length      | byte     | Variable-length extra lengths                    |

**Flag byte encoding (Cmd stream):**

| Value      | Meaning                                                |
|------------|--------------------------------------------------------|
| >= 24      | Inline literal+match: bits[2:0]=literal count, bits[6:3]=match length, bit[7]=use recent offset |
| 0          | Long literal run: read length from Length stream (+64)  |
| 1          | Long near-offset match: read length from Length stream (+91) |
| 2          | Long far-offset match: read length from Length stream (+29) |
| 3..23      | Short far-offset match: length = flagbyte + 5          |

Each sub-chunk's streams are entropy-coded (Huffman or tANS) or stored raw, with a per-stream header indicating the encoding method.

### High Codec (4-stream format)

The High codec uses four streams per chunk:

| Stream  | Type    | Content                                        |
|---------|---------|------------------------------------------------|
| Cmd     | byte    | Interleaved literal-length and match-length tokens |
| Offs    | int32   | Match offsets (when not using a recent offset)  |
| Lit     | byte    | Raw literal bytes                               |
| Len     | int32   | Overflow lengths (when token can't hold the full length) |

The command stream encodes (literal_length, match_length, use_recent_offset) triples. Short lengths are packed inline; longer lengths spill into the Len stream. The High codec supports a recent-offset carousel of the last 3 offsets, selectable by index in the command token.

---

## Entropy Coding

Individual streams within a chunk are compressed using one of:

1. **Raw (memcopy)** — stream is stored uncompressed
2. **Huffman** — canonical Huffman coding with code lengths transmitted as a compact header
3. **tANS** — table-based asymmetric numeral systems with 4-way interleaved state

The choice is made per-stream based on a cost model that estimates the compressed size of each option. The stream header byte identifies which method was used.

### Huffman Code Length Encoding

Code lengths (0-11 bits) are transmitted using a two-level scheme: first a set of "code length code lengths" (3-bit values for a small alphabet), then the actual code lengths are entropy-coded using that meta-code.

### tANS Table Encoding

The tANS frequency table is transmitted as a sequence of symbol counts using variable-length coding. The decoder rebuilds the decoding table from these frequencies. Four interleaved tANS states are maintained for throughput.

---

## Sliding Window

In the framed streaming API, a **sliding window** provides cross-block back-references:

- The compressor maintains a buffer of `windowSize + blockSize` bytes.
- After compressing each block, decoded output slides forward: the most recent `windowSize` bytes are retained as dictionary context for the next block.
- The decompressor maintains the same window and passes the dictionary context to the block decoder so LZ back-references can reach into previously decoded blocks.
- Default window size: 128 MB. Maximum: 1 GB.

When `SelfContained` mode is enabled, cross-chunk references within a block are disabled (each chunk is independent), but cross-block references via the sliding window are still active unless the frame compressor operates in fully independent mode.

**Dictionary ID:** The optional `DictionaryId` field in the frame header is an opaque 4-byte identifier that tags which pre-shared dictionary was used during compression. It does **not** carry dictionary content — both compressor and decompressor must have the dictionary available externally. If present, the dictionary is logically prepended to the sliding window before the first block (i.e., it occupies the initial window state so the first block can reference it via LZ back-references).

---

## Offset Encoding

Match offsets are encoded in two ranges:

### Low range (offset < 16,776,456)

```
bucket = BSR(offset + 760) - 9
nibble = (offset - 8) & 0xF
packed = nibble + 16 * bucket
```

This produces a single byte (0x00..0xEF) that the entropy coder compresses.

### High range (offset >= 16,776,456)

```
extraBits = BSR(offset - 16,710,912)
packed = extraBits | 0xF0
```

The packed byte (0xF0..0xFF) is followed by `extraBits` raw bits encoding the remainder.

---

## Constants Summary

| Constant           | Value       | Description                        |
|--------------------|-------------|------------------------------------|
| Magic number       | 0x534C5A31  | "SLZ1" in little-endian            |
| Version            | 1           | Current format version             |
| Chunk size         | 262,144     | 256 KB                             |
| Min block size     | 65,536      | 64 KB                              |
| Max block size     | 4,194,304   | 4 MB                               |
| Default block size | 262,144     | 256 KB (= chunk size)              |
| Max dictionary     | 1,073,741,824 | 1 GB                             |
| Default window     | 134,217,728 | 128 MB                             |
| SafeSpace          | 64          | Extra bytes needed past output end |
| Huffman LUT bits   | 11          | 2048-entry decode table            |
| Initial copy bytes | 8           | Verbatim bytes at chunk start      |
