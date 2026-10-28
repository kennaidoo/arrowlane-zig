//! One-field int64 Arrow IPC spike.
//!
//! This writes and reads the exact Arrow IPC stream layout that pyarrow uses
//! for one nullable int64 column with no nulls. It is a spike, not a general
//! IPC codec. The record-batch flatbuffer is a pinned template with the row and
//! buffer lengths patched.

const std = @import("std");
const base64 = @import("base64.zig");
const frame = @import("frame.zig");
const schema = @import("schema.zig");

pub const Error = error{
    BadStream,
    BadSchema,
    BadFrame,
    BadHeader,
    OutOfMemory,
};

pub const producer = "arrowlane-zig/0.1.0";

const record_batch_template = [_]u8{
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00,
    0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x3c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

const continuation = [_]u8{ 0xff, 0xff, 0xff, 0xff };
const eos = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00 };

fn putU32(out: []u8, value: u32) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
}

fn putU64(out: []u8, value: u64) void {
    var v = value;
    for (0..8) |index| {
        out[index] = @truncate(v);
        v >>= 8;
    }
}

fn getU32(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

fn getU64(in: []const u8) u64 {
    var out: u64 = 0;
    for (in[0..8], 0..) |byte, index| {
        out |= @as(u64, byte) << @intCast(index * 8);
    }
    return out;
}

pub fn encode(allocator: std.mem.Allocator, values: []const i64) Error![]u8 {
    const schema_bytes = schema.encodeInt64(allocator, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
    };
    defer allocator.free(schema_bytes);

    const body_len = values.len * 8;
    const total = schema_bytes.len + 8 + record_batch_template.len + body_len + eos.len;
    const out = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    @memcpy(out[0..schema_bytes.len], schema_bytes);
    @memcpy(out[schema_bytes.len .. schema_bytes.len + 4], &continuation);
    putU32(out[schema_bytes.len + 4 .. schema_bytes.len + 8], record_batch_template.len);
    const meta_start = schema_bytes.len + 8;
    @memcpy(out[meta_start .. meta_start + record_batch_template.len], &record_batch_template);
    putU64(out[meta_start + 32 .. meta_start + 40], body_len);
    putU64(out[meta_start + 64 .. meta_start + 72], values.len);
    putU64(out[meta_start + 104 .. meta_start + 112], body_len);
    putU64(out[meta_start + 120 .. meta_start + 128], values.len);

    const body_start = meta_start + record_batch_template.len;
    for (values, 0..) |value, index| {
        putU64(out[body_start + index * 8 .. body_start + index * 8 + 8], @bitCast(value));
    }
    @memcpy(out[body_start + body_len ..][0..eos.len], &eos);
    return out;
}

pub fn decode(allocator: std.mem.Allocator, raw: []const u8) Error![]i64 {
    const schema_bytes = schema.encodeInt64(allocator, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
    };
    defer allocator.free(schema_bytes);
    if (raw.len < schema_bytes.len + 8 + record_batch_template.len + eos.len) return error.BadStream;
    if (!std.mem.eql(u8, raw[0..schema_bytes.len], schema_bytes)) return error.BadSchema;
    if (!std.mem.eql(u8, raw[schema_bytes.len .. schema_bytes.len + 4], &continuation)) return error.BadStream;
    const meta_len = getU32(raw[schema_bytes.len + 4 .. schema_bytes.len + 8]);
    if (meta_len != record_batch_template.len) return error.BadStream;
    const meta_start = schema_bytes.len + 8;
    const meta = raw[meta_start .. meta_start + meta_len];
    const body_len = getU64(meta[32..40]);
    const rows = getU64(meta[64..72]);
    const buffer_len = getU64(meta[104..112]);
    const node_len = getU64(meta[120..128]);
    if (rows != node_len) return error.BadStream;
    if (body_len != buffer_len) return error.BadStream;
    if (body_len != rows * 8) return error.BadStream;
    const body_start = meta_start + meta_len;
    if (raw.len != body_start + body_len + eos.len) return error.BadStream;
    if (!std.mem.eql(u8, raw[body_start + body_len ..][0..eos.len], &eos)) return error.BadStream;

    const values = allocator.alloc(i64, @intCast(rows)) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        value.* = @bitCast(getU64(raw[body_start + index * 8 .. body_start + index * 8 + 8]));
    }
    return values;
}

pub fn encodeFrame(allocator: std.mem.Allocator, values: []const i64) Error![]u8 {
    const raw = try encode(allocator, values);
    defer allocator.free(raw);
    const raw_schema = schema.encodeInt64(allocator, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
    };
    defer allocator.free(raw_schema);
    const encoded_schema = base64.encode(allocator, raw_schema) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return error.BadSchema,
    };
    defer allocator.free(encoded_schema);
    const header = std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/vnd.apache.arrow.stream\",\"ncols\":1,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
        .{ producer, encoded_schema },
    ) catch return error.OutOfMemory;
    defer allocator.free(header);
    return frame.encode(allocator, .{
        .lane_id = 2,
        .header_json = header,
        .payload = raw,
        .rows = values.len,
        .uncompressed_len = raw.len,
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFrame,
    };
}

pub fn decodeFrame(allocator: std.mem.Allocator, wire: []const u8) Error![]i64 {
    const parsed = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed.lane_id != 2) return error.BadFrame;
    if (parsed.uncompressed_len != parsed.payload.len) return error.BadFrame;

    var header = std.json.parseFromSlice(std.json.Value, allocator, parsed.header_json, .{}) catch return error.BadHeader;
    defer header.deinit();
    const object = switch (header.value) {
        .object => |value| value,
        else => return error.BadHeader,
    };
    const ncols_value = object.get("ncols") orelse return error.BadHeader;
    const ncols: u64 = switch (ncols_value) {
        .integer => |value| @intCast(value),
        else => return error.BadHeader,
    };
    if (ncols != 1) return error.BadHeader;
    const schema_value = object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    const raw_schema = base64.decode(allocator, schema_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return error.BadHeader,
    };
    defer allocator.free(raw_schema);
    const expected_schema = schema.encodeInt64(allocator, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
    };
    defer allocator.free(expected_schema);
    if (!std.mem.eql(u8, raw_schema, expected_schema)) return error.BadSchema;

    const values = decode(allocator, parsed.payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
        else => return error.BadFrame,
    };
    if (values.len != parsed.rows) {
        allocator.free(values);
        return error.BadFrame;
    }
    return values;
}

test "int64 ipc spike round trip" {
    const allocator = std.testing.allocator;
    const values = [_]i64{ 1, -2, 3 };
    const raw = try encode(allocator, &values);
    defer allocator.free(raw);
    const decoded = try decode(allocator, raw);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i64, &values, decoded);
}

test "int64 ipc frame round trip" {
    const allocator = std.testing.allocator;
    const values = [_]i64{ 1, -2, 3 };
    const wire = try encodeFrame(allocator, &values);
    defer allocator.free(wire);
    const decoded = try decodeFrame(allocator, wire);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i64, &values, decoded);
}

test "int64 ipc spike empty" {
    const allocator = std.testing.allocator;
    const raw = try encode(allocator, &.{});
    defer allocator.free(raw);
    const decoded = try decode(allocator, raw);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}
