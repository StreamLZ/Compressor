// HuffmanDecoder.Decode.cs — 3-stream parallel Huffman decode loop and block-level entry point.

using System.Buffers.Binary;
using System.IO;
using System.Runtime.CompilerServices;
using StreamLZ.Common;

namespace StreamLZ.Decompression.Entropy;

internal static unsafe partial class HuffmanDecoder
{
    #region High_DecodeBytesCore

    /// <summary>
    /// Core 3-stream parallel Huffman decoder.
    /// The compressed data is split into 3 independent bitstreams (forward, backward, middle)
    /// that are decoded simultaneously — 2 symbols from each per iteration = 6 symbols/loop.
    /// This hides the serial dependency in bit consumption by interleaving 3 independent chains.
    /// The forward and middle streams read left-to-right; the backward stream reads right-to-left
    /// with reversed bit order (hence the separate HuffRevLut with bit-reversed lookup tables).
    /// </summary>
    [SkipLocalsInit]
    public static bool High_DecodeBytesCore(HuffReader* huffmanReader, HuffRevLut* lut)
    {
        byte* src = huffmanReader->Src;
        uint srcBits = huffmanReader->SrcBits;
        int srcBitpos = huffmanReader->SrcBitpos;

        byte* srcMid = huffmanReader->SrcMid;
        uint srcMidBits = huffmanReader->SrcMidBits;
        int srcMidBitpos = huffmanReader->SrcMidBitpos;

        byte* srcEnd = huffmanReader->SrcEnd;
        uint srcEndBits = huffmanReader->SrcEndBits;
        int srcEndBitpos = huffmanReader->SrcEndBitpos;

        int lutIndex, codeBitLength;

        byte* dst = huffmanReader->Output;
        byte* dstEnd = huffmanReader->OutputEnd;

        if (src > srcMid)
        {
            return false;
        }

        if (huffmanReader->SrcEnd - srcMid >= 4 && dstEnd - dst >= 6)
        {
            dstEnd -= 5;
            srcEnd -= 4;

            while (dst < dstEnd && src <= srcMid && srcMid <= srcEnd)
            {
                // Refill: load 4 bytes into each stream's bit buffer. The advance formula
                // (31 - bitpos) >> 3 consumes 0-3 bytes depending on how many bits remain.
                // SAFETY: 4-byte reads may extend 1-3 bytes past the logical stream boundary.
                // The scratch buffer provides sufficient padding beyond each sub-stream region.
                // This is standard practice in high-performance bitstream decoders (LZ4, Zstd).
                srcBits |= *(uint*)src << srcBitpos;
                src += (31 - srcBitpos) >> 3;

                // Backward stream: bytes are loaded in reverse order (big-endian read).
                srcEndBits |= BinaryPrimitives.ReverseEndianness(*(uint*)srcEnd) << srcEndBitpos;
                srcEnd -= (31 - srcEndBitpos) >> 3;

                srcMidBits |= *(uint*)srcMid << srcMidBitpos;
                srcMid += (31 - srcMidBitpos) >> 3;

                // OR with 0x18 sets bits 3 and 4, clamping bitpos to at least 24.
                // This ensures a minimum of 24 valid bits are available after refill,
                // which is enough for two 11-bit Huffman lookups without re-refilling.
                srcBitpos |= StreamLZConstants.HuffmanBitposClampMask;
                srcEndBitpos |= StreamLZConstants.HuffmanBitposClampMask;
                srcMidBitpos |= StreamLZConstants.HuffmanBitposClampMask;

                // Decode 2 symbols from each of the 3 streams = 6 symbols per iteration.
                // Each lookup: mask low 11 bits → index into precomputed LUT → get symbol + code length.
                lutIndex = (int)(srcBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcBits >>= codeBitLength;
                srcBitpos -= codeBitLength;
                dst[0] = lut->Bits2Sym[lutIndex];

                lutIndex = (int)(srcEndBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcEndBits >>= codeBitLength;
                srcEndBitpos -= codeBitLength;
                dst[1] = lut->Bits2Sym[lutIndex];

                lutIndex = (int)(srcMidBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcMidBits >>= codeBitLength;
                srcMidBitpos -= codeBitLength;
                dst[2] = lut->Bits2Sym[lutIndex];

                lutIndex = (int)(srcBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcBits >>= codeBitLength;
                srcBitpos -= codeBitLength;
                dst[3] = lut->Bits2Sym[lutIndex];

                lutIndex = (int)(srcEndBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcEndBits >>= codeBitLength;
                srcEndBitpos -= codeBitLength;
                dst[4] = lut->Bits2Sym[lutIndex];

                lutIndex = (int)(srcMidBits & StreamLZConstants.HuffmanLutMask);
                codeBitLength = lut->Bits2Len[lutIndex];
                srcMidBits >>= codeBitLength;
                srcMidBitpos -= codeBitLength;
                dst[5] = lut->Bits2Sym[lutIndex];

                dst += 6;
            }

            dstEnd += 5;

            src -= srcBitpos >> 3;
            srcBitpos &= 7;

            srcEnd += 4 + (srcEndBitpos >> 3);
            srcEndBitpos &= 7;

            srcMid -= srcMidBitpos >> 3;
            srcMidBitpos &= 7;
        }

        // Tail loop: decode one symbol at a time from each stream
        for (; ; )
        {
            if (dst >= dstEnd)
            {
                break;
            }

            if (srcMid - src <= 1)
            {
                if (srcMid - src == 1)
                {
                    srcBits |= (uint)*src << srcBitpos;
                }
            }
            else
            {
                srcBits |= (uint)(*(ushort*)src) << srcBitpos;
            }

            lutIndex = (int)(srcBits & StreamLZConstants.HuffmanLutMask);
            codeBitLength = lut->Bits2Len[lutIndex];
            srcBitpos -= codeBitLength;
            srcBits >>= codeBitLength;
            *dst++ = lut->Bits2Sym[lutIndex];
            src += (7 - srcBitpos) >> 3;
            srcBitpos &= 7;

            if (dst < dstEnd)
            {
                if (srcEnd - srcMid <= 1)
                {
                    if (srcEnd - srcMid == 1)
                    {
                        srcEndBits |= (uint)*srcMid << srcEndBitpos;
                        srcMidBits |= (uint)*srcMid << srcMidBitpos;
                    }
                }
                else
                {
                    uint v = *(ushort*)(srcEnd - 2);
                    srcEndBits |= (uint)(((v >> 8) | (v << 8)) & 0xffff) << srcEndBitpos;
                    srcMidBits |= (uint)(*(ushort*)srcMid) << srcMidBitpos;
                }

                codeBitLength = lut->Bits2Len[srcEndBits & StreamLZConstants.HuffmanLutMask];
                *dst++ = lut->Bits2Sym[srcEndBits & StreamLZConstants.HuffmanLutMask];
                srcEndBitpos -= codeBitLength;
                srcEndBits >>= codeBitLength;
                srcEnd -= (7 - srcEndBitpos) >> 3;
                srcEndBitpos &= 7;

                if (dst < dstEnd)
                {
                    codeBitLength = lut->Bits2Len[srcMidBits & StreamLZConstants.HuffmanLutMask];
                    *dst++ = lut->Bits2Sym[srcMidBits & StreamLZConstants.HuffmanLutMask];
                    srcMidBitpos -= codeBitLength;
                    srcMidBits >>= codeBitLength;
                    srcMid += (7 - srcMidBitpos) >> 3;
                    srcMidBitpos &= 7;
                }
            }

            if (src > srcMid || srcMid > srcEnd)
            {
                return false;
            }
        }

        if (src != huffmanReader->SrcMidOrg || srcEnd != srcMid)
        {
            return false;
        }

        return true;
    }

    #endregion

    #region High_DecodeBytes_Type12

    /// <summary>
    /// Decodes a Huffman-coded byte block (type 1 = 2-way split, type 2 = 4-way split).
    /// Builds the Huffman table, then runs the 3-stream parallel decoder on each half.
    /// </summary>
    [SkipLocalsInit]
    public static int High_DecodeBytes_Type12(byte* src, int srcSize, byte* output, int outputSize, int type)
    {
        if (srcSize <= 0 || outputSize <= 0)
        {
            throw new InvalidDataException("Huffman block: source or output size is zero or negative");
        }

        BitReaderState bits;
        int halfOutputSize;
        uint splitLeft, splitMid, splitRight;
        byte* srcMid;
        NewHuffLut huffLut;
        HuffReader hr;
        HuffRevLut revLut;
        byte* srcEnd = src + srcSize;

        bits.Bitpos = 24;
        bits.Bits = 0;
        bits.P = src;
        bits.PEnd = srcEnd;
        BitReader_Refill(ref bits);

        uint* codePrefixOrgPtr = stackalloc uint[12];
        uint* codePrefixPtr = stackalloc uint[12];
        ReadOnlySpan<uint> cpOrg = CodePrefixOrg;
        for (int i = 0; i < 12; i++)
        {
            codePrefixOrgPtr[i] = cpOrg[i];
            codePrefixPtr[i] = cpOrg[i];
        }

        byte* syms = stackalloc byte[1280];
        int numSyms;

        if (BitReader_ReadBitNoRefill(ref bits) == 0)
        {
            numSyms = Huff_ReadCodeLengthsOld(ref bits, syms, codePrefixPtr);
        }
        else if (BitReader_ReadBitNoRefill(ref bits) == 0)
        {
            numSyms = Huff_ReadCodeLengthsNew(ref bits, syms, codePrefixPtr);
        }
        else
        {
            throw new InvalidDataException("Huffman block: unrecognized code length table format");
        }

        if (numSyms < 1)
        {
            throw new InvalidDataException("Huffman block: no symbols decoded from code length table");
        }

        src = bits.P - ((24 - bits.Bitpos) / 8);

        if (numSyms == 1)
        {
            Unsafe.InitBlockUnaligned(output, syms[0], (uint)outputSize);
            return srcSize;
        }

        if (!Huff_MakeLut(codePrefixOrgPtr, codePrefixPtr, &huffLut, syms))
        {
            throw new InvalidDataException("Huffman block: LUT construction failed (invalid canonical code)");
        }

        ReverseBitsArray2048(huffLut.Bits2Len, revLut.Bits2Len);
        ReverseBitsArray2048(huffLut.Bits2Sym, revLut.Bits2Sym);

        if (type == 1)
        {
            if (src + 3 > srcEnd)
            {
                throw new InvalidDataException("Huffman block type 1: insufficient source data for split offset");
            }

            splitMid = *(ushort*)src;
            src += 2;

            if (splitMid > (uint)(srcEnd - src))
            {
                throw new InvalidDataException("Huffman block type 1: mid-stream split offset exceeds remaining source data");
            }

            hr.Output = output;
            hr.OutputEnd = output + outputSize;
            hr.Src = src;
            hr.SrcEnd = srcEnd;
            hr.SrcMidOrg = hr.SrcMid = src + splitMid;
            hr.SrcBitpos = 0;
            hr.SrcBits = 0;
            hr.SrcMidBitpos = 0;
            hr.SrcMidBits = 0;
            hr.SrcEndBitpos = 0;
            hr.SrcEndBits = 0;

            if (!High_DecodeBytesCore(&hr, &revLut))
            {
                throw new InvalidDataException("Huffman block type 1: 3-stream decode failed (stream pointer mismatch)");
            }
        }
        else
        {
            if (src + 6 > srcEnd)
            {
                throw new InvalidDataException("Huffman block type 2: insufficient source data for split offsets");
            }

            halfOutputSize = (outputSize + 1) >> 1;
            splitMid = *(uint*)src & 0xFFFFFF;
            src += 3;

            if (splitMid > (uint)(srcEnd - src))
            {
                throw new InvalidDataException("Huffman block type 2: mid-stream split offset exceeds remaining source data");
            }

            srcMid = src + splitMid;
            splitLeft = *(ushort*)src;
            src += 2;

            if (srcMid - src < splitLeft + 2 || srcEnd - srcMid < 3)
            {
                throw new InvalidDataException("Huffman block type 2: left split offset or second-half header exceeds available data");
            }

            splitRight = *(ushort*)srcMid;
            if (srcEnd - (srcMid + 2) < splitRight + 2)
            {
                throw new InvalidDataException("Huffman block type 2: right split offset exceeds available data in second half");
            }

            // First half
            hr.Output = output;
            hr.OutputEnd = output + halfOutputSize;
            hr.Src = src;
            hr.SrcEnd = srcMid;
            hr.SrcMidOrg = hr.SrcMid = src + splitLeft;
            hr.SrcBitpos = 0;
            hr.SrcBits = 0;
            hr.SrcMidBitpos = 0;
            hr.SrcMidBits = 0;
            hr.SrcEndBitpos = 0;
            hr.SrcEndBits = 0;

            if (!High_DecodeBytesCore(&hr, &revLut))
            {
                throw new InvalidDataException("Huffman block type 2: first-half 3-stream decode failed (stream pointer mismatch)");
            }

            // Second half
            hr.Output = output + halfOutputSize;
            hr.OutputEnd = output + outputSize;
            hr.Src = srcMid + 2;
            hr.SrcEnd = srcEnd;
            hr.SrcMidOrg = hr.SrcMid = srcMid + 2 + splitRight;
            hr.SrcBitpos = 0;
            hr.SrcBits = 0;
            hr.SrcMidBitpos = 0;
            hr.SrcMidBits = 0;
            hr.SrcEndBitpos = 0;
            hr.SrcEndBits = 0;

            if (!High_DecodeBytesCore(&hr, &revLut))
            {
                throw new InvalidDataException("Huffman block type 2: second-half 3-stream decode failed (stream pointer mismatch)");
            }
        }

        return srcSize;
    }

    #endregion
}
