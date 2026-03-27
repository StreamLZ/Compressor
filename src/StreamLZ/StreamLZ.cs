// StreamLZ.cs — Public facade API for the StreamLZ compression library.

using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;

namespace StreamLZ;

/// <summary>
/// High-performance LZ compression library with streaming support.
/// </summary>
/// <remarks>
/// <para>Compression levels 1-11 provide a single scale from fastest to best ratio:</para>
/// <list type="table">
/// <listheader><term>Level</term><description>Description</description></listheader>
/// <item><term>1-5</term><description>Fast decompression (4-5 GB/s), greedy/lazy parsing</description></item>
/// <item><term>6-8</term><description>Balanced (3.8 GB/s decompress, ~34% ratio on enwik8)</description></item>
/// <item><term>9-11</term><description>Maximum ratio (~27% on enwik8, 1.4 GB/s decompress)</description></item>
/// </list>
/// <para>Default level is 6 (balanced speed and ratio). Values outside 1-11 are
/// clamped: values &lt;= 1 map to level 1, values &gt;= 11 map to level 11.</para>
/// <para>
/// For the simplest round-trip experience, use <see cref="CompressFramed(ReadOnlySpan{byte}, int)"/> and
/// <see cref="DecompressFramed"/>. These use the SLZ1 frame format and are self-describing
/// — no external metadata is needed to decompress.
/// </para>
/// <para>
/// For zero-copy in-memory compression of data under 2 GB, use
/// <see cref="Compress(ReadOnlySpan{byte}, Span{byte}, int)"/> and
/// <see cref="Decompress(ReadOnlySpan{byte}, Span{byte}, int)"/>. These use raw blocks
/// and require the caller to track the original size.
/// </para>
/// <para>
/// For files of any size or stream-based I/O, use <see cref="CompressStream"/>,
/// <see cref="DecompressStream"/>, <see cref="CompressFile"/>, or <see cref="DecompressFile"/>.
/// These use the SLZ1 frame format with a sliding window for cross-block match references.
/// </para>
/// <para><b>Thread safety:</b> All static methods on this class are thread-safe.
/// <see cref="SlzStream"/> instances are not thread-safe (same as <see cref="System.IO.Compression.GZipStream"/>).</para>
/// </remarks>
public static class Slz
{
    /// <summary>
    /// Static constructor pre-JITs the decompression hot paths so the first
    /// real call runs at full speed. Triggers automatically on first use of
    /// any <see cref="Slz"/> member.
    /// </summary>
    static Slz()
    {
        WarmUp();
    }

    // ────────────────────────────────────────────────────────────────
    //  Level mapping
    // ────────────────────────────────────────────────────────────────

    /// <summary>Minimum compression level.</summary>
    public const int MinLevel = 1;

    /// <summary>Maximum compression level.</summary>
    public const int MaxLevel = 11;

    /// <summary>Default compression level (balanced speed and ratio).</summary>
    public const int DefaultLevel = 6;

    internal readonly record struct InternalLevel(CodecType Codec, int CodecLevel, bool SelfContained);

    /// <summary>
    /// Maps unified level (1-11) to internal codec + level + self-contained flag.
    /// </summary>
    /// <remarks>
    /// <list type="table">
    /// <listheader><term>Level</term><description>Source</description></listheader>
    /// <item><term>1</term><description>Fast 1 — greedy, ushort hash</description></item>
    /// <item><term>2</term><description>Fast 2 — greedy, uint hash</description></item>
    /// <item><term>3</term><description>Fast 3 — greedy, litsub</description></item>
    /// <item><term>4</term><description>Fast 5 — greedy, rehash (skips Fast 4 which has worse ratio)</description></item>
    /// <item><term>5</term><description>Fast 6 — lazy, chain hasher</description></item>
    /// <item><term>6</term><description>High 5 self-contained — balanced ratio + fast decompress</description></item>
    /// <item><term>7</term><description>High 7 self-contained</description></item>
    /// <item><term>8</term><description>High 9 self-contained</description></item>
    /// <item><term>9</term><description>High 5 — optimal parser, maximum ratio</description></item>
    /// <item><term>10</term><description>High 7</description></item>
    /// <item><term>11</term><description>High 9 — maximum ratio</description></item>
    /// </list>
    /// Levels outside 1-11 are clamped: values &lt;= 1 map to level 1, values &gt;= 11 map to level 11.
    /// </remarks>
    internal static InternalLevel MapLevel(int level)
    {
        return level switch
        {
            <= 1 => new(CodecType.Fast, 1, false),
            2    => new(CodecType.Fast, 2, false),
            3    => new(CodecType.Fast, 3, false),
            4    => new(CodecType.Fast, 5, false),
            5    => new(CodecType.Fast, 6, false),
            6    => new(CodecType.High, 5, true),
            7    => new(CodecType.High, 7, true),
            8    => new(CodecType.High, 9, true),
            9    => new(CodecType.High, 5, false),
            10   => new(CodecType.High, 7, false),
            _    => new(CodecType.High, 9, false), // 11+
        };
    }

