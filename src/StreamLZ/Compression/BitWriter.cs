using System.Buffers.Binary;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Compression;

/// <summary>
/// Forward (low-to-high address) 64-bit bit writer.
/// Bits are accumulated in a 64-bit buffer and flushed in big-endian byte order.
/// <para><b>Invariants:</b></para>
/// <list type="bullet">
///   <item><see cref="Position"/> advances forward as bytes are flushed.</item>
///   <item><see cref="Pos"/> starts at 63 (empty) and decreases as bits are written;
///     when enough bits accumulate (Pos drops below 56), <see cref="Flush"/> writes
///     complete bytes and increments Pos back by 8 per byte flushed.</item>
///   <item><see cref="Bits"/> holds unflushed bits in the low portion of the 64-bit word,
///     shifted left by (Pos + 1) during flush to align the MSB for big-endian output.</item>
///   <item><see cref="TotalBits"/> is a running total across all Write calls (never reset by Flush).</item>
/// </list>
/// </summary>
internal unsafe struct BitWriter64Forward
{
    /// <summary>Current output pointer; advances forward as bytes are flushed.</summary>
    public byte* Position;
    /// <summary>Accumulated bit buffer holding unflushed bits in the low portion.</summary>
    public ulong Bits;
    /// <summary>
    /// Bit position within the buffer. Starts at 63 (empty); decreases by <c>n</c>
    /// on each <see cref="Write"/>. Flush reclaims 8 bits per byte written.
    /// </summary>
    public uint Pos;
    /// <summary>Running total of bits written across all Write/WriteNoFlush calls. Uses long to prevent overflow at 256MB+.</summary>
    public long TotalBits;

    /// <summary>Initializes the writer to write at the given destination.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public BitWriter64Forward(byte* dst)
    {
        Position = dst;
        Bits = 0;
        Pos = 63; // MSB position of 64-bit buffer (initial empty state)
        TotalBits = 0;
    }

    /// <summary>
    /// Flushes complete bytes from the bit buffer to the output pointer (forward direction).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Flush()
    {
        if (Pos == 63) return; // buffer empty, nothing to flush
        uint t = (63 - Pos) >> 3;
        ulong v = Bits << (int)(Pos + 1);
        Pos += 8 * t;
        // Forward: write big-endian (byteswap) and advance pointer
        *(ulong*)Position = BinaryPrimitives.ReverseEndianness(v);
        Position += t;
    }

    /// <summary>
    /// Writes <paramref name="n"/> bits from <paramref name="bits"/> and flushes.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Write(uint bits, int n)
    {
        TotalBits += n;
        Pos -= (uint)n;
        Bits = (Bits << n) | bits;
        Flush();
    }

    /// <summary>
    /// Writes <paramref name="n"/> bits from <paramref name="bits"/> without flushing.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void WriteNoFlush(uint bits, int n)
    {
        TotalBits += n;
        Pos -= (uint)n;
        Bits = (Bits << n) | bits;
    }

    /// <summary>
    /// Returns the pointer just past the last byte written, accounting for
    /// any residual bits in the buffer.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte* GetFinalPtr()
    {
        // Forward: position + (pos != 63 ? 1 : 0)
        return Position + (Pos != 63 ? 1 : 0);
    }
}

/// <summary>
/// Backward (high-to-low address) 64-bit bit writer.
/// Bits are accumulated in a 64-bit buffer and flushed in native byte order,
/// writing toward lower addresses.
/// <para><b>Invariants:</b></para>
/// <list type="bullet">
///   <item><see cref="Position"/> retreats (decreases) as bytes are flushed.</item>
///   <item><see cref="Pos"/> starts at 63 (empty) and decreases as bits are written;
///     Flush writes complete bytes at <c>Position - 8</c> in native byte order and retreats Position.</item>
///   <item><see cref="Bits"/> holds unflushed bits identically to <see cref="BitWriter64Forward"/>,
///     but the flush writes native-endian (no byte-swap) at the backward pointer.</item>
///   <item><see cref="TotalBits"/> is a running total across all Write calls.</item>
/// </list>
/// </summary>
internal unsafe struct BitWriter64Backward
{
    /// <summary>Current output pointer; retreats (decreases) as bytes are flushed.</summary>
    public byte* Position;
    /// <summary>Accumulated bit buffer holding unflushed bits in the low portion.</summary>
    public ulong Bits;
    /// <summary>
    /// Bit position within the buffer. Starts at 63 (empty); decreases by <c>n</c>
    /// on each <see cref="Write"/>. Flush reclaims 8 bits per byte written.
    /// </summary>
    public uint Pos;
    /// <summary>Running total of bits written across all Write/WriteNoFlush calls. Uses long to prevent overflow at 256MB+.</summary>
    public long TotalBits;

