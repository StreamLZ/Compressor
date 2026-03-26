using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace StreamLZ.Compression.Entropy;

/// <summary>
/// Generic pointer-based max-heap operations for unmanaged types.
/// Elements are ordered by <see cref="IComparable{T}.CompareTo"/>:
/// the element with the largest value sits at index 0.
/// </summary>
internal static unsafe class MaxHeap<T> where T : unmanaged, IComparable<T>
{
    /// <summary>
    /// Builds a max-heap in-place over [<paramref name="begin"/>, <paramref name="end"/>).
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void MakeHeap(T* begin, T* end)
    {
        long n = end - begin;
        for (long half = n >> 1; half-- > 0;)
        {
            long t = half, u;
            while ((u = 2 * t + 1) < n)
            {
                if (u + 1 < n && begin[u].CompareTo(begin[u + 1]) < 0)
                {
                    u++;
                }
                if (begin[u].CompareTo(begin[t]) < 0)
                {
                    break;
                }
                (begin[t], begin[u]) = (begin[u], begin[t]);
                t = u;
            }
        }
    }

    /// <summary>
    /// Sifts the last element (at <c>end - 1</c>) up into its correct position.
    /// Call after appending a new element at the end of the heap.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void PushHeap(T* begin, T* end)
    {
        long t = end - begin - 1, u;
        while (t > 0)
        {
            u = (t - 1) >> 1;
            if (begin[u].CompareTo(begin[t]) >= 0)
            {
                break;
            }
            (begin[t], begin[u]) = (begin[u], begin[t]);
            t = u;
        }
    }

    /// <summary>
    /// Removes the maximum element (at index 0) and restores the heap property.
    /// The logical heap size shrinks by one: the caller should decrement their end pointer.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static void PopHeap(T* begin, T* end)
    {
        long n = end - begin;
        Debug.Assert(n > 0, "PopHeap called on empty heap");
        long t = 0, u;
        while ((u = 2 * t + 1) < n)
        {
            if (u + 1 < n && begin[u].CompareTo(begin[u + 1]) < 0)
            {
                u++;
            }
            begin[t] = begin[u];
            t = u;
        }
        if (t < n - 1)
        {
            begin[t] = begin[n - 1];
            while (t > 0)
            {
                u = (t - 1) >> 1;
                if (begin[u].CompareTo(begin[t]) >= 0)
                {
                    break;
                }
                (begin[t], begin[u]) = (begin[u], begin[t]);
                t = u;
            }
        }
    }
}
