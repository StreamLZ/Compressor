
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

