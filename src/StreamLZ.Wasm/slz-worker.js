// StreamLZ WASM Worker — runs in both Node worker_threads and browser Web Workers
// Receives pre-compiled WASM Module via initialization, decompresses chunks on demand.

let wasm = null;
let mem = null;

let _parentPort = null;
function post(msg) {
  if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
    self.postMessage(msg); // Browser Web Worker
  } else if (_parentPort) {
    _parentPort.postMessage(msg); // Node
  }
}

async function init(wasmModule) {
  // Workers use private memory — each gets its own isolated WASM instance
  const privateMemory = new WebAssembly.Memory({ initial: 128, maximum: 65536, shared: true });
  const instance = await WebAssembly.instantiate(wasmModule, { env: { memory: privateMemory } });
  wasm = instance.exports;
  mem = new Uint8Array(wasm.memory.buffer);
  post({ type: 'ready' });
}

function decompressChunk(msg) {
  const { inputSAB, inputOffset, inputLen, outputSAB, outputOffset, dstSize, chunkIndex } = msg;
  const input = new Uint8Array(inputSAB);
  const output = new Uint8Array(outputSAB);

  const inputBase = wasm.getInputBase();

  // Ensure memory is large enough for input + output
  const outputBase = ((inputBase + inputLen + 255) & ~255);
  const needed = outputBase + dstSize + 65536;
  const currentSize = wasm.memory.buffer.byteLength;
  if (needed > currentSize) {
    try {
      wasm.memory.grow(Math.ceil((needed - currentSize) / 65536));
    } catch (e) {
      post({ type: 'done', chunkIndex, ok: false, error: 'OOM' });
      return;
    }
  }
  wasm.setOutputBase(outputBase);

  // Refresh mem view after potential grow
  mem = new Uint8Array(wasm.memory.buffer);

  // Copy chunk data directly to WASM input buffer
  mem.set(input.subarray(inputOffset, inputOffset + inputLen), inputBase);

  const result = wasm.decompressChunk(inputLen, dstSize);

  if (result === dstSize) {
    const outputBase = wasm.getOutputBase();
    mem = new Uint8Array(wasm.memory.buffer); // refresh after potential grow
    output.set(mem.subarray(outputBase, outputBase + dstSize), outputOffset);
    post({ type: 'done', chunkIndex, ok: true });
  } else {
    post({ type: 'done', chunkIndex, ok: false, error: result });
  }
}

const HLZ_SCRATCH_BASE = 0x00230000;
const HLZ_SCRATCH_SIZE = 0x00140020;

function phase1Batch(msg) {
  const { inputSAB, subChunks, scratchSAB, scratchBaseOffset, batchIndex } = msg;
  const input = new Uint8Array(inputSAB);
  const results = [];

  for (let k = 0; k < subChunks.length; k++) {
    const sc = subChunks[k];
    const inputBase = wasm.getInputBase();
    const outputBase = ((inputBase + sc.inputLen + 255) & ~255);
    const needed = outputBase + sc.dstSize + 65536;
    const currentSize = wasm.memory.buffer.byteLength;
    if (needed > currentSize) {
      try {
        wasm.memory.grow(Math.ceil((needed - currentSize) / 65536));
      } catch (e) {
        post({ type: 'done', batchIndex, ok: false, error: 'OOM' });
        return;
      }
    }
    wasm.setOutputBase(outputBase);
    mem = new Uint8Array(wasm.memory.buffer);

    // Copy sub-chunk compressed data to WASM input
    mem.set(input.subarray(sc.inputOffset, sc.inputOffset + sc.inputLen), inputBase);

    // Run Phase 1
    const fakeDst = sc.dstOffset === 0 ? outputBase : outputBase + 8;
    const result = wasm.hlzPhase1(
      inputBase, inputBase + sc.inputLen,
      fakeDst, sc.dstSize, sc.mode, outputBase
    );

    if (result !== 0) {
      post({ type: 'done', batchIndex, ok: false, error: result, failedSC: k });
      return;
    }

    // Read stream sizes and copy compact scratch to SAB
    mem = new Uint8Array(wasm.memory.buffer);
    const dv = new DataView(wasm.memory.buffer);
    const litSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x14, true);
    const cmdSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x04, true);
    const offsSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x0C, true);
    const lenSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x1C, true);

    const scratch = new Uint8Array(scratchSAB);
    const tableOff = scratchBaseOffset + k * HLZ_SCRATCH_SIZE;
    scratch.set(mem.subarray(HLZ_SCRATCH_BASE, HLZ_SCRATCH_BASE + 32), tableOff);
    const litPtr = dv.getInt32(HLZ_SCRATCH_BASE + 0x10, true);
    const cmdPtr = dv.getInt32(HLZ_SCRATCH_BASE + 0x00, true);
    scratch.set(mem.subarray(litPtr, litPtr + litSize), tableOff + 32);
    scratch.set(mem.subarray(cmdPtr, cmdPtr + cmdSize), tableOff + 32 + litSize);
    const offsBufBase = 0x00270020;
    const lenBufBase = 0x002F0020;
    scratch.set(mem.subarray(offsBufBase, offsBufBase + offsSize * 4), tableOff + 32 + litSize + cmdSize);
    scratch.set(mem.subarray(lenBufBase, lenBufBase + lenSize * 4), tableOff + 32 + litSize + cmdSize + offsSize * 4);

    results.push({ litSize, cmdSize, offsSize, lenSize });
  }

  post({ type: 'done', batchIndex, ok: true, results });
}

function onMessage(msg) {
  if (msg.type === 'init') init(msg.wasmModule);
  else if (msg.type === 'decompress_chunk') decompressChunk(msg);
  else if (msg.type === 'phase1_batch') phase1Batch(msg);
}

// Wire up message handler for both environments
if (typeof self !== 'undefined' && typeof self.addEventListener === 'function') {
  // Browser Web Worker
  self.addEventListener('message', (e) => onMessage(e.data));
} else {
  // Node worker_threads (dynamic import to avoid require() in ESM)
  import('worker_threads').then(({ parentPort, workerData }) => {
    _parentPort = parentPort;
    parentPort.on('message', onMessage);
    if (workerData && workerData.wasmModule) {
      init(workerData.wasmModule);
    }
  });
}
