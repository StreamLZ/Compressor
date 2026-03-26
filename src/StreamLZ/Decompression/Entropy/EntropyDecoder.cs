// Entropy routing and RLE decoding functions.

using System.Buffers.Binary;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StreamLZ.Decompression.Entropy;

/// <summary>
/// Main entropy decoder router.
/// Dispatches to Huffman, TANS, RLE, recursive, and memcopy decoders based on chunk type.
/// </summary>
internal static unsafe class EntropyDecoder
{
    #region Bitmask table

    /// <summary>
    /// Precomputed bitmasks: bitmasks[n] = (1 &lt;&lt; (n+1)) - 1 for variable-length bit extraction.
    /// </summary>
    private static ReadOnlySpan<uint> Bitmasks =>
    [
        0x1, 0x3, 0x7, 0xf, 0x1f, 0x3f, 0x7f, 0xff,
        0x1ff, 0x3ff, 0x7ff, 0xfff, 0x1fff, 0x3fff, 0x7fff, 0xffff,
        0x1ffff, 0x3ffff, 0x7ffff, 0xfffff, 0x1fffff, 0x3fffff, 0x7fffff,
        0xffffff, 0x1ffffff, 0x3ffffff, 0x7ffffff, 0xfffffff, 0x1fffffff, 0x3fffffff, 0x7fffffff, 0xffffffff
    ];

    #endregion

    #region High_GetBlockSize

    /// <summary>
    /// Parses the block header to determine compressed and decompressed sizes.
    /// Returns the number of source bytes consumed (header + payload).
    /// </summary>
    /// <remarks>
    /// Return semantics differ by chunkType:
    /// <list type="bullet">
    ///   <item>chunkType 0 (memcopy): returns header + srcSize (total consumed bytes).</item>
    ///   <item>chunkType 1-5 (entropy): returns srcSize only (compressed payload, excluding header).</item>
    /// </list>
    /// Block size encoding tiers: &lt;4096 = 12-bit, &lt;16384 = 14-bit, else 18-bit.
    /// </remarks>
    public static int High_GetBlockSize(byte* src, byte* srcEnd, int* destSize, int destCapacity)
    {
        byte* sourceStart = src;
        int srcSize, dstSize;

        if (srcEnd - src < 2)
        {
            throw new InvalidDataException("GetBlockSize: source too short for block header (need 2 bytes)");
        }

        int chunkType = (src[0] >> 4) & 0x7;
        if (chunkType == 0)
        {
            // Block size encoding tier 1 (memcopy): small = 12-bit (0xFFF mask), large = 18-bit (0x3ffff mask).
            if (src[0] >= 0x80)
            {
                srcSize = ((src[0] << 8) | src[1]) & StreamLZConstants.BlockSizeMask12;
                src += 2;
            }
            else
            {
                if (srcEnd - src < 3)
                {
                    throw new InvalidDataException("GetBlockSize: source too short for 3-byte memcopy header");
                }
                srcSize = (src[0] << 16) | (src[1] << 8) | src[2];
                if ((srcSize & ~0x3ffff) != 0)
                {
                    throw new InvalidDataException("GetBlockSize: memcopy long-mode reserved bits are set");
                }
                src += 3;
            }
            if (srcSize > destCapacity || srcEnd - src < srcSize)
            {
                throw new InvalidDataException("GetBlockSize: memcopy block size exceeds destination capacity or source remaining");
            }
            *destSize = srcSize;
            return (int)(src + srcSize - sourceStart);
        }

        if (chunkType >= 6)
        {
            throw new InvalidDataException($"GetBlockSize: invalid chunk type {chunkType} (must be 0-5)");
        }

        // Block size encoding tier 2: short mode = 10+10-bit (0x3ff), long mode = 18+18-bit (0x3ffff).
        if (src[0] >= 0x80)
        {
            if (srcEnd - src < 3)
            {
                throw new InvalidDataException("GetBlockSize: source too short for 3-byte entropy short header");
            }

            uint bits = (uint)((src[0] << 16) | (src[1] << 8) | src[2]);
            srcSize = (int)(bits & StreamLZConstants.BlockSizeMask10);
            dstSize = srcSize + (int)((bits >> 10) & StreamLZConstants.BlockSizeMask10) + 1;
            src += 3;
        }
        else
        {
            if (srcEnd - src < 5)
            {
                throw new InvalidDataException("GetBlockSize: source too short for 5-byte entropy long header");
            }

            uint bits = (uint)((src[1] << 24) | (src[2] << 16) | (src[3] << 8) | src[4]);
            srcSize = (int)(bits & 0x3ffff);
            dstSize = (int)(((bits >> 18) | ((uint)src[0] << 14)) & 0x3FFFF) + 1;
            if (srcSize >= dstSize)
            {
                throw new InvalidDataException("GetBlockSize: compressed size >= decompressed size in long-mode header");
            }
            src += 5;
        }

        if (srcEnd - src < srcSize || dstSize > destCapacity)
        {
            throw new InvalidDataException("GetBlockSize: block payload exceeds source remaining or destination capacity");
        }
        *destSize = dstSize;
        return srcSize;
    }

