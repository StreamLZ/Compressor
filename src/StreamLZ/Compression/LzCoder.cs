using StreamLZ.Compression.MatchFinding;

namespace StreamLZ.Compression;

/// <summary>
/// Top-level LZ encoder state.
/// </summary>
/// <remarks>
/// Fields are public and mutable by design: <see cref="Fast.Compressor.SetupEncoder"/> and
/// <see cref="High.Compressor.SetupEncoder"/> configure the coder after construction,
/// and <see cref="CloneForThread"/> shallow-copies all fields for parallel worker threads.
/// </remarks>
internal sealed class LzCoder : IDisposable
{
    /// <summary>Codec identifier (e.g. 2 = High, 3 = Fast).</summary>
    public int CodecId;
    /// <summary>Compression level (0-9).</summary>
    public int CompressionLevel;
    /// <summary>Compression options (dictionary size, match length, etc.).</summary>
    public CompressOptions? Options;
    /// <summary>Sub-chunk size for chunked processing.</summary>
    public int SubChunkSize;
    /// <summary>Hash-based match finder instance.</summary>
    public MatchHasherBase? Hasher;
    /// <summary>Simple hash table for Fast compressor (FastMatchHasher&lt;uint&gt;, FastMatchHasher&lt;ushort&gt;, or MatchHasher2).</summary>
    /// <remarks>Typed as <c>object</c> because it holds three distinct types including two generic
    /// instantiations. An interface would add virtual dispatch to the match-finding hot path.</remarks>
    public object? FastHasher;
    /// <summary>Whether the Fast compressor uses entropy coding on literal and token streams (true = higher ratio, slower decompress).</summary>
    public bool UseLiteralEntropyCoding;
    /// <summary>Maximum number of matches to evaluate per position.</summary>
    public int MaxMatchesToConsider;
    /// <summary>Speed vs. compression ratio tradeoff factor.</summary>
    public float SpeedTradeoff;
    /// <summary>Bitmask of <see cref="Compression.EntropyOptions"/> flags controlling which entropy coding modes the encoder may use.</summary>
    /// <remarks>Stored as <c>int</c> rather than the <see cref="Compression.EntropyOptions"/> enum because
    /// callers use bitwise expressions with int literals (e.g. <c>0xff &amp; ~(int)EntropyOptions.X</c>).
    /// Using the enum type would require casts at ~20 call sites.</remarks>
    public int EntropyOptions;
    /// <summary>Encoder flags passed to the encoding pipeline.</summary>
    public int EncodeFlags;
    /// <summary>Whether to try plain Huffman as an alternative encoding.</summary>
    public bool CheckPlainHuffman;
    /// <summary>File-level compressor identifier written to the stream header.</summary>
    public int CompressorFileId;
    /// <summary>Scratch block for symbol statistics reuse across chunks.</summary>
    public LzScratchBlock SymbolStatisticsScratch = new();
    /// <summary>Chunk type selected by the previous chunk (for statistics carry-over).</summary>
    public int LastChunkType;
    /// <summary>Number of compression threads (1 = single-threaded).</summary>
    public int NumThreads = 1;

    /// <summary>
    /// Disposes the <see cref="SymbolStatisticsScratch"/> owned by this coder.
    /// </summary>
    public void Dispose()
    {
        SymbolStatisticsScratch.Dispose();
    }

    /// <summary>
    /// Creates a shallow clone suitable for use on a parallel worker thread.
    /// Shared read-only fields (Options, CodecId, etc.) are copied by reference.
    /// Mutable per-block state (LastChunkType, SymbolStatisticsScratch) is reset.
    /// </summary>
    public LzCoder CloneForThread()
    {
        return new LzCoder
        {
            CodecId = CodecId,
            CompressionLevel = CompressionLevel,
            Options = Options,
            SubChunkSize = SubChunkSize,
            Hasher = Hasher,
            FastHasher = FastHasher,
            MaxMatchesToConsider = MaxMatchesToConsider,
            SpeedTradeoff = SpeedTradeoff,
            EntropyOptions = EntropyOptions,
            EncodeFlags = EncodeFlags,
            CheckPlainHuffman = CheckPlainHuffman,
            CompressorFileId = CompressorFileId,
            UseLiteralEntropyCoding = UseLiteralEntropyCoding,
            LastChunkType = -1,
            NumThreads = 1, // worker threads don't spawn sub-threads
        };
    }
}

/// <summary>
/// Scratch memory block used during LZ encoding. Manages a single allocation.
/// </summary>
internal sealed class LzScratchBlock : IDisposable
{
    /// <summary>Backing byte array, or null if not yet allocated.</summary>
    public byte[]? Buffer;
    /// <summary>Current allocated size of the buffer.</summary>
    public int Size;

