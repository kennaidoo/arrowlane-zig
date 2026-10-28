//! Fixture-scoped JSON lane for the canonical eight-column table.
//!
//! This is a compatibility slice. The schema message is pinned to the exact
//! bytes that `interop/check_wire.py` writes. It is not a general Arrow schema
//! codec and must not be described as one.

const std = @import("std");
const fixture_schema = @import("fixture_schema.zig");
const frame = @import("frame.zig");

pub const Error = error{
    BadFrame,
    BadHeader,
    BadPayload,
    BadSchema,
    OutOfMemory,
};

pub const columns: usize = 8;
pub const producer = "arrowlane-zig/0.1.0";

pub const Summary = struct {
    rows: u64,
    lane: []const u8,
};

fn appendText(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) Error!void {
    list.appendSlice(allocator, text) catch return error.OutOfMemory;
}

pub fn encodeSample(allocator: std.mem.Allocator, rows: usize) Error![]u8 {
    const header = std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/x-ndjson\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
        .{ producer, fixture_schema.schema_b64 },
    ) catch return error.OutOfMemory;
    defer allocator.free(header);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    for (0..rows) |index| {
        if (index > 0) try appendText(&payload, allocator, "\n");
        const name = if (index % 7 == 0)
            allocator.dupe(u8, "null") catch return error.OutOfMemory
        else
            std.fmt.allocPrint(allocator, "\"row-{d}\"", .{index}) catch return error.OutOfMemory;
        defer allocator.free(name);
        const day = std.fmt.allocPrint(
            allocator,
            "\"2026-01-{d:0>2}\"",
            .{index % 28 + 1},
        ) catch return error.OutOfMemory;
        defer allocator.free(day);
        const score = @as(f64, @floatFromInt(index)) / 3.0;
        const row = std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"name\":{s},\"score\":{d},\"ok\":{s},\"day\":{{\"$\":\"date\",\"v\":{s}}},\"amount\":{{\"$\":\"dec\",\"v\":\"12.34\"}},\"ts\":{{\"$\":\"ts\",\"v\":\"2026-10-28T12:00:00+00:00\"}},\"blob\":{{\"$\":\"bin\",\"v\":\"AAEC\"}}}}",
            .{ index, name, score, if (index % 2 == 0) "true" else "false", day },
        ) catch return error.OutOfMemory;
        defer allocator.free(row);
        try appendText(&payload, allocator, row);
    }

    return frame.encode(allocator, .{
        .lane_id = 1,
        .header_json = header,
        .payload = payload.items,
        .rows = @intCast(rows),
        .uncompressed_len = payload.items.len,
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFrame,
    };
}

fn isTagged(value: std.json.Value, tag: []const u8) bool {
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    if (object.count() != 2) return false;
    const tag_value = object.get("$") orelse return false;
    const payload_value = object.get("v") orelse return false;
    const tag_text = switch (tag_value) {
        .string => |text| text,
        else => return false,
    };
    if (!std.mem.eql(u8, tag_text, tag)) return false;
    return switch (payload_value) {
        .string => true,
        else => false,
    };
}

fn isIntegerOrFloat(value: std.json.Value) bool {
    return switch (value) {
        .integer, .float => true,
        else => false,
    };
}

pub fn validate(allocator: std.mem.Allocator, wire: []const u8) Error!Summary {
    const parsed_frame = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed_frame.lane_id != 1) return error.BadFrame;
    if (parsed_frame.uncompressed_len != parsed_frame.payload.len) return error.BadFrame;

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
    if (ncols != columns) return error.BadHeader;
    const schema_value = header_object.get("schema") orelse return error.BadHeader;
    const schema_text = switch (schema_value) {
        .string => |text| text,
        else => return error.BadHeader,
    };
    if (!std.mem.eql(u8, schema_text, fixture_schema.schema_b64)) return error.BadSchema;

    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, parsed_frame.payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var row = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.BadPayload;
        defer row.deinit();
        const object = switch (row.value) {
            .object => |value| value,
            else => return error.BadPayload,
        };
        if (object.count() != columns) return error.BadPayload;

        const id = object.get("id") orelse return error.BadPayload;
        switch (id) {
            .integer => {},
            else => return error.BadPayload,
        }
        const name = object.get("name") orelse return error.BadPayload;
        switch (name) {
            .string, .null => {},
            else => return error.BadPayload,
        }
        const score = object.get("score") orelse return error.BadPayload;
        if (!isIntegerOrFloat(score)) return error.BadPayload;
        const ok = object.get("ok") orelse return error.BadPayload;
        switch (ok) {
            .bool => {},
            else => return error.BadPayload,
        }
        const day = object.get("day") orelse return error.BadPayload;
        if (!isTagged(day, "date")) return error.BadPayload;
        const amount = object.get("amount") orelse return error.BadPayload;
        if (!isTagged(amount, "dec")) return error.BadPayload;
        const ts = object.get("ts") orelse return error.BadPayload;
        if (!isTagged(ts, "ts")) return error.BadPayload;
        const blob = object.get("blob") orelse return error.BadPayload;
        if (!isTagged(blob, "bin")) return error.BadPayload;
        count += 1;
    }
    if (count != parsed_frame.rows) return error.BadFrame;
    return .{ .rows = count, .lane = "json" };
}

test "fixture json round trip shape" {
    const allocator = std.testing.allocator;
    const wire = try encodeSample(allocator, 7);
    defer allocator.free(wire);
    const summary = try validate(allocator, wire);
    try std.testing.expectEqual(@as(u64, 7), summary.rows);
    try std.testing.expectEqualStrings("json", summary.lane);
}

test "fixture json rejects a different schema" {
    const allocator = std.testing.allocator;
    const wire = try encodeSample(allocator, 1);
    defer allocator.free(wire);
    const changed = try allocator.dupe(u8, wire);
    defer allocator.free(changed);
    changed[20] ^= 0xFF;
    try std.testing.expectError(error.BadFrame, validate(allocator, changed));
}
