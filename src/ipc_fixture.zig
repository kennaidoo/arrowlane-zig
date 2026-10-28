//! Fixture-scoped eight-column Arrow IPC lane.
//!
//! The schema is the pinned 480 byte canonical message. The record-batch
//! metadata is a 504 byte template with 8 field nodes and 18 buffer descriptors
//! patched from the computed body layout. The body is the canonical fixture:
//! id, nullable name, score, ok, date32, decimal128(9,2), timestamp(us, UTC)
//! and binary.

const std = @import("std");
const base64 = @import("base64.zig");
const fixture_ipc_template = @import("fixture_ipc_template.zig");
const fixture_schema = @import("fixture_schema.zig");
const frame = @import("frame.zig");

pub const Error = error{
    BadStream,
    BadSchema,
    BadFrame,
    BadHeader,
    OutOfMemory,
};

pub const producer = "arrowlane-zig/0.1.0";
pub const schema_bytes = 480;
pub const metadata_bytes = 504;
pub const node_count = 8;
pub const buffer_count = 18;
pub const node_offset = 376;
pub const buffer_offset = 80;
pub const stride = 16;

const continuation = [_]u8{ 0xff, 0xff, 0xff, 0xff };
const eos = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00 };
const date_base: i32 = 20454;
const timestamp_micros: i64 = 1_793_188_800_000_000;

pub const Summary = struct {
    rows: u64,
    lane: []const u8,
};

const Plan = struct {
    offsets: [buffer_count]usize,
    lengths: [buffer_count]usize,
    body_len: usize,
    name_nulls: u64,
};

fn align8(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

fn decimalDigits(value: usize) usize {
    var v = value;
    var digits: usize = 1;
    while (v >= 10) : (v /= 10) digits += 1;
    return digits;
}

fn nameLength(index: usize) usize {
    if (index % 7 == 0) return 0;
    return 4 + decimalDigits(index);
}

fn plan(start: usize, rows: usize) Plan {
    var result = Plan{
        .offsets = undefined,
        .lengths = undefined,
        .body_len = 0,
        .name_nulls = 0,
    };
    var position: usize = 0;
    const en = rows * 8;
    const name_validity = (rows + 7) / 8;
    var name_data: usize = 0;
    for (start..start + rows) |index| {
        if (index % 7 == 0) result.name_nulls += 1;
        name_data += nameLength(index);
    }

    result.offsets[0] = 0;
    result.lengths[0] = 0;
    result.offsets[1] = position;
    result.lengths[1] = en;
    position += en;

    result.offsets[2] = position;
    result.lengths[2] = name_validity;
    position = align8(position + name_validity);

    result.offsets[3] = position;
    result.lengths[3] = (rows + 1) * 4;
    position = align8(position + result.lengths[3]);

    result.offsets[4] = position;
    result.lengths[4] = name_data;
    position = align8(position + name_data);

    result.offsets[5] = position;
    result.lengths[5] = 0;
    result.offsets[6] = position;
    result.lengths[6] = en;
    position = align8(position + en);

    const bool_len = (rows + 7) / 8;
    result.offsets[7] = position;
    result.lengths[7] = 0;
    result.offsets[8] = position;
    result.lengths[8] = bool_len;
    position = align8(position + bool_len);

    result.offsets[9] = position;
    result.lengths[9] = 0;
    result.offsets[10] = position;
    result.lengths[10] = rows * 4;
    position = align8(position + result.lengths[10]);

    result.offsets[11] = position;
    result.lengths[11] = 0;
    result.offsets[12] = position;
    result.lengths[12] = rows * 16;
    position = align8(position + result.lengths[12]);

    result.offsets[13] = position;
    result.lengths[13] = 0;
    result.offsets[14] = position;
    result.lengths[14] = en;
    position = align8(position + en);

    result.offsets[15] = position;
    result.lengths[15] = 0;
    result.offsets[16] = position;
    result.lengths[16] = (rows + 1) * 4;
    position = align8(position + result.lengths[16]);

    result.offsets[17] = position;
    result.lengths[17] = rows * 3;
    position = align8(position + result.lengths[17]);

    result.body_len = position;
    return result;
}

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

fn schemaBytes(allocator: std.mem.Allocator) Error![]u8 {
    return base64.decode(allocator, fixture_schema.schema_b64) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBase64 => error.BadSchema,
    };
}

fn writeNameData(body: []u8, body_offset: usize, row_start: usize, rows: usize) void {
    var offset: usize = 0;
    var buffer: [32]u8 = undefined;
    for (row_start..row_start + rows) |index| {
        if (index % 7 == 0) continue;
        const text = std.fmt.bufPrint(&buffer, "row-{d}", .{index}) catch unreachable;
        @memcpy(body[body_offset + offset .. body_offset + offset + text.len], text);
        offset += text.len;
    }
}

