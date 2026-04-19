//! Dictionary trainer using the FASTCOVER algorithm.
//!
//! Scans training data for frequently-occurring d-mer patterns and
//! greedily selects segments that cover the most common patterns.
//! Output is a raw dictionary suitable for LZ compression preload.
//!
//! Based on zstd's FASTCOVER algorithm (lib/dictBuilder/fastcover.c).

const std = @import("std");

const default_d: usize = 8;
const default_k: usize = 48;
const default_f: u5 = 20;
const default_epochs: usize = 32;
const max_zero_score_epochs: usize = 10;

pub const TrainParams = struct {
    dict_size: usize = 32768,
    d: usize = default_d,
    k: usize = default_k,
    f: u5 = default_f,
    epochs: usize = default_epochs,
};

pub const TrainResult = struct {
    dict: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TrainResult) void {
        self.allocator.free(self.dict);
    }
};

fn hashDmer(src: [*]const u8, d: usize, f: u5) usize {
    _ = d;
    const v = std.mem.readInt(u64, src[0..8], .little);
    const h = v *% 0x9E3779B97F4A7C15;
    const shift: u6 = @intCast(@as(u7, 64) - @as(u7, f));
    return @intCast(h >> shift);
}

pub fn train(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    params: TrainParams,
) !TrainResult {
    if (samples.len == 0) return error.NoSamples;

    const d = params.d;
    const k = params.k;
    const f = params.f;
    const freq_size: usize = @as(usize, 1) << f;

    // Count d-mer frequencies across all samples.
    const freqs = try allocator.alloc(u32, freq_size);
    defer allocator.free(freqs);
    @memset(freqs, 0);

    var total_len: usize = 0;
    for (samples) |sample| {
        if (sample.len < d) continue;
        var pos: usize = 0;
        while (pos + d <= sample.len) : (pos += 1) {
            const idx = hashDmer(sample.ptr + pos, d, f);
            freqs[idx] += 1;
        }
        total_len += sample.len;
    }
    if (total_len < d) return error.NoSamples;

    // Per-segment frequency tracking (reset per segment evaluation).
    const seg_freqs = try allocator.alloc(u32, freq_size);
    defer allocator.free(seg_freqs);

    // Build the dictionary by selecting best segments.
    const dict = try allocator.alloc(u8, params.dict_size);
    var dict_pos: usize = params.dict_size;

    const epoch_size = params.dict_size / params.epochs;
    if (epoch_size == 0) return error.NoSamples;

    var zero_score_count: usize = 0;
    var epoch_idx: usize = 0;

    while (dict_pos > 0 and zero_score_count < max_zero_score_epochs) {
        // Round-robin through samples.
        const sample_idx = epoch_idx % samples.len;
        const sample = samples[sample_idx];
        epoch_idx += 1;

        if (sample.len < k) continue;

        // Find best segment of size k in this sample.
        @memset(seg_freqs, 0);

        const dmers_in_k = k - d + 1;
        var best_score: u64 = 0;
        var best_begin: usize = 0;
        var active_score: u64 = 0;
        var active_begin: usize = 0;

        var pos: usize = 0;
        while (pos + d <= sample.len) : (pos += 1) {
            const idx = hashDmer(sample.ptr + pos, d, f);

            if (seg_freqs[idx] == 0) {
                active_score += freqs[idx];
            }
            seg_freqs[idx] += 1;

            // Window is full — drop the oldest d-mer.
            if (pos - active_begin >= dmers_in_k) {
                const del_idx = hashDmer(sample.ptr + active_begin, d, f);
                seg_freqs[del_idx] -= 1;
                if (seg_freqs[del_idx] == 0) {
                    active_score -= freqs[del_idx];
                }
                active_begin += 1;
            }

            if (active_score > best_score and pos - active_begin + 1 >= dmers_in_k) {
                best_score = active_score;
                best_begin = active_begin;
            }
        }

        if (best_score == 0) {
            zero_score_count += 1;
            continue;
        }
        zero_score_count = 0;

        // Copy best segment into dictionary (filled backward).
        const seg_len = @min(k, dict_pos);
        const seg_start = best_begin;
        if (seg_start + seg_len > sample.len) continue;

        dict_pos -= seg_len;
        @memcpy(dict[dict_pos..][0..seg_len], sample[seg_start..][0..seg_len]);

        // Zero out the selected d-mers so they're not double-counted.
        var z: usize = 0;
        while (z + d <= seg_len) : (z += 1) {
            const idx = hashDmer(sample.ptr + seg_start + z, d, f);
            freqs[idx] = 0;
        }
    }

    // If dictionary wasn't fully filled, shift content to start.
    if (dict_pos > 0) {
        const used = params.dict_size - dict_pos;
        std.mem.copyForwards(u8, dict[0..used], dict[dict_pos..][0..used]);
        const result = allocator.realloc(dict, used) catch dict;
        return .{ .dict = result[0..used], .allocator = allocator };
    }

    return .{ .dict = dict, .allocator = allocator };
}

pub const NoSamples = error{NoSamples};
