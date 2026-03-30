# Entropy Decoder Security Issue

## Status: RESOLVED in v1.0.5

## Summary

The tANS entropy decoder (`Decompression/Entropy/TansDecoder.cs`) crashes with
`AccessViolationException` when fed corrupted compressed data. This is a
process-killing crash, not a catchable exception. Any .NET application using
StreamLZ to decompress untrusted data is vulnerable.

The LZ decoder layer has been hardened and fuzz-verified (5M mutations, zero
crashes on L1/L5/L9). The entropy layer has not.

## Reproduction

The fuzz test in `StreamLZ.Tests/FuzzTests.cs` reproduces it deterministically:
- Level 6, seed 129, first mutation (iteration 0)
- Any single bit flip in valid L6 compressed data triggers the crash
- The crashing input is saved to `%TEMP%/slz-fuzz-crash-L6.hex`

## Root Cause

`Tans_Decode()` and `High_DecodeTans()` perform raw `*(uint*)` pointer reads
without bounds checking:

```
// In Tans_Decode — forward refill (3 occurrences):
bitsF |= *(uint*)ptrF << bitposF;
ptrF += (31 - bitposF) >> 3;

// In Tans_Decode — backward refill (3 occurrences):
bitsB |= BinaryPrimitives.ReverseEndianness(((uint*)ptrB)[-1]) << bitposB;
ptrB -= (31 - bitposB) >> 3;

// In High_DecodeTans — initial state reads:
uint bitsF = *(uint*)src;
bitsF |= *(uint*)src << (int)bitposF;
```

When the compressed data is corrupted:
1. `Tans_DecodeTable` parses a corrupted frequency table
2. `Tans_InitLut` builds a LUT with corrupt `BitsX` values
3. In the decode loop, `bitposF -= e->BitsX` goes negative
4. The advance `(31 - bitposF) >> 3` produces a large number
5. `ptrF` shoots past the source buffer
6. `*(uint*)ptrF` reads unmapped memory → AccessViolationException

## Why Simple Fixes Don't Work

### Attempt 1: Check ptrF > ptrB before each refill
**Failed.** The tANS decoder deliberately reads from both ends toward the
middle. The forward pointer `ptrF` and backward pointer `ptrB` legitimately
overlap — they read the same bytes from opposite directions. Checking
`ptrF > ptrB` rejects valid streams where the pointers are about to converge.

### Attempt 2: Validate LUT entries after construction
**Failed.** Added checks for `BitsX <= logTableBits` and `W < lutSize` on
every LUT entry. The validation itself was too strict — valid tables have
entries where `W >= lutSize` is legitimate (the W field encodes a base offset,
not a direct index).

### Attempt 3: Validate frequency table totals before InitLut
**Failed.** Checked `AUsed + sum(B weights) == lutSize`. The validation
passed for corrupt tables that happened to have matching totals but still
produced bad BitsX values in the LUT.

## Correct Fix (Not Yet Implemented)

The fix needs to check `ptrF` and `ptrB` against the **original source buffer
bounds** (not against each other):

1. Add `srcStart` and `srcEnd` fields to `TansDecoderParams`
2. Before every `*(uint*)ptrF` read: check `ptrF + 4 <= srcEnd`
3. Before every `((uint*)ptrB)[-1]` read: check `ptrB - 4 >= srcStart`
4. Mask every state update: `stateN = (...) & lutMask` to prevent LUT overrun
5. Validate `bitposF >= 0` and `bitposB >= 0` after every round

The challenge: the pointers must be checked against the original `[src, srcEnd]`
range that was established in `High_DecodeTans` before the initial state reads
consumed the first/last 4 bytes. The `ptrF`/`ptrB` in `Tans_Decode` operate on
the *inner* range `[src+4, srcEnd-4]`. The absolute bounds for the 4-byte reads
are `[src+4, srcEnd]` for forward and `[src+4, srcEnd]` for backward.

The convergence check (`ptrB - ptrF` at the end) must still work — it's the
integrity verification for a valid stream.

## Affected Codecs

- **L6-L8** (High self-contained): uses tANS for entropy coding
- **L9-L11** (High non-SC): uses tANS for entropy coding
- **L1-L5** (Fast): also uses tANS but the fuzz test passed 2M mutations
  without crashing. The Fast path may call tANS differently or the specific
  mutation patterns that trigger the crash are level-dependent.

## Huffman Decoder

The Huffman decoder (`HuffmanDecoder.Decode.cs`) likely has the same class of
issue — raw `*(uint*)` reads in the 3-stream parallel decode loop. It was not
fuzz-tested independently. The `HuffmanDecoder.BitReaderState.Refill` is
bounds-checked (returns 0 past end), but the 3-stream parallel path bypasses
it with direct pointer reads for speed.

## Impact

An attacker sending a crafted .slz file to any application using StreamLZ
can crash the host process. This is not data corruption (which our LZ fixes
prevent) — it's a denial of service via uncatchable process termination.
