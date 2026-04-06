// StreamLZ WASM Decompressor — Universal API (Node + Browser)
// Supports L1-L11. L6-L8 SC auto-parallelized when SharedArrayBuffer available.

// ── Environment detection ────────────────────────────────────

const isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
const hasSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined';

let _wasmBytes = null;
let _wasmBytesPromise = null;
let _wasmModule = null;

async function getWasmBytes() {
  if (_wasmBytes) return _wasmBytes;
  if (_wasmBytesPromise) return _wasmBytesPromise;
  _wasmBytesPromise = (async () => {
    if (isNode) {
      const { readFileSync } = await import('fs');
      const { resolve, dirname } = await import('path');
      const { fileURLToPath } = await import('url');
      const __dirname = dirname(fileURLToPath(import.meta.url));
      _wasmBytes = readFileSync(resolve(__dirname, 'slz-decompress.wasm'));
    } else {
      _wasmBytes = null; // browser uses compileStreaming instead
    }
    return _wasmBytes;
  })();
  return _wasmBytesPromise;
}

async function getWasmModule() {
  if (_wasmModule) return _wasmModule;
  try {
    if (!isNode && typeof WebAssembly.compileStreaming === 'function') {
      // Browser: compile while downloading (faster cold start)
      _wasmModule = await WebAssembly.compileStreaming(
        fetch(new URL('slz-decompress.wasm', import.meta.url)));
    } else {
      const bytes = await getWasmBytes();
      _wasmModule = await WebAssembly.compile(bytes);
    }
  } catch (e) {
    if (e instanceof WebAssembly.CompileError) {
      throw new Error(
        'StreamLZ: WASM compilation failed. This module requires SIMD128 and bulk-memory support. ' +
        e.message);
    }
    throw e;
  }
  return _wasmModule;
}

// ── Frame scanner ────────────────────────────────────────────

