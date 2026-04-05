// Test the production StreamLZ WASM API
import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { performance } from 'perf_hooks';
import { decompress, shutdown } from './slz.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const dir = resolve(__dirname, 'test-vectors');

function assert(cond, msg) { if (!cond) { console.error('FAIL:', msg); process.exit(1); } }

async function testVector(name, threads) {
  const slzPath = resolve(dir, name + '.slz');
  const rawPath = resolve(dir, name + '.raw');
  try {
    const compressed = readFileSync(slzPath);
    const expected = readFileSync(rawPath);
    const result = await decompress(compressed, { threads });
    assert(result.length === expected.length, `${name}: size mismatch ${result.length} vs ${expected.length}`);
    for (let i = 0; i < expected.length; i++) {
      assert(result[i] === expected[i], `${name}: mismatch at byte ${i}`);
    }
    return true;
  } catch (e) {
    if (e.code === 'ENOENT') return null; // skip missing
    throw e;
  }
}

async function bench(name, threads, iters) {
  const compressed = readFileSync(resolve(dir, name + '.slz'));
  // Warmup
  await decompress(compressed, { threads });
  const t0 = performance.now();
  let size = 0;
  for (let i = 0; i < iters; i++) {
    const r = await decompress(compressed, { threads });
    size = r.length;
  }
  const elapsed = performance.now() - t0;
  return { mbps: (size * iters / (elapsed / 1000) / 1e6).toFixed(0), ms: (elapsed / iters).toFixed(1) };
}

async function main() {
  console.log('=== StreamLZ WASM API Tests ===\n');

  // Correctness tests
  const tests = [
    ['empty', 1], ['onebyte', 1], ['zeros1k', 1],
    ['pattern64k', 1], ['text', 1], ['web', 1],
    ['enwik8', 1],           // L1 single-threaded
    ['enwik8_l6', 1],        // L6 single-threaded
    ['enwik8_l6', 0],        // L6 auto-parallel
    ['enwik8_l9', 1],        // L9 single-threaded
    ['silesia100m', 1],      // L1 silesia
    ['silesia100m_l6', 0],   // L6 silesia parallel
    ['silesia100m_l9', 1],   // L9 silesia
  ];

  for (const [name, threads] of tests) {
    const r = await testVector(name, threads);
    if (r === null) { console.log(`  SKIP: ${name}`); continue; }
    const mode = threads === 0 ? 'parallel' : threads + 'T';
    console.log(`  ${name} (${mode}): PASS`);
  }

  // Benchmarks
  console.log('\n=== Benchmarks (enwik8 100MB) ===\n');

  const b1 = await bench('enwik8', 1, 3);
  console.log(`  L1  1-thread:  ${b1.mbps} MB/s`);

  const b6s = await bench('enwik8_l6', 1, 3);
  console.log(`  L6  1-thread:  ${b6s.mbps} MB/s`);

  const b6p = await bench('enwik8_l6', 0, 3);
  console.log(`  L6  parallel:  ${b6p.mbps} MB/s`);

  const b9 = await bench('enwik8_l9', 1, 3);
  console.log(`  L9  1-thread:  ${b9.mbps} MB/s`);

  shutdown();
  console.log('\nDone.');
}

main().catch(e => { console.error(e); process.exit(1); });
