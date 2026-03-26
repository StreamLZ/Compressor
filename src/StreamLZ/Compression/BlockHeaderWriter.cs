// BlockHeaderWriter.cs — Block header writing and utility methods for StreamLzCompressor.

using System.Runtime.CompilerServices;

namespace StreamLZ.Compression;

internal static unsafe partial class StreamLZCompressor
{
    /// <summary>
    /// Result of compressing a single 256KB block in parallel.
    /// The header + compressed data are stored in TmpBuf[0..TotalBytes].
    /// </summary>
    private struct BlockResult
    {
        public byte[] TmpBuf;
        public int TotalBytes; // header + compressed data length
    }

    /// <summary>
    /// Writes the 2-byte block header.
    /// </summary>
    /// <param name="dst">Pointer to the destination where the header is written.</param>
    /// <param name="comprId">Compressor file identifier (e.g. 2 for High, 3 for Fast).</param>
    /// <param name="crc">Whether to set the CRC flag in the header.</param>
    /// <param name="keyframe">Whether this block is a keyframe (dictionary reset).</param>
    /// <param name="uncompressed">Whether this block stores uncompressed data.</param>
    /// <param name="selfContained">Whether this block is self-contained (no cross-block references).</param>
    /// <param name="twoPhase">Whether two-phase decoding is enabled.</param>
    /// <returns>Pointer past the written header (dst + 2).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static byte* WriteBlockHdr(byte* dst, int comprId, bool crc, bool keyframe, bool uncompressed,
        bool selfContained = false, bool twoPhase = false)
    {
        // Block header byte 0 bit layout:
        //   [3:0]  magic nibble (0x5)
        //   [4]    SelfContained flag
        //   [5]    TwoPhase flag
        //   [6]    keyframe (RestartDecoder) flag
        //   [7]    uncompressed flag
        const byte BlockHeaderBase = 5; // Wire format: magic nibble 0x5 in the low 4 bits
        dst[0] = (byte)(BlockHeaderBase + (selfContained ? 0x10 : 0) + (twoPhase ? 0x20 : 0) + (keyframe ? 0x40 : 0) + (uncompressed ? 0x80 : 0));
        dst[1] = (byte)(comprId + (crc ? 0x80 : 0));
        return dst + 2;
    }

    /// <summary>
    /// Writes a 3-byte big-endian integer (used for chunk sub-headers within a block).
    /// </summary>
    /// <param name="dst">Pointer to the destination where the 3 bytes are written.</param>
    /// <param name="v">The 24-bit value to write (only the lower 24 bits are used).</param>
    /// <returns>Pointer past the written bytes (dst + 3).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static byte* WriteBE24(byte* dst, uint v)
    {
        dst[0] = (byte)(v >> 16);
        dst[1] = (byte)(v >> 8);
        dst[2] = (byte)v;
        return dst + 3;
    }

    /// <summary>
    /// Writes a 4-byte little-endian chunk header encoding the compressed size.
    /// </summary>
    /// <param name="dst">Pointer to the destination where the header is written.</param>
    /// <param name="compressedSizeMinus1">Compressed size minus 1 (stored in the low ChunkSizeBits).</param>
    /// <returns>Pointer past the written header (dst + ChunkHeaderSize).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static byte* WriteChunkHeader(byte* dst, uint compressedSizeMinus1)
    {
        // Type = 0 (normal), stored in bits above the size field
        *(uint*)dst = compressedSizeMinus1 & StreamLZConstants.ChunkSizeMask;
        return dst + StreamLZConstants.ChunkHeaderSize;
    }

    /// <summary>
    /// Writes a memset chunk header (5 bytes: 4-byte LE header + 1-byte fill value).
    /// </summary>
    /// <param name="dst">Pointer to the destination where the header is written.</param>
    /// <param name="v">The repeated byte value for the memset block.</param>
    /// <returns>Pointer past the written header.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static byte* WriteMemsetChunkHeader(byte* dst, byte v)
    {
        *(uint*)dst = StreamLZConstants.ChunkSizeMask | StreamLZConstants.ChunkTypeMemset;
        dst[StreamLZConstants.ChunkHeaderSize] = v;
        return dst + StreamLZConstants.ChunkHeaderSize + 1;
    }

    /// <summary>
    /// Returns true if every byte in the range is the same value.
    /// </summary>
    /// <param name="data">Pointer to the data to check.</param>
    /// <param name="size">Number of bytes to check.</param>
    /// <returns><c>true</c> if all bytes are equal (or size is 0 or 1); otherwise <c>false</c>.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    internal static bool AreAllBytesEqual(byte* data, int size)
    {
        if (size <= 1)
        {
            return true;
        }
        byte v = data[0];
        for (int i = 1; i < size; i++)
        {
            if (data[i] != v)
            {
                return false;
            }
        }
        return true;
    }
}