function scanFrame(data) {
  if (data.length < 10) return null;
  const magic = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
  if (magic !== 0x534C5A31) return null;

  const flags = data[5];
  const codec = data[6];
  let pos = 10;
  let contentSize = -1;
  if (flags & 1) { contentSize = data[pos] | (data[pos+1]<<8) | (data[pos+2]<<16) | (data[pos+3]<<24); pos += 8; }
  const headerSize = pos;

  if (headerSize + 8 > data.length) return null;
  const blockCompSize = (data[headerSize] | (data[headerSize+1]<<8) | (data[headerSize+2]<<16) | (data[headerSize+3]<<24)) & 0x7FFFFFFF;
  const blockDecompSize = data[headerSize+4] | (data[headerSize+5]<<8) | (data[headerSize+6]<<16) | (data[headerSize+7]<<24);

  const slzPos = headerSize + 8;
  const isSC = !!(data[slzPos] & 0x10);

  let chunks = null;
  let prefixBase = 0;
  if (isSC && codec === 0) {
    chunks = [];
    let p = slzPos;
    let dstOff = 0;
    while (dstOff < blockDecompSize && p < data.length - 4) {
      const chunkStart = p;
      const b0 = data[p];
      const isUncomp = !!(b0 & 0x80);
      p += 2;
      const chunkDstSize = Math.min(262144, blockDecompSize - dstOff);
      if (isUncomp) {
        chunks.push({ srcOffset: chunkStart, srcLen: 2 + chunkDstSize, dstOffset: dstOff, dstSize: chunkDstSize, isUncomp: true });
        p += chunkDstSize;
      } else {
        const hdr = data[p] | (data[p+1]<<8) | (data[p+2]<<16) | (data[p+3]<<24);
        const compSz = (hdr & 0x3FFFF) + 1;
        const type = (hdr >> 18) & 3;
        if (type === 1) {
          chunks.push({ srcOffset: chunkStart, srcLen: 7, dstOffset: dstOff, dstSize: chunkDstSize, isMemset: true, fillByte: data[p + 4] });
          p += 5;
        } else {
          chunks.push({ srcOffset: chunkStart, srcLen: 2 + 4 + compSz, dstOffset: dstOff, dstSize: chunkDstSize });
          p += 4 + compSz;
        }
      }
      dstOff += chunkDstSize;
    }
    prefixBase = headerSize + 8 + blockCompSize - (chunks.length - 1) * 8;
  }

  // Non-SC High: scan sub-chunks for two-phase parallel
  let subChunks = null;
  // Non-SC High: scan 256KB chunk boundaries for two-phase parallel
  // Each chunk: 2-byte block header + 4-byte chunk header (contains total compressed size)
  // Phase 1 workers process entire chunks (both sub-chunks within)
  let twoPhaseChunks = null;
  if (!isSC && codec === 0 && blockDecompSize > 262144) {
    twoPhaseChunks = [];
    let p = slzPos;
    let dstOff = 0;
    while (dstOff < blockDecompSize && p + 6 <= data.length) {
      const b0 = data[p];
      if ((b0 & 0x0F) !== 5) break;
      const chunkDstSize = Math.min(262144, blockDecompSize - dstOff);
      if (b0 & 0x80) {
        // Uncompressed chunk
        twoPhaseChunks.push({ srcOffset: p, srcLen: 2 + chunkDstSize, dstOffset: dstOff, dstSize: chunkDstSize, isUncomp: true });
        p += 2 + chunkDstSize;
      } else {
        // Compressed chunk: read 4-byte chunk header after 2-byte block header
        const chunkHdr = data[p+2] | (data[p+3] << 8) | (data[p+4] << 16) | (data[p+5] << 24);
        const compSz = (chunkHdr & 0x3FFFF) + 1;
        const chunkType = (chunkHdr >> 18) & 3;
        if (chunkType === 1) {
          // Memset
          twoPhaseChunks.push({ srcOffset: p, srcLen: 7, dstOffset: dstOff, dstSize: chunkDstSize, isMemset: true, fillByte: data[p + 6] });
          p += 7;
        } else {
          // Normal compressed: block hdr(2) + chunk hdr(4) + payload(compSz)
          twoPhaseChunks.push({ srcOffset: p, srcLen: 2 + 4 + compSz, dstOffset: dstOff, dstSize: chunkDstSize });
          p += 2 + 4 + compSz;
        }
      }
      dstOff += chunkDstSize;
    }
    if (twoPhaseChunks.length < 2) twoPhaseChunks = null;
  }

  return { contentSize: blockDecompSize, codec, isSC, chunks, prefixBase, headerSize, twoPhaseChunks };
}

// ── Error messages ───────────────────────────────────────────

function getError(wasm, code) {
  const trace = wasm.getTrace ? wasm.getTrace() : 0;
  const errors = {
    '-2001': 'Sub-chunk header truncated',
    '-2010': 'Entropy decoder failed',
    '-2011': 'Entropy decoded size mismatch',
    '-2020': 'Compressed sub-chunk data truncated',
    '-2030': 'Fast LZ decoder failed',
    '-2031': 'High LZ decoder failed',
    '-3004': 'High LZ: literal entropy decode failed',
    '-3005': 'High LZ: command entropy decode failed',
    '-3008': 'High LZ: unsupported offset scaling mode',
    '-3009': 'High LZ: length entropy decode failed',
    '-3010': 'High LZ: u32 length stream decode failed',
    '-3011': 'High LZ: traditional offset decode failed',
  };
  return `StreamLZ decompress failed: ${errors[String(trace)] || `error ${trace}`}`;
}

// ── Worker pool ──────────────────────────────────────────────

class WorkerPool {
  constructor(size) {
    this.size = size;
    this.workers = [];
    this.available = [];
    this.queue = [];
  }

