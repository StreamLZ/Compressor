  ;; ── 030-copy: SIMD copy primitives and helpers ─────────────
  ;; Functions: $copy64, $copy128, $wildcopy16, $read_be24,
  ;;            $match_copy, $decode_far_offsets, $combine_off16

  ;; ── copy64 ─────────────────────────────────────────────────
  ;; Copy 8 bytes (may overlap for match copies with offset >= 8).
  (func $copy64 (param $dst i32) (param $src i32)
    (i64.store (local.get $dst) (i64.load (local.get $src)))
  )

  ;; ── copy128 ────────────────────────────────────────────────
  ;; Copy 16 bytes using SIMD v128.
  (func $copy128 (param $dst i32) (param $src i32)
    (v128.store (local.get $dst) (v128.load (local.get $src)))
  )

  ;; ── wildcopy16 ─────────────────────────────────────────────
  ;; Copy bytes in 16-byte chunks until dst >= dstEnd.
  (func $wildcopy16 (param $dst i32) (param $src i32) (param $dstEnd i32)
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $dst) (local.get $dstEnd)))
        (v128.store (local.get $dst) (v128.load (local.get $src)))
        (local.set $dst (i32.add (local.get $dst) (i32.const 16)))
        (local.set $src (i32.add (local.get $src) (i32.const 16)))
        (br $loop)
      )
    )
  )

  ;; ── read_be24 ────────────────────────────────────────────────
  ;; Read 3-byte big-endian value from memory address.
  ;; Loads 4 bytes LE, byte-swaps to BE, shifts right 8 to get top 3 bytes.
  (func $read_be24 (param $addr i32) (result i32)
    (i32.shr_u (call $huff_bswap32 (i32.load (local.get $addr))) (i32.const 8))
  )

  ;; ── match_copy ───────────────────────────────────────────────
  ;; Copy match bytes: SIMD wildcopy if offset >= 16, else byte-at-a-time
  ;; for overlapping matches. Used by both Fast and High decoders.
  (func $match_copy (param $dst i32) (param $src i32) (param $len i32)
    (local $i i32)
    (if (i32.ge_u (i32.sub (local.get $dst) (local.get $src)) (i32.const 16))
      (then
        (call $wildcopy16 (local.get $dst) (local.get $src)
          (i32.add (local.get $dst) (local.get $len)))
      )
      (else
        (local.set $i (i32.const 0))
        (block $done (loop $loop
          (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
          (i32.store8 (i32.add (local.get $dst) (local.get $i))
            (i32.load8_u (i32.add (local.get $src) (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)))
      )
    )
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