    #endregion

    #region High_DecodeRLE

    /// <summary>
    /// RLE decoder for High.
    /// Commands are read from the end of the buffer backwards, literals from the front forwards.
    /// Supports both raw and entropy-coded command streams.
    /// </summary>
    [SkipLocalsInit]
    private static int High_DecodeRLE(byte* src, int srcSize, byte* dst, int dstSize,
                                     byte* scratch, byte* scratchEnd, int maxDepth)
    {
        if (srcSize <= 1)
        {
            if (srcSize != 1)
            {
                throw new InvalidDataException("DecodeRLE: source size is zero or negative");
            }
            Unsafe.InitBlockUnaligned(dst, src[0], (uint)dstSize);
            return 1;
        }

        byte* dstEnd = dst + dstSize;
        byte* cmdPtr = src + 1;
        byte* cmdPtrEnd = src + srcSize;

        // Unpack the first X bytes of the command buffer?
        if (src[0] != 0)
        {
            byte* dstPtr = scratch;
            int decSize;
            int n = High_DecodeBytesInternal(&dstPtr, src, src + srcSize, &decSize,
                                       (int)(scratchEnd - scratch), true, scratch, scratchEnd, maxDepth);
            // High_DecodeBytesInternal throws on error; n is always positive on success

            int cmdLen = srcSize - n + decSize;
            if (cmdLen > scratchEnd - scratch)
            {
                throw new InvalidDataException("DecodeRLE: decoded command buffer exceeds scratch space");
            }

            Buffer.MemoryCopy(src + n, dstPtr + decSize, srcSize - n, srcSize - n);
            cmdPtr = dstPtr;
            cmdPtrEnd = &dstPtr[cmdLen];
        }

        int rleByte = 0;

        while (cmdPtr < cmdPtrEnd)
        {
            uint cmd = cmdPtrEnd[-1];
            if (cmd - 1 >= StreamLZConstants.RleShortCommandThreshold)
            {
                cmdPtrEnd--;
                uint bytesToCopy = (~cmd) & 0xF;
                uint bytesToRle = cmd >> 4;

                if (dstEnd - dst < (int)(bytesToCopy + bytesToRle) || cmdPtrEnd - cmdPtr < (int)bytesToCopy)
                {
                    throw new InvalidDataException("DecodeRLE: short command copy+rle length exceeds buffer bounds");
                }

                Buffer.MemoryCopy(cmdPtr, dst, bytesToCopy, bytesToCopy);
                cmdPtr += bytesToCopy;
                dst += bytesToCopy;
                Unsafe.InitBlockUnaligned(dst, (byte)rleByte, bytesToRle);
                dst += bytesToRle;
            }
            else if (cmd >= 0x10)
            {
                uint data = (uint)(*(ushort*)(cmdPtrEnd - 2)) - 4096u;
                cmdPtrEnd -= 2;
                uint bytesToCopy = data & 0x3F;
                uint bytesToRle = data >> 6;

                if (dstEnd - dst < (int)(bytesToCopy + bytesToRle) || cmdPtrEnd - cmdPtr < (int)bytesToCopy)
                {
                    throw new InvalidDataException("DecodeRLE: extended command copy+rle length exceeds buffer bounds");
                }

                Buffer.MemoryCopy(cmdPtr, dst, bytesToCopy, bytesToCopy);
                cmdPtr += bytesToCopy;
                dst += bytesToCopy;
                Unsafe.InitBlockUnaligned(dst, (byte)rleByte, bytesToRle);
                dst += bytesToRle;
            }
            else if (cmd == 1)
            {
                rleByte = *cmdPtr++;
                cmdPtrEnd--;
            }
            else if (cmd >= 9)
            {
                uint bytesToRle = (uint)((*(ushort*)(cmdPtrEnd - 2)) - 0x8ff) * 128;
                cmdPtrEnd -= 2;

                if (dstEnd - dst < (int)bytesToRle)
                {
                    throw new InvalidDataException("DecodeRLE: large RLE run length exceeds destination remaining");
                }

                Unsafe.InitBlockUnaligned(dst, (byte)rleByte, bytesToRle);
                dst += bytesToRle;
            }
            else
            {
                uint bytesToCopy = (uint)((*(ushort*)(cmdPtrEnd - 2)) - 511) * 64;
                cmdPtrEnd -= 2;

                if (cmdPtrEnd - cmdPtr < (int)bytesToCopy || dstEnd - dst < (int)bytesToCopy)
                {
                    throw new InvalidDataException("DecodeRLE: large literal copy length exceeds buffer bounds");
                }

                Buffer.MemoryCopy(cmdPtr, dst, bytesToCopy, bytesToCopy);
                dst += bytesToCopy;
                cmdPtr += bytesToCopy;
            }
        }

        if (cmdPtrEnd != cmdPtr)
        {
            throw new InvalidDataException("DecodeRLE: command and literal pointers did not converge");
        }
        if (dst != dstEnd)
        {
            throw new InvalidDataException("DecodeRLE: output size mismatch after RLE decode");
        }

        return srcSize;
    }

