using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Common;

/// <summary>
/// Bit-level reader that consumes bits from a forward byte stream,
/// accumulating into a 32-bit buffer.
/// <para>
/// Invariant: after any <see cref="Refill"/> or <see cref="RefillBackwards"/> call,
/// <see cref="BitPos"/> &lt;= 0, which guarantees at least 24 bits are available for
/// consumption without another refill.
/// </para>
/// </summary>
#pragma warning disable CS0649, IDE0044 // Fields assigned via unsafe pointer operations, not C# assignment
internal unsafe struct BitReader
{
    /// <summary>Current read position in the byte stream.</summary>
    public byte* P;

    /// <summary>End of the byte stream buffer.</summary>
    public byte* PEnd;

    /// <summary>Accumulated bits (most-significant bits are consumed first).</summary>
    public uint Bits;

    /// <summary>
    /// Next byte will end up in this bit position within <see cref="Bits"/>.
    /// When &lt;= 0, the buffer has at least 24 valid bits.
    /// </summary>
    public int BitPos;

    /// <summary>
    /// Refills the bit buffer so that at least 24 bits are available.
    /// Reads forward through the stream.
    /// No per-byte bounds check — valid streams never exhaust
    /// (verified post-hoc by <c>bitsA.P == bitsB.P</c> in UnpackOffsets).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Refill()
    {
        Debug.Assert(BitPos <= 24);
        while (BitPos > 0)
        {
            if (P >= PEnd)
                break;
            Bits |= (uint)*P << BitPos;
            BitPos -= 8;
            P++;
        }
    }

    /// <summary>
    /// Refill the bit buffer so that at least 24 bits are available.
    /// Reads backwards through the stream.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void RefillBackwards()
    {
        Debug.Assert(BitPos <= 24);
        while (BitPos > 0)
        {
            if (P <= PEnd)
                break;
            P--;
            Bits |= (uint)*P << BitPos;
            BitPos -= 8;
        }
    }

    /// <summary>
    /// Calls <see cref="Refill"/> or <see cref="RefillBackwards"/> based on the direction flag.
    /// </summary>
    /// <param name="backwards">If true, refills backwards; otherwise forwards.</param>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void RefillConditional(bool backwards) { if (backwards) RefillBackwards(); else Refill(); }

    /// <summary>
    /// Refills the buffer, then reads a single bit from the MSB.
    /// </summary>
    /// <returns>The bit value (0 or 1).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadBit()
    {
        Refill();
        int r = (int)(Bits >> 31);
        Bits <<= 1;
        BitPos += 1;
        return r;
    }

    /// <summary>
    /// Reads a single bit without refilling first.
    /// </summary>
    /// <returns>The bit value (0 or 1).</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadBitNoRefill()
    {
        int r = (int)(Bits >> 31);
        Bits <<= 1;
        BitPos += 1;
        return r;
    }

    /// <summary>
    /// Reads <paramref name="n"/> bits without refilling. n must be >= 1.
    /// </summary>
    /// <param name="n">Number of bits to read (must be at least 1).</param>
    /// <returns>The unsigned value formed by the consumed bits.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadBitsNoRefill(int n)
    {
        int r = (int)(Bits >> (32 - n));
        Bits <<= n;
        BitPos += n;
        return r;
    }

    /// <summary>
    /// Reads <paramref name="n"/> bits without refilling. n may be zero.
    /// </summary>
    /// <param name="n">Number of bits to read (may be 0).</param>
    /// <returns>The unsigned value formed by the consumed bits, or 0 when <paramref name="n"/> is 0.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadBitsNoRefillZero(int n)
    {
        int r = (int)(Bits >> 1 >> (31 - n)); // Double-shift handles n=0 without branching (single shift by 32 is undefined in C#)
        Bits <<= n;
        BitPos += n;
        return r;
    }

    /// <summary>
    /// Reads up to 32 bits (more than 24), with forward refill.
    /// </summary>
    /// <param name="n">Number of bits to read (up to 32).</param>
    /// <returns>The unsigned value formed by the consumed bits.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint ReadMoreThan24Bits(int n) => ReadMoreThan24BitsCore(n, backwards: false);

    /// <summary>
    /// Reads up to 32 bits (more than 24), with backwards refill.
    /// </summary>
    /// <param name="n">Number of bits to read (up to 32).</param>
    /// <returns>The unsigned value formed by the consumed bits.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint ReadMoreThan24BitsB(int n) => ReadMoreThan24BitsCore(n, backwards: true);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private uint ReadMoreThan24BitsCore(int n, bool backwards)
    {
        Debug.Assert(n > 0 && n <= 32);
        uint rv;
        if (n <= 24)
        {
            rv = (uint)ReadBitsNoRefillZero(n);
        }
        else
        {
            rv = (uint)ReadBitsNoRefill(24) << (n - 24);
            RefillConditional(backwards);
            rv += (uint)ReadBitsNoRefill(n - 24);
        }
        RefillConditional(backwards);
        return rv;
    }