    /// <summary>
    /// Returns an uninitialized byte array. Callers must write before reading.
    /// Allocates a new buffer only if the current one is null or too small.
    /// </summary>
    /// <remarks>
    /// The returned array is allocated via <see cref="GC.AllocateArray{T}(int, bool)"/>
    /// with <c>pinned: true</c> so that callers can safely derive and store raw pointers.
    /// The array will not be relocated by the GC.
    /// </remarks>
    /// <param name="wantedSize">Minimum required buffer size in bytes.</param>
    /// <returns>A pinned byte array of at least <paramref name="wantedSize"/> bytes.</returns>
    public byte[] Allocate(int wantedSize)
    {
        if (Buffer == null || Size < wantedSize)
        {
            Buffer = GC.AllocateArray<byte>(wantedSize, pinned: true);
            Size = wantedSize;
        }
        return Buffer;
    }

    /// <summary>
    /// Releases the buffer and resets the size to zero.
    /// </summary>
    public void Dispose()
    {
        Buffer = null;
        Size = 0;
    }
}

/// <summary>
/// Growable, reusable array buffer that avoids LOH allocation churn.
/// Allocates once and reuses across chunks; only reallocates when a larger buffer is needed.
/// </summary>
/// <typeparam name="T">Element type of the buffer.</typeparam>
internal sealed class ReusableBuffer<T> where T : unmanaged
{
    private T[]? _buffer;

    /// <summary>
    /// Returns an array of at least <paramref name="minSize"/> elements,
    /// allocating a new one only when the current buffer is too small.
    /// </summary>
    public T[] Get(int minSize)
    {
        if (_buffer == null || _buffer.Length < minSize)
        {
            _buffer = GC.AllocateUninitializedArray<T>(minSize);
        }
        return _buffer;
    }

    /// <summary>
    /// Returns a zero-initialized array of at least <paramref name="minSize"/> elements.
    /// Clears existing buffer if reused, or allocates a new zeroed one.
    /// </summary>
    public T[] GetCleared(int minSize)
    {
        if (_buffer == null || _buffer.Length < minSize)
        {
            _buffer = new T[minSize];
        }
        else
        {
            Array.Clear(_buffer, 0, minSize);
        }
        return _buffer;
    }

    /// <summary>Releases the buffer reference for GC collection.</summary>
    public void Release() => _buffer = null;
}

/// <summary>
/// Collection of scratch blocks used during LZ encoding.
/// </summary>
internal sealed class LzTemp : IDisposable
{
    /// <summary>Scratch block for High encoder (literal/sub-literal buffers, pinned during Optimal).</summary>
    public LzScratchBlock HighEncoderScratch = new();
    /// <summary>Scratch block for LZ token storage.</summary>
    public LzScratchBlock LzTokenScratch = new();
    /// <summary>Scratch block for secondary LZ token storage.</summary>
    public LzScratchBlock LzToken2Scratch = new();
    /// <summary>Scratch block for all-matches storage.</summary>
    public LzScratchBlock AllMatchScratch = new();
    /// <summary>Scratch block for High encoder states.</summary>
    public LzScratchBlock HighStates = new();
    /// <summary>Scratch block for general encoder states.</summary>
    public LzScratchBlock States = new();

    /// <summary>Reusable match result buffer.</summary>
    public readonly ReusableBuffer<LengthAndOffset> Lao = new();
    /// <summary>Reusable match source byte buffer.</summary>
    public readonly ReusableBuffer<byte> MatchSrc = new();
    /// <summary>Reusable literal index buffer (zero-initialized on each use).</summary>
    public readonly ReusableBuffer<int> LitIndexes = new();
    /// <summary>Returns a reusable match result buffer of at least <paramref name="minSize"/> elements.</summary>
    public LengthAndOffset[] GetLaoBuffer(int minSize) => Lao.Get(minSize);

    /// <summary>Returns a reusable byte buffer of at least <paramref name="minSize"/> bytes.</summary>
    public byte[] GetMatchSrcBuffer(int minSize) => MatchSrc.Get(minSize);

    /// <summary>Returns a zero-initialized int buffer of at least <paramref name="minSize"/> elements.</summary>
    public int[] GetLitIndexesBuffer(int minSize) => LitIndexes.GetCleared(minSize);

    /// <summary>
    /// Disposes all scratch blocks and releases all reusable buffer references.
    /// </summary>
    public void Dispose()
    {
        HighEncoderScratch.Dispose();
        LzTokenScratch.Dispose();
        LzToken2Scratch.Dispose();
        AllMatchScratch.Dispose();
        HighStates.Dispose();
        States.Dispose();
        Lao.Release();
        MatchSrc.Release();
        LitIndexes.Release();
    }
}
