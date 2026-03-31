(module
  ;; ============================================================
  ;; StreamLZ WASM Decompressor — L1 (Fast) only
  ;; Hand-coded WAT for minimum size and maximum performance.
  ;; ============================================================
  ;;
  ;; Memory layout (64 KB pages):
  ;;   0x00000000 .. 0x000000FF  —  Scratch / parsed header (256 B)
  ;;   0x00000100 .. 0x03FFFFFF  —  Input buffer  (up to 64 MB)
  ;;   0x04000100 .. 0x0BFFFFFF  —  Output buffer (up to 128 MB)
  ;;   0x0C000100 .. 0x0C0010FF  —  Huffman LUT   (2048 * 2 = 4 KB)
  ;;   0x0C001100 .. 0x0C0810FF  —  Decode scratch (512 KB)
  ;;
  ;; All offsets are byte addresses in linear memory.
  ;; ============================================================

  (memory (export "memory") 3200)  ;; 3200 pages = 200 MB

  ;; ── Constants ──────────────────────────────────────────────
  ;; Frame magic: 'S','L','Z','1' = 0x534C5A31 written as LE bytes 31 5A 4C 53
  ;; i32.load reads LE, so we compare against 0x534C5A31
  (global $SLZ1_MAGIC i32 (i32.const 0x534C5A31))
  (global $FRAME_VERSION i32 (i32.const 1))

  ;; Memory region base addresses
  (global $INPUT_BASE  i32 (i32.const 0x00000100))
  (global $OUTPUT_BASE i32 (i32.const 0x04000100))
  (global $LUT_BASE    i32 (i32.const 0x0C000100))
  (global $SCRATCH_BASE i32 (i32.const 0x0C001100))

  ;; Parsed header fields (stored at address 0x00..0xFF)
  ;; Offsets within the scratch/header region:
  (global $HDR_VERSION  i32 (i32.const 0x00))  ;; u8
  (global $HDR_FLAGS    i32 (i32.const 0x01))  ;; u8
  (global $HDR_CODEC    i32 (i32.const 0x02))  ;; u8
  (global $HDR_LEVEL    i32 (i32.const 0x03))  ;; u8
  (global $HDR_BLOCKSIZE i32 (i32.const 0x04)) ;; i32
  (global $HDR_CONTENTSIZE i32 (i32.const 0x08)) ;; i64 (8 bytes)
  (global $HDR_HEADERSIZE i32 (i32.const 0x10))  ;; i32
  (global $HDR_DICTID   i32 (i32.const 0x14))  ;; u32

  ;; Flag bits
  (global $FLAG_CONTENT_SIZE i32 (i32.const 1))
  (global $FLAG_CONTENT_CHECKSUM i32 (i32.const 2))
  (global $FLAG_BLOCK_CHECKSUMS i32 (i32.const 4))
  (global $FLAG_DICT_ID i32 (i32.const 8))

  ;; Block header constants
  (global $BLOCK_UNCOMPRESSED_FLAG i32 (i32.const 0x80000000))
  (global $MIN_BLOCK_SIZE_LOG2 i32 (i32.const 16))  ;; log2(64KB)

  ;; ── Exported getters for test harness ──────────────────────

  (func (export "getVersion") (result i32)
    (i32.load8_u (global.get $HDR_VERSION))
  )
  (func (export "getFlags") (result i32)
    (i32.load8_u (global.get $HDR_FLAGS))
  )
  (func (export "getCodec") (result i32)
    (i32.load8_u (global.get $HDR_CODEC))
  )
  (func (export "getLevel") (result i32)
    (i32.load8_u (global.get $HDR_LEVEL))
  )
  (func (export "getBlockSize") (result i32)
    (i32.load (global.get $HDR_BLOCKSIZE))
  )
  (func (export "getContentSize") (result i64)
    (i64.load (global.get $HDR_CONTENTSIZE))
  )
  (func (export "getHeaderSize") (result i32)
    (i32.load (global.get $HDR_HEADERSIZE))
  )
  (func (export "getDictId") (result i32)
    (i32.load (global.get $HDR_DICTID))
  )
  (func (export "getInputBase") (result i32)
    (global.get $INPUT_BASE)
  )
  (func (export "getOutputBase") (result i32)
    (global.get $OUTPUT_BASE)
  )

  ;; ── parseFrameHeader ───────────────────────────────────────
  ;; Parses the SLZ1 frame header from the input buffer.
  ;; Parameters:
  ;;   inputLen — number of bytes available in the input buffer
  ;; Returns:
  ;;   header size in bytes on success, -1 on failure
  ;; Parsed fields are stored at addresses 0x00..0x1F.

  (func $parseFrameHeader (export "parseFrameHeader") (param $inputLen i32) (result i32)
    (local $pos i32)
    (local $base i32)
    (local $flags i32)
    (local $blockSizeLog2 i32)
    (local $blockSize i32)

    (local.set $base (global.get $INPUT_BASE))

    ;; Need at least 10 bytes for minimum header
    (if (i32.lt_u (local.get $inputLen) (i32.const 10))
      (then (return (i32.const -1)))
    )

    ;; Check magic: read 4 bytes LE at input[0]
    (if (i32.ne
          (i32.load (local.get $base))
          (global.get $SLZ1_MAGIC))
      (then (return (i32.const -1)))
    )

    (local.set $pos (i32.const 4))

    ;; Version — must be 1
    (if (i32.ne
          (i32.load8_u (i32.add (local.get $base) (local.get $pos)))
          (global.get $FRAME_VERSION))
      (then (return (i32.const -1)))
    )
    (i32.store8 (global.get $HDR_VERSION) (i32.const 1))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; Flags
    (local.set $flags (i32.load8_u (i32.add (local.get $base) (local.get $pos))))
    (i32.store8 (global.get $HDR_FLAGS) (local.get $flags))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; Codec
    (i32.store8 (global.get $HDR_CODEC)
      (i32.load8_u (i32.add (local.get $base) (local.get $pos))))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; Level
    (i32.store8 (global.get $HDR_LEVEL)
      (i32.load8_u (i32.add (local.get $base) (local.get $pos))))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; BlockSizeLog2 — stored as (log2(blockSize) - log2(minBlockSize))
    (local.set $blockSizeLog2
      (i32.add
        (i32.load8_u (i32.add (local.get $base) (local.get $pos)))
        (global.get $MIN_BLOCK_SIZE_LOG2)))
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; Validate blockSizeLog2 range: 16..22 (64KB..4MB)
    (if (i32.or
          (i32.lt_u (local.get $blockSizeLog2) (i32.const 16))
          (i32.gt_u (local.get $blockSizeLog2) (i32.const 22)))
      (then (return (i32.const -1)))
    )
    (local.set $blockSize (i32.shl (i32.const 1) (local.get $blockSizeLog2)))
    (i32.store (global.get $HDR_BLOCKSIZE) (local.get $blockSize))

    ;; Reserved byte — skip
    (local.set $pos (i32.add (local.get $pos) (i32.const 1)))

    ;; ContentSize (optional, 8 bytes LE)
    (i64.store (global.get $HDR_CONTENTSIZE) (i64.const -1))
    (if (i32.and (local.get $flags) (global.get $FLAG_CONTENT_SIZE))
      (then
        ;; Need 8 more bytes
        (if (i32.lt_u (local.get $inputLen)
              (i32.add (local.get $pos) (i32.const 8)))
          (then (return (i32.const -1)))
        )
        (i64.store (global.get $HDR_CONTENTSIZE)
          (i64.load (i32.add (local.get $base) (local.get $pos))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 8)))
      )
    )

    ;; DictionaryId (optional, 4 bytes LE)
    (i32.store (global.get $HDR_DICTID) (i32.const 0))
    (if (i32.and (local.get $flags) (global.get $FLAG_DICT_ID))
      (then
        (if (i32.lt_u (local.get $inputLen)
              (i32.add (local.get $pos) (i32.const 4)))
          (then (return (i32.const -1)))
        )
        (i32.store (global.get $HDR_DICTID)
          (i32.load (i32.add (local.get $base) (local.get $pos))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 4)))
      )
    )

    ;; Store header size
    (i32.store (global.get $HDR_HEADERSIZE) (local.get $pos))

    ;; Return header size
    (local.get $pos)
  )

  ;; ── parseBlockHeader ───────────────────────────────────────
  ;; Reads an 8-byte block header from input at offset $pos.
  ;; Returns compressed size (0 = end mark, -1 = error).
  ;; Writes decompressed size and isUncompressed flag to memory:
  ;;   address 0x20: decompressedSize (i32)
  ;;   address 0x24: isUncompressed   (i32, 0 or 1)

  (global $BLK_DECOMP_SIZE i32 (i32.const 0x20))
  (global $BLK_IS_UNCOMP   i32 (i32.const 0x24))

  (func (export "getBlockDecompSize") (result i32)
    (i32.load (global.get $BLK_DECOMP_SIZE))
  )
  (func (export "getBlockIsUncompressed") (result i32)
    (i32.load (global.get $BLK_IS_UNCOMP))
  )

  (func $parseBlockHeader (export "parseBlockHeader") (param $pos i32) (param $inputLen i32) (result i32)
    (local $addr i32)
    (local $value i32)
    (local $compSize i32)

    ;; Need at least 4 bytes to check for end mark
    (if (i32.lt_u
          (i32.sub (local.get $inputLen) (local.get $pos))
          (i32.const 4))
      (then (return (i32.const -1)))
    )

    (local.set $addr (i32.add (global.get $INPUT_BASE) (local.get $pos)))

    ;; Read first 4 bytes LE
    (local.set $value (i32.load (local.get $addr)))

    ;; End mark: value == 0 (only 4 bytes)
    (if (i32.eqz (local.get $value))
      (then
        (i32.store (global.get $BLK_DECOMP_SIZE) (i32.const 0))
        (i32.store (global.get $BLK_IS_UNCOMP) (i32.const 0))
        (return (i32.const 0))
      )
    )

    ;; Full block header is 8 bytes — need 4 more
    (if (i32.lt_u
          (i32.sub (local.get $inputLen) (local.get $pos))
          (i32.const 8))
      (then (return (i32.const -1)))
    )

    ;; isUncompressed = high bit set
    (i32.store (global.get $BLK_IS_UNCOMP)
      (i32.shr_u (local.get $value) (i32.const 31)))

    ;; compressedSize = value & ~0x80000000
    (local.set $compSize
      (i32.and (local.get $value)
        (i32.xor (global.get $BLOCK_UNCOMPRESSED_FLAG) (i32.const -1))))

    ;; Read decompressedSize from next 4 bytes
    (i32.store (global.get $BLK_DECOMP_SIZE)
      (i32.load (i32.add (local.get $addr) (i32.const 4))))

    ;; Validate: both sizes must be > 0
    (if (i32.or
          (i32.le_s (local.get $compSize) (i32.const 0))
          (i32.le_s (i32.load (global.get $BLK_DECOMP_SIZE)) (i32.const 0)))
      (then (return (i32.const -1)))
    )

    (local.get $compSize)
  )

  ;; ============================================================
  ;; Phase 2: Bit Reader
  ;; ============================================================
  ;; State stored at fixed addresses (0x30..0x4F):
  ;;   0x30: p      (i32) — current read position (byte address)
  ;;   0x34: pEnd   (i32) — end of stream (byte address)
  ;;   0x38: bits   (i32) — accumulated bits (MSB consumed first)
  ;;   0x3C: bitPos (i32) — next byte lands here; <= 0 means >= 24 valid bits
  ;;
  ;; Second reader (backward) at 0x40..0x4F same layout.

  (global $BR_P      i32 (i32.const 0x30))
  (global $BR_PEND   i32 (i32.const 0x34))
  (global $BR_BITS   i32 (i32.const 0x38))
  (global $BR_BITPOS i32 (i32.const 0x3C))

  (global $BR2_P      i32 (i32.const 0x40))
  (global $BR2_PEND   i32 (i32.const 0x44))
  (global $BR2_BITS   i32 (i32.const 0x48))
  (global $BR2_BITPOS i32 (i32.const 0x4C))

  ;; ── br_init ────────────────────────────────────────────────
  ;; Initialize forward bit reader.
  ;; p = start address, pEnd = end address, bits = 0, bitPos = 24
  (func $br_init (export "br_init") (param $p i32) (param $pEnd i32)
    (i32.store (global.get $BR_P) (local.get $p))
    (i32.store (global.get $BR_PEND) (local.get $pEnd))
    (i32.store (global.get $BR_BITS) (i32.const 0))
    (i32.store (global.get $BR_BITPOS) (i32.const 24))
  )

  ;; ── br_refill ──────────────────────────────────────────────
  ;; Refill forward: load bytes while bitPos > 0 and p < pEnd.
  ;; bits |= *p << bitPos; bitPos -= 8; p++
  (func $br_refill (export "br_refill")
    (local $p i32)
    (local $pEnd i32)
    (local $bits i32)
    (local $bitPos i32)

    (local.set $p (i32.load (global.get $BR_P)))
    (local.set $pEnd (i32.load (global.get $BR_PEND)))
    (local.set $bits (i32.load (global.get $BR_BITS)))
    (local.set $bitPos (i32.load (global.get $BR_BITPOS)))

    (block $done
      (loop $loop
        ;; while bitPos > 0 && p < pEnd
        (br_if $done (i32.le_s (local.get $bitPos) (i32.const 0)))
        (br_if $done (i32.ge_u (local.get $p) (local.get $pEnd)))

        ;; bits |= *p << bitPos
        (local.set $bits
          (i32.or (local.get $bits)
            (i32.shl
              (i32.load8_u (local.get $p))
              (local.get $bitPos))))

        ;; bitPos -= 8
        (local.set $bitPos (i32.sub (local.get $bitPos) (i32.const 8)))
        ;; p++
        (local.set $p (i32.add (local.get $p) (i32.const 1)))

        (br $loop)
      )
    )

    (i32.store (global.get $BR_P) (local.get $p))
    (i32.store (global.get $BR_BITS) (local.get $bits))
    (i32.store (global.get $BR_BITPOS) (local.get $bitPos))
  )

  ;; ── br_read_bits_no_refill ─────────────────────────────────
  ;; Read n bits from MSB without refilling. n must be >= 1.
  ;; Returns the extracted value.
  (func $br_read_bits_no_refill (export "br_read_bits_no_refill") (param $n i32) (result i32)
    (local $bits i32)
    (local $r i32)

    (local.set $bits (i32.load (global.get $BR_BITS)))

    ;; r = bits >> (32 - n)
    (local.set $r
      (i32.shr_u (local.get $bits)
        (i32.sub (i32.const 32) (local.get $n))))

    ;; bits <<= n
    (i32.store (global.get $BR_BITS)
      (i32.shl (local.get $bits) (local.get $n)))

    ;; bitPos += n
    (i32.store (global.get $BR_BITPOS)
      (i32.add (i32.load (global.get $BR_BITPOS)) (local.get $n)))

    (local.get $r)
  )

  ;; ── br_read_bits_no_refill_zero ────────────────────────────
  ;; Read n bits without refilling. n may be 0.
  ;; Uses double-shift to handle n=0 safely.
  (func $br_read_bits_no_refill_zero (export "br_read_bits_no_refill_zero") (param $n i32) (result i32)
    (local $bits i32)
    (local $r i32)

    (local.set $bits (i32.load (global.get $BR_BITS)))

    ;; r = (bits >> 1) >> (31 - n)
    (local.set $r
      (i32.shr_u
        (i32.shr_u (local.get $bits) (i32.const 1))
        (i32.sub (i32.const 31) (local.get $n))))

    ;; bits <<= n
    (i32.store (global.get $BR_BITS)
      (i32.shl (local.get $bits) (local.get $n)))

    ;; bitPos += n
    (i32.store (global.get $BR_BITPOS)
      (i32.add (i32.load (global.get $BR_BITPOS)) (local.get $n)))

    (local.get $r)
  )

  ;; ── br_read_bit ────────────────────────────────────────────
  ;; Refill, then read 1 bit from MSB.
  (func $br_read_bit (export "br_read_bit") (result i32)
    (call $br_refill)
    (call $br_read_bits_no_refill (i32.const 1))
  )

  ;; ── br_read_bits ───────────────────────────────────────────
  ;; Refill, then read n bits.
  (func $br_read_bits (export "br_read_bits") (param $n i32) (result i32)
    (call $br_refill)
    (call $br_read_bits_no_refill (local.get $n))
  )

  ;; ── Backward bit reader ────────────────────────────────────

  ;; br2_init: Initialize backward bit reader.
  ;; p = current position (starts past end), pEnd = start of stream (stop sentinel)
  (func $br2_init (export "br2_init") (param $p i32) (param $pEnd i32)
    (i32.store (global.get $BR2_P) (local.get $p))
    (i32.store (global.get $BR2_PEND) (local.get $pEnd))
    (i32.store (global.get $BR2_BITS) (i32.const 0))
    (i32.store (global.get $BR2_BITPOS) (i32.const 24))
  )

  ;; br2_refill: Refill backward — reads bytes in reverse.
  ;; while bitPos > 0 && p > pEnd: p--; bits |= *p << bitPos; bitPos -= 8
  (func $br2_refill (export "br2_refill")
    (local $p i32)
    (local $pEnd i32)
    (local $bits i32)
    (local $bitPos i32)

    (local.set $p (i32.load (global.get $BR2_P)))
    (local.set $pEnd (i32.load (global.get $BR2_PEND)))
    (local.set $bits (i32.load (global.get $BR2_BITS)))
    (local.set $bitPos (i32.load (global.get $BR2_BITPOS)))

    (block $done
      (loop $loop
        (br_if $done (i32.le_s (local.get $bitPos) (i32.const 0)))
        (br_if $done (i32.le_u (local.get $p) (local.get $pEnd)))

        ;; p--
        (local.set $p (i32.sub (local.get $p) (i32.const 1)))

        ;; bits |= *p << bitPos
        (local.set $bits
          (i32.or (local.get $bits)
            (i32.shl
              (i32.load8_u (local.get $p))
              (local.get $bitPos))))

        ;; bitPos -= 8
        (local.set $bitPos (i32.sub (local.get $bitPos) (i32.const 8)))

        (br $loop)
      )
    )

    (i32.store (global.get $BR2_P) (local.get $p))
    (i32.store (global.get $BR2_BITS) (local.get $bits))
    (i32.store (global.get $BR2_BITPOS) (local.get $bitPos))
  )

  ;; br2_read_bits_no_refill: Same as br_read_bits_no_refill but for reader 2.
  (func $br2_read_bits_no_refill (export "br2_read_bits_no_refill") (param $n i32) (result i32)
    (local $bits i32)
    (local $r i32)

    (local.set $bits (i32.load (global.get $BR2_BITS)))
    (local.set $r
      (i32.shr_u (local.get $bits)
        (i32.sub (i32.const 32) (local.get $n))))
    (i32.store (global.get $BR2_BITS)
      (i32.shl (local.get $bits) (local.get $n)))
    (i32.store (global.get $BR2_BITPOS)
      (i32.add (i32.load (global.get $BR2_BITPOS)) (local.get $n)))
    (local.get $r)
  )

  ;; br2_read_bits: Refill backward, then read n bits.
  (func $br2_read_bits (export "br2_read_bits") (param $n i32) (result i32)
    (call $br2_refill)
    (call $br2_read_bits_no_refill (local.get $n))
  )

  ;; ── Exported state getters for testing ─────────────────────

  (func (export "br_get_bits") (result i32)
    (i32.load (global.get $BR_BITS))
  )
  (func (export "br_get_bitpos") (result i32)
    (i32.load (global.get $BR_BITPOS))
  )
  (func (export "br_get_p") (result i32)
    (i32.load (global.get $BR_P))
  )
  (func (export "br2_get_bits") (result i32)
    (i32.load (global.get $BR2_BITS))
  )
  (func (export "br2_get_bitpos") (result i32)
    (i32.load (global.get $BR2_BITPOS))
  )
  (func (export "br2_get_p") (result i32)
    (i32.load (global.get $BR2_P))
  )

  ;; ============================================================
  ;; Phase 3: Entropy Decoder (High_DecodeBytes)
  ;; ============================================================
  ;;
  ;; Entropy block header format:
  ;;   chunkType = (byte0 >> 4) & 7
  ;;   Type 0: memcopy (uncompressed)
  ;;   Type 1: tANS
  ;;   Type 2: Huffman 2-way
  ;;   Type 3: RLE
  ;;   Type 4: Huffman 4-way
  ;;   Type 5: recursive

  ;; ── high_decode_bytes ──────────────────────────────────────
  ;; Decodes one entropy block.
  ;; Parameters:
  ;;   $src      — start of compressed data
  ;;   $srcEnd   — end of compressed data
  ;;   $dst      — destination buffer
  ;;   $dstCap   — max bytes to write
  ;; Returns: total source bytes consumed, or -1 on error.
  ;; Stores decoded size at address 0x50.

  (global $ENT_DECODED_SIZE i32 (i32.const 0x50))
  ;; Debug counter (kept for test harness)
  (global $DBG_COUNTER i32 (i32.const 0x54))

  (func (export "getEntDecodedSize") (result i32)
    (i32.load (global.get $ENT_DECODED_SIZE))
  )

  (func $high_decode_bytes (export "high_decode_bytes")
    (param $src i32) (param $srcEnd i32) (param $dst i32) (param $dstCap i32)
    (result i32)
    (local $chunkType i32)
    (local $srcSize i32)
    (local $dstSize i32)
    (local $srcStart i32)
    (local $bits i32)

    (local.set $srcStart (local.get $src))

    ;; Need at least 2 bytes
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
      (then (return (i32.const -1)))
    )

    ;; chunkType = (byte0 >> 4) & 7
    (local.set $chunkType
      (i32.and
        (i32.shr_u (i32.load8_u (local.get $src)) (i32.const 4))
        (i32.const 7)))

    ;; ── Type 0: memcopy ──
    (if (i32.eqz (local.get $chunkType))
      (then
        ;; Short mode: byte0 >= 0x80 → srcSize in bottom 12 bits of 2 bytes
        (if (i32.ge_u (i32.load8_u (local.get $src)) (i32.const 0x80))
          (then
            (local.set $srcSize
              (i32.and
                (i32.or
                  (i32.shl (i32.load8_u (local.get $src)) (i32.const 8))
                  (i32.load8_u (i32.add (local.get $src) (i32.const 1))))
                (i32.const 0xFFF)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
          )
          (else
            ;; Long mode: 3 bytes, 18-bit size
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
              (then (return (i32.const -1)))
            )
            (local.set $srcSize
              (i32.or
                (i32.or
                  (i32.shl (i32.load8_u (local.get $src)) (i32.const 16))
                  (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
                (i32.load8_u (i32.add (local.get $src) (i32.const 2)))))
            (local.set $src (i32.add (local.get $src) (i32.const 3)))
          )
        )

        ;; Validate
        (if (i32.or
              (i32.gt_s (local.get $srcSize) (local.get $dstCap))
              (i32.gt_s (local.get $srcSize) (i32.sub (local.get $srcEnd) (local.get $src))))
          (then (return (i32.const -1)))
        )

        ;; Copy srcSize bytes from src to dst
        (memory.copy (local.get $dst) (local.get $src) (local.get $srcSize))

        ;; Store decoded size
        (i32.store (global.get $ENT_DECODED_SIZE) (local.get $srcSize))

        ;; Return total consumed = (src + srcSize) - srcStart
        (return (i32.sub
          (i32.add (local.get $src) (local.get $srcSize))
          (local.get $srcStart)))
      )
    )

    ;; ── Types 1-5: entropy coded (have src_size + dst_size header) ──

    (if (i32.ge_u (i32.load8_u (local.get $src)) (i32.const 0x80))
      (then
        ;; Short mode: 3 bytes, 10-bit sizes
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
          (then (return (i32.const -1)))
        )
        (local.set $bits
          (i32.or
            (i32.or
              (i32.shl (i32.load8_u (local.get $src)) (i32.const 16))
              (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
            (i32.load8_u (i32.add (local.get $src) (i32.const 2)))))
        (local.set $srcSize (i32.and (local.get $bits) (i32.const 0x3FF)))
        (local.set $dstSize
          (i32.add
            (i32.add (local.get $srcSize)
              (i32.and (i32.shr_u (local.get $bits) (i32.const 10)) (i32.const 0x3FF)))
            (i32.const 1)))
        (local.set $src (i32.add (local.get $src) (i32.const 3)))
      )
      (else
        ;; Long mode: 5 bytes, 18-bit sizes
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 5))
          (then (return (i32.const -1)))
        )
        (local.set $bits
          (i32.or
            (i32.or
              (i32.or
                (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 24))
                (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 2))) (i32.const 16)))
              (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 3))) (i32.const 8)))
            (i32.load8_u (i32.add (local.get $src) (i32.const 4)))))
        (local.set $srcSize (i32.and (local.get $bits) (i32.const 0x3FFFF)))
        (local.set $dstSize
          (i32.add
            (i32.and
              (i32.or
                (i32.shr_u (local.get $bits) (i32.const 18))
                (i32.shl (i32.load8_u (local.get $src)) (i32.const 14)))
              (i32.const 0x3FFFF))
            (i32.const 1)))
        ;; Validate: srcSize < dstSize
        (if (i32.ge_u (local.get $srcSize) (local.get $dstSize))
          (then (return (i32.const -1)))
        )
        (local.set $src (i32.add (local.get $src) (i32.const 5)))
      )
    )

    ;; Validate sizes
    (if (i32.or
          (i32.gt_s (local.get $srcSize) (i32.sub (local.get $srcEnd) (local.get $src)))
          (i32.gt_s (local.get $dstSize) (local.get $dstCap)))
      (then (return (i32.const -1)))
    )

    ;; Store decoded size
    (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))

    ;; Dispatch based on chunkType
    ;; Type 5: recursive — decode N sub-blocks
    (if (i32.eq (local.get $chunkType) (i32.const 5))
      (then
        (return
          (call $high_decode_recursive
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)
            (local.get $srcStart)))
      )
    )

    ;; Type 3: RLE
    (if (i32.eq (local.get $chunkType) (i32.const 3))
      (then
        (return
          (call $high_decode_rle
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)
            (local.get $srcStart)))
      )
    )

    ;; Types 2 (Huffman 2-way) and 4 (Huffman 4-way)
    (if (i32.or (i32.eq (local.get $chunkType) (i32.const 2))
                (i32.eq (local.get $chunkType) (i32.const 4)))
      (then
        (return
          (call $high_decode_huff
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)
            (i32.shr_u (local.get $chunkType) (i32.const 1))  ;; type: 1=2way, 2=4way
            (local.get $srcStart)))
      )
    )

    ;; Type 1 (tANS): not yet implemented
    (return (i32.const -1))
  )

  ;; ── high_decode_recursive ──────────────────────────────────
  ;; Decode a recursive entropy block (type 5, simple variant).
  ;; Reads N sub-blocks, decoding each with high_decode_bytes.
  ;; Returns total source bytes consumed from srcStart, or -1 on error.
  (func $high_decode_recursive
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
    (param $srcStart i32)
    (result i32)
    (local $srcEnd i32)
    (local $dstEnd i32)
    (local $n i32)
    (local $dec i32)
    (local $decSize i32)

    (local.set $srcEnd (i32.add (local.get $src) (local.get $srcSize)))
    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))

    ;; Need at least 1 byte for sub-block count
    (if (i32.lt_s (local.get $srcSize) (i32.const 6))
      (then (return (i32.const -1)))
    )

    ;; n = first byte & 0x7F (sub-block count)
    (local.set $n (i32.and (i32.load8_u (local.get $src)) (i32.const 0x7F)))
    (if (i32.lt_s (local.get $n) (i32.const 2))
      (then (return (i32.const -1)))
    )

    ;; Check for multi-array variant (bit 7 set) — not implemented
    (if (i32.and (i32.load8_u (local.get $src)) (i32.const 0x80))
      (then (return (i32.const -1)))
    )

    (local.set $src (i32.add (local.get $src) (i32.const 1)))

    ;; Decode N sub-blocks
    (block $done
      (loop $loop
        (br_if $done (i32.le_s (local.get $n) (i32.const 0)))

        (local.set $dec
          (call $high_decode_bytes
            (local.get $src)
            (local.get $srcEnd)
            (local.get $dst)
            (i32.sub (local.get $dstEnd) (local.get $dst))))
        (if (i32.lt_s (local.get $dec) (i32.const 0))
          (then (return (i32.const -1)))
        )

        (local.set $decSize (i32.load (global.get $ENT_DECODED_SIZE)))
        (local.set $dst (i32.add (local.get $dst) (local.get $decSize)))
        (local.set $src (i32.add (local.get $src) (local.get $dec)))

        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $loop)
      )
    )

    ;; Verify all output was produced
    (if (i32.ne (local.get $dst) (local.get $dstEnd))
      (then (return (i32.const -1)))
    )

    ;; Return total consumed from srcStart
    (i32.sub (local.get $src) (local.get $srcStart))
  )

  ;; ── high_decode_rle ────────────────────────────────────────
  ;; RLE decoder (entropy type 3).
  ;; Commands read backwards from end, literals forward from front.
  ;; Returns total source bytes consumed from srcStart, or -1 on error.
  (func $high_decode_rle
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
    (param $srcStart i32)
    (result i32)
    (local $dstEnd i32)
    (local $cmdPtr i32)
    (local $cmdPtrEnd i32)
    (local $rleByte i32)
    (local $cmd i32)
    (local $bytesToCopy i32)
    (local $bytesToRle i32)
    (local $data i32)

    ;; Special case: srcSize == 1 → fill entire output with src[0]
    (if (i32.le_s (local.get $srcSize) (i32.const 1))
      (then
        (if (i32.ne (local.get $srcSize) (i32.const 1))
          (then (return (i32.const -1)))
        )
        (memory.fill (local.get $dst)
          (i32.load8_u (local.get $src))
          (local.get $dstSize))
        (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))
        (return (i32.sub
          (i32.add (local.get $src) (i32.const 1))
          (local.get $srcStart)))
      )
    )

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))

    ;; Check if command buffer is entropy-coded (src[0] != 0)
    (if (i32.ne (i32.load8_u (local.get $src)) (i32.const 0))
      (then
        ;; Decode the entropy-coded prefix into a scratch buffer
        ;; Use a scratch area past DECODE_SCRATCH + 256KB = 0x0C041100
        (local.set $cmdPtr (i32.const 0x0C081100))
        (local.set $data  ;; reuse $data as temp for decoded count
          (call $high_decode_bytes
            (local.get $src)
            (i32.add (local.get $src) (local.get $srcSize))
            (local.get $cmdPtr)
            (i32.const 0x40000)))  ;; max 256KB
        (if (i32.lt_s (local.get $data) (i32.const 0))
          (then (return (i32.const -1)))
        )
        ;; Decoded prefix is at $cmdPtr, decSize bytes long
        ;; Remaining raw bytes: src + $data .. src + srcSize
        ;; Concatenate: [decoded prefix][remaining raw] into one buffer
        (local.set $bytesToCopy (i32.load (global.get $ENT_DECODED_SIZE)))
        (local.set $bytesToRle (i32.sub (local.get $srcSize) (local.get $data)))
        ;; Copy remaining raw bytes after decoded prefix
        (memory.copy
          (i32.add (local.get $cmdPtr) (local.get $bytesToCopy))
          (i32.add (local.get $src) (local.get $data))
          (local.get $bytesToRle))
        ;; cmdPtrEnd = cmdPtr + decoded + remaining
        (local.set $cmdPtrEnd
          (i32.add (local.get $cmdPtr)
            (i32.add (local.get $bytesToCopy) (local.get $bytesToRle))))
      )
      (else
        ;; Raw command buffer: cmdPtr = src+1, cmdPtrEnd = src+srcSize
        (local.set $cmdPtr (i32.add (local.get $src) (i32.const 1)))
        (local.set $cmdPtrEnd (i32.add (local.get $src) (local.get $srcSize)))
      )
    )
    (local.set $rleByte (i32.const 0))

    ;; Command loop: read commands from end, literals from front
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $cmdPtr) (local.get $cmdPtrEnd)))

        ;; cmd = cmdPtrEnd[-1]
        (local.set $cmd
          (i32.load8_u (i32.sub (local.get $cmdPtrEnd) (i32.const 1))))

        ;; if (cmd - 1) >= 0x2F → short copy+RLE command
        (if (i32.ge_u (i32.sub (local.get $cmd) (i32.const 1)) (i32.const 0x2F))
          (then
            (local.set $cmdPtrEnd (i32.sub (local.get $cmdPtrEnd) (i32.const 1)))
            (local.set $bytesToCopy (i32.and (i32.xor (local.get $cmd) (i32.const 0xFF)) (i32.const 0xF)))
            (local.set $bytesToRle (i32.shr_u (local.get $cmd) (i32.const 4)))

            ;; Copy literals
            (memory.copy (local.get $dst) (local.get $cmdPtr) (local.get $bytesToCopy))
            (local.set $cmdPtr (i32.add (local.get $cmdPtr) (local.get $bytesToCopy)))
            (local.set $dst (i32.add (local.get $dst) (local.get $bytesToCopy)))

            ;; Fill RLE bytes
            (memory.fill (local.get $dst) (local.get $rleByte) (local.get $bytesToRle))
            (local.set $dst (i32.add (local.get $dst) (local.get $bytesToRle)))

            (br $loop)
          )
        )

        ;; cmd >= 0x10 → extended copy+RLE (2-byte command)
        (if (i32.ge_u (local.get $cmd) (i32.const 0x10))
          (then
            ;; data = LE16(cmdPtrEnd-2) - 4096
            (local.set $data
              (i32.sub
                (i32.load16_u (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))
                (i32.const 4096)))
            (local.set $cmdPtrEnd (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))
            (local.set $bytesToCopy (i32.and (local.get $data) (i32.const 0x3F)))
            (local.set $bytesToRle (i32.shr_u (local.get $data) (i32.const 6)))

            (memory.copy (local.get $dst) (local.get $cmdPtr) (local.get $bytesToCopy))
            (local.set $cmdPtr (i32.add (local.get $cmdPtr) (local.get $bytesToCopy)))
            (local.set $dst (i32.add (local.get $dst) (local.get $bytesToCopy)))

            (memory.fill (local.get $dst) (local.get $rleByte) (local.get $bytesToRle))
            (local.set $dst (i32.add (local.get $dst) (local.get $bytesToRle)))

            (br $loop)
          )
        )

        ;; cmd == 1 → set RLE byte
        (if (i32.eq (local.get $cmd) (i32.const 1))
          (then
            (local.set $rleByte (i32.load8_u (local.get $cmdPtr)))
            (local.set $cmdPtr (i32.add (local.get $cmdPtr) (i32.const 1)))
            (local.set $cmdPtrEnd (i32.sub (local.get $cmdPtrEnd) (i32.const 1)))
            (br $loop)
          )
        )

        ;; cmd >= 9 → large RLE run (2-byte command)
        (if (i32.ge_u (local.get $cmd) (i32.const 9))
          (then
            (local.set $bytesToRle
              (i32.mul
                (i32.sub
                  (i32.load16_u (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))
                  (i32.const 0x8FF))
                (i32.const 128)))
            (local.set $cmdPtrEnd (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))

            (memory.fill (local.get $dst) (local.get $rleByte) (local.get $bytesToRle))
            (local.set $dst (i32.add (local.get $dst) (local.get $bytesToRle)))
            (br $loop)
          )
        )

        ;; cmd 2..8 → large literal copy (2-byte command)
        (local.set $bytesToCopy
          (i32.mul
            (i32.sub
              (i32.load16_u (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))
              (i32.const 511))
            (i32.const 64)))
        (local.set $cmdPtrEnd (i32.sub (local.get $cmdPtrEnd) (i32.const 2)))

        (memory.copy (local.get $dst) (local.get $cmdPtr) (local.get $bytesToCopy))
        (local.set $dst (i32.add (local.get $dst) (local.get $bytesToCopy)))
        (local.set $cmdPtr (i32.add (local.get $cmdPtr) (local.get $bytesToCopy)))

        (br $loop)
      )
    )

    ;; Verify convergence
    (if (i32.ne (local.get $cmdPtrEnd) (local.get $cmdPtr))
      (then (return (i32.const -1)))
    )
    (if (i32.ne (local.get $dst) (local.get $dstEnd))
      (then (return (i32.const -1)))
    )

    (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))
    (i32.sub
      (i32.add (local.get $src) (local.get $srcSize))
      (local.get $srcStart))
  )

  ;; ============================================================
  ;; Phase 4: Fast LZ Decoder
  ;; ============================================================

  ;; ── copy64 ─────────────────────────────────────────────────
  ;; Copy 8 bytes (may overlap for match copies with offset >= 8).
  (func $copy64 (param $dst i32) (param $src i32)
    (i64.store (local.get $dst) (i64.load (local.get $src)))
  )

  ;; ── decode_far_offsets ─────────────────────────────────────
  ;; Decode 32-bit far offsets from source stream.
  ;; 3 bytes per offset; offsets >= 0xC00000 have a 4th byte.
  ;; Writes decoded offsets to $output (as u32 array).
  ;; Returns source bytes consumed, or -1 on error.
  (func $decode_far_offsets
    (param $src i32) (param $srcEnd i32)
    (param $output i32) (param $count i32) (param $offset i64)
    (result i32)
    (local $srcStart i32)
    (local $i i32)
    (local $off i32)

    (local.set $srcStart (local.get $src))

    (if (i64.lt_s (local.get $offset) (i64.const 0xBFFFFF))
      (then
        ;; Small offset path: all offsets are 3 bytes
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (local.get $count)))
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
              (then (return (i32.const -1)))
            )
            (local.set $off
              (i32.or
                (i32.or
                  (i32.load8_u (local.get $src))
                  (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
                (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 2))) (i32.const 16))))
            (local.set $src (i32.add (local.get $src) (i32.const 3)))
            ;; Validate offset <= current position
            (if (i32.gt_u (local.get $off) (i32.wrap_i64 (local.get $offset)))
              (then (return (i32.const -1)))
            )
            (i32.store (i32.add (local.get $output) (i32.shl (local.get $i) (i32.const 2)))
              (local.get $off))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)
          )
        )
        (return (i32.sub (local.get $src) (local.get $srcStart)))
      )
    )

    ;; Large offset path: offsets >= 0xC00000 have 4th byte
    (local.set $i (i32.const 0))
    (block $done2
      (loop $loop2
        (br_if $done2 (i32.ge_u (local.get $i) (local.get $count)))
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
          (then (return (i32.const -1)))
        )
        (local.set $off
          (i32.or
            (i32.or
              (i32.load8_u (local.get $src))
              (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
            (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 2))) (i32.const 16))))
        (local.set $src (i32.add (local.get $src) (i32.const 3)))

        (if (i32.ge_u (local.get $off) (i32.const 0xC00000))
          (then
            (if (i32.ge_u (local.get $src) (local.get $srcEnd))
              (then (return (i32.const -1)))
            )
            (local.set $off
              (i32.add (local.get $off)
                (i32.shl (i32.load8_u (local.get $src)) (i32.const 22))))
            (local.set $src (i32.add (local.get $src) (i32.const 1)))
          )
        )

        (if (i32.gt_u (local.get $off) (i32.wrap_i64 (local.get $offset)))
          (then (return (i32.const -1)))
        )
        (i32.store (i32.add (local.get $output) (i32.shl (local.get $i) (i32.const 2)))
          (local.get $off))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop2)
      )
    )

    (i32.sub (local.get $src) (local.get $srcStart))
  )

  ;; ── combine_off16 ──────────────────────────────────────────
  ;; Combine lo and hi byte arrays into u16 array.
  (func $combine_off16 (param $dst i32) (param $size i32) (param $lo i32) (param $hi i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $size)))
        (i32.store16
          (i32.add (local.get $dst) (i32.shl (local.get $i) (i32.const 1)))
          (i32.add
            (i32.load8_u (i32.add (local.get $lo) (local.get $i)))
            (i32.shl (i32.load8_u (i32.add (local.get $hi) (local.get $i))) (i32.const 8))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================
  ;; Full frame decompressor (L1 only)
  ;; ============================================================
  ;;
  ;; decompress(inputLen) → decompressed size, or -1 on error.
  ;; Input is at INPUT_BASE, output at OUTPUT_BASE.

  (func (export "decompress") (param $inputLen i32) (result i32)
    (local $pos i32)
    (local $outPos i32)
    (local $compSize i32)
    (local $decompSize i32)
    (local $isUncomp i32)
    (local $blockStart i32)

    ;; Parse frame header
    (local.set $pos (call $parseFrameHeader (local.get $inputLen)))
    (if (i32.lt_s (local.get $pos) (i32.const 0))
      (then (return (i32.const -1)))
    )

    ;; Verify codec == 1 (Fast)
    (if (i32.ne (i32.load8_u (global.get $HDR_CODEC)) (i32.const 1))
      (then (return (i32.const -1)))
    )

    (local.set $outPos (i32.const 0))

    ;; Block loop
    (block $end
      (loop $blockLoop
        ;; Parse block header
        (local.set $compSize
          (call $parseBlockHeader (local.get $pos) (local.get $inputLen)))

        ;; End mark
        (br_if $end (i32.eqz (local.get $compSize)))
        ;; Error
        (if (i32.lt_s (local.get $compSize) (i32.const 0))
          (then (return (i32.const -1)))
        )

        (local.set $decompSize (i32.load (global.get $BLK_DECOMP_SIZE)))
        (local.set $isUncomp (i32.load (global.get $BLK_IS_UNCOMP)))

        ;; blockStart = INPUT_BASE + pos + 8 (skip block header)
        (local.set $blockStart
          (i32.add (global.get $INPUT_BASE)
            (i32.add (local.get $pos) (i32.const 8))))

        (if (local.get $isUncomp)
          (then
            ;; Uncompressed block: just copy
            (memory.copy
              (i32.add (global.get $OUTPUT_BASE) (local.get $outPos))
              (local.get $blockStart)
              (local.get $decompSize))
          )
          (else
            ;; Compressed block: decode via StreamLZ chunk decoder
            (if (i32.lt_s
                  (call $decode_block
                    (local.get $blockStart)
                    (i32.add (local.get $blockStart) (local.get $compSize))
                    (i32.add (global.get $OUTPUT_BASE) (local.get $outPos))
                    (local.get $decompSize))
                  (i32.const 0))
              (then (return (i32.const -1)))
            )
          )
        )

        (local.set $outPos (i32.add (local.get $outPos) (local.get $decompSize)))
        (local.set $pos (i32.add (local.get $pos)
          (i32.add (i32.const 8) (local.get $compSize))))
        (br $blockLoop)
      )
    )

    (local.get $outPos)
  )

  ;; ── decode_block ───────────────────────────────────────────
  ;; Decode one compressed frame-level block.
  ;; A block contains multiple 256KB StreamLZ chunks, each with its own
  ;; 2-byte StreamLZ header + 4-byte chunk header + sub-chunk data.
  ;; Returns 0 on success, -1 on error.
  (func $decode_block
    (param $src i32) (param $srcEnd i32)
    (param $dst i32) (param $dstSize i32)
    (result i32)
    (local $b0 i32)
    (local $b1 i32)
    (local $decoderType i32)
    (local $isUncompChunk i32)
    (local $chunkHdr i32)
    (local $chunkCompSize i32)
    (local $chunkType i32)
    (local $dstEnd i32)
    (local $dstCur i32)
    (local $dstCount i32)
    (local $srcUsed i32)
    (local $mode i32)
    (local $subHdr i32)
    (local $offset i32)
    (local $chunkBytesLeft i32)

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))
    (local.set $dstCur (local.get $dst))
    (local.set $offset (i32.const 0))

    ;; Outer loop: one iteration per 256KB StreamLZ chunk
    (block $blockDone
      (loop $chunkOuterLoop
        (br_if $blockDone (i32.ge_u (local.get $dstCur) (local.get $dstEnd)))

        ;; Parse StreamLZ header at every 256KB boundary
        (if (i32.eqz (i32.and (local.get $offset) (i32.const 0x3FFFF)))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
              (then (return (i32.const -1)))
            )
            (local.set $b0 (i32.load8_u (local.get $src)))
            (local.set $b1 (i32.load8_u (i32.add (local.get $src) (i32.const 1))))
            (if (i32.ne (i32.and (local.get $b0) (i32.const 0xF)) (i32.const 5))
              (then (return (i32.const -1)))
            )
            (local.set $decoderType (i32.and (local.get $b1) (i32.const 0x7F)))
            (local.set $isUncompChunk (i32.and (i32.shr_u (local.get $b0) (i32.const 7)) (i32.const 1)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
            (if (i32.ne (local.get $decoderType) (i32.const 1))
              (then (return (i32.const -1)))
            )
          )
        )

        ;; Bytes left for this 256KB chunk
        (local.set $chunkBytesLeft
          (i32.sub (local.get $dstEnd) (local.get $dstCur)))
        (if (i32.gt_s (local.get $chunkBytesLeft) (i32.const 0x40000))
          (then (local.set $chunkBytesLeft (i32.const 0x40000)))
        )

        ;; If uncompressed chunk, just copy
        (if (local.get $isUncompChunk)
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (local.get $chunkBytesLeft))
              (then (return (i32.const -1)))
            )
            (memory.copy (local.get $dstCur) (local.get $src) (local.get $chunkBytesLeft))
            (local.set $src (i32.add (local.get $src) (local.get $chunkBytesLeft)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $chunkBytesLeft)))
            (local.set $offset (i32.add (local.get $offset) (local.get $chunkBytesLeft)))
            (br $chunkOuterLoop)
          )
        )

        ;; Read 4-byte LE chunk header
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 4))
          (then (return (i32.const -1)))
        )
        (local.set $chunkHdr (i32.load (local.get $src)))
        (local.set $chunkCompSize (i32.and (local.get $chunkHdr) (i32.const 0x3FFFF)))
        (local.set $chunkType (i32.and (i32.shr_u (local.get $chunkHdr) (i32.const 18)) (i32.const 3)))

        ;; Memset chunk (type 1)
        (if (i32.eq (local.get $chunkType) (i32.const 1))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 5))
              (then (return (i32.const -1)))
            )
            (memory.fill (local.get $dstCur)
              (i32.load8_u (i32.add (local.get $src) (i32.const 4)))
              (local.get $chunkBytesLeft))
            (local.set $src (i32.add (local.get $src) (i32.const 5)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $chunkBytesLeft)))
            (local.set $offset (i32.add (local.get $offset) (local.get $chunkBytesLeft)))
            (br $chunkOuterLoop)
          )
        )

        ;; Skip 4-byte chunk header
        (local.set $src (i32.add (local.get $src) (i32.const 4)))

        ;; Inner sub-chunk loop — process up to 128KB sub-chunks within this 256KB chunk
        (local.set $chunkBytesLeft (local.get $chunkBytesLeft)) ;; already set above
        (block $chunkDone
          (loop $chunkLoop
            (br_if $chunkDone (i32.le_s (local.get $chunkBytesLeft) (i32.const 0)))

            (local.set $dstCount (local.get $chunkBytesLeft))
            (if (i32.gt_s (local.get $dstCount) (i32.const 0x20000))
              (then (local.set $dstCount (i32.const 0x20000)))
            )

        ;; Read 3-byte big-endian sub-chunk header
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
          (then (return (i32.const -1)))
        )

        (local.set $subHdr
          (i32.or
            (i32.or
              (i32.shl (i32.load8_u (local.get $src)) (i32.const 16))
              (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
            (i32.load8_u (i32.add (local.get $src) (i32.const 2)))))

        ;; Check compressed flag (bit 23)
        (if (i32.eqz (i32.and (local.get $subHdr) (i32.const 0x800000)))
          (then
            ;; Not compressed — entropy-only, decode via High_DecodeBytes
            (local.set $srcUsed
              (call $high_decode_bytes
                (local.get $src)
                (local.get $srcEnd)
                (local.get $dstCur)
                (local.get $dstCount)))
            (if (i32.lt_s (local.get $srcUsed) (i32.const 0))
              (then (return (i32.const -1)))
            )
            (if (i32.ne (i32.load (global.get $ENT_DECODED_SIZE)) (local.get $dstCount))
              (then (return (i32.const -1)))
            )
            (local.set $src (i32.add (local.get $src) (local.get $srcUsed)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $dstCount)))
            (br $chunkLoop)
          )
        )

        ;; Compressed — extract size and mode from sub-chunk header
        (local.set $src (i32.add (local.get $src) (i32.const 3)))
        (local.set $srcUsed (i32.and (local.get $subHdr) (i32.const 0x7FFFF)))
        (local.set $mode (i32.and (i32.shr_u (local.get $subHdr) (i32.const 19)) (i32.const 0xF)))

        ;; Validate source data available
        (if (i32.gt_s (local.get $srcUsed) (i32.sub (local.get $srcEnd) (local.get $src)))
          (then (return (i32.const -1)))
        )

        ;; If srcUsed >= dstCount and mode == 0, stored (copy)
        (if (i32.and
              (i32.ge_u (local.get $srcUsed) (local.get $dstCount))
              (i32.eqz (local.get $mode)))
          (then
            (if (i32.ne (local.get $srcUsed) (local.get $dstCount))
              (then (return (i32.const -1)))
            )
            (memory.copy (local.get $dstCur) (local.get $src) (local.get $dstCount))
            (local.set $src (i32.add (local.get $src) (local.get $srcUsed)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $dstCount)))
            (br $chunkLoop)
          )
        )

        ;; LZ compressed — call fast_decode_chunk
        (if (i32.lt_s
              (call $fast_decode_chunk
                (local.get $src)
                (i32.add (local.get $src) (local.get $srcUsed))
                (local.get $dstCur)
                (local.get $dstCount)
                (local.get $mode)
                (local.get $dst))  ;; dstStart for offset validation
              (i32.const 0))
          (then (return (i32.const -1)))
        )
        (local.set $src (i32.add (local.get $src) (local.get $srcUsed)))
        (local.set $dstCur (i32.add (local.get $dstCur) (local.get $dstCount)))
        (local.set $chunkBytesLeft (i32.sub (local.get $chunkBytesLeft) (local.get $dstCount)))
        (local.set $offset (i32.add (local.get $offset) (local.get $dstCount)))
        (br $chunkLoop)
      )
    )  ;; end sub-chunk loop

    (br $chunkOuterLoop)
      )
    )  ;; end outer 256KB chunk loop

    (i32.const 0)
  )

  ;; ============================================================
  ;; FastLzTable — stored at fixed addresses 0x60..0xBF
  ;; ============================================================
  ;; 0x60: litStart      (i32)
  ;; 0x64: litEnd        (i32)
  ;; 0x68: cmdStart      (i32)
  ;; 0x6C: cmdEnd        (i32)
  ;; 0x70: lengthStream  (i32)
  ;; 0x74: off16Start    (i32)
  ;; 0x78: off16End      (i32)
  ;; 0x7C: off32Start    (i32)  — current chunk
  ;; 0x80: off32End      (i32)  — current chunk
  ;; 0x84: off32Backing1 (i32)
  ;; 0x88: off32Backing2 (i32)
  ;; 0x8C: off32Count1   (i32)
  ;; 0x90: off32Count2   (i32)
  ;; 0x94: cmd2Offset    (i32)
  ;; 0x98: cmd2OffsetEnd (i32)

  (global $LZ_LIT_START   i32 (i32.const 0x60))
  (global $LZ_LIT_END     i32 (i32.const 0x64))
  (global $LZ_CMD_START   i32 (i32.const 0x68))
  (global $LZ_CMD_END     i32 (i32.const 0x6C))
  (global $LZ_LEN_STREAM  i32 (i32.const 0x70))
  (global $LZ_OFF16_START i32 (i32.const 0x74))
  (global $LZ_OFF16_END   i32 (i32.const 0x78))
  (global $LZ_OFF32_START i32 (i32.const 0x7C))
  (global $LZ_OFF32_END   i32 (i32.const 0x80))
  (global $LZ_OFF32_BK1   i32 (i32.const 0x84))
  (global $LZ_OFF32_BK2   i32 (i32.const 0x88))
  (global $LZ_OFF32_CNT1  i32 (i32.const 0x8C))
  (global $LZ_OFF32_CNT2  i32 (i32.const 0x90))
  (global $LZ_CMD2_OFF    i32 (i32.const 0x94))
  (global $LZ_CMD2_END    i32 (i32.const 0x98))

  ;; Scratch memory for decoded sub-streams.
  ;; SCRATCH_BASE (0x0C001100) is used:
  ;;   +0x0000 .. +0x3FFFF: decoded literal/command streams (256KB)
  ;;   +0x40000 .. +0x5FFFF: off32 backing stores (128KB)
  ;; This is enough for chunks up to 128KB decompressed.

  (global $DECODE_SCRATCH i32 (i32.const 0x0C001100))
  (global $OFF32_SCRATCH  i32 (i32.const 0x0C041100))

  ;; ── fast_decode_chunk ──────────────────────────────────────
  ;; Decode one Fast LZ chunk: ReadLzTable + ProcessLzRuns.
  ;; Returns 0 on success, -1 on error.
  (func $fast_decode_chunk
    (param $src i32) (param $srcEnd i32)
    (param $dst i32) (param $dstCount i32)
    (param $mode i32) (param $dstStart i32)
    (result i32)
    (local $offset i64)
    (local $scratch i32)
    (local $scratchCur i32)
    (local $n i32)
    (local $decSize i32)
    (local $off16Count i32)
    (local $tmp i32)
    (local $off32Size1 i32)
    (local $off32Size2 i32)

    ;; Validate mode
    (if (i32.gt_u (local.get $mode) (i32.const 1))
      (then (return (i32.const -1)))
    )
    (if (i32.or (i32.le_s (local.get $dstCount) (i32.const 0))
                (i32.le_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 0)))
      (then (return (i32.const -1)))
    )

    (local.set $offset (i64.extend_i32_u (i32.sub (local.get $dst) (local.get $dstStart))))
    (local.set $scratch (global.get $DECODE_SCRATCH))
    (local.set $scratchCur (local.get $scratch))

    ;; If offset == 0, copy first 8 literal bytes directly to dst
    ;; (dst pointer is NOT advanced — ProcessLzRuns uses startOff=8 to skip them)
    (if (i64.eqz (local.get $offset))
      (then
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 8))
          (then (return (i32.const -1)))
        )
        (call $copy64 (local.get $dst) (local.get $src))
        (local.set $src (i32.add (local.get $src) (i32.const 8)))
      )
    )

    ;; ── Decode literal stream ──
    (local.set $n
      (call $high_decode_bytes
        (local.get $src) (local.get $srcEnd)
        (local.get $scratchCur) (local.get $dstCount)))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (return (i32.const -1)))
    )
    (local.set $decSize (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $n)))
    (i32.store (global.get $LZ_LIT_START) (local.get $scratchCur))
    (i32.store (global.get $LZ_LIT_END)
      (i32.add (local.get $scratchCur) (local.get $decSize)))
    (local.set $scratchCur (i32.add (local.get $scratchCur) (local.get $decSize)))

    ;; ── Decode command stream ──
    (local.set $n
      (call $high_decode_bytes
        (local.get $src) (local.get $srcEnd)
        (local.get $scratchCur) (local.get $dstCount)))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (return (i32.const -1)))
    )
    (local.set $decSize (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $n)))
    (i32.store (global.get $LZ_CMD_START) (local.get $scratchCur))
    (i32.store (global.get $LZ_CMD_END)
      (i32.add (local.get $scratchCur) (local.get $decSize)))
    (local.set $scratchCur (i32.add (local.get $scratchCur) (local.get $decSize)))

    ;; cmd2OffsetEnd = decSize (total command stream size)
    (i32.store (global.get $LZ_CMD2_END) (local.get $decSize))

    ;; cmd2Offset: if dstCount <= 0x10000, same as cmd2OffsetEnd; else read 2 bytes
    (if (i32.le_s (local.get $dstCount) (i32.const 0x10000))
      (then
        (i32.store (global.get $LZ_CMD2_OFF) (local.get $decSize))
      )
      (else
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
          (then (return (i32.const -1)))
        )
        (i32.store (global.get $LZ_CMD2_OFF)
          (i32.load16_u (local.get $src)))
        (local.set $src (i32.add (local.get $src) (i32.const 2)))
        ;; Validate cmd2Offset <= cmd2OffsetEnd
        (if (i32.gt_u (i32.load (global.get $LZ_CMD2_OFF))
                       (i32.load (global.get $LZ_CMD2_END)))
          (then (return (i32.const -1)))
        )
      )
    )

    ;; ── Decode off16 stream ──
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
      (then (return (i32.const -1)))
    )
    (local.set $off16Count (i32.load16_u (local.get $src)))

    (if (i32.eq (local.get $off16Count) (i32.const 0xFFFF))
      (then
        ;; Entropy-coded off16: decode hi and lo halves
        (local.set $src (i32.add (local.get $src) (i32.const 2)))
        ;; TODO: implement entropy-coded off16
        ;; For now, return error
        (return (i32.const -1))
      )
      (else
        ;; Raw off16: directly in source
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src))
              (i32.add (i32.const 2) (i32.shl (local.get $off16Count) (i32.const 1))))
          (then (return (i32.const -1)))
        )
        (i32.store (global.get $LZ_OFF16_START)
          (i32.add (local.get $src) (i32.const 2)))
        (local.set $src
          (i32.add (local.get $src)
            (i32.add (i32.const 2) (i32.shl (local.get $off16Count) (i32.const 1)))))
        (i32.store (global.get $LZ_OFF16_END) (local.get $src))
      )
    )

    ;; ── Decode off32 stream sizes ──
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
      (then (return (i32.const -1)))
    )
    (local.set $tmp
      (i32.or
        (i32.or
          (i32.load8_u (local.get $src))
          (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
        (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 2))) (i32.const 16))))
    (local.set $src (i32.add (local.get $src) (i32.const 3)))

    (if (i32.ne (local.get $tmp) (i32.const 0))
      (then
        (local.set $off32Size1 (i32.shr_u (local.get $tmp) (i32.const 12)))
        (local.set $off32Size2 (i32.and (local.get $tmp) (i32.const 0xFFF)))

        ;; Extended size for off32Size1
        (if (i32.eq (local.get $off32Size1) (i32.const 4095))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
              (then (return (i32.const -1)))
            )
            (local.set $off32Size1 (i32.load16_u (local.get $src)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
          )
        )
        ;; Extended size for off32Size2
        (if (i32.eq (local.get $off32Size2) (i32.const 4095))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
              (then (return (i32.const -1)))
            )
            (local.set $off32Size2 (i32.load16_u (local.get $src)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
          )
        )

        (i32.store (global.get $LZ_OFF32_CNT1) (local.get $off32Size1))
        (i32.store (global.get $LZ_OFF32_CNT2) (local.get $off32Size2))

        ;; Allocate backing stores from OFF32_SCRATCH
        ;; Align to 4 bytes
        (local.set $scratchCur (global.get $OFF32_SCRATCH))

        (i32.store (global.get $LZ_OFF32_BK1) (local.get $scratchCur))
        (local.set $scratchCur
          (i32.add (local.get $scratchCur)
            (i32.add (i32.shl (local.get $off32Size1) (i32.const 2)) (i32.const 32))))

        (i32.store (global.get $LZ_OFF32_BK2) (local.get $scratchCur))
        (local.set $scratchCur
          (i32.add (local.get $scratchCur)
            (i32.add (i32.shl (local.get $off32Size2) (i32.const 2)) (i32.const 32))))

        ;; Decode far offsets for chunk 1
        (local.set $n
          (call $decode_far_offsets
            (local.get $src) (local.get $srcEnd)
            (i32.load (global.get $LZ_OFF32_BK1))
            (local.get $off32Size1)
            (local.get $offset)))
        (if (i32.lt_s (local.get $n) (i32.const 0))
          (then (return (i32.const -1)))
        )
        (local.set $src (i32.add (local.get $src) (local.get $n)))

        ;; Decode far offsets for chunk 2 (offset + 0x10000)
        (local.set $n
          (call $decode_far_offsets
            (local.get $src) (local.get $srcEnd)
            (i32.load (global.get $LZ_OFF32_BK2))
            (local.get $off32Size2)
            (i64.add (local.get $offset) (i64.const 0x10000))))
        (if (i32.lt_s (local.get $n) (i32.const 0))
          (then (return (i32.const -1)))
        )
        (local.set $src (i32.add (local.get $src) (local.get $n)))
      )
      (else
        ;; No off32 entries
        (i32.store (global.get $LZ_OFF32_CNT1) (i32.const 0))
        (i32.store (global.get $LZ_OFF32_CNT2) (i32.const 0))
        (i32.store (global.get $LZ_OFF32_BK1) (global.get $OFF32_SCRATCH))
        (i32.store (global.get $LZ_OFF32_BK2) (global.get $OFF32_SCRATCH))
      )
    )

    ;; DBG: Store lit size at 0xA0, cmd size at 0xA4, off16 count at 0xA8
    (i32.store (i32.const 0xA0)
      (i32.sub (i32.load (global.get $LZ_LIT_END)) (i32.load (global.get $LZ_LIT_START))))
    (i32.store (i32.const 0xA4)
      (i32.sub (i32.load (global.get $LZ_CMD_END)) (i32.load (global.get $LZ_CMD_START))))
    (i32.store (i32.const 0xA8)
      (i32.shr_u
        (i32.sub (i32.load (global.get $LZ_OFF16_END)) (i32.load (global.get $LZ_OFF16_START)))
        (i32.const 1)))

    ;; Length stream = remaining source
    (i32.store (global.get $LZ_LEN_STREAM) (local.get $src))

    ;; DBG: 6 = about to process LZ runs
    (i32.store (global.get $DBG_COUNTER) (i32.const 6))

    ;; ── ProcessLzRuns ──
    ;; Process up to two 64KB sub-chunks
    (call $process_lz_runs
      (local.get $mode)
      (local.get $src) (local.get $srcEnd)
      (local.get $dst) (local.get $dstCount) (local.get $offset)
      (i32.add (local.get $dst) (local.get $dstCount))
      (local.get $dstStart))
  )

  ;; ── process_lz_runs ────────────────────────────────────────
  ;; Execute the Fast LZ match-copy loop over up to two 64KB chunks.
  ;; Returns 0 on success, -1 on error.
  (func $process_lz_runs
    (param $mode i32)
    (param $src i32) (param $srcEnd i32)
    (param $dst i32) (param $dstSize i32) (param $offset i64)
    (param $dstPtrEnd i32) (param $dstStart i32)
    (result i32)
    (local $savedDist i32)
    (local $iteration i32)
    (local $dstSizeCur i32)
    (local $startOff i32)
    (local $result i32)
    (local $cmdStartBase i32)

    (if (i32.or (i32.eqz (local.get $dstSize)) (i32.gt_u (local.get $mode) (i32.const 1)))
      (then (return (i32.const -1)))
    )

    (local.set $savedDist (i32.const -8))  ;; InitialRecentOffset
    ;; Store savedDist at 0x9C for process_mode to read/write
    (i32.store (i32.const 0x9C) (local.get $savedDist))
    (local.set $cmdStartBase (i32.load (global.get $LZ_CMD_START)))

    ;; Two iterations (two 64KB sub-chunks)
    (local.set $iteration (i32.const 0))
    (block $done
      (loop $iterLoop
        (br_if $done (i32.ge_u (local.get $iteration) (i32.const 2)))

        (local.set $dstSizeCur (local.get $dstSize))
        (if (i32.gt_u (local.get $dstSizeCur) (i32.const 0x10000))
          (then (local.set $dstSizeCur (i32.const 0x10000)))
        )

        ;; Set up off32 stream for this iteration
        (if (i32.eqz (local.get $iteration))
          (then
            ;; First chunk
            (i32.store (global.get $LZ_OFF32_START) (i32.load (global.get $LZ_OFF32_BK1)))
            (i32.store (global.get $LZ_OFF32_END)
              (i32.add (i32.load (global.get $LZ_OFF32_BK1))
                (i32.shl (i32.load (global.get $LZ_OFF32_CNT1)) (i32.const 2))))
            ;; cmdEnd = cmdStart + cmd2Offset
            (i32.store (global.get $LZ_CMD_END)
              (i32.add (local.get $cmdStartBase)
                (i32.load (global.get $LZ_CMD2_OFF))))
          )
          (else
            ;; Second chunk
            (i32.store (global.get $LZ_OFF32_START) (i32.load (global.get $LZ_OFF32_BK2)))
            (i32.store (global.get $LZ_OFF32_END)
              (i32.add (i32.load (global.get $LZ_OFF32_BK2))
                (i32.shl (i32.load (global.get $LZ_OFF32_CNT2)) (i32.const 2))))
            ;; cmdEnd = cmdStart + cmd2OffsetEnd
            (i32.store (global.get $LZ_CMD_END)
              (i32.add (local.get $cmdStartBase)
                (i32.load (global.get $LZ_CMD2_END))))
            ;; cmdStart = cmdStartBase + cmd2Offset
            (i32.store (global.get $LZ_CMD_START)
              (i32.add (local.get $cmdStartBase)
                (i32.load (global.get $LZ_CMD2_OFF))))
          )
        )

        ;; startOff = 8 if offset==0 and iteration==0, else 0
        (local.set $startOff (i32.const 0))
        (if (i32.and (i64.eqz (local.get $offset)) (i32.eqz (local.get $iteration)))
          (then (local.set $startOff (i32.const 8)))
        )

        ;; Call the match-copy loop
        (local.set $result
          (call $process_mode
            (local.get $mode)
            (local.get $dst) (local.get $dstSizeCur) (local.get $dstPtrEnd)
            (local.get $dstStart) (local.get $srcEnd)
            (local.get $startOff)))
        (if (i32.lt_s (local.get $result) (i32.const 0))
          (then (return (i32.const -1)))
        )

        (local.set $dst (i32.add (local.get $dst) (local.get $dstSizeCur)))
        (local.set $dstSize (i32.sub (local.get $dstSize) (local.get $dstSizeCur)))
        (if (i32.eqz (local.get $dstSize))
          (then (br $done))
        )

        (local.set $iteration (i32.add (local.get $iteration) (i32.const 1)))
        (br $iterLoop)
      )
    )

    (i32.const 0)
  )

  ;; ── process_mode ───────────────────────────────────────────
  ;; Core match-copy loop for one 64KB sub-chunk.
  ;; Mode 0 = delta literals (dst = lit + prev_match_byte)
  ;; Mode 1 = raw literals
  ;; Returns 0 on success, -1 on error.
  ;; Reads/updates LZ table state in memory.
  (func $process_mode
    (param $mode i32)
    (param $dst i32) (param $dstSize i32) (param $dstPtrEnd i32)
    (param $dstStart i32) (param $srcEnd i32)
    (param $startOff i32)
    (result i32)
    (local $dstEnd i32)
    (local $cmdStream i32)
    (local $cmdStreamEnd i32)
    (local $lengthStream i32)
    (local $litStream i32)
    (local $off16Stream i32)
    (local $off16StreamEnd i32)
    (local $off32Stream i32)
    (local $off32StreamEnd i32)
    (local $recentOffs i32)
    (local $cmd i32)
    (local $litLen i32)
    (local $matchLen i32)
    (local $match i32)
    (local $length i32)
    (local $newDist i32)
    (local $useDistance i32)
    (local $dstCur i32)
    (local $remaining i32)
    (local $isDelta i32)

    ;; DBG: 7 = entered process_mode
    (i32.store (global.get $DBG_COUNTER) (i32.const 7))

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))
    (local.set $cmdStream (i32.load (global.get $LZ_CMD_START)))
    (local.set $cmdStreamEnd (i32.load (global.get $LZ_CMD_END)))
    (local.set $lengthStream (i32.load (global.get $LZ_LEN_STREAM)))
    (local.set $litStream (i32.load (global.get $LZ_LIT_START)))
    (local.set $off16Stream (i32.load (global.get $LZ_OFF16_START)))
    (local.set $off16StreamEnd (i32.load (global.get $LZ_OFF16_END)))
    (local.set $off32Stream (i32.load (global.get $LZ_OFF32_START)))
    (local.set $off32StreamEnd (i32.load (global.get $LZ_OFF32_END)))
    ;; Read savedDist from shared address (set by process_lz_runs)
    (local.set $recentOffs (i32.load (i32.const 0x9C)))
    (local.set $isDelta (i32.eqz (local.get $mode)))

    (local.set $dstCur (i32.add (local.get $dst) (local.get $startOff)))

    ;; Command loop
    (block $cmdDone
      (loop $cmdLoop
        (br_if $cmdDone (i32.ge_u (local.get $cmdStream) (local.get $cmdStreamEnd)))

        (local.set $cmd (i32.load8_u (local.get $cmdStream)))
        (local.set $cmdStream (i32.add (local.get $cmdStream) (i32.const 1)))

        ;; ── cmd >= 24: Short token ──
        (if (i32.ge_u (local.get $cmd) (i32.const 24))
          (then
            ;; Bounds check
            (if (i32.ge_u (local.get $dstCur) (local.get $dstEnd))
              (then
                ;; Store diagnostics: offset 0x54=dstCur-dst, 0x58=dstSize
                (i32.store (global.get $DBG_COUNTER)
                  (i32.sub (local.get $dstCur) (local.get $dst)))
                (i32.store (i32.const 0x58) (local.get $dstSize))
                (return (i32.const -1)))
            )

            ;; litLen = cmd & 7
            (local.set $litLen (i32.and (local.get $cmd) (i32.const 7)))

            ;; Copy literals
            (if (local.get $isDelta)
              (then
                ;; Delta: dst[i] = lit[i] + dst[i + recentOffs]
                (block $litDone
                  (loop $litLoop
                    (br_if $litDone (i32.eqz (local.get $litLen)))
                    (i32.store8 (local.get $dstCur)
                      (i32.add
                        (i32.load8_u (local.get $litStream))
                        (i32.load8_u (i32.add (local.get $dstCur) (local.get $recentOffs)))))
                    (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 1)))
                    (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
                    (local.set $litLen (i32.sub (local.get $litLen) (i32.const 1)))
                    (br $litLoop)
                  )
                )
              )
              (else
                ;; Raw: copy up to 8 bytes via copy64
                (if (i32.ge_u (local.get $litLen) (i32.const 1))
                  (then
                    (call $copy64 (local.get $dstCur) (local.get $litStream))
                    (local.set $dstCur (i32.add (local.get $dstCur) (i32.and (local.get $cmd) (i32.const 7))))
                    (local.set $litStream (i32.add (local.get $litStream) (i32.and (local.get $cmd) (i32.const 7))))
                  )
                )
              )
            )

            ;; Offset select: bit 7 CLEAR = use new offset from off16
            ;; (bit 7 SET = keep recent offset)
            (local.set $newDist (i32.load16_u (local.get $off16Stream)))
            (if (i32.eqz (i32.and (local.get $cmd) (i32.const 128)))
              (then
                ;; New offset
                (local.set $recentOffs (i32.sub (i32.const 0) (local.get $newDist)))
                (local.set $off16Stream (i32.add (local.get $off16Stream) (i32.const 2)))
              )
            )

            ;; NOTE: offset validation skipped — WASM memory is flat and
            ;; matches may reference the initial 8 literal bytes at negative
            ;; offsets from dstCur (valid within the output buffer region).

            ;; Match copy: matchLen = (cmd >> 3) & 0xF
            (local.set $matchLen (i32.and (i32.shr_u (local.get $cmd) (i32.const 3)) (i32.const 0xF)))
            (local.set $match (i32.add (local.get $dstCur) (local.get $recentOffs)))
            (call $copy64 (local.get $dstCur) (local.get $match))
            (call $copy64 (i32.add (local.get $dstCur) (i32.const 8))
                          (i32.add (local.get $match) (i32.const 8)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $matchLen)))

            (br $cmdLoop)
          )
        )

        ;; ── cmd 3..23: Medium match with off32 ──
        (if (i32.gt_u (local.get $cmd) (i32.const 2))
          (then
            (local.set $length (i32.add (local.get $cmd) (i32.const 5)))

            (if (i32.ge_u (local.get $off32Stream) (local.get $off32StreamEnd))
              (then (return (i32.const -1)))
            )
            ;; dstBegin = dst (start of this 64KB chunk, not dstStart)
            (local.set $match
              (i32.sub (local.get $dst)
                (i32.load (local.get $off32Stream))))
            (local.set $off32Stream (i32.add (local.get $off32Stream) (i32.const 4)))
            (local.set $recentOffs (i32.sub (local.get $match) (local.get $dstCur)))

            (if (i32.lt_s (i32.sub (local.get $dstEnd) (local.get $dstCur)) (local.get $length))
              (then (return (i32.const -1)))
            )

            ;; Copy match (up to 32 bytes via 4x copy64)
            (call $copy64 (local.get $dstCur) (local.get $match))
            (call $copy64 (i32.add (local.get $dstCur) (i32.const 8))
                          (i32.add (local.get $match) (i32.const 8)))
            (call $copy64 (i32.add (local.get $dstCur) (i32.const 16))
                          (i32.add (local.get $match) (i32.const 16)))
            (call $copy64 (i32.add (local.get $dstCur) (i32.const 24))
                          (i32.add (local.get $match) (i32.const 24)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $length)))
            (br $cmdLoop)
          )
        )

        ;; ── cmd == 0: Long literal run ──
        (if (i32.eqz (local.get $cmd))
          (then
            (if (i32.le_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 0))
              (then (return (i32.const -1)))
            )
            (local.set $length (i32.load8_u (local.get $lengthStream)))
            (if (i32.gt_u (local.get $length) (i32.const 251))
              (then
                (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 3))
                  (then (return (i32.const -1)))
                )
                (local.set $length
                  (i32.add (local.get $length)
                    (i32.mul (i32.load16_u (i32.add (local.get $lengthStream) (i32.const 1)))
                             (i32.const 4))))
                (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 2)))
              )
            )
            (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 1)))
            (local.set $length (i32.add (local.get $length) (i32.const 64)))

            ;; Copy literals (long run)
            (if (local.get $isDelta)
              (then
                (block $litLongDone
                  (loop $litLongLoop
                    (br_if $litLongDone (i32.le_s (local.get $length) (i32.const 0)))
                    (i32.store8 (local.get $dstCur)
                      (i32.add
                        (i32.load8_u (local.get $litStream))
                        (i32.load8_u (i32.add (local.get $dstCur) (local.get $recentOffs)))))
                    (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 1)))
                    (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
                    (local.set $length (i32.sub (local.get $length) (i32.const 1)))
                    (br $litLongLoop)
                  )
                )
              )
              (else
                (block $litLongRawDone
                  (loop $litLongRawLoop
                    (br_if $litLongRawDone (i32.le_s (local.get $length) (i32.const 0)))
                    (if (i32.ge_s (local.get $length) (i32.const 8))
                      (then
                        (call $copy64 (local.get $dstCur) (local.get $litStream))
                        (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 8)))
                        (local.set $litStream (i32.add (local.get $litStream) (i32.const 8)))
                        (local.set $length (i32.sub (local.get $length) (i32.const 8)))
                      )
                      (else
                        (i32.store8 (local.get $dstCur) (i32.load8_u (local.get $litStream)))
                        (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 1)))
                        (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
                        (local.set $length (i32.sub (local.get $length) (i32.const 1)))
                      )
                    )
                    (br $litLongRawLoop)
                  )
                )
              )
            )
            (br $cmdLoop)
          )
        )

        ;; ── cmd == 1: Long match with off16 ──
        (if (i32.eq (local.get $cmd) (i32.const 1))
          (then
            (if (i32.le_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 0))
              (then (return (i32.const -1)))
            )
            (local.set $length (i32.load8_u (local.get $lengthStream)))
            (if (i32.gt_u (local.get $length) (i32.const 251))
              (then
                (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 3))
                  (then (return (i32.const -1)))
                )
                (local.set $length
                  (i32.add (local.get $length)
                    (i32.mul (i32.load16_u (i32.add (local.get $lengthStream) (i32.const 1)))
                             (i32.const 4))))
                (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 2)))
              )
            )
            (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 1)))
            (local.set $length (i32.add (local.get $length) (i32.const 91)))

            (if (i32.ge_u (local.get $off16Stream) (local.get $off16StreamEnd))
              (then (return (i32.const -1)))
            )
            (local.set $match
              (i32.sub (local.get $dstCur)
                (i32.load16_u (local.get $off16Stream))))
            (local.set $off16Stream (i32.add (local.get $off16Stream) (i32.const 2)))
            (if (i32.lt_u (local.get $match) (local.get $dstStart))
              (then (return (i32.const -1)))
            )
            (local.set $recentOffs (i32.sub (local.get $match) (local.get $dstCur)))

            ;; Copy match (long)
            (block $matchLongDone
              (loop $matchLongLoop
                (br_if $matchLongDone (i32.le_s (local.get $length) (i32.const 0)))
                (call $copy64 (local.get $dstCur) (local.get $match))
                (call $copy64 (i32.add (local.get $dstCur) (i32.const 8))
                              (i32.add (local.get $match) (i32.const 8)))
                (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 16)))
                (local.set $match (i32.add (local.get $match) (i32.const 16)))
                (local.set $length (i32.sub (local.get $length) (i32.const 16)))
                (br $matchLongLoop)
              )
            )
            ;; Correct overshoot
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $length)))
            (br $cmdLoop)
          )
        )

        ;; ── cmd == 2: Long match with off32 ──
        (if (i32.le_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 0))
          (then (return (i32.const -1)))
        )
        (local.set $length (i32.load8_u (local.get $lengthStream)))
        (if (i32.gt_u (local.get $length) (i32.const 251))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $lengthStream)) (i32.const 3))
              (then (return (i32.const -1)))
            )
            (local.set $length
              (i32.add (local.get $length)
                (i32.mul (i32.load16_u (i32.add (local.get $lengthStream) (i32.const 1)))
                         (i32.const 4))))
            (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 2)))
          )
        )
        (local.set $lengthStream (i32.add (local.get $lengthStream) (i32.const 1)))
        (local.set $length (i32.add (local.get $length) (i32.const 29)))

        (if (i32.ge_u (local.get $off32Stream) (local.get $off32StreamEnd))
          (then (return (i32.const -1)))
        )
        (local.set $match
          (i32.sub (local.get $dst)
            (i32.load (local.get $off32Stream))))
        (local.set $off32Stream (i32.add (local.get $off32Stream) (i32.const 4)))
        (local.set $recentOffs (i32.sub (local.get $match) (local.get $dstCur)))

        ;; Copy match (long)
        (block $matchLong2Done
          (loop $matchLong2Loop
            (br_if $matchLong2Done (i32.le_s (local.get $length) (i32.const 0)))
            (call $copy64 (local.get $dstCur) (local.get $match))
            (call $copy64 (i32.add (local.get $dstCur) (i32.const 8))
                          (i32.add (local.get $match) (i32.const 8)))
            (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 16)))
            (local.set $match (i32.add (local.get $match) (i32.const 16)))
            (local.set $length (i32.sub (local.get $length) (i32.const 16)))
            (br $matchLong2Loop)
          )
        )
        (local.set $dstCur (i32.add (local.get $dstCur) (local.get $length)))
        (br $cmdLoop)
      )
    )

    ;; DBG: 8 = command loop done
    (i32.store (global.get $DBG_COUNTER) (i32.const 8))

    ;; Copy remaining literals
    (local.set $remaining (i32.sub (local.get $dstEnd) (local.get $dstCur)))
    (if (local.get $isDelta)
      (then
        (block $tailDone
          (loop $tailLoop
            (br_if $tailDone (i32.le_s (local.get $remaining) (i32.const 0)))
            (i32.store8 (local.get $dstCur)
              (i32.add
                (i32.load8_u (local.get $litStream))
                (i32.load8_u (i32.add (local.get $dstCur) (local.get $recentOffs)))))
            (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 1)))
            (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
            (local.set $remaining (i32.sub (local.get $remaining) (i32.const 1)))
            (br $tailLoop)
          )
        )
      )
      (else
        (block $tailRawDone
          (loop $tailRawLoop
            (br_if $tailRawDone (i32.le_s (local.get $remaining) (i32.const 0)))
            (if (i32.ge_s (local.get $remaining) (i32.const 8))
              (then
                (call $copy64 (local.get $dstCur) (local.get $litStream))
                (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 8)))
                (local.set $litStream (i32.add (local.get $litStream) (i32.const 8)))
                (local.set $remaining (i32.sub (local.get $remaining) (i32.const 8)))
              )
              (else
                (i32.store8 (local.get $dstCur) (i32.load8_u (local.get $litStream)))
                (local.set $dstCur (i32.add (local.get $dstCur) (i32.const 1)))
                (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
                (local.set $remaining (i32.sub (local.get $remaining) (i32.const 1)))
              )
            )
            (br $tailRawLoop)
          )
        )
      )
    )

    ;; Save updated stream pointers
    (i32.store (global.get $LZ_LEN_STREAM) (local.get $lengthStream))
    (i32.store (global.get $LZ_OFF16_START) (local.get $off16Stream))
    (i32.store (global.get $LZ_LIT_START) (local.get $litStream))
    ;; Write back savedDist for next iteration
    (i32.store (i32.const 0x9C) (local.get $recentOffs))

    (i32.const 0)
  )

  ;; ============================================================
  ;; Huffman Decoder
  ;; ============================================================
  ;;
  ;; Memory layout (at 0x0C100000+):
  ;;   +0x0000: Forward LUT Bits2Len (2064 bytes)
  ;;   +0x0810: Forward LUT Bits2Sym (2064 bytes)
  ;;   +0x1020: Reverse LUT Bits2Len (2064 bytes)
  ;;   +0x1830: Reverse LUT Bits2Sym (2064 bytes)
  ;;   +0x2040: syms (1280 bytes)
  ;;   +0x2540: CodePrefixOrg (48 bytes)
  ;;   +0x2570: CodePrefixCur (48 bytes)

  (global $HUFF_LUT_LEN i32 (i32.const 0x0C100000))
  (global $HUFF_LUT_SYM i32 (i32.const 0x0C100810))
  (global $HUFF_REV_LEN i32 (i32.const 0x0C101020))
  (global $HUFF_REV_SYM i32 (i32.const 0x0C101830))
  (global $HUFF_SYMS    i32 (i32.const 0x0C102040))
  (global $HUFF_PFXORG  i32 (i32.const 0x0C102540))
  (global $HUFF_PFXCUR  i32 (i32.const 0x0C102570))

  ;; CodePrefixOrg data segment
  (data (i32.const 0x0C102540) "\00\00\00\00\00\00\00\00\02\00\00\00\06\00\00\00\0e\00\00\00\1e\00\00\00\3e\00\00\00\7e\00\00\00\fe\00\00\00\fe\01\00\00\fe\02\00\00\fe\03\00\00")

  ;; ── huff_init_prefix ───────────────────────────────────────
  ;; Copy CodePrefixOrg to CodePrefixCur (reset before each table build).
  (func $huff_init_prefix
    (memory.copy (global.get $HUFF_PFXCUR) (global.get $HUFF_PFXORG) (i32.const 48))
  )

  ;; ── huff_read_code_lengths_old ─────────────────────────────
  ;; Read Huffman code lengths using OLD (gamma-coded) format.
  ;; Uses BR at 0x30 as the bit reader.
  ;; Returns numSymbols on success, -1 on error.
  (func $huff_read_code_lengths_old (result i32)
    (local $sym i32)
    (local $codelen i32)
    (local $numSymbols i32)
    (local $avgBitsX4 i32)
    (local $forcedBits i32)
    (local $skipZeros i32)
    (local $n i32)
    (local $lz i32)
    (local $v i32)
    (local $thres i32)
    (local $bits i32)
    (local $codelenBits i32)
    (local $s i32)
    (local $i i32)

    ;; Read first bit (no refill — already refilled by caller)
    (if (i32.ne (call $br_read_bits_no_refill (i32.const 1)) (i32.const 0))
      (then
        ;; Dense encoding
        (local.set $sym (i32.const 0))
        (local.set $numSymbols (i32.const 0))
        (local.set $avgBitsX4 (i32.const 32))
        (local.set $forcedBits (call $br_read_bits_no_refill (i32.const 2)))

        ;; thres = 1 << (31 - (20 >> forcedBits))
        (local.set $thres
          (i32.shl (i32.const 1)
            (i32.sub (i32.const 31)
              (i32.shr_u (i32.const 20) (local.get $forcedBits)))))

        (local.set $skipZeros
          (call $br_read_bit))

        ;; Outer loop: process symbol groups
        (block $outerDone
          (loop $outerLoop
            ;; Skip zeros?
            (if (i32.eqz (local.get $skipZeros))
              (then
                ;; Read gamma-coded zero run
                (local.set $bits (i32.load (global.get $BR_BITS)))
                (if (i32.eqz (i32.and (local.get $bits) (i32.const 0xFF000000)))
                  (then (return (i32.const -1)))
                )
                (local.set $lz (i32.clz (local.get $bits)))
                (local.set $n (i32.add (i32.mul (local.get $lz) (i32.const 2)) (i32.const 2)))
                (local.set $sym
                  (i32.add (local.get $sym)
                    (i32.sub
                      (call $br_read_bits_no_refill (local.get $n))
                      (i32.const 1))))
                (br_if $outerDone (i32.ge_u (local.get $sym) (i32.const 256)))
              )
            )
            (local.set $skipZeros (i32.const 0))

            (call $br_refill)

            ;; Read gamma-coded symbol count
            (local.set $bits (i32.load (global.get $BR_BITS)))
            (if (i32.eqz (i32.and (local.get $bits) (i32.const 0xFF000000)))
              (then (return (i32.const -1)))
            )
            (local.set $lz (i32.clz (local.get $bits)))
            (local.set $n (i32.add (i32.mul (local.get $lz) (i32.const 2)) (i32.const 2)))
            (local.set $n
              (i32.sub
                (call $br_read_bits_no_refill (local.get $n))
                (i32.const 1)))

            (if (i32.gt_u (i32.add (local.get $sym) (local.get $n)) (i32.const 256))
              (then (return (i32.const -1)))
            )

            (call $br_refill)
            (local.set $numSymbols (i32.add (local.get $numSymbols) (local.get $n)))

            ;; Inner loop: read code lengths for n symbols
            (block $innerDone
              (loop $innerLoop
                (br_if $innerDone (i32.le_s (local.get $n) (i32.const 0)))

                (local.set $bits (i32.load (global.get $BR_BITS)))
                (if (i32.lt_u (local.get $bits) (local.get $thres))
                  (then (return (i32.const -1)))
                )

                (local.set $lz (i32.clz (local.get $bits)))
                ;; v = ReadBitsNoRefill(lz + forcedBits + 1) + ((lz-1) << forcedBits)
                (local.set $v
                  (i32.add
                    (call $br_read_bits_no_refill
                      (i32.add (i32.add (local.get $lz) (local.get $forcedBits)) (i32.const 1)))
                    (i32.shl (i32.sub (local.get $lz) (i32.const 1)) (local.get $forcedBits))))

                ;; codelen = (-(v&1) ^ (v>>1)) + ((avgBitsX4+2)>>2)
                (local.set $codelen
                  (i32.add
                    (i32.xor
                      (i32.sub (i32.const 0) (i32.and (local.get $v) (i32.const 1)))
                      (i32.shr_u (local.get $v) (i32.const 1)))
                    (i32.shr_u (i32.add (local.get $avgBitsX4) (i32.const 2)) (i32.const 2))))

                (if (i32.or (i32.lt_s (local.get $codelen) (i32.const 1))
                            (i32.gt_s (local.get $codelen) (i32.const 11)))
                  (then (return (i32.const -1)))
                )

                ;; avgBitsX4 = codelen + ((3 * avgBitsX4 + 2) >> 2)
                (local.set $avgBitsX4
                  (i32.add (local.get $codelen)
                    (i32.shr_u
                      (i32.add (i32.mul (i32.const 3) (local.get $avgBitsX4)) (i32.const 2))
                      (i32.const 2))))

                (call $br_refill)

                ;; syms[codePrefix[codelen]++] = sym++
                (local.set $i
                  (i32.load (i32.add (global.get $HUFF_PFXCUR)
                    (i32.shl (local.get $codelen) (i32.const 2)))))
                (i32.store8
                  (i32.add (global.get $HUFF_SYMS) (local.get $i))
                  (local.get $sym))
                (i32.store (i32.add (global.get $HUFF_PFXCUR)
                    (i32.shl (local.get $codelen) (i32.const 2)))
                  (i32.add (local.get $i) (i32.const 1)))

                (local.set $sym (i32.add (local.get $sym) (i32.const 1)))
                (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                (br $innerLoop)
              )
            )

            (br_if $outerDone (i32.eq (local.get $sym) (i32.const 256)))
            (br $outerLoop)
          )
        )

        (if (i32.or (i32.ne (local.get $sym) (i32.const 256))
                    (i32.lt_s (local.get $numSymbols) (i32.const 2)))
          (then (return (i32.const -1)))
        )
        (return (local.get $numSymbols))
      )
    )

    ;; Sparse encoding
    (local.set $numSymbols (call $br_read_bits_no_refill (i32.const 8)))
    (if (i32.eqz (local.get $numSymbols))
      (then (return (i32.const -1)))
    )
    (if (i32.eq (local.get $numSymbols) (i32.const 1))
      (then
        (i32.store8 (global.get $HUFF_SYMS)
          (call $br_read_bits_no_refill (i32.const 8)))
        (return (i32.const 1))
      )
    )

    ;; Multiple sparse symbols
    (local.set $codelenBits (call $br_read_bits_no_refill (i32.const 3)))
    (if (i32.gt_u (local.get $codelenBits) (i32.const 4))
      (then (return (i32.const -1)))
    )
    (local.set $i (i32.const 0))
    (block $sparseDone
      (loop $sparseLoop
        (br_if $sparseDone (i32.ge_u (local.get $i) (local.get $numSymbols)))
        (call $br_refill)
        (local.set $s (call $br_read_bits_no_refill (i32.const 8)))
        (local.set $codelen
          (i32.add
            (call $br_read_bits_no_refill_zero (local.get $codelenBits))
            (i32.const 1)))
        (if (i32.gt_u (local.get $codelen) (i32.const 11))
          (then (return (i32.const -1)))
        )
        ;; syms[codePrefix[codelen]++] = s
        (local.set $v
          (i32.load (i32.add (global.get $HUFF_PFXCUR)
            (i32.shl (local.get $codelen) (i32.const 2)))))
        (i32.store8
          (i32.add (global.get $HUFF_SYMS) (local.get $v))
          (local.get $s))
        (i32.store (i32.add (global.get $HUFF_PFXCUR)
            (i32.shl (local.get $codelen) (i32.const 2)))
          (i32.add (local.get $v) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $sparseLoop)
      )
    )
    (local.get $numSymbols)
  )

  ;; ── huff_make_lut ──────────────────────────────────────────
  ;; Build forward Huffman LUT (2048 entries) from code prefix arrays.
  ;; Returns 1 on success, 0 on failure.
  (func $huff_make_lut (result i32)
    (local $currslot i32)
    (local $i i32)
    (local $start i32)
    (local $count i32)
    (local $stepsize i32)
    (local $numToSet i32)
    (local $j i32)
    (local $p i32)
    (local $sym i32)

    (local.set $currslot (i32.const 0))

    ;; For code lengths 1..10
    (local.set $i (i32.const 1))
    (block $lutDone
      (loop $lutLoop
        (br_if $lutDone (i32.ge_u (local.get $i) (i32.const 11)))

        (local.set $start
          (i32.load (i32.add (global.get $HUFF_PFXORG)
            (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $count
          (i32.sub
            (i32.load (i32.add (global.get $HUFF_PFXCUR)
              (i32.shl (local.get $i) (i32.const 2))))
            (local.get $start)))

        (if (i32.ne (local.get $count) (i32.const 0))
          (then
            (local.set $stepsize
              (i32.shl (i32.const 1) (i32.sub (i32.const 11) (local.get $i))))
            (local.set $numToSet
              (i32.shl (local.get $count) (i32.sub (i32.const 11) (local.get $i))))

            (if (i32.gt_u (i32.add (local.get $currslot) (local.get $numToSet)) (i32.const 2048))
              (then (return (i32.const 0)))
            )

            ;; Fill Bits2Len with code length i
            (memory.fill
              (i32.add (global.get $HUFF_LUT_LEN) (local.get $currslot))
              (local.get $i)
              (local.get $numToSet))

            ;; Fill Bits2Sym: for each symbol, fill stepsize entries
            (local.set $p (i32.add (global.get $HUFF_LUT_SYM) (local.get $currslot)))
            (local.set $j (i32.const 0))
            (block $symDone
              (loop $symLoop
                (br_if $symDone (i32.ge_u (local.get $j) (local.get $count)))
                (local.set $sym
                  (i32.load8_u (i32.add (global.get $HUFF_SYMS)
                    (i32.add (local.get $start) (local.get $j)))))
                (memory.fill (local.get $p) (local.get $sym) (local.get $stepsize))
                (local.set $p (i32.add (local.get $p) (local.get $stepsize)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $symLoop)
              )
            )

            (local.set $currslot (i32.add (local.get $currslot) (local.get $numToSet)))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lutLoop)
      )
    )

    ;; Code length 11: no step expansion, just copy
    (local.set $start
      (i32.load (i32.add (global.get $HUFF_PFXORG) (i32.const 44))))  ;; [11]
    (local.set $count
      (i32.sub
        (i32.load (i32.add (global.get $HUFF_PFXCUR) (i32.const 44)))
        (local.get $start)))

    (if (i32.ne (local.get $count) (i32.const 0))
      (then
        (if (i32.gt_u (i32.add (local.get $currslot) (local.get $count)) (i32.const 2048))
          (then (return (i32.const 0)))
        )
        (memory.fill
          (i32.add (global.get $HUFF_LUT_LEN) (local.get $currslot))
          (i32.const 11)
          (local.get $count))
        (memory.copy
          (i32.add (global.get $HUFF_LUT_SYM) (local.get $currslot))
          (i32.add (global.get $HUFF_SYMS) (local.get $start))
          (local.get $count))
        (local.set $currslot (i32.add (local.get $currslot) (local.get $count)))
      )
    )

    ;; Must fill exactly 2048 slots
    (i32.eq (local.get $currslot) (i32.const 2048))
  )

  ;; ── huff_reverse_lut ───────────────────────────────────────
  ;; Bit-reverse the 2048-entry LUT for LSB-first 3-stream decoding.
  ;; Scalar path: for each index i, reverse 11 bits → rev, then
  ;; revLut[rev] = forwardLut[i].
  (func $huff_reverse_lut
    (local $i i32)
    (local $rev i32)
    (local $val i32)
    (local $b i32)

    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 2048)))

        ;; Reverse 11 bits of i
        (local.set $rev (i32.const 0))
        (local.set $val (local.get $i))
        (local.set $b (i32.const 0))
        (block $revDone
          (loop $revLoop
            (br_if $revDone (i32.ge_u (local.get $b) (i32.const 11)))
            (local.set $rev
              (i32.or
                (i32.shl (local.get $rev) (i32.const 1))
                (i32.and (local.get $val) (i32.const 1))))
            (local.set $val (i32.shr_u (local.get $val) (i32.const 1)))
            (local.set $b (i32.add (local.get $b) (i32.const 1)))
            (br $revLoop)
          )
        )

        ;; RevLut[rev] = ForwardLut[i]
        (i32.store8
          (i32.add (global.get $HUFF_REV_LEN) (local.get $rev))
          (i32.load8_u (i32.add (global.get $HUFF_LUT_LEN) (local.get $i))))
        (i32.store8
          (i32.add (global.get $HUFF_REV_SYM) (local.get $rev))
          (i32.load8_u (i32.add (global.get $HUFF_LUT_SYM) (local.get $i))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ── huff_bswap32 ───────────────────────────────────────────
  ;; Reverse the byte order of a 32-bit integer (for backward stream).
  (func $huff_bswap32 (param $v i32) (result i32)
    (i32.or
      (i32.or
        (i32.shl (i32.and (local.get $v) (i32.const 0xFF)) (i32.const 24))
        (i32.shl (i32.and (i32.shr_u (local.get $v) (i32.const 8)) (i32.const 0xFF)) (i32.const 16)))
      (i32.or
        (i32.shl (i32.and (i32.shr_u (local.get $v) (i32.const 16)) (i32.const 0xFF)) (i32.const 8))
        (i32.and (i32.shr_u (local.get $v) (i32.const 24)) (i32.const 0xFF))))
  )

  ;; ── huff_decode_3stream ────────────────────────────────────
  ;; 3-stream parallel Huffman decode.
  ;; Parameters: output, outputEnd, src, srcMid, srcEnd
  ;; The forward stream reads [src..srcMid), middle reads [srcMid..srcEnd),
  ;; backward stream reads [srcMid..srcEnd) in reverse.
  ;; Uses HUFF_REV_LEN/HUFF_REV_SYM as the LUT.
  ;; Returns 1 on success, 0 on failure.
  (func $huff_decode_3stream
    (param $dst i32) (param $dstEnd i32)
    (param $src i32) (param $srcMid i32) (param $srcEnd i32)
    (result i32)
    (local $srcBits i32) (local $srcBitpos i32)
    (local $srcMidBits i32) (local $srcMidBitpos i32)
    (local $srcEndBits i32) (local $srcEndBitpos i32)
    (local $srcMidOrg i32)
    (local $lutIndex i32) (local $codeLen i32)
    (local $dstSafe i32)

    (local.set $srcMidOrg (local.get $srcMid))
    (local.set $srcBits (i32.const 0))
    (local.set $srcBitpos (i32.const 0))
    (local.set $srcMidBits (i32.const 0))
    (local.set $srcMidBitpos (i32.const 0))
    (local.set $srcEndBits (i32.const 0))
    (local.set $srcEndBitpos (i32.const 0))

    (if (i32.gt_u (local.get $src) (local.get $srcMid))
      (then (return (i32.const 0)))
    )

    ;; Main loop: decode 6 symbols per iteration
    (if (i32.and
          (i32.ge_s (i32.sub (local.get $srcEnd) (local.get $srcMid)) (i32.const 4))
          (i32.ge_s (i32.sub (local.get $dstEnd) (local.get $dst)) (i32.const 6)))
      (then
        (local.set $dstSafe (i32.sub (local.get $dstEnd) (i32.const 5)))
        (local.set $srcEnd (i32.sub (local.get $srcEnd) (i32.const 4)))

        (block $mainDone
          (loop $mainLoop
            (br_if $mainDone
              (i32.or
                (i32.ge_u (local.get $dst) (local.get $dstSafe))
                (i32.or
                  (i32.gt_u (local.get $src) (local.get $srcMid))
                  (i32.gt_u (local.get $srcMid) (local.get $srcEnd)))))

            ;; Refill forward stream (LE 4-byte load)
            (local.set $srcBits
              (i32.or (local.get $srcBits)
                (i32.shl (i32.load (local.get $src)) (local.get $srcBitpos))))
            (local.set $src
              (i32.add (local.get $src)
                (i32.shr_u (i32.sub (i32.const 31) (local.get $srcBitpos)) (i32.const 3))))

            ;; Refill backward stream (BE 4-byte load = bswap)
            (local.set $srcEndBits
              (i32.or (local.get $srcEndBits)
                (i32.shl
                  (call $huff_bswap32 (i32.load (local.get $srcEnd)))
                  (local.get $srcEndBitpos))))
            (local.set $srcEnd
              (i32.sub (local.get $srcEnd)
                (i32.shr_u (i32.sub (i32.const 31) (local.get $srcEndBitpos)) (i32.const 3))))

            ;; Refill middle stream (LE 4-byte load)
            (local.set $srcMidBits
              (i32.or (local.get $srcMidBits)
                (i32.shl (i32.load (local.get $srcMid)) (local.get $srcMidBitpos))))
            (local.set $srcMid
              (i32.add (local.get $srcMid)
                (i32.shr_u (i32.sub (i32.const 31) (local.get $srcMidBitpos)) (i32.const 3))))

            ;; Clamp bitpos to >= 24
            (local.set $srcBitpos (i32.or (local.get $srcBitpos) (i32.const 0x18)))
            (local.set $srcEndBitpos (i32.or (local.get $srcEndBitpos) (i32.const 0x18)))
            (local.set $srcMidBitpos (i32.or (local.get $srcMidBitpos) (i32.const 0x18)))

            ;; Decode symbol 0 from forward stream
            (local.set $lutIndex (i32.and (local.get $srcBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcBits (i32.shr_u (local.get $srcBits) (local.get $codeLen)))
            (local.set $srcBitpos (i32.sub (local.get $srcBitpos) (local.get $codeLen)))
            (i32.store8 (local.get $dst)
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            ;; Decode symbol 1 from backward stream
            (local.set $lutIndex (i32.and (local.get $srcEndBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcEndBits (i32.shr_u (local.get $srcEndBits) (local.get $codeLen)))
            (local.set $srcEndBitpos (i32.sub (local.get $srcEndBitpos) (local.get $codeLen)))
            (i32.store8 (i32.add (local.get $dst) (i32.const 1))
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            ;; Decode symbol 2 from middle stream
            (local.set $lutIndex (i32.and (local.get $srcMidBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcMidBits (i32.shr_u (local.get $srcMidBits) (local.get $codeLen)))
            (local.set $srcMidBitpos (i32.sub (local.get $srcMidBitpos) (local.get $codeLen)))
            (i32.store8 (i32.add (local.get $dst) (i32.const 2))
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            ;; Decode symbol 3 from forward stream
            (local.set $lutIndex (i32.and (local.get $srcBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcBits (i32.shr_u (local.get $srcBits) (local.get $codeLen)))
            (local.set $srcBitpos (i32.sub (local.get $srcBitpos) (local.get $codeLen)))
            (i32.store8 (i32.add (local.get $dst) (i32.const 3))
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            ;; Decode symbol 4 from backward stream
            (local.set $lutIndex (i32.and (local.get $srcEndBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcEndBits (i32.shr_u (local.get $srcEndBits) (local.get $codeLen)))
            (local.set $srcEndBitpos (i32.sub (local.get $srcEndBitpos) (local.get $codeLen)))
            (i32.store8 (i32.add (local.get $dst) (i32.const 4))
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            ;; Decode symbol 5 from middle stream
            (local.set $lutIndex (i32.and (local.get $srcMidBits) (i32.const 0x7FF)))
            (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
            (local.set $srcMidBits (i32.shr_u (local.get $srcMidBits) (local.get $codeLen)))
            (local.set $srcMidBitpos (i32.sub (local.get $srcMidBitpos) (local.get $codeLen)))
            (i32.store8 (i32.add (local.get $dst) (i32.const 5))
              (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))

            (local.set $dst (i32.add (local.get $dst) (i32.const 6)))
            (br $mainLoop)
          )
        )

        (local.set $dstEnd (i32.add (local.get $dstSafe) (i32.const 5)))

        ;; Normalize bitpos: push unconsumed bytes back
        (local.set $src (i32.sub (local.get $src) (i32.shr_u (local.get $srcBitpos) (i32.const 3))))
        (local.set $srcBitpos (i32.and (local.get $srcBitpos) (i32.const 7)))
        (local.set $srcEnd
          (i32.add (local.get $srcEnd)
            (i32.add (i32.const 4) (i32.shr_u (local.get $srcEndBitpos) (i32.const 3)))))
        (local.set $srcEndBitpos (i32.and (local.get $srcEndBitpos) (i32.const 7)))
        (local.set $srcMid (i32.sub (local.get $srcMid) (i32.shr_u (local.get $srcMidBitpos) (i32.const 3))))
        (local.set $srcMidBitpos (i32.and (local.get $srcMidBitpos) (i32.const 7)))
      )
    )

    ;; Tail loop: one symbol at a time from each stream
    (block $tailDone
      (loop $tailLoop
        (br_if $tailDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

        ;; Refill forward
        (if (i32.gt_s (i32.sub (local.get $srcMid) (local.get $src)) (i32.const 1))
          (then
            (local.set $srcBits
              (i32.or (local.get $srcBits)
                (i32.shl (i32.load16_u (local.get $src)) (local.get $srcBitpos))))
          )
          (else
            (if (i32.eq (i32.sub (local.get $srcMid) (local.get $src)) (i32.const 1))
              (then
                (local.set $srcBits
                  (i32.or (local.get $srcBits)
                    (i32.shl (i32.load8_u (local.get $src)) (local.get $srcBitpos))))
              )
            )
          )
        )

        ;; Decode from forward
        (local.set $lutIndex (i32.and (local.get $srcBits) (i32.const 0x7FF)))
        (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
        (local.set $srcBitpos (i32.sub (local.get $srcBitpos) (local.get $codeLen)))
        (local.set $srcBits (i32.shr_u (local.get $srcBits) (local.get $codeLen)))
        (i32.store8 (local.get $dst)
          (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))
        (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
        (local.set $src
          (i32.add (local.get $src)
            (i32.shr_u (i32.sub (i32.const 7) (local.get $srcBitpos)) (i32.const 3))))
        (local.set $srcBitpos (i32.and (local.get $srcBitpos) (i32.const 7)))

        (br_if $tailDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

        ;; Refill backward + middle
        (if (i32.gt_s (i32.sub (local.get $srcEnd) (local.get $srcMid)) (i32.const 1))
          (then
            ;; Backward: 2-byte BE load from srcEnd-2
            (local.set $srcEndBits
              (i32.or (local.get $srcEndBits)
                (i32.shl
                  (i32.or
                    (i32.shr_u (i32.load16_u (i32.sub (local.get $srcEnd) (i32.const 2))) (i32.const 8))
                    (i32.shl (i32.load8_u (i32.sub (local.get $srcEnd) (i32.const 2))) (i32.const 8)))
                  (local.get $srcEndBitpos))))
            ;; Middle: LE load
            (local.set $srcMidBits
              (i32.or (local.get $srcMidBits)
                (i32.shl (i32.load16_u (local.get $srcMid)) (local.get $srcMidBitpos))))
          )
          (else
            (if (i32.eq (i32.sub (local.get $srcEnd) (local.get $srcMid)) (i32.const 1))
              (then
                (local.set $srcEndBits
                  (i32.or (local.get $srcEndBits)
                    (i32.shl (i32.load8_u (local.get $srcMid)) (local.get $srcEndBitpos))))
                (local.set $srcMidBits
                  (i32.or (local.get $srcMidBits)
                    (i32.shl (i32.load8_u (local.get $srcMid)) (local.get $srcMidBitpos))))
              )
            )
          )
        )

        ;; Decode from backward
        (local.set $lutIndex (i32.and (local.get $srcEndBits) (i32.const 0x7FF)))
        (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
        (i32.store8 (local.get $dst)
          (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))
        (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
        (local.set $srcEndBitpos (i32.sub (local.get $srcEndBitpos) (local.get $codeLen)))
        (local.set $srcEndBits (i32.shr_u (local.get $srcEndBits) (local.get $codeLen)))
        (local.set $srcEnd
          (i32.sub (local.get $srcEnd)
            (i32.shr_u (i32.sub (i32.const 7) (local.get $srcEndBitpos)) (i32.const 3))))
        (local.set $srcEndBitpos (i32.and (local.get $srcEndBitpos) (i32.const 7)))

        (br_if $tailDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

        ;; Decode from middle
        (local.set $lutIndex (i32.and (local.get $srcMidBits) (i32.const 0x7FF)))
        (local.set $codeLen (i32.load8_u (i32.add (global.get $HUFF_REV_LEN) (local.get $lutIndex))))
        (i32.store8 (local.get $dst)
          (i32.load8_u (i32.add (global.get $HUFF_REV_SYM) (local.get $lutIndex))))
        (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
        (local.set $srcMidBitpos (i32.sub (local.get $srcMidBitpos) (local.get $codeLen)))
        (local.set $srcMidBits (i32.shr_u (local.get $srcMidBits) (local.get $codeLen)))
        (local.set $srcMid
          (i32.add (local.get $srcMid)
            (i32.shr_u (i32.sub (i32.const 7) (local.get $srcMidBitpos)) (i32.const 3))))
        (local.set $srcMidBitpos (i32.and (local.get $srcMidBitpos) (i32.const 7)))

        ;; Check convergence
        (if (i32.or (i32.gt_u (local.get $src) (local.get $srcMid))
                    (i32.gt_u (local.get $srcMid) (local.get $srcEnd)))
          (then (return (i32.const 0)))
        )
        (br $tailLoop)
      )
    )

    ;; Final check: src == srcMidOrg && srcEnd == srcMid
    (i32.and
      (i32.eq (local.get $src) (local.get $srcMidOrg))
      (i32.eq (local.get $srcEnd) (local.get $srcMid)))
  )

  ;; ── high_decode_huff ───────────────────────────────────────
  ;; Decode a Huffman-coded entropy block (types 2 or 4).
  ;; type=1 for 2-way split, type=2 for 4-way split.
  ;; Returns total source bytes consumed from srcStart, or -1 on error.
  (func $high_decode_huff
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
    (param $type i32) (param $srcStart i32)
    (result i32)
    (local $srcEnd i32)
    (local $numSyms i32)
    (local $splitMid i32)
    (local $splitLeft i32)
    (local $splitRight i32)
    (local $srcMid i32)
    (local $halfOutput i32)

    (local.set $srcEnd (i32.add (local.get $src) (local.get $srcSize)))

    ;; Initialize bit reader for code-length decode
    (call $br_init (local.get $src) (local.get $srcEnd))
    (call $br_refill)

    ;; Initialize prefix arrays
    (call $huff_init_prefix)
    ;; Also copy org to a separate location for MakeLut
    (memory.copy (global.get $HUFF_PFXORG) (i32.const 0x0C102540) (i32.const 48))

    ;; Read first bit: 0 = old path
    (if (i32.eqz (call $br_read_bits_no_refill (i32.const 1)))
      (then
        (local.set $numSyms (call $huff_read_code_lengths_old))
      )
      (else
        ;; bit1: 0 = new (Golomb-Rice) path — not implemented for now
        (if (i32.eqz (call $br_read_bits_no_refill (i32.const 1)))
          (then
            ;; NEW path — TODO: implement Golomb-Rice code-length reader
            (return (i32.const -1))
          )
          (else
            (return (i32.const -1))  ;; error: bit pattern 11
          )
        )
      )
    )

    (if (i32.lt_s (local.get $numSyms) (i32.const 1))
      (then (return (i32.const -1)))
    )

    ;; Recover src position from bit reader
    (local.set $src
      (i32.sub (i32.load (global.get $BR_P))
        (i32.shr_u
          (i32.sub (i32.const 24) (i32.load (global.get $BR_BITPOS)))
          (i32.const 3))))

    ;; Special case: 1 symbol = fill output
    (if (i32.eq (local.get $numSyms) (i32.const 1))
      (then
        (memory.fill (local.get $dst)
          (i32.load8_u (global.get $HUFF_SYMS))
          (local.get $dstSize))
        (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))
        (return (i32.sub
          (i32.add (local.get $src) (local.get $srcSize))
          (local.get $srcStart)))
      )
    )

    ;; Build forward LUT
    (if (i32.eqz (call $huff_make_lut))
      (then (return (i32.const -1)))
    )

    ;; Build reversed LUT
    (call $huff_reverse_lut)

    ;; Dispatch based on type
    (if (i32.eq (local.get $type) (i32.const 1))
      (then
        ;; Type 1 (2-way split): single 3-stream decode
        (if (i32.gt_u (i32.add (local.get $src) (i32.const 3)) (local.get $srcEnd))
          (then (return (i32.const -1)))
        )
        (local.set $splitMid (i32.load16_u (local.get $src)))
        (local.set $src (i32.add (local.get $src) (i32.const 2)))

        (if (i32.eqz
              (call $huff_decode_3stream
                (local.get $dst)
                (i32.add (local.get $dst) (local.get $dstSize))
                (local.get $src)
                (i32.add (local.get $src) (local.get $splitMid))
                (local.get $srcEnd)))
          (then (return (i32.const -1)))
        )
      )
      (else
        ;; Type 2 (4-way split): two 3-stream decodes
        (if (i32.gt_u (i32.add (local.get $src) (i32.const 6)) (local.get $srcEnd))
          (then (return (i32.const -1)))
        )
        (local.set $halfOutput (i32.shr_u (i32.add (local.get $dstSize) (i32.const 1)) (i32.const 1)))

        ;; Read 3-byte split for first/second half boundary
        (local.set $splitMid
          (i32.and
            (i32.or
              (i32.or (i32.load8_u (local.get $src))
                      (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 1))) (i32.const 8)))
              (i32.shl (i32.load8_u (i32.add (local.get $src) (i32.const 2))) (i32.const 16)))
            (i32.const 0xFFFFFF)))
        (local.set $src (i32.add (local.get $src) (i32.const 3)))
        (local.set $srcMid (i32.add (local.get $src) (local.get $splitMid)))

        ;; Read 2-byte left split
        (local.set $splitLeft (i32.load16_u (local.get $src)))
        (local.set $src (i32.add (local.get $src) (i32.const 2)))

        ;; Read 2-byte right split
        (local.set $splitRight (i32.load16_u (local.get $srcMid)))

        ;; First half
        (if (i32.eqz
              (call $huff_decode_3stream
                (local.get $dst)
                (i32.add (local.get $dst) (local.get $halfOutput))
                (local.get $src)
                (i32.add (local.get $src) (local.get $splitLeft))
                (local.get $srcMid)))
          (then (return (i32.const -1)))
        )

        ;; Second half
        (if (i32.eqz
              (call $huff_decode_3stream
                (i32.add (local.get $dst) (local.get $halfOutput))
                (i32.add (local.get $dst) (local.get $dstSize))
                (i32.add (local.get $srcMid) (i32.const 2))
                (i32.add (i32.add (local.get $srcMid) (i32.const 2)) (local.get $splitRight))
                (local.get $srcEnd)))
          (then (return (i32.const -1)))
        )
      )
    )

    (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))
    (i32.sub
      (i32.add (local.get $src) (local.get $srcSize))
      (local.get $srcStart))
  )
)
