using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Compression.Entropy;
using StreamLZ.Compression.MatchFinding;
using StreamLZ.Decompression;
using StreamLZ.Decompression.Entropy;
using StreamLZ.Decompression.High;
using StreamLZ.Compression.High;
using StreamLZ;
using Xunit;

namespace StreamLZ.Tests;

// ================================================================
//  BitOps Tests
// ================================================================

public class BitOpsTests
{
    [Theory]
    [InlineData(1u, 0)]
    [InlineData(2u, 1)]
    [InlineData(3u, 1)]
    [InlineData(4u, 2)]
    [InlineData(0x80000000u, 31)]
    [InlineData(0xFFFFFFFFu, 31)]
    public void BSR_ReturnsHighestSetBitIndex(uint input, int expected)
    {
        Assert.Equal((uint)expected, (uint)BitOperations.Log2(input));
    }

    [Theory]
    [InlineData(1u, 0)]
    [InlineData(2u, 1)]
    [InlineData(4u, 2)]
    [InlineData(6u, 1)]
    [InlineData(0x80000000u, 31)]
    public void BSF_ReturnsLowestSetBitIndex(uint input, int expected)
    {
        Assert.Equal((uint)expected, (uint)BitOperations.TrailingZeroCount(input));
    }

    [Theory]
    [InlineData(0u, 32)]
    [InlineData(1u, 31)]
    [InlineData(0x80000000u, 0)]
    [InlineData(0x00010000u, 15)]
    public void CountLeadingZeros_MatchesBitOperations(uint input, int expected)
    {
        Assert.Equal(expected, (int)BitOperations.LeadingZeroCount(input));
    }

    [Theory]
    [InlineData(0u, 0)]
    [InlineData(1u, 0)]
    [InlineData(2u, 1)]
    [InlineData(3u, 2)]
    [InlineData(4u, 2)]
    [InlineData(5u, 3)]
    [InlineData(8u, 3)]
    [InlineData(9u, 4)]
    [InlineData(256u, 8)]
    public void Log2RoundUp_ReturnsCeilingLog2(uint input, int expected)
    {
        int result = input > 1 ? BitOperations.Log2(input - 1) + 1 : 0;
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData(0x80000001u, 1, 0x00000003u)]
    [InlineData(0x00000001u, 0, 0x00000001u)]
    [InlineData(0xFFFFFFFFu, 16, 0xFFFFFFFFu)]
    public void RotateLeft_MatchesBitOperations(uint input, int n, uint expected)
    {
        Assert.Equal(expected, BitOperations.RotateLeft(input, n));
    }
}

// ================================================================
//  BitReader Tests
// ================================================================

public unsafe class BitReaderTests
{
    [Fact]
    public void Refill_FillsAtLeast24Bits()
    {
        byte[] data = [0xAB, 0xCD, 0xEF, 0x12, 0x34];
        fixed (byte* p = data)
        {
            var br = new BitReader { P = p, PEnd = p + data.Length, Bits = 0, BitPos = 24 };
            br.Refill();

            // After refill, BitPos should be <= 0 (at least 24 bits available)
            Assert.True(br.BitPos <= 0, $"BitPos should be <= 0 after refill, got {br.BitPos}");
            // Bits should contain data from the stream
            Assert.NotEqual(0u, br.Bits);
        }
    }

    [Fact]
    public void RefillBackwards_ReadsInReverse()
    {
        byte[] data = [0x11, 0x22, 0x33, 0x44, 0x55];
        fixed (byte* p = data)
        {
            // Start P at end, PEnd is the lower bound
            var br = new BitReader { P = p + data.Length, PEnd = p, Bits = 0, BitPos = 24 };
            br.RefillBackwards();

            Assert.True(br.BitPos <= 0);
            Assert.NotEqual(0u, br.Bits);
        }
    }

    [Fact]
    public void ReadBitsNoRefill_ReturnsCorrectBits()
    {
        // Load 0xABCDEF12 into Bits
        var br = new BitReader { Bits = 0xABCDEF12, BitPos = 0 };

        // Read top 8 bits: should be 0xAB
        int val = br.ReadBitsNoRefill(8);
        Assert.Equal(0xAB, val);
        Assert.Equal(8, br.BitPos);

        // Read next 8 bits: should be 0xCD
        val = br.ReadBitsNoRefill(8);
        Assert.Equal(0xCD, val);
        Assert.Equal(16, br.BitPos);
    }

    [Fact]
    public void ReadBitsNoRefillZero_WithZeroBits_ReturnsZero()
    {
        var br = new BitReader { Bits = 0xFFFFFFFF, BitPos = 0 };
        int val = br.ReadBitsNoRefillZero(0);
        Assert.Equal(0, val);
        Assert.Equal(0, br.BitPos);
    }

    [Fact]
    public void ReadBitNoRefill_ReturnsMSB()
    {
        var br = new BitReader { Bits = 0x80000000, BitPos = 0 };
        Assert.Equal(1, br.ReadBitNoRefill());

        br.Bits = 0x00000000;
        br.BitPos = 0;
        Assert.Equal(0, br.ReadBitNoRefill());
    }

    [Fact]
    public void ReadBit_WithRefill_ReadsFromStream()
    {
        byte[] data = [0x80, 0x00, 0x00, 0x00];
        fixed (byte* p = data)
        {
            var br = new BitReader { P = p, PEnd = p + data.Length, Bits = 0, BitPos = 24 };
            int bit = br.ReadBit();
            // First byte is 0x80 -> first bit loaded should be 1
            Assert.Equal(1, bit);
        }
    }

    [Fact]
    public void ReadGamma_DecodesSimpleValues()
    {
        // Gamma encoding: value v is encoded as (v+2) in unary+binary
        // For v=0: encoded as "10" (2 bits for value 2, minus 2 = 0)
        // Bits: 10xxxxxx... (0x80000000 with MSBs)
        var br = new BitReader { Bits = 0x80000000, BitPos = 0 };
        int val = br.ReadGamma();
        Assert.Equal(0, val);
    }

    [Fact]
    public unsafe void ReadMoreThan24Bits_SmallN_Works()
    {
        // Provide backing data so Refill() doesn't dereference null
        byte[] data = new byte[16];
        fixed (byte* p = data)
        {
            var br = new BitReader { Bits = 0xFF000000, BitPos = 0, P = p, PEnd = p + data.Length };
            // Read 8 bits
            uint val = br.ReadMoreThan24Bits(8);
            Assert.Equal(0xFFu, val);
        }
    }

    [Fact]
    public void ReadLength_ValidCode_ReturnsTrueAndValue()
    {
        // A valid length code: starts with a 1 bit (0 leading zeros)
        // Then 7 more bits for the value
        // Bits: 1VVVVVVV where V = value bits
        byte[] data = [0x00, 0x00, 0x00, 0x00]; // padding for refill
        fixed (byte* p = data)
        {
            // Bits = 0xC0000000 = 1100_0000_0...
            // Leading zeros = 0, n starts at 0
            // After shift 0: Bits unchanged. Refill from all-zero stream.
            // n += 7 -> n = 7
            // value = (0xC0000000 >> 25) - 64 = 96 - 64 = 32
            var br = new BitReader { P = p, PEnd = p + data.Length, Bits = 0xC0000000, BitPos = 0 };
            bool ok = br.ReadLength(out uint v);
            Assert.True(ok);
            Assert.Equal(32u, v);
        }
    }

    [Fact]
    public void ReadLength_TooManyLeadingZeros_ReturnsFalse()
    {
        // 13+ leading zeros -> invalid
        var br = new BitReader { Bits = 0x00020000, BitPos = 0 }; // 14 leading zeros
        bool ok = br.ReadLength(out _);
        Assert.False(ok);
    }
}

// ================================================================
//  Types / Constants Tests
// ================================================================

public class TypesTests
{
    [Fact]
    public void CodecType_HasCorrectValues()
    {
        Assert.Equal(0, (int)CodecType.High);
        Assert.Equal(1, (int)CodecType.Fast);
        Assert.Equal(2, (int)CodecType.Turbo);
    }

    [Fact]
    public void Constants_ChunkSize_Is256KB()
    {
        Assert.Equal(0x40000, StreamLZConstants.ChunkSize);
        Assert.Equal(262144, StreamLZConstants.ChunkSize);
    }

    [Fact]
    public void Constants_ScratchSize_Is440KB()
    {
        Assert.Equal(0x6C000, StreamLZConstants.ScratchSize);
    }

    [Fact]
    public void StreamLZHeader_DefaultsToZero()
    {
        var hdr = new StreamLZHeader();
        Assert.Equal(0, (int)hdr.DecoderType);
        Assert.False(hdr.RestartDecoder);
        Assert.False(hdr.Uncompressed);
        Assert.False(hdr.UseChecksums);
    }