    /// <summary>Initializes the writer to write backward from the given destination.</summary>
    /// <remarks>
    /// The caller must guarantee at least 8 bytes of headroom before the initial
    /// <paramref name="dst"/> value, because <see cref="Flush"/> writes at <c>Position - 8</c>.
    /// </remarks>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public BitWriter64Backward(byte* dst)
    {
        Position = dst;
        Bits = 0;
        Pos = 63;
        TotalBits = 0;
    }

    /// <summary>
    /// Flushes complete bytes from the bit buffer to the output pointer (backward direction).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Flush()
    {
        if (Pos == 63) return; // buffer empty, nothing to flush
        uint t = (63 - Pos) >> 3;
        ulong v = Bits << (int)(Pos + 1);
        Pos += 8 * t;
        // Backward: write native-endian at Position-8 and retreat pointer
        *(ulong*)(Position - 8) = v;
        Position -= t;
    }

    /// <summary>
    /// Writes <paramref name="n"/> bits from <paramref name="bits"/> and flushes.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Write(uint bits, int n)
    {
        TotalBits += n;
        Pos -= (uint)n;
        Bits = (Bits << n) | bits;
        Flush();
    }

    /// <summary>
    /// Writes <paramref name="n"/> bits from <paramref name="bits"/> without flushing.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void WriteNoFlush(uint bits, int n)
    {
        TotalBits += n;
        Pos -= (uint)n;
        Bits = (Bits << n) | bits;
    }

    /// <summary>
    /// Returns the pointer just past the last byte written (toward lower addresses),
    /// accounting for any residual bits in the buffer.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte* GetFinalPtr()
    {
        // Backward: position - (pos != 63 ? 1 : 0)
        return Position - (Pos != 63 ? 1 : 0);
    }
}

/// <summary>
/// Forward (low-to-high address) 32-bit bit writer.
/// Bits are accumulated in a 64-bit buffer; once 32 bits are available they
/// are written out in native (little-endian) byte order.
/// <para><b>Invariants:</b></para>
/// <list type="bullet">
///   <item><see cref="Position"/> advances forward by 4 each time <see cref="Push32"/> flushes.</item>
///   <item><see cref="BitPos"/> counts bits accumulated in <see cref="Bits"/>; always &lt; 64.
///     After <see cref="Push32"/>, BitPos is &lt; 32.</item>
///   <item><see cref="Bits"/> stores pending bits from bit 0 upward (LSB-first packing).
///     The low 32 bits are written as a native-endian uint when BitPos reaches 32.</item>
/// </list>
/// </summary>
internal unsafe struct BitWriter32Forward
{
    /// <summary>Accumulated bit buffer; bits are packed from bit 0 upward (LSB-first).</summary>
    public ulong Bits;
    /// <summary>Current output pointer; advances forward by 4 on each <see cref="Push32"/>.</summary>
    public byte* Position;
    /// <summary>Number of bits currently accumulated in <see cref="Bits"/>. Always &lt; 64; &lt; 32 after <see cref="Push32"/>.</summary>
    public int BitPos;

    /// <summary>Initializes the writer to write at the given destination.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public BitWriter32Forward(byte* dst)
    {
        Bits = 0;
        Position = dst;
        BitPos = 0;
    }

