// LzDecoder.TwoPhase.cs — Two-phase parallel decompression for the High LZ decoder.

using System.IO;
using System.Runtime.CompilerServices;

namespace StreamLZ.Decompression.High;

internal static unsafe partial class LzDecoder
{
    // ================================================================
    //  Two-Phase Parallel Decompression — Phase 1
    // ================================================================

    /// <summary>
    /// Phase 1: Process a single chunk for two-phase decompression.
    /// Performs entropy decode (<see cref="ReadLzTable"/>) for each sub-chunk,
    /// populating HighLzTable in scratch. Phase 2 calls ProcessLzRuns serially.
    /// </summary>
    /// <returns>Compressed bytes consumed, or -1 on error.</returns>
    [SkipLocalsInit]
    public static int Phase1_ProcessChunk(
        byte* dst, byte* dstEnd, byte* dstStart,
        byte* src, byte* srcEnd,
        byte* scratch, byte* scratchEnd,
        DecodeBytes decodeBytes,
        ref ChunkPhase1Result result)
    {
        byte* srcIn = src;
        int mode, dstCount, srcUsed, writtenBytes;
        int subChunkIndex = 0;

        // Each sub-chunk gets its own scratch region so that sub-chunk 1's
        // LitStream (Mode 0) survives while sub-chunk 2's ReadLzTable runs.
        int totalScratch = (int)(scratchEnd - scratch);
        int perSubScratch = totalScratch / 2;

        while (dstEnd - dst != 0)
        {
            dstCount = (int)(dstEnd - dst);
            if (dstCount > 0x20000)
            {
                dstCount = 0x20000;
            }

            if (srcEnd - src < 4)
            {
                throw new InvalidDataException("High Phase1: source data truncated before sub-chunk header.");
            }

            // Select scratch region for this sub-chunk
            byte* subScratch = scratch + subChunkIndex * perSubScratch;
            byte* subScratchEnd = subScratch + perSubScratch;

            int chunkhdr = src[2] | (src[1] << 8) | (src[0] << 16);
            if ((chunkhdr & StreamLZConstants.ChunkHeaderCompressedFlag) == 0)
            {
                // Entropy-only sub-chunk: decode directly to output (no LZ tokens)
                byte* output = dst;
                srcUsed = decodeBytes(&output, src, srcEnd, &writtenBytes, dstCount, false, subScratch, subScratchEnd);
                if (writtenBytes != dstCount)
                {
                    throw new InvalidDataException($"High Phase1: entropy decode failed (writtenBytes={writtenBytes}, expected={dstCount}).");
                }

                ref SubChunkPhase1Result sub = ref (subChunkIndex == 0 ? ref result.Sub0 : ref result.Sub1);
                sub.IsLz = false;
                sub.DstOffset = (int)(dst - dstStart);
                sub.DstSize = dstCount;
            }
            else
            {
                src += 3;
                srcUsed = chunkhdr & 0x7FFFF;
                mode = (chunkhdr >> StreamLZConstants.SubChunkTypeShift) & 0xF;
                if (srcEnd - src < srcUsed)
                {
                    throw new InvalidDataException($"High Phase1: source data truncated (need {srcUsed} bytes, have {(int)(srcEnd - src)}).");
                }

                if (srcUsed < dstCount)
                {
                    nint scratchUsage = Math.Min(
                        StreamLZConstants.CalculateScratchSize(dstCount),
                        (int)(subScratchEnd - subScratch));
                    if (scratchUsage < sizeof(HighLzTable))
                    {
                        throw new InvalidDataException("High Phase1: scratch buffer too small for LZ table.");
                    }

                    if (!ReadLzTable(mode,
                        src, src + srcUsed,
                        dst, dstCount,
                        (int)(dst - dstStart),
                        subScratch + sizeof(HighLzTable), subScratch + scratchUsage,
                        (HighLzTable*)subScratch,
                        decodeBytes))
                    {
                        throw new InvalidDataException("High Phase1: ReadLzTable failed for sub-chunk.");
                    }

                    ref SubChunkPhase1Result sub = ref (subChunkIndex == 0 ? ref result.Sub0 : ref result.Sub1);
                    sub.IsLz = true;
                    sub.Mode = mode;
                    sub.DstOffset = (int)(dst - dstStart);
                    sub.DstSize = dstCount;
                }
                else if (srcUsed > dstCount || mode != 0)
                {
                    throw new InvalidDataException($"High Phase1: invalid stored sub-chunk (srcUsed={srcUsed}, dstCount={dstCount}, mode={mode}).");
                }
                else
                {
                    // Stored: copy directly
                    Buffer.MemoryCopy(src, dst, dstCount, dstCount);
                    ref SubChunkPhase1Result sub = ref (subChunkIndex == 0 ? ref result.Sub0 : ref result.Sub1);
                    sub.IsLz = false;
                    sub.DstSize = dstCount;
                    sub.DstOffset = (int)(dst - dstStart);
                }
            }
            src += srcUsed;
            dst += dstCount;
            subChunkIndex++;
        }

        result.SubChunkCount = subChunkIndex;
        return (int)(src - srcIn);
    }
}
