#!/bin/bash
# Build the StreamLZ WASM decompressor from WAT source.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
wat2wasm "$SCRIPT_DIR/slz-decompress.wat" -o "$SCRIPT_DIR/slz-decompress.wasm" --debug-names
echo "Built slz-decompress.wasm ($(wc -c < "$SCRIPT_DIR/slz-decompress.wasm") bytes)"
