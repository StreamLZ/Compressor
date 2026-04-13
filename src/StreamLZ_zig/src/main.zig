const std = @import("std");
const builtin = @import("builtin");
const frame = @import("format/frame_format.zig");
const decoder = @import("decode/streamlz_decoder.zig");
const encoder = @import("encode/streamlz_encoder.zig");

const version_string = "0.0.0-phase3a";

const Command = enum {
    version,
    help,
    info,
    decompress,
    compress,
    bench,
    benchc,

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
    }
}

/// In-memory compress + decompress benchmark mirroring the C# `slz -b`
/// output: per-run timings, median (not mean), and a final round-trip
/// pass/fail check.
fn runBenchCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 2 or args.len > 3) {
        try w.writeAll("usage: streamlz benchc <raw-file> <level> [runs]\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];
    const level: u8 = std.fmt.parseInt(u8, args[1], 10) catch {
        try w.writeAll("error: level must be 1..5\n");
        try w.flush();
        std.process.exit(2);
    };
    if (level < 1 or level > 5) {
        try w.writeAll("error: level must be 1..5\n");
        try w.flush();
        std.process.exit(2);
    }
    const runs: u32 = if (args.len == 3)
        std.fmt.parseInt(u32, args[2], 10) catch 3
    else
        3;
    if (runs == 0) {
        try w.writeAll("error: runs must be >= 1\n");
        try w.flush();
        std.process.exit(2);
    }

    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31;
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
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
    try w.print("Input: {s} ({d} bytes, {d:.2} MB)\n", .{ path, src.len, mb });

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

    // Warm-up decompress.
    _ = try decoder.decompressFramed(compressed[0..comp_size], decompressed);

    // ── Decompress benchmark ──────────────────────────────────────────
    const dec_times = try allocator.alloc(u64, runs);
    defer allocator.free(dec_times);
    r = 0;
    while (r < runs) : (r += 1) {
        var timer = try std.time.Timer.start();
        _ = try decoder.decompressFramed(compressed[0..comp_size], decompressed);
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
        try w.writeAll("Round-trip: FAIL\n");
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
    if (args.len < 1 or args.len > 2) {
        try w.writeAll("usage: streamlz bench <file.slz> [runs]\n");
        try w.flush();
        std.process.exit(2);
    }
    const path = args[0];
    const runs: u32 = if (args.len == 2)
        std.fmt.parseInt(u32, args[1], 10) catch 10
    else
        10;

    const in_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31;
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
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
    _ = decoder.decompressFramed(src, dst) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u64 = 0;
    var run: u32 = 0;
    while (run < runs) : (run += 1) {
        var timer = try std.time.Timer.start();
        _ = try decoder.decompressFramed(src, dst);
        const elapsed = timer.read();
        if (elapsed < best_ns) best_ns = elapsed;
        total_ns += elapsed;
    }

    const mean_ns: u64 = total_ns / runs;
    const mb: f64 = @as(f64, @floatFromInt(content_size)) / (1024.0 * 1024.0);
    const best_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(best_ns));
    const mean_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(mean_ns));

    try w.print("bench: {s}\n", .{path});
    try w.print("  src bytes:       {d}\n", .{src.len});
    try w.print("  decompressed:    {d} ({d:.2} MB)\n", .{ content_size, mb });
    try w.print("  runs:            {d} (plus 1 warm-up)\n", .{runs});
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
        \\  decompress <in> <out>      Decompress an SLZ1 file
        \\  compress [-l N] <in> <out> Compress a file to SLZ1 (N=1 or 2)
        \\  bench      <file> [runs]   Benchmark decompress on a preloaded file
        \\
    );
}

