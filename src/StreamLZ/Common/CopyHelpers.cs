using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;

namespace StreamLZ.Common;

/// <summary>
/// Low-level copy primitives used by the LZ decoders (High, Fast, Turbo).
/// </summary>
/// <remarks>
/// Uses SSE2 on x86/x64 and AdvSimd (NEON) on ARM, with scalar fallback.
/// Unaligned <c>*(ulong*)</c> loads are safe on x86/x64 and on ARM with .NET
/// (the JIT emits unaligned load instructions).
/// </remarks>
internal static unsafe class CopyHelpers
{
    /// <summary>
    /// Aligns a pointer up to the specified power-of-two alignment.
    /// Used by all LZ decoders (High, Fast, Turbo) to align scratch buffer pointers
    /// before allocating stream arrays.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static byte* AlignPointer(byte* p, nuint align)
    {
        return (byte*)(((nuint)p + (align - 1)) & ~(align - 1));
    }

    /// <summary>
    /// Copies 8 bytes via unaligned 64-bit load/store.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void Copy64(byte* dst, byte* src)
    {
        *(ulong*)dst = *(ulong*)src;
    }

    /// <summary>
    /// Copies 64 bytes using 4x 128-bit loads/stores (Vector128 on x86/ARM, scalar fallback).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void Copy64Bytes(byte* dst, byte* src)
    {
        if (Vector128.IsHardwareAccelerated)
        {
            Vector128.Store(Vector128.Load(src), dst);
            Vector128.Store(Vector128.Load(src + 16), dst + 16);
            Vector128.Store(Vector128.Load(src + 32), dst + 32);
            Vector128.Store(Vector128.Load(src + 48), dst + 48);
        }
        else
        {
            *(ulong*)(dst) = *(ulong*)(src);
            *(ulong*)(dst + 8) = *(ulong*)(src + 8);
            *(ulong*)(dst + 16) = *(ulong*)(src + 16);
            *(ulong*)(dst + 24) = *(ulong*)(src + 24);
            *(ulong*)(dst + 32) = *(ulong*)(src + 32);
            *(ulong*)(dst + 40) = *(ulong*)(src + 40);
            *(ulong*)(dst + 48) = *(ulong*)(src + 48);
            *(ulong*)(dst + 56) = *(ulong*)(src + 56);
        }
    }

    /// <summary>
    /// Copies in 16-byte chunks until <paramref name="dst"/> reaches <paramref name="dstEnd"/>.
    /// </summary>
    /// <remarks>
    /// <b>Caller responsibility:</b> This method may write up to 15 bytes past
    /// <paramref name="dstEnd"/> because it copies in 16-byte (two 8-byte) steps
    /// without a final partial-copy fallback. The caller must guarantee that
    /// <c>dstEnd + 15</c> is within a writable allocation — typically ensured by
    /// the <c>StreamLZDecoder.SafeSpace</c> (64-byte) padding at the end of the
    /// output buffer.
    /// </remarks>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void WildCopy16(byte* dst, byte* src, byte* dstEnd)
    {
        Debug.Assert(dst <= dstEnd, "WildCopy16: dst must not exceed dstEnd on entry");
        // 16 bytes per iteration via two 8-byte unaligned loads.
        // AVX2 (32-byte) was tested and is slower due to frequency throttling
        // on Arrow Lake. The 8-byte load pattern is optimal for this workload.
        do
        {
            *(ulong*)dst = *(ulong*)src;
            *(ulong*)(dst + 8) = *(ulong*)(src + 8);
            dst += 16;
            src += 16;
        } while (dst < dstEnd);
    }

    /// <summary>
    /// Loads 8 bytes from <paramref name="src"/> and <paramref name="delta"/>,
    /// adds them byte-wise, and stores the result to <paramref name="dst"/>.
    /// Used by Type0 LZ runs where literals are delta-coded against prior output.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void Copy64Add(byte* dst, byte* src, byte* delta)
    {
        if (Sse2.IsSupported)
        {
            var vs = Sse2.LoadScalarVector128((ulong*)src).AsByte();
            var vd = Sse2.LoadScalarVector128((ulong*)delta).AsByte();
            var result = Sse2.Add(vs, vd);
            Sse2.StoreScalar((ulong*)dst, result.AsUInt64());
        }
        else if (AdvSimd.IsSupported)
        {
            var vs = AdvSimd.LoadVector64(src);
            var vd = AdvSimd.LoadVector64(delta);
            AdvSimd.Store(dst, AdvSimd.Add(vs, vd));
        }
        else
        {
            // Scalar fallback: byte-wise add
            for (int i = 0; i < 8; i++)
            {
                dst[i] = (byte)(src[i] + delta[i]);
            }
        }
    }

    /// <summary>
    /// Cross-platform MoveMask: extracts one bit per byte lane from a 128-bit comparison result.
    /// On x86, uses <c>Sse2.MoveMask</c>. On ARM, uses a narrowing + shift + horizontal add sequence.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static int MoveMask(Vector128<byte> v)
    {
        if (Sse2.IsSupported)
        {
            return Sse2.MoveMask(v);
        }

        if (AdvSimd.Arm64.IsSupported)
        {
            // Each byte lane is 0x00 or 0xFF from a comparison result.
            // Narrow to extract the sign bits: AND with powers-of-two mask, then horizontal add.
            Vector128<byte> mask = Vector128.Create(
                (byte)1, 2, 4, 8, 16, 32, 64, 128,
                1, 2, 4, 8, 16, 32, 64, 128);
            var masked = AdvSimd.And(v, mask);
            // Sum each 8-byte half: the result is the movemask for that half.
            var paired = AdvSimd.Arm64.AddPairwise(masked, masked);
            paired = AdvSimd.Arm64.AddPairwise(paired, paired);
            paired = AdvSimd.Arm64.AddPairwise(paired, paired);
            return paired.GetElement(0) | (paired.GetElement(8) << 8);
        }

        // Scalar fallback
        int result = 0;
        for (int i = 0; i < 16; i++)
        {
            if ((v.GetElement(i) & 0x80) != 0)
                result |= 1 << i;
        }
        return result;
    }
}