    [Fact]
    public void ChunkHeader_DefaultsToZero()
    {
        var header = new ChunkHeader();
        Assert.Equal(0u, header.CompressedSize);
        Assert.Equal(0u, header.Checksum);
        Assert.Equal(0u, header.WholeMatchDistance);
    }

    [Fact]
    public unsafe void HighLzTable_HasCorrectLayout()
    {
        var table = new HighLzTable();
        Assert.True(table.CmdStream == null);
        Assert.Equal(0, table.CmdStreamSize);
        Assert.True(table.OffsStream == null);
        Assert.Equal(0, table.OffsStreamSize);
        Assert.True(table.LitStream == null);
        Assert.Equal(0, table.LitStreamSize);
        Assert.True(table.LenStream == null);
        Assert.Equal(0, table.LenStreamSize);
    }

    [Fact]
    public unsafe void HuffRevLut_Has2048Entries()
    {
        // Verify the fixed buffer sizes are correct at the type level
        Assert.Equal(2048 * 2, Unsafe.SizeOf<HuffRevLut>());
    }

    [Fact]
    public void StreamLZDecoderState_InitializesWithScratch()
    {
        var state = new StreamLZDecoderState();
        Assert.NotNull(state.Scratch);
        Assert.Equal(StreamLZConstants.ScratchSize, state.ScratchSize);
        // ArrayPool.Rent may return a larger buffer than requested
        Assert.True(state.Scratch.Length >= StreamLZConstants.ScratchSize);
    }
}

// ================================================================
//  StreamLZDecoder Integration Tests
// ================================================================

public unsafe class StreamLZDecoderTests
{
    [Fact]
    public void Decompress_InvalidHeader_Throws()
    {
        // All zeros is not a valid StreamLZ header (low nibble must be 0xA)
        byte[] src = [0x00, 0x00, 0x00, 0x00];
        byte[] dst = new byte[256 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 256));
    }

    [Fact]
    public void Decompress_EmptySource_ZeroDecompressedSize_ReturnsZero()
    {
        byte[] dst = new byte[64 + StreamLZDecoder.SafeSpace];
        // Empty source with 0 decompressed size -- no data to decode
        int result = StreamLZDecoder.Decompress(Array.Empty<byte>(), dst, 0);
        Assert.Equal(0, result);
    }

    [Fact]
    public void Decompress_GarbageData_Throws()
    {
        byte[] src = [0xCA, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]; // valid magic but bad chunk data
        byte[] dst = new byte[1024 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 1024));
    }

    [Fact]
    public void Decompress_UnsupportedDecoderType_Throws()
    {
        // Header: low nibble 0xA, decoder_type = 7 (not supported)
        byte[] src = [0x0A, 0x07, 0x00, 0x00];
        byte[] dst = new byte[256 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 256));
    }

    [Fact]
    public void Decompress_ValidHighHeader_FailsOnChunkData()
    {
        // Byte 0: 0x0A -> low nibble A, bits 4-5 = 0, bit 6 = 0 (no restart), bit 7 = 0 (not uncompressed)
        // Byte 1: 0x02 -> decoder_type = 2 (High), bit 7 = 0 (no checksums)
        // This is a valid header, but the chunk data will be invalid
        byte[] src = [0x0A, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        byte[] dst = new byte[256 + StreamLZDecoder.SafeSpace];

        // Should fail on chunk header parse, not header parse
        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 256));
    }

    [Fact]
    public void Decompress_PointerOverload_BothThrowOnInvalidData()
    {
        byte[] src = [0x00, 0x00, 0x00, 0x00];
        byte[] dst1 = new byte[256 + StreamLZDecoder.SafeSpace];
        byte[] dst2 = new byte[256 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst1, 256));

        Assert.Throws<InvalidDataException>(() =>
        {
            fixed (byte* srcPtr = src)
            fixed (byte* dstPtr = dst2)
            {
                StreamLZDecoder.Decompress(srcPtr, src.Length, dstPtr, 256);
            }
        });
    }

    [Fact]
    public void SafeSpace_Is64()
    {
        Assert.Equal(64, StreamLZDecoder.SafeSpace);
    }
}

// ================================================================
//  HuffmanDecoder Structural Tests
// ================================================================

public unsafe class HuffmanDecoderTests
{
    [Fact]
    public void HuffRange_HasCorrectSize()
    {
        Assert.Equal(4, Unsafe.SizeOf<HuffmanDecoder.HuffRange>());
    }

    [Fact]
    public void HuffRevLut_InHuffmanDecoder_Has2048Entries()
    {
        Assert.Equal(2048 * 2, Unsafe.SizeOf<HuffRevLut>());
    }

    [Fact]
    public void NewHuffLut_HasOverflowGuard()
    {
        // NewHuffLut has 2048+16 entries for both arrays
        int expectedSize = (2048 + 16) * 2;
        Assert.Equal(expectedSize, Unsafe.SizeOf<NewHuffLut>());
    }
}

// ================================================================
//  FastLzTable Tests
// ================================================================

public unsafe class FastLzTableTests
{
    [Fact]
    public void FastLzTable_DefaultsToNull()
    {
        var table = new FastLzTable();
        Assert.True(table.CommandStream.Start == null);
        Assert.True(table.CommandStream.End == null);
        Assert.True(table.LengthStream == null);
        Assert.True(table.LiteralStream.Start == null);
        Assert.True(table.LiteralStream.End == null);
        Assert.True(table.Offset16Stream.Start == null);
        Assert.True(table.Offset16Stream.End == null);
        Assert.True(table.Offset32Stream.Start == null);
        Assert.True(table.Offset32Stream.End == null);
        Assert.True(table.Offset32BackingStream1 == null);
        Assert.True(table.Offset32BackingStream2 == null);
        Assert.Equal(0u, table.Offset32Count1);
        Assert.Equal(0u, table.Offset32Count2);
        Assert.Equal(0u, table.CommandStream2Offset);
        Assert.Equal(0u, table.CommandStream2OffsetEnd);
    }
}

// ================================================================
//  Header Parsing Edge Case Tests
// ================================================================

public unsafe class HeaderParsingTests
{
    [Theory]
    [InlineData(0x0A, 0x02)]   // High, no flags
    [InlineData(0x0A, 0x03)]   // Fast
    [InlineData(0x0A, 0x04)]   // Turbo
    [InlineData(0xCA, 0x02)]   // High + restart + uncompressed
    [InlineData(0x4A, 0x02)]   // High + restart
    [InlineData(0x8A, 0x02)]   // High + uncompressed
    [InlineData(0x0A, 0x82)]   // High + checksums
    public void Decompress_HeaderParsing_ValidHeaders_FailOnChunkNotHeader(byte b0, byte b1)
    {
        // We can't directly test ParseHeader (it's private), but we can verify
        // the decoder doesn't reject valid headers by checking it gets past header parsing.
        // A valid header + invalid chunk data should throw InvalidDataException, not crash.
        byte[] src = [b0, b1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        byte[] dst = new byte[1024 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 1024));
    }

    [Theory]
    [InlineData(0x0C)]  // Wrong low nibble (old magic)
    [InlineData(0x2A)]  // bit 5 set (reserved must be 0)
    [InlineData(0x3A)]  // bits 4+5 set (reserved bit 5 must be 0)
    [InlineData(0x0D)]  // Wrong low nibble
    public void Decompress_InvalidHeaderByte0_Throws(byte b0)
    {
        byte[] src = [b0, 0x02, 0x00, 0x00];
        byte[] dst = new byte[256 + StreamLZDecoder.SafeSpace];

        // Decoder may throw InvalidDataException directly (serial path)
        // or AggregateException wrapping InvalidDataException (parallel path).
        var ex = Assert.ThrowsAny<Exception>(() =>
            StreamLZDecoder.Decompress(src, dst, 256));
        Assert.True(
            ex is InvalidDataException ||
            (ex is AggregateException agg && agg.InnerExceptions.Any(e => e is InvalidDataException)),
            $"Expected InvalidDataException but got {ex.GetType().Name}: {ex.Message}");
    }

    [Theory]
    [InlineData(0x00)]  // decoder_type = 0 (invalid)
    [InlineData(0x01)]  // decoder_type = 1 (LZNA, unsupported)
    [InlineData(0x05)]  // decoder_type = 5 (Ultra, unsupported)
    [InlineData(0x06)]  // decoder_type = 6 (invalid, old High value)
    [InlineData(0x07)]  // decoder_type = 7 (invalid)
    [InlineData(0x0A)]  // decoder_type = 10 (invalid, old Fast value)
    [InlineData(0x0C)]  // decoder_type = 12 (invalid, old Ultra value)
    [InlineData(0x7F)]  // decoder_type = 127 (invalid)
    public void Decompress_UnsupportedDecoderTypes_Throws(byte b1)
    {
        byte[] src = [0x0A, b1, 0x00, 0x00];
        byte[] dst = new byte[256 + StreamLZDecoder.SafeSpace];

        Assert.Throws<InvalidDataException>(() =>
            StreamLZDecoder.Decompress(src, dst, 256));
    }
}

