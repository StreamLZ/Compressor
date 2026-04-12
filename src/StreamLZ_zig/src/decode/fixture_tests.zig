//! Phase 8: exhaustive roundtrip tests over a pre-generated fixture corpus.
//!
//! The fixtures live in `$STREAMLZ_FIXTURES_DIR` (by convention
//! `c:/tmp/fixtures/`), laid out as:
//!
//!     <root>/raw/<shape>_<size>.raw
//!     <root>/slz/<shape>_<size>_L<level>.slz
//!
//! For every .slz under `slz/`, we find the matching `.raw` under `raw/`
//! (by stripping the `_L<N>` suffix), decompress the .slz, and assert the
//! output is byte-for-byte equal to the .raw.
//!
//! If `STREAMLZ_FIXTURES_DIR` is unset, the test prints a skip message and
//! succeeds — this lets `zig build test` work on clean checkouts without
//! a fixtures directory while still running locally.
//!
//! Generate the corpus via `scripts/gen_fixtures.sh`.

const std = @import("std");
const decoder = @import("streamlz_decoder.zig");

const testing = std.testing;

const Failure = struct {
    slz_name: []const u8,
    reason: []const u8,
    detail: []const u8,
};

/// Strip the trailing "_L<digits>.slz" suffix from a slz filename and
/// replace it with ".raw", returning a freshly-allocated string.
/// `text_256k_L11.slz` → `text_256k.raw`
fn rawNameFromSlz(allocator: std.mem.Allocator, slz_name: []const u8) ![]u8 {
    // Must end with ".slz".
    if (slz_name.len < 4 or !std.mem.endsWith(u8, slz_name, ".slz")) {
        return error.BadName;
    }
    const without_ext = slz_name[0 .. slz_name.len - 4];
    // Find last "_L".
    var i: usize = without_ext.len;
    while (i > 0) : (i -= 1) {
        if (i + 1 < without_ext.len and without_ext[i] == '_' and without_ext[i + 1] == 'L') {
            // Validate everything after `_L` is digits.
            var all_digits = true;
            var j: usize = i + 2;
            if (j == without_ext.len) all_digits = false;
            while (j < without_ext.len) : (j += 1) {
                if (without_ext[j] < '0' or without_ext[j] > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                const stem = without_ext[0..i];
                return std.fmt.allocPrint(allocator, "{s}.raw", .{stem});
            }
        }
    }
    return error.NoLevelSuffix;
}

test "fixture corpus roundtrip: every .slz decodes to its matching .raw" {
    const allocator = testing.allocator;

    const root = std.process.getEnvVarOwned(allocator, "STREAMLZ_FIXTURES_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print(
                "\n  [fixture_tests] STREAMLZ_FIXTURES_DIR not set — skipping.\n" ++
                    "  Run scripts/gen_fixtures.sh and set STREAMLZ_FIXTURES_DIR=c:/tmp/fixtures\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(root);

    const slz_dir_path = try std.fmt.allocPrint(allocator, "{s}/slz", .{root});
    defer allocator.free(slz_dir_path);
    const raw_dir_path = try std.fmt.allocPrint(allocator, "{s}/raw", .{root});
    defer allocator.free(raw_dir_path);

    var slz_dir = std.fs.cwd().openDir(slz_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("\n  [fixture_tests] cannot open {s}: {s}\n", .{ slz_dir_path, @errorName(err) });
        return err;
    };
    defer slz_dir.close();

    var raw_dir = std.fs.cwd().openDir(raw_dir_path, .{}) catch |err| {
        std.debug.print("\n  [fixture_tests] cannot open {s}: {s}\n", .{ raw_dir_path, @errorName(err) });
        return err;
    };
    defer raw_dir.close();

    var failures: std.ArrayList(Failure) = .empty;
    defer {
        for (failures.items) |f| {
            allocator.free(f.slz_name);
            allocator.free(f.reason);
            allocator.free(f.detail);
        }
        failures.deinit(allocator);
    }

    var total: usize = 0;
    var passed: usize = 0;

    var it = slz_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".slz")) continue;

        total += 1;

        const raw_name = rawNameFromSlz(allocator, entry.name) catch |err| {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "bad filename"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            });
            continue;
        };
        defer allocator.free(raw_name);

        // Read both files.
        const slz_bytes = slz_dir.readFileAlloc(allocator, entry.name, 1 << 30) catch |err| {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "read slz"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            });
            continue;
        };
        defer allocator.free(slz_bytes);

        const raw_bytes = raw_dir.readFileAlloc(allocator, raw_name, 1 << 30) catch |err| {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "read raw"),
                .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ raw_name, @errorName(err) }),
            });
            continue;
        };
        defer allocator.free(raw_bytes);

        // Allocate dst with safe_space headroom.
        const dst = allocator.alloc(u8, raw_bytes.len + decoder.safe_space) catch |err| {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "alloc"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            });
            continue;
        };
        defer allocator.free(dst);

        const n = decoder.decompressFramed(slz_bytes, dst) catch |err| {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "decompressFramed"),
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            });
            continue;
        };

        if (n != raw_bytes.len) {
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "size mismatch"),
                .detail = try std.fmt.allocPrint(allocator, "got {d}, expected {d}", .{ n, raw_bytes.len }),
            });
            continue;
        }

        if (!std.mem.eql(u8, dst[0..n], raw_bytes)) {
            // Find first differing byte to give a useful report.
            var diff_at: usize = 0;
            while (diff_at < n and dst[diff_at] == raw_bytes[diff_at]) : (diff_at += 1) {}
            try failures.append(allocator, .{
                .slz_name = try allocator.dupe(u8, entry.name),
                .reason = try allocator.dupe(u8, "byte mismatch"),
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "first diff @{d}: got 0x{x:0>2}, expected 0x{x:0>2}",
                    .{ diff_at, dst[diff_at], raw_bytes[diff_at] },
                ),
            });
            continue;
        }

        passed += 1;
    }

    if (failures.items.len != 0) {
        std.debug.print("\n  [fixture_tests] {d}/{d} fixtures failed:\n", .{ failures.items.len, total });
        for (failures.items) |f| {
            std.debug.print("    {s}: {s} — {s}\n", .{ f.slz_name, f.reason, f.detail });
        }
        return error.FixtureRoundtripFailed;
    }

    if (total == 0) {
        std.debug.print(
            "\n  [fixture_tests] no .slz files found under {s} — did you run gen_fixtures.sh?\n",
            .{slz_dir_path},
        );
        return error.NoFixturesFound;
    }

    std.debug.print("\n  [fixture_tests] all {d} fixtures passed\n", .{passed});
}

test "rawNameFromSlz strips _L<n>.slz suffix" {
    const allocator = testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "text_256k_L11.slz", .out = "text_256k.raw" },
        .{ .in = "binary_4m_L1.slz", .out = "binary_4m.raw" },
        .{ .in = "mixed_64k_L9.slz", .out = "mixed_64k.raw" },
        .{ .in = "repetitive_1m_L6.slz", .out = "repetitive_1m.raw" },
    };
    for (cases) |c| {
        const got = try rawNameFromSlz(allocator, c.in);
        defer allocator.free(got);
        try testing.expectEqualStrings(c.out, got);
    }
}

test "rawNameFromSlz rejects names missing _L<n> suffix" {
    const allocator = testing.allocator;
    try testing.expectError(error.NoLevelSuffix, rawNameFromSlz(allocator, "text_256k.slz"));
    try testing.expectError(error.NoLevelSuffix, rawNameFromSlz(allocator, "text_L.slz"));
    try testing.expectError(error.BadName, rawNameFromSlz(allocator, "text_256k_L1.txt"));
}