  async init() {
    const wasmModule = await getWasmModule();

    const spawns = [];
    for (let i = 0; i < this.size; i++) {
      spawns.push(this._spawnWorker(wasmModule));
    }
    // Don't await all — workers join available pool individually via _drain
    // But we need at least one ready before returning so dispatch works
    await Promise.race(spawns);
  }

  async _spawnWorker(wasmModule) {
    let worker;
    if (isNode) {
      const { Worker } = await import('worker_threads');
      const { resolve, dirname } = await import('path');
      const { fileURLToPath } = await import('url');
      worker = new Worker(resolve(dirname(fileURLToPath(import.meta.url)), 'slz-worker.js'), {
        workerData: { wasmModule }
      });
    } else {
      worker = new globalThis.Worker(new URL('slz-worker.js', import.meta.url));
      worker.postMessage({ type: 'init', wasmModule });
    }
    this.workers.push(worker);

    return new Promise((resolve) => {
      const onMsg = (msg) => {
        const data = msg.data || msg;
        if (data.type === 'ready') {
          this.available.push(worker);
          this._drain();
          resolve();
        } else if (data.type === 'done') {
          const cb = worker._callback;
          worker._callback = null;
          this.available.push(worker);
          if (cb) cb(data);
          this._drain();
        }
      };

      if (isNode) worker.on('message', onMsg);
      else worker.addEventListener('message', onMsg);
    });
  }

  dispatch(msg) {
    return new Promise((resolve) => {
      this.queue.push({ msg, resolve });
      this._drain();
    });
  }

  _drain() {
    while (this.queue.length > 0 && this.available.length > 0) {
      const worker = this.available.pop();
      const { msg, resolve } = this.queue.shift();
      worker._callback = resolve;
      worker.postMessage(msg);
    }
  }

  terminate() {
    for (const w of this.workers) w.terminate();
    this.workers = [];
    this.available = [];
  }
}

// ── Single-threaded decompress ───────────────────────────────

let _singleInstance = null;
let _sharedMemory = null;

function getSharedMemory() {
  if (!_sharedMemory) {
    _sharedMemory = new WebAssembly.Memory({ initial: 128, maximum: 65536, shared: true });
  }
  return _sharedMemory;
}

async function getSingleInstance() {
  if (!_singleInstance) {
    const module = await getWasmModule();
    const memory = getSharedMemory();
    const instance = await WebAssembly.instantiate(module, { env: { memory } });
    _singleInstance = instance.exports;
  }
  return _singleInstance;
}

const PAGE_SIZE = 65536;
const DEFAULT_MAX_DECOMPRESSED_SIZE = 1073741824; // 1 GB

function ensureCapacity(wasm, inputSize, outputSize) {
  const inputBase = wasm.getInputBase();
  // Place output right after input (aligned to 256 bytes)
  const outputBase = ((inputBase + inputSize + 255) & ~255);
  const needed = outputBase + outputSize + PAGE_SIZE;
  const currentSize = wasm.memory.buffer.byteLength;
  if (needed > currentSize) {
    try {
      wasm.memory.grow(Math.ceil((needed - currentSize) / PAGE_SIZE));
    } catch (e) {
      throw new Error(`StreamLZ: failed to allocate ${needed} bytes of WASM memory`);
    }
  }
  wasm.setOutputBase(outputBase);
}

function decompressSingle(data, contentSize) {
  const wasm = _singleInstance;
  ensureCapacity(wasm, data.length, contentSize || data.length * 4);
  const mem = new Uint8Array(wasm.memory.buffer);
  mem.set(data, wasm.getInputBase());
  const result = wasm.decompress(data.length);
  if (result < 0) throw new Error(getError(wasm, result));
  const outputBase = wasm.getOutputBase();
  return new Uint8Array(wasm.memory.buffer.slice(outputBase, outputBase + result));
}

// ── Parallel decompress (L6-L8 SC) ──────────────────────────

