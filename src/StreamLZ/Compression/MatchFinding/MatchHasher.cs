// MatchHasher.cs — Hash-based match position storage for LZ compression.

using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Compression.MatchFinding;

// ────────────────────────────────────────────────────────────────
//  Shared adaptive-step preload loop
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Callback interface for the adaptive preload loop. Implement this on a struct
/// to get zero-allocation, inlineable dispatch. Using an interface rather than a
/// delegate also avoids the C# restriction on capturing ref structs in lambdas.
/// </summary>
internal interface IPreloadInsert
{
    /// <summary>Insert the hash entry at the given source offset.</summary>
    void Insert(long offset);
}

/// <summary>
/// Contains the shared adaptive-step preload loop used by all match hasher types.
/// The loop runs once per chunk (not per byte), so callback overhead is negligible.
/// </summary>
internal static class MatchHasherPreload
{
    /// <summary>
    /// Executes the adaptive-step preload loop, calling
    /// <paramref name="inserter"/>.<see cref="IPreloadInsert.Insert"/> at each
    /// sampled position. The step size starts large and halves as the loop
    /// approaches <paramref name="srcStartOffset"/>, giving denser coverage near
    /// the current position.
    /// </summary>
    /// <typeparam name="T">Callback struct implementing <see cref="IPreloadInsert"/>.</typeparam>
    /// <param name="srcBaseOffset">Base offset of the source window.</param>
    /// <param name="srcStartOffset">Start offset (loop target).</param>
    /// <param name="maxPreloadLen">Maximum number of bytes to preload.</param>
    /// <param name="inserter">Callback invoked at each sampled offset.</param>
    internal static void AdaptivePreloadLoop<T>(
        long srcBaseOffset, long srcStartOffset, int maxPreloadLen,
        ref T inserter) where T : IPreloadInsert
    {
        long preloadLen = srcStartOffset - srcBaseOffset;
        long curOffset = srcBaseOffset;

        Debug.Assert(preloadLen > 0);

        if (preloadLen > maxPreloadLen)
        {
            preloadLen = maxPreloadLen;
            curOffset = srcStartOffset - preloadLen;
        }

        int step = Math.Max((int)(preloadLen >> 18), 2);
        int roundsUntilNextStep = (int)(preloadLen >> 1) / step;

        for (; ; )
        {
            if (--roundsUntilNextStep <= 0)
            {
                if (curOffset >= srcStartOffset)
                {
                    break;
                }
                step >>= 1;
                Debug.Assert(step >= 1);
                roundsUntilNextStep = (int)(srcStartOffset - curOffset) / step;
                if (step > 1)
                {
                    roundsUntilNextStep >>= 1;
                }
            }

            inserter.Insert(curOffset);
            curOffset += step;
        }
    }
}

// ────────────────────────────────────────────────────────────────
//  HashPos result returned by GetHashPos
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Stores the hash-table entry pointers and position metadata returned
/// by <see cref="MatchHasherBase.GetHashPos(ReadOnlySpan{byte}, long)"/>.
/// </summary>
internal readonly struct HasherHashPos
{
    /// <summary>Index into the hash table for the primary hash.</summary>
    public int Ptr1Index { get; init; }

    /// <summary>Index into the hash table for the secondary (dual) hash. Only used when DualHash is true.</summary>
    public int Ptr2Index { get; init; }

    /// <summary>Source position relative to src_base.</summary>
    public uint Pos { get; init; }

    /// <summary>7-bit collision-rejection tag derived from the hash.</summary>
    public uint Tag { get; init; }
}

// ────────────────────────────────────────────────────────────────
//  Abstract base for MatchHasher<NumHash, DualHash>
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Abstract base for the family of match-position hash tables.
/// </summary>
internal abstract class MatchHasherBase
{
    private const ulong FibonacciHashMultiplier = StreamLZConstants.FibonacciHashMultiplier;

    /// <summary>Hash table entries (cache-line aligned allocation).</summary>
    protected uint[] _hashTable = Array.Empty<uint>();

    /// <summary>Number of bits in the hash (log2 of the table size).</summary>
    protected int _hashBits;

    /// <summary>Mask applied to the hash to find the first entry in a bucket.</summary>
    protected uint _hashMask;

    /// <summary>Hash multiplier derived from the minimum match length parameter.</summary>
    protected ulong _hashMult;

    /// <summary>Number of hash entries per bucket.</summary>
    protected abstract int NumHash { get; }

    /// <summary>Whether the hasher maintains a second independent hash.</summary>
    protected abstract bool DualHash { get; }

    /// <summary>Public accessor for <see cref="NumHash"/> — the number of hash entries per bucket.</summary>
    public int NumHashEntries => NumHash;

