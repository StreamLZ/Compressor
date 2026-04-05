  ;; ============================================================
  ;; tANS Decoder
  ;; ============================================================
  ;;
  ;; Memory layout (at 0x00210000+):
  ;;   +0x0000: TansData.AUsed (4), BUsed (4), A[256] (256), B[256] (1024) = 1288 bytes
  ;;   +0x0508: reserved
  ;;   +0x0600: TansLut (up to 4096 * 8 = 32768 bytes for logTableBits=12)
  ;;   +0x8600: seen array (256 bytes)

  (global $TANS_DATA   i32 (i32.const 0x00210000))
  (global $TANS_AUSED  i32 (i32.const 0x00210000))
  (global $TANS_BUSED  i32 (i32.const 0x00210004))
  (global $TANS_A      i32 (i32.const 0x00210008))
  (global $TANS_B      i32 (i32.const 0x00210108))
  (global $TANS_LUT    i32 (i32.const 0x00210600))
  (global $TANS_SEEN   i32 (i32.const 0x00218600))

  ;; TansLutEnt: { X:u32, BitsX:u8, Symbol:u8, W:u16 } = 8 bytes
  ;; Stored as: [0-3]=X, [4]=BitsX, [5]=Symbol, [6-7]=W

  ;; ── tans_decode_table_sparse ───────────────────────────────
  ;; Decode tANS frequency table (sparse/explicit format).
  ;; Uses BR at 0x30 as bit reader.
  ;; Returns 1 on success, 0 on failure.
  (func $tans_decode_table_sparse (param $logTableBits i32) (result i32)
    (local $L i32)
    (local $count i32)
    (local $bitsPerSym i32)
    (local $maxDeltaBits i32)
    (local $weight i32)
    (local $totalWeights i32)
    (local $sym i32)
    (local $delta i32)
    (local $aPtr i32)
    (local $bPtr i32)
    (local $lastSym i32)
    (local $remaining i32)

    (local.set $L (i32.shl (i32.const 1) (local.get $logTableBits)))

    ;; Clear seen array
    (memory.fill (global.get $TANS_SEEN) (i32.const 0) (i32.const 256))

    (local.set $count (i32.add (call $br_read_bits_no_refill (i32.const 3)) (i32.const 1)))

    ;; bitsPerSym = log2(logTableBits) + 1
    (local.set $bitsPerSym
      (i32.add
        (i32.sub (i32.const 31) (i32.clz (local.get $logTableBits)))
        (i32.const 1)))

    (local.set $maxDeltaBits (call $br_read_bits_no_refill (local.get $bitsPerSym)))
    (if (i32.or (i32.eqz (local.get $maxDeltaBits))
                (i32.gt_u (local.get $maxDeltaBits) (local.get $logTableBits)))
      (then (return (i32.const 0)))
    )

    (local.set $aPtr (global.get $TANS_A))
    (local.set $bPtr (global.get $TANS_B))
    (local.set $weight (i32.const 0))
    (local.set $totalWeights (i32.const 0))

    ;; Read count symbol+delta pairs
    (block $done
      (loop $loop
        (br_if $done (i32.le_s (local.get $count) (i32.const 0)))

        (call $br_refill)
        (local.set $sym (call $br_read_bits_no_refill (i32.const 8)))

        ;; Check not seen
        (if (i32.load8_u (i32.add (global.get $TANS_SEEN) (local.get $sym)))
          (then (return (i32.const 0)))
        )

        (local.set $delta (call $br_read_bits_no_refill (local.get $maxDeltaBits)))
        (local.set $weight (i32.add (local.get $weight) (local.get $delta)))
        (if (i32.eqz (local.get $weight))
          (then (return (i32.const 0)))
        )

        (i32.store8 (i32.add (global.get $TANS_SEEN) (local.get $sym)) (i32.const 1))

        (if (i32.eq (local.get $weight) (i32.const 1))
          (then
            ;; A entry (weight=1 symbol)
            (i32.store8 (local.get $aPtr) (local.get $sym))
            (local.set $aPtr (i32.add (local.get $aPtr) (i32.const 1)))
          )
          (else
            ;; B entry (symbol << 16 | weight)
            (i32.store (local.get $bPtr)
              (i32.add (i32.shl (local.get $sym) (i32.const 16)) (local.get $weight)))
            (local.set $bPtr (i32.add (local.get $bPtr) (i32.const 4)))
          )
        )

        (local.set $totalWeights (i32.add (local.get $totalWeights) (local.get $weight)))
        (local.set $count (i32.sub (local.get $count) (i32.const 1)))
        (br $loop)
      )
    )

    ;; Read last symbol
    (call $br_refill)
    (local.set $lastSym (call $br_read_bits_no_refill (i32.const 8)))
    (if (i32.load8_u (i32.add (global.get $TANS_SEEN) (local.get $lastSym)))
      (then (return (i32.const 0)))
    )

    ;; Validate: L - totalWeights must be > 1 and >= weight
    (local.set $remaining (i32.sub (local.get $L) (local.get $totalWeights)))
    (if (i32.or
          (i32.lt_s (local.get $remaining) (local.get $weight))
          (i32.le_s (local.get $remaining) (i32.const 1)))
      (then (return (i32.const 0)))
    )

    ;; Add last symbol as B entry with remaining weight
    (i32.store (local.get $bPtr)
      (i32.add (i32.shl (local.get $lastSym) (i32.const 16)) (local.get $remaining)))
    (local.set $bPtr (i32.add (local.get $bPtr) (i32.const 4)))

    ;; Store AUsed and BUsed
    (i32.store (global.get $TANS_AUSED)
      (i32.shr_u (i32.sub (local.get $aPtr) (global.get $TANS_A)) (i32.const 0)))
    (i32.store (global.get $TANS_BUSED)
      (i32.shr_u (i32.sub (local.get $bPtr) (global.get $TANS_B)) (i32.const 2)))

    ;; Sort A array (insertion sort on bytes)
    (call $sort_bytes (global.get $TANS_A) (local.get $aPtr))
    ;; Sort B array (insertion sort on uint32s)
    (call $sort_u32s (global.get $TANS_B) (local.get $bPtr))

    (i32.const 1)
  )

  ;; ── sort_bytes ─────────────────────────────────────────────
  ;; Insertion sort on a byte array [start, end).
  (func $sort_bytes (param $start i32) (param $end i32)
    (local $i i32) (local $j i32) (local $key i32) (local $len i32)
    (local.set $len (i32.sub (local.get $end) (local.get $start)))
    (if (i32.le_s (local.get $len) (i32.const 1)) (then (return)))
    (local.set $i (i32.const 1))
    (block $done
      (loop $outer
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $key (i32.load8_u (i32.add (local.get $start) (local.get $i))))
        (local.set $j (local.get $i))
        (block $innerDone
          (loop $inner
            (br_if $innerDone (i32.eqz (local.get $j)))
            (br_if $innerDone
              (i32.le_u
                (i32.load8_u (i32.add (local.get $start) (i32.sub (local.get $j) (i32.const 1))))
                (local.get $key)))
            (i32.store8 (i32.add (local.get $start) (local.get $j))
              (i32.load8_u (i32.add (local.get $start) (i32.sub (local.get $j) (i32.const 1)))))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $inner)
          )
        )
        (i32.store8 (i32.add (local.get $start) (local.get $j)) (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $outer)
      )
    )
  )

  ;; ── sort_u32s ──────────────────────────────────────────────
  ;; Insertion sort on a uint32 array [start, end) where end is byte address.
  (func $sort_u32s (param $start i32) (param $end i32)
    (local $i i32) (local $j i32) (local $key i32) (local $count i32)
    (local.set $count (i32.shr_u (i32.sub (local.get $end) (local.get $start)) (i32.const 2)))
    (if (i32.le_s (local.get $count) (i32.const 1)) (then (return)))
    (local.set $i (i32.const 1))
    (block $done
      (loop $outer
        (br_if $done (i32.ge_u (local.get $i) (local.get $count)))
        (local.set $key (i32.load (i32.add (local.get $start) (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $j (local.get $i))
        (block $innerDone
          (loop $inner
            (br_if $innerDone (i32.eqz (local.get $j)))
            (br_if $innerDone
              (i32.le_u
                (i32.load (i32.add (local.get $start) (i32.shl (i32.sub (local.get $j) (i32.const 1)) (i32.const 2))))
                (local.get $key)))
            (i32.store (i32.add (local.get $start) (i32.shl (local.get $j) (i32.const 2)))
              (i32.load (i32.add (local.get $start) (i32.shl (i32.sub (local.get $j) (i32.const 1)) (i32.const 2)))))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $inner)
          )
        )
        (i32.store (i32.add (local.get $start) (i32.shl (local.get $j) (i32.const 2))) (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $outer)
      )
    )
  )

  ;; ── tans_init_lut ──────────────────────────────────────────
  ;; Build tANS decode LUT from TansData.
  ;; Returns 1 on success, 0 on failure.
  (func $tans_init_lut (param $logTableBits i32) (result i32)
    (local $L i32)
    (local $aUsed i32)
    (local $slotsLeft i32)
    (local $sa i32)
    (local $ptr0 i32) (local $ptr1 i32) (local $ptr2 i32) (local $ptr3 i32)
    (local $sb i32)
    (local $i i32)
    (local $lutBase i32)
    (local $lutEnd i32)
    (local $weight i32)
    (local $symbol i32)
    (local $weightsSum i32)
    (local $symBits i32)
    (local $bitsPerSym i32)
    (local $whatToAdd i32)
    (local $upperSlotCount i32)
    (local $qw i32)
    (local $dst i32)
    (local $j i32)
    (local $n i32)
    (local $ww i32)
    (local $bitsVal i32)
    (local $idx i32)
    (local $le_X i32) (local $le_BitsX i32) (local $le_W i32)

    (local.set $L (i32.shl (i32.const 1) (local.get $logTableBits)))
    (local.set $lutBase (global.get $TANS_LUT))
    (local.set $lutEnd (i32.add (local.get $lutBase) (i32.shl (local.get $L) (i32.const 3))))
    (local.set $aUsed (i32.load (global.get $TANS_AUSED)))
    (local.set $slotsLeft (i32.sub (local.get $L) (local.get $aUsed)))

    ;; Compute 4-way interleaved pointers
    (local.set $sa (i32.shr_u (local.get $slotsLeft) (i32.const 2)))
    (local.set $ptr0 (local.get $lutBase))

    (local.set $sb (i32.add (local.get $sa)
      (i32.gt_u (i32.and (local.get $slotsLeft) (i32.const 3)) (i32.const 0))))
    (local.set $ptr1 (i32.add (local.get $lutBase) (i32.shl (local.get $sb) (i32.const 3))))

    (local.set $sb (i32.add (local.get $sb)
      (i32.add (local.get $sa)
        (i32.gt_u (i32.and (local.get $slotsLeft) (i32.const 3)) (i32.const 1)))))
    (local.set $ptr2 (i32.add (local.get $lutBase) (i32.shl (local.get $sb) (i32.const 3))))

    (local.set $sb (i32.add (local.get $sb)
      (i32.add (local.get $sa)
        (i32.gt_u (i32.and (local.get $slotsLeft) (i32.const 3)) (i32.const 2)))))
    (local.set $ptr3 (i32.add (local.get $lutBase) (i32.shl (local.get $sb) (i32.const 3))))

    ;; Setup singles (weight=1) at offset slotsLeft
    (local.set $i (i32.const 0))
    (local.set $dst (i32.add (local.get $lutBase) (i32.shl (local.get $slotsLeft) (i32.const 3))))
    (local.set $le_X (i32.sub (local.get $L) (i32.const 1)))
    (block $singDone
      (loop $singLoop
        (br_if $singDone (i32.ge_u (local.get $i) (local.get $aUsed)))
        ;; TansLutEnt: X=L-1, BitsX=logTableBits, Symbol=A[i], W=0
        (i32.store (local.get $dst) (local.get $le_X))
        (i32.store8 (i32.add (local.get $dst) (i32.const 4)) (local.get $logTableBits))
        (i32.store8 (i32.add (local.get $dst) (i32.const 5))
          (i32.load8_u (i32.add (global.get $TANS_A) (local.get $i))))
        (i32.store16 (i32.add (local.get $dst) (i32.const 6)) (i32.const 0))
        (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $singLoop)
      )
    )

    ;; Setup multi-weight entries
    (local.set $weightsSum (i32.const 0))
    (local.set $i (i32.const 0))
    (block $multiDone
      (loop $multiLoop
        (br_if $multiDone (i32.ge_u (local.get $i) (i32.load (global.get $TANS_BUSED))))

        (local.set $weight
          (i32.and (i32.load (i32.add (global.get $TANS_B) (i32.shl (local.get $i) (i32.const 2))))
            (i32.const 0xFFFF)))
        (local.set $symbol
          (i32.shr_u (i32.load (i32.add (global.get $TANS_B) (i32.shl (local.get $i) (i32.const 2))))
            (i32.const 16)))

        (if (i32.gt_s (local.get $weight) (i32.const 4))
          (then
            ;; Weight > 4: use log2-based distribution
            (local.set $symBits (i32.sub (i32.const 31) (i32.clz (local.get $weight))))
            (local.set $bitsPerSym (i32.sub (local.get $logTableBits) (local.get $symBits)))
            (local.set $le_X (i32.sub (i32.shl (i32.const 1) (local.get $bitsPerSym)) (i32.const 1)))
            (local.set $le_W
              (i32.and (i32.sub (local.get $L) (i32.const 1))
                (i32.shl (local.get $weight) (local.get $bitsPerSym))))
            (local.set $whatToAdd (i32.shl (i32.const 1) (local.get $bitsPerSym)))
            (local.set $upperSlotCount
              (i32.sub (i32.shl (i32.const 1) (i32.add (local.get $symBits) (i32.const 1)))
                (local.get $weight)))

            ;; Distribute across 4 lanes
            (local.set $j (i32.const 0))
            (block $laneDone
              (loop $laneLoop
                (br_if $laneDone (i32.ge_u (local.get $j) (i32.const 4)))

                ;; Select pointer for this lane
                (if (i32.eqz (local.get $j)) (then (local.set $dst (local.get $ptr0))))
                (if (i32.eq (local.get $j) (i32.const 1)) (then (local.set $dst (local.get $ptr1))))
                (if (i32.eq (local.get $j) (i32.const 2)) (then (local.set $dst (local.get $ptr2))))
                (if (i32.eq (local.get $j) (i32.const 3)) (then (local.set $dst (local.get $ptr3))))

                (local.set $qw
                  (i32.shr_u
                    (i32.add (local.get $weight)
                      (i32.and
                        (i32.sub (i32.sub (local.get $weightsSum) (local.get $j)) (i32.const 1))
                        (i32.const 3)))
                    (i32.const 2)))

                (if (i32.ge_s (local.get $upperSlotCount) (local.get $qw))
                  (then
                    ;; All slots at current bitsPerSym
                    (local.set $n (local.get $qw))
                    (block $slotDone
                      (loop $slotLoop
                        (br_if $slotDone (i32.le_s (local.get $n) (i32.const 0)))
                        (i32.store (local.get $dst) (local.get $le_X))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 4)) (local.get $bitsPerSym))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 5)) (local.get $symbol))
                        (i32.store16 (i32.add (local.get $dst) (i32.const 6)) (local.get $le_W))
                        (local.set $le_W (i32.add (local.get $le_W) (local.get $whatToAdd)))
                        (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
                        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                        (br $slotLoop)
                      )
                    )
                    (local.set $upperSlotCount
                      (i32.sub (local.get $upperSlotCount) (local.get $qw)))
                  )
                  (else
                    ;; Some at current, some at bitsPerSym-1
                    (local.set $n (local.get $upperSlotCount))
                    (block $slotDone2
                      (loop $slotLoop2
                        (br_if $slotDone2 (i32.le_s (local.get $n) (i32.const 0)))
                        (i32.store (local.get $dst) (local.get $le_X))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 4)) (local.get $bitsPerSym))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 5)) (local.get $symbol))
                        (i32.store16 (i32.add (local.get $dst) (i32.const 6)) (local.get $le_W))
                        (local.set $le_W (i32.add (local.get $le_W) (local.get $whatToAdd)))
                        (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
                        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                        (br $slotLoop2)
                      )
                    )
                    ;; Switch to lower precision
                    (local.set $bitsPerSym (i32.sub (local.get $bitsPerSym) (i32.const 1)))
                    (local.set $whatToAdd (i32.shr_u (local.get $whatToAdd) (i32.const 1)))
                    (local.set $le_X (i32.shr_u (local.get $le_X) (i32.const 1)))
                    (local.set $le_W (i32.const 0))
                    (local.set $n (i32.sub (local.get $qw) (local.get $upperSlotCount)))
                    (block $slotDone3
                      (loop $slotLoop3
                        (br_if $slotDone3 (i32.le_s (local.get $n) (i32.const 0)))
                        (i32.store (local.get $dst) (local.get $le_X))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 4)) (local.get $bitsPerSym))
                        (i32.store8 (i32.add (local.get $dst) (i32.const 5)) (local.get $symbol))
                        (i32.store16 (i32.add (local.get $dst) (i32.const 6)) (local.get $le_W))
                        (local.set $le_W (i32.add (local.get $le_W) (local.get $whatToAdd)))
                        (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
                        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                        (br $slotLoop3)
                      )
                    )
                    (local.set $upperSlotCount (local.get $weight))
                  )
                )

                ;; Save pointer back
                (if (i32.eqz (local.get $j)) (then (local.set $ptr0 (local.get $dst))))
                (if (i32.eq (local.get $j) (i32.const 1)) (then (local.set $ptr1 (local.get $dst))))
                (if (i32.eq (local.get $j) (i32.const 2)) (then (local.set $ptr2 (local.get $dst))))
                (if (i32.eq (local.get $j) (i32.const 3)) (then (local.set $ptr3 (local.get $dst))))

                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $laneLoop)
              )
            )
          )
          (else
            ;; Weight <= 4: use bitmask-based distribution
            (local.set $bitsVal
              (i32.shl (i32.sub (i32.shl (i32.const 1) (local.get $weight)) (i32.const 1))
                (i32.and (local.get $weightsSum) (i32.const 3))))
            (local.set $bitsVal
              (i32.or (local.get $bitsVal) (i32.shr_u (local.get $bitsVal) (i32.const 4))))
            (local.set $n (local.get $weight))
            (local.set $ww (local.get $weight))
            (block $bitmaskDone
              (loop $bitmaskLoop
                (br_if $bitmaskDone (i32.le_s (local.get $n) (i32.const 0)))
                (local.set $idx (i32.ctz (local.get $bitsVal)))
                (local.set $bitsVal (i32.and (local.get $bitsVal)
                  (i32.sub (local.get $bitsVal) (i32.const 1))))
                ;; Select pointer
                (if (i32.eqz (local.get $idx)) (then (local.set $dst (local.get $ptr0))))
                (if (i32.eq (local.get $idx) (i32.const 1)) (then (local.set $dst (local.get $ptr1))))
                (if (i32.eq (local.get $idx) (i32.const 2)) (then (local.set $dst (local.get $ptr2))))
                (if (i32.eq (local.get $idx) (i32.const 3)) (then (local.set $dst (local.get $ptr3))))
                ;; Write entry
                (local.set $symBits (i32.sub (i32.const 31) (i32.clz (local.get $ww))))
                (local.set $bitsPerSym (i32.sub (local.get $logTableBits) (local.get $symBits)))
                (i32.store (local.get $dst)
                  (i32.sub (i32.shl (i32.const 1) (local.get $bitsPerSym)) (i32.const 1)))
                (i32.store8 (i32.add (local.get $dst) (i32.const 4)) (local.get $bitsPerSym))
                (i32.store8 (i32.add (local.get $dst) (i32.const 5)) (local.get $symbol))
                (i32.store16 (i32.add (local.get $dst) (i32.const 6))
                  (i32.and (i32.sub (local.get $L) (i32.const 1))
                    (i32.shl (local.get $ww) (local.get $bitsPerSym))))
                ;; Advance pointer
                (local.set $dst (i32.add (local.get $dst) (i32.const 8)))
                (if (i32.eqz (local.get $idx)) (then (local.set $ptr0 (local.get $dst))))
                (if (i32.eq (local.get $idx) (i32.const 1)) (then (local.set $ptr1 (local.get $dst))))
                (if (i32.eq (local.get $idx) (i32.const 2)) (then (local.set $ptr2 (local.get $dst))))
                (if (i32.eq (local.get $idx) (i32.const 3)) (then (local.set $ptr3 (local.get $dst))))
                (local.set $ww (i32.add (local.get $ww) (i32.const 1)))
                (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                (br $bitmaskLoop)
              )
            )
          )
        )

        (local.set $weightsSum (i32.add (local.get $weightsSum) (local.get $weight)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $multiLoop)
      )
    )

    (i32.const 1)
  )

  ;; ── tans_decode ────────────────────────────────────────────
  ;; 5-state interleaved tANS decode.
  ;; Parameters stored in locals. Returns 1 on success, 0 on failure.
  (func $tans_decode
    (param $dst i32) (param $dstEnd i32)
    (param $ptrF i32) (param $ptrB i32)
    (param $bitsF i32) (param $bitsB i32)
    (param $bitposF i32) (param $bitposB i32)
    (param $state0 i32) (param $state1 i32)
    (param $state2 i32) (param $state3 i32) (param $state4 i32)
    (param $lutMask i32)
    (param $srcStart i32) (param $srcEnd i32)
    (result i32)
    (local $e i32)  ;; pointer to LutEnt
    (local $eBitsX i32) (local $eX i32) (local $eW i32)

    (if (i32.gt_u (local.get $ptrF) (local.get $ptrB))
      (then (return (i32.const 0)))
    )

    (if (i32.lt_u (local.get $dst) (local.get $dstEnd))
      (then
        (block $decodeDone
          (loop $decodeLoop
            ;; FORWARD REFILL
            (local.set $bitsF
              (i32.or (local.get $bitsF)
                (i32.shl (i32.load (local.get $ptrF)) (local.get $bitposF))))
            (local.set $ptrF (i32.add (local.get $ptrF)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposF)) (i32.const 3))))
            (local.set $bitposF (i32.or (local.get $bitposF) (i32.const 24)))

            ;; FORWARD ROUND state0
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state0) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state0 (i32.and
              (i32.add (i32.and (local.get $bitsF) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $eBitsX)))
            (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; FORWARD ROUND state1
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state1) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state1 (i32.and
              (i32.add (i32.and (local.get $bitsF) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $eBitsX)))
            (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; FORWARD REFILL
            (local.set $bitsF
              (i32.or (local.get $bitsF)
                (i32.shl (i32.load (local.get $ptrF)) (local.get $bitposF))))
            (local.set $ptrF (i32.add (local.get $ptrF)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposF)) (i32.const 3))))
            (local.set $bitposF (i32.or (local.get $bitposF) (i32.const 24)))

            ;; FORWARD ROUND state2
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state2) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state2 (i32.and
              (i32.add (i32.and (local.get $bitsF) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $eBitsX)))
            (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; FORWARD ROUND state3
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state3) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state3 (i32.and
              (i32.add (i32.and (local.get $bitsF) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $eBitsX)))
            (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; FORWARD REFILL + ROUND state4
            (local.set $bitsF
              (i32.or (local.get $bitsF)
                (i32.shl (i32.load (local.get $ptrF)) (local.get $bitposF))))
            (local.set $ptrF (i32.add (local.get $ptrF)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposF)) (i32.const 3))))
            (local.set $bitposF (i32.or (local.get $bitposF) (i32.const 24)))

            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state4) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state4 (i32.and
              (i32.add (i32.and (local.get $bitsF) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $eBitsX)))
            (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; BACKWARD REFILL
            (local.set $bitsB
              (i32.or (local.get $bitsB)
                (i32.shl
                  (call $huff_bswap32 (i32.load (i32.sub (local.get $ptrB) (i32.const 4))))
                  (local.get $bitposB))))
            (local.set $ptrB (i32.sub (local.get $ptrB)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposB)) (i32.const 3))))
            (local.set $bitposB (i32.or (local.get $bitposB) (i32.const 24)))

            ;; BACKWARD ROUND state0
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state0) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state0 (i32.and
              (i32.add (i32.and (local.get $bitsB) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $eBitsX)))
            (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; BACKWARD ROUND state1
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state1) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state1 (i32.and
              (i32.add (i32.and (local.get $bitsB) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $eBitsX)))
            (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; BACKWARD REFILL
            (local.set $bitsB
              (i32.or (local.get $bitsB)
                (i32.shl
                  (call $huff_bswap32 (i32.load (i32.sub (local.get $ptrB) (i32.const 4))))
                  (local.get $bitposB))))
            (local.set $ptrB (i32.sub (local.get $ptrB)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposB)) (i32.const 3))))
            (local.set $bitposB (i32.or (local.get $bitposB) (i32.const 24)))

            ;; BACKWARD ROUND state2
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state2) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state2 (i32.and
              (i32.add (i32.and (local.get $bitsB) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $eBitsX)))
            (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; BACKWARD ROUND state3
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state3) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state3 (i32.and
              (i32.add (i32.and (local.get $bitsB) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $eBitsX)))
            (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            ;; BACKWARD REFILL
            (local.set $bitsB
              (i32.or (local.get $bitsB)
                (i32.shl
                  (call $huff_bswap32 (i32.load (i32.sub (local.get $ptrB) (i32.const 4))))
                  (local.get $bitposB))))
            (local.set $ptrB (i32.sub (local.get $ptrB)
              (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposB)) (i32.const 3))))
            (local.set $bitposB (i32.or (local.get $bitposB) (i32.const 24)))

            ;; BACKWARD ROUND state4
            (local.set $e (i32.add (global.get $TANS_LUT) (i32.shl (local.get $state4) (i32.const 3))))
            (i32.store8 (local.get $dst) (i32.load8_u (i32.add (local.get $e) (i32.const 5))))
            (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
            (local.set $eBitsX (i32.load8_u (i32.add (local.get $e) (i32.const 4))))
            (local.set $state4 (i32.and
              (i32.add (i32.and (local.get $bitsB) (i32.load (local.get $e)))
                (i32.load16_u (i32.add (local.get $e) (i32.const 6))))
              (local.get $lutMask)))
            (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $eBitsX)))
            (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $eBitsX)))
            (br_if $decodeDone (i32.ge_u (local.get $dst) (local.get $dstEnd)))

            (br $decodeLoop)
          )
        )
      )
    )

    ;; Write final 5 state bytes past dstEnd
    (i32.store8 (local.get $dstEnd) (local.get $state0))
    (i32.store8 (i32.add (local.get $dstEnd) (i32.const 1)) (local.get $state1))
    (i32.store8 (i32.add (local.get $dstEnd) (i32.const 2)) (local.get $state2))
    (i32.store8 (i32.add (local.get $dstEnd) (i32.const 3)) (local.get $state3))
    (i32.store8 (i32.add (local.get $dstEnd) (i32.const 4)) (local.get $state4))

    (i32.const 1)
  )

  ;; ── high_decode_tans ───────────────────────────────────────
  ;; Top-level tANS block decoder.
  ;; Returns total source bytes consumed from srcStart, or -1 on error.
  (func $high_decode_tans
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
    (result i32)
    (local $srcEnd i32)
    (local $logTableBits i32)
    (local $lMask i32)
    (local $bitsF i32) (local $bitsB i32)
    (local $bitposF i32) (local $bitposB i32)
    (local $state0 i32) (local $state1 i32)
    (local $state2 i32) (local $state3 i32) (local $state4 i32)
    (local $ptrF i32) (local $ptrB i32)

    (if (i32.or (i32.lt_s (local.get $srcSize) (i32.const 8))
                (i32.lt_s (local.get $dstSize) (i32.const 5)))
      (then (return (i32.const -1)))
    )

    (local.set $srcEnd (i32.add (local.get $src) (local.get $srcSize)))

    ;; Init bit reader and read header
    (call $br_init (local.get $src) (local.get $srcEnd))
    (call $br_refill)

    ;; Reserved bit (must be 0)
    ;; TRACE:
    (global.set $TRACE (i32.const 0x10))
    (if (call $br_read_bits_no_refill (i32.const 1))
      (then (return (i32.const -1)))
    )

    ;; logTableBits = ReadBits(2) + 8
    (local.set $logTableBits
      (i32.add (call $br_read_bits_no_refill (i32.const 2)) (i32.const 8)))
    ;; TRACE:
    (global.set $TRACE (i32.add (i32.const 0x20) (local.get $logTableBits)))

    ;; Decode frequency table (sparse path)
    ;; Check which path: read next bit
    (call $br_refill)
    (if (call $br_read_bits_no_refill (i32.const 1))
      (then
        ;; Golomb-Rice path
        (if (i32.eqz (call $tans_decode_table_gr (local.get $logTableBits)))
          (then (return (i32.const -1)))
        )
      )
      (else
        ;; Sparse path
        (if (i32.eqz (call $tans_decode_table_sparse (local.get $logTableBits)))
          (then (return (i32.const -1)))
        )
      )
    )

    ;; Recover src from bit reader
    (local.set $src
      (i32.sub (i32.load (global.get $BR_P))
        (i32.shr_u
          (i32.sub (i32.const 24) (i32.load (global.get $BR_BITPOS)))
          (i32.const 3))))

    (if (i32.lt_s (i32.sub (local.get $srcEnd) (local.get $src)) (i32.const 8))
      (then (return (i32.const -1)))
    )

    ;; Build LUT
    (if (i32.eqz (call $tans_init_lut (local.get $logTableBits)))
      (then
        ;; TRACE:
    (global.set $TRACE (i32.const 0x61))
        (return (i32.const -1)))
    )
    ;; TRACE:
    (global.set $TRACE (i32.const 0x70))

    ;; Read initial states from bitstream
    (local.set $lMask (i32.sub (i32.shl (i32.const 1) (local.get $logTableBits)) (i32.const 1)))

    ;; Forward 4 bytes
    (local.set $bitsF (i32.load (local.get $src)))
    (local.set $src (i32.add (local.get $src) (i32.const 4)))
    ;; Backward 4 bytes (bswap)
    (local.set $bitsB (call $huff_bswap32 (i32.load (i32.sub (local.get $srcEnd) (i32.const 4)))))
    (local.set $srcEnd (i32.sub (local.get $srcEnd) (i32.const 4)))

    (local.set $bitposF (i32.const 32))
    (local.set $bitposB (i32.const 32))

    ;; Read state0 from forward
    (local.set $state0 (i32.and (local.get $bitsF) (local.get $lMask)))
    (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $logTableBits)))
    (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $logTableBits)))

    ;; Read state1 from backward
    (local.set $state1 (i32.and (local.get $bitsB) (local.get $lMask)))
    (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $logTableBits)))
    (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $logTableBits)))

    ;; Read state2 from forward
    (local.set $state2 (i32.and (local.get $bitsF) (local.get $lMask)))
    (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $logTableBits)))
    (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $logTableBits)))

    ;; Read state3 from backward
    (local.set $state3 (i32.and (local.get $bitsB) (local.get $lMask)))
    (local.set $bitsB (i32.shr_u (local.get $bitsB) (local.get $logTableBits)))
    (local.set $bitposB (i32.sub (local.get $bitposB) (local.get $logTableBits)))

    ;; Refill forward for state4
    (local.set $bitsF
      (i32.or (local.get $bitsF)
        (i32.shl (i32.load (local.get $src)) (local.get $bitposF))))
    (local.set $src (i32.add (local.get $src)
      (i32.shr_u (i32.sub (i32.const 31) (local.get $bitposF)) (i32.const 3))))
    (local.set $bitposF (i32.or (local.get $bitposF) (i32.const 24)))

    ;; Read state4
    (local.set $state4 (i32.and (local.get $bitsF) (local.get $lMask)))
    (local.set $bitsF (i32.shr_u (local.get $bitsF) (local.get $logTableBits)))
    (local.set $bitposF (i32.sub (local.get $bitposF) (local.get $logTableBits)))

    ;; Setup pointers
    (local.set $ptrF (i32.sub (local.get $src) (i32.shr_u (local.get $bitposF) (i32.const 3))))
    (local.set $bitposF (i32.and (local.get $bitposF) (i32.const 7)))
    (local.set $ptrB (i32.add (local.get $srcEnd) (i32.shr_u (local.get $bitposB) (i32.const 3))))
    (local.set $bitposB (i32.and (local.get $bitposB) (i32.const 7)))

    ;; Run the decode
    (if (i32.eqz
          (call $tans_decode
            (local.get $dst)
            (i32.sub (i32.add (local.get $dst) (local.get $dstSize)) (i32.const 5))
            (local.get $ptrF) (local.get $ptrB)
            (local.get $bitsF) (local.get $bitsB)
            (local.get $bitposF) (local.get $bitposB)
            (local.get $state0) (local.get $state1)
            (local.get $state2) (local.get $state3) (local.get $state4)
            (local.get $lMask)
            (local.get $src) (local.get $srcEnd)))
      (then (return (i32.const -1)))
    )

    (i32.store (global.get $ENT_DECODED_SIZE) (local.get $dstSize))
    (local.get $srcSize)
  )