    #endregion

    #region High_DecodeRecursive

    /// <summary>
    /// Recursive entropy decoder: splits a block into N sub-blocks, each decoded by High_DecodeBytes.
    /// Also handles the multi-array variant (bit 7 set).
    /// </summary>
    [SkipLocalsInit]
    private static int High_DecodeRecursive(byte* src, int srcSize, byte* output, int outputSize,
                                           byte* scratch, byte* scratchEnd, int maxDepth)
    {
        byte* sourceStart = src;
        byte* outputEnd = output + outputSize;
        byte* srcEnd = src + srcSize;

        if (srcSize < 6)
        {
            throw new InvalidDataException("DecodeRecursive: source too short for recursive block (need >= 6 bytes)");
        }

        int n = src[0] & 0x7f;
        if (n < 2)
        {
            throw new InvalidDataException($"DecodeRecursive: sub-block count {n} is less than minimum of 2");
        }

        if ((src[0] & 0x80) == 0)
        {
            src++;
            do
            {
                int decodedSize;
                int dec = High_DecodeBytesInternal(&output, src, srcEnd, &decodedSize,
                                             (int)(outputEnd - output), true, scratch, scratchEnd, maxDepth);
                // High_DecodeBytesInternal throws on error; dec is always valid on success
                output += decodedSize;
                src += dec;
            } while (--n != 0);

            if (output != outputEnd)
            {
                throw new InvalidDataException("DecodeRecursive: total decoded sub-block size does not match expected output size");
            }
            return (int)(src - sourceStart);
        }
        else
        {
            byte* arrayData;
            int arrayLen, decodedSize;
            int dec = High_DecodeMultiArrayInternal(src, srcEnd, output, outputEnd,
                                              &arrayData, &arrayLen, 1, &decodedSize,
                                              true, scratch, scratchEnd, maxDepth);
            // High_DecodeMultiArrayInternal throws on error; dec is always valid on success
            output += decodedSize;
            if (output != outputEnd)
            {
                throw new InvalidDataException("DecodeRecursive: multi-array decoded size does not match expected output size");
            }
            return dec;
        }
    }

    #endregion

    #region High_DecodeMultiArray

    /// <summary>
    /// Decodes multiple interleaved entropy-coded arrays from a single compressed block.
    /// Used by the recursive decoder and multi-stream literal coding.
    /// </summary>
    [SkipLocalsInit]
    public static int High_DecodeMultiArray(byte* src, byte* srcEnd,
                                              byte* dst, byte* dstEnd,
                                              byte** arrayData, int* arrayLens,
                                              int arrayCount, int* totalSizeOut,
                                              bool forceMemmove, byte* scratch, byte* scratchEnd)
    {
        return High_DecodeMultiArrayInternal(src, srcEnd, dst, dstEnd, arrayData, arrayLens,
                                              arrayCount, totalSizeOut, forceMemmove, scratch, scratchEnd, maxDepth: 16);
    }

