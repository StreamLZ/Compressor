using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace StreamLZ.Compression;

/// <summary>
/// A (length, offset) pair describing a single LZ match.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1036", Justification = "IComparable used for heap ordering only")]
internal struct LengthAndOffset : IComparable<LengthAndOffset>
{
    /// <summary>Match length in bytes.</summary>
    public int Length;
    /// <summary>Match offset (backward distance in buffer).</summary>
    public int Offset;

    /// <summary>
    /// Sets the <see cref="Length"/> and <see cref="Offset"/> fields in a single call.
    /// </summary>
    /// <param name="length">The match length in bytes.</param>
    /// <param name="offset">The match offset (distance back in the buffer).</param>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Set(int length, int offset)
    {
        Length = length;
        Offset = offset;
    }

    /// <summary>
    /// Compares by length descending (longest match first), then by offset ascending,
    /// for use with <see cref="Array.Sort{T}(T[])"/> and similar sorting APIs.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int CompareTo(LengthAndOffset other)
    {
        // For IComparable we return negative when "this" should come first.
        if (Length == other.Length)
        {
            return Offset.CompareTo(other.Offset);
        }
        return other.Length.CompareTo(Length); // descending
    }
}

/// <summary>
/// A (hash, position) pair used by hash-based match finders.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct HashPos
{
    /// <summary>Hash value computed from the source bytes.</summary>
    public readonly uint Hash;
    /// <summary>Position in the source buffer.</summary>
    public readonly int Position;
}
