//! Fixture-scoped chunked JSON streams.
//!
//! Each chunk is a complete frame with `chunk` metadata. The producer emits one
//! frame at a time; the consumer validates the stream order before it trusts a
//! batch.

const std = @import("std");
const frame = @import("frame.zig");
const fixture_json = @import("fixture_json.zig");
const ipc_fixture = @import("ipc_fixture.zig");
const ipc_zstd = @import("ipc_zstd.zig");

pub const Error = error{
    BadArgument,
    BadChunk,
    BadFrame,
    BadStream,
    UnknownLane,
    OutOfMemory,
};

pub const MAX_CHUNK_ROWS: usize = 10_000_000;
pub const stream_id = "00000000000000000000000000000001";

pub const Summary = struct {
    rows: u64,
    chunks: u64,
    lane: []const u8,
};

fn chunkOf(allocator: std.mem.Allocator, header_json: []const u8, id_out: *[32]u8) Error!frame.ChunkInfo {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, header_json, .{}) catch return error.BadChunk;
    defer parsed.deinit();
    const header = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadChunk,
    };
    const chunk_value = header.get("chunk") orelse return error.BadChunk;
    const chunk = switch (chunk_value) {
        .object => |object| object,
        else => return error.BadChunk,
    };
    if (chunk.count() != 3) return error.BadChunk;
    const id_value = chunk.get("id") orelse return error.BadChunk;
    const id = switch (id_value) {
        .string => |text| text,
        else => return error.BadChunk,
    };
    if (id.len != id_out.len) return error.BadChunk;
    @memcpy(id_out, id);
    const index_value = chunk.get("index") orelse return error.BadChunk;
    const index: u64 = switch (index_value) {
        .integer => |number| @intCast(number),
        else => return error.BadChunk,
    };
    const last_value = chunk.get("last") orelse return error.BadChunk;
    const last = switch (last_value) {
        .bool => |value| value,
        else => return error.BadChunk,
    };
    const info = frame.ChunkInfo{ .id = id_out[0..], .index = index, .last = last };
    info.validate() catch return error.BadChunk;
    return info;
}

pub fn pack(allocator: std.mem.Allocator, rows: usize, chunk_rows: usize) Error![]u8 {
    return packLane(allocator, rows, chunk_rows, "json");
}

pub fn packLane(allocator: std.mem.Allocator, rows: usize, chunk_rows: usize, lane: []const u8) Error![]u8 {
    if (chunk_rows == 0 or chunk_rows > MAX_CHUNK_ROWS) return error.BadArgument;
    if (!std.mem.eql(u8, lane, "json") and !std.mem.eql(u8, lane, "ipc") and !std.mem.eql(u8, lane, "ipc-zstd")) return error.UnknownLane;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var start: usize = 0;
    var index: u64 = 0;
    while (true) {
        const count = if (start < rows) @min(chunk_rows, rows - start) else 0;
        const last = start + count >= rows;
        const info = frame.ChunkInfo{ .id = stream_id, .index = index, .last = last };
        const wire = if (std.mem.eql(u8, lane, "ipc"))
            ipc_fixture.encodeFrameRange(allocator, start, count, info) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadFrame,
            }
        else if (std.mem.eql(u8, lane, "ipc-zstd"))
            ipc_zstd.encodeFrameRange(allocator, start, count, info) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadFrame,
            }
        else
            fixture_json.encodeRange(allocator, start, count, info) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadFrame,
            };
        defer allocator.free(wire);
        out.appendSlice(allocator, wire) catch return error.OutOfMemory;
        start += count;
        index += 1;
        if (last) break;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn validate(allocator: std.mem.Allocator, data: []const u8) Error!Summary {
    var offset: usize = 0;
    var expected_index: u64 = 0;
    var stream_storage: [32]u8 = undefined;
    var has_stream = false;
    var total_rows: u64 = 0;
    var chunks: u64 = 0;
    var last_seen = false;
    var id_storage: [32]u8 = undefined;
    var lane_name: ?[]const u8 = null;

    while (offset < data.len) {
        if (last_seen) return error.BadStream;
        const span = frame.span(data[offset..]) catch return error.BadStream;
        if (span == 0 or offset + span > data.len) return error.BadStream;
        const wire = data[offset .. offset + span];
        const parsed = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
        const info = try chunkOf(allocator, parsed.header_json, &id_storage);
        if (has_stream) {
            if (!std.mem.eql(u8, stream_storage[0..], info.id)) return error.BadChunk;
        } else {
            @memcpy(stream_storage[0..], info.id);
            has_stream = true;
        }
        if (info.index != expected_index) return error.BadChunk;
        const current_lane = switch (parsed.lane_id) {
            1 => "json",
            2 => "ipc",
            3 => "ipc-zstd",
            else => return error.BadStream,
        };
        if (lane_name) |known| {
            if (!std.mem.eql(u8, known, current_lane)) return error.BadStream;
        } else {
            lane_name = current_lane;
        }
        const summary_rows: u64 = switch (parsed.lane_id) {
            1 => (fixture_json.validate(allocator, wire) catch return error.BadFrame).rows,
            2 => (ipc_fixture.summaryFrame(allocator, wire) catch return error.BadFrame).rows,
            3 => (ipc_zstd.summaryFrame(allocator, wire) catch return error.BadFrame).rows,
            else => unreachable,
        };
        total_rows += summary_rows;
        last_seen = info.last;
        offset += span;
        expected_index += 1;
        chunks += 1;
    }
    if (!last_seen) return error.BadStream;
    return .{ .rows = total_rows, .chunks = chunks, .lane = lane_name orelse "json" };
}

test "fixture json chunks split and validate" {
    const allocator = std.testing.allocator;
    const stream = try pack(allocator, 1000, 250);
    defer allocator.free(stream);
    const summary = try validate(allocator, stream);
    try std.testing.expectEqual(@as(u64, 1000), summary.rows);
    try std.testing.expectEqual(@as(u64, 4), summary.chunks);
}

test "fixture ipc chunks split and validate" {
    const allocator = std.testing.allocator;
    const stream = try packLane(allocator, 1000, 250, "ipc");
    defer allocator.free(stream);
    const summary = try validate(allocator, stream);
    try std.testing.expectEqual(@as(u64, 1000), summary.rows);
    try std.testing.expectEqual(@as(u64, 4), summary.chunks);
    try std.testing.expectEqualStrings("ipc", summary.lane);
}

test "fixture ipc-zstd chunks split and validate" {
    const allocator = std.testing.allocator;
    const stream = try packLane(allocator, 1000, 250, "ipc-zstd");
    defer allocator.free(stream);
    const summary = try validate(allocator, stream);
    try std.testing.expectEqual(@as(u64, 1000), summary.rows);
    try std.testing.expectEqual(@as(u64, 4), summary.chunks);
    try std.testing.expectEqualStrings("ipc-zstd", summary.lane);
}

test "fixture json empty stream is one empty chunk" {
    const allocator = std.testing.allocator;
    const stream = try pack(allocator, 0, 250);
    defer allocator.free(stream);
    const summary = try validate(allocator, stream);
    try std.testing.expectEqual(@as(u64, 0), summary.rows);
    try std.testing.expectEqual(@as(u64, 1), summary.chunks);
}