    /// <summary>Public accessor for <see cref="DualHash"/> — whether the hasher maintains a second independent hash.</summary>
    public bool IsDualHash => DualHash;

    // Cached state from the most recent SetHashPos call
    /// <summary>Index of the primary hash entry for the current position.</summary>
    public int HashEntryPtrNextIndex;

    /// <summary>Index of the secondary hash entry (dual hash) for the current position.</summary>
    public int HashEntry2PtrNextIndex;

    /// <summary>7-bit collision-rejection tag derived from the hash of the current position's bytes.</summary>
    public uint CurrentHashTag;

    // Source tracking
    private long _srcBaseOffset;
    private long _srcCurOffset;

    // We store offsets relative to a conceptual base.
    // The caller passes raw pointers/spans — we track offsets internally.

    /// <summary>
    /// Allocates the hash table with <c>1 &lt;&lt; bits</c> entries.
    /// </summary>
    /// <param name="bits">Log2 of the hash table size.</param>
    /// <param name="k">Minimum match length hint (clamped to 1..8, default 4).</param>
    public virtual void AllocateHash(int bits, int k)
    {
        _hashBits = bits;
        _hashMask = (uint)((1 << bits) - NumHash);
        k = Math.Max(Math.Min(k > 0 ? k : 4, 8), 1);
        _hashMult = FibonacciHashMultiplier << (8 * (8 - k));
        _hashTable = GC.AllocateUninitializedArray<uint>(1 << bits, pinned: true);
        Array.Clear(_hashTable);
    }

    /// <summary>
    /// Clears the hash table for reuse without reallocating.
    /// Only reallocates if the requested size differs from current.
    /// </summary>
    public void ClearHash(int bits, int k)
    {
        int needed = 1 << bits;
        if (_hashTable == null || _hashTable.Length != needed)
        {
            AllocateHash(bits, k);
            return;
        }
        _hashBits = bits;
        _hashMask = (uint)((1 << bits) - NumHash);
        k = Math.Max(Math.Min(k > 0 ? k : 4, 8), 1);
        _hashMult = FibonacciHashMultiplier << (8 * (8 - k));
        Array.Clear(_hashTable);
    }

    /// <summary>
    /// Sets the base pointer offset without preloading any data.
    /// </summary>
    public void SetBaseWithoutPreload(long srcBaseOffset)
    {
        _srcBaseOffset = srcBaseOffset;
    }

    /// <summary>
    /// Sets the base pointer and preloads hash entries from the window
    /// preceding <paramref name="srcStartOffset"/>.
    /// </summary>
    public void SetBaseAndPreload(ReadOnlySpan<byte> src, long srcBaseOffset, long srcStartOffset, int maxPreloadLen)
    {
        _srcBaseOffset = srcBaseOffset;
        if (srcBaseOffset == srcStartOffset)
        {
            return;
        }

        unsafe
        {
            fixed (byte* srcPtr = src)
            {
                var inserter = new MatchHasherBasePreloadInsert(this, srcPtr);
                MatchHasherPreload.AdaptivePreloadLoop(srcBaseOffset, srcStartOffset, maxPreloadLen, ref inserter);
            }
        }
    }

    /// <summary>Callback struct for <see cref="MatchHasherBase"/> preload.</summary>
    private unsafe struct MatchHasherBasePreloadInsert : IPreloadInsert
    {
        private readonly MatchHasherBase _hasher;
        private readonly byte* _srcPtr;

        public MatchHasherBasePreloadInsert(MatchHasherBase hasher, byte* srcPtr)
        {
            _hasher = hasher;
            _srcPtr = srcPtr;
        }

        public void Insert(long offset)
        {
            _hasher.SetHashPos(_srcPtr + offset);
            var hp = _hasher.GetHashPos(_srcPtr + offset);
            _hasher.Insert(hp);
        }
    }

    /// <summary>
    /// Combines position and high-bit tag into a single hash-table value.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static uint MakeHashValue(uint hashTag, uint curPos)
    {
        return (hashTag & StreamLZConstants.HashTagMask) | (curPos & StreamLZConstants.HashPositionMask);
    }

    /// <summary>
    /// Returns the current hash position info.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public HasherHashPos GetHashPos(ReadOnlySpan<byte> src, long offset)
    {
        return new HasherHashPos
        {
            Ptr1Index = HashEntryPtrNextIndex,
            Ptr2Index = HashEntry2PtrNextIndex,
            Pos = (uint)(offset - _srcBaseOffset),
            Tag = CurrentHashTag,
        };
    }

