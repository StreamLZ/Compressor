//! Signed-offset pointer arithmetic helper.
//!
//! Wraps the `@ptrFromInt(@intFromPtr(base) +% offset)` pattern that
//! appears throughout the LZ hot loops. The offset can be negative
//! (e.g., match source behind the current cursor). Zig's slice
//! arithmetic would trap on negative offsets, so raw pointer math
//! via integer round-trip is intentional here.

/// Advance `base` by `delta` bytes (delta may be negative).
/// Equivalent to C's `(const uint8_t*)base + delta`.
pub inline fn offsetPtr(comptime T: type, base: T, delta: isize) T {
    return @ptrFromInt(@intFromPtr(base) +% @as(usize, @bitCast(delta)));
}
