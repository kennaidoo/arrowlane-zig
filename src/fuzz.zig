//! Deterministic parser fuzz gate for untrusted wire inputs.
//!
//! The gate mutates known seeds and feeds generated inputs to the frame, shm
//! descriptor and general schema parsers. It runs in normal tests and in
//! `zig build fuzz`.
//!
//! Zig 0.17's coverage-guided runner is not used. It crashes in
//! `fuzzer_new_input` before the target runs on Linux.

const std = @import("std");
const frame = @import("frame.zig");
const schema_general = @import("schema_general.zig");
const shm_lane = @import("shm_lane.zig");

const iterations: usize = 10_000;

const seeds = [_][]const u8{
    "ALN1\x01\x01\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xc2\x41\x24\x35\x02\x00{}abc",
    "{\"name\":\"al-abc123\",\"length\":10,\"crc32\":7,\"token\":\"0123456789abcdef\",\"offset\":0}",
    "\xff\xff\xff\xff\x00\x00\x00\x00",
};

fn fuzzFrame(input: []const u8) void {
    const allocator = std.testing.allocator;
    _ = frame.span(input) catch {};
    _ = frame.decode(allocator, input, .{}) catch {};
}

fn fuzzDescriptor(input: []const u8) void {
    const allocator = std.testing.allocator;
    const desc = shm_lane.Descriptor.fromBytes(allocator, input) catch return;
    defer desc.deinit(allocator);
    _ = shm_lane.validateRange(desc, 1024) catch {};
}

fn fuzzSchema(input: []const u8) void {
    const allocator = std.testing.allocator;
    const parsed = schema_general.parse(allocator, input) catch return;
    defer allocator.free(parsed.fields);
}

fn nextRandom(state: *u64) u64 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}

test "fuzz wire parsers" {
    var state: u64 = 0x5eed_1234_abcd_0001;
    var buffer: [512]u8 = undefined;

    for (0..iterations) |iteration| {
        const seed = seeds[iteration % seeds.len];
        @memcpy(buffer[0..seed.len], seed);
        const extra: usize = @intCast(nextRandom(&state) % 48);
        const len = seed.len + extra;
        for (0..extra) |index| {
            buffer[seed.len + index] = @truncate(nextRandom(&state));
        }

        const mutations = 1 + @as(usize, @intCast(nextRandom(&state) % 6));
        for (0..mutations) |_| {
            const position: usize = @intCast(nextRandom(&state) % len);
            buffer[position] ^= @truncate(nextRandom(&state));
        }

        switch (iteration % 3) {
            0 => fuzzFrame(buffer[0..len]),
            1 => fuzzDescriptor(buffer[0..len]),
            else => fuzzSchema(buffer[0..len]),
        }
    }
}
