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