async function decompressParallel(data, frame, pool) {
  const { chunks, contentSize, prefixBase } = frame;
  const inputSAB = new SharedArrayBuffer(data.length);
  new Uint8Array(inputSAB).set(data);
  const outputSAB = new SharedArrayBuffer(contentSize);
  const output = new Uint8Array(outputSAB);

  const promises = [];
  for (let i = 0; i < chunks.length; i++) {
    const c = chunks[i];
    if (c.isUncomp) {
      output.set(data.subarray(c.srcOffset + 2, c.srcOffset + 2 + c.dstSize), c.dstOffset);
      continue;
    }
    if (c.isMemset) {
      output.fill(c.fillByte, c.dstOffset, c.dstOffset + c.dstSize);
      continue;
    }
    promises.push(pool.dispatch({
      type: 'decompress_chunk',
      inputSAB, inputOffset: c.srcOffset, inputLen: c.srcLen,
      outputSAB, outputOffset: c.dstOffset, dstSize: c.dstSize,
      chunkIndex: i
    }).then(result => {
      if (!result.ok) throw new Error(`Chunk ${i} failed (code ${result.error})`);
    }));
  }
  await Promise.all(promises);

  // Restore SC prefix bytes
  for (let i = 0; i < chunks.length - 1; i++) {
    const c = chunks[i + 1];
    output.set(data.subarray(prefixBase + i * 8, prefixBase + i * 8 + Math.min(8, c.dstSize)), c.dstOffset);
  }

  return new Uint8Array(outputSAB);
}

// ── Two-phase parallel decompress (L9-L11 non-SC) ───────────
// Phase 1 (parallel): workers run hlzPhase1 (entropy decode + offset unpack)
// Phase 2 (serial): main thread runs hlzPhase2 (token resolve + match copy)

const HLZ_SCRATCH_BASE = 0x00230000;
const HLZ_SCRATCH_SIZE = 0x00140020; // 0x230000 to 0x370020

