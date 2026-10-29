//! Coverage-guided fuzz targets for untrusted wire inputs.
//!
//! Built and run on Linux x86_64 via `zig build fuzz --fuzz=10000`.
//! On non-fuzz builds, `std.testing.fuzz` executes the seed corpus plus one
//! empty smoke input.

const std = @import("std");
const frame = @import("frame.zig");
const schema_general = @import("schema_general.zig");
const shm_lane = @import("shm_lane.zig");

fn fuzzFrame(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    _ = frame.span(input) catch {};
    _ = frame.decode(allocator, input, .{}) catch {};
}

fn fuzzDescriptor(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    const desc = shm_lane.Descriptor.fromBytes(allocator, input) catch return;
    defer desc.deinit(allocator);
    _ = shm_lane.validateRange(desc, 1024) catch {};
}

fn fuzzSchema(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    const parsed = schema_general.parse(allocator, input) catch return;
    defer allocator.free(parsed.fields);
}

test "fuzz frame parser" {
    try std.testing.fuzz({}, fuzzFrame, .{
        .corpus = &.{
            "ALN1\x01\x01\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xc2\x41\x24\x35\x02\x00{}abc",
            "ALN1",
            "",
        },
    });
}

test "fuzz shm descriptor parser" {
    try std.testing.fuzz({}, fuzzDescriptor, .{
        .corpus = &.{
            "{\"name\":\"al-abc123\",\"length\":10,\"crc32\":7,\"token\":\"0123456789abcdef\",\"offset\":0}",
            "{\"name\":\"al-overflow\",\"length\":1,\"crc32\":0,\"token\":\"0123456789abcdef\",\"offset\":18446744073709551615}",
            "{}",
        },
    });
}

test "fuzz general schema parser" {
    try std.testing.fuzz({}, fuzzSchema, .{
        .corpus = &.{
            "\xff\xff\xff\xff\x00\x00\x00\x00",
            "",
        },
    });
}
