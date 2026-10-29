//! Coverage-guided fuzz targets for untrusted wire inputs.
//!
//! Built and run on Linux x86_64 via `zig build fuzz --fuzz=10000`.
//! On non-fuzz builds, `std.testing.fuzz` executes the seed corpus plus one
//! empty smoke input.

const std = @import("std");
const frame = @import("frame.zig");
const schema_general = @import("schema_general.zig");
const shm_lane = @import("shm_lane.zig");

fn fuzzFrame(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    _ = frame.span(input) catch {};
    _ = frame.decode(allocator, input, .{}) catch {};
}

fn fuzzDescriptor(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const desc = shm_lane.Descriptor.fromBytes(allocator, input) catch return;
    defer desc.deinit(allocator);
    _ = shm_lane.validateRange(desc, 1024) catch {};
}

fn fuzzSchema(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const parsed = schema_general.parse(allocator, input) catch return;
    defer allocator.free(parsed.fields);
}

fn fuzzAll(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    if (len == 0) return;
    const input = buf[1..len];
    switch (buf[0] % 3) {
        0 => try fuzzFrame(input),
        1 => try fuzzDescriptor(input),
        else => try fuzzSchema(input),
    }
}

test "fuzz wire parsers" {
    try std.testing.fuzz({}, fuzzAll, .{});
}
