// StreamLZ WASM Worker — runs in both Node worker_threads and browser Web Workers
// Receives WASM module bytes via initialization, decompresses chunks on demand.

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

  // Build minimal SLZ1 frame wrapping this chunk
  const frameSize = 18 + 8 + inputLen + 4;
  const inputBase = wasm.getInputBase();

  // Refresh mem view in case of memory.grow
  mem = new Uint8Array(wasm.memory.buffer);

  const dv = new DataView(wasm.memory.buffer, inputBase, frameSize);
  dv.setUint32(0, 0x534C5A31, true); // magic
  mem[inputBase + 4] = 1;   // version
  mem[inputBase + 5] = 1;   // flags (contentSize)
  mem[inputBase + 6] = 0;   // codec = High
  mem[inputBase + 7] = 5;   // level
  mem[inputBase + 8] = 2;   // blockSizeLog2
  mem[inputBase + 9] = 0;   // reserved
  dv.setUint32(10, dstSize, true);
  dv.setUint32(14, 0, true);
  dv.setUint32(18, inputLen, true);
  dv.setInt32(22, dstSize, true);

  // Copy chunk data from shared input
  mem.set(input.subarray(inputOffset, inputOffset + inputLen), inputBase + 26);
  dv.setUint32(26 + inputLen, 0, true); // end mark

  const result = wasm.decompress(frameSize);

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
