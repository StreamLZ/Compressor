  ;; ── 070-golomb-rice: Golomb-Rice decoders + range builders ──
  ;; Functions: $decode_golomb_rice_lengths, $decode_golomb_rice_bits,
  ;;   $br_read_fluff, $huff_convert_to_ranges, $tans_decode_table_gr
  ;; Uses: GR BitReader2 at 0xC0-0xC8
  ;; Scratch: TANS_GR_RICE at 0x220000, TANS_GR_RANGE at 0x220210
  ;; Uses BitReader2 state at addresses 0xC0..0xCB:
  ;;   0xC0: P (i32), 0xC4: PEnd (i32), 0xC8: Bitpos (i32)

  (global $GR_P      i32 (i32.const 0xC0))
  (global $GR_PEND   i32 (i32.const 0xC4))
  (global $GR_BITPOS i32 (i32.const 0xC8))

  ;; ── decode_golomb_rice_lengths ──────────────────────────────
  ;; Decodes Golomb-Rice run-lengths using LUT byte-at-a-time.
  ;; GR BitReader2 state must be initialized before calling.
  ;; Parameters: dst, size (number of symbols to decode)
  ;; Returns 1 on success, 0 on failure.
  ;; Updates GR_P and GR_BITPOS.
  (func $decode_golomb_rice_lengths (param $dst i32) (param $size i32) (result i32)
    (local $p i32) (local $pEnd i32) (local $dstEnd i32)
    (local $count i32) (local $v i32) (local $x i32) (local $n i32)
    (local $bitpos i32)

    (local.set $p (i32.load (global.get $GR_P)))
    (local.set $pEnd (i32.load (global.get $GR_PEND)))
    (local.set $dstEnd (i32.add (local.get $dst) (local.get $size)))

    (if (i32.ge_u (local.get $p) (local.get $pEnd))
      (then (return (i32.const 0)))
    )

    ;; count = -(int)bitpos; v = *p++ & (255 >> bitpos)
    (local.set $bitpos (i32.load (global.get $GR_BITPOS)))
    (local.set $count (i32.sub (i32.const 0) (local.get $bitpos)))
    (local.set $v
      (i32.and
        (i32.load8_u (local.get $p))
        (i32.shr_u (i32.const 255) (local.get $bitpos))))
    (local.set $p (i32.add (local.get $p) (i32.const 1)))

    ;; Main loop
    (block $done
      (loop $loop
        (if (i32.eqz (local.get $v))
          (then
            ;; Zero byte: accumulate count
            (local.set $count (i32.add (local.get $count) (i32.const 8)))
          )
          (else
            ;; Non-zero: decode symbols using LUT
            (local.set $x (i32.load (i32.add (global.get $RICE_VALUE)
              (i32.shl (local.get $v) (i32.const 2)))))
            ;; Write 4 low symbols: dst[0..3] = count + (x & 0x0F0F0F0F)
            (i32.store (local.get $dst)
              (i32.add (local.get $count)
                (i32.and (local.get $x) (i32.const 0x0F0F0F0F))))
            ;; Write 4 high symbols: dst[4..7] = (x >> 4) & 0x0F0F0F0F
            (i32.store (i32.add (local.get $dst) (i32.const 4))
              (i32.and (i32.shr_u (local.get $x) (i32.const 4)) (i32.const 0x0F0F0F0F)))
            ;; Advance dst by number of decoded symbols
            (local.set $dst (i32.add (local.get $dst)
              (i32.load8_u (i32.add (global.get $RICE_LEN) (local.get $v)))))
            ;; Check if done
            (br_if $done (i32.ge_u (local.get $dst) (local.get $dstEnd)))
            ;; Carry count from top nibble
            (local.set $count (i32.shr_u (local.get $x) (i32.const 28)))
          )
        )
        ;; Read next byte
        (if (i32.ge_u (local.get $p) (local.get $pEnd))
          (then (return (i32.const 0)))
        )
        (local.set $v (i32.load8_u (local.get $p)))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $loop)
      )
    )

    ;; Step back if we overshot
    (if (i32.gt_u (local.get $dst) (local.get $dstEnd))
      (then
        (local.set $n (i32.sub (local.get $dst) (local.get $dstEnd)))
        (block $stepDone
          (loop $stepLoop
            (br_if $stepDone (i32.le_s (local.get $n) (i32.const 0)))
            ;; v &= v - 1 (clear lowest set bit)
            (local.set $v (i32.and (local.get $v) (i32.sub (local.get $v) (i32.const 1))))
            (local.set $n (i32.sub (local.get $n) (i32.const 1)))
            (br $stepLoop)
          )
        )
      )
    )

    ;; Step back if byte not fully consumed
    (local.set $bitpos (i32.const 0))
    (if (i32.eqz (i32.and (local.get $v) (i32.const 1)))
      (then
        (local.set $p (i32.sub (local.get $p) (i32.const 1)))
        (local.set $bitpos (i32.sub (i32.const 8) (i32.ctz (local.get $v))))
      )
    )

    ;; Update state
    (i32.store (global.get $GR_P) (local.get $p))
    (i32.store (global.get $GR_BITPOS) (local.get $bitpos))
    (i32.const 1)
  )

  ;; ── decode_golomb_rice_bits ─────────────────────────────────
  ;; Merges precision bits into the decoded run-lengths.
  ;; For bitcount=1: multiply existing values by 2 and add 1 bit each.
  ;; For bitcount=2: multiply by 4 and add 2 bits each.
  ;; For bitcount=3: multiply by 8 and add 3 bits each.
  ;; Returns 1 on success, 0 on failure.
  (func $decode_golomb_rice_bits
    (param $dst i32) (param $size i32) (param $bitcount i32) (result i32)
    (local $p i32) (local $bitpos i32) (local $pEnd i32)
    (local $dstEnd i32) (local $bitsNeeded i32) (local $bytesNeeded i32)
    (local $bits i32) (local $val i32) (local $i i32)

    (if (i32.eqz (local.get $bitcount))
      (then (return (i32.const 1)))
    )

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $size)))
    (local.set $p (i32.load (global.get $GR_P)))
    (local.set $bitpos (i32.load (global.get $GR_BITPOS)))
    (local.set $pEnd (i32.load (global.get $GR_PEND)))

    ;; Validate enough source data
    (local.set $bitsNeeded (i32.add (local.get $bitpos)
      (i32.mul (local.get $bitcount) (local.get $size))))
    (local.set $bytesNeeded (i32.shr_u (i32.add (local.get $bitsNeeded) (i32.const 7)) (i32.const 3)))
    (if (i32.gt_u (local.get $bytesNeeded) (i32.sub (local.get $pEnd) (local.get $p)))
      (then (return (i32.const 0)))
    )

    ;; Simple bit-at-a-time implementation (works for bitcount 1-3)
    ;; Load initial bits
    (local.set $bits (i32.const 0))
    (if (i32.lt_u (local.get $p) (local.get $pEnd))
      (then (local.set $bits (i32.load8_u (local.get $p))))
    )

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $dst) (local.get $dstEnd)))

        ;; Read bitcount bits
        (local.set $val (i32.const 0))
        (local.set $i (i32.const 0))
        (block $bitDone
          (loop $bitLoop
            (br_if $bitDone (i32.ge_u (local.get $i) (local.get $bitcount)))
            ;; Extract one bit: (bits >> (7 - bitpos)) & 1
            (local.set $val
              (i32.or
                (i32.shl (local.get $val) (i32.const 1))
                (i32.and
                  (i32.shr_u (local.get $bits)
                    (i32.sub (i32.const 7) (local.get $bitpos)))
                  (i32.const 1))))
            (local.set $bitpos (i32.add (local.get $bitpos) (i32.const 1)))
            (if (i32.ge_u (local.get $bitpos) (i32.const 8))
              (then
                (local.set $bitpos (i32.const 0))
                (local.set $p (i32.add (local.get $p) (i32.const 1)))
                (if (i32.lt_u (local.get $p) (local.get $pEnd))
                  (then (local.set $bits (i32.load8_u (local.get $p))))
                )
              )
            )
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $bitLoop)
          )
        )

        ;; dst[0] = dst[0] * (1 << bitcount) + val
        (i32.store8 (local.get $dst)
          (i32.add
            (i32.shl (i32.load8_u (local.get $dst)) (local.get $bitcount))
            (local.get $val)))
        (local.set $dst (i32.add (local.get $dst) (i32.const 1)))
        (br $loop)
      )
    )

    ;; Update state
    (i32.store (global.get $GR_P) (local.get $p))
    (i32.store (global.get $GR_BITPOS) (local.get $bitpos))
    (i32.const 1)
  )

  ;; ── br_read_fluff ──────────────────────────────────────────
  ;; Read the fluff value for sub-256 symbol alphabets.
  ;; Uses BR at 0x30.
  (func $br_read_fluff (param $numSymbols i32) (result i32)
    (local $x i32) (local $y i32) (local $v i32) (local $z i32)
    (local $bits i32)

    (if (i32.eq (local.get $numSymbols) (i32.const 256))
      (then (return (i32.const 0)))
    )

    (local.set $x (i32.sub (i32.const 257) (local.get $numSymbols)))
    (if (i32.gt_s (local.get $x) (local.get $numSymbols))
      (then (local.set $x (local.get $numSymbols)))
    )
    (local.set $x (i32.mul (local.get $x) (i32.const 2)))

    ;; y = log2(x-1) + 1
    (local.set $y
      (i32.add
        (i32.sub (i32.const 31) (i32.clz (i32.sub (local.get $x) (i32.const 1))))
        (i32.const 1)))

    (local.set $bits (i32.load (global.get $BR_BITS)))
    (local.set $v (i32.shr_u (local.get $bits)
      (i32.sub (i32.const 32) (local.get $y))))
    (local.set $z (i32.sub (i32.shl (i32.const 1) (local.get $y)) (local.get $x)))

    (if (i32.ge_u (i32.shr_u (local.get $v) (i32.const 1)) (local.get $z))
      (then
        ;; Full precision
        (i32.store (global.get $BR_BITS) (i32.shl (local.get $bits) (local.get $y)))
        (i32.store (global.get $BR_BITPOS)
          (i32.add (i32.load (global.get $BR_BITPOS)) (local.get $y)))
        (return (i32.sub (local.get $v) (local.get $z)))
      )
    )

    ;; Half precision
    (i32.store (global.get $BR_BITS)
      (i32.shl (local.get $bits) (i32.sub (local.get $y) (i32.const 1))))
    (i32.store (global.get $BR_BITPOS)
      (i32.add (i32.load (global.get $BR_BITPOS)) (i32.sub (local.get $y) (i32.const 1))))
    (i32.shr_u (local.get $v) (i32.const 1))
  )

  ;; ============================================================
  ;; Huff_ConvertToRanges
  ;; ============================================================
  ;; Converts symbol ranges from fluff+rice data.
  ;; rangeAddr = base address for HuffRange array (4 bytes each: symbol u16 + num u16)
  ;; symlen = pointer to range descriptor bytes
  ;; Uses BR at 0x30.
  ;; Returns number of ranges on success, -1 on error.

  (func $huff_convert_to_ranges
    (param $rangeAddr i32) (param $numSymbols i32) (param $P i32) (param $symlen i32)
    (result i32)
    (local $numRanges i32) (local $symIdx i32) (local $symsUsed i32)
    (local $i i32) (local $v i32) (local $num i32) (local $space i32)

    (local.set $numRanges (i32.shr_u (local.get $P) (i32.const 1)))
    (local.set $symIdx (i32.const 0))

    ;; Start with space?
    (if (i32.and (local.get $P) (i32.const 1))
      (then
        (call $br_refill)
        (local.set $v (i32.load8_u (local.get $symlen)))
        (local.set $symlen (i32.add (local.get $symlen) (i32.const 1)))
        (if (i32.ge_u (local.get $v) (i32.const 8))
          (then (return (i32.const -1)))
        )
        (local.set $symIdx
          (i32.sub
            (i32.add
              (call $br_read_bits_no_refill (i32.add (local.get $v) (i32.const 1)))
              (i32.shl (i32.const 1) (i32.add (local.get $v) (i32.const 1))))
            (i32.const 1)))
      )
    )

    (local.set $symsUsed (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $numRanges)))
        (call $br_refill)

        ;; num = ReadBitsNoRefillZero(symlen[0]) + (1 << symlen[0])
        (local.set $v (i32.load8_u (local.get $symlen)))
        (if (i32.ge_u (local.get $v) (i32.const 9))
          (then (return (i32.const -1)))
        )
        (local.set $num
          (i32.add
            (call $br_read_bits_no_refill_zero (local.get $v))
            (i32.shl (i32.const 1) (local.get $v))))

        ;; space = ReadBitsNoRefill(symlen[1]+1) + (1 << (symlen[1]+1)) - 1
        (local.set $v (i32.load8_u (i32.add (local.get $symlen) (i32.const 1))))
        (if (i32.ge_u (local.get $v) (i32.const 8))
          (then (return (i32.const -1)))
        )
        (local.set $space
          (i32.sub
            (i32.add
              (call $br_read_bits_no_refill (i32.add (local.get $v) (i32.const 1)))
              (i32.shl (i32.const 1) (i32.add (local.get $v) (i32.const 1))))
            (i32.const 1)))

        ;; range[i] = {symIdx, num}
        (i32.store16 (i32.add (local.get $rangeAddr) (i32.shl (local.get $i) (i32.const 2)))
          (local.get $symIdx))
        (i32.store16 (i32.add (i32.add (local.get $rangeAddr) (i32.shl (local.get $i) (i32.const 2))) (i32.const 2))
          (local.get $num))

        (local.set $symsUsed (i32.add (local.get $symsUsed) (local.get $num)))
        (local.set $symIdx (i32.add (local.get $symIdx) (i32.add (local.get $num) (local.get $space))))
        (local.set $symlen (i32.add (local.get $symlen) (i32.const 2)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )

    ;; Validate
    (if (i32.or
          (i32.ge_u (local.get $symIdx) (i32.const 256))
          (i32.or
            (i32.ge_u (local.get $symsUsed) (local.get $numSymbols))
            (i32.gt_u
              (i32.add (local.get $symIdx) (i32.sub (local.get $numSymbols) (local.get $symsUsed)))
              (i32.const 256))))
      (then (return (i32.const -1)))
    )

    ;; Final range entry
    (i32.store16 (i32.add (local.get $rangeAddr) (i32.shl (local.get $numRanges) (i32.const 2)))
      (local.get $symIdx))
    (i32.store16 (i32.add (i32.add (local.get $rangeAddr) (i32.shl (local.get $numRanges) (i32.const 2))) (i32.const 2))
      (i32.sub (local.get $numSymbols) (local.get $symsUsed)))

    (i32.add (local.get $numRanges) (i32.const 1))
  )

  ;; ============================================================
  ;; tANS Golomb-Rice table path
  ;; ============================================================
  ;; Extends tans_decode_table_sparse to handle format bit=1 (Golomb-Rice)

  ;; Scratch for tANS GR: rice buffer at 0x00220000 (528 bytes), range at 0x00220210 (532 bytes)
  (global $TANS_GR_RICE  i32 (i32.const 0x00220000))
  (global $TANS_GR_RANGE i32 (i32.const 0x00220210))

  (func $tans_decode_table_gr (param $logTableBits i32) (result i32)
    (local $Q i32) (local $numSymbols i32) (local $fluff i32) (local $totalRice i32)
    (local $L i32) (local $curRice i32) (local $curRiceEnd i32)
    (local $average i32) (local $somesum i32) (local $aCount i32) (local $bCount i32)
    (local $ri i32) (local $symbol i32) (local $num i32)
    (local $nextra i32) (local $v i32) (local $avgDiv4 i32) (local $limit i32)
    (local $ranges i32)

    (local.set $Q (call $br_read_bits_no_refill (i32.const 3)))
    (local.set $numSymbols (i32.add (call $br_read_bits_no_refill (i32.const 8)) (i32.const 1)))
    (if (i32.lt_s (local.get $numSymbols) (i32.const 2))
      (then (return (i32.const 0)))
    )

    (local.set $fluff (call $br_read_fluff (local.get $numSymbols)))
    (local.set $totalRice (i32.add (local.get $fluff) (local.get $numSymbols)))
    (if (i32.or (i32.gt_s (local.get $totalRice) (i32.const 512))
                (i32.lt_s (local.get $totalRice) (i32.const 0)))
      (then (return (i32.const 0)))
    )

    ;; Initialize GR BitReader2 from BR state
    (i32.store (global.get $GR_BITPOS)
      (i32.and (i32.sub (i32.load (global.get $BR_BITPOS)) (i32.const 24)) (i32.const 7)))
    (i32.store (global.get $GR_PEND) (i32.load (global.get $BR_PEND)))
    (i32.store (global.get $GR_P)
      (i32.sub (i32.load (global.get $BR_P))
        (i32.shr_u
          (i32.add (i32.sub (i32.const 24) (i32.load (global.get $BR_BITPOS))) (i32.const 7))
          (i32.const 3))))

    ;; Decode Golomb-Rice lengths
    (if (i32.eqz (call $decode_golomb_rice_lengths (global.get $TANS_GR_RICE) (local.get $totalRice)))
      (then (return (i32.const 0)))
    )
    ;; Zero padding
    (memory.fill (i32.add (global.get $TANS_GR_RICE) (local.get $totalRice)) (i32.const 0) (i32.const 16))

    ;; Reset BR from GR state
    (i32.store (global.get $BR_BITPOS) (i32.const 24))
    (i32.store (global.get $BR_P) (i32.load (global.get $GR_P)))
    (i32.store (global.get $BR_BITS) (i32.const 0))
    (call $br_refill)
    ;; Adjust for remaining GR bits
    (i32.store (global.get $BR_BITS)
      (i32.shl (i32.load (global.get $BR_BITS)) (i32.load (global.get $GR_BITPOS))))
    (i32.store (global.get $BR_BITPOS)
      (i32.add (i32.load (global.get $BR_BITPOS)) (i32.load (global.get $GR_BITPOS))))

    ;; ConvertToRanges
    (if (i32.ge_s (i32.shr_u (local.get $fluff) (i32.const 1)) (i32.const 133))
      (then (return (i32.const 0)))
    )
    (local.set $ranges
      (call $huff_convert_to_ranges
        (global.get $TANS_GR_RANGE)
        (local.get $numSymbols)
        (local.get $fluff)
        (i32.add (global.get $TANS_GR_RICE) (local.get $numSymbols))))
    (if (i32.le_s (local.get $ranges) (i32.const 0))
      (then (return (i32.const 0)))
    )

    (call $br_refill)

    ;; Build TansData from ranges + rice values
    (local.set $L (i32.shl (i32.const 1) (local.get $logTableBits)))
    (local.set $curRice (global.get $TANS_GR_RICE))
    (local.set $curRiceEnd (i32.add (global.get $TANS_GR_RICE) (local.get $totalRice)))
    (local.set $average (i32.const 6))
    (local.set $somesum (i32.const 0))
    (local.set $aCount (i32.const 0))
    (local.set $bCount (i32.const 0))

    (local.set $ri (i32.const 0))
    (block $riDone
      (loop $riLoop
        (br_if $riDone (i32.ge_u (local.get $ri) (local.get $ranges)))

        (local.set $symbol
          (i32.load16_u (i32.add (global.get $TANS_GR_RANGE) (i32.shl (local.get $ri) (i32.const 2)))))
        (local.set $num
          (i32.load16_u (i32.add (i32.add (global.get $TANS_GR_RANGE) (i32.shl (local.get $ri) (i32.const 2))) (i32.const 2))))

        (if (i32.or (i32.le_s (local.get $num) (i32.const 0)) (i32.gt_s (local.get $num) (i32.const 256)))
          (then (return (i32.const 0)))
        )

        (block $numDone
          (loop $numLoop
            (br_if $numDone (i32.le_s (local.get $num) (i32.const 0)))
            (call $br_refill)

            (if (i32.ge_u (local.get $curRice) (local.get $curRiceEnd))
              (then (return (i32.const 0)))
            )
            (local.set $nextra (i32.add (local.get $Q) (i32.load8_u (local.get $curRice))))
            (local.set $curRice (i32.add (local.get $curRice) (i32.const 1)))
            (if (i32.gt_s (local.get $nextra) (i32.const 15))
              (then (return (i32.const 0)))
            )

            ;; v = ReadBitsNoRefillZero(nextra) + (1 << nextra) - (1 << Q)
            (local.set $v
              (i32.sub
                (i32.add
                  (call $br_read_bits_no_refill_zero (local.get $nextra))
                  (i32.shl (i32.const 1) (local.get $nextra)))
                (i32.shl (i32.const 1) (local.get $Q))))

            ;; Zigzag decode with average prediction
            (local.set $avgDiv4 (i32.shr_u (local.get $average) (i32.const 2)))
            (local.set $limit (i32.shl (local.get $avgDiv4) (i32.const 1)))
            (if (i32.le_s (local.get $v) (local.get $limit))
              (then
                (local.set $v
                  (i32.add (local.get $avgDiv4)
                    (i32.xor
                      (i32.sub (i32.const 0) (i32.and (local.get $v) (i32.const 1)))
                      (i32.shr_u (local.get $v) (i32.const 1)))))
              )
            )
            (if (i32.gt_s (local.get $limit) (local.get $v))
              (then (local.set $limit (local.get $v)))
            )
            (local.set $v (i32.add (local.get $v) (i32.const 1)))
            (local.set $average (i32.add (local.get $average)
              (i32.sub (local.get $limit) (local.get $avgDiv4))))

            ;; Store in TansData
            (if (i32.eq (local.get $v) (i32.const 1))
              (then
                (if (i32.ge_u (local.get $aCount) (i32.const 256))
                  (then (return (i32.const 0)))
                )
                (i32.store8 (i32.add (global.get $TANS_A) (local.get $aCount)) (local.get $symbol))
                (local.set $aCount (i32.add (local.get $aCount) (i32.const 1)))
              )
              (else
                (if (i32.ge_u (local.get $bCount) (i32.const 256))
                  (then (return (i32.const 0)))
                )
                (i32.store (i32.add (global.get $TANS_B) (i32.shl (local.get $bCount) (i32.const 2)))
                  (i32.add (i32.shl (local.get $symbol) (i32.const 16)) (local.get $v)))
                (local.set $bCount (i32.add (local.get $bCount) (i32.const 1)))
              )
            )
            (local.set $somesum (i32.add (local.get $somesum) (local.get $v)))
            (if (i32.gt_s (local.get $somesum) (local.get $L))
              (then (return (i32.const 0)))
            )
            (local.set $symbol (i32.add (local.get $symbol) (i32.const 1)))
            (local.set $num (i32.sub (local.get $num) (i32.const 1)))
            (br $numLoop)
          )
        )

        (local.set $ri (i32.add (local.get $ri) (i32.const 1)))
        (br $riLoop)
      )
    )

    (if (i32.ne (local.get $somesum) (local.get $L))
      (then (return (i32.const 0)))
    )

    (i32.store (global.get $TANS_AUSED) (local.get $aCount))
    (i32.store (global.get $TANS_BUSED) (local.get $bCount))

    ;; Sort A and B
    (call $sort_bytes (global.get $TANS_A) (i32.add (global.get $TANS_A) (local.get $aCount)))
    (call $sort_u32s (global.get $TANS_B) (i32.add (global.get $TANS_B) (i32.shl (local.get $bCount) (i32.const 2))))

    (i32.const 1)
  )

