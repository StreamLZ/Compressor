const std = @import("std");
const builtin = @import("builtin");
const frame = @import("format/frame_format.zig");
const decoder = @import("decode/streamlz_decoder.zig");
const encoder = @import("encode/streamlz_encoder.zig");
const dict_mod = @import("dict/dictionary.zig");

const version_string = "0.0.0-phase3a";

// ─── Argument parsing ────────────────────────────────────────────────

const trainer = @import("dict/trainer.zig");

const Mode = enum {
    compress,
    decompress,
    bench, // compress + decompress benchmark
    bench_decompress, // decompress-only benchmark (-db)
    bench_all, // all levels L1-L11 (-ba)
    train, // dictionary training
    info,
    version,
    help,
};

const Args = struct {
    mode: Mode,
    level: u8,
    runs: ?u32, // null = use default for mode
    threads: u32,
    input: ?[]const u8,
    output: ?[]const u8,
    dict_name: ?[]const u8 = null, // -D name or path
    no_dict: bool = false, // --no-dict disables auto-detection
};

fn parseArgs(raw: []const []const u8, w: *std.Io.Writer) Args {
    var result: Args = .{
        .mode = .compress,
        .level = 1,
        .runs = null,
        .threads = 0,
        .input = null,
        .output = null,
    };

    var i: usize = 1; // skip argv[0]
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];

        if (eql(arg, "-V") or eql(arg, "--version")) {
            result.mode = .version;
            return result;
        }
        if (eql(arg, "-h") or eql(arg, "--help")) {
            result.mode = .help;
            return result;
        }
        if (eql(arg, "-c")) {
            result.mode = .compress;

            continue;
        }
        if (eql(arg, "-d")) {
            result.mode = .decompress;

            continue;
        }
        if (eql(arg, "-b")) {
            result.mode = .bench;

            continue;
        }
        if (eql(arg, "-db")) {
            result.mode = .bench_decompress;

            continue;
        }
        if (eql(arg, "-ba")) {
            result.mode = .bench_all;

            continue;
        }
        if (eql(arg, "-i")) {
            result.mode = .info;
            continue;
        }
        if (eql(arg, "--train")) {
            result.mode = .train;
            continue;
        }
        if (eql(arg, "-l")) {
            if (i + 1 >= raw.len) die(w, "error: -l requires a value\n");
            i += 1;
            result.level = parseInt(u8, raw[i], w, "-l");
            continue;
        }
        if (eql(arg, "-r")) {
            if (i + 1 >= raw.len) die(w, "error: -r requires a value\n");
            i += 1;
            result.runs = parseInt(u32, raw[i], w, "-r");
            continue;
        }
        if (eql(arg, "-t")) {
            if (i + 1 >= raw.len) die(w, "error: -t requires a value\n");
            i += 1;
            result.threads = parseInt(u32, raw[i], w, "-t");
            continue;
        }
        if (eql(arg, "-o")) {
            if (i + 1 >= raw.len) die(w, "error: -o requires a value\n");
            i += 1;
            result.output = raw[i];
            continue;
        }
        if (eql(arg, "-D")) {
            if (i + 1 >= raw.len) die(w, "error: -D requires a dictionary name or path\n");
            i += 1;
            result.dict_name = raw[i];
            continue;
        }
        if (eql(arg, "--no-dict")) {
            result.no_dict = true;
            continue;
        }
        // Starts with '-' but not recognized
        if (arg.len > 0 and arg[0] == '-') {
            w.print("error: unknown flag '{s}'\n\n", .{arg}) catch {};
            printUsage(w) catch {};
            w.flush() catch {};
            std.process.exit(2);
        }
        // Positional: input file
        if (result.input == null) {
            result.input = arg;
        } else {
            w.print("error: unexpected argument '{s}'\n\n", .{arg}) catch {};
            printUsage(w) catch {};
            w.flush() catch {};
            std.process.exit(2);
        }
    }

    return result;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseInt(comptime T: type, s: []const u8, w: *std.Io.Writer, flag: []const u8) T {
    return std.fmt.parseInt(T, s, 10) catch {
        w.print("error: invalid {s} value '{s}'\n", .{ flag, s }) catch {};
        w.flush() catch {};
        std.process.exit(2);
    };
}

