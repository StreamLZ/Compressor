(module
  ;; ============================================================
  ;; StreamLZ WASM Decompressor
  ;; Hand-coded WAT — all levels L1-L11, SIMD128, parallel L6-L8
  ;; ============================================================
  ;;
  ;; Memory layout (64 KB pages):
  ;;   0x00000000 .. 0x000000FF  —  Header globals, bit readers, LZ table
  ;;   0x00100000 .. 0x003FFFFF  —  Scratch, LUTs, tANS, High LZ (~3 MB)
  ;;   0x00400000 .. INPUT_END   —  Input buffer (dynamic size)
  ;;   OUTPUT_BASE .. OUTPUT_END —  Output buffer (dynamic size)
  ;;
  ;; INPUT_BASE is fixed at 0x400000 (4 MB). OUTPUT_BASE is set by
  ;; JS via setOutputBase() before calling decompress(). JS grows
  ;; memory as needed for large files.
  ;; ============================================================

  (memory (import "env" "memory") 128 65536 shared)  ;; shared, JS-created, 8 MB initial, 4 GB max
  (export "memory" (memory 0))

  ;; ── Constants ──────────────────────────────────────────────
  ;; Frame magic: 'S','L','Z','1' = 0x534C5A31 written as LE bytes 31 5A 4C 53
  ;; i32.load reads LE, so we compare against 0x534C5A31
  (global $SLZ1_MAGIC i32 (i32.const 0x534C5A31))
  (global $FRAME_VERSION i32 (i32.const 1))
  (global $TRACE (mut i32) (i32.const 0))
  (func (export "getTrace") (result i32) (global.get $TRACE))

  ;; Memory region base addresses
  (global $INPUT_BASE  i32 (i32.const 0x00400000))
  (global $OUTPUT_BASE (mut i32) (i32.const 0x00800000))

  ;; Set output base address (called by JS for large files)
  (func (export "setOutputBase") (param $base i32)
    (global.set $OUTPUT_BASE (local.get $base))
  )
  (global $LUT_BASE    i32 (i32.const 0x00100100))
  (global $SCRATCH_BASE i32 (i32.const 0x00101100))

  ;; Parsed header fields (stored at address 0x00..0xFF)
  ;; Offsets within the scratch/header region:
  (global $HDR_VERSION  i32 (i32.const 0x00))  ;; u8
  (global $HDR_FLAGS    i32 (i32.const 0x01))  ;; u8
  (global $HDR_CODEC    i32 (i32.const 0x02))  ;; u8
  (global $HDR_LEVEL    i32 (i32.const 0x03))  ;; u8
  (global $HDR_BLOCKSIZE i32 (i32.const 0x04)) ;; i32
  (global $HDR_CONTENTSIZE i32 (i32.const 0x08)) ;; i64 (8 bytes)
  (global $HDR_HEADERSIZE i32 (i32.const 0x10))  ;; i32
  (global $HDR_DICTID   i32 (i32.const 0x14))  ;; u32

  ;; Flag bits
  (global $FLAG_CONTENT_SIZE i32 (i32.const 1))
  (global $FLAG_CONTENT_CHECKSUM i32 (i32.const 2))
  (global $FLAG_BLOCK_CHECKSUMS i32 (i32.const 4))
  (global $FLAG_DICT_ID i32 (i32.const 8))

  ;; Block header constants
  (global $BLOCK_UNCOMPRESSED_FLAG i32 (i32.const 0x80000000))
  (global $MIN_BLOCK_SIZE_LOG2 i32 (i32.const 16))  ;; log2(64KB)

  ;; ── Exported getters for test harness ──────────────────────

  (func (export "getVersion") (result i32)
    (i32.load8_u (global.get $HDR_VERSION))
  )
  (func (export "getFlags") (result i32)
    (i32.load8_u (global.get $HDR_FLAGS))
  )
  (func (export "getCodec") (result i32)
    (i32.load8_u (global.get $HDR_CODEC))
  )
  (func (export "getLevel") (result i32)
    (i32.load8_u (global.get $HDR_LEVEL))
  )
  (func (export "getBlockSize") (result i32)
    (i32.load (global.get $HDR_BLOCKSIZE))
  )
  (func (export "getContentSize") (result i64)
    (i64.load (global.get $HDR_CONTENTSIZE))
  )
  (func (export "getHeaderSize") (result i32)
    (i32.load (global.get $HDR_HEADERSIZE))
  )
  (func (export "getDictId") (result i32)
    (i32.load (global.get $HDR_DICTID))
  )
  (func (export "getInputBase") (result i32)
    (global.get $INPUT_BASE)
  )
  (func (export "getOutputBase") (result i32)
    (global.get $OUTPUT_BASE)
  )

  ;; ── parseFrameHeader ───────────────────────────────────────
  ;; Parses the SLZ1 frame header from the input buffer.
  ;; Parameters:
  ;;   inputLen — number of bytes available in the input buffer
  ;; Returns:
  ;;   header size in bytes on success, -1 on failure
  ;; Parsed fields are stored at addresses 0x00..0x1F.
