// Worker: decompresses chunks using shared WASM memory
import { parentPort, workerData } from 'worker_threads';

const { instance } = await WebAssembly.instantiate(workerData.wasmModule);
const wasm = instance.exports;
const mem = new Uint8Array(wasm.memory.buffer);

parentPort.on('message', (msg) => {
  if (msg.type === 'decompress_chunk') {
    const { inputSAB, inputOffset, inputLen, outputSAB, outputOffset, dstSize, chunkIndex } = msg;

    const input = new Uint8Array(inputSAB);
    const output = new Uint8Array(outputSAB);

    // Build minimal SLZ1 frame wrapping this chunk
    const frameSize = 18 + 8 + inputLen + 4;
    const inputBase = wasm.getInputBase();

    // Frame header
    const frame = mem.subarray(inputBase, inputBase + frameSize);
    const dv = new DataView(wasm.memory.buffer, inputBase, frameSize);
    dv.setUint32(0, 0x534C5A31, true);
    mem[inputBase + 4] = 1; mem[inputBase + 5] = 1; mem[inputBase + 6] = 0;
    mem[inputBase + 7] = 5; mem[inputBase + 8] = 2; mem[inputBase + 9] = 0;
    dv.setUint32(10, dstSize, true); dv.setUint32(14, 0, true);
    dv.setUint32(18, inputLen, true); dv.setInt32(22, dstSize, true);

    // Copy chunk data from shared input
    mem.set(input.subarray(inputOffset, inputOffset + inputLen), inputBase + 26);

    // End mark
    dv.setUint32(26 + inputLen, 0, true);

    const result = wasm.decompress(frameSize);

    if (result === dstSize) {
      // Copy output to shared buffer
      const outputBase = wasm.getOutputBase();
      output.set(mem.subarray(outputBase, outputBase + dstSize), outputOffset);
      parentPort.postMessage({ type: 'done', chunkIndex, ok: true });
    } else {
      parentPort.postMessage({ type: 'done', chunkIndex, ok: false, error: result });
    }
  }
});

parentPort.postMessage({ type: 'ready' });