    /// <summary>
    /// Inserts the given hash entry at both primary (and optionally dual) positions.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Insert(in HasherHashPos hp)
    {
        uint he = MakeHashValue(hp.Tag, hp.Pos);
        InsertAtIndex(hp.Ptr1Index, he);
        if (DualHash)
        {
            InsertAtIndex(hp.Ptr2Index, he);
        }
    }

    /// <summary>
    /// Inserts a hash value at two explicit table indices.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Insert(int idx1, int idx2, uint he)
    {
        InsertAtIndex(idx1, he);
        if (DualHash)
        {
            InsertAtIndex(idx2, he);
        }
    }

    /// <summary>
    /// Inserts a single value into the hash bucket at <paramref name="index"/>
    /// with ring-buffer / shift semantics. The exact behaviour depends on <see cref="NumHash"/>.
    /// </summary>
    protected abstract void InsertAtIndex(int index, uint hval);

    /// <summary>
    /// Computes the hash for the 8 bytes at <paramref name="offset"/> and caches
    /// the entry pointers and high bits.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void SetHashPos(ReadOnlySpan<byte> src, long offset)
    {
        _srcCurOffset = offset;
        Debug.Assert(offset <= int.MaxValue, "offset exceeds int.MaxValue before cast");
        ulong atSrc = Unsafe.ReadUnaligned<ulong>(ref MemoryMarshal.GetReference(src.Slice((int)offset)));
        uint hash1 = BitOperations.RotateLeft((uint)((_hashMult * atSrc) >> 32), _hashBits);
        CurrentHashTag = hash1;
        HashEntryPtrNextIndex = (int)(hash1 & _hashMask);
        if (DualHash)
        {
            uint hash2 = (uint)((FibonacciHashMultiplier * atSrc) >> (64 - _hashBits));
            HashEntry2PtrNextIndex = (int)(hash2 & ~((uint)NumHash - 1));
        }
    }

    /// <summary>
    /// Computes the hash and prefetches the corresponding cache line(s).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void SetHashPosPrefetch(ReadOnlySpan<byte> src, long offset)
    {
        SetHashPos(src, offset);
        if (Sse.IsSupported)
        {
            unsafe
            {
                fixed (uint* p = &_hashTable[HashEntryPtrNextIndex])
                {
                    Sse.Prefetch0(p);
                }
                if (DualHash)
                {
                    fixed (uint* p = &_hashTable[HashEntry2PtrNextIndex])
                    {
                        Sse.Prefetch0(p);
                    }
                }
            }
        }
    }

    // ── Raw-pointer overloads for Fast compressor ──
    //
    // These intentionally duplicate the Span<byte> overloads above.
    // The pointer versions avoid Span overhead on the Fast compressor's
    // inner loop. Keep both sets of overloads in sync when making changes.

    /// <summary>Raw base pointer to the source window, set during SetupEncoder.</summary>
    /// <remarks>Safe because the source buffer is pinned via <c>fixed</c> in
    /// <see cref="StreamLZCompressor"/> for the entire compression lifetime.</remarks>
    public unsafe byte* SrcBase;

    /// <summary>SetHashPos from raw pointer.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe void SetHashPos(byte* p)
    {
        long offset = p - SrcBase;
        _srcCurOffset = offset;
        ulong atSrc = *(ulong*)p;
        uint hash1 = BitOperations.RotateLeft((uint)((_hashMult * atSrc) >> 32), _hashBits);
        CurrentHashTag = hash1;
        HashEntryPtrNextIndex = (int)(hash1 & _hashMask);
        if (DualHash)
        {
            uint hash2 = (uint)((FibonacciHashMultiplier * atSrc) >> (64 - _hashBits));
            HashEntry2PtrNextIndex = (int)(hash2 & ~((uint)NumHash - 1));
        }
    }

    /// <summary>GetHashPos from raw pointer.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe HasherHashPos GetHashPos(byte* p)
    {
        return new HasherHashPos
        {
            Ptr1Index = HashEntryPtrNextIndex,
            Ptr2Index = HashEntry2PtrNextIndex,
            Pos = (uint)(p - SrcBase - _srcBaseOffset),
            Tag = CurrentHashTag,
        };
    }

    /// <summary>SetHashPosPrefetch from raw pointer.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe void SetHashPosPrefetch(byte* p)
    {
        SetHashPos(p);
        if (Sse.IsSupported)
        {
            fixed (uint* pp = &_hashTable[HashEntryPtrNextIndex])
                Sse.Prefetch0(pp);
            if (DualHash)
            {
                fixed (uint* pp = &_hashTable[HashEntry2PtrNextIndex])
                    Sse.Prefetch0(pp);
            }
        }
    }