// ================================================================
//  StreamLZConstants Tests
// ================================================================

public class StreamLZConstantsTests
{
    [Fact]
    public void ChunkSize_Is0x40000()
    {
        Assert.Equal(0x40000, StreamLZConstants.ChunkSize);
    }

    [Fact]
    public void ScratchSize_Is0x6C000()
    {
        Assert.Equal(0x6C000, StreamLZConstants.ScratchSize);
    }

    [Fact]
    public void MaxDictionarySize_Is0x40000000()
    {
        Assert.Equal(0x40000000, StreamLZConstants.MaxDictionarySize);
    }

    [Fact]
    public void OffsetBiasConstant_Is760()
    {
        Assert.Equal(760, StreamLZConstants.OffsetBiasConstant);
    }

    [Fact]
    public void HighOffsetThreshold_Is16776456()
    {
        Assert.Equal(16776456, StreamLZConstants.HighOffsetThreshold);
    }

    [Fact]
    public void LowOffsetEncodingLimit_Is16710912()
    {
        Assert.Equal(16710912, StreamLZConstants.LowOffsetEncodingLimit);
    }

    [Fact]
    public void HighOffsetMarker_Is0xF0()
    {
        Assert.Equal(0xF0, StreamLZConstants.HighOffsetMarker);
    }

    [Fact]
    public void HighOffsetCostAdjust_Is0xE0()
    {
        Assert.Equal(0xE0, StreamLZConstants.HighOffsetCostAdjust);
    }

    [Fact]
    public void HuffmanLutSize_Is2048()
    {
        Assert.Equal(2048, StreamLZConstants.HuffmanLutSize);
    }

    [Fact]
    public void HuffmanLutBits_Is11()
    {
        Assert.Equal(11, StreamLZConstants.HuffmanLutBits);
    }

    [Fact]
    public void AlphabetSize_Is256()
    {
        Assert.Equal(256, StreamLZConstants.AlphabetSize);
    }

    [Fact]
    public void HashPositionMask_Is0x01FFFFFF()
    {
        Assert.Equal(0x01FFFFFFu, StreamLZConstants.HashPositionMask);
    }

    [Fact]
    public void HashTagMask_Is0xFE000000()
    {
        Assert.Equal(0xFE000000u, StreamLZConstants.HashTagMask);
    }

    [Fact]
    public void HashMasks_AreComplementary()
    {
        // Position mask and tag mask together should cover all 32 bits
        Assert.Equal(0xFFFFFFFFu, StreamLZConstants.HashPositionMask | StreamLZConstants.HashTagMask);
    }

    [Fact]
    public void HighOffsetCostAdjust_EqualsMarkerMinus16()
    {
        Assert.Equal(StreamLZConstants.HighOffsetMarker - 16, StreamLZConstants.HighOffsetCostAdjust);
    }
}

// ================================================================
//  CopyHelpers Tests
// ================================================================

public unsafe class CopyHelpersTests
{
    [Fact]
    public void Copy64_CopiesExactly8Bytes()
    {
        byte[] src = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xAA, 0xBB];
        byte[] dst = new byte[16];

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64(pDst, pSrc);
        }

        for (int i = 0; i < 8; i++)
            Assert.Equal(src[i], dst[i]);
    }

    [Fact]
    public void Copy64_DoesNotWriteBeyond8Bytes()
    {
        byte[] src = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
        byte[] dst = new byte[16];
        // Fill sentinel bytes beyond the 8-byte copy region
        for (int i = 8; i < 16; i++)
            dst[i] = 0xFF;

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64(pDst, pSrc);
        }

        // Sentinel bytes should be untouched
        for (int i = 8; i < 16; i++)
            Assert.Equal(0xFF, dst[i]);
    }

    [Fact]
    public void Copy64Bytes_CopiesExactly64Bytes()
    {
        byte[] src = new byte[80];
        for (int i = 0; i < 80; i++)
            src[i] = (byte)(i + 1);

        byte[] dst = new byte[80];

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64Bytes(pDst, pSrc);
        }

        for (int i = 0; i < 64; i++)
            Assert.Equal(src[i], dst[i]);
    }

    [Fact]
    public void Copy64Bytes_DoesNotWriteBeyond64Bytes()
    {
        byte[] src = new byte[64];
        for (int i = 0; i < 64; i++)
            src[i] = (byte)(i + 1);

        byte[] dst = new byte[80];
        // Fill sentinel bytes beyond the 64-byte copy region
        for (int i = 64; i < 80; i++)
            dst[i] = 0xFF;

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64Bytes(pDst, pSrc);
        }

        for (int i = 64; i < 80; i++)
            Assert.Equal(0xFF, dst[i]);
    }

    [Fact]
    public void Copy64Add_AddsBytesCorrectly()
    {
        byte[] src = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80];
        byte[] delta = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
        byte[] dst = new byte[8];
        byte[] expected = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];

        fixed (byte* pSrc = src)
        fixed (byte* pDelta = delta)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64Add(pDst, pSrc, pDelta);
        }

        for (int i = 0; i < 8; i++)
            Assert.Equal(expected[i], dst[i]);
    }

    [Fact]
    public void Copy64Add_WithZeroDelta_ProducesCopy()
    {
        byte[] src = [0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44];
        byte[] delta = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        byte[] dst = new byte[8];

        fixed (byte* pSrc = src)
        fixed (byte* pDelta = delta)
        fixed (byte* pDst = dst)
        {
            CopyHelpers.Copy64Add(pDst, pSrc, pDelta);
        }

        for (int i = 0; i < 8; i++)
            Assert.Equal(src[i], dst[i]);
    }

    [Fact]
    public void WildCopy16_CopiesInChunksOf16()
    {
        byte[] src = new byte[64];
        byte[] dst = new byte[64];
        for (int i = 0; i < 64; i++) src[i] = (byte)(i + 1);

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            // Copy 48 bytes (3 x 16-byte chunks)
            CopyHelpers.WildCopy16(pDst, pSrc, pDst + 48);
        }

        for (int i = 0; i < 48; i++)
            Assert.Equal(src[i], dst[i]);
    }

    [Fact]
    public void WildCopy16_ExactlyOneChunk()
    {
        byte[] src = new byte[32];
        byte[] dst = new byte[32];
        for (int i = 0; i < 32; i++) src[i] = (byte)(0xA0 + i);

        fixed (byte* pSrc = src)
        fixed (byte* pDst = dst)
        {
            // Copy exactly 16 bytes
            CopyHelpers.WildCopy16(pDst, pSrc, pDst + 16);
        }

        for (int i = 0; i < 16; i++)
            Assert.Equal(src[i], dst[i]);
    }
}

// ================================================================
//  MatchUtils Tests
// ================================================================

public unsafe class MatchUtilsTests
{
    [Fact]
    public void CountMatchingBytes_IdenticalData_ReturnsFullLength()
    {
        // Two identical 32-byte regions; p points at the second copy, offset = 32
        byte[] data = new byte[64];
        for (int i = 0; i < 32; i++)
        {
            data[i] = (byte)(i + 1);
            data[i + 32] = (byte)(i + 1);
        }

        fixed (byte* ptr = data)
        {
            byte* p = ptr + 32;       // start of second copy
            byte* pEnd = ptr + 64;    // end of buffer
            nint offset = 32;         // p[-32] == ptr[0]
            int len = MatchUtils.CountMatchingBytes(p, pEnd, offset);
            Assert.Equal(32, len);
        }
    }

    [Fact]
    public void CountMatchingBytes_NoMatch_ReturnsZero()
    {
        byte[] data = new byte[16];
        data[0] = 0xAA;
        data[8] = 0xBB; // different first byte

        fixed (byte* ptr = data)
        {
            byte* p = ptr + 8;
            byte* pEnd = ptr + 16;
            nint offset = 8;
            int len = MatchUtils.CountMatchingBytes(p, pEnd, offset);
            Assert.Equal(0, len);
        }
    }

    [Fact]
    public void CountMatchingBytes_PartialMatch_ReturnsCorrectPosition()
    {
        byte[] data = new byte[32];
        // First half: 0,1,2,3,4,5,...
        for (int i = 0; i < 16; i++)
            data[i] = (byte)i;
        // Second half: same first 5, then different
        for (int i = 0; i < 5; i++)
            data[i + 16] = (byte)i;
        data[21] = 0xFF; // mismatch at position 5

        fixed (byte* ptr = data)
        {
            byte* p = ptr + 16;
            byte* pEnd = ptr + 32;
            nint offset = 16;
            int len = MatchUtils.CountMatchingBytes(p, pEnd, offset);
            Assert.Equal(5, len);
        }
    }