    /// <summary>
    /// Accumulates <paramref name="n"/> bits from <paramref name="bits"/> into the buffer.
    /// Call <see cref="Push32"/> afterwards to flush when needed.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Write(uint bits, int n)
    {
        Bits |= (ulong)bits << BitPos;
        BitPos += n;
    }

    /// <summary>
    /// If 32 or more bits have accumulated, writes the low 32 bits to the
    /// output in native byte order and advances the pointer by 4.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Push32()
    {
        if (BitPos >= 32)
        {
            // Forward: write little-endian
            *(uint*)Position = (uint)Bits;
            Position += 4;
            Bits >>= 32;
            BitPos -= 32;
        }
    }

    /// <summary>
    /// Flushes all remaining bits byte-by-byte in forward order.
    /// After this call, <see cref="BitPos"/> may be negative (decremented
    /// past zero by the final 8-bit step) and the struct should be
    /// considered consumed — no further writes are valid.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void PushFinal()
    {
        while (BitPos > 0)
        {
            *Position++ = (byte)Bits;
            Bits >>= 8;
            BitPos -= 8;
        }
        Debug.Assert(BitPos <= 0, "BitWriter32Forward.PushFinal: bits remain unflushed");
    }
}

/// <summary>
/// Backward (high-to-low address) 32-bit bit writer.
/// Bits are accumulated in a 64-bit buffer; once 32 bits are available they
/// are written out in big-endian byte order toward lower addresses.
/// <para><b>Invariants:</b></para>
/// <list type="bullet">
///   <item><see cref="Position"/> retreats by 4 each time <see cref="Push32"/> flushes.</item>
///   <item><see cref="BitPos"/> counts bits accumulated in <see cref="Bits"/>; always &lt; 64.
///     After <see cref="Push32"/>, BitPos is &lt; 32.</item>
///   <item><see cref="Bits"/> stores pending bits from bit 0 upward (LSB-first packing).
///     The low 32 bits are byte-swapped to big-endian before writing at the retreating pointer.</item>
/// </list>
/// </summary>
internal unsafe struct BitWriter32Backward
{
    /// <summary>Accumulated bit buffer; bits are packed from bit 0 upward (LSB-first).</summary>
    public ulong Bits;
    /// <summary>Current output pointer; retreats by 4 on each <see cref="Push32"/>.</summary>
    public byte* Position;
    /// <summary>Number of bits currently accumulated in <see cref="Bits"/>. Always &lt; 64; &lt; 32 after <see cref="Push32"/>.</summary>
    public int BitPos;

    /// <summary>Initializes the writer to write backward from the given destination.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public BitWriter32Backward(byte* dst)
    {
        Bits = 0;
        Position = dst;
        BitPos = 0;
    }

    /// <summary>
    /// Accumulates <paramref name="n"/> bits from <paramref name="bits"/> into the buffer.
    /// Call <see cref="Push32"/> afterwards to flush when needed.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Write(uint bits, int n)
    {
        Bits |= (ulong)bits << BitPos;
        BitPos += n;
    }

    /// <summary>
    /// If 32 or more bits have accumulated, writes the low 32 bits to the
    /// output in big-endian byte order (byte-swapped) and retreats the pointer by 4.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Push32()
    {
        if (BitPos >= 32)
        {
            // Backward: byteswap and write at Position-4, then retreat
            Position -= 4;
            *(uint*)Position = BinaryPrimitives.ReverseEndianness((uint)Bits);
            Bits >>= 32;
            BitPos -= 32;
        }
    }

    /// <summary>
    /// Flushes all remaining bits byte-by-byte in backward order.
    /// After this call, <see cref="BitPos"/> may be negative (decremented
    /// past zero by the final 8-bit step) and the struct should be
    /// considered consumed — no further writes are valid.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void PushFinal()
    {
        while (BitPos > 0)
        {
            *--Position = (byte)Bits;
            Bits >>= 8;
            BitPos -= 8;
        }
        Debug.Assert(BitPos <= 0, "BitWriter32Backward.PushFinal: bits remain unflushed");
    }
}
