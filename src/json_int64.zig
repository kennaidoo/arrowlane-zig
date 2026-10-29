//! One-column JSON lane for the int64 schema spike.
//!
//! This is an end-to-end vertical slice, not the general JSON lane. It emits
//! NDJSON objects `{"a": value}` and the exact int64 schema message in the
//! frame header. Python can decode the result with the normal JsonLane.

const std = @import("std");
const base64 = @import("base64.zig");
const frame = @import("frame.zig");
const schema = @import("schema.zig");

pub const Error = error{
    BadFrame,
    BadHeader,
    BadPayload,
    BadSchema,
    OutOfMemory,
};

pub const producer = "arrowlane-zig/0.3.0";

pub fn encode(allocator: std.mem.Allocator, values: []const ?i64) Error![]u8 {
    var nullable = false;
    for (values) |value| {
        if (value == null) {
            nullable = true;
            break;
        }
    }

    const raw_schema = try schema.encodeInt64(allocator, nullable);
    defer allocator.free(raw_schema);
    const encoded_schema = base64.encode(allocator, raw_schema) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return error.BadSchema,
    };
    defer allocator.free(encoded_schema);

    const header = std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/x-ndjson\",\"ncols\":1,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
        .{ producer, encoded_schema },
    ) catch return error.OutOfMemory;
    defer allocator.free(header);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index > 0) payload.append(allocator, '\n') catch return error.OutOfMemory;
        if (value) |number| {
            const line = std.fmt.allocPrint(allocator, "{{\"a\":{d}}}", .{number}) catch return error.OutOfMemory;
            defer allocator.free(line);
            payload.appendSlice(allocator, line) catch return error.OutOfMemory;
        } else {
            payload.appendSlice(allocator, "{\"a\":null}") catch return error.OutOfMemory;
        }
    }

    return frame.encode(allocator, .{
        .lane_id = 1,
        .header_json = header,
        .payload = payload.items,
        .rows = values.len,
        .uncompressed_len = payload.items.len,
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFrame,
    };
}

pub fn decode(allocator: std.mem.Allocator, wire: []const u8) Error![]?i64 {
    const parsed_frame = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed_frame.lane_id != 1) return error.BadFrame;
    if (parsed_frame.uncompressed_len != parsed_frame.payload.len) return error.BadFrame;
    if (parsed_frame.rows > std.math.maxInt(usize)) return error.BadFrame;

    var header = std.json.parseFromSlice(std.json.Value, allocator, parsed_frame.header_json, .{}) catch return error.BadHeader;
    defer header.deinit();
    const header_object = switch (header.value) {
        .object => |object| object,
        else => return error.BadHeader,
    };
    const ncols_value = header_object.get("ncols") orelse return error.BadHeader;
    const ncols: u64 = switch (ncols_value) {
        .integer => |value| @intCast(value),
        else => return error.BadHeader,
    };
    if (ncols != 1) return error.BadHeader;
    const schema_value = header_object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |value| value,
        else => return error.BadHeader,
    };
    const raw_schema = base64.decode(allocator, schema_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return error.BadHeader,
    };
    defer allocator.free(raw_schema);
    const nullable = schema.nullableOfInt64(allocator, raw_schema) catch return error.BadSchema;

    var values: std.ArrayList(?i64) = .empty;
    defer values.deinit(allocator);
    var lines = std.mem.splitScalar(u8, parsed_frame.payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var row = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.BadPayload;
        defer row.deinit();
        const object = switch (row.value) {
            .object => |value| value,
            else => return error.BadPayload,
        };
        if (object.count() != 1) return error.BadPayload;
        const field = object.get("a") orelse return error.BadPayload;
        const value: ?i64 = switch (field) {
            .null => null,
            .integer => |number| number,
            else => return error.BadPayload,
        };
        if (value == null and !nullable) return error.BadPayload;
        values.append(allocator, value) catch return error.OutOfMemory;
    }
    const owned = values.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(owned);
    if (owned.len != parsed_frame.rows) return error.BadFrame;
    return owned;
}

test "json int64 round trip" {
    const allocator = std.testing.allocator;
    const values = [_]?i64{ 1, -2, null, 4 };
    const wire = try encode(allocator, &values);
    defer allocator.free(wire);
    const decoded = try decode(allocator, wire);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(?i64, &values, decoded);
}

test "json int64 non-nullable rejects null" {
    const allocator = std.testing.allocator;
    const values = [_]?i64{ 1, 2 };
    const wire = try encode(allocator, &values);
    defer allocator.free(wire);
    const decoded = try decode(allocator, wire);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(?i64, &values, decoded);
}