    [Fact]
    public void GetMatchLengthQuick_FullMatch_Returns4Plus()
    {
        // Create data where first 4 bytes at offset match, plus some more
        byte[] data = new byte[32];
        for (int i = 0; i < 16; i++)
        {
            data[i] = (byte)(i + 1);
            data[i + 16] = (byte)(i + 1);
        }

        fixed (byte* ptr = data)
        {
            byte* src = ptr + 16;
            byte* srcEnd = ptr + 32;
            int offset = 16;
            uint u32AtCur = *(uint*)src;
            int len = MatchUtils.GetMatchLengthQuick(src, offset, srcEnd, u32AtCur);
            Assert.True(len >= 4, $"Expected >= 4, got {len}");
        }
    }

    [Fact]
    public void GetMatchLengthQuick_NoMatch_ReturnsZero()
    {
        byte[] data = new byte[32];
        // Fill differently so first 2 bytes differ
        data[0] = 0xAA;
        data[1] = 0xBB;
        data[16] = 0xCC;
        data[17] = 0xDD;

        fixed (byte* ptr = data)
        {
            byte* src = ptr + 16;
            byte* srcEnd = ptr + 32;
            int offset = 16;
            uint u32AtCur = *(uint*)src;
            int len = MatchUtils.GetMatchLengthQuick(src, offset, srcEnd, u32AtCur);
            Assert.Equal(0, len);
        }
    }

    [Fact]
    public void GetMatchLengthMin2_SingleByteMatch_ReturnsZero()
    {
        byte[] data = new byte[32];
        // Only the first byte matches
        data[0] = 0xAA;
        data[16] = 0xAA;
        data[1] = 0x11;
        data[17] = 0x22;

        fixed (byte* ptr = data)
        {
            byte* src = ptr + 16;
            byte* srcEnd = ptr + 32;
            int offset = 16;
            int len = MatchUtils.GetMatchLengthMin2(src, offset, srcEnd);
            Assert.Equal(0, len);
        }
    }

    [Theory]
    [InlineData(0, 5, 100, true)]    // recentLen < 2 -> always better
    [InlineData(1, 5, 100, true)]    // recentLen < 2 -> always better
    [InlineData(5, 3, 100, false)]   // matchLen < recentLen -> not better
    [InlineData(5, 10, 500, true)]   // matchLen much longer -> better
    [InlineData(5, 7, 512, true)]    // recentLen+1 < matchLen AND offset < 1024
    public void IsBetterThanRecent_EdgeCases(int recentLen, int matchLen, int offset, bool expected)
    {
        Assert.Equal(expected, MatchUtils.IsBetterThanRecent(recentLen, matchLen, offset));
    }

    [Theory]
    [InlineData(4u, 100u, 3u, 200u, true)]    // longer match -> better
    [InlineData(3u, 100u, 4u, 200u, false)]   // shorter match -> not better
    [InlineData(4u, 50u, 4u, 200u, true)]     // same length, closer offset -> better
    [InlineData(4u, 200u, 4u, 50u, false)]    // same length, farther offset -> not better
    public void IsMatchBetter_BasicCases(uint matchLen, uint offset, uint bestLen, uint bestOffset, bool expected)
    {
        Assert.Equal(expected, MatchUtils.IsMatchBetter(matchLen, offset, bestLen, bestOffset));
    }

    [Fact]
    public void GetLazyScore_LongerMatch_PositiveScore()
    {
        var a = new LengthAndOffset { Length = 10, Offset = 100 };
        var b = new LengthAndOffset { Length = 5, Offset = 100 };
        // a is much longer than b at same offset -> positive score
        Assert.True(MatchUtils.GetLazyScore(a, b) > 0);
    }

    [Fact]
    public void GetLazyScore_ShorterMatch_NegativeScore()
    {
        var a = new LengthAndOffset { Length = 3, Offset = 100 };
        var b = new LengthAndOffset { Length = 10, Offset = 100 };
        // a is shorter than b -> negative score
        Assert.True(MatchUtils.GetLazyScore(a, b) < 0);
    }

    [Fact]
    public void GetLazyScore_RecentOffset_BetterThanFar()
    {
        var recent = new LengthAndOffset { Length = 5, Offset = 0 };  // recent (0 bits for offset)
        var far = new LengthAndOffset { Length = 5, Offset = 65536 }; // far offset
        // Same length, but recent offset costs fewer bits -> higher score for recent
        Assert.True(MatchUtils.GetLazyScore(recent, far) > MatchUtils.GetLazyScore(far, recent));
    }
}

// ================================================================
//  CompressOptions Tests
// ================================================================

public class CompressOptionsTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    [InlineData(9)]
    public void GetDefaultCompressOpts_AllLevels_HaveChunkSizeSeekChunk(int level)
    {
        var opts = StreamLZCompressor.GetDefaultCompressOpts(level);
        Assert.Equal(StreamLZConstants.ChunkSize, opts.SeekChunkLen);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(9)]
    public void GetDefaultCompressOpts_AllLevels_HavePositiveSpaceSpeedTradeoff(int level)
    {
        var opts = StreamLZCompressor.GetDefaultCompressOpts(level);
        Assert.True(opts.SpaceSpeedTradeoffBytes > 0, "SpaceSpeedTradeoffBytes should be positive");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(9)]
    public void GetDefaultCompressOpts_AllLevels_HavePositiveMaxLocalDictSize(int level)
    {
        var opts = StreamLZCompressor.GetDefaultCompressOpts(level);
        Assert.True(opts.MaxLocalDictionarySize > 0, "MaxLocalDictionarySize should be positive");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(9)]
    public void GetDefaultCompressOpts_AllLevels_ReturnNonNull(int level)
    {
        var opts = StreamLZCompressor.GetDefaultCompressOpts(level);
        Assert.NotNull(opts);
    }
}

// ================================================================
//  Round-Trip Tests
// ================================================================

public class RoundTripTests
{
    // ---- Data generators ----

    private static byte[] GenerateTextData(int size)
    {
        var rng = new Random(42);
        var data = new byte[size];
        string[] phrases = [
            "the quick brown fox ",
            "jumps over the lazy dog ",
            "hello world ",
            "lorem ipsum dolor sit amet ",
            "data compression test ",
        ];
        int pos = 0;
        while (pos < size)
        {
            // 70% chance: pick a repeated phrase; 30% chance: random ASCII
            if (rng.Next(100) < 70)
            {
                string phrase = phrases[rng.Next(phrases.Length)];
                foreach (char c in phrase)
                {
                    if (pos >= size) break;
                    data[pos++] = (byte)c;
                }
            }
            else
            {
                // random ASCII letters, spaces, newlines
                int run = rng.Next(1, 40);
                for (int j = 0; j < run && pos < size; j++)
                {
                    int kind = rng.Next(10);
                    if (kind < 6)
                        data[pos++] = (byte)('a' + rng.Next(26));
                    else if (kind < 8)
                        data[pos++] = (byte)('A' + rng.Next(26));
                    else if (kind == 8)
                        data[pos++] = (byte)' ';
                    else
                        data[pos++] = (byte)'\n';
                }
            }
        }
        return data;
    }

    private static byte[] GenerateBinaryData(int size)
    {
        var rng = new Random(123);
        var data = new byte[size];
        int pos = 0;
        while (pos < size)
        {
            if (rng.Next(100) < 40)
            {
                // run of repeated bytes
                byte val = (byte)rng.Next(256);
                int run = rng.Next(4, 64);
                for (int j = 0; j < run && pos < size; j++)
                    data[pos++] = val;
            }
            else
            {
                // varying data
                int run = rng.Next(1, 32);
                for (int j = 0; j < run && pos < size; j++)
                    data[pos++] = (byte)rng.Next(256);
            }
        }
        return data;
    }

    private static byte[] GenerateRepetitiveData(int size)
    {
        var pattern = "ABCDEFGH"u8;
        var data = new byte[size];
        for (int i = 0; i < size; i++)
            data[i] = pattern[i % pattern.Length];
        return data;
    }

    private static byte[] GenerateRandomData(int size)
    {
        var rng = new Random(999);
        var data = new byte[size];
        rng.NextBytes(data);
        return data;
    }

    // ---- Round-trip helper ----

    private static void AssertRoundTrip(byte[] source, int level)
    {
        int bound = Slz.GetCompressBound(source.Length);
        byte[] compressed = new byte[bound];
        int compressedSize = Slz.Compress(source, compressed, level);
        Assert.True(compressedSize > 0, $"Compression failed for level {level}, returned {compressedSize}");
        // Small data and random/incompressible data may expand due to framing overhead.
        // Only check compression ratio for structured data above 1KB.
        if (source.Length >= 1024)
        {
            int maxExpected = (int)(source.Length * 1.01) + 64;
            Assert.True(compressedSize <= maxExpected,
                $"Compressed much larger than source ({compressedSize} > {maxExpected})");
        }

        byte[] decompressed = new byte[source.Length + Slz.SafeSpace];
        int decompressedSize = Slz.Decompress(
            compressed.AsSpan(0, compressedSize), decompressed, source.Length);
        Assert.Equal(source.Length, decompressedSize);
        Assert.Equal(source, decompressed.AsSpan(0, source.Length).ToArray());
    }

