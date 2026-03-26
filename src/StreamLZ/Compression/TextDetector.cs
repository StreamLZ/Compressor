// TextDetector.cs — Text detection heuristics for StreamLzCompressor.

using System.Runtime.CompilerServices;

namespace StreamLZ.Compression;

internal static unsafe partial class StreamLZCompressor
{
    /// <summary>
    /// Quick heuristic: samples 32 spans of the input and checks if they look
    /// like valid UTF-8 text.
    /// </summary>
    /// <param name="p">Pointer to the data to sample.</param>
    /// <param name="size">Length of the data in bytes.</param>
    /// <returns><c>true</c> if at least 14 of 32 sampled spans appear to be valid UTF-8 text.</returns>
    public static bool IsProbablyText(byte* p, int size)
    {
        const int SampleCount = 32;
        const int MinBlockSize = 32;
        const int MinTextSamples = 14;

        byte* dataStart = p;
        if (size / SampleCount < MinBlockSize)
        {
            return false;
        }

        int score = 0;
        int step = size / SampleCount;
        for (int i = 0; i < SampleCount; i++, p += step)
        {
            int blockLen = Math.Min(MinBlockSize, (int)(dataStart + size - p));
            if (IsBlockProbablyText(p, p + blockLen))
            {
                score++;
            }
        }
        return score >= MinTextSamples;
    }

    /// <summary>
    /// Checks whether a small block is valid UTF-8 text.
    /// </summary>
    /// <param name="p">Pointer to the start of the block.</param>
    /// <param name="pEnd">Pointer past the end of the block.</param>
    /// <returns><c>true</c> if the block contains valid UTF-8 sequences in the printable range.</returns>
    internal static bool IsBlockProbablyText(byte* p, byte* pEnd)
    {
        // UTF-8 byte range constants
        const byte MinPrintable = 9;           // Tab — lowest acceptable "text" byte
        const byte MaxAsciiPrintable = 0x7E;   // '~' — highest single-byte printable
        const byte ContinuationLo = 0x80;      // Start of UTF-8 continuation range
        const byte ContinuationHi = 0xBF;      // End of UTF-8 continuation range
        const byte MinTwoByteLeadByte = 0xC2;  // 0xC0-0xC1 are overlong — reject
        const byte MaxValidLeadByte = 0xF4;    // 0xF5+ encodes > U+10FFFF — reject
        const byte MinThreeByteLeadByte = 0xE0;
        const byte MinFourByteLeadByte = 0xF0;

        byte* blockStart = p;
        // Tolerates up to 3 leading continuation bytes for mid-sequence block boundaries.
        // A block boundary can land in the middle of a multi-byte UTF-8 sequence, so
        // the first 1-3 bytes may be continuation bytes (0x80..0xBF) from the prior block.
        while (p < pEnd && IsByteInside(*p, ContinuationLo, ContinuationHi))
        {
            p++;
        }
        if (p - blockStart > 3)
        {
            return false;
        }

        while (p < pEnd)
        {
            byte c = *p++;
            if (!IsByteInside(c, MinPrintable, MaxAsciiPrintable))
            {
                if (!IsByteInside(c, MinTwoByteLeadByte, MaxValidLeadByte))
                {
                    return false;
                }

                long left = pEnd - p;
                if (c < MinThreeByteLeadByte)
                {
                    // 2-byte sequence: 1 continuation byte
                    if (left == 0)
                    {
                        break;
                    }
                    p += 1;
                    if (!IsByteInside(p[-1], ContinuationLo, ContinuationHi))
                    {
                        return false;
                    }
                }
                else if (c < MinFourByteLeadByte)
                {
                    // 3-byte sequence: 2 continuation bytes
                    if (left < 2)
                    {
                        if (left == 0)
                        {
                            break;
                        }
                        p += 1;
                        if (!IsByteInside(p[-1], ContinuationLo, ContinuationHi))
                        {
                            return false;
                        }
                    }
                    else
                    {
                        p += 2;
                        if (!(IsByteInside(p[-2], ContinuationLo, ContinuationHi) && IsByteInside(p[-1], ContinuationLo, ContinuationHi)))
                        {
                            return false;
                        }
                    }
                }
                else
                {
                    // 4-byte sequence: 3 continuation bytes
                    if (left < 3)
                    {
                        if (left < 2)
                        {
                            if (left == 0)
                            {
                                break;
                            }
                            p += 1;
                            if (!IsByteInside(p[-1], ContinuationLo, ContinuationHi))
                            {
                                return false;
                            }
                        }
                        else
                        {
                            p += 2;
                            if (!(IsByteInside(p[-2], ContinuationLo, ContinuationHi) && IsByteInside(p[-1], ContinuationLo, ContinuationHi)))
                            {
                                return false;
                            }
                        }
                    }
                    else
                    {
                        p += 3;
                        if (!(IsByteInside(p[-3], ContinuationLo, ContinuationHi) &&
                              IsByteInside(p[-2], ContinuationLo, ContinuationHi) &&
                              IsByteInside(p[-1], ContinuationLo, ContinuationHi)))
                        {
                            return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static bool IsByteInside(byte a, byte lo, byte hi)
    {
        return (byte)(a - lo) <= (byte)(hi - lo);
    }
}