    /// <summary>InsertRange from raw pointer.</summary>
    public unsafe void InsertRange(byte* matchStart, int len)
    {
        long offset = matchStart - SrcBase;
        if (_srcCurOffset < offset + len)
        {
            uint he = MakeHashValue(CurrentHashTag, (uint)(_srcCurOffset - _srcBaseOffset));
            InsertAtIndex(HashEntryPtrNextIndex, he);
            if (DualHash)
                InsertAtIndex(HashEntry2PtrNextIndex, he);

            for (long i = _srcCurOffset - offset + 1; i < len; i *= 2)
            {
                ulong atSrc = *(ulong*)(matchStart + i);
                uint hash = BitOperations.RotateLeft((uint)((_hashMult * atSrc) >> 32), _hashBits);
                int idx = (int)(hash & _hashMask);
                InsertAtIndex(idx, MakeHashValue(hash, (uint)(offset + i - _srcBaseOffset)));
            }
            SetHashPos(matchStart + len);
        }
        else if (_srcCurOffset != offset + len)
        {
            SetHashPos(matchStart + len);
        }
    }

    /// <summary>
    /// Clears the hash table and resets the base offset.
    /// </summary>
    public void Reset(long offset)
    {
        Array.Clear(_hashTable);
        _srcBaseOffset = offset;
    }

    /// <summary>
    /// Inserts entries covering a match of the given length starting at <paramref name="offset"/>.
    /// Entries are inserted at exponentially spaced positions within the match.
    /// </summary>
    public void InsertRange(ReadOnlySpan<byte> src, long offset, int len)
    {
        if (_srcCurOffset < offset + len)
        {
            uint he = MakeHashValue(CurrentHashTag, (uint)(_srcCurOffset - _srcBaseOffset));
            InsertAtIndex(HashEntryPtrNextIndex, he);
            if (DualHash)
            {
                InsertAtIndex(HashEntry2PtrNextIndex, he);
            }

            for (long i = _srcCurOffset - offset + 1; i < len; i *= 2)
            {
                Debug.Assert(offset + i <= int.MaxValue, "offset + i exceeds int.MaxValue before cast");
                ulong atSrc = Unsafe.ReadUnaligned<ulong>(ref MemoryMarshal.GetReference(src.Slice((int)(offset + i))));
                uint hash = BitOperations.RotateLeft((uint)((_hashMult * atSrc) >> 32), _hashBits);
                int idx = (int)(hash & _hashMask);
                InsertAtIndex(idx, MakeHashValue(hash, (uint)(offset + i - _srcBaseOffset)));
            }

            SetHashPos(src, offset + len);
        }
        else if (_srcCurOffset != offset + len)
        {
            SetHashPos(src, offset + len);
        }
    }

    /// <summary>
    /// Direct read access to the hash table (for match checking).
    /// </summary>
    public uint[] HashTable => _hashTable;

    /// <summary>Current source base offset.</summary>
    public long SrcBaseOffset => _srcBaseOffset;

    /// <summary>Current source cursor offset.</summary>
    public long SrcCurOffset => _srcCurOffset;
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher1 — NumHash=1, DualHash=false
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Single-entry hash table (NumHash=1, no dual hash).
/// </summary>
internal sealed class MatchHasher1 : MatchHasherBase
{
    /// <inheritdoc/>
    protected override int NumHash => 1;

    /// <inheritdoc/>
    protected override bool DualHash => false;

    /// <inheritdoc/>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    protected override void InsertAtIndex(int index, uint hval)
    {
        _hashTable[index] = hval;
    }
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher2x — NumHash=2, DualHash=false
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Two-entry hash table (NumHash=2, no dual hash).
/// </summary>
internal sealed class MatchHasher2x : MatchHasherBase
{
    /// <inheritdoc/>
    protected override int NumHash => 2;

    /// <inheritdoc/>
    protected override bool DualHash => false;

    /// <inheritdoc/>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    protected override void InsertAtIndex(int index, uint hval)
    {
        _hashTable[index + 1] = _hashTable[index];
        _hashTable[index] = hval;
    }
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher4 — NumHash=4, DualHash=false
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Four-entry hash table (NumHash=4, no dual hash).
/// </summary>
internal sealed class MatchHasher4 : MatchHasherBase
{
    /// <inheritdoc/>
    protected override int NumHash => 4;

    /// <inheritdoc/>
    protected override bool DualHash => false;