    // ---- All levels: text data ----

    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)]
    [InlineData(6)] [InlineData(7)] [InlineData(8)] [InlineData(9)] [InlineData(10)] [InlineData(11)]
    public void RoundTrip_TextData(int level) =>
        AssertRoundTrip(GenerateTextData(100_000), level);

    // ---- All levels: binary data ----

    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)]
    [InlineData(6)] [InlineData(7)] [InlineData(8)] [InlineData(9)] [InlineData(10)] [InlineData(11)]
    public void RoundTrip_BinaryData(int level) =>
        AssertRoundTrip(GenerateBinaryData(100_000), level);

    // ---- Size variation tests ----

    [Theory]
    [InlineData(1)] [InlineData(100)] [InlineData(1000)] [InlineData(10_000)] [InlineData(100_000)] [InlineData(500_000)]
    public void RoundTrip_VariousSizes_Fast(int size) =>
        AssertRoundTrip(GenerateTextData(size), 3);

    [Theory]
    [InlineData(1)] [InlineData(100)] [InlineData(1000)] [InlineData(10_000)] [InlineData(100_000)] [InlineData(500_000)]
    public void RoundTrip_VariousSizes_High(int size) =>
        AssertRoundTrip(GenerateTextData(size), 9);

    // ---- Data type variation tests ----

    [Theory]
    [InlineData(3)]
    [InlineData(5)]
    [InlineData(7)]
    [InlineData(10)]
    public void RoundTrip_RepetitiveData(int level) =>
        AssertRoundTrip(GenerateRepetitiveData(50_000), level);

    [Theory]
    [InlineData(3)]
    [InlineData(5)]
    [InlineData(7)]
    [InlineData(10)]
    public void RoundTrip_RandomData(int level) =>
        AssertRoundTrip(GenerateRandomData(50_000), level);

    // ---- Edge cases ----

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void RoundTrip_AllZeros(int level) =>
        AssertRoundTrip(new byte[10_000], level);

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void RoundTrip_AllOnes(int level) =>
        AssertRoundTrip(Enumerable.Repeat((byte)0xFF, 10_000).ToArray(), level);

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void RoundTrip_SingleByte(int level) =>
        AssertRoundTrip(new byte[] { 42 }, level);

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void RoundTrip_TwoDistinctBytes(int level)
    {
        var data = new byte[10_000];
        for (int i = 0; i < data.Length; i++)
            data[i] = (byte)(i % 2 == 0 ? 'A' : 'B');
        AssertRoundTrip(data, level);
    }
}

// ================================================================
//  Frame Format Tests
// ================================================================

public class FrameFormatTests
{
    private static byte[] GenerateTextData(int size)
    {
        var rng = new Random(42);
        var data = new byte[size];
        string[] phrases = ["the quick brown fox ", "jumps over the lazy dog ", "hello world "];
        int pos = 0;
        while (pos < size)
        {
            string phrase = phrases[rng.Next(phrases.Length)];
            foreach (char c in phrase)
            {
                if (pos >= size) break;
                data[pos++] = (byte)c;
            }
        }
        return data;
    }

    private static void AssertStreamRoundTrip(byte[] source, int level)
    {
        using var inputStream = new MemoryStream(source);
        using var compressedStream = new MemoryStream();
        long compressedSize = Slz.CompressStream(inputStream, compressedStream, level, contentSize: source.Length);
        Assert.True(compressedSize > 0);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        long decompressedSize = Slz.DecompressStream(compressedStream, decompressedStream);
        Assert.Equal(source.Length, decompressedSize);

        byte[] decompressed = decompressedStream.ToArray();
        Assert.Equal(source, decompressed);
    }

    // ---- Frame header tests ----

    [Fact]
    public void FrameHeader_WriteRead_RoundTrips()
    {
        Span<byte> buf = stackalloc byte[FrameConstants.MaxHeaderSize];
        int written = FrameSerializer.WriteHeader(buf, 3, 5, contentSize: 12345);
        Assert.True(FrameSerializer.TryReadHeader(buf[..written], out FrameHeader header));
        Assert.Equal(FrameConstants.Version, header.Version);
        Assert.Equal(3, header.Codec);
        Assert.Equal(5, header.Level);
        Assert.Equal(12345L, header.ContentSize);
        Assert.Equal(FrameConstants.DefaultBlockSize, header.BlockSize);
    }

    [Fact]
    public void FrameHeader_NoContentSize_ReturnsMinusOne()
    {
        Span<byte> buf = stackalloc byte[FrameConstants.MaxHeaderSize];
        int written = FrameSerializer.WriteHeader(buf, 2, 3);
        Assert.True(FrameSerializer.TryReadHeader(buf[..written], out FrameHeader header));
        Assert.Equal(-1L, header.ContentSize);
    }

    [Fact]
    public void FrameHeader_BadMagic_ReturnsFalse()
    {
        byte[] buf = new byte[FrameConstants.MinHeaderSize];
        buf[0] = 0xFF; // wrong magic
        Assert.False(FrameSerializer.TryReadHeader(buf, out _));
    }

    [Fact]
    public void BlockHeader_WriteRead_RoundTrips()
    {
        byte[] buf = new byte[8];
        FrameSerializer.WriteBlockHeader(buf, 1234, 5000, isUncompressed: false);
        Assert.True(FrameSerializer.TryReadBlockHeader(buf, out int size, out int decompSize, out bool uncomp));
        Assert.Equal(1234, size);
        Assert.Equal(5000, decompSize);
        Assert.False(uncomp);
    }

    [Fact]
    public void BlockHeader_Uncompressed_FlagSet()
    {
        byte[] buf = new byte[8];
        FrameSerializer.WriteBlockHeader(buf, 5678, 5678, isUncompressed: true);
        Assert.True(FrameSerializer.TryReadBlockHeader(buf, out int size, out _, out bool uncomp));
        Assert.Equal(5678, size);
        Assert.True(uncomp);
    }

    [Fact]
    public void EndMark_IsZero()
    {
        byte[] buf = new byte[8];
        FrameSerializer.WriteEndMark(buf);
        Assert.True(FrameSerializer.TryReadBlockHeader(buf, out int size, out _, out _));
        Assert.Equal(0, size);
    }

    // ---- Stream round-trip tests ----

    [Theory]
    [InlineData(3)]
    [InlineData(5)]
    [InlineData(7)]
    [InlineData(10)]
    public void Stream_RoundTrip_TextData(int level) =>
        AssertStreamRoundTrip(GenerateTextData(100_000), level);

    [Theory]
    [InlineData(1)]
    [InlineData(100)]
    [InlineData(1000)]
    [InlineData(10_000)]
    [InlineData(100_000)]
    [InlineData(500_000)]
    public void Stream_RoundTrip_VariousSizes(int size) =>
        AssertStreamRoundTrip(GenerateTextData(size), 3);

    [Fact]
    public void Stream_RoundTrip_MultipleBlocks()
    {
        // 1MB = 4 blocks of 256KB each
        AssertStreamRoundTrip(GenerateTextData(1_000_000), 9);
    }

    [Fact]
    public void Stream_RoundTrip_AllZeros() =>
        AssertStreamRoundTrip(new byte[50_000], 3);

    [Fact]
    public void Stream_CompressFile_DecompressFile()
    {
        byte[] source = GenerateTextData(100_000);
        string tmpInput = Path.GetTempFileName();
        string tmpCompressed = Path.GetTempFileName();
        string tmpDecompressed = Path.GetTempFileName();
        try
        {
            File.WriteAllBytes(tmpInput, source);
            Slz.CompressFile(tmpInput, tmpCompressed, 3);
            Slz.DecompressFile(tmpCompressed, tmpDecompressed);
            byte[] result = File.ReadAllBytes(tmpDecompressed);
            Assert.Equal(source, result);
        }
        finally
        {
            File.Delete(tmpInput);
            File.Delete(tmpCompressed);
            File.Delete(tmpDecompressed);
        }
    }

    // ---- Sliding window / cross-block tests ----

    [Fact]
    public void SlidingWindow_PatternRepeatsAcrossBlocks()
    {
        // Create data where a 1KB pattern appears in block 1 and repeats in block 3.
        // Block size is 256KB, so we need >512KB of data.
        int blockSize = FrameConstants.DefaultBlockSize; // 256KB
        var data = new byte[blockSize * 3];
        var rng = new Random(777);

        // Fill with random data
        rng.NextBytes(data);

        // Plant a distinctive 1KB pattern at offset 1000 (block 1)
        byte[] pattern = new byte[1024];
        for (int i = 0; i < pattern.Length; i++)
            pattern[i] = (byte)(i * 7 + 42);

        Buffer.BlockCopy(pattern, 0, data, 1000, pattern.Length);
        // Repeat the same pattern at offset blockSize*2 + 5000 (block 3)
        Buffer.BlockCopy(pattern, 0, data, blockSize * 2 + 5000, pattern.Length);

        AssertStreamRoundTrip(data, 3);
    }

