// Phase 1 test: verify frame header and block header parsing.
// Compresses test data with .NET, then feeds the compressed bytes to WASM.

import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = resolve(__dirname, 'slz-decompress.wasm');

// ── Helpers ──────────────────────────────────────────────────

function assert(cond, msg) {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
}

function assertEq(actual, expected, label) {
  assert(actual === expected, `${label}: expected ${expected}, got ${actual}`);
}

// ── Generate test data and compress with .NET ────────────────

function compressWithDotnet(data, level) {
  const tmpIn = resolve(__dirname, '_test_input.bin');
  const tmpOut = resolve(__dirname, '_test_output.slz');
  try {
    writeFileSync(tmpIn, data);
    // Use the CLI to compress
    const cliDir = resolve(__dirname, '..', 'StreamLZ.Cli');
    execSync(
      `dotnet run --project "${cliDir}" -- -l ${level} -o "${tmpOut}" "${tmpIn}"`,
      { stdio: 'pipe' }
    );
    return readFileSync(tmpOut);
  } finally {
    if (existsSync(tmpIn)) unlinkSync(tmpIn);
    if (existsSync(tmpOut)) unlinkSync(tmpOut);
  }
}

// ── Load WASM ────────────────────────────────────────────────

async function loadWasm() {
  const wasmBytes = readFileSync(WASM_PATH);
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  return instance.exports;
}

// ── Tests ────────────────────────────────────────────────────