fn runCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    var level: u8 = 1;
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-l") and i + 1 < args.len) {
            level = std.fmt.parseInt(u8, args[i + 1], 10) catch {
                try w.print("error: invalid level '{s}'\n", .{args[i + 1]});
                try w.flush();
                std.process.exit(2);
            };
            i += 1;
        } else if (in_path == null) {
            in_path = a;
        } else if (out_path == null) {
            out_path = a;
        } else {
            try w.writeAll("usage: streamlz compress [-l N] <in> <out>\n");
            try w.flush();
            std.process.exit(2);
        }
    }
    if (in_path == null or out_path == null) {
        try w.writeAll("usage: streamlz compress [-l N] <in> <out>\n");
        try w.flush();
        std.process.exit(2);
    }

    if (level < 1 or level > 5) {
        try w.print("error: only levels 1-5 are currently supported (got {d})\n", .{level});
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

    const written = encoder.compressFramed(allocator, src, dst, .{ .level = level }) catch |err| {
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
    if (args.len != 2) {
        try w.writeAll("usage: streamlz decompress <in.slz> <out>\n");
        try w.flush();
        std.process.exit(2);
    }
    const in_path = args[0];
    const out_path = args[1];

    const in_file = std.fs.cwd().openFile(in_path, .{}) catch |err| {
        try w.print("error: cannot open '{s}': {s}\n", .{ in_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer in_file.close();

    const max_bytes: usize = 1 << 31; // 2 GiB hard cap for phase 3a
    const src = in_file.readToEndAlloc(allocator, max_bytes) catch |err| {
        try w.print("error: cannot read '{s}': {s}\n", .{ in_path, @errorName(err) });
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

    const written = decoder.decompressFramed(src, dst) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    const out_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try w.print("error: cannot create '{s}': {s}\n", .{ out_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer out_file.close();
    out_file.writeAll(dst[0..written]) catch |err| {
        try w.print("error: cannot write '{s}': {s}\n", .{ out_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };

    try w.print("decompressed {d} → {d} bytes  ({s} → {s})\n", .{
        src.len, written, in_path, out_path,
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
        const bh = frame.parseBlockHeader(data[pos..]) catch |err| {
            try w.print("    [#{d}] invalid block header at pos={d}: {s}\n", .{ block_index, pos, @errorName(err) });
            break;
        };
        if (bh.isEndMark()) {
            try w.print("    end_mark at pos={d}\n", .{pos});
            pos += 4;
            break;
        }
        try w.print("    [#{d}] pos={d} comp={d} decomp={d}{s}\n", .{
            block_index,
            pos,
            bh.compressed_size,
            bh.decompressed_size,
            if (bh.uncompressed) " UNCOMPRESSED" else "",
        });
        total_decompressed += bh.decompressed_size;
        pos += 8 + bh.compressed_size;
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
    _ = @import("io/bit_reader.zig");
    _ = @import("io/bit_writer.zig");
    _ = @import("io/bit_writer_64.zig");
    _ = @import("io/copy_helpers.zig");
    _ = @import("decode/streamlz_decoder.zig");
    _ = @import("decode/huffman_decoder.zig");
    _ = @import("decode/entropy_decoder.zig");
    _ = @import("decode/fast_lz_decoder.zig");
    _ = @import("decode/high_lz_decoder.zig");
    _ = @import("decode/high_lz_process_runs.zig");
    _ = @import("decode/tans_decoder.zig");
    _ = @import("decode/fixture_tests.zig");
    _ = @import("encode/byte_histogram.zig");
    _ = @import("encode/fast_constants.zig");
    _ = @import("encode/tans_encoder.zig");
    _ = @import("encode/offset_encoder.zig");
    _ = @import("encode/entropy_encoder.zig");
    _ = @import("encode/fast_match_hasher.zig");
    _ = @import("encode/match_hasher.zig");
    _ = @import("encode/text_detector.zig");
    _ = @import("encode/cost_coefficients.zig");
    _ = @import("encode/cost_model.zig");
    _ = @import("encode/fast_stream_writer.zig");
    _ = @import("encode/fast_token_writer.zig");
    _ = @import("encode/fast_lz_parser.zig");
    _ = @import("encode/match_eval.zig");
    _ = @import("encode/block_header_writer.zig");
    _ = @import("encode/managed_match_len_storage.zig");
    _ = @import("encode/match_finder.zig");
    _ = @import("encode/high_types.zig");
    _ = @import("encode/high_matcher.zig");
    _ = @import("encode/high_cost_model.zig");
    _ = @import("encode/high_encoder.zig");
    _ = @import("encode/high_fast_parser.zig");
    _ = @import("encode/high_compressor.zig");
    _ = @import("encode/fast_lz_encoder.zig");
    _ = @import("encode/streamlz_encoder.zig");
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