fn die(w: *std.Io.Writer, msg: []const u8) noreturn {
    w.writeAll(msg) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

// ─── Entry point ─────────────────────────────────────────────────────

pub fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    if (raw_args.len < 2) {
        try printUsage(w);
        return;
    }

    const args = parseArgs(raw_args, w);

    switch (args.mode) {
        .version => try printVersion(w),
        .help => try printUsage(w),
        .compress => try runCompress(allocator, w, args),
        .decompress => try runDecompress(allocator, w, args),
        .bench => try runBenchCompress(allocator, w, args),
        .bench_decompress => try runBenchDecompress(allocator, w, args),
        .bench_all => try runBenchAll(allocator, w, args),
        .info => try runInfo(allocator, w, args),
        .train => try runTrain(allocator, w, args),
    }
}

// ─── Help / version ──────────────────────────────────────────────────

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
        \\Usage: streamlz [options] <input-file>
        \\
        \\Mode flags (default: -c):
        \\  -c              Compress
        \\  -d              Decompress
        \\  -b              Benchmark (compress + decompress, verify round-trip)
        \\  -db             Decompress benchmark (input is pre-compressed .slz file)
        \\  -ba             Bench all levels L1-L11 (compress only, shows ratio table)
        \\  --train         Train a dictionary from input files (-o dict.bin file1 file2 ...)
        \\  -i              Info (dump SLZ1 frame header + block list)
        \\
        \\Options:
        \\  -l <level>      Compression level 1-11 (default: 1)
        \\  -r <runs>       Benchmark runs (default: 3 for -b, 10 for -db)
        \\  -t <threads>    Threads (0=auto, default: 0)
        \\  -o <file>       Output file
        \\  -D <name|path>  Dictionary (built-in: json, html, text, xml, css, js)
        \\  --no-dict       Disable auto-detected dictionary
        \\  -V, --version   Print version
        \\  -h, --help      Print help
        \\
    );
}

// ─── Helpers ─────────────────────────────────────────────────────────

/// Derive the output path for compress: input + ".slz"
fn deriveCompressOutput(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, input.len + 4);
    @memcpy(result[0..input.len], input);
    @memcpy(result[input.len..][0..4], ".slz");
    return result;
}

/// Derive the output path for decompress: strip .slz or append .dec
fn deriveDecompressOutput(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len > 4 and eql(input[input.len - 4 ..], ".slz")) {
        const result = try allocator.alloc(u8, input.len - 4);
        @memcpy(result, input[0 .. input.len - 4]);
        return result;
    }
    const result = try allocator.alloc(u8, input.len + 4);
    @memcpy(result[0..input.len], input);
    @memcpy(result[input.len..][0..4], ".dec");
    return result;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, w: *std.Io.Writer) []const u8 {
    const max_bytes: usize = 1 << 31;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        w.print("error: cannot open '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        w.flush() catch {};
        std.process.exit(1);
    };
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes) catch |err| {
        w.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        w.flush() catch {};
        std.process.exit(1);
    };
}

fn requireInput(args: Args, w: *std.Io.Writer) []const u8 {
    return args.input orelse {
        w.writeAll("error: no input file specified\n\n") catch {};
        printUsage(w) catch {};
        w.flush() catch {};
        std.process.exit(2);
    };
}

/// Median of a slice of nanosecond durations.
fn median(times: []const u64) u64 {
    var buf: [256]u64 = undefined;
    const n = times.len;
    if (n == 0) return 0;
    if (n > buf.len) {
        var sum: u128 = 0;
        for (times) |t| sum += t;
        return @intCast(sum / n);
    }
    @memcpy(buf[0..n], times);
    std.mem.sort(u64, buf[0..n], {}, std.sort.asc(u64));
    if (n % 2 == 1) return buf[n / 2];
    return (buf[n / 2 - 1] + buf[n / 2]) / 2;
}

/// Format a byte count with thousands separators (e.g. 1,234,567).
fn fmtBytes(buf: []u8, value: usize) []const u8 {
    // First, render the raw number.
    var raw: [32]u8 = undefined;
    const raw_slice = std.fmt.bufPrint(&raw, "{d}", .{value}) catch return "?";
    const len = raw_slice.len;
    if (len <= 3) {
        @memcpy(buf[0..len], raw_slice);
        return buf[0..len];
    }
    // Insert commas.
    const commas = (len - 1) / 3;
    const total = len + commas;
    if (total > buf.len) return raw_slice;
    var out: usize = total;
    var src_i: usize = len;
    var group: usize = 0;
    while (src_i > 0) {
        src_i -= 1;
        out -= 1;
        buf[out] = raw_slice[src_i];
        group += 1;
        if (group == 3 and src_i > 0) {
            out -= 1;
            buf[out] = ',';
            group = 0;
        }
    }
    return buf[0..total];
}

