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

    ;; Verify codec: 0 (High) or 1 (Fast)
    (if (i32.gt_u (i32.load8_u (global.get $HDR_CODEC)) (i32.const 1))
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

  ;; ── decompressChunk ──────────────────────────────────────────
  ;; Decompress a single SC chunk directly (no frame/block header parsing).
  ;; Input: chunk data at INPUT_BASE (StreamLZ header + chunk header + sub-chunks).
  ;; Output: decompressed data at OUTPUT_BASE.
  ;; Parameters:
  ;;   inputLen — byte length of chunk data at INPUT_BASE
  ;;   dstSize  — expected decompressed size
  ;; Returns: decompressed size on success, -1 on error.
  (func (export "decompressChunk") (param $inputLen i32) (param $dstSize i32) (result i32)
    (if (i32.lt_s
          (call $decode_block
            (global.get $INPUT_BASE)
            (i32.add (global.get $INPUT_BASE) (local.get $inputLen))
            (global.get $OUTPUT_BASE)
            (local.get $dstSize))
          (i32.const 0))
      (then (return (i32.const -1)))
    )
    (local.get $dstSize)
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
    (local $isSC i32)

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))
    (local.set $dstCur (local.get $dst))
    (local.set $offset (i32.const 0))
    (local.set $isSC (i32.const 0))

    ;; Outer loop: one iteration per 256KB StreamLZ chunk
    (block $blockDone
      (loop $chunkOuterLoop
        (br_if $blockDone (i32.ge_u (local.get $dstCur) (local.get $dstEnd)))

        ;; Track: pack chunk_index (upper 16) and sub-chunk iterations completed (lower 16)
        (global.set $TRACE (i32.shr_u (local.get $offset) (i32.const 18)))
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
            (local.set $isSC (i32.and (i32.shr_u (local.get $b0) (i32.const 4)) (i32.const 1)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
            ;; Accept decoder type 0 (High) or 1 (Fast)
            (if (i32.gt_u (local.get $decoderType) (i32.const 1))
              (then (return (i32.const -1)))
            )
          )
        )

        ;; Store chunk dstStart (at 0xD0):
        ;; SC mode: per-chunk (each chunk independent)
        ;; Non-SC mode: block start (cross-chunk references)
        (if (local.get $isSC)
          (then (i32.store (i32.const 0xD0) (local.get $dstCur)))
          (else (i32.store (i32.const 0xD0) (local.get $dst)))
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
          (then (global.set $TRACE (i32.const -2001)) (return (i32.const -1)))
        )

        (local.set $subHdr (call $read_be24 (local.get $src)))

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
              (then
                ;; Store the first byte of the failing entropy block for diagnosis

                (global.set $TRACE (i32.const -2010)) (return (i32.const -1)))
            )
            (if (i32.ne (i32.load (global.get $ENT_DECODED_SIZE)) (local.get $dstCount))
              (then (global.set $TRACE (i32.const -2011)) (return (i32.const -1)))
            )
            (local.set $src (i32.add (local.get $src) (local.get $srcUsed)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $dstCount)))
            (local.set $chunkBytesLeft (i32.sub (local.get $chunkBytesLeft) (local.get $dstCount)))
            (local.set $offset (i32.add (local.get $offset) (local.get $dstCount)))
            (br $chunkLoop)
          )
        )

        ;; Compressed — extract size and mode from sub-chunk header
        (local.set $src (i32.add (local.get $src) (i32.const 3)))
        (local.set $srcUsed (i32.and (local.get $subHdr) (i32.const 0x7FFFF)))
        (local.set $mode (i32.and (i32.shr_u (local.get $subHdr) (i32.const 19)) (i32.const 0xF)))

        ;; Validate source data available
        (if (i32.gt_s (local.get $srcUsed) (i32.sub (local.get $srcEnd) (local.get $src)))
          (then (global.set $TRACE (i32.const -2020)) (return (i32.const -1)))
        )

        ;; If srcUsed >= dstCount and mode == 0, stored (copy)
        (if (i32.and
              (i32.ge_u (local.get $srcUsed) (local.get $dstCount))
              (i32.eqz (local.get $mode)))
          (then
            (if (i32.ne (local.get $srcUsed) (local.get $dstCount))
              (then (global.set $TRACE (i32.const -2021)) (return (i32.const -1)))
            )
            (memory.copy (local.get $dstCur) (local.get $src) (local.get $dstCount))
            (local.set $src (i32.add (local.get $src) (local.get $srcUsed)))
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $dstCount)))
            (local.set $chunkBytesLeft (i32.sub (local.get $chunkBytesLeft) (local.get $dstCount)))
            (local.set $offset (i32.add (local.get $offset) (local.get $dstCount)))
            (br $chunkLoop)
          )
        )

        ;; LZ compressed — route to High or Fast decoder
        (if (i32.eqz (local.get $decoderType))
          (then
            ;; High codec (decoder type 0)
            ;; SC mode: dstStart = chunk output start (stored at start of outer loop)
            ;; This makes offset = dst - dstStart = position within current chunk
            (if (i32.lt_s
                  (call $high_decode_chunk_lz
                    (local.get $src)
                    (i32.add (local.get $src) (local.get $srcUsed))
                    (local.get $dstCur)
                    (local.get $dstCount)
                    (local.get $mode)
                    (i32.load (i32.const 0xD0)))  ;; chunk dstStart from outer loop
                  (i32.const 0))
              (then (return (i32.const -1)))  ;; TRACE already set by inner function
            )
          )
          (else
            ;; Fast codec (decoder type 1)
            (if (i32.lt_s
                  (call $fast_decode_chunk
                    (local.get $src)
                    (i32.add (local.get $src) (local.get $srcUsed))
                    (local.get $dstCur)
                    (local.get $dstCount)
                    (local.get $mode)
                    (local.get $dst))
                  (i32.const 0))
              (then (global.set $TRACE (i32.const -2030)) (return (i32.const -1)))
            )
          )
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

