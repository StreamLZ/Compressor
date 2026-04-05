// StreamLZ WASM Decompressor — Production API
// Supports L1 (Fast), L6 (High SC), and L9 (High non-SC).
// L6 SC automatically uses parallel workers when SharedArrayBuffer is available.

import { readFileSync } from 'fs';
import { Worker } from 'worker_threads';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = resolve(__dirname, 'slz-decompress.wasm');

let _wasmBytes = null;
function getWasmBytes() {
  if (!_wasmBytes) _wasmBytes = readFileSync(WASM_PATH);
  return _wasmBytes;
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

  // Scan StreamLZ header for SC flag
  const slzPos = headerSize + 8;
  const isSC = !!(data[slzPos] & 0x10);

  // Scan chunks for SC parallel decompression
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

  return { contentSize: blockDecompSize, codec, isSC, chunks, prefixBase, headerSize };
}

// ── Error messages ───────────────────────────────────────────

function getError(wasm, code) {
  const trace = wasm.getTrace ? wasm.getTrace() : 0;
  const errors = {
    '-2001': 'Sub-chunk header truncated (src exhausted)',
    '-2010': 'Entropy decoder failed on sub-chunk',
    '-2011': 'Entropy decoded size mismatch',
    '-2020': 'Compressed sub-chunk source data truncated',
    '-2021': 'Stored sub-chunk size mismatch',
    '-2030': 'Fast LZ decoder failed',
    '-2031': 'High LZ decoder failed',
    '-3001': 'High LZ: invalid mode (must be 0 or 1)',
    '-3002': 'High LZ: invalid input size',
    '-3003': 'High LZ: source too short',
    '-3004': 'High LZ: literal entropy decode failed',
    '-3005': 'High LZ: command entropy decode failed',
    '-3008': 'High LZ: unsupported offset scaling mode',
    '-3009': 'High LZ: packed length entropy decode failed',
    '-3010': 'High LZ: u32 length stream gamma decode failed',
    '-3011': 'High LZ: traditional offset mode failed',
  };
  const msg = errors[String(trace)] || `unknown error (trace=${trace})`;
  return `StreamLZ decompress failed (code ${code}): ${msg}`;
}

// ── Worker pool ──────────────────────────────────────────────

class WorkerPool {
  constructor(size) {
    this.size = size;
    this.workers = [];
    this.available = [];
    this.queue = [];
    this.ready = 0;
    this._readyPromise = null;
    this._readyResolve = null;
  }

  async init() {
    const wasmModule = getWasmBytes();
    this._readyPromise = new Promise(r => { this._readyResolve = r; });

    for (let i = 0; i < this.size; i++) {
      const worker = new Worker(resolve(__dirname, 'worker-shared.mjs'), {
        workerData: { wasmModule }
      });
      this.workers.push(worker);

      worker.on('message', (msg) => {
        if (msg.type === 'ready') {
          this.ready++;
          if (this.ready === this.size) this._readyResolve();
        } else if (msg.type === 'done') {
          const cb = worker._callback;
          worker._callback = null;
          this.available.push(worker);
          if (cb) cb(msg);
          this._drain();
        }
      });
    }

    await this._readyPromise;
    this.available = [...this.workers];
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
async function getSingleInstance() {
  if (!_singleInstance) {
    const { instance } = await WebAssembly.instantiate(getWasmBytes());
    _singleInstance = instance.exports;
  }
  return _singleInstance;
}

// Scratch region ends at ~0x0C300000 (195MB). Output can go above that for large files.
const SCRATCH_END = 0x0D000000; // 208MB — safe margin above all scratch/LUT/tANS/HighLZ
const DEFAULT_OUTPUT_BASE = 0x04000100;
const PAGE_SIZE = 65536;

function ensureCapacity(wasm, inputSize, outputSize) {
  const inputBase = wasm.getInputBase();
  const inputEnd = inputBase + inputSize;

  // If input fits before default output and output fits before scratch: use defaults
  if (inputEnd <= DEFAULT_OUTPUT_BASE && outputSize <= SCRATCH_END - DEFAULT_OUTPUT_BASE) {
    wasm.setOutputBase(DEFAULT_OUTPUT_BASE);
    return;
  }

  // Large file: place output AFTER scratch region
  const outputBase = SCRATCH_END;
  wasm.setOutputBase(outputBase);

  // Grow memory if needed
  const needed = outputBase + outputSize + PAGE_SIZE; // +1 page safety
  const currentSize = wasm.memory.buffer.byteLength;
  if (needed > currentSize) {
    const pagesToGrow = Math.ceil((needed - currentSize) / PAGE_SIZE);
    wasm.memory.grow(pagesToGrow);
  }
}

function decompressSingle(data, contentSize) {
  const wasm = _singleInstance;
  ensureCapacity(wasm, data.length, contentSize || data.length * 4);
  const mem = new Uint8Array(wasm.memory.buffer);
  const inputBase = wasm.getInputBase();
  mem.set(data, inputBase);
  const result = wasm.decompress(data.length);
  if (result < 0) throw new Error(getError(wasm, result));
  const outputBase = wasm.getOutputBase();
  return new Uint8Array(wasm.memory.buffer.slice(outputBase, outputBase + result));
}

// ── Parallel decompress (L6 SC) ─────────────────────────────

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
      if (!result.ok) throw new Error(`Chunk ${i} failed: ${result.error}`);
    }));
  }
  await Promise.all(promises);

  // Restore SC prefix bytes for chunks 1..N
  for (let i = 0; i < chunks.length - 1; i++) {
    const c = chunks[i + 1];
    const copySize = Math.min(8, c.dstSize);
    output.set(data.subarray(prefixBase + i * 8, prefixBase + i * 8 + copySize), c.dstOffset);
  }

  return new Uint8Array(outputSAB);
}

// ── Public API ───────────────────────────────────────────────

let _pool = null;
const hasSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined';

/**
 * Decompress SLZ1-framed data.
 *
 * @param {Uint8Array|Buffer} data - Compressed SLZ1 data
 * @param {Object} [options]
 * @param {number} [options.threads=0] - Worker count for L6 SC parallel decompression.
 *   0 = auto (use navigator.hardwareConcurrency or 4).
 *   1 = force single-threaded.
 * @returns {Promise<Uint8Array>} Decompressed data
 */
export async function decompress(data, options = {}) {
  if (data.length === 0) return new Uint8Array(0);

  const threads = options.threads ?? 0;
  const frame = scanFrame(data);
  if (!frame) throw new Error('Not a valid SLZ1 stream');

  // L6 SC with threads > 1 and SharedArrayBuffer available → parallel
  if (frame.isSC && frame.chunks && threads !== 1 && hasSharedArrayBuffer) {
    const numWorkers = threads > 0 ? threads :
      (typeof navigator !== 'undefined' && navigator.hardwareConcurrency
        ? navigator.hardwareConcurrency
        : (await import('os')).default.cpus().length);

    if (!_pool || _pool.size !== numWorkers) {
      if (_pool) _pool.terminate();
      _pool = new WorkerPool(numWorkers);
      await _pool.init();
    }

    return decompressParallel(data, frame, _pool);
  }

  // Single-threaded fallback (L1, L9, small files, no SharedArrayBuffer)
  await getSingleInstance();
  return decompressSingle(data, frame.contentSize);
}

/**
 * Shut down the worker pool. Call when done with decompression.
 */
export function shutdown() {
  if (_pool) { _pool.terminate(); _pool = null; }
}