async function decompressTwoPhase(data, frame, pool) {
  const { twoPhaseChunks, contentSize } = frame;
  await getSingleInstance();
  const wasm = _singleInstance;

  // Ensure main thread WASM has enough memory for full output
  ensureCapacity(wasm, data.length, contentSize);
  const inputBase = wasm.getInputBase();
  const outputBase = wasm.getOutputBase();

  // Copy compressed data to main WASM input buffer (for initial 8 bytes + stored sub-chunks)
  let mem = new Uint8Array(wasm.memory.buffer);
  mem.set(data, inputBase);

  // Shared input buffer for workers
  const inputSAB = new SharedArrayBuffer(data.length);
  new Uint8Array(inputSAB).set(data);

  // Partition chunks into coreCount groups (one dispatch per core)
  const coreCount = pool.size;
  const lzChunks = twoPhaseChunks.filter(c => !c.isUncomp && !c.isMemset);
  const groupSize = Math.ceil(lzChunks.length / coreCount);
  const numGroups = Math.min(coreCount, lzChunks.length);

  // Handle special chunks on main thread
  for (const c of twoPhaseChunks) {
    if (c.isUncomp) {
      mem = new Uint8Array(wasm.memory.buffer);
      mem.copyWithin(outputBase + c.dstOffset, inputBase + c.srcOffset + 2, inputBase + c.srcOffset + 2 + c.dstSize);
    } else if (c.isMemset) {
      mem = new Uint8Array(wasm.memory.buffer);
      mem.fill(c.fillByte, outputBase + c.dstOffset, outputBase + c.dstOffset + c.dstSize);
    }
  }

  // Each chunk has up to 2 sub-chunks. Allocate scratch per sub-chunk.
  const maxSCperGroup = groupSize * 2;
  const scratchSAB = new SharedArrayBuffer(numGroups * maxSCperGroup * HLZ_SCRATCH_SIZE);

  // Phase 1: dispatch one message per core
  const phase1Promises = [];
  const groupMeta = [];

  for (let g = 0; g < numGroups; g++) {
    const start = g * groupSize;
    const end = Math.min(start + groupSize, lzChunks.length);
    const group = [];
    for (let k = start; k < end; k++) {
      const c = lzChunks[k];
      // Pass chunk data (block hdr + chunk hdr + payload) for Phase 1
      group.push({
        inputOffset: c.srcOffset,
        inputLen: c.srcLen,
        dstOffset: c.dstOffset,
        dstSize: c.dstSize
      });
    }
    groupMeta.push({ start, count: end - start });

    phase1Promises.push(pool.dispatch({
      type: 'phase1_batch',
      inputSAB,
      subChunks: group,
      scratchSAB,
      scratchBaseOffset: g * maxSCperGroup * HLZ_SCRATCH_SIZE,
      batchIndex: g
    }).then(result => {
      if (!result.ok) throw new Error(`Phase1 group ${g} failed (${result.error})`);
      return result;
    }));
  }
  await Promise.all(phase1Promises);

  // Collect all sub-chunk results from workers, in order
  const allSubResults = [];
  for (let g = 0; g < numGroups; g++) {
    const result = await phase1Promises[g]; // already resolved
    if (result.subResults) {
      for (const sr of result.subResults) {
        sr._group = g;
      }
      allSubResults.push(...result.subResults);
    }
  }

  // Sort by dstOffset to ensure correct processing order
  allSubResults.sort((a, b) => a.dstOffset - b.dstOffset);

  // Phase 2: serial resolve on main thread
  const scratchView = new Uint8Array(scratchSAB);
  mem = new Uint8Array(wasm.memory.buffer);

  for (const sr of allSubResults) {
    if (sr.isStored) {
      mem = new Uint8Array(wasm.memory.buffer);
      mem.copyWithin(outputBase + sr.dstOffset, inputBase + sr.srcOffset, inputBase + sr.srcOffset + sr.dstSize);
      continue;
    }
    if (sr.isEntropy) continue; // should not happen (worker aborts on entropy-only)

    const tableOff = (sr._group * maxSCperGroup + sr.scIdx) * HLZ_SCRATCH_SIZE;
    const { cmdSize, offsSize, litSize, lenSize, mode } = sr;

    // Copy decoded streams to main WASM's HLZ scratch area
    const HLZ_SCRATCH_DATA = HLZ_SCRATCH_BASE + 0x20;
    let dataOff = tableOff + 32;
    const litDst = HLZ_SCRATCH_DATA;
    mem = new Uint8Array(wasm.memory.buffer);
    mem.set(scratchView.subarray(dataOff, dataOff + litSize), litDst);
    dataOff += litSize;
    const cmdDst = litDst + litSize;
    mem.set(scratchView.subarray(dataOff, dataOff + cmdSize), cmdDst);
    dataOff += cmdSize;
    mem.set(scratchView.subarray(dataOff, dataOff + offsSize * 4), 0x00270020);
    dataOff += offsSize * 4;
    mem.set(scratchView.subarray(dataOff, dataOff + lenSize * 4), 0x002F0020);

    // Write HLZ_TABLE with corrected pointers
    const dv = new DataView(wasm.memory.buffer);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x00, cmdDst, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x04, cmdSize, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x08, 0x00270020, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x0C, offsSize, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x10, litDst, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x14, litSize, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x18, 0x002F0020, true);
    dv.setInt32(HLZ_SCRATCH_BASE + 0x1C, lenSize, true);

    // Initial 8 literal bytes for first sub-chunk of entire block
    if (sr.dstOffset === 0) {
      // Find the compressed payload start for this chunk
      // The first LZ chunk's payload starts after block hdr(2) + chunk hdr(4) + sub-chunk hdr(3) + excess byte skip
      // Actually, Phase 1 already consumed the initial 8 bytes from src.
      // We need to replicate: the first 8 bytes of the sub-chunk's compressed payload
      // are raw literals. Find the chunk that contains dstOffset=0.
      const firstChunk = lzChunks[0];
      mem.copyWithin(outputBase, inputBase + firstChunk.srcOffset + 2 + 4 + 3, inputBase + firstChunk.srcOffset + 2 + 4 + 3 + 8);
    }

    const result = wasm.hlzPhase2(
      outputBase + sr.dstOffset,
      sr.dstSize,
      mode,
      outputBase
    );
    if (result < 0) throw new Error(`Phase2 sub-chunk at dstOff=${sr.dstOffset} failed (trace: ${wasm.getTrace()})`);
  }

  return new Uint8Array(wasm.memory.buffer.slice(outputBase, outputBase + contentSize));
}

