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
  const instance = await WebAssembly.instantiate(wasmModule);
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
    wasm.memory.grow(Math.ceil((needed - currentSize) / 65536));
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

function onMessage(msg) {
  if (msg.type === 'init') init(msg.wasmModule);
  else if (msg.type === 'decompress_chunk') decompressChunk(msg);
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
