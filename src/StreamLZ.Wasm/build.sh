#!/bin/bash
# Build the StreamLZ WASM decompressor from WAT source files.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAT_DIR="$SCRIPT_DIR/wat"
OUT_WAT="$SCRIPT_DIR/slz-decompress.wat"
OUT_WASM="$SCRIPT_DIR/slz-decompress.wasm"

# Concatenate WAT source files in order
cat \
  "$WAT_DIR"/000-module.wat \
  "$WAT_DIR"/010-frame.wat \
  "$WAT_DIR"/020-bitreader.wat \
  "$WAT_DIR"/030-copy.wat \
  "$WAT_DIR"/040-entropy.wat \
  "$WAT_DIR"/050-huffman.wat \
  "$WAT_DIR"/060-tans.wat \
  "$WAT_DIR"/070-golomb-rice.wat \
  "$WAT_DIR"/080-fast-lz.wat \
  "$WAT_DIR"/090-high-lz.wat \
  "$WAT_DIR"/100-decompress.wat \
  "$WAT_DIR"/900-data.wat \
  > "$OUT_WAT"

wat2wasm "$OUT_WAT" -o "$OUT_WASM" --debug-names
echo "Built slz-decompress.wasm ($(wc -c < "$OUT_WASM") bytes)"