fn fillBody(body: []u8, values: Plan, row_start: usize, rows: usize) void {
    const name_offsets = body[values.offsets[3] .. values.offsets[3] + values.lengths[3]];
    var name_offset: u32 = 0;
    putU32(name_offsets[0..4], 0);
    for (0..rows) |index| {
        const absolute = row_start + index;
        if (absolute % 7 != 0) name_offset += @intCast(nameLength(absolute));
        putU32(name_offsets[(index + 1) * 4 ..][0..4], name_offset);
    }
    writeNameData(body, values.offsets[4], row_start, rows);

    for (0..rows) |index| {
        const absolute = row_start + index;
        putU64(body[values.offsets[1] + index * 8 ..][0..8], @intCast(absolute));
        const score = @as(f64, @floatFromInt(absolute)) / 3.0;
        putU64(body[values.offsets[6] + index * 8 ..][0..8], @bitCast(score));
        putU64(body[values.offsets[14] + index * 8 ..][0..8], @bitCast(timestamp_micros));
        putU32(body[values.offsets[10] + index * 4 ..][0..4], @intCast(date_base + @as(i32, @intCast(absolute % 28))));
        const amount_offset = values.offsets[12] + index * 16;
        @memset(body[amount_offset .. amount_offset + 16], 0);
        putU64(body[amount_offset .. amount_offset + 8], 1234);
        putU32(body[values.offsets[16] + index * 4 ..][0..4], @intCast(index * 3));
        const blob_offset = values.offsets[17] + index * 3;
        body[blob_offset] = 0;
        body[blob_offset + 1] = 1;
        body[blob_offset + 2] = 2;
    }
    putU32(body[values.offsets[16] + rows * 4 ..][0..4], @intCast(rows * 3));

    if (values.lengths[2] > 0) {
        for (0..rows) |index| {
            const absolute = row_start + index;
            if (absolute % 7 != 0) body[values.offsets[2] + index / 8] |= @as(u8, 1) << @intCast(index % 8);
        }
    }
    if (values.lengths[8] > 0) {
        for (0..rows) |index| {
            const absolute = row_start + index;
            if (absolute % 2 == 0) body[values.offsets[8] + index / 8] |= @as(u8, 1) << @intCast(index % 8);
        }
    }
}

fn headerFor(allocator: std.mem.Allocator, chunk: ?frame.ChunkInfo) Error![]u8 {
    if (chunk) |info| {
        info.validate() catch return error.BadFrame;
        return std.fmt.allocPrint(
            allocator,
            "{{\"chunk\":{{\"id\":\"{s}\",\"index\":{d},\"last\":{s}}},\"media_type\":\"application/vnd.apache.arrow.stream\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
            .{ info.id, info.index, if (info.last) "true" else "false", producer, fixture_schema.schema_b64 },
        ) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/vnd.apache.arrow.stream\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
        .{ producer, fixture_schema.schema_b64 },
    ) catch return error.OutOfMemory;
}

pub fn encodeSample(allocator: std.mem.Allocator, rows: usize) Error![]u8 {
    return encodeRange(allocator, 0, rows);
}

pub fn encodeRange(allocator: std.mem.Allocator, start: usize, rows: usize) Error![]u8 {
    const schema = try schemaBytes(allocator);
    defer allocator.free(schema);
    if (schema.len != schema_bytes) return error.BadSchema;

    const values = plan(start, rows);
    const total = schema.len + 8 + metadata_bytes + values.body_len + eos.len;
    const out = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    @memset(out, 0);

    @memcpy(out[0..schema.len], schema);
    @memcpy(out[schema.len .. schema.len + 4], &continuation);
    putU32(out[schema.len + 4 .. schema.len + 8], metadata_bytes);
    const meta_start = schema.len + 8;
    @memcpy(out[meta_start .. meta_start + metadata_bytes], &fixture_ipc_template.record_batch_template);
    const meta = out[meta_start .. meta_start + metadata_bytes];
    putU64(meta[32..40], @intCast(values.body_len));
    putU64(meta[64..72], @intCast(rows));
    for (0..node_count) |index| {
        putU64(meta[node_offset + index * stride ..][0..8], @intCast(rows));
        putU64(meta[node_offset + index * stride + 8 ..][0..8], if (index == 1) values.name_nulls else 0);
    }
    for (0..buffer_count) |index| {
        putU64(meta[buffer_offset + index * stride ..][0..8], @intCast(values.offsets[index]));
        putU64(meta[buffer_offset + index * stride + 8 ..][0..8], @intCast(values.lengths[index]));
    }

    const body_start = meta_start + metadata_bytes;
    fillBody(out[body_start .. body_start + values.body_len], values, start, rows);
    @memcpy(out[body_start + values.body_len ..][0..eos.len], &eos);
    return out;
}

pub fn validate(allocator: std.mem.Allocator, raw: []const u8) Error!Summary {
    return validateRange(allocator, raw, 0);
}

