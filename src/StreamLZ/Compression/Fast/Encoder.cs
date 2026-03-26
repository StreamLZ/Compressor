// Encoder.cs — Stream writer and compressed output assembly for the Fast compressor.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;
using StreamLZ.Common;
using StreamLZ.Compression.Entropy;

namespace StreamLZ.Compression.Fast;

/// <summary>
/// Manages the six parallel output streams (literals, delta-literals, tokens,
/// offset16, offset32, lengths) during Fast compression. Written to by the
/// parsers, then assembled into the final compressed output by
/// <see cref="Encoder.AssembleCompressedOutput"/>.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct FastStreamWriter
{
    public byte* LiteralStart;
    public byte* LiteralCursor;
    public byte* DeltaLiteralStart;
    public byte* DeltaLiteralCursor;
    public byte* TokenStart;
    public byte* TokenCursor;
    public ushort* Offset16Start;
    public ushort* Offset16Cursor;
    public byte* Offset32Start;
    public byte* Offset32Cursor;
    public byte* LengthStart;
    public byte* LengthCursor;
    public int ComplexTokenCount;
    public int Offset32Count;
    public int SourceLength;
    public byte* SourcePointer;
    public int Block2StartOffset;
    public int Block1Size;
    public int Block2Size;
    public int TokenStream2Offset;
    public int Offset32CountBlock1;
    public int Offset32CountBlock2;
    /// <summary>Base pointer of the native allocation (for freeing).</summary>
    public byte* AllocationBase;

    /// <summary>
    /// Allocates stream buffers and initializes all fields.
    /// The caller must call <see cref="FreeBuffers"/> when done.
    /// </summary>
    public static void Initialize(FastStreamWriter* writer, int sourceLength, byte* source, bool useDeltaLiterals)
    {
        // Zero the entire struct first so FreeBuffers is safe if NativeMemory.Alloc throws.
        // AllocationBase will be null → NativeMemory.Free(null) is a no-op.
        *writer = default;
        writer->SourcePointer = source;
        writer->SourceLength = sourceLength;

        int literalSize = checked(sourceLength + 8);
        int tokenSize = sourceLength / 2 + 8;
        int offset16Size = sourceLength / 3;
        int offset32Size = sourceLength / 8;
        int lengthSize = sourceLength / 29;

        int totalSize = checked(literalSize + tokenSize + offset16Size * 2 + lengthSize + offset32Size * 4 + 256);
        if (useDeltaLiterals)
            totalSize += literalSize;
        byte* buffer = (byte*)NativeMemory.Alloc((nuint)totalSize);

        writer->AllocationBase = buffer;
        writer->LiteralStart = writer->LiteralCursor = buffer;
        buffer += literalSize;
        if (useDeltaLiterals)
        {
            writer->DeltaLiteralStart = writer->DeltaLiteralCursor = buffer;
            buffer += literalSize;
        }
        else
        {
            writer->DeltaLiteralStart = writer->DeltaLiteralCursor = null;
        }
        writer->TokenStart = writer->TokenCursor = buffer;
        buffer += tokenSize;
        writer->Offset16Start = writer->Offset16Cursor = (ushort*)buffer;
        buffer += (nuint)offset16Size * 2;
        writer->Offset32Start = writer->Offset32Cursor = buffer;
        buffer += (nuint)offset32Size * 4;
        writer->LengthStart = writer->LengthCursor = buffer;
        buffer += lengthSize;
        writer->TokenStream2Offset = 0;
        writer->Offset32CountBlock1 = writer->Offset32CountBlock2 = 0;
        writer->Block1Size = Math.Min(sourceLength, FastConstants.Block1MaxSize);
        writer->Block2Size = sourceLength - writer->Block1Size;
    }

    /// <summary>Frees the native buffer allocated by <see cref="Initialize"/>.</summary>
    public static void FreeBuffers(FastStreamWriter* writer)
    {
        NativeMemory.Free(writer->AllocationBase);
    }
}

