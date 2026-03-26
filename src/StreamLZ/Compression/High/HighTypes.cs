// Types.cs — Constants and core data structures for the High compressor.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using StreamLZ.Common;

namespace StreamLZ.Compression.High;

internal static unsafe partial class Compressor
{
    private const int MinBytesPerRound = 256;
    private const int MaxBytesPerRound = 4096;
    private const int RecentOffsetCount = 3;

    /// <summary>Recent-offset ring for High (3 entries, stored at indices 4-6).</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct HighRecentOffs
    {
        public fixed int Offs[8];

        public static HighRecentOffs Create()
        {
            var r = new HighRecentOffs();
            r.Offs[4] = StreamLZConstants.InitialRecentOffset;
            r.Offs[5] = StreamLZConstants.InitialRecentOffset;
            r.Offs[6] = StreamLZConstants.InitialRecentOffset;
            return r;
        }
    }

    /// <summary>
    /// Intermediate LZ encoding state — holds the six output streams
    /// (literals, sub-literals, tokens, u8 offsets, u32 offsets, lrl8, len32).
    /// </summary>
    internal struct HighStreamWriter
    {
        public byte* LitsStart, Lits;
        public byte* SubLitsStart, SubLits;
        public byte* TokensStart, Tokens;
        public byte* U8OffsStart, U8Offs;
        public uint* U32OffsStart, U32Offs;
        public byte* Lrl8Start, Lrl8;
        public uint* Len32Start, Len32;
        public int SrcLen;
        public byte* SrcPtr;
        public int Recent0;
        public int EncodeFlags;
    }

    /// <summary>A single token in the parsed LZ sequence.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct Token
    {
        public int RecentOffset0;
        public int LitLen;
        public int MatchLen;
        public int Offset;
    }

    /// <summary>Growable token array.</summary>
    private struct TokenArray
    {
        public Token* Data;
        public int Size;
        public int Capacity;
    }

    /// <summary>Token array exported from the optimal parser for two-phase compression.</summary>
    public class ExportedTokens
    {
        public Token[] Tokens = Array.Empty<Token>();
        public int Count;
        public int ChunkType;
    }

    /// <summary>Optimal-parser state (one per grid cell).</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct State
    {
        public int BestBitCount;
        public int RecentOffs0, RecentOffs1, RecentOffs2;
        public int MatchLen;
        public int LitLen;
        public int QuickRecentMatchLenLitLen;
        public int PrevState;

        public void Initialize()
        {
            BestBitCount = 0;
            RecentOffs0 = StreamLZConstants.InitialRecentOffset;
            RecentOffs1 = StreamLZConstants.InitialRecentOffset;
            RecentOffs2 = StreamLZConstants.InitialRecentOffset;
            MatchLen = 0;
            LitLen = 0;
            PrevState = 0;
            QuickRecentMatchLenLitLen = 0;
        }

        /// <summary>Access recent_offs by index (0, 1, or 2).</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public readonly int GetRecentOffs(int idx)
        {
            return idx switch
            {
                0 => RecentOffs0,
                1 => RecentOffs1,
                2 => RecentOffs2,
                _ => throw new ArgumentOutOfRangeException(nameof(idx), idx, "Recent offset index must be 0, 1, or 2."),
            };
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void SetRecentOffs(int idx, int value)
        {
            switch (idx)
            {
                case 0: RecentOffs0 = value; break;
                case 1: RecentOffs1 = value; break;
                case 2: RecentOffs2 = value; break;
                default: throw new ArgumentOutOfRangeException(nameof(idx), idx, "Recent offset index must be 0, 1, or 2.");
            }
        }
    }

    /// <summary>Cost model built from running statistics.</summary>
    private struct CostModel
    {
        public int ChunkType;
        public int SubOrCopyMask;
        public fixed uint LitCost[256];
        public fixed uint TokenCost[256];
        public int OffsEncodeType;
        public fixed uint OffsCost[256];
        public fixed uint OffsLoCost[256];
        public fixed uint MatchLenCost[256];
    }

    /// <summary>Running compression statistics (histograms for each stream).</summary>
    internal struct Stats
    {
        public HistoU8 LitRaw;
        public HistoU8 LitSub;
        public HistoU8 TokenHisto;
        public HistoU8 MatchLenHisto;
        public int OffsEncodeType;
        public HistoU8 OffsHisto;
        public HistoU8 OffsLoHisto;
    }
}