    /// <inheritdoc/>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    protected override void InsertAtIndex(int index, uint hval)
    {
        uint a = _hashTable[index + 2];
        uint b = _hashTable[index + 1];
        uint c = _hashTable[index];
        _hashTable[index + 3] = a;
        _hashTable[index + 2] = b;
        _hashTable[index + 1] = c;
        _hashTable[index] = hval;
    }
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher4Dual — NumHash=4, DualHash=true
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Four-entry hash table with dual hashing (NumHash=4, DualHash=true).
/// </summary>
internal sealed class MatchHasher4Dual : MatchHasherBase
{
    /// <inheritdoc/>
    protected override int NumHash => 4;

    /// <inheritdoc/>
    protected override bool DualHash => true;

    /// <inheritdoc/>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    protected override void InsertAtIndex(int index, uint hval)
    {
        uint a = _hashTable[index + 2];
        uint b = _hashTable[index + 1];
        uint c = _hashTable[index];
        _hashTable[index + 3] = a;
        _hashTable[index + 2] = b;
        _hashTable[index + 1] = c;
        _hashTable[index] = hval;
    }
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher16Dual — NumHash=16, DualHash=true, SSE2 insert
// ────────────────────────────────────────────────────────────────

/// <summary>
/// 16-entry hash table with dual hashing and SSE2-accelerated insert.
/// </summary>
internal sealed class MatchHasher16Dual : MatchHasherBase
{
    /// <inheritdoc/>
    protected override int NumHash => 16;

    /// <inheritdoc/>
    protected override bool DualHash => true;

    /// <inheritdoc/>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    protected override void InsertAtIndex(int index, uint hval)
    {
        if (Vector128.IsHardwareAccelerated)
        {
            unsafe
            {
                fixed (uint* h = &_hashTable[index])
                {
                    // Bucket rotation via overlapping 128-bit stores:
                    // Load 4 x 128-bit vectors at offsets +0, +3, +7, +11 (16 entries total),
                    // then store them at offsets +1, +4, +8, +12 respectively. Because each
                    // vector covers 4 uint slots and the store offset is +1 from the load,
                    // the overlap between consecutive load/store pairs (e.g., load@+3 covers
                    // [3..6], store@+1 covers [1..4]) cascades the shift across all 15 entries.
                    // Finally h[0] is set to hval, completing the ring-buffer insert.
                    Vector128<uint> a0 = Vector128.Load(h);
                    Vector128<uint> a1 = Vector128.Load(h + 3);
                    Vector128<uint> a2 = Vector128.Load(h + 7);
                    Vector128<uint> a3 = Vector128.Load(h + 11);
                    Vector128.Store(a0, h + 1);
                    Vector128.Store(a1, h + 4);
                    Vector128.Store(a2, h + 8);
                    Vector128.Store(a3, h + 12);
                    h[0] = hval;
                }
            }
        }
        else
        {
            // Scalar fallback: shift entries [0..14] -> [1..15]
            for (int i = 14; i >= 0; i--)
            {
                _hashTable[index + i + 1] = _hashTable[index + i];
            }
            _hashTable[index] = hval;
        }
    }
}

// ────────────────────────────────────────────────────────────────
//  MatchHasher2 — separate class with firsthash/longhash/nexthash
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Hash position returned by <see cref="MatchHasher2.GetHashPos(ReadOnlySpan{byte}, long)"/>.
/// </summary>
internal readonly struct MatchHasher2HashPos
{
    /// <summary>Source position relative to src_base.</summary>
    public uint Pos { get; init; }

    /// <summary>Index into firsthash table.</summary>
    public uint HashA { get; init; }

    /// <summary>Index into longhash table.</summary>
    public uint HashB { get; init; }

    /// <summary>Full hash_b value (before index extraction).</summary>
    public uint HashBTag { get; init; }

    /// <summary>Pointer to the next byte after the hashed position.</summary>
    public long NextOffset { get; init; }
}

/// <summary>
/// Separate chain-based match hasher with three tables: firsthash, longhash, nexthash.
/// </summary>
internal sealed class MatchHasher2
{
    private const ulong FibonacciHashMultiplier = StreamLZConstants.FibonacciHashMultiplier;

    private uint[] _firstHash = Array.Empty<uint>();
    private uint[] _longHash = Array.Empty<uint>();
    private ushort[] _nextHash = Array.Empty<ushort>();

    private long _srcBaseOffset;
    private long _srcCurOffset;

    private uint _firstHashMask;
    private uint _longHashMask;
    private uint _nextHashMask;
    private byte _firstHashBits;
    private byte _longHashBits;

    /// <summary>Direct access to the firsthash table.</summary>
    public uint[] FirstHash => _firstHash;

    /// <summary>Direct access to the longhash table.</summary>
    public uint[] LongHash => _longHash;