    // ────────────────────────────────────────────────────────────────
    //  In-memory compression (data under 2 GB)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Compresses <paramref name="source"/> into <paramref name="destination"/>.
    /// </summary>
    /// <param name="source">The data to compress.</param>
    /// <param name="destination">Buffer for compressed output. Must be at least <see cref="GetCompressBound"/> bytes.</param>
    /// <param name="level">Compression level 1-11 (default: 6). Higher = better ratio, slower.</param>
    /// <returns>Number of compressed bytes written.</returns>
    /// <exception cref="ArgumentException">Thrown when <paramref name="destination"/> is too small.</exception>
    public static int Compress(ReadOnlySpan<byte> source, Span<byte> destination, int level = DefaultLevel)
    {
        if (source.Length > 0 && destination.Length < GetCompressBound(source.Length))
            throw new ArgumentException($"Destination buffer too small. Need at least {GetCompressBound(source.Length)} bytes, got {destination.Length}.", nameof(destination));

        var mapped = MapLevel(level);
        return StreamLZCompressor.Compress(source, destination, mapped.Codec, mapped.CodecLevel,
            selfContained: mapped.SelfContained);
    }

    /// <summary>
    /// Compresses <paramref name="source"/> into <paramref name="destination"/>.
    /// </summary>
    public static int Compress(ReadOnlySpan<byte> source, Span<byte> destination, SlzCompressionLevel level)
        => Compress(source, destination, (int)level);

    /// <summary>
    /// Compresses <paramref name="source"/> and returns the compressed bytes.
    /// </summary>
    /// <param name="source">The data to compress.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <returns>Compressed byte array.</returns>
    public static byte[] Compress(ReadOnlySpan<byte> source, int level = DefaultLevel)
    {
        if (source.Length == 0)
            return [];

        int bound = GetCompressBound(source.Length);
        byte[] rented = System.Buffers.ArrayPool<byte>.Shared.Rent(bound);
        try
        {
            int size = Compress(source, rented, level);
            return rented.AsSpan(0, size).ToArray();
        }
        finally
        {
            System.Buffers.ArrayPool<byte>.Shared.Return(rented);
        }
    }

    /// <summary>
    /// Compresses <paramref name="source"/> and returns the compressed bytes.
    /// </summary>
    public static byte[] Compress(ReadOnlySpan<byte> source, SlzCompressionLevel level)
        => Compress(source, (int)level);

    // ────────────────────────────────────────────────────────────────
    //  Framed in-memory compression (self-describing round-trip)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Compresses <paramref name="source"/> using the SLZ1 frame format and returns the
    /// compressed bytes. The output is self-describing: <see cref="DecompressFramed"/>
    /// can decompress it without knowing the original size.
    /// </summary>
    /// <param name="source">The data to compress.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <returns>Compressed byte array in SLZ1 frame format.</returns>
    public static byte[] CompressFramed(ReadOnlySpan<byte> source, int level = DefaultLevel)
    {
        if (source.Length == 0)
            return [];

        var mapped = MapLevel(level);
        using var input = new MemoryStream(source.ToArray(), writable: false);
        int estimatedSize = source.Length + FrameConstants.MaxHeaderSize + 64;
        using var output = new MemoryStream(estimatedSize);
        StreamLzFrameCompressor.Compress(input, output, mapped.Codec, mapped.CodecLevel,
            contentSize: source.Length, selfContained: mapped.SelfContained);
        return output.ToArray();
    }