    [Fact]
    public void SlidingWindow_MatchSpansBlockBoundary()
    {
        // Create data with a match that crosses the exact 256KB block boundary.
        int blockSize = FrameConstants.DefaultBlockSize;
        var data = new byte[blockSize * 2];
        var rng = new Random(888);
        rng.NextBytes(data);

        // Plant a 64-byte pattern ending 4 bytes before block boundary
        byte[] pattern = new byte[64];
        for (int i = 0; i < 64; i++) pattern[i] = (byte)(i + 100);
        Buffer.BlockCopy(pattern, 0, data, blockSize - 68, 64);

        // Repeat it starting 100 bytes into block 2
        Buffer.BlockCopy(pattern, 0, data, blockSize + 100, 64);

        AssertStreamRoundTrip(data, 9);
    }

    [Fact]
    public void SlidingWindow_SmallWindowSize()
    {
        // Use window = blockSize (minimum), effectively self-contained
        int blockSize = FrameConstants.DefaultBlockSize;
        byte[] data = GenerateTextData(blockSize * 3);

        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        StreamLzFrameCompressor.Compress(inputStream, compressedStream,
            CodecType.Fast, 3, windowSize: blockSize);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        StreamLzFrameDecompressor.Decompress(compressedStream, decompressedStream,
            windowSize: blockSize);

        Assert.Equal(data, decompressedStream.ToArray());
    }

    [Fact]
    public void SlidingWindow_LargeWindowCoversMultipleBlocks()
    {
        // Window = 1MB (4 blocks worth), data = 2MB
        int blockSize = FrameConstants.DefaultBlockSize;
        byte[] data = GenerateTextData(blockSize * 8); // 2MB

        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        StreamLzFrameCompressor.Compress(inputStream, compressedStream,
            CodecType.Fast, 5, windowSize: 1024 * 1024);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        StreamLzFrameDecompressor.Decompress(compressedStream, decompressedStream,
            windowSize: 1024 * 1024);

        Assert.Equal(data, decompressedStream.ToArray());
    }

    // ---- Frame format edge cases ----

    [Fact]
    public void Frame_EmptyInput()
    {
        byte[] data = Array.Empty<byte>();
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        long compressedSize = Slz.CompressStream(inputStream, compressedStream, 3);
        // Should be header + end mark only
        Assert.True(compressedSize >= FrameConstants.MinHeaderSize + 4);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        long decompSize = Slz.DecompressStream(compressedStream, decompressedStream);
        Assert.Equal(0, decompSize);
        Assert.Empty(decompressedStream.ToArray());
    }

    [Fact]
    public void Frame_ExactlyOneBlock()
    {
        byte[] data = GenerateTextData(FrameConstants.DefaultBlockSize);
        AssertStreamRoundTrip(data, 3);
    }

    [Fact]
    public void Frame_OneByteOverOneBlock()
    {
        byte[] data = GenerateTextData(FrameConstants.DefaultBlockSize + 1);
        AssertStreamRoundTrip(data, 9);
    }

    [Fact]
    public void Frame_IncompressibleData_StoresUncompressed()
    {
        // Pure random data — should produce uncompressed (stored) blocks
        var rng = new Random(12345);
        var data = new byte[100_000];
        rng.NextBytes(data);

        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(inputStream, compressedStream, 3);

        // Compressed should be slightly larger than source (header + block headers + end mark)
        Assert.True(compressedStream.Length >= data.Length);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        Slz.DecompressStream(compressedStream, decompressedStream);
        Assert.Equal(data, decompressedStream.ToArray());
    }

    [Fact]
    public void Frame_ContentSizePresent()
    {
        byte[] data = GenerateTextData(50_000);
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(inputStream, compressedStream, 3, contentSize: data.Length);

        // Verify header has content size
        compressedStream.Position = 0;
        byte[] headerBytes = new byte[FrameConstants.MaxHeaderSize];
        compressedStream.Read(headerBytes);
        Assert.True(FrameSerializer.TryReadHeader(headerBytes, out FrameHeader header));
        Assert.Equal(data.Length, header.ContentSize);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        Slz.DecompressStream(compressedStream, decompressedStream);
        Assert.Equal(data, decompressedStream.ToArray());
    }

    [Fact]
    public void Frame_ContentSizeAbsent()
    {
        byte[] data = GenerateTextData(50_000);
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(inputStream, compressedStream, 3);

        compressedStream.Position = 0;
        byte[] headerBytes = new byte[FrameConstants.MaxHeaderSize];
        compressedStream.Read(headerBytes);
        Assert.True(FrameSerializer.TryReadHeader(headerBytes, out FrameHeader header));
        Assert.Equal(-1L, header.ContentSize);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        Slz.DecompressStream(compressedStream, decompressedStream);
        Assert.Equal(data, decompressedStream.ToArray());
    }

    [Fact]
    public void Frame_TruncatedFrame_Throws()
    {
        byte[] data = GenerateTextData(50_000);
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(inputStream, compressedStream, 3);

        // Truncate: remove end mark and last few bytes
        byte[] truncated = compressedStream.ToArray()[..^8];
        using var truncatedStream = new MemoryStream(truncated);
        using var decompressedStream = new MemoryStream();
        Assert.ThrowsAny<Exception>(() =>
            Slz.DecompressStream(truncatedStream, decompressedStream));
    }

    [Fact]
    public void Frame_CorruptedBlockHeader_Throws()
    {
        byte[] data = GenerateTextData(50_000);
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(inputStream, compressedStream, 3);

        byte[] corrupted = compressedStream.ToArray();
        // Corrupt the first block header (right after the frame header)
        int headerSize = FrameConstants.MinHeaderSize;
        corrupted[headerSize] = 0xFF;
        corrupted[headerSize + 1] = 0xFF;
        corrupted[headerSize + 2] = 0xFF;
        corrupted[headerSize + 3] = 0x7F; // huge compressed size without uncompressed flag

        using var corruptedStream = new MemoryStream(corrupted);
        using var decompressedStream = new MemoryStream();
        Assert.ThrowsAny<Exception>(() =>
            Slz.DecompressStream(corruptedStream, decompressedStream));
    }