    /// <summary>Direct access to the nexthash table.</summary>
    public ushort[] NextHash => _nextHash;

    /// <summary>Current source base offset.</summary>
    public long SrcBaseOffset => _srcBaseOffset;

    /// <summary>Current source cursor offset.</summary>
    public long SrcCurOffset => _srcCurOffset;

    /// <summary>
    /// Allocates all three hash tables.
    /// </summary>
    /// <param name="bits">Requested hash bits (clamped to 19 max for firsthash/longhash).</param>
    /// <param name="minMatchLen">Minimum match length (unused, kept for API parity).</param>
    public void AllocateHash(int bits, int minMatchLen)
    {
        int aBits = Math.Min(bits, 19);
        int bBits = Math.Min(bits, 19);
        int cBits = 16;

        _firstHashBits = (byte)aBits;
        _longHashBits = (byte)bBits;

        _firstHashMask = (uint)((1 << aBits) - 1);
        _longHashMask = (uint)((1 << bBits) - 1);
        _nextHashMask = (uint)((1 << cBits) - 1);

        _firstHash = GC.AllocateUninitializedArray<uint>(1 << aBits);
        _longHash = GC.AllocateUninitializedArray<uint>(1 << bBits);
        _nextHash = GC.AllocateUninitializedArray<ushort>(1 << cBits);
        Array.Clear(_firstHash);
        Array.Clear(_longHash);
        Array.Clear(_nextHash);
    }

    /// <summary>
    /// Gets the hash position info for the 8 bytes at <paramref name="offset"/>.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public MatchHasher2HashPos GetHashPos(ReadOnlySpan<byte> src, long offset)
    {
        Debug.Assert(offset <= int.MaxValue, "offset exceeds int.MaxValue before cast");
        ulong atSrc = Unsafe.ReadUnaligned<ulong>(ref MemoryMarshal.GetReference(src.Slice((int)offset)));
        uint hashA = (uint)((0xB7A5646300000000UL * atSrc) >> 32);
        uint hashB = (uint)((FibonacciHashMultiplier * atSrc) >> 32);
        return new MatchHasher2HashPos
        {
            Pos = (uint)(offset - _srcBaseOffset),
            HashA = hashA >> (32 - _firstHashBits),
            HashB = hashB >> (32 - _longHashBits),
            HashBTag = hashB,
            NextOffset = offset + 1,
        };
    }

    /// <summary>
    /// Sets the base offset without preloading.
    /// </summary>
    public void SetBaseWithoutPreload(long srcBaseOffset)
    {
        _srcBaseOffset = srcBaseOffset;
    }

    /// <summary>
    /// Sets the base offset and preloads the hash tables from the preceding window.
    /// </summary>
    public void SetBaseAndPreload(ReadOnlySpan<byte> src, long srcBaseOffset, long srcStartOffset, int maxPreloadLen)
    {
        _srcBaseOffset = srcBaseOffset;
        if (srcBaseOffset == srcStartOffset)
        {
            return;
        }

        unsafe
        {
            fixed (byte* srcPtr = src)
            {
                var inserter = new MatchHasher2PreloadInsert(this, srcPtr);
                MatchHasherPreload.AdaptivePreloadLoop(srcBaseOffset, srcStartOffset, maxPreloadLen, ref inserter);
            }
        }
    }

    /// <summary>Callback struct for <see cref="MatchHasher2"/> preload.</summary>
    private unsafe struct MatchHasher2PreloadInsert : IPreloadInsert
    {
        private readonly MatchHasher2 _hasher;
        private readonly byte* _srcPtr;

        public MatchHasher2PreloadInsert(MatchHasher2 hasher, byte* srcPtr)
        {
            _hasher = hasher;
            _srcPtr = srcPtr;
        }

        public void Insert(long offset)
        {
            var hp = _hasher.GetHashPos(_srcPtr + offset);
            _hasher._firstHash[hp.HashA] = hp.Pos;
            _hasher._longHash[hp.HashB] = (hp.HashBTag & 0x3F) | (hp.Pos << 6);
        }
    }

    /// <summary>
    /// Combines high hash bits and position into a single stored value.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static uint MakeHashValue(uint hashTag, uint curPos)
    {
        return (hashTag & StreamLZConstants.HashTagMask) | (curPos & StreamLZConstants.HashPositionMask);
    }

    /// <summary>
    /// Inserts the hash position into the firsthash chain.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Insert(in MatchHasher2HashPos hp)
    {
        _nextHash[hp.Pos & _nextHashMask] = (ushort)_firstHash[hp.HashA];
        _firstHash[hp.HashA] = hp.Pos;
        _srcCurOffset = hp.NextOffset;
    }

