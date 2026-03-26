// FrameFormat.cs — StreamLZ frame format constants, header types, and serialization.

using System.Buffers.Binary;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Common;

/// <summary>
/// Constants for the StreamLZ frame format (version 1).
/// </summary>
public static class FrameConstants
{
    /// <summary>Magic number identifying a StreamLZ frame: "SLZ1" (0x314C5A53 little-endian).</summary>
    public const uint MagicNumber = 0x53_4C_5A_31; // 'S','L','Z','1' in memory order

    /// <summary>Current frame format version.</summary>
    public const byte Version = 1;

    /// <summary>End-of-stream marker: a block with compressed size = 0.</summary>
    public const uint EndMark = 0;

    /// <summary>High bit in block compressed size indicating uncompressed (stored) data.</summary>
    public const uint BlockUncompressedFlag = 0x80000000;

    /// <summary>Minimum frame header size (no optional fields): magic + version + flags + codec + level + blockSize + reserved = 10 bytes.</summary>
    public const int MinHeaderSize = 10;

    /// <summary>Maximum frame header size (all optional fields): min + contentSize(8) + dictId(4) = 22 bytes.</summary>
    public const int MaxHeaderSize = 22;

    /// <summary>Default block size for framed compression (256 KB, matching the chunk size).</summary>
    public const int DefaultBlockSize = StreamLZConstants.ChunkSize;

    /// <summary>Minimum supported block size (64 KB).</summary>
    public const int MinBlockSize = 0x10000;

    /// <summary>Maximum supported block size for serial path (4 MB).</summary>
    public const int MaxBlockSize = 0x400000;

    /// <summary>Maximum decompressed block size accepted from a stream (512 MB).
    /// Guards against malicious streams claiming enormous block sizes to force allocation.</summary>
    public const int MaxDecompressedBlockSize = 512 * 1024 * 1024;

    /// <summary>Default sliding window size (128 MB).</summary>
    public const int DefaultWindowSize = 128 * 1024 * 1024;

    /// <summary>Maximum sliding window size (1 GB, matching MaxDictionarySize).</summary>
    public const int MaxWindowSize = StreamLZConstants.MaxDictionarySize;
}