    // ---- Level coverage through frame API ----

    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)]
    [InlineData(6)] [InlineData(7)] [InlineData(8)] [InlineData(9)] [InlineData(10)] [InlineData(11)]
    public void Frame_AllLevels(int level) =>
        AssertStreamRoundTrip(GenerateTextData(50_000), level);

    [Fact]
    public void Frame_HighLevel_MultiBlock() =>
        AssertStreamRoundTrip(GenerateTextData(FrameConstants.DefaultBlockSize * 3), 9);

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void Frame_AllZeros(int level) =>
        AssertStreamRoundTrip(new byte[100_000], level);

    [Theory]
    [InlineData(3)]
    [InlineData(9)]
    public void Frame_SingleByteRepeated(int level) =>
        AssertStreamRoundTrip(Enumerable.Repeat((byte)0xAB, 100_000).ToArray(), level);

    // ---- API robustness ----

    [Fact]
    public void Frame_NonSeekableInputStream()
    {
        byte[] data = GenerateTextData(100_000);
        using var innerStream = new MemoryStream(data);
        using var nonSeekable = new NonSeekableStream(innerStream);
        using var compressedStream = new MemoryStream();
        Slz.CompressStream(nonSeekable, compressedStream, 3);

        // Now decompress from a non-seekable compressed stream
        byte[] compressed = compressedStream.ToArray();
        using var compressedInner = new MemoryStream(compressed);
        using var nonSeekableCompressed = new NonSeekableStream(compressedInner);
        using var decompressedStream = new MemoryStream();
        Slz.DecompressStream(nonSeekableCompressed, decompressedStream);

        Assert.Equal(data, decompressedStream.ToArray());
    }

    [Fact]
    public void Frame_CompressToMemoryStream_CorrectLength()
    {
        byte[] data = GenerateTextData(50_000);
        using var inputStream = new MemoryStream(data);
        using var compressedStream = new MemoryStream();
        long written = Slz.CompressStream(inputStream, compressedStream, 3);
        Assert.Equal(written, compressedStream.Length);
        Assert.True(written > 0);
    }

    [Fact]
    public void Frame_CompressFile_PathWithSpaces()
    {
        byte[] data = GenerateTextData(50_000);
        string tmpDir = Path.Combine(Path.GetTempPath(), "streamlz test dir");
        Directory.CreateDirectory(tmpDir);
        string tmpInput = Path.Combine(tmpDir, "input file.bin");
        string tmpCompressed = Path.Combine(tmpDir, "compressed file.slz");
        string tmpDecompressed = Path.Combine(tmpDir, "output file.bin");
        try
        {
            File.WriteAllBytes(tmpInput, data);
            Slz.CompressFile(tmpInput, tmpCompressed, 3);
            Slz.DecompressFile(tmpCompressed, tmpDecompressed);
            Assert.Equal(data, File.ReadAllBytes(tmpDecompressed));
        }
        finally
        {
            if (Directory.Exists(tmpDir))
                Directory.Delete(tmpDir, recursive: true);
        }
    }

    // ---- Multi-chunk streaming (exercises repeated Compress calls, catches GC relocation bugs) ----

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void Stream_MultiChunk_2MB(int level)
    {
        // 2MB = multiple frame chunks at all levels, exercises repeated
        // StreamLZCompressor.Compress calls with ArrayPool reuse.
        AssertStreamRoundTrip(GenerateTextData(2_000_000), level);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    public void Stream_MultiChunk_5MB(int level)
    {
        // 5MB = ~20 chunks, enough to stress parallel SC and serial paths
        AssertStreamRoundTrip(GenerateTextData(5_000_000), level);
    }

    // ---- All levels via stream path at various sizes ----

    [Theory]
    [InlineData(1, 100_000)]
    [InlineData(1, 500_000)]
    [InlineData(3, 100_000)]
    [InlineData(3, 500_000)]
    [InlineData(6, 100_000)]
    [InlineData(6, 500_000)]
    [InlineData(9, 100_000)]
    [InlineData(9, 500_000)]
    public void Stream_RoundTrip_AllLevelsAndSizes(int level, int size) =>
        AssertStreamRoundTrip(GenerateTextData(size), level);

    // ---- Stream round-trip with incompressible data (stored blocks) ----

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    public void Stream_IncompressibleData(int level)
    {
        var rng = new Random(99999);
        byte[] data = new byte[500_000];
        rng.NextBytes(data);
        AssertStreamRoundTrip(data, level);
    }

    // ---- CompressFile / DecompressFile round-trip at all key levels ----

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void CompressFile_DecompressFile_RoundTrip(int level)
    {
        byte[] data = GenerateTextData(500_000);
        string tmpInput = Path.GetTempFileName();
        string tmpCompressed = Path.GetTempFileName();
        string tmpDecompressed = Path.GetTempFileName();
        try
        {
            File.WriteAllBytes(tmpInput, data);
            Slz.CompressFile(tmpInput, tmpCompressed, level);
            Slz.DecompressFile(tmpCompressed, tmpDecompressed);
            Assert.Equal(data, File.ReadAllBytes(tmpDecompressed));
        }
        finally
        {
            File.Delete(tmpInput);
            File.Delete(tmpCompressed);
            File.Delete(tmpDecompressed);
        }
    }
}

// ================================================================
//  Public API validation tests
// ================================================================

public class PublicApiValidationTests
{
    [Fact]
    public void Compress_ThrowsArgumentException_WhenDestinationTooSmall()
    {
        byte[] source = new byte[1000];
        new Random(42).NextBytes(source);
        byte[] tooSmall = new byte[10]; // way too small

        var ex = Assert.Throws<ArgumentException>(() => Slz.Compress(source, tooSmall));
        Assert.Contains("too small", ex.Message);
    }

    [Fact]
    public void Compress_EmptySource_ReturnsEmptyArray()
    {
        // Empty input produces empty compressed output
        byte[] result = Slz.Compress(ReadOnlySpan<byte>.Empty);
        Assert.Empty(result);
    }

    [Fact]
    public void Decompress_ThrowsArgumentOutOfRangeException_WhenNegativeSize()
    {
        byte[] src = new byte[100];
        byte[] dst = new byte[200];

        Assert.Throws<ArgumentOutOfRangeException>(() => Slz.Decompress(src, dst, -1));
    }

    [Fact]
    public void Decompress_ThrowsArgumentException_WhenDestinationTooSmall()
    {
        byte[] src = new byte[100];
        byte[] dst = new byte[10]; // needs at least decompressedSize + SafeSpace

        Assert.Throws<ArgumentException>(() => Slz.Decompress(src, dst, 100));
    }

    [Fact]
    public void Decompress_ThrowsInvalidDataException_OnCorruptData()
    {
        byte[] garbage = new byte[100];
        new Random(99).NextBytes(garbage);
        byte[] dst = new byte[1000 + Slz.SafeSpace];

        Assert.Throws<InvalidDataException>(() => Slz.Decompress(garbage, dst, 1000));
    }

    [Fact]
    public void CompressStream_ThrowsArgumentNullException_OnNullInput()
    {
        Assert.Throws<ArgumentNullException>(() => Slz.CompressStream(null!, new MemoryStream()));
    }

    [Fact]
    public void CompressStream_ThrowsArgumentNullException_OnNullOutput()
    {
        Assert.Throws<ArgumentNullException>(() => Slz.CompressStream(new MemoryStream(), null!));
    }

    [Fact]
    public void DecompressStream_ThrowsArgumentNullException_OnNullInput()
    {
        Assert.Throws<ArgumentNullException>(() => Slz.DecompressStream(null!, new MemoryStream()));
    }

    [Fact]
    public void DecompressStream_ThrowsArgumentNullException_OnNullOutput()
    {
        Assert.Throws<ArgumentNullException>(() => Slz.DecompressStream(new MemoryStream(), null!));
    }
}

// ================================================================
//  Async stream tests
// ================================================================

public class AsyncStreamTests
{
    private static byte[] GenerateTestData(int size)
    {
        var rng = new Random(42);
        var data = new byte[size];
        int pos = 0;
        string[] phrases = ["hello world ", "the quick brown fox ", "lorem ipsum "];
        while (pos < size)
        {
            string phrase = phrases[rng.Next(phrases.Length)];
            foreach (char c in phrase)
            {
                if (pos >= size) break;
                data[pos++] = (byte)c;
            }
        }
        return data;
    }

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    [InlineData(6)]
    [InlineData(9)]
    public async Task CompressStreamAsync_DecompressStreamAsync_RoundTrips(int level)
    {
        byte[] source = GenerateTestData(100_000);

        using var inputStream = new MemoryStream(source);
        using var compressedStream = new MemoryStream();
        long compressedSize = await Slz.CompressStreamAsync(inputStream, compressedStream, level);
        Assert.True(compressedSize > 0);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        long decompressedSize = await Slz.DecompressStreamAsync(compressedStream, decompressedStream);
        Assert.Equal(source.Length, decompressedSize);
        Assert.Equal(source, decompressedStream.ToArray());
    }

    [Theory]
    [InlineData(6)]   // self-contained
    [InlineData(9)]   // cross-block references
    public async Task CompressStreamAsync_DecompressStreamAsync_MultiBlock_RoundTrips(int level)
    {
        // 500 KB forces multiple blocks (block size = 256 KB)
        byte[] source = GenerateTestData(500_000);

        using var inputStream = new MemoryStream(source);
        using var compressedStream = new MemoryStream();
        long compressedSize = await Slz.CompressStreamAsync(inputStream, compressedStream, level);
        Assert.True(compressedSize > 0);

        compressedStream.Position = 0;
        using var decompressedStream = new MemoryStream();
        long decompressedSize = await Slz.DecompressStreamAsync(compressedStream, decompressedStream);
        Assert.Equal(source.Length, decompressedSize);
        Assert.Equal(source, decompressedStream.ToArray());
    }

    [Fact]
    public async Task CompressStreamAsync_RespectsСancellation()
    {
        byte[] source = GenerateTestData(500_000);
        using var cts = new CancellationTokenSource();
        cts.Cancel(); // pre-cancel

        using var inputStream = new MemoryStream(source);
        using var outputStream = new MemoryStream();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => Slz.CompressStreamAsync(inputStream, outputStream, cancellationToken: cts.Token));
    }

    [Fact]
    public async Task DecompressStreamAsync_RespectsСancellation()
    {
        // First compress something valid
        byte[] source = GenerateTestData(50_000);
        using var inputStream = new MemoryStream(source);
        using var compressedStream = new MemoryStream();
        await Slz.CompressStreamAsync(inputStream, compressedStream, level: 1);

        // Now try to decompress with a pre-cancelled token
        compressedStream.Position = 0;
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        using var outputStream = new MemoryStream();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => Slz.DecompressStreamAsync(compressedStream, outputStream, cancellationToken: cts.Token));
    }

    [Fact]
    public async Task CompressStreamAsync_ThrowsArgumentNullException_OnNullInput()
    {
        await Assert.ThrowsAsync<ArgumentNullException>(
            () => Slz.CompressStreamAsync(null!, new MemoryStream()));
    }

    [Fact]
    public async Task DecompressStreamAsync_ThrowsArgumentNullException_OnNullInput()
    {
        await Assert.ThrowsAsync<ArgumentNullException>(
            () => Slz.DecompressStreamAsync(null!, new MemoryStream()));
    }
}

