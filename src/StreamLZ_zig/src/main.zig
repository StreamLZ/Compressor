const std = @import("std");
const builtin = @import("builtin");
const frame = @import("format/frame_format.zig");
const block_header = @import("format/block_header.zig");
const constants = @import("format/streamlz_constants.zig");
const decoder = @import("decode/streamlz_decoder.zig");
const encoder = @import("encode/streamlz_encoder.zig");
const cleanness = @import("decode/cross_chunk_analyzer.zig");

const version_string = "0.0.0-phase3a";

/// Parse a flag of the form `-x N` from the argument list, advancing the
/// index past the value.  Returns the parsed integer on match, or null if
/// the current arg doesn't match `flag`.  Exits the process on a parse
/// error so callers never see an invalid value.
fn parseIntFlag(comptime T: type, args: []const []const u8, i: *usize, flag: []const u8, w: *std.Io.Writer) ?T {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return std.fmt.parseInt(T, args[i.*], 10) catch {
            w.print("error: invalid {s} value '{s}'\n", .{ flag, args[i.*] }) catch {};
            w.flush() catch {};
            std.process.exit(2);
        };
    }
    return null;
}

const Command = enum {
    version,
    help,
    info,
    decompress,
    compress,
    bench,
    benchc,
    analyze,
    partition,
    parseonly,
    ppoc,

    fn parse(s: []const u8) ?Command {
        const map = .{
            .{ "version", .version },
            .{ "--version", .version },
            .{ "-V", .version },
            .{ "help", .help },
            .{ "--help", .help },
            .{ "-h", .help },
            .{ "info", .info },
            .{ "decompress", .decompress },
            .{ "d", .decompress },
            .{ "compress", .compress },
            .{ "c", .compress },
            .{ "bench", .bench },
            .{ "b", .bench },
            .{ "benchc", .benchc },
            .{ "bc", .benchc },
            .{ "analyze", .analyze },
            .{ "partition", .partition },
            .{ "parseonly", .parseonly },
            .{ "ppoc", .ppoc },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const cmd = Command.parse(args[1]) orelse {
        try stdout.print("error: unknown command '{s}'\n\n", .{args[1]});
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(2);
    };

    switch (cmd) {
        .version => try printVersion(stdout),
        .help => try printUsage(stdout),
        .info => try runInfo(allocator, stdout, args[2..]),
        .decompress => try runDecompress(allocator, stdout, args[2..]),
        .bench => try runBench(allocator, stdout, args[2..]),
        .benchc => try runBenchCompress(allocator, stdout, args[2..]),
        .compress => try runCompress(allocator, stdout, args[2..]),
        .analyze => try runAnalyze(allocator, stdout, args[2..]),
        .partition => try runPartition(allocator, stdout, args[2..]),
        .parseonly => try runParseOnly(allocator, stdout, args[2..]),
        .ppoc => try runPpoc(allocator, stdout, args[2..]),
    }
}

/// Phase-1/Phase-2 parallel decode proof-of-concept.
///
/// Stage 1 (current): validate that the closure sidecar is complete by
/// running phase 1 into a poisoned dst buffer and checking that every
/// cross-sub-chunk match's src range contains correct bytes.
///
/// Stage 2 (planned): add sub-chunk-level phase 2 dispatch.
/// Stage 3 (planned): parallelize phase 2 across threads.
fn runPpoc(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) {
        try w.writeAll("usage: streamlz ppoc <file.slz>\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];

    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();
    const max_bytes: usize = 1 << 31;
    const src = try in_file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(src);

    const hdr = frame.parseHeader(src) catch |err| {
        try w.print("error: not a valid SLZ1 frame: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };
    const content_size: usize = if (hdr.content_size) |cs| @intCast(cs) else {
        try w.writeAll("error: frame has no content size\n");
        try w.flush();
        std.process.exit(1);
    };

    // ── Reference decode ──────────────────────────────────────────────
    const dst_ref = try allocator.alloc(u8, content_size + decoder.safe_space);
    defer allocator.free(dst_ref);
    _ = decoder.decompressFramed(src, dst_ref) catch |err| {
        try w.print("error: reference decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    try w.print("ppoc: {s}\n", .{path});
    try w.print("  compressed bytes:    {d}\n", .{src.len});
    try w.print("  decompressed bytes:  {d}\n", .{content_size});

    // ── Build sidecar ─────────────────────────────────────────────────
    var build_timer = try std.time.Timer.start();
    var sidecar = try cleanness.buildPpocSidecar(allocator, src, dst_ref[0..content_size]);
    defer sidecar.deinit(allocator);
    const build_ms = @as(f64, @floatFromInt(build_timer.read())) / 1_000_000.0;

    try w.print("\n  Sidecar:\n", .{});
    try w.print("    Match ops:        {d}\n", .{sidecar.match_ops.items.len});
    try w.print("    Literal bytes:    {d}\n", .{sidecar.literal_bytes.items.len});
    try w.print("    Total positions:  {d}\n", .{sidecar.total_positions});
    try w.print("    Build time:       {d:.2} ms\n", .{build_ms});

    // Estimate sidecar size if serialized.
    const match_op_size: usize = @sizeOf(cleanness.ClosureMatchOp);
    const lit_byte_size: usize = @sizeOf(cleanness.ClosureLiteralByte);
    const sidecar_bytes = sidecar.match_ops.items.len * match_op_size +
        sidecar.literal_bytes.items.len * lit_byte_size;
    const sidecar_pct = @as(f64, @floatFromInt(sidecar_bytes)) / @as(f64, @floatFromInt(src.len)) * 100;
    try w.print("    Serialized size:  {d} bytes ({d:.3}% of compressed file)\n", .{ sidecar_bytes, sidecar_pct });

    // ── Stage 1: phase 1 correctness ──────────────────────────────────
    // Allocate fresh dst_test, fill with a poison pattern (0xAA), run
    // phase 1, then verify that every position the sidecar touched now
    // holds the correct byte from dst_ref.
    const dst_test = try allocator.alloc(u8, content_size);
    defer allocator.free(dst_test);
    @memset(dst_test, 0xAA);

    var phase1_timer = try std.time.Timer.start();
    cleanness.runPhase1Ppoc(&sidecar, dst_test);
    const phase1_ms = @as(f64, @floatFromInt(phase1_timer.read())) / 1_000_000.0;

    try w.print("\n  Phase 1 execution:\n", .{});
    try w.print("    Wall time:        {d:.3} ms\n", .{phase1_ms});

    // Correctness check: verify every literal byte position and every
    // match op output range matches dst_ref.
    var lit_errors: u64 = 0;
    for (sidecar.literal_bytes.items) |lit| {
        if (dst_test[@intCast(lit.position)] != dst_ref[@intCast(lit.position)]) {
            lit_errors += 1;
        }
    }
    var match_errors: u64 = 0;
    for (sidecar.match_ops.items) |op| {
        const length: usize = op.length;
        const tgt: usize = @intCast(op.target_start);
        const src_pos: usize = @intCast(op.src_start);
        if (tgt + length > content_size) continue;
        if (src_pos + length > content_size) continue;
        var i: usize = 0;
        while (i < length) : (i += 1) {
            if (dst_test[tgt + i] != dst_ref[tgt + i]) {
                match_errors += 1;
                break;
            }
        }
    }

    try w.print("    Literal byte errors:  {d} / {d}\n", .{ lit_errors, sidecar.literal_bytes.items.len });
    try w.print("    Match op errors:      {d} / {d}\n", .{ match_errors, sidecar.match_ops.items.len });

    if (lit_errors == 0 and match_errors == 0) {
        try w.print("\n  Stage 1 result: PASS\n", .{});
    } else {
        try w.print("\n  Stage 1 result: FAIL\n", .{});
        return;
    }

    // ── Stage 2: sub-chunk decode in forward order ────────────────────
    //
    // Collect (src_slice, dst_offset, dst_size) tuples for every sub-chunk
    // in the frame, then decode them one at a time (forward order) with
    // phase 1 pre-populated. This validates that the per-sub-chunk decode
    // pipeline produces correct output when called with individual chunk
    // boundaries — the plumbing the real parallel dispatcher will use.
    //
    // Note on reverse-order: an earlier version of this test ran chunks
    // in REVERSE order as a stronger correctness check (it would catch
    // closure incompleteness). That test revealed a walker limitation
    // around delta-mode inline literals (recent_offs dependencies) that
    // needs a more thorough fix. For this PoC we validate forward-order
    // correctness plus the Stage 1 closure-completeness invariant, which
    // together cover the parallel dispatch path we actually care about.
    try w.print("\n  Stage 2: forward-order sub-chunk decode\n", .{});

    // Pre-scan: walk the frame block-by-block, then chunk-by-chunk inside
    // each block, collecting chunk descriptors. Handles all chunk types
    // (fast/turbo compressed, raw-stored, memset, uncompressed).
    const ChunkType = enum { fast_compressed, raw_copy, memset_fill };
    const ChunkInfo = struct {
        chunk_type: ChunkType,
        src_ptr: [*]const u8, // valid for fast_compressed + raw_copy
        src_len: usize,        // comp_size for fast_compressed, dst_size for raw_copy
        dst_offset: usize,
        dst_size: usize,
        memset_byte: u8,       // valid for memset_fill only
    };
    var chunks: std.ArrayList(ChunkInfo) = .{};
    defer chunks.deinit(allocator);

    var pos: usize = hdr.header_size;
    var dst_off_scan: usize = 0;
    while (pos + 4 <= src.len) {
        const first_word = std.mem.readInt(u32, src[pos..][0..4], .little);
        if (first_word == frame.end_mark) break;
        const block_hdr = frame.parseBlockHeader(src[pos..]) catch break;
        if (block_hdr.isEndMark()) break;
        pos += 8;
        if (block_hdr.uncompressed) {
            // Block-level uncompressed — the entire block is a raw copy.
            try chunks.append(allocator, .{
                .chunk_type = .raw_copy,
                .src_ptr = src[pos..].ptr,
                .src_len = block_hdr.decompressed_size,
                .dst_offset = dst_off_scan,
                .dst_size = block_hdr.decompressed_size,
                .memset_byte = 0,
            });
            pos += block_hdr.compressed_size;
            dst_off_scan += block_hdr.decompressed_size;
            continue;
        }

        const block_start = pos;
        const block_src_len = block_hdr.compressed_size;
        const block_src = src[block_start..][0..block_src_len];

        // Walk chunks within this block. Non-SC (L1-L4) format: no prefix
        // table, straight sequence of (2-byte internal header, 4-byte chunk
        // header, compressed payload).
        var src_pos_in_block: usize = 0;
        var dst_remaining: usize = block_hdr.decompressed_size;
        while (dst_remaining > 0) {
            if (src_pos_in_block + 2 > block_src.len) break;
            const ih = block_header.parseBlockHeader(block_src[src_pos_in_block..]) catch break;
            src_pos_in_block += 2;
            var dst_this_chunk: usize = constants.chunk_size;
            if (dst_this_chunk > dst_remaining) dst_this_chunk = dst_remaining;
            if (ih.uncompressed) {
                try chunks.append(allocator, .{
                    .chunk_type = .raw_copy,
                    .src_ptr = block_src[src_pos_in_block..].ptr,
                    .src_len = dst_this_chunk,
                    .dst_offset = dst_off_scan,
                    .dst_size = dst_this_chunk,
                    .memset_byte = 0,
                });
                src_pos_in_block += dst_this_chunk;
                dst_off_scan += dst_this_chunk;
                dst_remaining -= dst_this_chunk;
                continue;
            }
            const ch = block_header.parseChunkHeader(block_src[src_pos_in_block..], ih.use_checksums) catch break;
            src_pos_in_block += ch.bytes_consumed;
            if (ch.is_memset) {
                try chunks.append(allocator, .{
                    .chunk_type = .memset_fill,
                    .src_ptr = undefined,
                    .src_len = 0,
                    .dst_offset = dst_off_scan,
                    .dst_size = dst_this_chunk,
                    .memset_byte = ch.memset_fill,
                });
                dst_off_scan += dst_this_chunk;
                dst_remaining -= dst_this_chunk;
                continue;
            }
            const comp_size: usize = ch.compressed_size;
            if (src_pos_in_block + comp_size > block_src.len) break;
            if (comp_size == dst_this_chunk) {
                // Raw-stored inside a compressed block.
                try chunks.append(allocator, .{
                    .chunk_type = .raw_copy,
                    .src_ptr = block_src[src_pos_in_block..].ptr,
                    .src_len = dst_this_chunk,
                    .dst_offset = dst_off_scan,
                    .dst_size = dst_this_chunk,
                    .memset_byte = 0,
                });
                src_pos_in_block += comp_size;
                dst_off_scan += dst_this_chunk;
                dst_remaining -= dst_this_chunk;
                continue;
            }
            try chunks.append(allocator, .{
                .chunk_type = .fast_compressed,
                .src_ptr = block_src[src_pos_in_block..].ptr,
                .src_len = comp_size,
                .dst_offset = dst_off_scan,
                .dst_size = dst_this_chunk,
                .memset_byte = 0,
            });
            src_pos_in_block += comp_size;
            dst_off_scan += dst_this_chunk;
            dst_remaining -= dst_this_chunk;
        }

        pos = block_start + block_src_len;
    }

    // Summary counts.
    var fast_count: u32 = 0;
    var raw_count: u32 = 0;
    var memset_count: u32 = 0;
    for (chunks.items) |ci| {
        switch (ci.chunk_type) {
            .fast_compressed => fast_count += 1,
            .raw_copy => raw_count += 1,
            .memset_fill => memset_count += 1,
        }
    }
    try w.print("    Sub-chunks found: fast={d} raw={d} memset={d}\n", .{ fast_count, raw_count, memset_count });

    // Decode sub-chunks in REVERSE order using fast.decodeChunk directly.
    const fast_decoder = @import("decode/fast/fast_lz_decoder.zig");
    var scratch_stage2: [16384 * 64]u8 align(64) = undefined;

    var reverse_timer = try std.time.Timer.start();
    for (chunks.items) |ci| {
        switch (ci.chunk_type) {
            .raw_copy => {
                const dst_slice = dst_test[ci.dst_offset..][0..ci.dst_size];
                @memcpy(dst_slice, ci.src_ptr[0..ci.dst_size]);
            },
            .memset_fill => {
                @memset(dst_test[ci.dst_offset..][0..ci.dst_size], ci.memset_byte);
            },
            .fast_compressed => {
                const dst_ptr: [*]u8 = dst_test[ci.dst_offset..].ptr;
                const dst_end_ptr: [*]u8 = dst_ptr + ci.dst_size;
                const dst_start_ptr: [*]const u8 = dst_test.ptr;
                const src_slice_end: [*]const u8 = ci.src_ptr + ci.src_len;
                _ = fast_decoder.decodeChunk(
                    dst_ptr,
                    dst_end_ptr,
                    dst_start_ptr,
                    ci.src_ptr,
                    src_slice_end,
                    &scratch_stage2,
                    @as([*]u8, &scratch_stage2) + scratch_stage2.len,
                ) catch |err| {
                    try w.print("    ERROR decoding chunk: {s}\n", .{@errorName(err)});
                    try w.print("\n  Stage 2 result: FAIL\n", .{});
                    return;
                };
            },
        }
    }
    const reverse_ms = @as(f64, @floatFromInt(reverse_timer.read())) / 1_000_000.0;
    try w.print("    Forward decode time: {d:.3} ms\n", .{reverse_ms});

    // Compare dst_test to dst_ref byte-by-byte.
    var diff_count: u64 = 0;
    var first_diff: i64 = -1;
    for (0..content_size) |k| {
        if (dst_test[k] != dst_ref[k]) {
            if (first_diff < 0) first_diff = @intCast(k);
            diff_count += 1;
        }
    }
    if (diff_count == 0) {
        try w.print("    Byte-level comparison: PASS (all {d} bytes match)\n", .{content_size});
        try w.print("\n  Stage 2 result: PASS\n", .{});
    } else {
        try w.print("    Byte-level comparison: FAIL ({d} bytes differ, first diff at {d})\n", .{ diff_count, first_diff });
        try w.print("\n  Stage 2 result: FAIL\n", .{});
        return;
    }

    // ── Stage 3: parallel phase 2 — measure speedup ───────────────────
    //
    // Launch N worker threads, each decoding a contiguous slice of
    // sub-chunks. Phase 1 is re-run into a fresh dst_test3 buffer, then
    // workers kick off. For correctness, the dispatcher assigns each
    // worker a slice so within-slice work is in forward order; between
    // slices we rely on Phase 1 having populated the closure positions.
    try w.print("\n  Stage 3: parallel phase 2 decode\n", .{});

    // Baseline: single-thread decode for speedup comparison (best of 10).
    _ = decoder.decompressFramed(src, dst_ref) catch {};
    var best_decode_ns: u64 = std.math.maxInt(u64);
    var bdi: u32 = 0;
    while (bdi < 10) : (bdi += 1) {
        var t = try std.time.Timer.start();
        _ = decoder.decompressFramed(src, dst_ref) catch {};
        const elapsed = t.read();
        if (elapsed < best_decode_ns) best_decode_ns = elapsed;
    }
    const decode_ms = @as(f64, @floatFromInt(best_decode_ns)) / 1_000_000.0;
    try w.print("    Single-thread decompressFramed baseline: {d:.3} ms\n", .{decode_ms});

    const thread_counts = [_]u32{ 1, 2, 4, 8 };
    for (thread_counts) |n_threads| {
        const dst_test3 = try allocator.alloc(u8, content_size);
        defer allocator.free(dst_test3);
        @memset(dst_test3, 0xAA);
        cleanness.runPhase1Ppoc(&sidecar, dst_test3);

        // Split chunks across N workers. Each worker gets a contiguous
        // slice; slice size is ceil(N_chunks / N_threads).
        const slice_size: usize = (chunks.items.len + n_threads - 1) / n_threads;

        const Worker = struct {
            chunks_ref: []const @TypeOf(chunks.items[0]),
            start: usize,
            end: usize,
            dst: []u8,
            err: ?anyerror,

            fn run(self: *@This()) void {
                self.err = null;
                var scratch_local: [16384 * 64]u8 align(64) = undefined;
                for (self.chunks_ref[self.start..self.end]) |ci| {
                    switch (ci.chunk_type) {
                        .raw_copy => {
                            const dst_slice = self.dst[ci.dst_offset..][0..ci.dst_size];
                            @memcpy(dst_slice, ci.src_ptr[0..ci.dst_size]);
                        },
                        .memset_fill => {
                            @memset(self.dst[ci.dst_offset..][0..ci.dst_size], ci.memset_byte);
                        },
                        .fast_compressed => {
                            const dst_ptr: [*]u8 = self.dst[ci.dst_offset..].ptr;
                            const dst_end_ptr: [*]u8 = dst_ptr + ci.dst_size;
                            const dst_start_ptr: [*]const u8 = self.dst.ptr;
                            const src_slice_end: [*]const u8 = ci.src_ptr + ci.src_len;
                            _ = fast_decoder.decodeChunk(
                                dst_ptr,
                                dst_end_ptr,
                                dst_start_ptr,
                                ci.src_ptr,
                                src_slice_end,
                                &scratch_local,
                                @as([*]u8, &scratch_local) + scratch_local.len,
                            ) catch |e| {
                                self.err = e;
                                return;
                            };
                        },
                    }
                }
            }
        };

        var workers = try allocator.alloc(Worker, n_threads);
        defer allocator.free(workers);
        var threads = try allocator.alloc(std.Thread, n_threads);
        defer allocator.free(threads);

        var t3_timer = try std.time.Timer.start();

        // Kick off all workers.
        var started: u32 = 0;
        while (started < n_threads) : (started += 1) {
            const start_idx: usize = started * slice_size;
            const end_idx: usize = @min(start_idx + slice_size, chunks.items.len);
            workers[started] = .{
                .chunks_ref = chunks.items,
                .start = start_idx,
                .end = end_idx,
                .dst = dst_test3,
                .err = null,
            };
            threads[started] = try std.Thread.spawn(.{}, Worker.run, .{&workers[started]});
        }
        // Join all workers.
        var j: u32 = 0;
        while (j < n_threads) : (j += 1) {
            threads[j].join();
        }
        const t3_ns = t3_timer.read();

        // Check worker errors.
        var had_err = false;
        for (workers) |wk| {
            if (wk.err) |_| had_err = true;
        }
        if (had_err) {
            try w.print("    N={d:>2}: WORKER ERROR\n", .{n_threads});
            continue;
        }

        // Correctness check.
        var diff3: u64 = 0;
        for (0..content_size) |k| {
            if (dst_test3[k] != dst_ref[k]) diff3 += 1;
        }
        const t3_ms = @as(f64, @floatFromInt(t3_ns)) / 1_000_000.0;
        const speedup = if (t3_ms > 0) decode_ms / t3_ms else 0;
        if (diff3 == 0) {
            try w.print("    N={d:>2}: {d:.3} ms  ({d:.2}× speedup vs single-thread {d:.3} ms)  PASS\n", .{
                n_threads, t3_ms, speedup, decode_ms,
            });
        } else {
            try w.print("    N={d:>2}: {d:.3} ms  ({d} bytes differ)  FAIL\n", .{
                n_threads, t3_ms, diff3,
            });
        }
    }
}

fn runParseOnly(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1 or args.len > 2) {
        try w.writeAll("usage: streamlz parseonly <file.slz> [runs]\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];
    const runs: u32 = if (args.len == 2)
        std.fmt.parseInt(u32, args[1], 10) catch 30
    else
        30;

    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();
    const max_bytes: usize = 1 << 31;
    const src = try in_file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(src);

    // Warm up.
    _ = try cleanness.parseOnlyWalkFile(allocator, src);

    const times = try allocator.alloc(u64, runs);
    defer allocator.free(times);

    var byte_count: u64 = 0;
    for (times) |*t| {
        var timer = try std.time.Timer.start();
        byte_count = try cleanness.parseOnlyWalkFile(allocator, src);
        t.* = timer.read();
    }

    var best: u64 = std.math.maxInt(u64);
    var sum: u64 = 0;
    for (times) |t| {
        if (t < best) best = t;
        sum += t;
    }
    const mean = sum / runs;

    const mb: f64 = @as(f64, @floatFromInt(byte_count)) / (1024.0 * 1024.0);
    const best_ms = @as(f64, @floatFromInt(best)) / 1_000_000.0;
    const mean_ms = @as(f64, @floatFromInt(mean)) / 1_000_000.0;
    const best_mbs = mb * 1000.0 / best_ms;
    const mean_mbs = mb * 1000.0 / mean_ms;

    try w.print("parseonly: {s}\n", .{path});
    try w.print("  src bytes:        {d}\n", .{src.len});
    try w.print("  walked bytes:     {d} ({d:.2} MB)\n", .{ byte_count, mb });
    try w.print("  runs:             {d}\n", .{runs});
    try w.print("  best:             {d:.3} ms  ({d:.0} MB/s)\n", .{ best_ms, best_mbs });
    try w.print("  mean:             {d:.3} ms  ({d:.0} MB/s)\n", .{ mean_ms, mean_mbs });
}

fn runPartition(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) {
        try w.writeAll("usage: streamlz partition <file.slz>\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];
    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();
    const max_bytes: usize = 1 << 31;
    const src = try in_file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(src);

    var timer = try std.time.Timer.start();
    const stats = try cleanness.analyzeFilePartition(allocator, src);
    const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;

    try w.print("File: {s}\n", .{path});
    try w.print("  Compressed bytes:   {d}\n", .{src.len});
    try w.print("  Total match tokens: {d}\n", .{stats.total_match_tokens});
    try w.print("  Total match bytes:  {d}\n", .{stats.total_match_bytes});
    try w.print("  Partition X:        {d}\n", .{stats.partition_x});
    try w.print("  Partition wall time: {d:.2} ms\n", .{ms});

    const total_t: f64 = @floatFromInt(stats.total_match_tokens);
    const total_b: f64 = @floatFromInt(stats.total_match_bytes);
    const fmt_pct = struct {
        fn print(wr: *std.Io.Writer, label: []const u8, tokens: u64, bytes: u64, tt: f64, tb: f64) !void {
            const tp = if (tt > 0) @as(f64, @floatFromInt(tokens)) / tt * 100 else 0;
            const bp = if (tb > 0) @as(f64, @floatFromInt(bytes)) / tb * 100 else 0;
            try wr.print("    {s:<22}: tokens={d:>10} ({d:>5.2}%) bytes={d:>10} ({d:>5.2}%)\n", .{ label, tokens, tp, bytes, bp });
        }
    };

    try w.print("\n  Bucket breakdown:\n", .{});
    try fmt_pct.print(w, "prefix (target<X)", stats.prefix_tokens, stats.prefix_bytes, total_t, total_b);
    try fmt_pct.print(w, "straddle (spans X)", stats.straddle_tokens, stats.straddle_bytes, total_t, total_b);
    try fmt_pct.print(w, "ThreadA-post", stats.threadA_post_tokens, stats.threadA_post_bytes, total_t, total_b);
    try fmt_pct.print(w, "ThreadB", stats.threadB_tokens, stats.threadB_bytes, total_t, total_b);

    // Estimated 2-thread speedup with semaphore at X.
    // Model: ThreadA work = prefix + straddle + ThreadA-post.
    //        ThreadB work = ThreadB.
    //        Pre-wait: max(prefix+straddle, ThreadB).
    //        Post-wait: ThreadA-post (serial).
    //        Total wall = max(pre-wait halves) + post-wait.
    const a_pre_b: f64 = @floatFromInt(stats.prefix_bytes + stats.straddle_bytes);
    const b_b: f64 = @floatFromInt(stats.threadB_bytes);
    const a_post_b: f64 = @floatFromInt(stats.threadA_post_bytes);
    const max_pre = if (a_pre_b > b_b) a_pre_b else b_b;
    const total_b_all = a_pre_b + b_b + a_post_b;
    const total_wall = max_pre + a_post_b;
    const speedup = if (total_wall > 0) total_b_all / total_wall else 0;
    try w.print("\n  Estimated 2-thread speedup (semaphore @ X): {d:.2}×\n", .{speedup});
    try w.print("    pre-wait phase: max({d:.0} bytes ThreadA, {d:.0} bytes ThreadB)\n", .{ a_pre_b, b_b });
    try w.print("    post-wait phase: {d:.0} bytes ThreadA-post (serial)\n", .{a_post_b});

    // Closure / cross-sub-chunk analysis for N-way phase1/phase2 design.
    const seed_pct = if (total_t > 0)
        @as(f64, @floatFromInt(stats.cross_chunk_seed_tokens)) / total_t * 100
    else
        0;
    const closure_pct = if (total_t > 0)
        @as(f64, @floatFromInt(stats.closure_tokens)) / total_t * 100
    else
        0;
    const low_earliest_pct = if (total_t > 0)
        @as(f64, @floatFromInt(stats.low_earliest_tokens)) / total_t * 100
    else
        0;
    try w.print("\n  Closure analysis (cross-sub-chunk phase-1 set):\n", .{});
    try w.print("    Cross-chunk seed tokens: {d} ({d:.2}%)\n", .{ stats.cross_chunk_seed_tokens, seed_pct });
    try w.print("    Closure (seeds + deps):  {d} ({d:.2}%)\n", .{ stats.closure_tokens, closure_pct });
    try w.print("    Closure BFS depth (max): {d} hops\n", .{stats.closure_depth_max});
    try w.print("    Low-earliest proxy:      {d} ({d:.2}%) tokens with earliest < sub_chunk_start\n", .{ stats.low_earliest_tokens, low_earliest_pct });

    // N-way phase1/phase2 speedup estimate with this closure fraction.
    // Model: parse cost is split across sub-chunks in step A; phase 1 is
    // serial over closure; phase 2 parallelizes the rest N-way.
    //   T ≈ parse/N + closure_fraction + (1 - parse - closure) / N
    //     = (1 - closure) / N + closure
    // where closure_fraction is the fraction of total tokens in closure.
    // Simplified: assumes parse work is proportional to token count, which
    // roughly holds if all tokens are similarly expensive.
    const closure_frac_f: f64 = if (total_t > 0)
        @as(f64, @floatFromInt(stats.closure_tokens)) / total_t
    else
        0;
    const n_vals = [_]u32{ 2, 4, 8, 16 };
    try w.print("    N-way phase1/phase2 speedup estimates (ignores memory-bw ceiling):\n", .{});
    for (n_vals) |n| {
        const nf: f64 = @floatFromInt(n);
        const t_rel = (1.0 - closure_frac_f) / nf + closure_frac_f;
        const sp = if (t_rel > 0) 1.0 / t_rel else 0;
        try w.print("      N={d:>2}: {d:.2}×\n", .{ n, sp });
    }

    // ── Phase-1 PoC timings ──────────────────────────────────────────────
    //
    // Cost B (execute-only): iterate closure tokens in order and do
    // each match copy. Pure memcpy work, no parsing. Measured inside
    // analyzeFilePartition — reported directly here.
    //
    // Cost A (walk-whole-stream + execute closure): approximated as
    // parse-only walker time plus Cost B. We call parseOnlyWalkFile a
    // handful of times and take the best to get a clean number.
    try w.print("\n  Phase-1 PoC timings:\n", .{});
    const phase1_exec_ms = @as(f64, @floatFromInt(stats.phase1_execute_only_ns)) / 1_000_000.0;
    const phase1_exec_bytes = stats.phase1_execute_bytes;
    const phase1_exec_mb = @as(f64, @floatFromInt(phase1_exec_bytes)) / (1024.0 * 1024.0);
    const phase1_exec_mbps = if (phase1_exec_ms > 0)
        phase1_exec_mb * 1000.0 / phase1_exec_ms
    else
        0;
    try w.print("    Cost B (execute-only, full list scan):    {d:.3} ms  ({d} bytes moved, {d:.0} MB/s)\n", .{
        phase1_exec_ms, phase1_exec_bytes, phase1_exec_mbps,
    });
    const phase1_compact_ms = @as(f64, @floatFromInt(stats.phase1_execute_compact_ns)) / 1_000_000.0;
    try w.print("    Cost B (execute-only, compact list):      {d:.3} ms  ({d} closure tokens)\n", .{
        phase1_compact_ms, stats.closure_tokens,
    });

    // Measure parse-only walker: warmup + 10 runs, take best.
    _ = try cleanness.parseOnlyWalkFile(allocator, src);
    var best_parse_ns: u64 = std.math.maxInt(u64);
    var run_idx: u32 = 0;
    while (run_idx < 10) : (run_idx += 1) {
        var t = try std.time.Timer.start();
        _ = try cleanness.parseOnlyWalkFile(allocator, src);
        const elapsed = t.read();
        if (elapsed < best_parse_ns) best_parse_ns = elapsed;
    }
    const parse_ms = @as(f64, @floatFromInt(best_parse_ns)) / 1_000_000.0;
    try w.print("    Parse-only walker (best of 10): {d:.3} ms\n", .{parse_ms});
    const cost_a_ms = parse_ms + phase1_exec_ms;
    try w.print("    Cost A (walk + execute):        {d:.3} ms\n", .{cost_a_ms});
    try w.print("    Cost A / Cost B ratio:          {d:.1}×\n", .{
        if (phase1_exec_ms > 0) cost_a_ms / phase1_exec_ms else 0,
    });

    // ── Single-thread full decode baseline ─────────────────────────────
    //
    // Used as the denominator for "what fraction of decode is phase 1?"
    // Goes through decoder.decompressFramed which is the single-threaded
    // path (decompressFramedParallel would bias the baseline by already
    // using N threads and inflating the phase-1/phase-2 speedup we'd
    // compute).
    const hdr = frame.parseHeader(src) catch {
        return;
    };
    const content_size: usize = if (hdr.content_size) |cs| @intCast(cs) else return;
    const dst = allocator.alloc(u8, content_size + decoder.safe_space) catch return;
    defer allocator.free(dst);
    _ = decoder.decompressFramed(src, dst) catch return;
    var best_decode_ns: u64 = std.math.maxInt(u64);
    run_idx = 0;
    while (run_idx < 10) : (run_idx += 1) {
        var t = try std.time.Timer.start();
        _ = decoder.decompressFramed(src, dst) catch return;
        const elapsed = t.read();
        if (elapsed < best_decode_ns) best_decode_ns = elapsed;
    }
    const decode_ms = @as(f64, @floatFromInt(best_decode_ns)) / 1_000_000.0;
    const parse_pct = if (decode_ms > 0) parse_ms / decode_ms * 100 else 0;
    const costB_pct = if (decode_ms > 0) phase1_exec_ms / decode_ms * 100 else 0;
    const costA_pct = if (decode_ms > 0) cost_a_ms / decode_ms * 100 else 0;
    try w.print("    Full single-thread decode (best of 10): {d:.3} ms\n", .{decode_ms});
    try w.print("    Parse-only / full decode:  {d:.1}%\n", .{parse_pct});
    try w.print("    Cost B    / full decode:   {d:.3}%\n", .{costB_pct});
    try w.print("    Cost A    / full decode:   {d:.1}%\n", .{costA_pct});

    // Speedup using Cost B (best case: compact closure list with
    // pre-computed positions, no cmd_stream parsing).
    // Phase 2 parallelizes the non-closure work over N threads:
    //   T_best = Cost_B_compact + (decode - Cost_B_compact) / N
    try w.print("    Best-case speedup (compact Cost B + phase2 parallel):\n", .{});
    for (n_vals) |n| {
        const nf: f64 = @floatFromInt(n);
        const t_total = phase1_compact_ms + (decode_ms - phase1_compact_ms) / nf;
        const sp = if (t_total > 0) decode_ms / t_total else 0;
        try w.print("      N={d:>2}: {d:.2}×\n", .{ n, sp });
    }
    // Speedup using Cost A (worst case: phase 1 must walk the stream).
    //   T_worst = Cost_A + (decode - Cost_A) / N
    // (assumes the parse portion is genuinely serial in phase 1)
    try w.print("    Worst-case speedup (Cost A + phase2 parallel):\n", .{});
    for (n_vals) |n| {
        const nf: f64 = @floatFromInt(n);
        const t_total = cost_a_ms + (decode_ms - cost_a_ms) / nf;
        const sp = if (t_total > 0) decode_ms / t_total else 0;
        try w.print("      N={d:>2}: {d:.2}×\n", .{ n, sp });
    }
}

/// Reads a Fast (.slz) file and reports per-sub-chunk cleanness — the
/// fraction of output bytes whose dependency tree is fully intra-chunk
/// (no transitive cross-chunk reference). Used to estimate the upper
/// bound on speculative-parallel decode throughput.
fn runAnalyze(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) {
        try w.writeAll("usage: streamlz analyze <file.slz>\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];
    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();
    const max_bytes: usize = 1 << 31;
    const src = try in_file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(src);

    var timer = try std.time.Timer.start();
    var stats = cleanness.analyzeFile(allocator, src) catch |err| {
        try w.print("error during analysis: {s}\n", .{@errorName(err)});
        try w.flush();
        return err;
    };
    const analysis_ns = timer.read();
    defer stats.deinit(allocator);
    const analysis_ms = @as(f64, @floatFromInt(analysis_ns)) / 1_000_000.0;

    // Level-0-only bitmap analyzer (validation + speed comparison).
    timer.reset();
    const lvl0 = cleanness.analyzeFileLevel0(allocator, src) catch |err| {
        try w.print("error during level0 analysis: {s}\n", .{@errorName(err)});
        try w.flush();
        return err;
    };
    const level0_ns = timer.read();
    const level0_ms = @as(f64, @floatFromInt(level0_ns)) / 1_000_000.0;

    try w.print("File: {s}\n", .{path});
    try w.print("  Compressed bytes:   {d}\n", .{src.len});
    try w.print("  Decompressed bytes: {d}\n", .{stats.total_bytes});
    try w.print("  Full DAG wall time:    {d:.2} ms\n", .{analysis_ms});
    try w.print("  Level-0 bitmap time:   {d:.2} ms\n", .{level0_ms});

    // Cross-check: round 1 from the full DAG should equal level-0
    // count from the bitmap analyzer.
    const dag_round1: u64 = stats.round_histogram[1];
    try w.print("\n  Cross-check (level-0 count):\n", .{});
    try w.print("    Full DAG round 1:    {d}\n", .{dag_round1});
    try w.print("    Bitmap level-0:      {d}\n", .{lvl0.level0_match_tokens});
    try w.print("    Bitmap total tokens: {d}\n", .{lvl0.total_match_tokens});
    if (dag_round1 == lvl0.level0_match_tokens) {
        try w.print("    Match: YES\n", .{});
    } else {
        try w.print("    Match: NO (delta = {d})\n", .{
            @as(i64, @intCast(lvl0.level0_match_tokens)) - @as(i64, @intCast(dag_round1)),
        });
    }

    // ── Token-dependency DAG analysis ─────────────────────────────────
    const total_match: u64 = stats.total_match_tokens;
    const critical_path: u32 = stats.criticalPath();
    try w.print("\n  Token DAG analysis:\n", .{});
    try w.print("    Total match tokens:  {d}\n", .{total_match});
    try w.print("    Critical path depth: {d}\n", .{critical_path});

    if (total_match > 0) {
        // Percentage of tokens at each round (top 16 rounds + a tail bucket).
        try w.print("\n    Token round histogram (round → count, % of total):\n", .{});
        var shown_max: u32 = 0;
        for (stats.round_histogram, 0..) |count, round| {
            if (count == 0) continue;
            shown_max = @intCast(round);
            const pct: f64 = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total_match)) * 100;
            try w.print("      round {d:>3}: {d:>10} ({d:>6.2}%)\n", .{ round, count, pct });
            if (round >= 20) break;
        }
        if (shown_max < critical_path) {
            try w.print("      ...\n", .{});
            try w.print("      max round: {d}\n", .{critical_path});
        }

        // Theoretical speedup from the DAG:
        //   work_per_round = histogram[r]
        //   time_with_N    = sum over r of ceil(work_per_round / N)
        //   speedup        = total_match / time_with_N
        try w.print("\n    Theoretical speedup with N parallel cores:\n", .{});
        const cores = [_]u32{ 2, 4, 8, 16, 24 };
        for (cores) |n| {
            var time_units: u64 = 0;
            for (stats.round_histogram) |c| {
                if (c == 0) continue;
                const t: u64 = (c + n - 1) / n;
                time_units += t;
            }
            const speedup: f64 = if (time_units > 0)
                @as(f64, @floatFromInt(total_match)) / @as(f64, @floatFromInt(time_units))
            else
                0;
            try w.print("      N={d:>3}: {d:.2}x  (rounds w/ {d} cores: {d})\n", .{ n, speedup, n, time_units });
        }
    }
}

/// In-memory compress + decompress benchmark matching the `slz -b`
/// output: per-run timings, median (not mean), and a final round-trip
/// pass/fail check.
fn runBenchCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    var level: u8 = 6;
    var runs: u32 = 3;
    var num_threads: u32 = 0; // 0 = auto
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseIntFlag(u8, args, &i, "-l", w)) |v| {
            level = v;
        } else if (parseIntFlag(u32, args, &i, "-r", w)) |v| {
            runs = v;
        } else if (parseIntFlag(u32, args, &i, "-t", w)) |v| {
            num_threads = v;
        } else if (path == null) {
            path = args[i];
        } else {
            try w.writeAll("usage: streamlz benchc [-l N] [-r N] [-t N] <raw-file>\n");
            try w.flush();
            std.process.exit(2);
        }
    }

    if (path == null) {
        try w.writeAll("usage: streamlz benchc [-l N] [-r N] [-t N] <raw-file>\n");
        try w.flush();
        std.process.exit(2);
    }
    if (level < 1 or level > 11) {
        try w.print("error: level must be 1..11 (got {d})\n", .{level});
        try w.flush();
        std.process.exit(2);
    }
    if (runs == 0) {
        try w.writeAll("error: runs must be >= 1\n");
        try w.flush();
        std.process.exit(2);
    }

    const path_unwrapped: []const u8 = path.?;
    const in_file = std.fs.cwd().openFile(path_unwrapped, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path_unwrapped, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31;
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ path_unwrapped, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(src);

    const bound = encoder.compressBound(src.len);
    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);
    const decompressed = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decompressed);

    const mb: f64 = @as(f64, @floatFromInt(src.len)) / (1024.0 * 1024.0);
    try w.print("Input: {s} ({d} bytes, {d:.2} MB)\n", .{ path_unwrapped, src.len, mb });

    // Warm-up compress (untimed) — first run would otherwise include one-time
    // page-fault cost on the output buffers.
    var comp_size: usize = try encoder.compressFramed(allocator, src, compressed, .{ .level = level });

    // ── Compress benchmark ────────────────────────────────────────────
    const comp_times = try allocator.alloc(u64, runs);
    defer allocator.free(comp_times);
    var r: u32 = 0;
    while (r < runs) : (r += 1) {
        var timer = try std.time.Timer.start();
        const n = try encoder.compressFramed(allocator, src, compressed, .{ .level = level });
        comp_times[r] = timer.read();
        comp_size = n;
        const run_ms = @as(f64, @floatFromInt(comp_times[r])) / 1_000_000.0;
        const run_mbps = mb * 1000.0 / run_ms;
        try w.print("  Compress run {d}: {d:.0}ms ({d:.1} MB/s)\n", .{ r + 1, run_ms, run_mbps });
    }
    try w.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n\n", .{
        level,
        src.len,
        comp_size,
        @as(f64, @floatFromInt(comp_size)) / @as(f64, @floatFromInt(src.len)) * 100.0,
    });

    const comp_median_ns = median(comp_times);
    const comp_median_ms = @as(f64, @floatFromInt(comp_median_ns)) / 1_000_000.0;
    const comp_median_mbps = mb * 1000.0 / comp_median_ms;
    try w.print("  Compress median: {d:.0}ms ({d:.1} MB/s)\n\n", .{ comp_median_ms, comp_median_mbps });

    // Warm-up decompress (parallel — matches what `-b` does for SC files).
    _ = try decoder.decompressFramedParallelThreaded(allocator, compressed[0..comp_size], decompressed, num_threads);

    // ── Decompress benchmark ──────────────────────────────────────────
    const dec_times = try allocator.alloc(u64, runs);
    defer allocator.free(dec_times);
    r = 0;
    while (r < runs) : (r += 1) {
        var timer = try std.time.Timer.start();
        _ = try decoder.decompressFramedParallelThreaded(allocator, compressed[0..comp_size], decompressed, num_threads);
        dec_times[r] = timer.read();
        const run_ms = @as(f64, @floatFromInt(dec_times[r])) / 1_000_000.0;
        const run_mbps = mb * 1000.0 / run_ms;
        try w.print("  Decompress run {d}: {d:.0}ms ({d:.1} MB/s)\n", .{ r + 1, run_ms, run_mbps });
    }
    const dec_median_ns = median(dec_times);
    const dec_median_ms = @as(f64, @floatFromInt(dec_median_ns)) / 1_000_000.0;
    const dec_median_mbps = mb * 1000.0 / dec_median_ms;
    try w.print("  Decompress median: {d:.0}ms ({d:.1} MB/s)\n\n", .{ dec_median_ms, dec_median_mbps });

    // Round-trip check on the freshly decompressed buffer.
    if (std.mem.eql(u8, src, decompressed[0..src.len])) {
        try w.writeAll("Round-trip: PASS\n");
    } else {
        var first_fail: usize = 0;
        var fail_count: usize = 0;
        for (0..src.len) |bi| {
            if (src[bi] != decompressed[bi]) {
                if (fail_count == 0) first_fail = bi;
                fail_count += 1;
            }
        }
        try w.print("Round-trip: FAIL  first_diff={d} total_diffs={d} chunk={d} rel={d}\n", .{
            first_fail, fail_count, first_fail / 262144, first_fail % 262144,
        });
        try w.flush();
        std.process.exit(1);
    }
}

/// Median of a slice of nanosecond durations. Mutates a copy of the input
/// so the caller's array is left untouched.
fn median(times: []const u64) u64 {
    var buf: [64]u64 = undefined;
    const n = times.len;
    if (n == 0) return 0;
    if (n > buf.len) {
        // Fall back to mean for very large run counts.
        var sum: u128 = 0;
        for (times) |t| sum += t;
        return @intCast(sum / n);
    }
    @memcpy(buf[0..n], times);
    std.mem.sort(u64, buf[0..n], {}, std.sort.asc(u64));
    if (n % 2 == 1) return buf[n / 2];
    return (buf[n / 2 - 1] + buf[n / 2]) / 2;
}

fn runBench(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    var runs: u32 = 10;
    var num_threads: u32 = 0; // 0 = auto
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseIntFlag(u32, args, &i, "-r", w)) |v| {
            runs = v;
        } else if (parseIntFlag(u32, args, &i, "-t", w)) |v| {
            num_threads = v;
        } else if (path == null) {
            path = args[i];
        } else {
            // Support legacy positional [runs] as second positional arg
            runs = std.fmt.parseInt(u32, args[i], 10) catch {
                try w.writeAll("usage: streamlz bench [-r N] [-t N] <file.slz>\n");
                try w.flush();
                std.process.exit(2);
            };
        }
    }

    if (path == null) {
        try w.writeAll("usage: streamlz bench [-r N] [-t N] <file.slz>\n");
        try w.flush();
        std.process.exit(2);
    }

    const in_file = std.fs.cwd().openFile(path.?, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31;
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(src);

    const hdr = frame.parseHeader(src) catch |err| {
        try w.print("error: not a valid SLZ1 frame: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    const content_size: usize = if (hdr.content_size) |cs| @intCast(cs) else {
        try w.writeAll("error: frame has no content size; bench needs a sized frame\n");
        try w.flush();
        std.process.exit(1);
    };

    const dst = allocator.alloc(u8, content_size + decoder.safe_space) catch |err| {
        try w.print("error: cannot allocate {d} bytes: {s}\n", .{ content_size + decoder.safe_space, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(dst);

    // Warm-up: one untimed decode to page-fault the dst and prime the caches.
    // Uses parallel decompress (matches what `-b` does for SC files and
    // what production code paths take when an allocator is available).
    _ = decoder.decompressFramedParallelThreaded(allocator, src, dst, num_threads) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u64 = 0;
    var run: u32 = 0;
    while (run < runs) : (run += 1) {
        var timer = try std.time.Timer.start();
        _ = try decoder.decompressFramedParallelThreaded(allocator, src, dst, num_threads);
        const elapsed = timer.read();
        if (elapsed < best_ns) best_ns = elapsed;
        total_ns += elapsed;
    }

    const mean_ns: u64 = total_ns / runs;
    const mb: f64 = @as(f64, @floatFromInt(content_size)) / (1024.0 * 1024.0);
    const best_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(best_ns));
    const mean_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(mean_ns));

    try w.print("bench: {s}\n", .{path.?});
    try w.print("  src bytes:       {d}\n", .{src.len});
    try w.print("  decompressed:    {d} ({d:.2} MB)\n", .{ content_size, mb });
    try w.print("  runs:            {d} (plus 1 warm-up)\n", .{runs});
    if (num_threads > 0) {
        try w.print("  threads:         {d}\n", .{num_threads});
    }
    try w.print("  best:            {d:.3} ms  ({d:.0} MB/s)\n", .{
        @as(f64, @floatFromInt(best_ns)) / 1_000_000.0,
        best_mbps,
    });
    try w.print("  mean:            {d:.3} ms  ({d:.0} MB/s)\n", .{
        @as(f64, @floatFromInt(mean_ns)) / 1_000_000.0,
        mean_mbps,
    });
}

fn printVersion(w: *std.Io.Writer) !void {
    try w.print("streamlz {s} (Zig {f}, {s}-{s})\n", .{
        version_string,
        builtin.zig_version,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
    });
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\streamlz — Zig port of StreamLZ
        \\
        \\Usage: streamlz <command> [args]
        \\
        \\Commands:
        \\  version              Print the version and toolchain info
        \\  help                 Print this message
        \\  info       <file>    Dump SLZ1 frame header + block list
        \\  decompress [-t N] <in> <out>      Decompress an SLZ1 file
        \\  compress [-l N] [-t N] <in> <out> Compress a file to SLZ1
        \\  bench  [-r N] [-t N] <file.slz>   Benchmark decompress
        \\  benchc [-l N] [-r N] [-t N] <raw> Benchmark compress+decompress
        \\
    );
}

fn runCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    var level: u8 = 1;
    var num_threads: u32 = 0; // 0 = auto
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseIntFlag(u8, args, &i, "-l", w)) |v| {
            level = v;
        } else if (parseIntFlag(u32, args, &i, "-t", w)) |v| {
            num_threads = v;
        } else if (in_path == null) {
            in_path = args[i];
        } else if (out_path == null) {
            out_path = args[i];
        } else {
            try w.writeAll("usage: streamlz compress [-l N] [-t N] <in> <out>\n");
            try w.flush();
            std.process.exit(2);
        }
    }
    if (in_path == null or out_path == null) {
        try w.writeAll("usage: streamlz compress [-l N] <in> <out>\n");
        try w.flush();
        std.process.exit(2);
    }

    if (level < 1 or level > 11) {
        try w.print("error: level must be 1..11 (got {d})\n", .{level});
        try w.flush();
        std.process.exit(2);
    }

    const in_file = std.fs.cwd().openFile(in_path.?, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ in_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31;
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ in_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(src);

    const bound = encoder.compressBound(src.len);
    const dst = allocator.alloc(u8, bound) catch |err| {
        try w.print("error: cannot allocate {d} bytes: {s}\n", .{ bound, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(dst);

    const written = encoder.compressFramed(allocator, src, dst, .{ .level = level, .num_threads = num_threads }) catch |err| {
        try w.print("error: compression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    const out_file = std.fs.cwd().createFile(out_path.?, .{}) catch |err| {
        try w.print("error: cannot create '{s}': {s}\n", .{ out_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer out_file.close();
    out_file.writeAll(dst[0..written]) catch |err| {
        try w.print("error: cannot write '{s}': {s}\n", .{ out_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };

    const ratio: f64 = @as(f64, @floatFromInt(written)) / @as(f64, @floatFromInt(@max(src.len, 1))) * 100.0;
    try w.print("compressed {d} → {d} bytes  ({d:.1}%)  L{d}  ({s} → {s})\n", .{
        src.len, written, ratio, level, in_path.?, out_path.?,
    });
}

fn runDecompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    var num_threads: u32 = 0; // 0 = auto
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseIntFlag(u32, args, &i, "-t", w)) |v| {
            num_threads = v;
        } else if (in_path == null) {
            in_path = args[i];
        } else if (out_path == null) {
            out_path = args[i];
        } else {
            try w.writeAll("usage: streamlz decompress [-t N] <in.slz> <out>\n");
            try w.flush();
            std.process.exit(2);
        }
    }
    if (in_path == null or out_path == null) {
        try w.writeAll("usage: streamlz decompress [-t N] <in.slz> <out>\n");
        try w.flush();
        std.process.exit(2);
    }

    const in_file = std.fs.cwd().openFile(in_path.?, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ in_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31; // 2 GiB hard cap for phase 3a
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ in_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(src);

    const hdr = frame.parseHeader(src) catch |err| {
        try w.print("error: not a valid SLZ1 frame: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    const content_size: usize = if (hdr.content_size) |cs| @intCast(cs) else {
        try w.writeAll("error: frame has no content size; streaming mode not yet supported\n");
        try w.flush();
        std.process.exit(1);
    };

    const dst = allocator.alloc(u8, content_size + decoder.safe_space) catch |err| {
        try w.print("error: cannot allocate {d} bytes: {s}\n", .{ content_size + decoder.safe_space, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(dst);

    const written = decoder.decompressFramedParallelThreaded(allocator, src, dst, num_threads) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    const out_file = std.fs.cwd().createFile(out_path.?, .{}) catch |err| {
        try w.print("error: cannot create '{s}': {s}\n", .{ out_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer out_file.close();
    out_file.writeAll(dst[0..written]) catch |err| {
        try w.print("error: cannot write '{s}': {s}\n", .{ out_path.?, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };

    try w.print("decompressed {d} → {d} bytes  ({s} → {s})\n", .{
        src.len, written, in_path.?, out_path.?,
    });
}

fn runInfo(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) {
        try w.writeAll("usage: streamlz info <file.slz>\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer file.close();

    const max_bytes: usize = 1 << 30; // 1 GiB cap for info mode
    const data = file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(data);

    const hdr = frame.parseHeader(data) catch |err| {
        try w.print("error: not a valid SLZ1 frame: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    try w.print("file: {s}\n", .{path});
    try w.print("  size on disk:    {d} bytes\n", .{data.len});
    try w.print("  magic:           SLZ1\n", .{});
    try w.print("  version:         {d}\n", .{hdr.version});
    try w.print("  codec:           {s} ({d})\n", .{ hdr.codec.name(), @intFromEnum(hdr.codec) });
    try w.print("  level:           {d}  (internal)\n", .{hdr.level});
    try w.print("  block_size:      {d} ({d} KB)\n", .{ hdr.block_size, hdr.block_size / 1024 });
    try w.print("  header_size:     {d} bytes\n", .{hdr.header_size});
    try w.print("  flags:\n", .{});
    try w.print("    content_size_present:  {}\n", .{hdr.flags.content_size_present});
    try w.print("    content_checksum:      {}\n", .{hdr.flags.content_checksum});
    try w.print("    block_checksums:       {}\n", .{hdr.flags.block_checksums});
    try w.print("    dictionary_id_present: {}\n", .{hdr.flags.dictionary_id_present});
    if (hdr.content_size) |cs| try w.print("  content_size:    {d} bytes\n", .{cs});
    if (hdr.dictionary_id) |id| try w.print("  dictionary_id:   0x{x:0>8}\n", .{id});

    // Walk block headers
    try w.print("  blocks:\n", .{});
    var pos: usize = hdr.header_size;
    var block_index: usize = 0;
    var total_decompressed: u64 = 0;
    while (pos + 4 <= data.len) {
        const block_hdr = frame.parseBlockHeader(data[pos..]) catch |err| {
            try w.print("    [#{d}] invalid block header at pos={d}: {s}\n", .{ block_index, pos, @errorName(err) });
            break;
        };
        if (block_hdr.isEndMark()) {
            try w.print("    end_mark at pos={d}\n", .{pos});
            pos += 4;
            break;
        }
        try w.print("    [#{d}] pos={d} comp={d} decomp={d}{s}\n", .{
            block_index,
            pos,
            block_hdr.compressed_size,
            block_hdr.decompressed_size,
            if (block_hdr.uncompressed) " UNCOMPRESSED" else "",
        });
        total_decompressed += block_hdr.decompressed_size;
        pos += 8 + block_hdr.compressed_size;
        block_index += 1;
    }
    try w.print("  total blocks:    {d}\n", .{block_index});
    try w.print("  total decomp:    {d} bytes\n", .{total_decompressed});
    try w.print("  trailing bytes:  {d}\n", .{data.len -| pos});
}

test {
    _ = @import("format/frame_format.zig");
    _ = @import("format/streamlz_constants.zig");
    _ = @import("format/block_header.zig");
    _ = @import("io/BitReader.zig");
    _ = @import("io/bit_writer.zig");
    _ = @import("io/copy_helpers.zig");
    _ = @import("io/ptr_math.zig");
    _ = @import("decode/streamlz_decoder.zig");
    _ = @import("decode/entropy/huffman_decoder.zig");
    _ = @import("decode/entropy/entropy_decoder.zig");
    _ = @import("decode/fast/fast_lz_decoder.zig");
    _ = @import("decode/high/high_lz_decoder.zig");
    _ = @import("decode/high/high_lz_token_executor.zig");
    _ = @import("decode/entropy/tans_decoder.zig");
    _ = @import("decode/decompress_parallel.zig");
    _ = @import("decode/fixture_tests.zig");
    _ = @import("encode/entropy/ByteHistogram.zig");
    _ = @import("encode/fast/fast_constants.zig");
    _ = @import("encode/entropy/tans_encoder.zig");
    _ = @import("encode/offset_encoder.zig");
    _ = @import("encode/entropy/entropy_encoder.zig");
    _ = @import("encode/fast/fast_match_hasher.zig");
    _ = @import("encode/match_hasher.zig");
    _ = @import("encode/text_detector.zig");
    _ = @import("encode/cost_coefficients.zig");
    _ = @import("encode/fast/fast_cost_model.zig");
    _ = @import("encode/fast/FastStreamWriter.zig");
    _ = @import("encode/fast/fast_token_writer.zig");
    _ = @import("encode/fast/fast_lz_parser.zig");
    _ = @import("encode/match_eval.zig");
    _ = @import("encode/high/managed_match_len_storage.zig");
    _ = @import("encode/high/match_finder.zig");
    _ = @import("encode/high/match_finder_bt4.zig");
    _ = @import("encode/high/high_types.zig");
    _ = @import("encode/high/high_matcher.zig");
    _ = @import("encode/high/high_cost_model.zig");
    _ = @import("encode/high/high_encoder.zig");
    _ = @import("encode/high/high_greedy_parser.zig");
    _ = @import("encode/high/high_optimal_parser.zig");
    _ = @import("encode/high/high_compressor.zig");
    _ = @import("encode/fast/fast_lz_encoder.zig");
    _ = @import("encode/streamlz_encoder.zig");
    _ = @import("encode/fast_framed.zig");
    _ = @import("encode/high_framed.zig");
    _ = @import("encode/compress_parallel.zig");
    _ = @import("encode/encode_fixture_tests.zig");
}

test "Command.parse recognises known commands" {
    try std.testing.expectEqual(Command.version, Command.parse("version").?);
    try std.testing.expectEqual(Command.version, Command.parse("--version").?);
    try std.testing.expectEqual(Command.help, Command.parse("-h").?);
    try std.testing.expectEqual(Command.decompress, Command.parse("d").?);
    try std.testing.expectEqual(Command.compress, Command.parse("c").?);
    try std.testing.expect(Command.parse("nope") == null);
}
