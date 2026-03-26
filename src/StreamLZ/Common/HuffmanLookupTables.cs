using System.Runtime.InteropServices;

namespace StreamLZ.Common;

/// <summary>
/// Reverse-bit lookup table for Huffman decoding.
/// Unlike <see cref="NewHuffLut"/> (which has +16 overflow guard), HuffRevLut uses
/// exactly <see cref="StreamLZConstants.HuffmanLutSize"/> entries because it is
/// populated with bounded symbol/length writes that never exceed the 11-bit table size.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct HuffRevLut
{
    /// <summary>Maps an 11-bit pattern to a code length.</summary>
    public fixed byte Bits2Len[StreamLZConstants.HuffmanLutSize];

    /// <summary>Maps an 11-bit pattern to a symbol.</summary>
    public fixed byte Bits2Sym[StreamLZConstants.HuffmanLutSize];
}

/// <summary>
/// Forward-bit lookup table for Huffman decoding.
/// Arrays are <see cref="StreamLZConstants.HuffmanLutSize"/> + <see cref="StreamLZConstants.HuffmanLutOverflow"/>
/// to allow overflow in vectorized fill operations.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct NewHuffLut
{
    /// <summary>Maps a bit pattern to a code length.</summary>
    public fixed byte Bits2Len[StreamLZConstants.HuffmanLutSize + StreamLZConstants.HuffmanLutOverflow];

    /// <summary>Maps a bit pattern to a symbol.</summary>
    public fixed byte Bits2Sym[StreamLZConstants.HuffmanLutSize + StreamLZConstants.HuffmanLutOverflow];
}