    /// <summary>
    /// Compresses <paramref name="source"/> using the SLZ1 frame format.
    /// </summary>
    public static byte[] CompressFramed(ReadOnlySpan<byte> source, SlzCompressionLevel level)
        => CompressFramed(source, (int)level);

    /// <summary>
    /// Decompresses SLZ1-framed data produced by <see cref="CompressFramed(ReadOnlySpan{byte}, int)"/>.
    /// No external metadata (original size) is needed — the frame header contains it.
    /// </summary>
    /// <param name="compressed">SLZ1-framed compressed data.</param>
    /// <returns>Decompressed byte array.</returns>
    /// <exception cref="InvalidDataException">Thrown when the data is not a valid SLZ1 frame
    /// or is corrupt.</exception>
    public static byte[] DecompressFramed(ReadOnlySpan<byte> compressed)
    {
        if (compressed.Length == 0)
            return [];

        // Parse the frame header to get the content size for a single allocation
        if (FrameSerializer.TryReadHeader(compressed, out FrameHeader header) && header.ContentSize >= 0)
        {
            byte[] result = new byte[header.ContentSize];
            using var input = new MemoryStream(compressed.ToArray(), writable: false);
            using var output = new MemoryStream(result, writable: true);
            long written = StreamLzFrameDecompressor.Decompress(input, output);
            if (written != header.ContentSize)
                throw new InvalidDataException($"SLZ1 frame content size mismatch: header says {header.ContentSize} bytes, decompressed {written}.");
            return result;
        }

        // Content size not in header — decompress with growing buffer
        using var inputStream = new MemoryStream(compressed.ToArray(), writable: false);
        using var outputStream = new MemoryStream();
        StreamLzFrameDecompressor.Decompress(inputStream, outputStream);
        return outputStream.ToArray();
    }

    // ────────────────────────────────────────────────────────────────
    //  Raw in-memory decompression (caller-managed buffers)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Decompresses <paramref name="source"/> into <paramref name="destination"/>.
    /// </summary>
    /// <param name="source">The compressed data.</param>
    /// <param name="destination">Buffer for decompressed output (must be at least <paramref name="decompressedSize"/> + <see cref="SafeSpace"/> bytes).</param>
    /// <param name="decompressedSize">Expected decompressed size in bytes.</param>
    /// <returns>Number of decompressed bytes written.</returns>
    /// <exception cref="ArgumentOutOfRangeException">Thrown when <paramref name="decompressedSize"/> is negative.</exception>
    /// <exception cref="ArgumentException">Thrown when <paramref name="destination"/> is too small.</exception>
    /// <exception cref="InvalidDataException">Thrown when the compressed data is corrupt or truncated.</exception>
    public static int Decompress(ReadOnlySpan<byte> source, Span<byte> destination, int decompressedSize)
    {
        if (decompressedSize < 0 || decompressedSize > int.MaxValue - SafeSpace)
            throw new ArgumentOutOfRangeException(nameof(decompressedSize), "Decompressed size cannot be negative or exceed int.MaxValue - SafeSpace.");
        if (destination.Length < decompressedSize + SafeSpace)
            throw new ArgumentException($"Destination buffer too small. Need at least {decompressedSize + SafeSpace} bytes (decompressedSize + SafeSpace), got {destination.Length}.", nameof(destination));

        int result = StreamLZDecoder.Decompress(source, destination, decompressedSize);
        if (result < 0)
            throw new InvalidDataException("StreamLZ decompression failed: compressed data is corrupt or truncated.");
        return result;
    }

