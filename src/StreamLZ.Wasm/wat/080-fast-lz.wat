  ;; ── 080-fast-lz: Fast codec decoder (L1-L5) ────────────────
  ;; Functions: $fast_decode_chunk, $process_lz_runs, $process_mode
  ;; FastLzTable at 0x60-0x98 (stream pointers)
  ;; State: savedDist at 0x9C (persisted across 64KB iterations)
  ;; Scratch: DECODE_SCRATCH at 0x101100, OFF32_SCRATCH at 0x141100
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
  ;; SCRATCH_BASE (0x00101100) is used:
  ;;   +0x0000 .. +0x3FFFF: decoded literal/command streams (256KB)
  ;;   +0x40000 .. +0x5FFFF: off32 backing stores (128KB)
  ;; This is enough for chunks up to 128KB decompressed.

  (global $DECODE_SCRATCH i32 (i32.const 0x00101100))
  (global $OFF32_SCRATCH  i32 (i32.const 0x00141100))

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
      (then (global.set $TRACE (i32.const -1001)) (return (i32.const -1)))
    )
    (if (i32.or (i32.le_s (local.get $dstCount) (i32.const 0))
                (i32.le_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 0)))
      (then (global.set $TRACE (i32.const -1002)) (return (i32.const -1)))
    )

    (local.set $offset (i64.extend_i32_u (i32.sub (local.get $dst) (local.get $dstStart))))
    (local.set $scratch (global.get $DECODE_SCRATCH))
    (local.set $scratchCur (local.get $scratch))

    ;; If offset == 0, copy first 8 literal bytes directly to dst
    ;; (dst pointer is NOT advanced — ProcessLzRuns uses startOff=8 to skip them)
    (if (i64.eqz (local.get $offset))
      (then
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 8))
          (then (global.set $TRACE (i32.const -1003)) (return (i32.const -1)))
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
      (then (global.set $TRACE (i32.const -1001)) (global.set $TRACE (i32.const -1004)) (return (i32.const -1)))
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
      (then (global.set $TRACE (i32.const -1005)) (return (i32.const -1)))
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
          (then (global.set $TRACE (i32.const -1006)) (return (i32.const -1)))
        )
        (i32.store (global.get $LZ_CMD2_OFF)
          (i32.load16_u (local.get $src)))
        (local.set $src (i32.add (local.get $src) (i32.const 2)))
        ;; Validate cmd2Offset <= cmd2OffsetEnd
        (if (i32.gt_u (i32.load (global.get $LZ_CMD2_OFF))
                       (i32.load (global.get $LZ_CMD2_END)))
          (then (global.set $TRACE (i32.const -1007)) (return (i32.const -1)))
        )
      )
    )

    ;; ── Decode off16 stream ──
    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
      (then (global.set $TRACE (i32.const -1008)) (return (i32.const -1)))
    )
    (local.set $off16Count (i32.load16_u (local.get $src)))

    (if (i32.eq (local.get $off16Count) (i32.const 0xFFFF))
      (then
        ;; Entropy-coded off16: decode hi and lo halves
        (local.set $src (i32.add (local.get $src) (i32.const 2)))
        ;; TODO: implement entropy-coded off16
        ;; For now, return error
        (global.set $TRACE (i32.const -1009)) (return (i32.const -1))
      )
      (else
        ;; Raw off16: directly in source
        (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src))
              (i32.add (i32.const 2) (i32.shl (local.get $off16Count) (i32.const 1))))
          (then (global.set $TRACE (i32.const -1010)) (return (i32.const -1)))
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
      (then (global.set $TRACE (i32.const -1011)) (return (i32.const -1)))
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
              (then (global.set $TRACE (i32.const -1012)) (return (i32.const -1)))
            )
            (local.set $off32Size1 (i32.load16_u (local.get $src)))
            (local.set $src (i32.add (local.get $src) (i32.const 2)))
          )
        )
        ;; Extended size for off32Size2
        (if (i32.eq (local.get $off32Size2) (i32.const 4095))
          (then
            (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 2))
              (then (global.set $TRACE (i32.const -1013)) (return (i32.const -1)))
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
          (then (global.set $TRACE (i32.const -1014)) (return (i32.const -1)))
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
          (then (global.set $TRACE (i32.const -1015)) (return (i32.const -1)))
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

    ;; (debug traces removed)
    (i32.store (i32.const 0xA4)
      (i32.sub (i32.load (global.get $LZ_CMD_END)) (i32.load (global.get $LZ_CMD_START))))
    (i32.store (i32.const 0xA8)
      (i32.shr_u
        (i32.sub (i32.load (global.get $LZ_OFF16_END)) (i32.load (global.get $LZ_OFF16_START)))
        (i32.const 1)))

    ;; Length stream = remaining source
    (i32.store (global.get $LZ_LEN_STREAM) (local.get $src))

    ;; DBG: 6 = about to process LZ runs


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

        ;; ── cmd >= 24: Short token (with fast-path loop) ──
        (if (i32.ge_u (local.get $cmd) (i32.const 24))
          (then (block $shortToken (loop $shortLoop
            ;; Bounds check
            (if (i32.ge_u (local.get $dstCur) (local.get $dstEnd))
              (then (return (i32.const -1)))
            )

            ;; litLen = cmd & 7 (cmd is set by main loop or by fast-path peek)
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
                ;; Raw: unconditional 16-byte SIMD copy (litLen 0-7, no overlap)
                (call $copy128 (local.get $dstCur) (local.get $litStream))
                (local.set $dstCur (i32.add (local.get $dstCur) (local.get $litLen)))
                (local.set $litStream (i32.add (local.get $litStream) (local.get $litLen)))
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

            ;; Match copy: matchLen = (cmd >> 3) & 0xF (max 15 bytes)
            (local.set $matchLen (i32.and (i32.shr_u (local.get $cmd) (i32.const 3)) (i32.const 0xF)))
            (local.set $match (i32.add (local.get $dstCur) (local.get $recentOffs)))
            ;; Validate match source is within output buffer
            (if (i32.lt_u (local.get $match) (local.get $dstStart))
              (then (return (i32.const -1)))
            )
            ;; Use SIMD only if offset >= 16 (no overlap)
            (if (i32.ge_u (i32.sub (i32.const 0) (local.get $recentOffs)) (i32.const 16))
              (then (call $copy128 (local.get $dstCur) (local.get $match)))
              (else
                (call $copy64 (local.get $dstCur) (local.get $match))
                (call $copy64 (i32.add (local.get $dstCur) (i32.const 8))
                              (i32.add (local.get $match) (i32.const 8)))
              )
            )
            (local.set $dstCur (i32.add (local.get $dstCur) (local.get $matchLen)))

            ;; Fast-path: peek next cmd; if also short token, read and loop
            (br_if $shortToken (i32.ge_u (local.get $cmdStream) (local.get $cmdStreamEnd)))
            (if (i32.ge_u (i32.load8_u (local.get $cmdStream)) (i32.const 24))
              (then
                (local.set $cmd (i32.load8_u (local.get $cmdStream)))
                (local.set $cmdStream (i32.add (local.get $cmdStream) (i32.const 1)))
                (br $shortLoop)
              )
            )
          ))
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
            (if (i32.lt_u (local.get $match) (local.get $dstStart))
              (then (return (i32.const -1)))
            )
            (local.set $recentOffs (i32.sub (local.get $match) (local.get $dstCur)))

            (if (i32.lt_s (i32.sub (local.get $dstEnd) (local.get $dstCur)) (local.get $length))
              (then (return (i32.const -1)))
            )

            ;; Copy match (up to 32 bytes)
            (if (i32.ge_u (i32.sub (local.get $dstCur) (local.get $match)) (i32.const 16))
              (then
                (call $copy128 (local.get $dstCur) (local.get $match))
                (call $copy128 (i32.add (local.get $dstCur) (i32.const 16))
                               (i32.add (local.get $match) (i32.const 16)))
              )
              (else
                (call $copy64 (local.get $dstCur) (local.get $match))
                (call $copy64 (i32.add (local.get $dstCur) (i32.const 8)) (i32.add (local.get $match) (i32.const 8)))
                (call $copy64 (i32.add (local.get $dstCur) (i32.const 16)) (i32.add (local.get $match) (i32.const 16)))
                (call $copy64 (i32.add (local.get $dstCur) (i32.const 24)) (i32.add (local.get $match) (i32.const 24)))
              )
            )
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
                ;; Raw long literal: bulk copy via memory.copy
                (memory.copy (local.get $dstCur) (local.get $litStream) (local.get $length))
                (local.set $dstCur (i32.add (local.get $dstCur) (local.get $length)))
                (local.set $litStream (i32.add (local.get $litStream) (local.get $length)))
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

            (call $match_copy (local.get $dstCur) (local.get $match) (local.get $length))
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
        (if (i32.lt_u (local.get $match) (local.get $dstStart))
          (then (return (i32.const -1)))
        )
        (if (i32.lt_s (i32.sub (local.get $dstEnd) (local.get $dstCur)) (local.get $length))
          (then (return (i32.const -1)))
        )
        (local.set $recentOffs (i32.sub (local.get $match) (local.get $dstCur)))

        (call $match_copy (local.get $dstCur) (local.get $match) (local.get $length))
        (local.set $dstCur (i32.add (local.get $dstCur) (local.get $length)))
        (br $cmdLoop)
      )
    )

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
        ;; Raw trailing literals: bulk copy via memory.copy
        (memory.copy (local.get $dstCur) (local.get $litStream) (local.get $remaining))
        (local.set $dstCur (i32.add (local.get $dstCur) (local.get $remaining)))
        (local.set $litStream (i32.add (local.get $litStream) (local.get $remaining)))
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

