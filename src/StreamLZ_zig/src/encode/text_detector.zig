//! Quick UTF-8 text-detection heuristic. Port of
//! `src/StreamLZ/Compression/TextDetector.cs`.
//!
//! Samples 32 fixed-size spans spaced across the input and counts how many
//! look like valid UTF-8 (printable ASCII ≥ 0x09 plus multi-byte sequences
//! with well-formed lead/continuation bytes). Input is classified as text
//! when at least 14 / 32 samples pass.
//!
//! Used by the Fast compressor's `SetupEncoder` to bump `minimum_match_length`
//! from 4 to 6 on text inputs at engine levels ≤ 3 — longer minimum matches
//! favor the tANS literal stream on text, which tends to produce shorter
//! literal runs than 4-byte matches.

const std = @import("std");

const sample_count: usize = 32;
const min_block_size: usize = 32;
const min_text_samples: usize = 14;

/// Returns true when the input looks like UTF-8 text.
pub fn isProbablyText(data: []const u8) bool {
    if (data.len / sample_count < min_block_size) return false;
    var score: usize = 0;
    const step: usize = data.len / sample_count;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const base = i * step;
        const remaining = data.len - base;
        const block_len = @min(min_block_size, remaining);
        if (isBlockProbablyText(data[base .. base + block_len])) {
            score += 1;
        }
    }
    return score >= min_text_samples;
}

inline fn inRange(a: u8, lo: u8, hi: u8) bool {
    return @as(u8, a -% lo) <= @as(u8, hi -% lo);
}

/// Classifies a single ≥32-byte block as probably-text. Port of C#
/// `TextDetector.IsBlockProbablyText` (`TextDetector.cs:47-162`).
///
/// Exposed publicly so the High codec (step 29+) can call it directly
/// on arbitrary window regions without forcing the full `isProbablyText`
/// sampling pattern.
pub fn isBlockProbablyText(block: []const u8) bool {
    const min_printable: u8 = 9;
    const max_ascii: u8 = 0x7E;
    const cont_lo: u8 = 0x80;
    const cont_hi: u8 = 0xBF;
    const min_two_byte_lead: u8 = 0xC2;
    const max_valid_lead: u8 = 0xF4;
    const min_three_byte_lead: u8 = 0xE0;
    const min_four_byte_lead: u8 = 0xF0;

    var i: usize = 0;
    // Allow up to 3 leading continuation bytes — a sample may land mid-codepoint.
    while (i < block.len and inRange(block[i], cont_lo, cont_hi)) : (i += 1) {}
    if (i > 3) return false;

    while (i < block.len) {
        const c = block[i];
        i += 1;
        if (inRange(c, min_printable, max_ascii)) continue;
        if (!inRange(c, min_two_byte_lead, max_valid_lead)) return false;

        const left = block.len - i;
        if (c < min_three_byte_lead) {
            // 2-byte sequence.
            if (left == 0) break;
            if (!inRange(block[i], cont_lo, cont_hi)) return false;
            i += 1;
        } else if (c < min_four_byte_lead) {
            // 3-byte sequence.
            if (left < 2) {
                if (left == 0) break;
                if (!inRange(block[i], cont_lo, cont_hi)) return false;
                i += 1;
            } else {
                if (!(inRange(block[i], cont_lo, cont_hi) and inRange(block[i + 1], cont_lo, cont_hi))) return false;
                i += 2;
            }
        } else {
            // 4-byte sequence.
            if (left < 3) {
                if (left < 2) {
                    if (left == 0) break;
                    if (!inRange(block[i], cont_lo, cont_hi)) return false;
                    i += 1;
                } else {
                    if (!(inRange(block[i], cont_lo, cont_hi) and inRange(block[i + 1], cont_lo, cont_hi))) return false;
                    i += 2;
                }
            } else {
                if (!(inRange(block[i], cont_lo, cont_hi) and
                    inRange(block[i + 1], cont_lo, cont_hi) and
                    inRange(block[i + 2], cont_lo, cont_hi))) return false;
                i += 3;
            }
        }
    }
    return true;
}

// ────────────────────────────────────────────────────────────
//  Tests
// ────────────────────────────────────────────────────────────

const testing = std.testing;

test "isProbablyText: ASCII English" {
    var buf: [4096]u8 = undefined;
    const p = "The quick brown fox jumps over a lazy dog. ";
    for (&buf, 0..) |*b, i| b.* = p[i % p.len];
    try testing.expect(isProbablyText(&buf));
}

test "isProbablyText: random bytes" {
    var buf: [4096]u8 = undefined;
    var state: u32 = 0xDEADBEEF;
    for (&buf) |*b| {
        state = state *% 1103515245 +% 12345;
        b.* = @intCast((state >> 16) & 0xFF);
    }
    try testing.expect(!isProbablyText(&buf));
}

test "isProbablyText: too small returns false" {
    const tiny = "hello world";
    try testing.expect(!isProbablyText(tiny));
}

test "isProbablyText: UTF-8 multibyte" {
    var buf: [4096]u8 = undefined;
    const p = "Привет мир! 안녕 세계 — 日本語テスト 123 ABC xyz. ";
    for (&buf, 0..) |*b, i| b.* = p[i % p.len];
    try testing.expect(isProbablyText(&buf));
}