    /// <summary>
    /// Attempts to decompress <paramref name="source"/> into <paramref name="destination"/>
    /// without throwing on invalid data.
    /// </summary>
    /// <param name="source">The compressed data.</param>
    /// <param name="destination">Buffer for decompressed output (must be at least
    /// <paramref name="decompressedSize"/> + <see cref="SafeSpace"/> bytes).</param>
    /// <param name="decompressedSize">Expected decompressed size in bytes.</param>
    /// <param name="bytesWritten">On success, the number of decompressed bytes written.</param>
    /// <returns><c>true</c> if decompression succeeded; <c>false</c> if the data is corrupt or invalid.</returns>
    public static bool TryDecompress(ReadOnlySpan<byte> source, Span<byte> destination,
        int decompressedSize, out int bytesWritten)
    {
        bytesWritten = 0;
        if (decompressedSize < 0 || decompressedSize > int.MaxValue - SafeSpace)
            return false;
        if (destination.Length < decompressedSize + SafeSpace)
            return false;

        try
        {
            int result = StreamLZDecoder.Decompress(source, destination, decompressedSize);
            if (result < 0)
                return false;
            bytesWritten = result;
            return true;
        }
        catch (InvalidDataException)
        {
            return false;
        }
    }

    /// <summary>
    /// Returns the maximum compressed size for a given input length.
    /// Use this to allocate the destination buffer for <see cref="Compress(ReadOnlySpan{byte}, Span{byte}, int)"/>.
    /// </summary>
    public static int GetCompressBound(int sourceLength)
    {
        return StreamLZCompressor.GetCompressBound(sourceLength);
    }

    /// <summary>
    /// Extra bytes needed at the end of the decompression output buffer.
    /// </summary>
    public const int SafeSpace = StreamLZDecoder.SafeSpace;

