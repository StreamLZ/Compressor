  ;; ============================================================
  ;; Huffman Decoder
  ;; ============================================================
  ;;
  ;; Memory layout (at 0x00200000+):
  ;;   +0x0000: Forward LUT Bits2Len (2064 bytes)
  ;;   +0x0810: Forward LUT Bits2Sym (2064 bytes)
  ;;   +0x1020: Reverse LUT Bits2Len (2064 bytes)
  ;;   +0x1830: Reverse LUT Bits2Sym (2064 bytes)
  ;;   +0x2040: syms (1280 bytes)
  ;;   +0x2540: CodePrefixOrg (48 bytes)
  ;;   +0x2570: CodePrefixCur (48 bytes)

  (global $HUFF_LUT_LEN i32 (i32.const 0x00200000))
  (global $HUFF_LUT_SYM i32 (i32.const 0x00200810))
  (global $HUFF_REV_LEN i32 (i32.const 0x00201020))
  (global $HUFF_REV_SYM i32 (i32.const 0x00201830))
  (global $HUFF_SYMS    i32 (i32.const 0x00202040))
  (global $HUFF_PFXORG  i32 (i32.const 0x00202540))
  (global $HUFF_PFXCUR  i32 (i32.const 0x00202570))

  ;; CodePrefixOrg data segment
  (data (i32.const 0x00202540) "\00\00\00\00\00\00\00\00\02\00\00\00\06\00\00\00\0e\00\00\00\1e\00\00\00\3e\00\00\00\7e\00\00\00\fe\00\00\00\fe\01\00\00\fe\02\00\00\fe\03\00\00")

  ;; Golomb-Rice value table at 0x00203000 (256 * 4 = 1024 bytes)
  (global $RICE_VALUE i32 (i32.const 0x00203000))
  (data (i32.const 0x00203000) "\00\00\00\80\07\00\00\00\06\00\00\10\06\00\00\00\05\00\00\20\05\01\00\00\05\00\00\10\05\00\00\00\04\00\00\30\04\02\00\00\04\01\00\10\04\01\00\00\04\00\00\20\04\00\01\00\04\00\00\10\04\00\00\00\03\00\00\40\03\03\00\00\03\02\00\10\03\02\00\00\03\01\00\20\03\01\01\00\03\01\00\10\03\01\00\00\03\00\00\30\03\00\02\00\03\00\01\10\03\00\01\00\03\00\00\20\03\00\00\01\03\00\00\10\03\00\00\00\02\00\00\50\02\04\00\00\02\03\00\10\02\03\00\00\02\02\00\20\02\02\01\00\02\02\00\10\02\02\00\00\02\01\00\30\02\01\02\00\02\01\01\10\02\01\01\00\02\01\00\20\02\01\00\01\02\01\00\10\02\01\00\00\02\00\00\40\02\00\03\00\02\00\02\10\02\00\02\00\02\00\01\20\02\00\01\01\02\00\01\10\02\00\01\00\02\00\00\30\02\00\00\02\02\00\00\11\02\00\00\01\02\00\00\20\12\00\00\00\02\00\00\10\02\00\00\00\01\00\00\60\01\05\00\00\01\04\00\10\01\04\00\00\01\03\00\20\01\03\01\00\01\03\00\10\01\03\00\00\01\02\00\30\01\02\02\00\01\02\01\10\01\02\01\00\01\02\00\20\01\02\00\01\01\02\00\10\01\02\00\00\01\01\00\40\01\01\03\00\01\01\02\10\01\01\02\00\01\01\01\20\01\01\01\01\01\01\01\10\01\01\01\00\01\01\00\30\01\01\00\02\01\01\00\11\01\01\00\01\01\01\00\20\11\01\00\00\01\01\00\10\01\01\00\00\01\00\00\50\01\00\04\00\01\00\03\10\01\00\03\00\01\00\02\20\01\00\02\01\01\00\02\10\01\00\02\00\01\00\01\30\01\00\01\02\01\00\01\11\01\00\01\01\01\00\01\20\11\00\01\00\01\00\01\10\01\00\01\00\01\00\00\40\01\00\00\03\01\00\00\12\01\00\00\02\01\00\00\21\11\00\00\01\01\00\00\11\01\00\00\01\01\00\00\30\21\00\00\00\11\00\00\10\11\00\00\00\01\00\00\20\01\10\00\00\01\00\00\10\01\00\00\00\00\00\00\70\00\06\00\00\00\05\00\10\00\05\00\00\00\04\00\20\00\04\01\00\00\04\00\10\00\04\00\00\00\03\00\30\00\03\02\00\00\03\01\10\00\03\01\00\00\03\00\20\00\03\00\01\00\03\00\10\00\03\00\00\00\02\00\40\00\02\03\00\00\02\02\10\00\02\02\00\00\02\01\20\00\02\01\01\00\02\01\10\00\02\01\00\00\02\00\30\00\02\00\02\00\02\00\11\00\02\00\01\00\02\00\20\10\02\00\00\00\02\00\10\00\02\00\00\00\01\00\50\00\01\04\00\00\01\03\10\00\01\03\00\00\01\02\20\00\01\02\01\00\01\02\10\00\01\02\00\00\01\01\30\00\01\01\02\00\01\01\11\00\01\01\01\00\01\01\20\10\01\01\00\00\01\01\10\00\01\01\00\00\01\00\40\00\01\00\03\00\01\00\12\00\01\00\02\00\01\00\21\10\01\00\01\00\01\00\11\00\01\00\01\00\01\00\30\20\01\00\00\10\01\00\10\10\01\00\00\00\01\00\20\00\11\00\00\00\01\00\10\00\01\00\00\00\00\00\60\00\00\05\00\00\00\04\10\00\00\04\00\00\00\03\20\00\00\03\01\00\00\03\10\00\00\03\00\00\00\02\30\00\00\02\02\00\00\02\11\00\00\02\01\00\00\02\20\10\00\02\00\00\00\02\10\00\00\02\00\00\00\01\40\00\00\01\03\00\00\01\12\00\00\01\02\00\00\01\21\10\00\01\01\00\00\01\11\00\00\01\01\00\00\01\30\20\00\01\00\10\00\01\10\10\00\01\00\00\00\01\20\00\10\01\00\00\00\01\10\00\00\01\00\00\00\00\50\00\00\00\04\00\00\00\13\00\00\00\03\00\00\00\22\10\00\00\02\00\00\00\12\00\00\00\02\00\00\00\31\20\00\00\01\10\00\00\11\10\00\00\01\00\00\00\21\00\10\00\01\00\00\00\11\00\00\00\01\00\00\00\40\30\00\00\00\20\00\00\10\20\00\00\00\10\00\00\20\10\10\00\00\10\00\00\10\10\00\00\00\00\00\00\30\00\20\00\00\00\10\00\10\00\10\00\00\00\00\00\20\00\00\10\00\00\00\00\10\00\00\00\00")

  ;; Golomb-Rice length table at 0x00203400 (256 bytes)
  (global $RICE_LEN i32 (i32.const 0x00203400))
  (data (i32.const 0x00203400) "\00\01\01\02\01\02\02\03\01\02\02\03\02\03\03\04\01\02\02\03\02\03\03\04\02\03\03\04\03\04\04\05\01\02\02\03\02\03\03\04\02\03\03\04\03\04\04\05\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\01\02\02\03\02\03\03\04\02\03\03\04\03\04\04\05\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\03\04\04\05\04\05\05\06\04\05\05\06\05\06\06\07\01\02\02\03\02\03\03\04\02\03\03\04\03\04\04\05\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\03\04\04\05\04\05\05\06\04\05\05\06\05\06\06\07\02\03\03\04\03\04\04\05\03\04\04\05\04\05\05\06\03\04\04\05\04\05\05\06\04\05\05\06\05\06\06\07\03\04\04\05\04\05\05\06\04\05\05\06\05\06\06\07\04\05\05\06\05\06\06\07\05\06\06\07\06\07\07\08")

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

  ;; Scratch for Huffman NEW path
  (global $HUFF_NEW_CODELEN i32 (i32.const 0x00204000))  ;; 528 bytes
  (global $HUFF_NEW_RANGE   i32 (i32.const 0x00204210))  ;; 532 bytes

  ;; ── huff_read_code_lengths_new ─────────────────────────────
  ;; Read Huffman code lengths using NEW (Golomb-Rice) format.
  ;; Uses BR at 0x30. Returns numSymbols on success, -1 on error.
  (func $huff_read_code_lengths_new (result i32)
    (local $forcedBits i32) (local $numSymbols i32) (local $fluff i32) (local $totalRice i32)
    (local $i i32) (local $v i32) (local $runningSum i32)
    (local $ranges i32) (local $sym i32) (local $num i32) (local $cp i32)
    (local $codelen i32) (local $pfxIdx i32)

    (local.set $forcedBits (call $br_read_bits_no_refill (i32.const 2)))
    (local.set $numSymbols (i32.add (call $br_read_bits_no_refill (i32.const 8)) (i32.const 1)))
    (local.set $fluff (call $br_read_fluff (local.get $numSymbols)))

    (if (i32.or (i32.lt_s (local.get $fluff) (i32.const 0))
                (i32.gt_s (i32.add (local.get $numSymbols) (local.get $fluff)) (i32.const 512)))
      (then (return (i32.const -1)))
    )

    (local.set $totalRice (i32.add (local.get $numSymbols) (local.get $fluff)))

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
    (if (i32.eqz (call $decode_golomb_rice_lengths (global.get $HUFF_NEW_CODELEN) (local.get $totalRice)))
      (then (return (i32.const -1)))
    )
    ;; Zero padding
    (memory.fill (i32.add (global.get $HUFF_NEW_CODELEN) (local.get $totalRice)) (i32.const 0) (i32.const 16))

    ;; Decode precision bits
    (if (i32.eqz (call $decode_golomb_rice_bits (global.get $HUFF_NEW_CODELEN) (local.get $numSymbols) (local.get $forcedBits)))
      (then (return (i32.const -1)))
    )

    ;; Reset BR from GR state
    (i32.store (global.get $BR_BITPOS) (i32.const 24))
    (i32.store (global.get $BR_P) (i32.load (global.get $GR_P)))
    (i32.store (global.get $BR_BITS) (i32.const 0))
    (call $br_refill)
    (i32.store (global.get $BR_BITS)
      (i32.shl (i32.load (global.get $BR_BITS)) (i32.load (global.get $GR_BITPOS))))
    (i32.store (global.get $BR_BITPOS)
      (i32.add (i32.load (global.get $BR_BITPOS)) (i32.load (global.get $GR_BITPOS))))

    ;; Apply zigzag filter
    (local.set $runningSum (i32.const 0x1E))
    (local.set $i (i32.const 0))
    (block $filterDone
      (loop $filterLoop
        (br_if $filterDone (i32.ge_u (local.get $i) (local.get $numSymbols)))
        (local.set $v (i32.load8_u (i32.add (global.get $HUFF_NEW_CODELEN) (local.get $i))))
        (local.set $v (i32.xor
          (i32.sub (i32.const 0) (i32.and (local.get $v) (i32.const 1)))
          (i32.shr_u (local.get $v) (i32.const 1))))
        (local.set $codelen
          (i32.add (local.get $v)
            (i32.add (i32.shr_u (local.get $runningSum) (i32.const 2)) (i32.const 1))))
        (if (i32.or (i32.lt_s (local.get $codelen) (i32.const 1))
                    (i32.gt_s (local.get $codelen) (i32.const 11)))
          (then (return (i32.const -1)))
        )
        (i32.store8 (i32.add (global.get $HUFF_NEW_CODELEN) (local.get $i)) (local.get $codelen))
        (local.set $runningSum (i32.add (local.get $runningSum) (local.get $v)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $filterLoop)
      )
    )

    ;; ConvertToRanges
    (local.set $ranges
      (call $huff_convert_to_ranges
        (global.get $HUFF_NEW_RANGE)
        (local.get $numSymbols)
        (local.get $fluff)
        (i32.add (global.get $HUFF_NEW_CODELEN) (local.get $numSymbols))))
    (if (i32.le_s (local.get $ranges) (i32.const 0))
      (then (return (i32.const -1)))
    )

    ;; Build syms from ranges and code lengths
    (local.set $cp (global.get $HUFF_NEW_CODELEN))
    (local.set $i (i32.const 0))
    (block $buildDone
      (loop $buildLoop
        (br_if $buildDone (i32.ge_u (local.get $i) (local.get $ranges)))
        (local.set $sym
          (i32.load16_u (i32.add (global.get $HUFF_NEW_RANGE) (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $num
          (i32.load16_u (i32.add (i32.add (global.get $HUFF_NEW_RANGE) (i32.shl (local.get $i) (i32.const 2))) (i32.const 2))))
        (block $symDone
          (loop $symLoop
            (br_if $symDone (i32.le_s (local.get $num) (i32.const 0)))
            ;; syms[codePrefixCur[*cp]++] = sym
            (local.set $codelen (i32.load8_u (local.get $cp)))
            (local.set $cp (i32.add (local.get $cp) (i32.const 1)))
            (local.set $pfxIdx
              (i32.load (i32.add (global.get $HUFF_PFXCUR) (i32.shl (local.get $codelen) (i32.const 2)))))
            (i32.store8 (i32.add (global.get $HUFF_SYMS) (local.get $pfxIdx)) (local.get $sym))
            (i32.store (i32.add (global.get $HUFF_PFXCUR) (i32.shl (local.get $codelen) (i32.const 2)))
              (i32.add (local.get $pfxIdx) (i32.const 1)))
            (local.set $sym (i32.add (local.get $sym) (i32.const 1)))
            (local.set $num (i32.sub (local.get $num) (i32.const 1)))
            (br $symLoop)
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $buildLoop)
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
    (param $type i32)
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
    (memory.copy (global.get $HUFF_PFXORG) (i32.const 0x00202540) (i32.const 48))

    ;; Read first bit: 0 = old path
    (if (i32.eqz (call $br_read_bits_no_refill (i32.const 1)))
      (then
        (local.set $numSyms (call $huff_read_code_lengths_old))
      )
      (else
        ;; bit1: 0 = new (Golomb-Rice) path
        (if (i32.eqz (call $br_read_bits_no_refill (i32.const 1)))
          (then
            (local.set $numSyms (call $huff_read_code_lengths_new))
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
        (return (local.get $srcSize))
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
    (local.get $srcSize)
  )

