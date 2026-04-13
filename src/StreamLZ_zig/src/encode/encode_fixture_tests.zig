//! Phase 9: encode-then-decode roundtrip tests over the Phase 8 fixture
//! corpus. For every `.raw` file under `$STREAMLZ_FIXTURES_DIR/raw/`, run
//! it through the Zig Fast encoder at levels 1 and 2, decode the result
//! with the Zig decoder, and diff byte-for-byte against the original.
//!
//! Self-skips cleanly if `STREAMLZ_FIXTURES_DIR` is unset.

const std = @import("std");
const encoder = @import("streamlz_encoder.zig");
const decoder = @import("../decode/streamlz_decoder.zig");

const testing = std.testing;

const Failure = struct {
    raw_name: []const u8,
    level: u8,
    reason: []const u8,
    detail: []const u8,
};

test "encoder roundtrip: every .raw encodes + decodes byte-exact (L1/L2)" {
    const allocator = testing.allocator;

    const root = std.process.getEnvVarOwned(allocator, "STREAMLZ_FIXTURES_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print(
                "\n  [encode_fixture_tests] STREAMLZ_FIXTURES_DIR not set — skipping.\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(root);

    const raw_dir_path = try std.fmt.allocPrint(allocator, "{s}/raw", .{root});
    defer allocator.free(raw_dir_path);

    var raw_dir = std.fs.cwd().openDir(raw_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("\n  [encode_fixture_tests] cannot open {s}: {s}\n", .{ raw_dir_path, @errorName(err) });
        return err;
    };
    defer raw_dir.close();

    var failures: std.ArrayList(Failure) = .empty;
    defer {
        for (failures.items) |f| {
            allocator.free(f.raw_name);
            allocator.free(f.reason);
            allocator.free(f.detail);
        }
        failures.deinit(allocator);
    }

    var total: usize = 0;
    var passed: usize = 0;

    var it = raw_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".raw")) continue;

        const raw_bytes = raw_dir.readFileAlloc(allocator, entry.name, 1 << 30) catch |err| {
            try failures.append(allocator, .{
                .raw_name = try allocator.dupe(u8, entry.name),
                .level = 0,
                .reason = try allocator.dupe(u8, "read"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            });
            continue;
        };
        defer allocator.free(raw_bytes);

        const levels = [_]u8{ 1, 2, 5 };
        for (levels) |level| {
            total += 1;
            const bound = encoder.compressBound(raw_bytes.len);
            const encoded = try allocator.alloc(u8, bound);
            defer allocator.free(encoded);

            const n = encoder.compressFramed(allocator, raw_bytes, encoded, .{ .level = level }) catch |err| {
                try failures.append(allocator, .{
                    .raw_name = try allocator.dupe(u8, entry.name),
                    .level = level,
                    .reason = try allocator.dupe(u8, "encode"),
                    .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
                });
                continue;
            };

            const decoded = try allocator.alloc(u8, raw_bytes.len + decoder.safe_space);
            defer allocator.free(decoded);

            const written = decoder.decompressFramed(encoded[0..n], decoded) catch |err| {
                try failures.append(allocator, .{
                    .raw_name = try allocator.dupe(u8, entry.name),
                    .level = level,
                    .reason = try allocator.dupe(u8, "decode"),
                    .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
                });
                continue;
            };

            if (written != raw_bytes.len) {
                try failures.append(allocator, .{
                    .raw_name = try allocator.dupe(u8, entry.name),
                    .level = level,
                    .reason = try allocator.dupe(u8, "size"),
                    .detail = try std.fmt.allocPrint(allocator, "got {d} want {d}", .{ written, raw_bytes.len }),
                });
                continue;
            }

            if (!std.mem.eql(u8, decoded[0..written], raw_bytes)) {
                var diff_at: usize = 0;
                while (diff_at < written and decoded[diff_at] == raw_bytes[diff_at]) : (diff_at += 1) {}
                try failures.append(allocator, .{
                    .raw_name = try allocator.dupe(u8, entry.name),
                    .level = level,
                    .reason = try allocator.dupe(u8, "mismatch"),
                    .detail = try std.fmt.allocPrint(
                        allocator,
                        "@{d}: got 0x{x:0>2} want 0x{x:0>2}",
                        .{ diff_at, decoded[diff_at], raw_bytes[diff_at] },
                    ),
                });
                continue;
            }

            passed += 1;
        }
    }

    if (failures.items.len != 0) {
        std.debug.print("\n  [encode_fixture_tests] {d}/{d} cases failed:\n", .{ failures.items.len, total });
        for (failures.items) |f| {
            std.debug.print("    {s} L{d}: {s} — {s}\n", .{ f.raw_name, f.level, f.reason, f.detail });
        }
        return error.EncoderRoundtripFailed;
    }

    if (total == 0) {
        std.debug.print("\n  [encode_fixture_tests] no .raw files found under {s}\n", .{raw_dir_path});
        return error.NoFixturesFound;
    }

    std.debug.print("\n  [encode_fixture_tests] all {d} encode roundtrips passed\n", .{passed});
}