    // ────────────────────────────────────────────────────────────────
    //  Stream-based compression (any size, SLZ1 frame format)
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Compresses data from <paramref name="input"/> to <paramref name="output"/>
    /// using the SLZ1 frame format. Supports files of any size.
    /// </summary>
    /// <param name="input">Source stream.</param>
    /// <param name="output">Destination stream.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <param name="contentSize">Known content size for the header, or -1 if unknown.</param>
    /// <param name="useContentChecksum">When true, appends an XXH32 checksum of the uncompressed content
    /// after the end mark. The decompressor will verify this on read.</param>
    /// <returns>Total compressed bytes written.</returns>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="input"/> or <paramref name="output"/> is null.</exception>
    public static long CompressStream(Stream input, Stream output, int level = DefaultLevel,
        long contentSize = -1, bool useContentChecksum = false)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        var mapped = MapLevel(level);
        return StreamLzFrameCompressor.Compress(input, output, mapped.Codec, mapped.CodecLevel, contentSize,
            useContentChecksum: useContentChecksum, selfContained: mapped.SelfContained);
    }

    /// <summary>
    /// Decompresses SLZ1-framed data from <paramref name="input"/> to <paramref name="output"/>.
    /// </summary>
    /// <param name="input">Source stream containing SLZ1-framed compressed data.</param>
    /// <param name="output">Destination stream for decompressed output.</param>
    /// <returns>Total decompressed bytes written.</returns>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="input"/> or <paramref name="output"/> is null.</exception>
    /// <exception cref="InvalidDataException">Thrown when the frame header is invalid or data is corrupt.</exception>
    public static long DecompressStream(Stream input, Stream output)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        return StreamLzFrameDecompressor.Decompress(input, output);
    }

    // ────────────────────────────────────────────────────────────────
    //  Async stream-based compression
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Asynchronously compresses data from <paramref name="input"/> to <paramref name="output"/>
    /// using the SLZ1 frame format. Supports cancellation and non-blocking I/O.
    /// </summary>
    /// <param name="input">Source stream.</param>
    /// <param name="output">Destination stream.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <param name="contentSize">Known content size for the header, or -1 if unknown.</param>
    /// <param name="useContentChecksum">When true, appends an XXH32 checksum of the uncompressed content
    /// after the end mark. The decompressor will verify this on read.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total compressed bytes written.</returns>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="input"/> or <paramref name="output"/> is null.</exception>
    /// <exception cref="OperationCanceledException">Thrown when cancellation is requested.</exception>
    public static async Task<long> CompressStreamAsync(Stream input, Stream output,
        int level = DefaultLevel, long contentSize = -1,
        bool useContentChecksum = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        var mapped = MapLevel(level);
        return await StreamLzFrameCompressor.CompressAsync(input, output, mapped.Codec, mapped.CodecLevel,
            contentSize, useContentChecksum: useContentChecksum,
            selfContained: mapped.SelfContained,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Asynchronously decompresses SLZ1-framed data from <paramref name="input"/> to <paramref name="output"/>.
    /// </summary>
    /// <param name="input">Source stream containing SLZ1-framed compressed data.</param>
    /// <param name="output">Destination stream for decompressed output.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total decompressed bytes written.</returns>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="input"/> or <paramref name="output"/> is null.</exception>
    /// <exception cref="OperationCanceledException">Thrown when cancellation is requested.</exception>
    /// <exception cref="InvalidDataException">Thrown when the frame header is invalid or data is corrupt.</exception>
    public static async Task<long> DecompressStreamAsync(Stream input, Stream output,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        return await StreamLzFrameDecompressor.DecompressAsync(input, output,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    // ────────────────────────────────────────────────────────────────
    //  File convenience methods
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Compresses a file using the SLZ1 frame format.
    /// </summary>
    /// <param name="inputPath">Path to the input file.</param>
    /// <param name="outputPath">Path to the compressed output file.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <param name="useContentChecksum">When true, appends an XXH32 checksum of the
    /// uncompressed content after the end mark for integrity verification.</param>
    /// <returns>Total compressed bytes written.</returns>
    public static long CompressFile(string inputPath, string outputPath,
        int level = DefaultLevel, bool useContentChecksum = false)
    {
        ArgumentNullException.ThrowIfNull(inputPath);
        ArgumentNullException.ThrowIfNull(outputPath);
        var mapped = MapLevel(level);
        const int ioBufSize = 1024 * 1024;
        using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, ioBufSize, FileOptions.SequentialScan);
        using var output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, ioBufSize, FileOptions.SequentialScan);
        return StreamLzFrameCompressor.Compress(input, output, mapped.Codec, mapped.CodecLevel,
            contentSize: input.Length, useContentChecksum: useContentChecksum,
            selfContained: mapped.SelfContained);
    }

    /// <summary>
    /// Decompresses an SLZ1-framed file.
    /// </summary>
    /// <param name="inputPath">Path to the compressed input file.</param>
    /// <param name="outputPath">Path to the decompressed output file.</param>
    /// <returns>Total decompressed bytes written.</returns>
    public static long DecompressFile(string inputPath, string outputPath)
    {
        ArgumentNullException.ThrowIfNull(inputPath);
        ArgumentNullException.ThrowIfNull(outputPath);
        return StreamLzFrameDecompressor.DecompressFile(inputPath, outputPath);
    }

    // ────────────────────────────────────────────────────────────────
    //  Async file convenience methods
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Asynchronously compresses a file using the SLZ1 frame format.
    /// </summary>
    /// <param name="inputPath">Path to the input file.</param>
    /// <param name="outputPath">Path to the compressed output file.</param>
    /// <param name="level">Compression level 1-11 (default: 6).</param>
    /// <param name="useContentChecksum">When true, appends an XXH32 content checksum.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total compressed bytes written.</returns>
    public static async Task<long> CompressFileAsync(string inputPath, string outputPath,
        int level = DefaultLevel, bool useContentChecksum = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(inputPath);
        ArgumentNullException.ThrowIfNull(outputPath);
        var mapped = MapLevel(level);
        const int ioBufSize = 1024 * 1024;
#pragma warning disable CA2007 // await using on FileStream — disposal is synchronous
        await using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, ioBufSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, ioBufSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
#pragma warning restore CA2007
        return await StreamLzFrameCompressor.CompressAsync(input, output, mapped.Codec, mapped.CodecLevel,
            contentSize: input.Length, useContentChecksum: useContentChecksum,
            selfContained: mapped.SelfContained,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Asynchronously decompresses an SLZ1-framed file.
    /// </summary>
    /// <param name="inputPath">Path to the compressed input file.</param>
    /// <param name="outputPath">Path to the decompressed output file.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Total decompressed bytes written.</returns>
    public static async Task<long> DecompressFileAsync(string inputPath, string outputPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(inputPath);
        ArgumentNullException.ThrowIfNull(outputPath);
        const int ioBufSize = 1024 * 1024;
#pragma warning disable CA2007 // await using on FileStream — disposal is synchronous
        await using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, ioBufSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, ioBufSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
#pragma warning restore CA2007
        return await StreamLzFrameDecompressor.DecompressAsync(input, output,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    // ────────────────────────────────────────────────────────────────
    //  Validation
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Checks whether <paramref name="data"/> begins with a valid SLZ1 frame header.
    /// Does not decompress or validate the compressed payload.
    /// </summary>
    /// <param name="data">The data to check.</param>
    /// <returns><c>true</c> if the data starts with a valid SLZ1 frame header.</returns>
    public static bool IsValidFrame(ReadOnlySpan<byte> data)
    {
        return FrameSerializer.TryReadHeader(data, out _);
    }

    /// <summary>
    /// Checks whether the stream begins with a valid SLZ1 frame header.
    /// Reads up to <see cref="Common.FrameConstants.MaxHeaderSize"/> bytes.
    /// The stream position is restored if the stream supports seeking.
    /// </summary>
    /// <param name="input">The stream to check.</param>
    /// <returns><c>true</c> if the stream starts with a valid SLZ1 frame header.</returns>
    public static bool IsValidFrame(Stream input)
    {
        ArgumentNullException.ThrowIfNull(input);
        long startPos = input.CanSeek ? input.Position : -1;
        byte[] buf = new byte[FrameConstants.MaxHeaderSize];
        int bytesRead = 0;
        while (bytesRead < buf.Length)
        {
            int n = input.Read(buf, bytesRead, buf.Length - bytesRead);
            if (n == 0) break;
            bytesRead += n;
        }
        bool valid = FrameSerializer.TryReadHeader(buf.AsSpan(0, bytesRead), out _);
        if (startPos >= 0) input.Position = startPos;
        return valid;
    }

    // ────────────────────────────────────────────────────────────────
    //  JIT warmup
    // ────────────────────────────────────────────────────────────────

    /// <summary>
    /// Pre-JITs all decompression hot-path methods using
    /// <see cref="System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(RuntimeMethodHandle)"/>
    /// so the first real decompress call runs at full speed. No data is compressed
    /// or decompressed — only JIT compilation of native code is triggered.
    /// </summary>
    /// <remarks>
    /// Called automatically by the <see cref="Slz"/> static constructor on first use.
    /// Reduces first-call decompress penalty from ~30% to ~7% (residual gap is
    /// cache/memory cold start, not JIT). Adds ~15ms to startup.
    /// </remarks>
    public static void WarmUp()
    {
        PrepareHotMethods(typeof(StreamLZDecoder));
        PrepareHotMethods(typeof(Decompression.High.LzDecoder));
        PrepareHotMethods(typeof(Decompression.Fast.LzDecoder));
        PrepareHotMethods(typeof(Decompression.Entropy.EntropyDecoder));
        PrepareHotMethods(typeof(Decompression.Entropy.HuffmanDecoder));
        PrepareHotMethods(typeof(Decompression.Entropy.TansDecoder));
        PrepareHotMethods(typeof(Common.CopyHelpers));
    }

    private static void PrepareHotMethods(Type type)
    {
        foreach (var method in type.GetMethods(
            System.Reflection.BindingFlags.Public |
            System.Reflection.BindingFlags.NonPublic |
            System.Reflection.BindingFlags.Static |
            System.Reflection.BindingFlags.Instance |
            System.Reflection.BindingFlags.DeclaredOnly))
        {
            if (method.IsAbstract || method.ContainsGenericParameters)
                continue;
            try
            {
                System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
            {
                // PrepareMethod can throw ArgumentException, InvalidProgramException, etc.
                // for methods it can't compile (generic instantiations, extern, etc.) — skip.
                System.Diagnostics.Trace.TraceWarning($"PrepareMethod failed for {method.Name}: {ex.Message}");
            }
        }
    }
}