// ── Public API ───────────────────────────────────────────────

let _pool = null;

async function getCoreCount() {
  if (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) {
    return navigator.hardwareConcurrency;
  }
  if (isNode) {
    return (await import('os')).default.cpus().length;
  }
  return 4;
}

/**
 * Decompress SLZ1-framed data.
 *
 * @param {Uint8Array|Buffer} data - Compressed SLZ1 data
 * @param {Object} [options]
 * @param {number} [options.threads=0] - Worker count for L6-L8 SC parallel decompression.
 *   0 = auto (use hardware concurrency). 1 = force single-threaded.
 * @param {number} [options.maxDecompressedSize=1073741824] - Maximum allowed decompressed
 *   size in bytes. Rejects streams claiming larger output to prevent decompression bombs.
 * @returns {Promise<Uint8Array>} Decompressed data
 */
export async function decompress(data, options = {}) {
  if (data.length === 0) return new Uint8Array(0);

  const threads = options.threads ?? 0;
  const maxSize = options.maxDecompressedSize ?? DEFAULT_MAX_DECOMPRESSED_SIZE;
  const frame = scanFrame(data);
  if (!frame) throw new Error('Not a valid SLZ1 stream');

  if (frame.contentSize > maxSize) {
    throw new Error(
      `StreamLZ: contentSize ${frame.contentSize} exceeds maxDecompressedSize ${maxSize}`);
  }

  // L6-L8 SC with threads > 1 and SharedArrayBuffer available → parallel
  if (frame.isSC && frame.chunks && threads !== 1 && hasSharedArrayBuffer) {
    const dispatchable = frame.chunks.filter(c => !c.isUncomp && !c.isMemset).length;
    if (dispatchable < 2) {
      // Not worth parallelizing — single-threaded is faster
      await getSingleInstance();
      return decompressSingle(data, frame.contentSize);
    }

    const coreCount = threads > 0 ? threads : await getCoreCount();
    const numWorkers = Math.min(coreCount, dispatchable);

    if (!_pool || _pool.size < numWorkers) {
      if (_pool) _pool.terminate();
      _pool = new WorkerPool(numWorkers);
      await _pool.init();
    }

    return decompressParallel(data, frame, _pool);
  }

  // L9-L11 non-SC High with multiple chunks → two-phase parallel
  if (frame.twoPhaseChunks && threads !== 1 && hasSharedArrayBuffer) {
    const lzChunks = frame.twoPhaseChunks.filter(c => !c.isUncomp && !c.isMemset);
    if (lzChunks.length >= 2) {
      const coreCount = threads > 0 ? threads : await getCoreCount();
      const numWorkers = Math.min(coreCount, lzChunks.length);

      if (!_pool || _pool.size < numWorkers) {
        if (_pool) _pool.terminate();
        _pool = new WorkerPool(numWorkers);
        await _pool.init();
      }

      return decompressTwoPhase(data, frame, _pool);
    }
  }

  // Single-threaded fallback
  await getSingleInstance();
  return decompressSingle(data, frame.contentSize);
}

/**
 * Shut down the worker pool. Call when done with decompression.
 */
export function shutdown() {
  if (_pool) { _pool.terminate(); _pool = null; }
}