/// <summary>
/// Static methods for writing tokens/matches into a <see cref="FastStreamWriter"/>
/// and assembling the final compressed output.
/// </summary>
internal static unsafe class Encoder
{
    // ────────────────────────────────────────────────────────────────
    //  Low-level stream writing helpers
    // ────────────────────────────────────────────────────────────────

    /// <summary>Extends a match forward by comparing 4 bytes at a time.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static byte* ExtendMatchForward(byte* source, byte* sourceEnd, nint recentOffset)
    {
        while (source < sourceEnd)
        {
            uint xorValue = *(uint*)source ^ *(uint*)(source + recentOffset);
            source += 4;
            if (xorValue != 0)
            {
                source = source + (BitOperations.TrailingZeroCount(xorValue) >> 3) - 4;
                break;
            }
        }
        return source < sourceEnd ? source : sourceEnd;
    }

    /// <summary>Copies bytes in 4-byte chunks (may overwrite past <paramref name="count"/>).</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void CopyBytesUnsafe(byte* destination, byte* source, int count)
    {
        byte* destinationEnd = destination + count;
        do
        {
            *(uint*)destination = *(uint*)source;
            destination += 4;
            source += 4;
        } while (destination < destinationEnd);
    }

    /// <summary>Writes an extended length value to the length stream.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteLengthValue(ref FastStreamWriter writer, uint value)
    {
        byte* lengthPointer = writer.LengthCursor;
        if (value > FastConstants.MaxSingleByteLengthValue)
        {
            // Extended length encoding: tag byte = (value & 3) - 4 maps to 0xFC..0xFF,
            // followed by a 16-bit value = (value - base) >> 2. The decoder reverses this.
            *lengthPointer = (byte)((value & FastConstants.ExtendedLengthMask) - 4);
            *(ushort*)(lengthPointer + 1) = (ushort)((value - ((value & FastConstants.ExtendedLengthMask) + FastConstants.ExtendedLengthBase)) >> 2);
            lengthPointer += 3;
        }
        else
        {
            *lengthPointer++ = (byte)value;
        }
        writer.LengthCursor = lengthPointer;
    }

    /// <summary>Writes a 32-bit offset to the offset32 stream.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteOffset32(ref FastStreamWriter writer, uint offset)
    {
        byte* pointer = writer.Offset32Cursor;
        if (offset >= FastConstants.LargeOffsetThreshold)
        {
            uint truncated = (offset & 0x3FFFFF) | 0xC00000;
            pointer[0] = (byte)truncated;
            pointer[1] = (byte)(truncated >> 8);
            pointer[2] = (byte)(truncated >> 16);
            pointer[3] = (byte)((offset - truncated) >> 22);
            pointer += 4;
        }
        else
        {
            pointer[0] = (byte)offset;
            pointer[1] = (byte)(offset >> 8);
            pointer[2] = (byte)(offset >> 16);
            pointer += 3;
        }
        writer.Offset32Cursor = pointer;
        writer.Offset32Count++;
    }