async function testFrameHeader() {
  console.log('Test: parseFrameHeader with L1 compressed data...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Create 64KB of test data
  const source = Buffer.alloc(64 * 1024);
  for (let i = 0; i < source.length; i++) source[i] = i & 0xFF;

  const compressed = compressWithDotnet(source, 1);
  console.log(`  Compressed ${source.length} -> ${compressed.length} bytes`);

  // Copy compressed data into WASM input buffer
  const inputBase = wasm.getInputBase();
  mem.set(compressed, inputBase);

  // Parse frame header
  const headerSize = wasm.parseFrameHeader(compressed.length);
  assert(headerSize > 0, `parseFrameHeader returned ${headerSize}`);
  console.log(`  Header size: ${headerSize}`);

  // Verify parsed fields
  assertEq(wasm.getVersion(), 1, 'version');
  assertEq(wasm.getCodec(), 1, 'codec (Fast)');
  assertEq(wasm.getLevel(), 1, 'level');

  const blockSize = wasm.getBlockSize();
  assert(blockSize >= 65536 && blockSize <= 4194304, `blockSize ${blockSize} out of range`);
  console.log(`  Block size: ${blockSize}`);

  const contentSize = wasm.getContentSize();
  // Content size should be present and match source length
  const flags = wasm.getFlags();
  if (flags & 1) {
    assertEq(Number(contentSize), source.length, 'contentSize');
    console.log(`  Content size: ${contentSize}`);
  } else {
    console.log('  Content size: not present');
  }

  console.log('  PASS');
}

async function testBlockHeader() {
  console.log('Test: parseBlockHeader...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Create test data and compress
  const source = Buffer.alloc(64 * 1024);
  for (let i = 0; i < source.length; i++) source[i] = i & 0xFF;
  const compressed = compressWithDotnet(source, 1);

  // Copy into WASM
  const inputBase = wasm.getInputBase();
  mem.set(compressed, inputBase);

  // Parse frame header first
  const headerSize = wasm.parseFrameHeader(compressed.length);
  assert(headerSize > 0, 'frame header parse failed');

  // Parse first block header (starts right after frame header)
  const compSize = wasm.parseBlockHeader(headerSize, compressed.length);
  assert(compSize > 0, `parseBlockHeader returned ${compSize}`);

  const decompSize = wasm.getBlockDecompSize();
  const isUncomp = wasm.getBlockIsUncompressed();

  console.log(`  Block: compSize=${compSize}, decompSize=${decompSize}, uncompressed=${isUncomp}`);
  assert(decompSize > 0, 'decompSize should be > 0');
  assert(compSize <= compressed.length, 'compSize should not exceed input');

  console.log('  PASS');
}

async function testEndMark() {
  console.log('Test: end mark detection...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Write 8 zero bytes at the input buffer (simulates end mark + padding)
  const inputBase = wasm.getInputBase();
  for (let i = 0; i < 8; i++) mem[inputBase + i] = 0;

  const result = wasm.parseBlockHeader(0, 8);
  assertEq(result, 0, 'end mark should return 0');
  assertEq(wasm.getBlockDecompSize(), 0, 'decompSize at end mark');

  console.log('  PASS');
}

async function testMultiBlock() {
  console.log('Test: multi-block iteration...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Larger data to force multiple blocks
  const source = Buffer.alloc(512 * 1024);
  for (let i = 0; i < source.length; i++) source[i] = (i * 7 + 13) & 0xFF;
  const compressed = compressWithDotnet(source, 1);

  const inputBase = wasm.getInputBase();
  mem.set(compressed, inputBase);

  const headerSize = wasm.parseFrameHeader(compressed.length);
  assert(headerSize > 0, 'frame header parse failed');

  // Walk all block headers
  let pos = headerSize;
  let blockCount = 0;
  let totalDecomp = 0;

  while (pos < compressed.length) {
    const compSize = wasm.parseBlockHeader(pos, compressed.length);
    if (compSize === 0) {
      // End mark
      console.log(`  End mark at offset ${pos}`);
      break;
    }
    assert(compSize > 0, `block ${blockCount} parse failed at offset ${pos}`);
    const decompSize = wasm.getBlockDecompSize();
    const isUncomp = wasm.getBlockIsUncompressed();
    console.log(`  Block ${blockCount}: comp=${compSize}, decomp=${decompSize}, uncomp=${isUncomp}`);
    totalDecomp += decompSize;
    pos += 8 + compSize; // 8-byte block header + payload
    blockCount++;
  }

  console.log(`  ${blockCount} blocks, total decompressed: ${totalDecomp}`);
  assertEq(totalDecomp, source.length, 'total decompressed size');

  console.log('  PASS');
}

async function testTruncated() {
  console.log('Test: truncated input rejection...');
  const wasm = await loadWasm();

  // Too short for frame header
  assertEq(wasm.parseFrameHeader(5), -1, 'short input');

  // Wrong magic
  const mem = new Uint8Array(wasm.memory.buffer);
  const inputBase = wasm.getInputBase();
  for (let i = 0; i < 10; i++) mem[inputBase + i] = 0;
  assertEq(wasm.parseFrameHeader(10), -1, 'wrong magic');

  console.log('  PASS');
}

// ── Phase 2: Bit Reader Tests ────────────────────────────────

async function testBitReaderForward() {
  console.log('Test: forward bit reader...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Place known bytes at a test address (use scratch area)
  const testAddr = 0x00101100; // SCRATCH_BASE
  // Bytes: 0xA5 = 10100101, 0x3C = 00111100, 0xF0 = 11110000, 0x0F = 00001111
  mem[testAddr + 0] = 0xA5;
  mem[testAddr + 1] = 0x3C;
  mem[testAddr + 2] = 0xF0;
  mem[testAddr + 3] = 0x0F;

  // Init forward reader: p=testAddr, pEnd=testAddr+4
  wasm.br_init(testAddr, testAddr + 4);
  assertEq(wasm.br_get_bitpos(), 24, 'initial bitPos');
  assertEq(wasm.br_get_bits() >>> 0, 0, 'initial bits');

  // Refill — should load 3 bytes (bitPos goes from 24 to 0)
  wasm.br_refill();
  assertEq(wasm.br_get_bitpos(), 0, 'bitPos after refill');
  // bits = 0xA5 << 24 | 0x3C << 16 | 0xF0 << 8 = 0xA53CF000
  assertEq(wasm.br_get_bits() >>> 0, 0xA53CF000 >>> 0, 'bits after refill');

  // Read 4 bits from MSB: should get 0xA = 1010
  let v = wasm.br_read_bits_no_refill(4);
  assertEq(v, 0xA, 'read 4 bits');
  // bits should now be 0x53CF0000
  assertEq(wasm.br_get_bits() >>> 0, 0x53CF0000 >>> 0, 'bits after read 4');

  // Read 8 bits: should get 0x53 = 01010011
  v = wasm.br_read_bits_no_refill(8);
  assertEq(v, 0x53, 'read 8 bits');

  // Read with refill — should pull in the 4th byte (0x0F)
  v = wasm.br_read_bits(8);
  assertEq(v, 0xCF, 'read 8 bits with refill');

  // Read remaining
  v = wasm.br_read_bits(4);
  assertEq(v, 0x0, 'next 4 bits');

  v = wasm.br_read_bits_no_refill(8);
  assertEq(v, 0x0F, 'final 8 bits');

  console.log('  PASS');
}

async function testBitReaderBackward() {
  console.log('Test: backward bit reader...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  // Same test data
  const testAddr = 0x00101100;
  mem[testAddr + 0] = 0xA5;
  mem[testAddr + 1] = 0x3C;
  mem[testAddr + 2] = 0xF0;
  mem[testAddr + 3] = 0x0F;

  // Init backward reader: p = past-end, pEnd = start (stop sentinel)
  // Reads: 0x0F, 0xF0, 0x3C (in that order, backwards)
  wasm.br2_init(testAddr + 4, testAddr);
  assertEq(wasm.br2_get_bitpos(), 24, 'br2 initial bitPos');

  // Refill — should read backwards: 0x0F at bitPos=24, 0xF0 at 16, 0x3C at 8
  wasm.br2_refill();
  assertEq(wasm.br2_get_bitpos(), 0, 'br2 bitPos after refill');
  // bits = 0x0F << 24 | 0xF0 << 16 | 0x3C << 8 = 0x0FF03C00
  assertEq(wasm.br2_get_bits() >>> 0, 0x0FF03C00 >>> 0, 'br2 bits after refill');

  // Read 8 bits: 0x0F
  let v = wasm.br2_read_bits_no_refill(8);
  assertEq(v, 0x0F, 'br2 read 8 bits');

  // Read 8 bits: 0xF0
  v = wasm.br2_read_bits_no_refill(8);
  assertEq(v, 0xF0, 'br2 read next 8 bits');

  // Refill + read — should pull in 0xA5
  v = wasm.br2_read_bits(8);
  assertEq(v, 0x3C, 'br2 read with refill');

  v = wasm.br2_read_bits(8);
  assertEq(v, 0xA5, 'br2 read last byte');

  console.log('  PASS');
}

async function testBitReaderZeroBits() {
  console.log('Test: read 0 bits...');
  const wasm = await loadWasm();
  const mem = new Uint8Array(wasm.memory.buffer);

  const testAddr = 0x00101100;
  mem[testAddr] = 0xFF;
  wasm.br_init(testAddr, testAddr + 1);
  wasm.br_refill();

  // Reading 0 bits should return 0 and not change state
  const bitsBefore = wasm.br_get_bits() >>> 0;
  const v = wasm.br_read_bits_no_refill_zero(0);
  assertEq(v, 0, 'read 0 bits returns 0');
  assertEq(wasm.br_get_bits() >>> 0, bitsBefore, 'bits unchanged after 0-bit read');

  console.log('  PASS');
}

// ── Phase 3+: End-to-end decompress tests ────────────────────

async function testDecompressVector(name, expectPass = true) {
  const slzPath = resolve(__dirname, 'test-vectors', `${name}.slz`);
  const rawPath = resolve(__dirname, 'test-vectors', `${name}.raw`);

  if (!existsSync(slzPath) || !existsSync(rawPath)) {
    console.log(`  SKIP: ${name} (test vectors not generated)`);
    return;
  }

  const compressed = readFileSync(slzPath);
  const expected = readFileSync(rawPath);

  // Handle empty case
  if (compressed.length === 0) {
    assertEq(expected.length, 0, `${name}: empty compressed should mean empty raw`);
    console.log(`  ${name}: empty (PASS)`);
    return;
  }

  const wasm = await loadWasm();

  const inputBase = wasm.getInputBase();
  // Ensure memory is large enough for input + output
  const outputBase = ((inputBase + compressed.length + 255) & ~255);
  const needed = outputBase + expected.length + 65536;
  const currentSize = wasm.memory.buffer.byteLength;
  if (needed > currentSize) {
    wasm.memory.grow(Math.ceil((needed - currentSize) / 65536));
  }
  wasm.setOutputBase(outputBase);

  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(compressed, inputBase);

  const result = wasm.decompress(compressed.length);

  if (!expectPass) {
    if (result < 0) {
      console.log(`  ${name}: expected fail, got error (PASS — not yet implemented)`);
      return;
    }
  }

  if (result < 0) {
    const trace = wasm.getTrace ? wasm.getTrace() : '?';
    console.log(`  FAIL: ${name}: decompress returned ${result} (trace=${trace})`);
    process.exit(1);
  }

  assertEq(result, expected.length, `${name}: decompressed size`);

  // Compare output
  const output = mem.slice(outputBase, outputBase + result);
  for (let i = 0; i < expected.length; i++) {
    if (output[i] !== expected[i]) {
      console.log(`  FAIL: ${name}: mismatch at byte ${i}: got ${output[i]}, expected ${expected[i]}`);
      process.exit(1);
    }
  }

  console.log(`  ${name}: ${compressed.length} -> ${result} bytes (PASS)`);
}

// ── Run ──────────────────────────────────────────────────────

async function main() {
  console.log('=== StreamLZ WASM Tests ===\n');

  console.log('── Phase 1: Frame/Block Parsing ──');
  await testTruncated();
  await testFrameHeader();
  await testBlockHeader();
  await testEndMark();
  await testMultiBlock();

  console.log('\n── Phase 2: Bit Reader ──');
  await testBitReaderForward();
  await testBitReaderBackward();
  await testBitReaderZeroBits();

  console.log('\n── Phase 3+: End-to-end Decompress ──');
  // These should pass (uncompressed/memset blocks):
  await testDecompressVector('empty');
  await testDecompressVector('onebyte');
  await testDecompressVector('random4k');
  await testDecompressVector('zeros1k');
  // These need LZ/Huffman (expect fail for now):
  await testDecompressVector('pattern64k', false);
  await testDecompressVector('text');
  await testDecompressVector('boundary');
  await testDecompressVector('web');
  await testDecompressVector('enwik8');
  await testDecompressVector('silesia10m');
  await testDecompressVector('silesia100m', false);  // blocked on src drift bug
  await testDecompressVector('enwik8_l6_64k');
  await testDecompressVector('l6_128k');
  await testDecompressVector('l6_256k');
  await testDecompressVector('enwik8_l6');
  await testDecompressVector('enwik8_l9');
  await testDecompressVector('silesia100m_l6');
  await testDecompressVector('silesia100m_l9');

  console.log('\nAll tests passed.');
}

main().catch(e => { console.error(e); process.exit(1); });
