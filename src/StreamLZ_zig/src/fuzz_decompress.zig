const std = @import("std");
const decoder = @import("decode/streamlz_decoder.zig");

/// Fuzz harness for the StreamLZ decompressor.
///
/// Usage:  fuzz-decompress <input-file>
///
/// Reads the file as compressed input, calls decompressFramed with a
/// fixed-size output buffer, and swallows decode errors (expected for
/// fuzz-generated input). Memory safety violations will panic, which
/// ReleaseSafe catches via bounds/overflow checks.
///
/// Works with AFL (@@), honggfuzz, or manual corpus files.
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return;

    const file = std.fs.cwd().openFile(args[1], .{}) catch return;
    defer file.close();

    const input = file.readToEndAlloc(allocator, 1 << 24) catch return;
    defer allocator.free(input);

    var dst: [1 << 24]u8 = undefined;
    _ = decoder.decompressFramed(input, &dst) catch return;
}