// ─── Compress ────────────────────────────────────────────────────────

fn runCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);
    const level = args.level;

    if (level < 1 or level > 11) {
        try w.print("error: level must be 1..11 (got {d})\n", .{level});
        try w.flush();
        std.process.exit(2);
    }

    const src = readFile(allocator, in_path, w);
    defer allocator.free(src);

    // Derive output path
    const out_path_owned = if (args.output) |o| blk: {
        _ = o;
        break :blk @as(?[]const u8, null);
    } else try deriveCompressOutput(allocator, in_path);
    defer if (out_path_owned) |o| allocator.free(o);
    const out_path = args.output orelse out_path_owned.?;

    const bound = encoder.compressBound(src.len);
    const dst = allocator.alloc(u8, bound) catch |err| {
        try w.print("error: cannot allocate {d} bytes: {s}\n", .{ bound, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(dst);

    // Dictionary resolution: explicit -D flag, or auto-detect by extension.
    var dict_data: ?[]const u8 = null;
    var dict_id: ?u32 = null;
    if (args.dict_name) |name| {
        if (dict_mod.findByName(name)) |d| {
            dict_data = d.data;
            dict_id = d.id;
            try w.print("  dictionary: {s} (built-in, {d} bytes)\n", .{ d.name, d.data.len });
        } else {
            try w.print("error: unknown dictionary '{s}'\n", .{name});
            try w.flush();
            std.process.exit(2);
        }
    } else if (!args.no_dict) {
        if (dict_mod.findByExtension(in_path)) |d| {
            dict_data = d.data;
            dict_id = d.id;
            try w.print("  dictionary: {s} (auto-detected, {d} bytes)\n", .{ d.name, d.data.len });
        }
    }

    const written = encoder.compressFramed(allocator, src, dst, .{
        .level = level,
        .num_threads = args.threads,
        .dictionary = dict_data,
        .dictionary_id = dict_id,
    }) catch |err| {
        try w.print("error: compression failed: {s}\n", .{@errorName(err)});
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

    const ratio: f64 = @as(f64, @floatFromInt(written)) / @as(f64, @floatFromInt(@max(src.len, 1))) * 100.0;
    try w.print("compressed {d} -> {d} bytes  ({d:.1}%)  L{d}  ({s} -> {s})\n", .{
        src.len, written, ratio, level, in_path, out_path,
    });
}

// ─── Decompress ──────────────────────────────────────────────────────

fn runDecompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);

    const src = readFile(allocator, in_path, w);
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

    const dict_overhead: usize = if (hdr.dictionary_id) |did|
        if (dict_mod.findById(did)) |d| d.data.len + decoder.safe_space else 0
    else
        0;
    const dst = allocator.alloc(u8, content_size + decoder.safe_space + dict_overhead) catch |err| {
        try w.print("error: cannot allocate {d} bytes: {s}\n", .{ content_size + decoder.safe_space + dict_overhead, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer allocator.free(dst);

    const written = decoder.decompressFramedParallelThreaded(allocator, src, dst, args.threads) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    // Derive output path
    const out_path_owned = if (args.output) |_| @as(?[]const u8, null) else try deriveDecompressOutput(allocator, in_path);
    defer if (out_path_owned) |o| allocator.free(o);
    const out_path = args.output orelse out_path_owned.?;

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

    try w.print("decompressed {d} -> {d} bytes  ({s} -> {s})\n", .{
        src.len, written, in_path, out_path,
    });
}

// ─── Benchmark: compress + decompress (-b) ───────────────────────────

fn runBenchCompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);
    const level = args.level;
    const runs = args.runs orelse 3;

    if (level < 1 or level > 11) {
        try w.print("error: level must be 1..11 (got {d})\n", .{level});
        try w.flush();
        std.process.exit(2);
    }
    if (runs == 0) {
        die(w, "error: runs must be >= 1\n");
    }

    const src = readFile(allocator, in_path, w);
    defer allocator.free(src);

    const bound = encoder.compressBound(src.len);
    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);
    const mb: f64 = @as(f64, @floatFromInt(src.len)) / (1024.0 * 1024.0);
    try w.print("Input: {s} ({d} bytes, {d:.2} MB)\n", .{ in_path, src.len, mb });

    // Dictionary resolution (same logic as runCompress).
    var dict_data_b: ?[]const u8 = null;
    var dict_id_b: ?u32 = null;
    if (args.dict_name) |name| {
        if (dict_mod.findByName(name)) |d| { dict_data_b = d.data; dict_id_b = d.id; }
    } else if (!args.no_dict) {
        if (dict_mod.findByExtension(in_path)) |d| { dict_data_b = d.data; dict_id_b = d.id; }
    }

    const dict_buf_extra: usize = if (dict_data_b) |d| d.len + decoder.safe_space else 0;
    const decompressed = try allocator.alloc(u8, src.len + decoder.safe_space + dict_buf_extra);
    defer allocator.free(decompressed);

    // Warm-up compress.
    const comp_opts: encoder.Options = .{ .level = level, .dictionary = dict_data_b, .dictionary_id = dict_id_b };
    var comp_size: usize = try encoder.compressFramed(allocator, src, compressed, comp_opts);

    // Compress benchmark.
    const comp_times = try allocator.alloc(u64, runs);
    defer allocator.free(comp_times);
    var r: u32 = 0;
    while (r < runs) : (r += 1) {
        var timer = try std.time.Timer.start();
        const n = try encoder.compressFramed(allocator, src, compressed, comp_opts);
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

    // Persistent thread pool for decompress.
    var dec_ctx = if (args.threads > 0)
        decoder.DecompressContext.initThreaded(allocator, args.threads)
    else
        decoder.DecompressContext.init(allocator);
    defer dec_ctx.deinit();

    // Warm-up decompress.
    _ = try dec_ctx.decompress(compressed[0..comp_size], decompressed);

    // Decompress benchmark.
    const dec_times = try allocator.alloc(u64, runs);
    defer allocator.free(dec_times);
    r = 0;
    while (r < runs) : (r += 1) {
        var timer = try std.time.Timer.start();
        _ = try dec_ctx.decompress(compressed[0..comp_size], decompressed);
        dec_times[r] = timer.read();
        const run_ms = @as(f64, @floatFromInt(dec_times[r])) / 1_000_000.0;
        const run_mbps = mb * 1000.0 / run_ms;
        try w.print("  Decompress run {d}: {d:.0}ms ({d:.1} MB/s)\n", .{ r + 1, run_ms, run_mbps });
    }
    const dec_median_ns = median(dec_times);
    const dec_median_ms = @as(f64, @floatFromInt(dec_median_ns)) / 1_000_000.0;
    const dec_median_mbps = mb * 1000.0 / dec_median_ms;
    try w.print("  Decompress median: {d:.0}ms ({d:.1} MB/s)\n\n", .{ dec_median_ms, dec_median_mbps });

    // Round-trip check.
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

// ─── Benchmark: decompress only (-db) ────────────────────────────────

fn runBenchDecompress(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);
    const runs = args.runs orelse 10;

    const src = readFile(allocator, in_path, w);
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

    var dec_ctx = if (args.threads > 0)
        decoder.DecompressContext.initThreaded(allocator, args.threads)
    else
        decoder.DecompressContext.init(allocator);
    defer dec_ctx.deinit();

    // Warm-up.
    _ = dec_ctx.decompress(src, dst) catch |err| {
        try w.print("error: decompression failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u64 = 0;
    var run_i: u32 = 0;
    while (run_i < runs) : (run_i += 1) {
        var timer = try std.time.Timer.start();
        _ = try dec_ctx.decompress(src, dst);
        const elapsed = timer.read();
        if (elapsed < best_ns) best_ns = elapsed;
        total_ns += elapsed;
    }

    const mean_ns: u64 = total_ns / runs;
    const mb: f64 = @as(f64, @floatFromInt(content_size)) / (1024.0 * 1024.0);
    const best_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(best_ns));
    const mean_mbps: f64 = mb * 1e9 / @as(f64, @floatFromInt(mean_ns));

    try w.print("bench: {s}\n", .{in_path});
    try w.print("  src bytes:       {d}\n", .{src.len});
    try w.print("  decompressed:    {d} ({d:.2} MB)\n", .{ content_size, mb });
    try w.print("  runs:            {d} (plus 1 warm-up)\n", .{runs});
    if (args.threads > 0) {
        try w.print("  threads:         {d}\n", .{args.threads});
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

// ─── Benchmark: all levels (-ba) ─────────────────────────────────────

fn runBenchAll(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);
    const runs = args.runs orelse 3;

    if (runs == 0) {
        die(w, "error: runs must be >= 1\n");
    }

    const src = readFile(allocator, in_path, w);
    defer allocator.free(src);

    const mb: f64 = @as(f64, @floatFromInt(src.len)) / (1024.0 * 1024.0);
    try w.print("streamlz bench-all: {s} ({d} bytes)\n", .{ in_path, src.len });

    const bound = encoder.compressBound(src.len);
    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);
    const decompressed = try allocator.alloc(u8, src.len + decoder.safe_space);
    defer allocator.free(decompressed);

    // Collect results for all levels, then print table.
    const Result = struct {
        level: u8,
        comp_size: usize,
        ratio: f64,
        comp_mbps: f64,
        dec_mbps: f64,
        pass: bool,
    };
    var results: [11]Result = undefined;

    var level: u8 = 1;
    while (level <= 11) : (level += 1) {
        const idx = level - 1;

        // Warm-up compress.
        const comp_size = encoder.compressFramed(allocator, src, compressed, .{ .level = level }) catch |err| {
            try w.print("  L{d}: compress failed: {s}\n", .{ level, @errorName(err) });
            results[idx] = .{ .level = level, .comp_size = 0, .ratio = 0, .comp_mbps = 0, .dec_mbps = 0, .pass = false };
            continue;
        };

        // Compress: best of N runs.
        var best_comp_ns: u64 = std.math.maxInt(u64);
        var r: u32 = 0;
        while (r < runs) : (r += 1) {
            var timer = try std.time.Timer.start();
            _ = try encoder.compressFramed(allocator, src, compressed, .{ .level = level });
            const elapsed = timer.read();
            if (elapsed < best_comp_ns) best_comp_ns = elapsed;
        }

        // Decompress context.
        var dec_ctx = if (args.threads > 0)
            decoder.DecompressContext.initThreaded(allocator, args.threads)
        else
            decoder.DecompressContext.init(allocator);
        defer dec_ctx.deinit();

        // Warm-up decompress.
        _ = dec_ctx.decompress(compressed[0..comp_size], decompressed) catch |err| {
            try w.print("  L{d}: decompress failed: {s}\n", .{ level, @errorName(err) });
            results[idx] = .{ .level = level, .comp_size = comp_size, .ratio = 0, .comp_mbps = 0, .dec_mbps = 0, .pass = false };
            continue;
        };

        // Decompress: best of N runs.
        var best_dec_ns: u64 = std.math.maxInt(u64);
        r = 0;
        while (r < runs) : (r += 1) {
            var timer = try std.time.Timer.start();
            _ = try dec_ctx.decompress(compressed[0..comp_size], decompressed);
            const elapsed = timer.read();
            if (elapsed < best_dec_ns) best_dec_ns = elapsed;
        }

        // Round-trip verification.
        const pass = std.mem.eql(u8, src, decompressed[0..src.len]);

        const ratio = @as(f64, @floatFromInt(comp_size)) / @as(f64, @floatFromInt(@max(src.len, 1))) * 100.0;
        const comp_ms = @as(f64, @floatFromInt(best_comp_ns)) / 1_000_000.0;
        const dec_ms = @as(f64, @floatFromInt(best_dec_ns)) / 1_000_000.0;
        const comp_mbps = mb * 1000.0 / comp_ms;
        const dec_mbps = mb * 1000.0 / dec_ms;

        results[idx] = .{
            .level = level,
            .comp_size = comp_size,
            .ratio = ratio,
            .comp_mbps = comp_mbps,
            .dec_mbps = dec_mbps,
            .pass = pass,
        };

        // Progress indicator (levels can be slow).
        try w.print("  L{d} done ({d:.1}%)\n", .{ level, ratio });
        try w.flush();
    }

    // Print the table.
    try w.writeAll("\nLevel | Compressed         | Ratio  | Compress   | Decompress\n");
    try w.writeAll("------+--------------------+--------+------------+-----------\n");

    for (results) |res| {
        var bytes_buf: [32]u8 = undefined;
        const bytes_str = fmtBytes(&bytes_buf, res.comp_size);

        // Format MB/s with appropriate precision.
        var comp_mbps_buf: [16]u8 = undefined;
        const comp_mbps_str = fmtMbps(&comp_mbps_buf, res.comp_mbps);
        var dec_mbps_buf: [16]u8 = undefined;
        const dec_mbps_str = fmtMbps(&dec_mbps_buf, res.dec_mbps);

        const pass_str: []const u8 = if (res.pass) "" else " FAIL";

        try w.print("L{d:<2}   | {s:>14} bytes | {d:>5.1}% | {s:>7} MB/s | {s:>7} MB/s{s}\n", .{
            res.level,
            bytes_str,
            res.ratio,
            comp_mbps_str,
            dec_mbps_str,
            pass_str,
        });
    }
}

fn fmtMbps(buf: []u8, value: f64) []const u8 {
    if (value >= 1000.0) {
        return std.fmt.bufPrint(buf, "{d:>.0}", .{value}) catch "?";
    } else if (value >= 100.0) {
        return std.fmt.bufPrint(buf, "{d:>.0}", .{value}) catch "?";
    } else if (value >= 10.0) {
        return std.fmt.bufPrint(buf, "{d:>.1}", .{value}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:>.1}", .{value}) catch "?";
    }
}

// ─── Info ────────────────────────────────────────────────────────────

fn runInfo(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const path = requireInput(args, w);

    const data = readFile(allocator, path, w);
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

    // Walk block headers.
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

// ─── Train ─────────────────────────────────────────────────────────

fn runTrain(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) !void {
    const in_path = requireInput(args, w);
    const out_path = args.output orelse "dictionary.bin";
    const dict_size: usize = 32768;

    // Read all files from the input directory as training samples.
    var dir = std.fs.cwd().openDir(in_path, .{ .iterate = true }) catch |err| {
        try w.print("error: cannot open directory '{s}': {s}\n", .{ in_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer dir.close();

    var samples: std.ArrayList([]const u8) = .{};
    defer {
        for (samples.items) |s| allocator.free(s);
        samples.deinit(allocator);
    }

    var total_bytes: usize = 0;
    var file_count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();
        const data = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch continue;
        if (data.len < 16) {
            allocator.free(data);
            continue;
        }
        try samples.append(allocator, data);
        total_bytes += data.len;
        file_count += 1;
    }

    if (file_count == 0) {
        try w.print("error: no usable files found in '{s}'\n", .{in_path});
        try w.flush();
        std.process.exit(1);
    }

    try w.print("training: {d} files, {d:.1} KB total\n", .{
        file_count,
        @as(f64, @floatFromInt(total_bytes)) / 1024.0,
    });

    var timer = try std.time.Timer.start();
    var result = trainer.train(allocator, samples.items, .{
        .dict_size = dict_size,
    }) catch |err| {
        try w.print("error: training failed: {s}\n", .{@errorName(err)});
        try w.flush();
        std.process.exit(1);
    };
    defer result.deinit();
    const train_ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;

    // Write dictionary.
    const out_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try w.print("error: cannot create '{s}': {s}\n", .{ out_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };
    defer out_file.close();
    out_file.writeAll(result.dict) catch |err| {
        try w.print("error: cannot write '{s}': {s}\n", .{ out_path, @errorName(err) });
        try w.flush();
        std.process.exit(1);
    };

    try w.print("trained: {d} bytes dictionary -> {s}  ({d:.0} ms)\n", .{
        result.dict.len,
        out_path,
        train_ms,
    });

    // Quick quality check: compress each sample with and without dictionary.
    var total_no_dict: usize = 0;
    var total_with_dict: usize = 0;
    for (samples.items) |sample| {
        if (sample.len < 64) continue;
        const bound = encoder.compressBound(sample.len);
        const comp_buf = allocator.alloc(u8, bound) catch continue;
        defer allocator.free(comp_buf);

        const no_dict_size = encoder.compressFramed(allocator, sample, comp_buf, .{
            .level = 3,
        }) catch continue;
        total_no_dict += no_dict_size;

        const with_dict_size = encoder.compressFramed(allocator, sample, comp_buf, .{
            .level = 3,
            .dictionary = result.dict,
            .dictionary_id = 0x10000001,
        }) catch continue;
        total_with_dict += with_dict_size;
    }

    if (total_no_dict > 0) {
        const improvement = @as(f64, @floatFromInt(total_no_dict)) - @as(f64, @floatFromInt(total_with_dict));
        const pct = improvement / @as(f64, @floatFromInt(total_no_dict)) * 100.0;
        try w.print("quality: no_dict={d} bytes, with_dict={d} bytes ({d:.2}% improvement)\n", .{
            total_no_dict,
            total_with_dict,
            pct,
        });
    }
}