    /// <summary>
    /// Writes a match with potentially complex encoding (long literal runs,
    /// large offsets, or long match lengths).
    /// </summary>
    public static void WriteComplexOffset(ref FastStreamWriter writer, int matchLength, int literalRunLength,
        int offset, nint recentOffset, byte* literalPointer)
    {
        byte* literalEnd = literalPointer + literalRunLength;
        if (writer.DeltaLiteralCursor != null)
        {
            byte* oldDeltaLiteral = writer.DeltaLiteralCursor;
            writer.DeltaLiteralCursor += literalRunLength;
            OffsetEncoder.SubtractBytesUnsafe(oldDeltaLiteral, literalPointer, (nuint)literalRunLength, (nuint)recentOffset);
        }
        byte* oldLiteral = writer.LiteralCursor;
        writer.LiteralCursor += literalRunLength;
        CopyBytesUnsafe(oldLiteral, literalPointer, literalRunLength);

        if (literalRunLength < 64)
        {
            while (literalRunLength > 7)
            {
                *writer.TokenCursor++ = 0x87;
                literalRunLength -= 7;
            }
        }
        else
        {
            WriteLengthValue(ref writer, (uint)(literalRunLength - 64));
            *writer.TokenCursor++ = 0x00;
            writer.ComplexTokenCount++;
            literalRunLength = 0;

            if (matchLength == 0)
                return;
        }

        if (offset <= 0xffff && matchLength < FastConstants.NearOffsetMaxMatchLength + 1)
        {
            int currentMatchLength = Math.Min(matchLength, 15);
            byte token = (byte)(literalRunLength + 8 * currentMatchLength);
            if (offset == 0)
            {
                token += 0x80;
            }
            else
            {
                *writer.Offset16Cursor++ = (ushort)offset;
            }
            matchLength -= currentMatchLength;
            *writer.TokenCursor++ = token;

            while (matchLength != 0)
            {
                currentMatchLength = Math.Min(matchLength, 15);
                *writer.TokenCursor++ = (byte)(0x80 + 8 * currentMatchLength);
                matchLength -= currentMatchLength;
            }
        }
        else
        {
            writer.ComplexTokenCount++;
            if (literalRunLength != 0)
                *writer.TokenCursor++ = (byte)(0x80 + literalRunLength);

            if (offset == 0)
                offset = -(int)recentOffset;

            byte tokenByte;
            int lengthValue;

            if (offset > 0xffff)
            {
                if (matchLength - 5 <= 23)
                {
                    tokenByte = (byte)(matchLength - 5);
                    lengthValue = -1;
                }
                else
                {
                    tokenByte = 2;
                    lengthValue = matchLength - 29;
                }
            }
            else
            {
                tokenByte = 1;
                lengthValue = matchLength - 91;
            }
            *writer.TokenCursor++ = tokenByte;
            if (lengthValue >= 0)
                WriteLengthValue(ref writer, (uint)lengthValue);

            if (offset > 0xffff)
            {
                WriteOffset32(ref writer, (uint)(offset + (int)(writer.SourcePointer + writer.Block2StartOffset - literalEnd)));
            }
            else
            {
                *writer.Offset16Cursor++ = (ushort)offset;
            }
        }
    }