    [SkipLocalsInit]
    private static int High_DecodeMultiArrayInternal(byte* src, byte* srcEnd,
                                              byte* dst, byte* dstEnd,
                                              byte** arrayData, int* arrayLens,
                                              int arrayCount, int* totalSizeOut,
                                              bool forceMemmove, byte* scratch, byte* scratchEnd,
                                              int maxDepth)
    {
        byte* sourceStart = src;

        if (srcEnd - src < 4)
        {
            throw new InvalidDataException("DecodeMultiArray: source too short for multi-array header (need >= 4 bytes)");
        }

        int decodedSize;
        int numArraysInFile = *src++;
        if ((numArraysInFile & 0x80) == 0)
        {
            throw new InvalidDataException("DecodeMultiArray: multi-array marker bit (0x80) not set in header byte");
        }
        numArraysInFile &= 0x3f;

        if (arrayCount <= 0)
        {
            throw new InvalidDataException($"DecodeMultiArray: invalid array count {arrayCount} (must be > 0)");
        }
        if (numArraysInFile > 32)
        {
            throw new InvalidDataException($"DecodeMultiArray: number of arrays in file {numArraysInFile} exceeds maximum of 32");
        }

        if (dst == scratch)
        {
            // 0xC000 (49152 bytes) is reserved at the end of scratch for intermediate
            // entropy decode buffers. Split remaining scratch in half for dst vs workspace.
            scratch += (int)((scratchEnd - scratch - 0xc000) >> 1);
            dstEnd = scratch;
        }

        int totalSize = 0;

        if (numArraysInFile == 0)
        {
            for (int i = 0; i < arrayCount; i++)
            {
                byte* chunkDst = dst;
                int dec = High_DecodeBytesInternal(&chunkDst, src, srcEnd, &decodedSize,
                                             (int)(dstEnd - dst), forceMemmove, scratch, scratchEnd, maxDepth);
                // High_DecodeBytesInternal throws on error; dec is always valid on success
                dst += decodedSize;
                arrayLens[i] = decodedSize;
                arrayData[i] = chunkDst;
                src += dec;
                totalSize += decodedSize;
            }
            *totalSizeOut = totalSize;
            return (int)(src - sourceStart);
        }

        byte** entropyArrayData = stackalloc byte*[32];
        uint* entropyArraySize = stackalloc uint[32];

        // First loop just decodes everything to scratch
        byte* scratchCur = scratch;

        for (int i = 0; i < numArraysInFile; i++)
        {
            byte* chunkDst = scratchCur;
            int dec = High_DecodeBytesInternal(&chunkDst, src, srcEnd, &decodedSize,
                                         (int)(scratchEnd - scratchCur), forceMemmove, scratchCur, scratchEnd, maxDepth);
            // High_DecodeBytesInternal throws on error; dec is always valid on success
            entropyArrayData[i] = chunkDst;
            entropyArraySize[i] = (uint)decodedSize;
            scratchCur += decodedSize;
            totalSize += decodedSize;
            src += dec;
        }
        *totalSizeOut = totalSize;

        if (srcEnd - src < 3)
        {
            throw new InvalidDataException("DecodeMultiArray: source too short for Q-value and index block header");
        }

        int Q = *(ushort*)src;
        src += 2;

        int outSize;
        // High_GetBlockSize throws on error
        High_GetBlockSize(src, srcEnd, &outSize, totalSize);
        int numIndexes = outSize;

        int numLens = numIndexes - arrayCount;
        if (numLens < 1)
        {
            throw new InvalidDataException($"DecodeMultiArray: interval count {numLens} is less than minimum of 1");
        }

        if (scratchEnd - scratchCur < numIndexes)
        {
            throw new InvalidDataException("DecodeMultiArray: insufficient scratch space for interval length log2 array");
        }
        byte* intervalLenlog2 = scratchCur;
        scratchCur += numIndexes;

        if (scratchEnd - scratchCur < numIndexes)
        {
            throw new InvalidDataException("DecodeMultiArray: insufficient scratch space for interval index array");
        }
        byte* intervalIndexes = scratchCur;
        scratchCur += numIndexes;

        if ((Q & 0x8000) != 0)
        {
            int sizeOut;
            int n = High_DecodeBytesInternal(&intervalIndexes, src, srcEnd, &sizeOut, numIndexes,
                                       false, scratchCur, scratchEnd, maxDepth);
            // High_DecodeBytesInternal throws on error; check size match only
            if (sizeOut != numIndexes)
            {
                throw new InvalidDataException($"DecodeMultiArray: packed index+lenlog2 decoded size {sizeOut} != expected {numIndexes}");
            }
            src += n;

            for (int i = 0; i < numIndexes; i++)
            {
                int t = intervalIndexes[i];
                intervalLenlog2[i] = (byte)(t >> 4);
                intervalIndexes[i] = (byte)(t & 0xF);
            }
            numLens = numIndexes;
        }
        else
        {
            int lenlog2Chunksize = numIndexes - arrayCount;

            int sizeOut;
            int n = High_DecodeBytesInternal(&intervalIndexes, src, srcEnd, &sizeOut, numIndexes,
                                       false, scratchCur, scratchEnd, maxDepth);
            // High_DecodeBytesInternal throws on error; check size match only
            if (sizeOut != numIndexes)
            {
                throw new InvalidDataException($"DecodeMultiArray: interval index decoded size {sizeOut} != expected {numIndexes}");
            }
            src += n;

            n = High_DecodeBytesInternal(&intervalLenlog2, src, srcEnd, &sizeOut, lenlog2Chunksize,
                                   false, scratchCur, scratchEnd, maxDepth);
            // High_DecodeBytesInternal throws on error; check size match only
            if (sizeOut != lenlog2Chunksize)
            {
                throw new InvalidDataException($"DecodeMultiArray: interval lenlog2 decoded size {sizeOut} != expected {lenlog2Chunksize}");
            }
            src += n;

            for (int i = 0; i < lenlog2Chunksize; i++)
            {
                if (intervalLenlog2[i] > 16)
                {
                    throw new InvalidDataException($"DecodeMultiArray: interval length log2 value {intervalLenlog2[i]} exceeds maximum of 16 at index {i}");
                }
            }
        }

        if (scratchEnd - scratchCur < 4)
        {
            throw new InvalidDataException("DecodeMultiArray: insufficient scratch space for alignment padding");
        }

        scratchCur = (byte*)(((nuint)scratchCur + 3) & ~(nuint)3);
        if (scratchEnd - scratchCur < numLens * 4)
        {
            throw new InvalidDataException("DecodeMultiArray: insufficient scratch space for decoded interval values");
        }
        uint* decodedIntervals = (uint*)scratchCur;

        int varbitsComplen = Q & 0x3FFF;
        if (srcEnd - src < varbitsComplen)
        {
            throw new InvalidDataException("DecodeMultiArray: source too short for variable-length bit stream");
        }

        byte* f = src;
        uint bitsF = 0;
        int bitposF = 24;

        byte* srcEndActual = src + varbitsComplen;

        byte* b = srcEndActual;
        uint bitsB = 0;
        int bitposB = 24;

        int ii;
        for (ii = 0; ii + 2 <= numLens; ii += 2)
        {
            bitsF |= BinaryPrimitives.ReverseEndianness(*(uint*)f) >> (24 - bitposF);
            f += (bitposF + 7) >> 3;

            bitsB |= ((uint*)b)[-1] >> (24 - bitposB);
            b -= (bitposB + 7) >> 3;

            int numbitsF = intervalLenlog2[ii + 0];
            int numbitsB = intervalLenlog2[ii + 1];

            bitsF = BitOperations.RotateLeft(bitsF | 1, numbitsF);
            bitposF += numbitsF - 8 * ((bitposF + 7) >> 3);

            bitsB = BitOperations.RotateLeft(bitsB | 1, numbitsB);
            bitposB += numbitsB - 8 * ((bitposB + 7) >> 3);

            int valueF = (int)(bitsF & Bitmasks[numbitsF]);
            bitsF &= ~Bitmasks[numbitsF];

            int valueB = (int)(bitsB & Bitmasks[numbitsB]);
            bitsB &= ~Bitmasks[numbitsB];

            decodedIntervals[ii + 0] = (uint)valueF;
            decodedIntervals[ii + 1] = (uint)valueB;
        }

        // Read final one since above loop reads 2
        if (ii < numLens)
        {
            bitsF |= BinaryPrimitives.ReverseEndianness(*(uint*)f) >> (24 - bitposF);
            int numbitsFF = intervalLenlog2[ii];
            bitsF = BitOperations.RotateLeft(bitsF | 1, numbitsFF);
            int valueFF = (int)(bitsF & Bitmasks[numbitsFF]);
            decodedIntervals[ii + 0] = (uint)valueFF;
        }

        if (intervalIndexes[numIndexes - 1] != 0)
        {
            throw new InvalidDataException("DecodeMultiArray: last interval index is not zero (missing terminator)");
        }

        int indi = 0, leni = 0;
        int incrementLeni = ((Q & 0x8000) != 0) ? 1 : 0;

        for (int arri = 0; arri < arrayCount; arri++)
        {
            arrayData[arri] = dst;
            if (indi >= numIndexes)
            {
                throw new InvalidDataException($"DecodeMultiArray: interval index pointer {indi} exceeded total index count {numIndexes}");
            }

            int source;
            while ((source = intervalIndexes[indi++]) != 0)
            {
                if (indi > numIndexes)
                {
                    throw new InvalidDataException("DecodeMultiArray: no zero terminator in interval indexes");
                }
                if (source > numArraysInFile)
                {
                    throw new InvalidDataException($"DecodeMultiArray: interval source index {source} exceeds number of arrays {numArraysInFile}");
                }
                if (leni >= numLens)
                {
                    throw new InvalidDataException($"DecodeMultiArray: interval length index {leni} exceeded total length count {numLens}");
                }
                int curLen = (int)decodedIntervals[leni++];
                int bytesLeft = (int)entropyArraySize[source - 1];
                if (curLen > bytesLeft || curLen > dstEnd - dst)
                {
                    throw new InvalidDataException($"DecodeMultiArray: interval length {curLen} exceeds source array remaining {bytesLeft} or destination remaining");
                }
                byte* blksrc = entropyArrayData[source - 1];
                entropyArraySize[source - 1] -= (uint)curLen;
                entropyArrayData[source - 1] += curLen;
                byte* dstx = dst;
                dst += curLen;
                Buffer.MemoryCopy(blksrc, dstx, curLen, curLen);
            }

            leni += incrementLeni;
            arrayLens[arri] = (int)(dst - arrayData[arri]);
        }

        if (indi != numIndexes || leni != numLens)
        {
            throw new InvalidDataException($"DecodeMultiArray: index/length counters mismatch at end (indi={indi}/{numIndexes}, leni={leni}/{numLens})");
        }

        for (int i = 0; i < numArraysInFile; i++)
        {
            if (entropyArraySize[i] != 0)
            {
                throw new InvalidDataException($"DecodeMultiArray: entropy array {i} has {entropyArraySize[i]} unconsumed bytes");
            }
        }

        return (int)(srcEndActual - sourceStart);
    }

