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

function decompressGroup(msg) {
  const { inputSAB, outputSAB, groupDstOffset, chunks, groupIndex } = msg;
  const input = new Uint8Array(inputSAB);
  const output = new Uint8Array(outputSAB);

  // Calculate total group size for contiguous decode
  let groupTotalSize = 0;
  for (const c of chunks) groupTotalSize += c.dstSize;

  // Find max input chunk size
  let maxInputLen = 0;
  for (const c of chunks) if (c.srcLen > maxInputLen) maxInputLen = c.srcLen;

  const inputBase = wasm.getInputBase();
  const outputBase = ((inputBase + maxInputLen + 255) & ~255);
  const needed = outputBase + groupTotalSize + 65536;
  const currentSize = wasm.memory.buffer.byteLength;
  if (needed > currentSize) {
    try {
      wasm.memory.grow(Math.ceil((needed - currentSize) / 65536));
    } catch (e) {
      post({ type: 'done', groupIndex, ok: false, error: 'OOM' });
      return;
    }
  }
  wasm.setOutputBase(outputBase);
  mem = new Uint8Array(wasm.memory.buffer);

  // Decode chunks sequentially into contiguous WASM output region
  let groupOffset = 0;
  for (const c of chunks) {
    if (c.isUncomp || c.isMemset) {
      // Already handled on main thread; skip but advance offset
      groupOffset += c.dstSize;
      continue;
    }

    // Copy this chunk's compressed data to WASM input
    mem = new Uint8Array(wasm.memory.buffer);
    mem.set(input.subarray(c.srcOffset, c.srcOffset + c.srcLen), inputBase);

    // decompressChunk decodes at outputBase with dstOffset for cross-chunk refs
    const result = wasm.decompressChunkAt(inputBase, c.srcLen, outputBase, groupOffset, c.dstSize);

    if (result !== c.dstSize) {
      post({ type: 'done', groupIndex, ok: false, error: result });
      return;
    }

    groupOffset += c.dstSize;
  }

  // Copy full group output to shared buffer
  mem = new Uint8Array(wasm.memory.buffer);
  output.set(mem.subarray(outputBase, outputBase + groupTotalSize), groupDstOffset);

  post({ type: 'done', groupIndex, ok: true });
}

const HLZ_SCRATCH_BASE = 0x00230000;
const HLZ_SCRATCH_SIZE = 0x00140020;

function phase1Batch(msg) {
  const { inputSAB, subChunks: chunks, scratchSAB, scratchBaseOffset, batchIndex } = msg;
  const input = new Uint8Array(inputSAB);
  const subResults = []; // { mode, litSize, cmdSize, offsSize, lenSize } per sub-chunk
  let scIdx = 0; // sub-chunk index within this batch's scratch region

  for (let k = 0; k < chunks.length; k++) {
    const c = chunks[k];
    const inputBase = wasm.getInputBase();
    const outputBase = ((inputBase + c.inputLen + 255) & ~255);
    const needed = outputBase + c.dstSize + 65536;
    if (needed > wasm.memory.buffer.byteLength) {
      try { wasm.memory.grow(Math.ceil((needed - wasm.memory.buffer.byteLength) / 65536)); }
      catch (e) { post({ type: 'done', batchIndex, ok: false, error: 'OOM' }); return; }
    }
    wasm.setOutputBase(outputBase);
    mem = new Uint8Array(wasm.memory.buffer);

    // Copy chunk data to WASM input
    mem.set(input.subarray(c.inputOffset, c.inputOffset + c.inputLen), inputBase);

    // Parse chunk: 2-byte block header + 4-byte chunk header + sub-chunk payloads
    let p = inputBase + 2; // skip block header
    const chunkHdr = mem[p] | (mem[p+1] << 8) | (mem[p+2] << 16) | (mem[p+3] << 24);
    p += 4; // skip chunk header

    let dstRem = c.dstSize;
    let subDstOff = 0;

    while (dstRem > 0) {
      const subDstSize = Math.min(0x20000, dstRem);
      // 3-byte sub-chunk header (big-endian)
      const subHdr = (mem[p] << 16) | (mem[p+1] << 8) | mem[p+2];

      if (!(subHdr & 0x800000)) {
        // Entropy-only: run via high_decode_bytes directly — can't Phase 1 this
        // Mark as special; main thread handles via full decoder
        subResults.push({ isEntropy: true, dstOffset: c.dstOffset + subDstOff, dstSize: subDstSize });
        // We don't know src size — abort this chunk, let main thread handle it
        // Actually, for simplicity, fall back entire batch to serial
        post({ type: 'done', batchIndex, ok: false, error: 'entropy-only-subchunk' });
        return;
      }

      p += 3;
      const compSz = subHdr & 0x7FFFF;
      const mode = (subHdr >> 19) & 0xF;

      if (compSz >= subDstSize && mode === 0) {
        // Stored: copy directly — mark as special
        subResults.push({ isStored: true, srcOffset: p - inputBase + c.inputOffset, dstOffset: c.dstOffset + subDstOff, dstSize: subDstSize });
        p += compSz;
      } else {
        // LZ sub-chunk: run Phase 1
        const fakeDst = (c.dstOffset + subDstOff === 0) ? outputBase : outputBase + 8;
        const result = wasm.hlzPhase1(p, p + compSz, fakeDst, subDstSize, mode, outputBase);
        if (result !== 0) {
          post({ type: 'done', batchIndex, ok: false, error: result });
          return;
        }

        // Copy compact scratch to SAB
        mem = new Uint8Array(wasm.memory.buffer);
        const dv = new DataView(wasm.memory.buffer);
        const litSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x14, true);
        const cmdSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x04, true);
        const offsSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x0C, true);
        const lenSize = dv.getInt32(HLZ_SCRATCH_BASE + 0x1C, true);

        const scratch = new Uint8Array(scratchSAB);
        const tableOff = scratchBaseOffset + scIdx * HLZ_SCRATCH_SIZE;
        scratch.set(mem.subarray(HLZ_SCRATCH_BASE, HLZ_SCRATCH_BASE + 32), tableOff);
        const litPtr = dv.getInt32(HLZ_SCRATCH_BASE + 0x10, true);
        const cmdPtr = dv.getInt32(HLZ_SCRATCH_BASE + 0x00, true);
        scratch.set(mem.subarray(litPtr, litPtr + litSize), tableOff + 32);
        scratch.set(mem.subarray(cmdPtr, cmdPtr + cmdSize), tableOff + 32 + litSize);
        scratch.set(mem.subarray(0x00270020, 0x00270020 + offsSize * 4), tableOff + 32 + litSize + cmdSize);
        scratch.set(mem.subarray(0x002F0020, 0x002F0020 + lenSize * 4), tableOff + 32 + litSize + cmdSize + offsSize * 4);

        subResults.push({ mode, litSize, cmdSize, offsSize, lenSize, dstOffset: c.dstOffset + subDstOff, dstSize: subDstSize, scIdx });
        scIdx++;
        p += compSz;
      }

      subDstOff += subDstSize;
      dstRem -= subDstSize;
    }
  }

  post({ type: 'done', batchIndex, ok: true, subResults });
}

function onMessage(msg) {
  if (msg.type === 'init') init(msg.wasmModule);
  else if (msg.type === 'decompress_chunk') decompressChunk(msg);
  else if (msg.type === 'decompress_group') decompressGroup(msg);
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
