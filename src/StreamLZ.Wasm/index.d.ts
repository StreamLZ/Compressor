/**
 * Decompress SLZ1-framed data.
 *
 * Supports all StreamLZ levels (L1-L11). L6-L8 self-contained streams
 * are automatically decompressed in parallel using Web Workers when
 * SharedArrayBuffer is available.
 *
 * @param data - Compressed SLZ1 data
 * @param options - Decompression options
 * @param options.threads - Worker count for parallel decompression.
 *   0 = auto (hardware concurrency). 1 = force single-threaded.
 * @param options.maxDecompressedSize - Maximum allowed decompressed size in bytes.
 *   Rejects streams claiming larger output. Default: 1 GB (1073741824).
 * @returns Decompressed data
 */
export function decompress(
  data: Uint8Array | Buffer,
  options?: { threads?: number; maxDecompressedSize?: number }
): Promise<Uint8Array>;

/**
 * Shut down the worker pool. Call when done with decompression
 * to release resources.
 */
export function shutdown(): void;