/// <summary>Wrapper that makes a stream non-seekable for testing.</summary>
internal sealed class NonSeekableStream : Stream
{
    private readonly Stream _inner;
    public NonSeekableStream(Stream inner) => _inner = inner;
    public override bool CanRead => _inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => _inner.CanWrite;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() => _inner.Flush();
    public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => _inner.Write(buffer, offset, count);
}

// ────────────────────────────────────────────────────────────────────
//  SlzStream tests
// ────────────────────────────────────────────────────────────────────

public class SlzStreamTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void SlzStream_RoundTrip_Compress_Decompress(int level)
    {
        // Generate compressible text-like data
        byte[] original = new byte[100_000];
        var rng = new Random(42);
        for (int i = 0; i < original.Length; i++)
            original[i] = (byte)('a' + rng.Next(26));

        // Compress via SlzStream
        using var compressedMs = new MemoryStream();
        using (var compressStream = new SlzStream(compressedMs, CompressionMode.Compress, leaveOpen: true, level))
        {
            compressStream.Write(original, 0, original.Length);
        }

        Assert.True(compressedMs.Length > 0);

        // Decompress via SlzStream
        compressedMs.Position = 0;
        using var decompressStream = new SlzStream(compressedMs, CompressionMode.Decompress);
        using var resultMs = new MemoryStream();
        decompressStream.CopyTo(resultMs);

        Assert.Equal(original, resultMs.ToArray());
    }

    [Fact]
    public void SlzStream_CannotReadInCompressMode()
    {
        using var ms = new MemoryStream();
        using var stream = new SlzStream(ms, CompressionMode.Compress, leaveOpen: true);
        Assert.Throws<InvalidOperationException>(() => stream.Read(new byte[10], 0, 10));
    }

    [Fact]
    public void SlzStream_CannotWriteInDecompressMode()
    {
        // Create a valid compressed stream first
        byte[] data = [1, 2, 3, 4, 5];
        using var compMs = new MemoryStream();
        using (var cs = new SlzStream(compMs, CompressionMode.Compress, leaveOpen: true))
            cs.Write(data);

        compMs.Position = 0;
        using var ds = new SlzStream(compMs, CompressionMode.Decompress);
        Assert.Throws<InvalidOperationException>(() => ds.Write(new byte[10], 0, 10));
    }

    [Fact]
    public void SlzStream_NullStreamThrows()
    {
        Assert.Throws<ArgumentNullException>(() => new SlzStream(null!, CompressionMode.Compress));
    }

    [Theory]
    [InlineData(6)]   // self-contained High
    [InlineData(9)]   // non-self-contained High (cross-block references)
    public void SlzStream_Decompress_CrossBlock_ViaCompressStream(int level)
    {
        // Generate data larger than one block (256 KB) to force multiple blocks
        byte[] original = new byte[400_000];
        var rng = new Random(123);
        for (int i = 0; i < original.Length; i++)
            original[i] = (byte)('A' + rng.Next(26));

        // Compress via Slz.CompressStream (uses the full frame compressor with sliding window)
        using var compressedMs = new MemoryStream();
        Slz.CompressStream(new MemoryStream(original), compressedMs, level);

        // Decompress via SlzStream (must handle cross-block references for level 9)
        compressedMs.Position = 0;
        using var decompressStream = new SlzStream(compressedMs, CompressionMode.Decompress);
        using var resultMs = new MemoryStream();
        decompressStream.CopyTo(resultMs);

        Assert.Equal(original, resultMs.ToArray());
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    public async Task SlzStream_Async_RoundTrip(int level)
    {
        byte[] original = new byte[50_000];
        var rng = new Random(99);
        for (int i = 0; i < original.Length; i++)
            original[i] = (byte)(rng.Next(256));

        // Compress via async WriteAsync
        using var compressedMs = new MemoryStream();
        await using (var compressStream = new SlzStream(compressedMs, CompressionMode.Compress, leaveOpen: true, level))
        {
            // Write in small chunks to exercise the block-fill logic
            for (int offset = 0; offset < original.Length; offset += 1024)
            {
                int count = Math.Min(1024, original.Length - offset);
                await compressStream.WriteAsync(original.AsMemory(offset, count));
            }
        }

        Assert.True(compressedMs.Length > 0);

        // Decompress via async ReadAsync
        compressedMs.Position = 0;
        await using var decompressStream = new SlzStream(compressedMs, CompressionMode.Decompress);
        byte[] result = new byte[original.Length];
        int totalRead = 0;
        while (totalRead < result.Length)
        {
            int bytesRead = await decompressStream.ReadAsync(result.AsMemory(totalRead));
            if (bytesRead == 0) break;
            totalRead += bytesRead;
        }

        Assert.Equal(original.Length, totalRead);
        Assert.Equal(original, result);
    }

    [Fact]
    public void SlzStream_Decompress_WithContentChecksum()
    {
        byte[] original = new byte[10_000];
        var rng = new Random(77);
        for (int i = 0; i < original.Length; i++)
            original[i] = (byte)('a' + rng.Next(26));

        // Compress with checksum enabled
        using var compressedMs = new MemoryStream();
        Slz.CompressStream(new MemoryStream(original), compressedMs, useContentChecksum: true);

        // Decompress via SlzStream (should verify checksum without error)
        compressedMs.Position = 0;
        using var decompressStream = new SlzStream(compressedMs, CompressionMode.Decompress);
        using var resultMs = new MemoryStream();
        decompressStream.CopyTo(resultMs);

        Assert.Equal(original, resultMs.ToArray());
    }
}

// ────────────────────────────────────────────────────────────────────
//  Content checksum tests
// ────────────────────────────────────────────────────────────────────

public class ContentChecksumTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public void ContentChecksum_RoundTrip_Verified(int level)
    {
        byte[] original = new byte[50_000];
        new Random(99).NextBytes(original);
        for (int i = 0; i < original.Length; i += 5)
            original[i] = (byte)(i & 0xFF);

        // Compress with checksum
        using var compressedMs = new MemoryStream();
        using var inputMs = new MemoryStream(original);
        Slz.CompressStream(inputMs, compressedMs, level, useContentChecksum: true);

        // Decompress — should verify checksum without error
        compressedMs.Position = 0;
        using var outputMs = new MemoryStream();
        long decompSize = Slz.DecompressStream(compressedMs, outputMs);

        Assert.Equal(original.Length, (int)decompSize);
        Assert.Equal(original, outputMs.ToArray());
    }

    [Fact]
    public void ContentChecksum_Corrupted_Throws()
    {
        byte[] original = new byte[10_000];
        new Random(77).NextBytes(original);

        // Compress with checksum
        using var compressedMs = new MemoryStream();
        using var inputMs = new MemoryStream(original);
        Slz.CompressStream(inputMs, compressedMs, 3, useContentChecksum: true);

        byte[] compressed = compressedMs.ToArray();

        // Corrupt the last 4 bytes (the XXH32 checksum)
        compressed[^1] ^= 0xFF;
        compressed[^2] ^= 0xFF;

        // Decompress should throw on checksum mismatch
        using var corruptedMs = new MemoryStream(compressed);
        using var outputMs = new MemoryStream();
        Assert.Throws<InvalidDataException>(() => Slz.DecompressStream(corruptedMs, outputMs));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(6)]
    [InlineData(9)]
    public async Task ContentChecksum_Async_RoundTrip_Verified(int level)
    {
        byte[] original = new byte[50_000];
        new Random(99).NextBytes(original);
        for (int i = 0; i < original.Length; i += 5)
            original[i] = (byte)(i & 0xFF);

        // Compress async with checksum
        using var compressedMs = new MemoryStream();
        using var inputMs = new MemoryStream(original);
        await Slz.CompressStreamAsync(inputMs, compressedMs, level,
            contentSize: original.Length, useContentChecksum: true);

        // Decompress sync — should verify checksum without error
        compressedMs.Position = 0;
        using var outputMs = new MemoryStream();
        long decompSize = Slz.DecompressStream(compressedMs, outputMs);

        Assert.Equal(original.Length, (int)decompSize);
        Assert.Equal(original, outputMs.ToArray());
    }

    [Fact]
    public void NoChecksum_CorruptedChecksum_NoThrow()
    {
        byte[] original = new byte[10_000];
        new Random(77).NextBytes(original);

        // Compress WITHOUT checksum
        using var compressedMs = new MemoryStream();
        using var inputMs = new MemoryStream(original);
        Slz.CompressStream(inputMs, compressedMs, 3, useContentChecksum: false);

        // Decompress — no checksum verification
        compressedMs.Position = 0;
        using var outputMs = new MemoryStream();
        long decompSize = Slz.DecompressStream(compressedMs, outputMs);
        Assert.Equal(original.Length, (int)decompSize);
    }
}