    /// <summary>
    /// Updates the current position (no actual hashing).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void SetHashPos(ReadOnlySpan<byte> src, long offset)
    {
        _srcCurOffset = offset;
    }

    /// <summary>
    /// Prefetches the firsthash and longhash entries for the given position.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void SetHashPosPrefetch(ReadOnlySpan<byte> src, long offset)
    {
        var hp = GetHashPos(src, offset);
        if (Sse.IsSupported)
        {
            unsafe
            {
                fixed (uint* pf = &_firstHash[hp.HashA])
                {
                    Sse.Prefetch0(pf);
                }
                fixed (uint* pl = &_longHash[hp.HashB])
                {
                    Sse.Prefetch0(pl);
                }
            }
        }
    }

    /// <summary>
    /// Inserts entries covering a match of the given length starting at <paramref name="offset"/>.
    /// </summary>
    public void InsertRange(ReadOnlySpan<byte> src, long offset, int len)
    {
        // Insert longhash at exponentially spaced positions
        for (int i = 0; i < len; i = 2 * i + 1)
        {
            Debug.Assert(offset + i <= int.MaxValue, "offset + i exceeds int.MaxValue before cast");
            ulong atSrc = Unsafe.ReadUnaligned<ulong>(ref MemoryMarshal.GetReference(src.Slice((int)(offset + i))));
            uint hashB = (uint)((FibonacciHashMultiplier * atSrc) >> 32);
            _longHash[hashB >> (32 - _longHashBits)] = (hashB & 0x3F) | ((uint)(offset + i - _srcBaseOffset) << 6);
        }

        // Insert all positions into the firsthash chain
        long pEnd = offset + len;
        while (_srcCurOffset < pEnd)
        {
            Debug.Assert(_srcCurOffset <= int.MaxValue, "_srcCurOffset exceeds int.MaxValue before cast");
            ulong atSrc = Unsafe.ReadUnaligned<ulong>(ref MemoryMarshal.GetReference(src.Slice((int)_srcCurOffset)));
            uint hashA = (uint)((0xB7A5646300000000UL * atSrc) >> 32) >> (32 - _firstHashBits);
            uint pos = (uint)(_srcCurOffset - _srcBaseOffset);

            _nextHash[pos & _nextHashMask] = (ushort)_firstHash[hashA];
            _firstHash[hashA] = pos;
            _srcCurOffset++;
        }
    }

    // ── Raw-pointer overloads for Fast compressor ──
    //
    // These intentionally duplicate the Span<byte> overloads above.
    // The pointer versions avoid Span overhead on the Fast compressor's
    // inner loop. Keep both sets of overloads in sync when making changes.

    /// <summary>Raw base pointer to the source window, set during SetupEncoder.</summary>
    /// <remarks>Safe because the source buffer is pinned via <c>fixed</c> in
    /// <see cref="StreamLZCompressor"/> for the entire compression lifetime.</remarks>
    public unsafe byte* SrcBase;

    /// <summary>GetHashPos from raw pointer.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe MatchHasher2HashPos GetHashPos(byte* p)
    {
        long offset = p - SrcBase;
        ulong atSrc = *(ulong*)p;
        uint hashA = (uint)((0xB7A5646300000000UL * atSrc) >> 32);
        uint hashB = (uint)((FibonacciHashMultiplier * atSrc) >> 32);
        return new MatchHasher2HashPos
        {
            Pos = (uint)(offset - _srcBaseOffset),
            HashA = hashA >> (32 - _firstHashBits),
            HashB = hashB >> (32 - _longHashBits),
            HashBTag = hashB,
            NextOffset = offset + 1,
        };
    }

    /// <summary>SetHashPosPrefetch from raw pointer.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe void SetHashPosPrefetch(byte* p)
    {
        var hp = GetHashPos(p);
        if (Sse.IsSupported)
        {
            fixed (uint* pf = &_firstHash[hp.HashA])
                Sse.Prefetch0(pf);
            fixed (uint* pl = &_longHash[hp.HashB])
                Sse.Prefetch0(pl);
        }
    }

    /// <summary>SetHashPos from raw pointer (just update cursor).</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe void SetHashPos(byte* p)
    {
        _srcCurOffset = p - SrcBase;
    }

