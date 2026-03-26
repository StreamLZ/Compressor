// ManagedMatchLenStorage.cs — Managed-array based storage for variable-length encoded match data.

namespace StreamLZ.Compression.MatchFinding;

/// <summary>
/// Managed-array based storage for variable-length encoded match data.
/// Each source offset maps to a variable-length sequence of
/// (length, offset) pairs. See also the <c>MatchLenStorage</c> in High/Compressor.cs
/// which uses raw pointers for unsafe interop.
/// </summary>
internal class ManagedMatchLenStorage
{
    /// <summary>Variable-length encoded match data buffer.</summary>
    public byte[] ByteBuffer = Array.Empty<byte>();

    /// <summary>Current write position in <see cref="ByteBuffer"/>.</summary>
    public int ByteBufferUse;

    /// <summary>Maps source offset to position in <see cref="ByteBuffer"/>.</summary>
    public int[] Offset2Pos = Array.Empty<int>();

    /// <summary>Base offset of the source window within the match finder's byte array.</summary>
    public int WindowBaseOffset;

    /// <summary>
    /// Absolute start-position of the round that populated this MLS.
    /// Used by Optimal to convert absolute startPos to MLS-relative indices.
    /// </summary>
    public int RoundStartPos;

    /// <summary>
    /// Creates a new <see cref="ManagedMatchLenStorage"/> with the given capacity.
    /// </summary>
    /// <param name="entries">Number of source offsets to support.</param>
    /// <param name="avgBytes">Average bytes of match data per offset.</param>
    public static ManagedMatchLenStorage Create(int entries, float avgBytes)
    {
        var mls = new ManagedMatchLenStorage
        {
            ByteBuffer = GC.AllocateUninitializedArray<byte>((int)(entries * avgBytes)),
            Offset2Pos = new int[entries], // must be zero-initialized
            ByteBufferUse = 1, // offset 0 means "no data", so start at 1
            WindowBaseOffset = 0,
        };
        return mls;
    }

    /// <summary>
    /// Resets this MLS for reuse. Grows buffers if needed, clears Offset2Pos.
    /// </summary>
    public void Reset(int entries, float avgBytes)
    {
        int neededBytes = (int)(entries * avgBytes);
        if (ByteBuffer.Length < neededBytes)
        {
            ByteBuffer = GC.AllocateUninitializedArray<byte>(neededBytes);
        }
        if (Offset2Pos.Length < entries)
        {
            Offset2Pos = new int[entries]; // must be zero-initialized
        }
        else
        {
            Array.Clear(Offset2Pos, 0, entries);
        }
        ByteBufferUse = 1;
        WindowBaseOffset = 0;
        RoundStartPos = 0;
    }
}
