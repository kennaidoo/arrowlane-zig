//! Fixture-scoped `ipc-zstd` lane.
//!
//! The payload is the pinned eight-column IPC stream compressed with libzstd.
//! Decode uses Zig's std zstd decoder with a hard output cap.

const std = @import("std");
const fixture_schema = @import("fixture_schema.zig");
const frame = @import("frame.zig");
const ipc_fixture = @import("ipc_fixture.zig");
const zstd = @import("zstd.zig");

pub const Error = error{
    BadFrame,
    BadHeader,
    BadCompressed,
    BadSchema,
    CompressFailed,
    OutOfMemory,
};

pub const producer = "arrowlane-zig/0.3.0";
pub const level: c_int = 3;

pub const Summary = struct {
    rows: u64,
    lane: []const u8,
};

fn decompress(allocator: std.mem.Allocator, payload: []const u8, expected_len: usize) Error![]u8 {
    var input = std.Io.Reader.fixed(payload);
    var empty: [0]u8 = .{};
    var decoder = std.compress.zstd.Decompress.init(&input, &empty, .{});
    const output = decoder.reader.allocRemaining(allocator, .limited(@max(expected_len, 1))) catch return error.BadCompressed;
    if (output.len != expected_len) {
        allocator.free(output);
        return error.BadCompressed;
    }
    return output;
}

fn headerFor(allocator: std.mem.Allocator, chunk: ?frame.ChunkInfo) Error![]u8 {
    if (chunk) |info| {
        info.validate() catch return error.BadFrame;
        return std.fmt.allocPrint(
            allocator,
            "{{\"chunk\":{{\"id\":\"{s}\",\"index\":{d},\"last\":{s}}},\"codec\":\"zstd\",\"media_type\":\"application/vnd.apache.arrow.stream\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\",\"zstd_level\":{d}}}",
            .{ info.id, info.index, if (info.last) "true" else "false", producer, fixture_schema.schema_b64, level },
        ) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"codec\":\"zstd\",\"media_type\":\"application/vnd.apache.arrow.stream\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\",\"zstd_level\":{d}}}",
        .{ producer, fixture_schema.schema_b64, level },
    ) catch return error.OutOfMemory;
}

pub fn encodeFrame(allocator: std.mem.Allocator, rows: usize) Error![]u8 {
    return encodeFrameRange(allocator, 0, rows, null);
}

pub fn encodeFrameRange(allocator: std.mem.Allocator, start: usize, rows: usize, chunk: ?frame.ChunkInfo) Error![]u8 {
    const raw = ipc_fixture.encodeRange(allocator, start, rows) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFrame,
    };
    defer allocator.free(raw);
    const payload = zstd.compress(allocator, raw, level) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompressFailed => return error.CompressFailed,
    };
    defer allocator.free(payload);
    const header = try headerFor(allocator, chunk);
    defer allocator.free(header);
    return frame.encode(allocator, .{
        .lane_id = 3,
        .header_json = header,
        .payload = payload,
        .rows = @intCast(rows),
        .uncompressed_len = raw.len,
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFrame,
    };
}

pub fn decodeFrame(allocator: std.mem.Allocator, wire: []const u8) Error!Summary {
    return decodeFrameAt(allocator, wire, 0);
}

pub fn decodeFrameAt(allocator: std.mem.Allocator, wire: []const u8, start: usize) Error!Summary {
    const parsed = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed.lane_id != 3) return error.BadFrame;
    if (parsed.uncompressed_len > frame.MAX_UNCOMPRESSED_BYTES) return error.BadFrame;
    var header = std.json.parseFromSlice(std.json.Value, allocator, parsed.header_json, .{}) catch return error.BadHeader;
    defer header.deinit();
    const object = switch (header.value) {
        .object => |value| value,
        else => return error.BadHeader,
    };
    const codec_value = object.get("codec") orelse return error.BadHeader;
    const codec = switch (codec_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, codec, "zstd")) return error.BadHeader;
    const ncols_value = object.get("ncols") orelse return error.BadHeader;
    const ncols: u64 = switch (ncols_value) {
        .integer => |value| @intCast(value),
        else => return error.BadHeader,
    };
    if (ncols != 8) return error.BadHeader;
    const schema_value = object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, schema_text, fixture_schema.schema_b64)) return error.BadSchema;

    const raw = try decompress(allocator, parsed.payload, @intCast(parsed.uncompressed_len));
    defer allocator.free(raw);
    const summary = ipc_fixture.validateRange(allocator, raw, start) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
        else => return error.BadFrame,
    };
    if (summary.rows != parsed.rows) return error.BadFrame;
    return .{ .rows = summary.rows, .lane = "ipc-zstd" };
}

/// Check the compressed frame envelope and schema without decompressing.
/// Used for chunk streams produced by another implementation.
pub fn summaryFrame(allocator: std.mem.Allocator, wire: []const u8) Error!Summary {
    const parsed = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed.lane_id != 3) return error.BadFrame;
    if (parsed.uncompressed_len > frame.MAX_UNCOMPRESSED_BYTES) return error.BadFrame;
    var header = std.json.parseFromSlice(std.json.Value, allocator, parsed.header_json, .{}) catch return error.BadHeader;
    defer header.deinit();
    const object = switch (header.value) {
        .object => |value| value,
        else => return error.BadHeader,
    };
    const codec_value = object.get("codec") orelse return error.BadHeader;
    const codec = switch (codec_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, codec, "zstd")) return error.BadHeader;
    const ncols_value = object.get("ncols") orelse return error.BadHeader;
    const ncols: u64 = switch (ncols_value) {
        .integer => |value| @intCast(value),
        else => return error.BadHeader,
    };
    if (ncols != 8) return error.BadHeader;
    const schema_value = object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, schema_text, fixture_schema.schema_b64)) return error.BadSchema;
    return .{ .rows = parsed.rows, .lane = "ipc-zstd" };
}

test "ipc zstd frame round trip" {
    const allocator = std.testing.allocator;
    const wire = try encodeFrame(allocator, 7);
    defer allocator.free(wire);
    const summary = try decodeFrame(allocator, wire);
    try std.testing.expectEqual(@as(u64, 7), summary.rows);
    try std.testing.expectEqualStrings("ipc-zstd", summary.lane);
}