    /// <summary>InsertRange from raw pointer.</summary>
    public unsafe void InsertRange(byte* matchStart, int len)
    {
        long offset = matchStart - SrcBase;
        for (int i = 0; i < len; i = 2 * i + 1)
        {
            ulong atSrc = *(ulong*)(matchStart + i);
            uint hashB = (uint)((FibonacciHashMultiplier * atSrc) >> 32);
            _longHash[hashB >> (32 - _longHashBits)] = (hashB & 0x3F) | ((uint)(offset + i - _srcBaseOffset) << 6);
        }

        long pEnd = offset + len;
        while (_srcCurOffset < pEnd)
        {
            ulong atSrc = *(ulong*)(SrcBase + _srcCurOffset);
            uint hashA = (uint)((0xB7A5646300000000UL * atSrc) >> 32) >> (32 - _firstHashBits);
            uint pos = (uint)(_srcCurOffset - _srcBaseOffset);
            _nextHash[pos & _nextHashMask] = (ushort)_firstHash[hashA];
            _firstHash[hashA] = pos;
            _srcCurOffset++;
        }
    }
}

// ────────────────────────────────────────────────────────────────
//  FastMatchHasher<T> — simple single-entry hash for fast modes
// ────────────────────────────────────────────────────────────────

/// <summary>
/// Simple single-entry hash table for fast compression modes.
/// <typeparamref name="T"/> is the element type of the hash table
/// (typically <see cref="uint"/> or <see cref="ushort"/>).
/// The JIT specializes for each value type, so this is zero-cost.
/// </summary>
internal sealed class FastMatchHasher<T> where T : unmanaged, INumberBase<T>
{
    private const ulong FibonacciHashMultiplier = StreamLZConstants.FibonacciHashMultiplier;

    private T[] _hashTable = Array.Empty<T>();
    private long _srcBaseOffset;
    private ulong _hashMult;
    private int _hashBits;

    /// <summary>Direct access to the hash table.</summary>
    public T[] HashTable => _hashTable;

    /// <summary>Current source base offset.</summary>
    public long SrcBaseOffset => _srcBaseOffset;

    /// <summary>Hash multiplier.</summary>
    public ulong HashMult => _hashMult;

    /// <summary>Number of hash bits.</summary>
    public int HashBits => _hashBits;

    /// <summary>
    /// Allocates the hash table.
    /// </summary>
    /// <param name="bits">Log2 of the table size.</param>
    /// <param name="k">Minimum match length hint.</param>
    public void AllocateHash(int bits, int k)
    {
        _hashBits = bits;
        if (k == 0)
        {
            k = 4;
        }

        if (k >= 5 && k <= 8)
        {
            _hashMult = FibonacciHashMultiplier << (8 * (8 - k));
        }
        else
        {
            _hashMult = 0x9E3779B100000000UL;
        }

        _hashTable = GC.AllocateUninitializedArray<T>(1 << bits);
        Array.Clear(_hashTable);
    }

    /// <summary>
    /// Sets the base offset without preloading.
    /// </summary>
    public void SetBaseWithoutPreload(long srcBaseOffset)
    {
        _srcBaseOffset = srcBaseOffset;
    }

    /// <summary>
    /// Sets the base and preloads entries from the preceding window.
    /// </summary>
    public void SetBaseAndPreload(ReadOnlySpan<byte> src, long srcBaseOffset, long srcStartOffset, int maxPreloadLen)
    {
        _srcBaseOffset = srcBaseOffset;
        if (srcBaseOffset == srcStartOffset)
        {
            return;
        }

        unsafe
        {
            fixed (byte* srcPtr = src)
            {
                var inserter = new FastMatchHasherPreloadInsert(_hashTable, srcPtr, _hashMult, 64 - _hashBits, _srcBaseOffset);
                MatchHasherPreload.AdaptivePreloadLoop(srcBaseOffset, srcStartOffset, maxPreloadLen, ref inserter);
            }
        }
    }

    /// <summary>Callback struct for <see cref="FastMatchHasher{T}"/> preload.</summary>
    private unsafe struct FastMatchHasherPreloadInsert : IPreloadInsert
    {
        private readonly T[] _hashTable;
        private readonly byte* _srcPtr;
        private readonly ulong _hashMult;
        private readonly int _hashShift;
        private readonly long _srcBaseOffset;

        public FastMatchHasherPreloadInsert(T[] hashTable, byte* srcPtr, ulong hashMult, int hashShift, long srcBaseOffset)
        {
            _hashTable = hashTable;
            _srcPtr = srcPtr;
            _hashMult = hashMult;
            _hashShift = hashShift;
            _srcBaseOffset = srcBaseOffset;
        }

        public void Insert(long offset)
        {
            Debug.Assert(offset <= int.MaxValue, "offset exceeds int.MaxValue before cast");
            ulong atSrc = *(ulong*)(_srcPtr + offset);
            _hashTable[(int)(atSrc * _hashMult >> _hashShift)] = T.CreateTruncating(offset - _srcBaseOffset);
        }
    }
}