    /// <summary>
    /// Writes a match with its preceding literals. Uses the fast path for short
    /// literal runs and small offsets, falling back to <see cref="WriteComplexOffset"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteOffset(ref FastStreamWriter writer, int matchLength, int literalRunLength,
        int offset, nint recentOffset, byte* literalStart)
    {
        if (literalRunLength <= 7 && matchLength <= 15 && offset <= 0xffff)
        {
            *(ulong*)writer.LiteralCursor = *(ulong*)literalStart;
            writer.LiteralCursor += literalRunLength;
            if (writer.DeltaLiteralCursor != null)
            {
                // Delta-literal: subtract the byte at the recent offset from the literal byte.
                if (Sse2.IsSupported)
                {
                    Sse2.StoreScalar((long*)writer.DeltaLiteralCursor,
                        Sse2.Subtract(Sse2.LoadScalarVector128((long*)literalStart).AsByte(),
                                      Sse2.LoadScalarVector128((long*)(literalStart + recentOffset)).AsByte()).AsInt64());
                }
                else if (AdvSimd.IsSupported)
                {
                    AdvSimd.Store(writer.DeltaLiteralCursor,
                        AdvSimd.Subtract(AdvSimd.LoadVector64(literalStart),
                                         AdvSimd.LoadVector64(literalStart + recentOffset)));
                }
                else
                {
                    for (int k = 0; k < 8; k++)
                        writer.DeltaLiteralCursor[k] = (byte)(literalStart[k] - literalStart[k + recentOffset]);
                }
                writer.DeltaLiteralCursor += literalRunLength;
            }
            *writer.TokenCursor++ = (byte)(((offset == 0) ? 0x80 : 0) + literalRunLength + 8 * matchLength);
            if (offset != 0)
                *writer.Offset16Cursor++ = (ushort)offset;
        }
        else
        {
            WriteComplexOffset(ref writer, matchLength, literalRunLength, offset, recentOffset, literalStart);
        }
    }

    /// <summary>
    /// Scans for single-byte delta-literal matches within a literal run
    /// and splits the run to encode them as length-1 recent-offset matches.
    /// </summary>
    private static void WriteOffsetWithLiteral1Inner(ref FastStreamWriter writer, int matchLength, int literalRunLength,
        int offset, nint recentOffset, byte* literalStart)
    {
        int i = 1, last = 0;
        int* found = stackalloc int[33];
        int foundCount = 0;
        while (i < literalRunLength)
        {
            int mask;
            if (Sse2.IsSupported)
            {
                mask = Sse2.MoveMask(Sse2.CompareEqual(
                    Sse2.LoadVector128(&literalStart[i]),
                    Sse2.LoadVector128(&literalStart[i + recentOffset])));
            }
            else
            {
                var a = Vector128.LoadUnsafe(ref literalStart[i]);
                var b = Vector128.LoadUnsafe(ref literalStart[i + recentOffset]);
                mask = CopyHelpers.MoveMask(Vector128.Equals(a, b).AsByte());
            }
            if (mask == 0)
            {
                i += 16;
            }
            else
            {
                int j = i + BitOperations.TrailingZeroCount(mask);
                if (j >= literalRunLength)
                    break;
                i = j + 1;
                if (j - last != 0)
                {
                    found[foundCount++] = j - last;
                    last = i;
                }
            }
        }
        if (foundCount != 0)
        {
            Debug.Assert(foundCount < 33, "foundCount exceeded stackalloc boundary");
            found[foundCount] = literalRunLength - last;
            for (int fi = 0; fi < foundCount; fi++)
            {
                int current = found[fi];
                if (FastConstants.LiteralRunSlotCount(current) + FastConstants.LiteralRunSlotCount(found[fi + 1]) + 1 > 7)
                {
                    WriteOffset(ref writer, 1, current, 0, recentOffset, literalStart);
                    literalStart += current + 1;
                    literalRunLength -= current + 1;
                }
                else
                {
                    found[fi + 1] += current + 1;
                }
            }
        }
        WriteOffset(ref writer, matchLength, literalRunLength, offset, recentOffset, literalStart);
    }

    /// <summary>
    /// Copies trailing literal bytes (after the last match) to the literal and
    /// delta-literal streams. Shared epilogue for all parser variants.
    /// </summary>
    /// <param name="writer">Stream writer to append literals to.</param>
    /// <param name="literalStart">Pointer to the first unmatched byte.</param>
    /// <param name="sourceEnd">Pointer past the end of the source block.</param>
    /// <param name="recentOffset">Most recent match offset (negative).</param>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void CopyTrailingLiterals(ref FastStreamWriter writer, byte* literalStart, byte* sourceEnd, nint recentOffset)
    {
        nint count = (nint)(sourceEnd - literalStart);
        if (count > 0)
        {
            byte* oldLiteral = writer.LiteralCursor;
            writer.LiteralCursor += (int)count;
            Buffer.MemoryCopy(literalStart, oldLiteral, count, count);
            if (writer.DeltaLiteralCursor != null)
            {
                byte* oldDeltaLiteral = writer.DeltaLiteralCursor;
                writer.DeltaLiteralCursor += (int)count;
                OffsetEncoder.SubtractBytes(oldDeltaLiteral, literalStart, (nuint)count, (nuint)recentOffset);
            }
        }
    }

    public static void WriteOffsetWithLiteral1(ref FastStreamWriter writer, int matchLength, int literalRunLength,
        int offset, nint recentOffset, byte* literalStart)
    {
        if ((uint)(literalRunLength - 8) > 55)
        {
            WriteOffset(ref writer, matchLength, literalRunLength, offset, recentOffset, literalStart);
        }
        else
        {
            WriteOffsetWithLiteral1Inner(ref writer, matchLength, literalRunLength, offset, recentOffset, literalStart);
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  Final output assembly
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Returns the maximum scratch memory usage for a given codec and chunk length.
    /// </summary>
    private static int GetScratchUsage(int codecId, int chunkLength)
    {
        int result = 2 * chunkLength + 32;
        if (codecId != 9 && codecId != 11)
            result += chunkLength;
        return Math.Min(result + 0xD000, 0x6C000);
    }

    /// <summary>
    /// Assembles the six parallel streams into the final compressed output.
    /// Entropy-codes the literal and token streams, packs offset16/32 and length streams,
    /// and computes the rate-distortion cost.
    /// </summary>
    public static int AssembleCompressedOutput(float* costOutput, int* chunkTypeOutput,
        byte* destination, byte* destinationEnd, LzCoder coder, LzTemp lztemp, FastStreamWriter* writer, int startPosition,
        int? entropyOptsOverride = null, int? levelOverride = null)
    {
        bool useLiteralEntropyCoding = coder.UseLiteralEntropyCoding;
        byte* source = writer->SourcePointer;
        int sourceLength = writer->SourceLength;
        int tokenCount = (int)(writer->TokenCursor - writer->TokenStart);
        byte* destinationStart = destination;
        if (tokenCount == 0 && (!useLiteralEntropyCoding || writer->DeltaLiteralStart == null))
            return sourceLength;

        int entropyOpts = entropyOptsOverride ?? coder.EntropyOptions;
        int level = levelOverride ?? coder.CompressionLevel;
        int platforms = 0;
        float speedTradeoff = coder.SpeedTradeoff;

        int initialBytes = 0;
        if (startPosition == 0)
        {
            *(ulong*)destination = *(ulong*)source;
            destination += FastConstants.InitialCopyBytes;
            initialBytes = FastConstants.InitialCopyBytes;
        }

        int literalCount = (int)(writer->LiteralCursor - writer->LiteralStart);
        int deltaLiteralCount = writer->DeltaLiteralCursor != null ? (int)(writer->DeltaLiteralCursor - writer->DeltaLiteralStart) : 0;

        float literalCost = StreamLZConstants.InvalidCost;
        float rawLiteralCost = literalCount + 3;

        if (literalCount == 0 && deltaLiteralCount > 0)
        {
            *chunkTypeOutput = 0;

            HistoU8 deltaLiteralHisto;
            HighEntropyEncoder.CountBytesHistoU8(writer->DeltaLiteralStart, deltaLiteralCount, &deltaLiteralHisto);
            int encodedLiteralBytes = HighEntropyEncoder.EncodeArrayU8WithHisto(destination, destinationEnd, writer->DeltaLiteralStart, deltaLiteralCount,
                deltaLiteralHisto, entropyOpts, speedTradeoff, &literalCost, level);
            if (encodedLiteralBytes < 0 || encodedLiteralBytes > deltaLiteralCount)
                return sourceLength;
            destination += encodedLiteralBytes;
        }
        else if (useLiteralEntropyCoding && literalCount >= 32)
        {
            HistoU8 literalHisto;
            HighEntropyEncoder.CountBytesHistoU8(writer->LiteralStart, literalCount, &literalHisto);
            int encodedBytes, encodedLiteralBytes = -1;
            if (writer->DeltaLiteralStart != null)
            {
                HistoU8 deltaLiteralHisto;
                HighEntropyEncoder.CountBytesHistoU8(writer->DeltaLiteralStart, literalCount, &deltaLiteralHisto);
                float deltaLiteralTimeCost = CostModel.CombinePlatformCostsScaled(platforms, literalCount, 0.324f, 0.433f, 0.550f, 0.289f) * speedTradeoff;
                if (level >= 6 || OffsetEncoder.GetHistoCostApprox(&literalHisto, literalCount) * 0.125f > OffsetEncoder.GetHistoCostApprox(&deltaLiteralHisto, literalCount) * 0.125f + deltaLiteralTimeCost)
                {
                    *chunkTypeOutput = 0;
                    encodedLiteralBytes = HighEntropyEncoder.EncodeArrayU8WithHisto(destination, destinationEnd, writer->DeltaLiteralStart, literalCount,
                        deltaLiteralHisto, entropyOpts, speedTradeoff, &literalCost, level);
                    literalCost += deltaLiteralTimeCost;
                    if (encodedLiteralBytes < 0 || encodedLiteralBytes >= literalCount || literalCost > rawLiteralCost)
                    {
                        literalCost = StreamLZConstants.InvalidCost;
                        encodedLiteralBytes = -1;
                    }
                }
            }
            if (encodedLiteralBytes < 0 || level >= 6)
            {
                encodedBytes = HighEntropyEncoder.EncodeArrayU8(destination, destinationEnd, writer->LiteralStart, literalCount,
                    entropyOpts, speedTradeoff, &literalCost, level, null);
                if (encodedBytes > 0)
                {
                    encodedLiteralBytes = encodedBytes;
                    *chunkTypeOutput = 1;
                }
                else if (encodedLiteralBytes < 0)
                {
                    return sourceLength;
                }
            }
            destination += encodedLiteralBytes;
        }
        else
        {
            int encodedLiteralBytes = literalCount + 3;
            literalCost = rawLiteralCost;
            *chunkTypeOutput = 1;
            if (useLiteralEntropyCoding)
            {
                HighEntropyEncoder.EncodeArrayU8_Memcpy(destination, destinationEnd, writer->LiteralStart, literalCount);
            }
            else
            {
                // Raw-coded mode writes literals directly to the stream
                destination[0] = (byte)(literalCount >> 16);
                destination[1] = (byte)(literalCount >> 8);
                destination[2] = (byte)literalCount;
            }
            destination += encodedLiteralBytes;
        }

        // Encode tokens
        float tokenCost = StreamLZConstants.InvalidCost;
        int encodedTokenBytes;
        if (useLiteralEntropyCoding)
        {
            encodedTokenBytes = HighEntropyEncoder.EncodeArrayU8(destination, destinationEnd, writer->TokenStart, tokenCount,
                entropyOpts, speedTradeoff, &tokenCost, level, null);
        }
        else
        {
            tokenCost = tokenCount + 3;
            encodedTokenBytes = HighEntropyEncoder.EncodeArrayU8_Memcpy(destination, destinationEnd, writer->TokenStart, tokenCount);
        }
        if (encodedTokenBytes < 0)
            return sourceLength;
        destination += encodedTokenBytes;

        byte* destinationAfterTokens = destination;

        if (destinationEnd - destination <= 16)
            return sourceLength;

        if (sourceLength > FastConstants.Block1MaxSize)
        {
            *(ushort*)destination = (ushort)writer->TokenStream2Offset;
            destination += 2;
        }

        int offset16Count = (int)(writer->Offset16Cursor - writer->Offset16Start);
        float offset16Cost = offset16Count * 2;
        int offset16Bytes = 0;
        bool useEntropyCodedOffset16 = false;

        if (useLiteralEntropyCoding && offset16Count >= 32)
        {
            // Try entropy-coded split encoding: separate high and low bytes
            byte* lowOffset16 = writer->LiteralStart;
            byte* highOffset16 = lowOffset16 + offset16Count;
            for (int i = 0; i < offset16Count; i++)
            {
                uint value = writer->Offset16Start[i];
                lowOffset16[i] = (byte)value;
                highOffset16[i] = (byte)(value >> 8);
            }
            byte* offset16Destination = writer->LiteralStart + 2 * offset16Count;
            float costOffset16Low = StreamLZConstants.InvalidCost;
            float costOffset16High = StreamLZConstants.InvalidCost;
            int highBytes = HighEntropyEncoder.EncodeArrayU8(offset16Destination, (byte*)writer->Offset16Start, highOffset16, offset16Count,
                entropyOpts, speedTradeoff, &costOffset16High, level, null);
            int lowBytes = HighEntropyEncoder.EncodeArrayU8(offset16Destination + highBytes, (byte*)writer->Offset16Start, lowOffset16, offset16Count,
                entropyOpts, speedTradeoff, &costOffset16Low, level, null);
            offset16Bytes = highBytes + lowBytes;
            float cost = costOffset16Low + costOffset16High + CostModel.GetDecodingTimeOffset16(platforms, offset16Count) * speedTradeoff;
            if (cost < offset16Cost && offset16Bytes + 2 < destinationEnd - destination)
            {
                useEntropyCodedOffset16 = true;
                offset16Cost = cost;
                *(ushort*)destination = FastConstants.EntropyCoded16Marker;
                destination += 2;
                Buffer.MemoryCopy(offset16Destination, destination, destinationEnd - destination, offset16Bytes);
                destination += offset16Bytes;
            }
        }

        if (!useEntropyCodedOffset16)
        {
            // Fallback: write raw offset16 data
            offset16Bytes = (int)((byte*)writer->Offset16Cursor - (byte*)writer->Offset16Start);
            if (offset16Bytes + 2 >= destinationEnd - destination)
                return sourceLength;
            *(ushort*)destination = (ushort)offset16Count;
            destination += 2;
            Buffer.MemoryCopy(writer->Offset16Start, destination, destinationEnd - destination, offset16Bytes);
            destination += offset16Bytes;
        }

        int offset32Count = writer->Offset32CountBlock1 + writer->Offset32CountBlock2;
        int requiredScratch = tokenCount + literalCount + 4 * (offset32Count + offset16Count) + 0xd000 + 0x40 + 4;

        if (requiredScratch > GetScratchUsage(coder.CodecId, sourceLength))
        {
            Debug.Assert(false);
            return sourceLength;
        }

        if (destinationEnd - destination <= 7)
            return sourceLength;

        uint packedOffset32Counts = (uint)(Math.Min(writer->Offset32CountBlock1, 4095) << 12) + (uint)Math.Min(writer->Offset32CountBlock2, 4095);
        *(uint*)destination = packedOffset32Counts;
        destination += 3;

        if (writer->Offset32CountBlock1 >= 4095)
        {
            *(ushort*)destination = (ushort)writer->Offset32CountBlock1;
            destination += 2;
        }
        if (writer->Offset32CountBlock2 >= 4095)
        {
            *(ushort*)destination = (ushort)writer->Offset32CountBlock2;
            destination += 2;
        }

        int offset32ByteCount = (int)(writer->Offset32Cursor - writer->Offset32Start);
        if (offset32ByteCount >= destinationEnd - destination)
            return sourceLength;
        Buffer.MemoryCopy(writer->Offset32Start, destination, destinationEnd - destination, offset32ByteCount);
        destination += offset32ByteCount;

        int lengthCount = (int)(writer->LengthCursor - writer->LengthStart);
        if (lengthCount >= destinationEnd - destination)
            return sourceLength;
        Buffer.MemoryCopy(writer->LengthStart, destination, destinationEnd - destination, lengthCount);
        destination += lengthCount;

        if (destination - destinationStart >= sourceLength)
            return sourceLength;

        float decodingTime = useLiteralEntropyCoding
            ? CostModel.GetDecodingTimeEntropyCoded(platforms, sourceLength, tokenCount, writer->ComplexTokenCount)
            : CostModel.GetDecodingTimeRawCoded(platforms, sourceLength, tokenCount, writer->ComplexTokenCount, literalCount);

        float offset32Time = CostModel.GetDecodingTimeOffset32(platforms, offset32Count) * speedTradeoff;
        int extraBytes = (int)(destination - destinationAfterTokens) - offset16Bytes;
        *costOutput = offset32Time + (tokenCost + literalCost + decodingTime * speedTradeoff + extraBytes + offset16Cost + initialBytes);
        return (int)(destination - destinationStart);
    }
}