    #endregion

    #region High_DecodeBytes

    /// <summary>
    /// Main entropy decoding dispatcher.
    /// Parses the chunk header then routes to the appropriate decoder:
    ///   Type 0: Memcopy (uncompressed)
    ///   Type 1: TANS
    ///   Type 2: Huffman (2-way split)
    ///   Type 3: RLE
    ///   Type 4: Huffman (4-way split)
    ///   Type 5: Recursive / multi-block
    /// Returns total source bytes consumed.
    /// </summary>
    [SkipLocalsInit]
    public static int High_DecodeBytes(byte** output, byte* src, byte* srcEnd,
                                         int* decodedSize, int outputSize,
                                         bool forceMemmove, byte* scratch, byte* scratchEnd)
    {
        return High_DecodeBytesInternal(output, src, srcEnd, decodedSize, outputSize,
                                        forceMemmove, scratch, scratchEnd, maxDepth: 16);
    }

    /// <summary>
    /// Internal entropy decoding dispatcher with recursive depth limit.
    /// </summary>
    [SkipLocalsInit]
    private static int High_DecodeBytesInternal(byte** output, byte* src, byte* srcEnd,
                                         int* decodedSize, int outputSize,
                                         bool forceMemmove, byte* scratch, byte* scratchEnd,
                                         int maxDepth)
    {
        if (maxDepth <= 0)
        {
            throw new InvalidDataException("DecodeBytesInternal: recursive depth limit exceeded");
        }

        if (outputSize < 0)
        {
            throw new InvalidDataException($"DecodeBytesInternal: invalid negative output size {outputSize}");
        }

        byte* sourceStart = src;
        int srcSize, dstSize;

        if (srcEnd - src < 2)
        {
            throw new InvalidDataException("DecodeBytesInternal: source too short for chunk header (need 2 bytes)");
        }

        int chunkType = (src[0] >> 4) & 0x7;

        if (chunkType == 0)
        {
            // Memcopy / uncompressed
            if (src[0] >= 0x80)
            {
                // Short mode: length in bottom 12 bits
                srcSize = ((src[0] << 8) | src[1]) & StreamLZConstants.BlockSizeMask12;
                src += 2;
            }
            else
            {
                if (srcEnd - src < 3)
                {
                    throw new InvalidDataException("DecodeBytesInternal: source too short for 3-byte memcopy header");
                }
                srcSize = (src[0] << 16) | (src[1] << 8) | src[2];
                if ((srcSize & ~0x3ffff) != 0)
                {
                    throw new InvalidDataException("DecodeBytesInternal: memcopy long-mode reserved bits are set");
                }
                src += 3;
            }

            if (srcSize > outputSize || srcEnd - src < srcSize)
            {
                throw new InvalidDataException("DecodeBytesInternal: memcopy block size exceeds output capacity or source remaining");
            }

            *decodedSize = srcSize;
            if (forceMemmove)
            {
                Buffer.MemoryCopy(src, *output, srcSize, srcSize);
            }
            else
            {
                *output = src;
            }

            return (int)(src + srcSize - sourceStart);
        }

        // All other modes: initial bytes encode src_size and dst_size
        if (src[0] >= 0x80)
        {
            if (srcEnd - src < 3)
            {
                throw new InvalidDataException("DecodeBytesInternal: source too short for 3-byte entropy short header");
            }

            // Short mode, 10 bit sizes
            uint bits = (uint)((src[0] << 16) | (src[1] << 8) | src[2]);
            srcSize = (int)(bits & StreamLZConstants.BlockSizeMask10);
            dstSize = srcSize + (int)((bits >> 10) & StreamLZConstants.BlockSizeMask10) + 1;
            src += 3;
        }
        else
        {
            // Long mode, 18 bit sizes
            if (srcEnd - src < 5)
            {
                throw new InvalidDataException("DecodeBytesInternal: source too short for 5-byte entropy long header");
            }
            uint bits = (uint)((src[1] << 24) | (src[2] << 16) | (src[3] << 8) | src[4]);
            srcSize = (int)(bits & 0x3ffff);
            dstSize = (int)(((bits >> 18) | ((uint)src[0] << 14)) & 0x3FFFF) + 1;
            if (srcSize >= dstSize)
            {
                throw new InvalidDataException("DecodeBytesInternal: compressed size >= decompressed size in long-mode header");
            }
            src += 5;
        }

        if (srcEnd - src < srcSize || dstSize > outputSize)
        {
            throw new InvalidDataException("DecodeBytesInternal: entropy payload exceeds source remaining or output capacity");
        }

        byte* dst = *output;
        if (dst == scratch)
        {
            if (scratchEnd - scratch < dstSize)
            {
                throw new InvalidDataException("DecodeBytesInternal: insufficient scratch space for decoded output");
            }
            scratch += dstSize;
        }

        // All sub-decoders throw on error; srcUsed is always valid after a successful call.
        int srcUsed;
        switch (chunkType)
        {
            case 2: // Huffman 2-way split
            case 4: // Huffman 4-way split
                srcUsed = HuffmanDecoder.High_DecodeBytes_Type12(src, srcSize, dst, dstSize, chunkType >> 1);
                break;

            case 5: // Recursive
                srcUsed = High_DecodeRecursive(src, srcSize, dst, dstSize, scratch, scratchEnd, maxDepth - 1);
                break;

            case 3: // RLE
                srcUsed = High_DecodeRLE(src, srcSize, dst, dstSize, scratch, scratchEnd, maxDepth - 1);
                break;

            case 1: // TANS
                srcUsed = TansDecoder.High_DecodeTans(src, srcSize, dst, dstSize, scratch, scratchEnd);
                break;

            default:
                throw new InvalidDataException($"DecodeBytesInternal: unsupported chunk type {chunkType}");
        }

        if (srcUsed != srcSize)
        {
            throw new InvalidDataException($"DecodeBytesInternal: sub-decoder consumed {srcUsed} bytes but expected {srcSize}");
        }

        *decodedSize = dstSize;
        return (int)(src + srcSize - sourceStart);
    }

    #endregion
}
