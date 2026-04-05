  ;; ── 040-entropy: Entropy stream dispatcher ─────────────────
  ;; Functions: $high_decode_bytes (dispatcher), $high_decode_recursive,
  ;;            $high_decode_rle
  ;; Dispatches: type 0=memcopy, 1=tANS, 2/4=Huffman, 3=RLE, 5=recursive
  ;; Writes: ENT_DECODED_SIZE at 0x50
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
            (local.set $srcSize (call $read_be24 (local.get $src)))
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
        (local.set $bits (call $read_be24 (local.get $src)))
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
    ;; Dispatch to sub-decoders. Each returns srcSize on success, -1 on error.
    ;; We then compute total consumed = src + srcSize - srcStart.
    (local.set $bits (i32.const -1))  ;; reuse $bits as sub-decoder result

    ;; Type 5: recursive
    (if (i32.eq (local.get $chunkType) (i32.const 5))
      (then
        (local.set $bits
          (call $high_decode_recursive
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)))
      )
    )
    ;; Type 3: RLE
    (if (i32.eq (local.get $chunkType) (i32.const 3))
      (then
        (local.set $bits
          (call $high_decode_rle
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)))
      )
    )
    ;; Types 2/4: Huffman
    (if (i32.or (i32.eq (local.get $chunkType) (i32.const 2))
                (i32.eq (local.get $chunkType) (i32.const 4)))
      (then
        (local.set $bits
          (call $high_decode_huff
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)
            (i32.shr_u (local.get $chunkType) (i32.const 1))))
      )
    )
    ;; Type 1: tANS
    (if (i32.eq (local.get $chunkType) (i32.const 1))
      (then
        (local.set $bits
          (call $high_decode_tans
            (local.get $src) (local.get $srcSize)
            (local.get $dst) (local.get $dstSize)))
      )
    )

    ;; Check result
    (if (i32.lt_s (local.get $bits) (i32.const 0))
      (then (return (i32.const -1)))
    )

    ;; Return total consumed: src + srcSize - srcStart
    (i32.sub (i32.add (local.get $src) (local.get $srcSize)) (local.get $srcStart))
  )

  ;; ── high_decode_recursive ──────────────────────────────────
  ;; Decode a recursive entropy block (type 5, simple variant).
  ;; Reads N sub-blocks, decoding each with high_decode_bytes.
  ;; Returns srcSize on success, or -1 on error.
  (func $high_decode_recursive
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
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

    ;; Return srcSize on success
    (local.get $srcSize)
  )

  ;; ── high_decode_rle ────────────────────────────────────────
  ;; RLE decoder (entropy type 3).
  ;; Commands read backwards from end, literals forward from front.
  ;; Returns srcSize on success, or -1 on error.
  (func $high_decode_rle
    (param $src i32) (param $srcSize i32)
    (param $dst i32) (param $dstSize i32)
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
        (return (local.get $srcSize))
      )
    )

    (local.set $dstEnd (i32.add (local.get $dst) (local.get $dstSize)))

    ;; Check if command buffer is entropy-coded (src[0] != 0)
    (i32.store (i32.const 0xB4) (i32.const 0))
    (if (i32.ne (i32.load8_u (local.get $src)) (i32.const 0))
      (then
        ;; Decode the entropy-coded prefix into a scratch buffer
        ;; Use a scratch area past DECODE_SCRATCH + 256KB = 0x00141100
        (local.set $cmdPtr (i32.const 0x00181100))
        (global.set $TRACE (i32.const 0xE0))
        (local.set $data  ;; reuse $data as temp for decoded count
          (call $high_decode_bytes
            (local.get $src)
            (i32.add (local.get $src) (local.get $srcSize))
            (local.get $cmdPtr)
            (i32.const 0x40000)))  ;; max 256KB
        (global.set $TRACE (i32.add (i32.const 0xE000) (local.get $data)))
        (if (i32.lt_s (local.get $data) (i32.const 0))
          (then (return (i32.const -1)))
        )
        ;; Decoded prefix is at $cmdPtr, decSize bytes long
        ;; Remaining raw bytes: src + $data .. src + srcSize
        ;; Concatenate: [decoded prefix][remaining raw] into one buffer
        (local.set $bytesToCopy (i32.load (global.get $ENT_DECODED_SIZE)))
        (local.set $bytesToRle (i32.sub (local.get $srcSize) (local.get $data)))
        ;; Trace: prefix decoded ok
        (i32.store (i32.const 0xB4) (i32.const 1))
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
    (local.get $srcSize)
  )