    /// <summary>
    /// Reads an exponential-Golomb (gamma) coded value.
    /// Assumes the reader already has at least 23 valid bits.
    /// </summary>
    /// <returns>The decoded gamma value.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadGamma()
    {
        int n;
        if (Bits != 0)
        {
            n = BitOperations.LeadingZeroCount(Bits);
        }
        else
        {
            throw new InvalidDataException("Corrupted stream: ReadGamma encountered zero bits");
        }
        n = 2 * n + 2;
        Debug.Assert(n < 24);
        BitPos += n;
        int r = (int)(Bits >> (32 - n));
        Bits <<= n;
        return r - 2;
    }

    /// <summary>
    /// Reads a gamma value with <paramref name="forced"/> number of forced extra bits.
    /// </summary>
    /// <param name="forced">Number of additional bits to read after the gamma prefix.</param>
    /// <returns>The decoded gamma value incorporating the forced bits.</returns>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    // Reads a gamma code with "forced bits" — extra bits appended after the gamma prefix for additional precision.
    public int ReadGammaX(int forced)
    {
        if (Bits != 0)
        {
            int leadingZeros = BitOperations.LeadingZeroCount(Bits);
            Debug.Assert(leadingZeros < 24);
            int result = (int)(Bits >> (31 - leadingZeros - forced)) + ((leadingZeros - 1) << forced);
            Bits <<= leadingZeros + forced + 1;
            BitPos += leadingZeros + forced + 1;
            return result;
        }
        return 0;
    }

    /// <summary>
    /// Reads an offset code parameterized by <paramref name="distanceSymbol"/>, using forward refill.
    /// </summary>
    /// <param name="distanceSymbol">The distance symbol from the Huffman table that determines how many extra bits to read.</param>
    /// <returns>The decoded distance value.</returns>
    public uint ReadDistance(uint distanceSymbol) => ReadDistanceCore(distanceSymbol, backwards: false);

    /// <summary>
    /// Reads an offset code parameterized by <paramref name="distanceSymbol"/>, using backwards refill.
    /// </summary>
    /// <param name="distanceSymbol">The distance symbol from the Huffman table that determines how many extra bits to read.</param>
    /// <returns>The decoded distance value.</returns>
    public uint ReadDistanceBackward(uint distanceSymbol) => ReadDistanceCore(distanceSymbol, backwards: true);

    private uint ReadDistanceCore(uint distanceSymbol, bool backwards)
    {
        uint rotated, mask, bitsToRead, result;
        if (distanceSymbol < StreamLZConstants.HighOffsetMarker)
        {
            bitsToRead = (distanceSymbol >> 4) + 5;
            rotated = BitOperations.RotateLeft(Bits | 1, (int)bitsToRead);
            BitPos += (int)bitsToRead;
            mask = (2u << (int)bitsToRead) - 1;
            Bits = rotated & ~mask;
            result = ((rotated & mask) << 4) + (distanceSymbol & 0xF) - StreamLZConstants.OffsetBiasConstant;
        }
        else
        {
            bitsToRead = distanceSymbol - (uint)StreamLZConstants.HighOffsetMarker + 4;
            rotated = BitOperations.RotateLeft(Bits | 1, (int)bitsToRead);
            BitPos += (int)bitsToRead;
            mask = (2u << (int)bitsToRead) - 1;
            Bits = rotated & ~mask;
            result = (uint)StreamLZConstants.LowOffsetEncodingLimit + ((rotated & mask) << 12);
            RefillConditional(backwards);
            result += Bits >> 20;
            BitPos += 12;
            Bits <<= 12;
        }
        RefillConditional(backwards);
        return result;
    }

    /// <summary>
    /// Reads a length code with forward refill.
    /// Returns false if the leading zero count exceeds 12 (invalid).
    /// </summary>
    /// <param name="v">When this method returns true, contains the decoded length value.</param>
    /// <returns><see langword="true"/> if the length was decoded successfully; <see langword="false"/> if the stream is invalid.</returns>
    public bool ReadLength(out uint v) => ReadLengthCore(out v, backwards: false);

    /// <summary>
    /// Reads a length code with backwards refill.
    /// Returns false if the leading zero count exceeds 12 (invalid).
    /// </summary>
    /// <param name="v">When this method returns true, contains the decoded length value.</param>
    /// <returns><see langword="true"/> if the length was decoded successfully; <see langword="false"/> if the stream is invalid.</returns>
    public bool ReadLengthBackward(out uint v) => ReadLengthCore(out v, backwards: true);

    // Returns false on stream corruption (leading zero count exceeds maximum encodable length).
    private bool ReadLengthCore(out uint decodedLength, bool backwards)
    {
        int leadingZeros = BitOperations.LeadingZeroCount(Bits);
        if (leadingZeros > 12)
        {
            decodedLength = 0;
            return false;
        }
        BitPos += leadingZeros;
        Bits <<= leadingZeros;
        RefillConditional(backwards);
        int totalBits = leadingZeros + 7;
        BitPos += totalBits;
        decodedLength = (Bits >> (32 - totalBits)) - 64;
        Bits <<= totalBits;
        RefillConditional(backwards);
        return true;
    }
}
#pragma warning restore CS0649, IDE0044
