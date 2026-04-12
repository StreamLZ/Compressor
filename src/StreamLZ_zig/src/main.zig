const std = @import("std");
const builtin = @import("builtin");
const frame = @import("format/frame_format.zig");
const decoder = @import("decode/streamlz_decoder.zig");

const version_string = "0.0.0-phase3a";

const Command = enum {
    version,
    help,
    info,
    decompress,
    compress,

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
        .compress => {
            try stdout.print("error: 'compress' is not implemented yet (coming in phase 9)\n", .{});
            try stdout.flush();
            std.process.exit(2);
        },
    }
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
        \\  decompress <in> <out>  [phase 3] Decompress an SLZ1 file
        \\  compress   <in> <out>  [phase 9] Compress a file to SLZ1
        \\
    );
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
    _ = @import("io/copy_helpers.zig");
    _ = @import("decode/streamlz_decoder.zig");
    _ = @import("decode/huffman_decoder.zig");
}

test "Command.parse recognises known commands" {
    try std.testing.expectEqual(Command.version, Command.parse("version").?);
    try std.testing.expectEqual(Command.version, Command.parse("--version").?);
    try std.testing.expectEqual(Command.help, Command.parse("-h").?);
    try std.testing.expectEqual(Command.decompress, Command.parse("d").?);
    try std.testing.expectEqual(Command.compress, Command.parse("c").?);
    try std.testing.expect(Command.parse("nope") == null);
}
