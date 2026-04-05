  ;; ── 090-high-lz: High codec decoder (L6-L11) ───────────────
  ;; Function: $high_decode_chunk_lz
  ;; Pipeline: ReadLzTable → UnpackOffsets → ResolveTokens → Execute
  ;; State: SC dstStart at 0xD0, lastOffset at 0xD4 (delta mode)
  ;; Scratch: HLZ_TABLE at 0x230000, HLZ_SCRATCH at 0x230020,
  ;;          offsets at 0x270020, lengths at 0x2F0020, tokens at 0x370020
  ;;
  ;; Memory layout for High LZ working space (at 0x00230000):
  ;;   HighLzTable: CmdStream(4), CmdStreamSize(4), OffsStream(4), OffsStreamSize(4),
  ;;                LitStream(4), LitStreamSize(4), LenStream(4), LenStreamSize(4) = 32 bytes
  ;;   Token array: up to 128KB / 4 = 32K tokens * 16 bytes = 512KB
  ;;   Offset/Length unpacked arrays: up to 128KB entries * 4 = 512KB each

  (global $HIGH_LZ_TABLE i32 (i32.const 0x00230000))
  ;; HighLzTable fields (32 bytes)
  (global $HLZ_CMD       i32 (i32.const 0x00230000))  ;; CmdStream ptr
  (global $HLZ_CMD_SIZE  i32 (i32.const 0x00230004))  ;; CmdStreamSize
  (global $HLZ_OFFS      i32 (i32.const 0x00230008))  ;; OffsStream ptr (int*)
  (global $HLZ_OFFS_SIZE i32 (i32.const 0x0023000C))  ;; OffsStreamSize
  (global $HLZ_LIT       i32 (i32.const 0x00230010))  ;; LitStream ptr
  (global $HLZ_LIT_SIZE  i32 (i32.const 0x00230014))  ;; LitStreamSize
  (global $HLZ_LEN       i32 (i32.const 0x00230018))  ;; LenStream ptr (int*)
  (global $HLZ_LEN_SIZE  i32 (i32.const 0x0023001C))  ;; LenStreamSize

  ;; Scratch areas
  (global $HLZ_SCRATCH    i32 (i32.const 0x00230020))  ;; entropy decode scratch (256KB)
  (global $HLZ_OFFS_BUF   i32 (i32.const 0x00270020))  ;; unpacked offsets (128K * 4 = 512KB)
  (global $HLZ_LEN_BUF    i32 (i32.const 0x002F0020))  ;; unpacked lengths (128K * 4 = 512KB)
  (global $HLZ_TOKEN_BUF  i32 (i32.const 0x00370020))  ;; token array (32K * 16 = 512KB)

  ;; ── high_decode_chunk_lz ───────────────────────────────────
  ;; High LZ decoder: ReadLzTable + ResolveTokens + ExecuteTokens.
  ;; Returns 0 on success, -1 on error.
  (func $high_decode_chunk_lz
    (param $src i32) (param $srcEnd i32)
    (param $dst i32) (param $dstCount i32)
    (param $mode i32) (param $dstStart i32)
    (result i32)
    (local $offset i32)
    (local $scratch i32) (local $lowBitsPtr i32) (local $bytesRead i32)
    (local $offsScaling i32)
    (local $packedOffsStream i32) (local $packedLenStream i32)
    ;; UnpackOffsets locals
    (local $bitsA_p i32) (local $bitsA_pEnd i32) (local $bitsA_bits i32) (local $bitsA_bitpos i32)
    (local $bitsB_p i32) (local $bitsB_pEnd i32) (local $bitsB_bits i32) (local $bitsB_bitpos i32)
    (local $u32LenStreamSize i32) (local $i i32)
    (local $cmd i32) (local $nb i32) (local $offs i32)
    ;; ResolveTokens + Execute locals
    (local $cmdStream i32) (local $cmdStreamEnd i32)
    (local $lenStream i32) (local $offsStream i32)
    (local $recent3 i32) (local $recent4 i32) (local $recent5 i32)
    (local $dstPos i32) (local $tokenCount i32)
    (local $litLen i32) (local $matchLen i32) (local $offIdx i32)
    (local $tokOffset i32) (local $litStream i32)
    (local $match i32) (local $remaining i32)

    (local.set $offset (i32.sub (local.get $dst) (local.get $dstStart)))

    ;; Validate
    (if (i32.or (i32.gt_u (local.get $mode) (i32.const 1))
                (i32.le_s (local.get $dstCount) (i32.const 0)))
      (then (global.set $TRACE (i32.const -3001)) (return (i32.const -1)))
    )
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 13))
      (then (global.set $TRACE (i32.const -3002)) (return (i32.const -1)))
    )

    ;; Initial 8 literal bytes
    (if (i32.eqz (local.get $offset))
      (then
        (call $copy64 (local.get $dst) (local.get $src))
        (local.set $src (i32.add (local.get $src) (i32.const 8)))
      )
    )

    ;; Check excess flag (not supported)
    (if (i32.and (i32.load8_u (local.get $src)) (i32.const 0x80))
      (then (global.set $TRACE (i32.const -3003)) (return (i32.const -1)))
    )

    (local.set $scratch (global.get $HLZ_SCRATCH))

    ;; ── ReadLzTable: decode 4 entropy streams (lit, cmd, offs, litlen) ──
    ;; Each follows: decode → check error → store ptr+size → advance src+scratch

    ;; 1. Literal stream
    (local.set $lowBitsPtr
      (call $high_decode_bytes (local.get $src) (local.get $srcEnd)
        (local.get $scratch) (local.get $dstCount)))
    (if (i32.lt_s (local.get $lowBitsPtr) (i32.const 0))
      (then (global.set $TRACE (i32.const -3004)) (return (i32.const -1)))
    )
    (local.set $bytesRead (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $lowBitsPtr)))
    (i32.store (global.get $HLZ_LIT) (local.get $scratch))
    (i32.store (global.get $HLZ_LIT_SIZE) (local.get $bytesRead))
    (local.set $scratch (i32.add (local.get $scratch) (local.get $bytesRead)))

    ;; 2. Command stream
    (local.set $lowBitsPtr
      (call $high_decode_bytes (local.get $src) (local.get $srcEnd)
        (local.get $scratch) (local.get $dstCount)))
    (if (i32.lt_s (local.get $lowBitsPtr) (i32.const 0))
      (then (global.set $TRACE (i32.const -3005)) (return (i32.const -1)))
    )
    (local.set $bytesRead (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $lowBitsPtr)))
    (i32.store (global.get $HLZ_CMD) (local.get $scratch))
    (i32.store (global.get $HLZ_CMD_SIZE) (local.get $bytesRead))
    (local.set $scratch (i32.add (local.get $scratch) (local.get $bytesRead)))

    ;; ── Check offset scaling mode ──
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 3))
      (then (global.set $TRACE (i32.const -3006)) (return (i32.const -1)))
    )

    (local.set $offsScaling (i32.const 0))
    (if (i32.and (i32.load8_u (local.get $src)) (i32.const 0x80))
      (then
        ;; New offset scaling mode
        (local.set $offsScaling (i32.sub (i32.load8_u (local.get $src)) (i32.const 127)))
        (local.set $src (i32.add (local.get $src) (i32.const 1)))
      )
    )

    ;; 3. Packed offset stream
    (local.set $packedOffsStream (local.get $scratch))
    (local.set $lowBitsPtr
      (call $high_decode_bytes (local.get $src) (local.get $srcEnd)
        (local.get $scratch) (i32.load (global.get $HLZ_CMD_SIZE))))
    (if (i32.lt_s (local.get $lowBitsPtr) (i32.const 0))
      (then (global.set $TRACE (i32.const -3007)) (return (i32.const -1)))
    )
    (i32.store (global.get $HLZ_OFFS_SIZE) (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $lowBitsPtr)))
    (local.set $scratch (i32.add (local.get $scratch) (i32.load (global.get $HLZ_OFFS_SIZE))))

    ;; Extra offset stream for offsScaling > 1: low-order bits per offset
    (local.set $lowBitsPtr (i32.const 0))  ;; reuse as packedOffsStreamExtra pointer
    (if (i32.and (i32.ne (local.get $offsScaling) (i32.const 0))
                 (i32.ne (local.get $offsScaling) (i32.const 1)))
      (then
        ;; Decode extra offset stream
        (local.set $lowBitsPtr (local.get $scratch))  ;; packedOffsStreamExtra = scratch
        (local.set $bytesRead (i32.const 0))
        (local.set $i  ;; reuse as temp for decode result
          (call $high_decode_bytes (local.get $src) (local.get $srcEnd)
            (local.get $scratch) (i32.load (global.get $HLZ_OFFS_SIZE))))
        (if (i32.lt_s (local.get $i) (i32.const 0))
          (then (return (i32.const -1)))
        )
        (if (i32.ne (i32.load (global.get $ENT_DECODED_SIZE)) (i32.load (global.get $HLZ_OFFS_SIZE)))
          (then (return (i32.const -1)))
        )
        (local.set $src (i32.add (local.get $src) (local.get $i)))
        (local.set $scratch (i32.add (local.get $scratch) (i32.load (global.get $HLZ_OFFS_SIZE))))
      )
    )

    ;; Save lowBits to a safe location (0x002E0000) before litlen decode can corrupt them
    (if (i32.and (i32.ne (local.get $offsScaling) (i32.const 0))
                 (i32.ne (local.get $offsScaling) (i32.const 1)))
      (then
        (memory.copy (i32.const 0x002E0000) (local.get $lowBitsPtr)
          (i32.load (global.get $HLZ_OFFS_SIZE)))
        (local.set $lowBitsPtr (i32.const 0x002E0000))
      )
    )

    ;; 4. Packed litlen stream
    (local.set $packedLenStream (local.get $scratch))
    (local.set $bytesRead  ;; reuse $bytesRead as temp (not $lowBitsPtr — $lowBitsPtr holds lowBits address!)
      (call $high_decode_bytes (local.get $src) (local.get $srcEnd)
        (local.get $scratch) (i32.shr_u (local.get $dstCount) (i32.const 2))))
    (if (i32.lt_s (local.get $bytesRead) (i32.const 0))
      (then (global.set $TRACE (i32.const -3009)) (return (i32.const -1)))
    )
    (i32.store (global.get $HLZ_LEN_SIZE) (i32.load (global.get $ENT_DECODED_SIZE)))
    (local.set $src (i32.add (local.get $src) (local.get $bytesRead)))
    (local.set $scratch (i32.add (local.get $scratch) (i32.load (global.get $HLZ_LEN_SIZE))))

    ;; ── Reserve and set offset/length stream pointers ──
    (i32.store (global.get $HLZ_OFFS) (global.get $HLZ_OFFS_BUF))
    (i32.store (global.get $HLZ_LEN) (global.get $HLZ_LEN_BUF))

    ;; ── UnpackOffsets ──
    ;; Initialize forward bit reader (bitsA)
    (local.set $bitsA_p (local.get $src))
    (local.set $bitsA_pEnd (local.get $srcEnd))
    (local.set $bitsA_bits (i32.const 0))
    (local.set $bitsA_bitpos (i32.const 24))
    ;; Refill A
    (block $refA (loop $rA
      (br_if $refA (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
      (br_if $refA (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
      (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
        (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
      (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
      (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
      (br $rA)))

    ;; Initialize backward bit reader (bitsB)
    (local.set $bitsB_p (local.get $srcEnd))
    (local.set $bitsB_pEnd (local.get $src))
    (local.set $bitsB_bits (i32.const 0))
    (local.set $bitsB_bitpos (i32.const 24))
    ;; Refill B (backwards)
    (block $refB (loop $rB
      (br_if $refB (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
      (br_if $refB (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
      (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
      (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
        (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
      (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
      (br $rB)))

    ;; Read u32LenStreamSize from backward reader (gamma coded)
    (local.set $u32LenStreamSize (i32.const 0))
    (if (i32.lt_u (local.get $bitsB_bits) (i32.const 0x2000))
      (then (global.set $TRACE (i32.const -3010)) (return (i32.const -1)))
    )
    (local.set $bytesRead (i32.clz (local.get $bitsB_bits)))  ;; use $bytesRead as temp, NOT $lowBitsPtr (lowBits ptr!)
    (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $bytesRead)))
    (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (local.get $bytesRead)))
    ;; Refill B
    (block $refB2 (loop $rB2
      (br_if $refB2 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
      (br_if $refB2 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
      (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
      (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
        (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
      (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
      (br $rB2)))
    (local.set $bytesRead (i32.add (local.get $bytesRead) (i32.const 1)))
    (local.set $u32LenStreamSize
      (i32.sub (i32.shr_u (local.get $bitsB_bits) (i32.sub (i32.const 32) (local.get $bytesRead))) (i32.const 1)))
    (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $bytesRead)))
    (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (local.get $bytesRead)))
    ;; Refill B
    (block $refB3 (loop $rB3
      (br_if $refB3 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
      (br_if $refB3 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
      (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
      (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
        (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
      (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
      (br $rB3)))

    ;; Unpack offsets (new scaling mode: nb = cmd >> 3, base = (8 + (cmd & 7)) << nb)
    (if (i32.ne (local.get $offsScaling) (i32.const 0))
      (then
        (local.set $offsStream (global.get $HLZ_OFFS_BUF))
        (local.set $i (i32.const 0))
        (block $offsDone
          (loop $offsLoop
            (br_if $offsDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_OFFS_SIZE))))

            ;; Forward offset
            (local.set $cmd (i32.load8_u (i32.add (local.get $packedOffsStream) (local.get $i))))
            (local.set $nb (i32.shr_u (local.get $cmd) (i32.const 3)))
            (local.set $offs (i32.shl (i32.add (i32.const 8) (i32.and (local.get $cmd) (i32.const 7))) (local.get $nb)))
            ;; Read nb extra bits from forward reader
            (if (i32.gt_s (local.get $nb) (i32.const 0))
              (then
                ;; ReadMoreThan24Bits for forward
                (if (i32.le_s (local.get $nb) (i32.const 24))
                  (then
                    ;; Refill A
                    (block $rA4 (loop $rA4L
                      (br_if $rA4 (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
                      (br_if $rA4 (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
                      (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
                        (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
                      (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
                      (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
                      (br $rA4L)))
                    ;; Read nb bits from MSB
                    (local.set $offs (i32.or (local.get $offs)
                      (i32.shr_u
                        (i32.shr_u (local.get $bitsA_bits) (i32.const 1))
                        (i32.sub (i32.const 31) (local.get $nb)))))
                    (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (local.get $nb)))
                    (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $nb)))
                    ;; Refill A
                    (block $rA5 (loop $rA5L
                      (br_if $rA5 (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
                      (br_if $rA5 (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
                      (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
                        (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
                      (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
                      (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
                      (br $rA5L)))
                  )
                )
              )
            )
            (i32.store (i32.add (local.get $offsStream) (i32.shl (local.get $i) (i32.const 2)))
              (i32.sub (i32.const 8) (local.get $offs)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br_if $offsDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_OFFS_SIZE))))

            ;; Backward offset
            (local.set $cmd (i32.load8_u (i32.add (local.get $packedOffsStream) (local.get $i))))
            (local.set $nb (i32.shr_u (local.get $cmd) (i32.const 3)))
            (local.set $offs (i32.shl (i32.add (i32.const 8) (i32.and (local.get $cmd) (i32.const 7))) (local.get $nb)))
            (if (i32.gt_s (local.get $nb) (i32.const 0))
              (then
                (if (i32.le_s (local.get $nb) (i32.const 24))
                  (then
                    ;; Refill B
                    (block $rB4 (loop $rB4L
                      (br_if $rB4 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
                      (br_if $rB4 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
                      (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
                      (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
                        (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
                      (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
                      (br $rB4L)))
                    (local.set $offs (i32.or (local.get $offs)
                      (i32.shr_u
                        (i32.shr_u (local.get $bitsB_bits) (i32.const 1))
                        (i32.sub (i32.const 31) (local.get $nb)))))
                    (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (local.get $nb)))
                    (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $nb)))
                    ;; Refill B
                    (block $rB5 (loop $rB5L
                      (br_if $rB5 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
                      (br_if $rB5 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
                      (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
                      (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
                        (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
                      (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
                      (br $rB5L)))
                  )
                )
              )
            )
            (i32.store (i32.add (local.get $offsStream) (i32.shl (local.get $i) (i32.const 2)))
              (i32.sub (i32.const 8) (local.get $offs)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $offsLoop)
          )
        )
      )
      (else
        ;; Traditional offset mode (offsScaling == 0)
        ;; Uses ReadDistance from bidirectional bitstream
        ;; Each packed offset byte encodes: offset = ReadDistance(packedByte)
        ;; Alternates forward/backward readers
        (local.set $offsStream (global.get $HLZ_OFFS_BUF))
        (local.set $i (i32.const 0))
        (block $tradDone
          (loop $tradLoop
            (br_if $tradDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_OFFS_SIZE))))

            ;; Forward: ReadDistance from bitsA
            (local.set $cmd (i32.load8_u (i32.add (local.get $packedOffsStream) (local.get $i))))
            ;; ReadDistance: complex encoding based on cmd value
            ;; For cmd < 0xF0 (HighOffsetMarker):
            ;;   bitsToRead = (cmd >> 4) + 5
            ;;   result = ((rotl(bits|1, bitsToRead) & mask) << 4) + (cmd & 0xF) - 760
            ;; For cmd >= 0xF0:
            ;;   bitsToRead = cmd - 0xF0 + 4
            ;;   result = 16710912 + (rotl(bits|1, bitsToRead) & mask) << 12 + bits>>20 * blah
            ;; This is very complex. For now, use a simplified version.
            ;; TODO: implement full ReadDistance
            (if (i32.lt_u (local.get $cmd) (i32.const 0xF0))
              (then
                (local.set $nb (i32.add (i32.shr_u (local.get $cmd) (i32.const 4)) (i32.const 5)))
                ;; rotated = rotl(bitsA_bits | 1, nb)
                (local.set $offs
                  (i32.or
                    (i32.shl (i32.or (local.get $bitsA_bits) (i32.const 1)) (local.get $nb))
                    (i32.shr_u (i32.or (local.get $bitsA_bits) (i32.const 1))
                      (i32.sub (i32.const 32) (local.get $nb)))))
                (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $nb)))
                ;; mask = (2 << nb) - 1
                (local.set $nb (i32.sub (i32.shl (i32.const 2) (local.get $nb)) (i32.const 1)))
                (local.set $bitsA_bits (i32.and (local.get $offs) (i32.xor (local.get $nb) (i32.const -1))))
                (local.set $offs
                  (i32.sub
                    (i32.add
                      (i32.shl (i32.and (local.get $offs) (local.get $nb)) (i32.const 4))
                      (i32.and (local.get $cmd) (i32.const 0xF)))
                    (i32.const 760)))
                ;; Refill A
                (block $rTA (loop $rTAL
                  (br_if $rTA (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
                  (br_if $rTA (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
                  (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
                    (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
                  (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
                  (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
                  (br $rTAL)))
              )
              (else
                ;; High offset range (cmd >= 0xF0) — simplified, may need full impl
                (local.set $nb (i32.add (i32.sub (local.get $cmd) (i32.const 0xF0)) (i32.const 4)))
                (local.set $offs
                  (i32.or
                    (i32.shl (i32.or (local.get $bitsA_bits) (i32.const 1)) (local.get $nb))
                    (i32.shr_u (i32.or (local.get $bitsA_bits) (i32.const 1))
                      (i32.sub (i32.const 32) (local.get $nb)))))
                (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $nb)))
                (local.set $nb (i32.sub (i32.shl (i32.const 2) (local.get $nb)) (i32.const 1)))
                (local.set $bitsA_bits (i32.and (local.get $offs) (i32.xor (local.get $nb) (i32.const -1))))
                (local.set $offs (i32.add (i32.const 16710912)
                  (i32.shl (i32.and (local.get $offs) (local.get $nb)) (i32.const 12))))
                ;; Refill A
                (block $rTA2 (loop $rTA2L
                  (br_if $rTA2 (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
                  (br_if $rTA2 (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
                  (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
                    (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
                  (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
                  (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
                  (br $rTA2L)))
                ;; Read 12 more bits for high offset
                (local.set $offs (i32.add (local.get $offs)
                  (i32.shr_u (local.get $bitsA_bits) (i32.const 20))))
                (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (i32.const 12)))
                (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (i32.const 12)))
                ;; Refill A
                (block $rTA3 (loop $rTA3L
                  (br_if $rTA3 (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
                  (br_if $rTA3 (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
                  (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
                    (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
                  (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
                  (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
                  (br $rTA3L)))
              )
            )
            (i32.store (i32.add (local.get $offsStream) (i32.shl (local.get $i) (i32.const 2)))
              (i32.sub (i32.const 0) (local.get $offs)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br_if $tradDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_OFFS_SIZE))))

            ;; Backward: ReadDistanceBackward from bitsB (same logic, different reader)
            (local.set $cmd (i32.load8_u (i32.add (local.get $packedOffsStream) (local.get $i))))
            (if (i32.lt_u (local.get $cmd) (i32.const 0xF0))
              (then
                (local.set $nb (i32.add (i32.shr_u (local.get $cmd) (i32.const 4)) (i32.const 5)))
                (local.set $offs
                  (i32.or
                    (i32.shl (i32.or (local.get $bitsB_bits) (i32.const 1)) (local.get $nb))
                    (i32.shr_u (i32.or (local.get $bitsB_bits) (i32.const 1))
                      (i32.sub (i32.const 32) (local.get $nb)))))
                (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $nb)))
                (local.set $nb (i32.sub (i32.shl (i32.const 2) (local.get $nb)) (i32.const 1)))
                (local.set $bitsB_bits (i32.and (local.get $offs) (i32.xor (local.get $nb) (i32.const -1))))
                (local.set $offs
                  (i32.sub
                    (i32.add
                      (i32.shl (i32.and (local.get $offs) (local.get $nb)) (i32.const 4))
                      (i32.and (local.get $cmd) (i32.const 0xF)))
                    (i32.const 760)))
                ;; Refill B
                (block $rTB (loop $rTBL
                  (br_if $rTB (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
                  (br_if $rTB (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
                  (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
                  (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
                    (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
                  (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
                  (br $rTBL)))
              )
              (else
                (local.set $nb (i32.add (i32.sub (local.get $cmd) (i32.const 0xF0)) (i32.const 4)))
                (local.set $offs
                  (i32.or
                    (i32.shl (i32.or (local.get $bitsB_bits) (i32.const 1)) (local.get $nb))
                    (i32.shr_u (i32.or (local.get $bitsB_bits) (i32.const 1))
                      (i32.sub (i32.const 32) (local.get $nb)))))
                (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $nb)))
                (local.set $nb (i32.sub (i32.shl (i32.const 2) (local.get $nb)) (i32.const 1)))
                (local.set $bitsB_bits (i32.and (local.get $offs) (i32.xor (local.get $nb) (i32.const -1))))
                (local.set $offs (i32.add (i32.const 16710912)
                  (i32.shl (i32.and (local.get $offs) (local.get $nb)) (i32.const 12))))
                ;; Refill B
                (block $rTB2 (loop $rTB2L
                  (br_if $rTB2 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
                  (br_if $rTB2 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
                  (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
                  (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
                    (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
                  (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
                  (br $rTB2L)))
                (local.set $offs (i32.add (local.get $offs)
                  (i32.shr_u (local.get $bitsB_bits) (i32.const 20))))
                (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (i32.const 12)))
                (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (i32.const 12)))
                ;; Refill B
                (block $rTB3 (loop $rTB3L
                  (br_if $rTB3 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
                  (br_if $rTB3 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
                  (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
                  (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
                    (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
                  (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
                  (br $rTB3L)))
              )
            )
            (i32.store (i32.add (local.get $offsStream) (i32.shl (local.get $i) (i32.const 2)))
              (i32.sub (i32.const 0) (local.get $offs)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $tradLoop)
          )
        )
      )
    )

    ;; DEBUG: dump base offsets and lowBits before scaling
    (if (i32.and (i32.ne (local.get $offsScaling) (i32.const 0))
                 (i32.ne (local.get $offsScaling) (i32.const 1)))
      (then
        ;; Store first 10 base offsets at 0xF0
        (i32.store (i32.const 0xF0) (i32.load (i32.add (global.get $HLZ_OFFS_BUF) (i32.const 0))))
        (i32.store (i32.const 0xF4) (i32.load (i32.add (global.get $HLZ_OFFS_BUF) (i32.const 4))))
        ;; Store first 10 lowBits at 0x100 -- wait, that's INPUT_BASE!
        ;; Use a safe address like 0x00229000
        (i32.store (i32.const 0x00229000) (i32.load8_u (local.get $lowBitsPtr)))
        (i32.store (i32.const 0x00229004) (i32.load8_u (i32.add (local.get $lowBitsPtr) (i32.const 1))))
        (i32.store (i32.const 0x00229008) (i32.load8_u (i32.add (local.get $lowBitsPtr) (i32.const 2))))
        (i32.store (i32.const 0x0022900C) (local.get $offsScaling))
      )
    )

    ;; Apply offset scaling: offsStream[i] = scale * offsStream[i] - lowBits[i]
    (if (i32.and (i32.ne (local.get $offsScaling) (i32.const 0))
                 (i32.ne (local.get $offsScaling) (i32.const 1)))
      (then
        (local.set $i (i32.const 0))
        (block $scaleDone
          (loop $scaleLoop
            (br_if $scaleDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_OFFS_SIZE))))
            (local.set $offs (i32.load (i32.add (global.get $HLZ_OFFS_BUF)
              (i32.shl (local.get $i) (i32.const 2)))))
            (i32.store (i32.add (global.get $HLZ_OFFS_BUF) (i32.shl (local.get $i) (i32.const 2)))
              (i32.sub
                (i32.mul (local.get $offsScaling) (local.get $offs))
                (i32.load8_u (i32.add (local.get $lowBitsPtr) (local.get $i)))))  ;; $lowBitsPtr = packedOffsStreamExtra
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $scaleLoop)
          )
        )
      )
    )

    ;; DEBUG: store bitsA/bitsB state at 0xD4..0xE3
    (i32.store (i32.const 0xD4) (local.get $bitsA_bits))
    (i32.store (i32.const 0xD8) (local.get $bitsA_bitpos))
    (i32.store (i32.const 0xDC) (local.get $bitsB_bits))
    (i32.store (i32.const 0xE0) (local.get $bitsB_bitpos))
    (i32.store (i32.const 0xE4) (local.get $u32LenStreamSize))

    ;; Unpack u32 length stream (alternating forward/backward ReadLength)
    ;; u32LenStream stored at 0x00228000 (up to 512 entries * 4 = 2048 bytes)
    (if (i32.or (i32.lt_s (local.get $u32LenStreamSize) (i32.const 0))
                (i32.gt_s (local.get $u32LenStreamSize) (i32.const 512)))
      (then (global.set $TRACE (i32.const -3012)) (return (i32.const -1)))
    )
    (local.set $i (i32.const 0))
    (block $u32Done
      (loop $u32Loop
        (br_if $u32Done (i32.ge_u (i32.add (local.get $i) (i32.const 1))
                                   (local.get $u32LenStreamSize)))
        ;; Forward: ReadLength from bitsA
        ;; leadingZeros = clz(bitsA_bits)
        (local.set $bytesRead (i32.clz (local.get $bitsA_bits)))
        (if (i32.gt_s (local.get $bytesRead) (i32.const 12)) (then (global.set $TRACE (i32.const -3013)) (return (i32.const -1))))
        (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $bytesRead)))
        (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (local.get $bytesRead)))
        ;; Refill A
        (block $rLA (loop $rLAL
          (br_if $rLA (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
          (br_if $rLA (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
          (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
            (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
          (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
          (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
          (br $rLAL)))
        ;; totalBits = leadingZeros + 7
        (local.set $nb (i32.add (local.get $bytesRead) (i32.const 7)))
        (i32.store (i32.add (i32.const 0x00228000) (i32.shl (local.get $i) (i32.const 2)))
          (i32.sub (i32.shr_u (local.get $bitsA_bits) (i32.sub (i32.const 32) (local.get $nb))) (i32.const 64)))
        (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $nb)))
        (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (local.get $nb)))
        ;; Refill A
        (block $rLA2 (loop $rLA2L
          (br_if $rLA2 (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
          (br_if $rLA2 (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
          (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
            (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
          (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
          (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
          (br $rLA2L)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))

        ;; Backward: ReadLengthBackward from bitsB
        (br_if $u32Done (i32.ge_u (local.get $i) (local.get $u32LenStreamSize)))
        (local.set $bytesRead (i32.clz (local.get $bitsB_bits)))
        (if (i32.gt_s (local.get $bytesRead) (i32.const 12)) (then (global.set $TRACE (i32.const -3014)) (return (i32.const -1))))
        (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $bytesRead)))
        (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (local.get $bytesRead)))
        ;; Refill B
        (block $rLB (loop $rLBL
          (br_if $rLB (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
          (br_if $rLB (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
          (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
          (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
            (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
          (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
          (br $rLBL)))
        (local.set $nb (i32.add (local.get $bytesRead) (i32.const 7)))
        (i32.store (i32.add (i32.const 0x00228000) (i32.shl (local.get $i) (i32.const 2)))
          (i32.sub (i32.shr_u (local.get $bitsB_bits) (i32.sub (i32.const 32) (local.get $nb))) (i32.const 64)))
        (local.set $bitsB_bitpos (i32.add (local.get $bitsB_bitpos) (local.get $nb)))
        (local.set $bitsB_bits (i32.shl (local.get $bitsB_bits) (local.get $nb)))
        ;; Refill B
        (block $rLB2 (loop $rLB2L
          (br_if $rLB2 (i32.le_s (local.get $bitsB_bitpos) (i32.const 0)))
          (br_if $rLB2 (i32.le_u (local.get $bitsB_p) (local.get $bitsB_pEnd)))
          (local.set $bitsB_p (i32.sub (local.get $bitsB_p) (i32.const 1)))
          (local.set $bitsB_bits (i32.or (local.get $bitsB_bits)
            (i32.shl (i32.load8_u (local.get $bitsB_p)) (local.get $bitsB_bitpos))))
          (local.set $bitsB_bitpos (i32.sub (local.get $bitsB_bitpos) (i32.const 8)))
          (br $rLB2L)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $u32Loop)
      )
    )
    ;; Handle odd count
    (if (i32.lt_u (local.get $i) (local.get $u32LenStreamSize))
      (then
        (local.set $bytesRead (i32.clz (local.get $bitsA_bits)))
        (if (i32.gt_s (local.get $bytesRead) (i32.const 12)) (then (global.set $TRACE (i32.const -3015)) (return (i32.const -1))))
        (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $bytesRead)))
        (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (local.get $bytesRead)))
        (block $rLAO (loop $rLAOL
          (br_if $rLAO (i32.le_s (local.get $bitsA_bitpos) (i32.const 0)))
          (br_if $rLAO (i32.ge_u (local.get $bitsA_p) (local.get $bitsA_pEnd)))
          (local.set $bitsA_bits (i32.or (local.get $bitsA_bits)
            (i32.shl (i32.load8_u (local.get $bitsA_p)) (local.get $bitsA_bitpos))))
          (local.set $bitsA_bitpos (i32.sub (local.get $bitsA_bitpos) (i32.const 8)))
          (local.set $bitsA_p (i32.add (local.get $bitsA_p) (i32.const 1)))
          (br $rLAOL)))
        (local.set $nb (i32.add (local.get $bytesRead) (i32.const 7)))
        (i32.store (i32.add (i32.const 0x00228000) (i32.shl (local.get $i) (i32.const 2)))
          (i32.sub (i32.shr_u (local.get $bitsA_bits) (i32.sub (i32.const 32) (local.get $nb))) (i32.const 64)))
        (local.set $bitsA_bitpos (i32.add (local.get $bitsA_bitpos) (local.get $nb)))
        (local.set $bitsA_bits (i32.shl (local.get $bitsA_bits) (local.get $nb)))
      )
    )

    ;; Unpack packed litlen stream: values < 255 direct, 255 = overflow from u32 stream
    (local.set $lenStream (global.get $HLZ_LEN_BUF))
    (local.set $lowBitsPtr (i32.const 0))  ;; u32LenStream index
    (local.set $i (i32.const 0))
    (block $lenDone
      (loop $lenLoop
        (br_if $lenDone (i32.ge_u (local.get $i) (i32.load (global.get $HLZ_LEN_SIZE))))
        (local.set $nb (i32.load8_u (i32.add (local.get $packedLenStream) (local.get $i))))
        (if (i32.eq (local.get $nb) (i32.const 255))
          (then
            ;; Overflow: read from u32LenStream
            (local.set $nb (i32.add (local.get $nb)
              (i32.load (i32.add (i32.const 0x00228000) (i32.shl (local.get $lowBitsPtr) (i32.const 2))))))
            (local.set $lowBitsPtr (i32.add (local.get $lowBitsPtr) (i32.const 1)))
          )
        )
        (i32.store (i32.add (local.get $lenStream) (i32.shl (local.get $i) (i32.const 2)))
          (i32.add (local.get $nb) (i32.const 3)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lenLoop)
      )
    )

    ;; ── ResolveTokens ──
    ;; Command byte: [offsIndex:2][matchLen:4][litLen:2]
    (local.set $cmdStream (i32.load (global.get $HLZ_CMD)))
    (local.set $cmdStreamEnd (i32.add (local.get $cmdStream) (i32.load (global.get $HLZ_CMD_SIZE))))
    (local.set $lenStream (global.get $HLZ_LEN_BUF))
    (local.set $offsStream (global.get $HLZ_OFFS_BUF))

    ;; Recent offsets carousel
    (local.set $recent3 (i32.const -8))
    (local.set $recent4 (i32.const -8))
    (local.set $recent5 (i32.const -8))
    ;; For delta mode: track the PREVIOUS token's offset for literal delta
    ;; (stored at 0xD4 as "lastOffset")
    (i32.store (i32.const 0xD4) (i32.const -8))

    (local.set $dstPos (i32.const 0))
    (local.set $tokenCount (i32.const 0))
    (local.set $litStream (i32.load (global.get $HLZ_LIT)))

    ;; Combined resolve + execute (simpler than two-phase for WASM)
    ;; Skip token array — just execute directly inline
    (local.set $remaining (local.get $dstCount))
    (if (i32.eqz (local.get $offset))
      (then
        ;; Account for initial 8 literal bytes
        (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
        (local.set $remaining (i32.sub (local.get $remaining) (i32.const 8)))
      )
    )

    (block $execDone
      (loop $execLoop
        (br_if $execDone (i32.ge_u (local.get $cmdStream) (local.get $cmdStreamEnd)))

        (local.set $cmd (i32.load8_u (local.get $cmdStream)))
        (local.set $cmdStream (i32.add (local.get $cmdStream) (i32.const 1)))

        ;; litLen = cmd & 3
        (local.set $litLen (i32.and (local.get $cmd) (i32.const 3)))
        ;; matchLen = (cmd >> 2) & 0xF
        (local.set $matchLen (i32.and (i32.shr_u (local.get $cmd) (i32.const 2)) (i32.const 0xF)))
        ;; offIdx = cmd >> 6
        (local.set $offIdx (i32.shr_u (local.get $cmd) (i32.const 6)))

        ;; Resolve literal length (3 = read from length stream)
        (if (i32.eq (local.get $litLen) (i32.const 3))
          (then
            (local.set $litLen (i32.load (local.get $lenStream)))
            (local.set $lenStream (i32.add (local.get $lenStream) (i32.const 4)))
          )
        )

        ;; Resolve offset from carousel
        ;; offIdx 0 = recent3 (MRU), 1 = recent4, 2 = recent5, 3 = new from stream
        (if (i32.eq (local.get $offIdx) (i32.const 0))
          (then (local.set $tokOffset (local.get $recent3)))
        )
        (if (i32.eq (local.get $offIdx) (i32.const 1))
          (then
            (local.set $tokOffset (local.get $recent4))
            ;; Rotate: 4→temp, 3→4
            (local.set $recent4 (local.get $recent3))
            (local.set $recent3 (local.get $tokOffset))
          )
        )
        (if (i32.eq (local.get $offIdx) (i32.const 2))
          (then
            (local.set $tokOffset (local.get $recent5))
            (local.set $recent5 (local.get $recent4))
            (local.set $recent4 (local.get $recent3))
            (local.set $recent3 (local.get $tokOffset))
          )
        )
        (if (i32.eq (local.get $offIdx) (i32.const 3))
          (then
            (local.set $tokOffset (i32.load (local.get $offsStream)))
            (local.set $offsStream (i32.add (local.get $offsStream) (i32.const 4)))
            (local.set $recent5 (local.get $recent4))
            (local.set $recent4 (local.get $recent3))
            (local.set $recent3 (local.get $tokOffset))
          )
        )

        ;; Resolve match length (15 = read from length stream + 14)
        (if (i32.eq (local.get $matchLen) (i32.const 15))
          (then
            (local.set $matchLen (i32.add (i32.const 14) (i32.load (local.get $lenStream))))
            (local.set $lenStream (i32.add (local.get $lenStream) (i32.const 4)))
          )
          (else
            (local.set $matchLen (i32.add (local.get $matchLen) (i32.const 2)))
          )
        )

        ;; Bounds check: ensure dst + litLen + matchLen <= dstEnd
        (if (i32.gt_u
              (i32.add (local.get $dst) (i32.add (local.get $litLen) (local.get $matchLen)))
              (i32.add (local.get $dstStart) (i32.add (local.get $offset) (local.get $dstCount))))
          (then (global.set $TRACE (i32.const -3020)) (return (i32.const -1)))
        )

        ;; ── Execute: copy literals ──
        (if (i32.eq (local.get $mode) (i32.const 1))
          (then
            ;; Raw literals — SIMD wildcopy (faster than memory.copy for small litLen 0-3)
            (call $wildcopy16 (local.get $dst) (local.get $litStream)
              (i32.add (local.get $dst) (local.get $litLen)))
          )
          (else
            ;; Delta literals (mode 0) — add byte at PREVIOUS match offset
            (local.set $i (i32.const 0))
            (block $litDDone
              (loop $litDLoop
                (br_if $litDDone (i32.ge_u (local.get $i) (local.get $litLen)))
                (i32.store8 (i32.add (local.get $dst) (local.get $i))
                  (i32.add
                    (i32.load8_u (i32.add (local.get $litStream) (local.get $i)))
                    (i32.load8_u (i32.add (i32.add (local.get $dst) (local.get $i))
                      (i32.load (i32.const 0xD4))))))  ;; lastOffset from PREVIOUS token
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $litDLoop)
              )
            )
          )
        )
        (local.set $dst (i32.add (local.get $dst) (local.get $litLen)))
        (local.set $litStream (i32.add (local.get $litStream) (local.get $litLen)))

        ;; ── Execute: copy match ──
        (local.set $match (i32.add (local.get $dst) (local.get $tokOffset)))
        ;; Validate match source is within output buffer
        (if (i32.lt_u (local.get $match) (local.get $dstStart))
          (then (global.set $TRACE (i32.const -3021)) (return (i32.const -1)))
        )
        (call $match_copy (local.get $dst) (local.get $match) (local.get $matchLen))
        (local.set $dst (i32.add (local.get $dst) (local.get $matchLen)))

        ;; Save current offset as lastOffset for delta mode's next literal
        (i32.store (i32.const 0xD4) (local.get $tokOffset))

        (br $execLoop)
      )
    )

    ;; Copy trailing literals (raw for mode 1, delta for mode 0)
    (local.set $remaining (i32.sub
      (i32.add (local.get $dstStart) (i32.add (local.get $offset) (local.get $dstCount)))
      (local.get $dst)))
    (if (i32.eq (local.get $mode) (i32.const 1))
      (then
        ;; Raw trailing literals: bulk copy via memory.copy
        (memory.copy (local.get $dst) (local.get $litStream) (local.get $remaining))
        (local.set $dst (i32.add (local.get $dst) (local.get $remaining)))
        (local.set $litStream (i32.add (local.get $litStream) (local.get $remaining)))
      )
      (else
        ;; Delta trailing literals
        (block $trailDDone
          (loop $trailDLoop
            (br_if $trailDDone (i32.le_s (local.get $remaining) (i32.const 0)))
            (i32.store8 (local.get $dst)
              (i32.add
                (i32.load8_u (local.get $litStream))
                (i32.load8_u (i32.add (local.get $dst) (i32.load (i32.const 0xD4))))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $litStream (i32.add (local.get $litStream) (i32.const 1)))
            (local.set $remaining (i32.sub (local.get $remaining) (i32.const 1)))
            (br $trailDLoop)
          )
        )
      )
    )

    (i32.const 0)
  )