pub fn validateRange(allocator: std.mem.Allocator, raw: []const u8, start: usize) Error!Summary {
    const schema = try schemaBytes(allocator);
    defer allocator.free(schema);
    if (raw.len < schema.len + 8 + metadata_bytes + eos.len) return error.BadStream;
    if (!std.mem.eql(u8, raw[0..schema.len], schema)) return error.BadSchema;
    if (!std.mem.eql(u8, raw[schema.len .. schema.len + 4], &continuation)) return error.BadStream;
    if (getU32(raw[schema.len + 4 .. schema.len + 8]) != metadata_bytes) return error.BadStream;
    const meta_start = schema.len + 8;
    const meta = raw[meta_start .. meta_start + metadata_bytes];
    const body_len: usize = @intCast(getU64(meta[32..40]));
    const rows: usize = @intCast(getU64(meta[64..72]));
    if (rows > std.math.maxInt(usize) / 16) return error.BadStream;
    const values = plan(start, rows);
    if (body_len != values.body_len) return error.BadStream;
    if (raw.len != meta_start + metadata_bytes + body_len + eos.len) return error.BadStream;
    if (!std.mem.eql(u8, raw[meta_start + metadata_bytes + body_len ..][0..eos.len], &eos)) return error.BadStream;
    for (0..node_count) |index| {
        if (getU64(meta[node_offset + index * stride ..][0..8]) != rows) return error.BadStream;
        const expected_null: u64 = if (index == 1) values.name_nulls else 0;
        if (getU64(meta[node_offset + index * stride + 8 ..][0..8]) != expected_null) return error.BadStream;
    }
    for (0..buffer_count) |index| {
        if (getU64(meta[buffer_offset + index * stride ..][0..8]) != values.offsets[index]) return error.BadStream;
        if (getU64(meta[buffer_offset + index * stride + 8 ..][0..8]) != values.lengths[index]) return error.BadStream;
    }
    return .{ .rows = @intCast(rows), .lane = "ipc" };
}

pub fn encodeFrame(allocator: std.mem.Allocator, rows: usize) Error![]u8 {
    return encodeFrameRange(allocator, 0, rows, null);
}

pub fn encodeFrameRange(allocator: std.mem.Allocator, start: usize, rows: usize, chunk: ?frame.ChunkInfo) Error![]u8 {
    const raw = try encodeRange(allocator, start, rows);
    defer allocator.free(raw);
    const header = try headerFor(allocator, chunk);
    defer allocator.free(header);
    return frame.encode(allocator, .{
        .lane_id = 2,
        .header_json = header,
        .payload = raw,
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
    if (ncols != 8) return error.BadHeader;
    const schema_value = object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, schema_text, fixture_schema.schema_b64)) return error.BadSchema;
    const summary = validateRange(allocator, parsed.payload, start) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
        else => return error.BadFrame,
    };
    if (summary.rows != parsed.rows) return error.BadFrame;
    return summary;
}

/// Check the frame envelope and schema without assuming the exact body padding.
/// Used for chunk streams produced by another implementation.
pub fn summaryFrame(allocator: std.mem.Allocator, wire: []const u8) Error!Summary {
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
    if (ncols != 8) return error.BadHeader;
    const schema_value = object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, schema_text, fixture_schema.schema_b64)) return error.BadSchema;
    return .{ .rows = parsed.rows, .lane = "ipc" };
}

test "fixture ipc body plan for seven rows" {
    const values = plan(0, 7);
    try std.testing.expectEqual(@as(usize, 0), values.offsets[0]);
    try std.testing.expectEqual(@as(usize, 56), values.offsets[2]);
    try std.testing.expectEqual(@as(usize, 1), values.lengths[2]);
    try std.testing.expectEqual(@as(usize, 64), values.offsets[3]);
    try std.testing.expectEqual(@as(usize, 32), values.lengths[3]);
    try std.testing.expectEqual(@as(usize, 96), values.offsets[4]);
    try std.testing.expectEqual(@as(usize, 30), values.lengths[4]);
    try std.testing.expectEqual(@as(usize, 448), values.body_len);
    try std.testing.expectEqual(@as(u64, 1), values.name_nulls);
}

test "fixture ipc round trip shape" {
    const allocator = std.testing.allocator;
    const raw = try encodeSample(allocator, 7);
    defer allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 1448), raw.len);
    const summary = try validate(allocator, raw);
    try std.testing.expectEqual(@as(u64, 7), summary.rows);
    try std.testing.expectEqualStrings("ipc", summary.lane);
}

test "fixture ipc frame round trip shape" {
    const allocator = std.testing.allocator;
    const wire = try encodeFrame(allocator, 500);
    defer allocator.free(wire);
    const summary = try decodeFrame(allocator, wire);
    try std.testing.expectEqual(@as(u64, 500), summary.rows);
}
