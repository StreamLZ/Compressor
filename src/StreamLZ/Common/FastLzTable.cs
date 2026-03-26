namespace StreamLZ.Common;

/// <summary>
/// Represents a contiguous byte range. Start &lt;= End.
/// Start == End represents an empty range.
/// </summary>
internal unsafe struct StreamRange<T> where T : unmanaged
{
    /// <summary>Pointer to the first element.</summary>
    public T* Start;

    /// <summary>Pointer past the last element.</summary>
    public T* End;
}

/// <summary>
/// Fast/Turbo LZ decode tables for the second phase of decompression.
/// Both Fast and Turbo use the same on-disk format; only the compressor differs.
/// </summary>
/// <remarks>
/// Flag stream format:
/// <para>Read flagbyte from CommandStream.</para>
/// <para>If flagbyte >= 24:</para>
/// <para>  bit 7 clear: read from Offset16Stream into recent_offs.</para>
/// <para>  bit 7 set:   don't read offset.</para>
/// <para>  bits 0-2:    number of literals to copy from LiteralStream.</para>
/// <para>  bits 3-6:    number of bytes to copy from recent_offs.</para>
/// <para>If flagbyte == 0: read long literal run from LengthStream (L+64).</para>
/// <para>If flagbyte == 1: read long near-offset match from LengthStream (L+91).</para>
/// <para>If flagbyte == 2: read long far-offset match from LengthStream (L+29).</para>
/// <para>If flagbyte > 2 and &lt; 24: short far-offset match of length flagbyte+5.</para>
/// </remarks>
internal unsafe struct FastLzTable
{
    /// <summary>Flag/command stream (start and end).</summary>
    public StreamRange<byte> CommandStream;

    /// <summary>Length stream (variable-length encoded extra lengths).</summary>
    public byte* LengthStream;

    /// <summary>Literal stream (start and end).</summary>
    public StreamRange<byte> LiteralStream;

    /// <summary>Near (16-bit) offset stream (start and end).</summary>
    public StreamRange<ushort> Offset16Stream;

    /// <summary>Far (32-bit) offset stream for current chunk (start and end).</summary>
    public StreamRange<uint> Offset32Stream;

    // Offset32BackingStream1 and Offset32BackingStream2 are the per-chunk backing stores that
    // Offset32Stream alternates between: during the first 64KB sub-chunk Offset32Stream points
    // to Offset32BackingStream1, and during the second sub-chunk it points to Offset32BackingStream2.

    /// <summary>Far offset stream backing store for chunk 1.</summary>
    public uint* Offset32BackingStream1;

    /// <summary>Far offset stream backing store for chunk 2.</summary>
    public uint* Offset32BackingStream2;

    /// <summary>Number of far offset entries for chunk 1.</summary>
    public uint Offset32Count1;

    /// <summary>Number of far offset entries for chunk 2.</summary>
    public uint Offset32Count2;

    /// <summary>Command stream offset for next 64KB chunk start.</summary>
    public uint CommandStream2Offset;

    /// <summary>Command stream offset for next 64KB chunk end.</summary>
    public uint CommandStream2OffsetEnd;
}