/// <summary>
/// Flags stored in the frame header controlling optional features.
/// Underlying type is <c>byte</c> because it maps directly to a single header byte on the wire.
/// </summary>
[Flags]
[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1028", Justification = "Byte maps directly to wire format")]
[System.Diagnostics.CodeAnalysis.SuppressMessage("Naming", "CA1711", Justification = "Flags suffix is descriptive for a [Flags] enum")]
public enum FrameFlags : byte
{
    /// <summary>No optional features.</summary>
    None = 0,

    /// <summary>8-byte content size is present after the fixed header fields.</summary>
    ContentSizePresent = 1 << 0,

    /// <summary>XXH32 content checksum is appended after the end mark.</summary>
    ContentChecksum = 1 << 1,

    /// <summary>XXH32 block checksum is appended after each compressed block.</summary>
    BlockChecksums = 1 << 2,

    /// <summary>4-byte dictionary ID is present after content size (if any).</summary>
    DictionaryIdPresent = 1 << 3,
}

/// <summary>
/// Parsed frame header describing the compressed stream.
/// </summary>
public readonly struct FrameHeader
{
    /// <summary>Frame format version (currently 1).</summary>
    public byte Version { get; init; }

    /// <summary>Feature flags.</summary>
    public FrameFlags Flags { get; init; }

    /// <summary>Codec used for compression (0 = High, 1 = Fast).</summary>
    public byte Codec { get; init; }

    /// <summary>Compression level (0-9).</summary>
    public byte Level { get; init; }

    /// <summary>Block size in bytes (decoded from log2 representation).</summary>
    public int BlockSize { get; init; }

    /// <summary>Original uncompressed content size, or -1 if not present.</summary>
    public long ContentSize { get; init; }

    /// <summary>Dictionary ID, or 0 if not present.</summary>
    public uint DictionaryId { get; init; }

    /// <summary>Total number of header bytes (for skipping past the header on read).</summary>
    public int HeaderSize { get; init; }
}

/// <summary>
/// Reads and writes StreamLZ frame headers.
/// </summary>
public static class FrameSerializer
{
    /// <summary>
    /// Writes a frame header to the destination buffer.
    /// </summary>
    /// <param name="destination">Buffer to write the header to (must be at least <see cref="FrameConstants.MaxHeaderSize"/> bytes).</param>
    /// <param name="codec">Codec identifier (0 = High, 1 = Fast).</param>
    /// <param name="level">Compression level (0-9).</param>
    /// <param name="blockSize">Block size in bytes (must be a power of 2 between 64KB and 4MB).</param>
    /// <param name="contentSize">Original content size, or -1 if unknown.</param>
    /// <param name="useContentChecksum">Whether to write a content checksum after the last block.</param>
    /// <param name="useBlockChecksums">Whether to write per-block checksums.</param>
    /// <returns>Number of header bytes written.</returns>
    public static int WriteHeader(Span<byte> destination, int codec, int level,
        int blockSize = FrameConstants.DefaultBlockSize, long contentSize = -1,
        bool useContentChecksum = false, bool useBlockChecksums = false)
    {
        FrameFlags flags = FrameFlags.None;
        if (contentSize >= 0) flags |= FrameFlags.ContentSizePresent;
        if (useContentChecksum) flags |= FrameFlags.ContentChecksum;
        if (useBlockChecksums) flags |= FrameFlags.BlockChecksums;

        if (!BitOperations.IsPow2(blockSize))
            throw new ArgumentException($"Block size must be a power of 2, got {blockSize}.", nameof(blockSize));

        int blockSizeLog2 = BitOperationsLog2(blockSize) - BitOperationsLog2(FrameConstants.MinBlockSize);

        int pos = 0;
        BinaryPrimitives.WriteUInt32LittleEndian(destination[pos..], FrameConstants.MagicNumber);
        pos += 4;
        destination[pos++] = FrameConstants.Version;
        destination[pos++] = (byte)flags;
        destination[pos++] = (byte)codec;
        destination[pos++] = (byte)level;
        destination[pos++] = (byte)blockSizeLog2;
        destination[pos++] = 0; // reserved

        if ((flags & FrameFlags.ContentSizePresent) != 0)
        {
            BinaryPrimitives.WriteInt64LittleEndian(destination[pos..], contentSize);
            pos += 8;
        }

        return pos;
    }

    /// <summary>
    /// Reads and parses a frame header from the source buffer.
    /// </summary>
    /// <param name="source">Buffer containing the frame header.</param>
    /// <param name="header">Receives the parsed header.</param>
    /// <returns>True if the header was parsed successfully, false if the magic number doesn't match or the data is too short.</returns>
    public static bool TryReadHeader(ReadOnlySpan<byte> source, out FrameHeader header)
    {
        header = default;

        if (source.Length < FrameConstants.MinHeaderSize)
            return false;

        uint magic = BinaryPrimitives.ReadUInt32LittleEndian(source);
        if (magic != FrameConstants.MagicNumber)
            return false;

        int pos = 4;
        byte version = source[pos++];
        if (version != FrameConstants.Version)
            return false;

        var flags = (FrameFlags)source[pos++];
        byte codec = source[pos++];
        byte level = source[pos++];

        int blockSizeLog2 = source[pos++] + BitOperationsLog2(FrameConstants.MinBlockSize);
        if (blockSizeLog2 < BitOperationsLog2(FrameConstants.MinBlockSize) || blockSizeLog2 > BitOperationsLog2(FrameConstants.MaxBlockSize))
            return false;
        int blockSize = 1 << blockSizeLog2;
        pos++; // reserved

        long contentSize = -1;
        if ((flags & FrameFlags.ContentSizePresent) != 0)
        {
            if (source.Length < pos + 8)
                return false;
            contentSize = BinaryPrimitives.ReadInt64LittleEndian(source[pos..]);
            pos += 8;
        }

        uint dictionaryId = 0;
        if ((flags & FrameFlags.DictionaryIdPresent) != 0)
        {
            if (source.Length < pos + 4)
                return false;
            dictionaryId = BinaryPrimitives.ReadUInt32LittleEndian(source[pos..]);
            pos += 4;
        }

        header = new FrameHeader
        {
            Version = version,
            Flags = flags,
            Codec = codec,
            Level = level,
            BlockSize = blockSize,
            ContentSize = contentSize,
            DictionaryId = dictionaryId,
            HeaderSize = pos,
        };
        return true;
    }

    /// <summary>
    /// Writes an end-of-stream mark (4 zero bytes).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteEndMark(Span<byte> destination)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(destination, FrameConstants.EndMark);
    }

    /// <summary>
    /// Writes a block header: 4-byte LE compressed size + 4-byte LE decompressed size.
    /// High bit of compressed size indicates uncompressed (stored) data.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WriteBlockHeader(Span<byte> destination, int compressedSize, int decompressedSize, bool isUncompressed)
    {
        uint value = (uint)compressedSize;
        if (isUncompressed) value |= FrameConstants.BlockUncompressedFlag;
        BinaryPrimitives.WriteUInt32LittleEndian(destination, value);
        BinaryPrimitives.WriteInt32LittleEndian(destination[4..], decompressedSize);
    }

    /// <summary>
    /// Reads a block header: returns compressed size, decompressed size, and whether the block is uncompressed.
    /// A compressed size of 0 indicates end-of-stream.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static bool TryReadBlockHeader(ReadOnlySpan<byte> source, out int compressedSize, out int decompressedSize, out bool isUncompressed)
    {
        compressedSize = 0;
        decompressedSize = 0;
        isUncompressed = false;
        if (source.Length < 8)
            return false;
        uint value = BinaryPrimitives.ReadUInt32LittleEndian(source);
        if (value == FrameConstants.EndMark)
            return true; // end mark: compressedSize = 0
        isUncompressed = (value & FrameConstants.BlockUncompressedFlag) != 0;
        compressedSize = (int)(value & ~FrameConstants.BlockUncompressedFlag);
        decompressedSize = BinaryPrimitives.ReadInt32LittleEndian(source[4..]);
        return compressedSize > 0 && decompressedSize > 0;
    }

    private static int BitOperationsLog2(int value)
    {
        return System.Numerics.BitOperations.Log2((uint)value);
    }
}
