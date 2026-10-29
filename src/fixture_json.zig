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
pub const producer = "arrowlane-zig/0.3.0";

pub const Summary = struct {
    rows: u64,
    lane: []const u8,
};

fn appendText(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) Error!void {
    list.appendSlice(allocator, text) catch return error.OutOfMemory;
}

pub fn encodeSample(allocator: std.mem.Allocator, rows: usize) Error![]u8 {
    return encodeRange(allocator, 0, rows, null);
}

pub fn encodeRange(allocator: std.mem.Allocator, start: usize, rows: usize, chunk: ?frame.ChunkInfo) Error![]u8 {
    const header = if (chunk) |info| blk: {
        info.validate() catch return error.BadFrame;
        break :blk std.fmt.allocPrint(
            allocator,
            "{{\"chunk\":{{\"id\":\"{s}\",\"index\":{d},\"last\":{s}}},\"media_type\":\"application/x-ndjson\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
            .{ info.id, info.index, if (info.last) "true" else "false", producer, fixture_schema.schema_b64 },
        ) catch return error.OutOfMemory;
    } else std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/x-ndjson\",\"ncols\":8,\"producer\":\"{s}\",\"schema\":\"{s}\"}}",
        .{ producer, fixture_schema.schema_b64 },
    ) catch return error.OutOfMemory;
    defer allocator.free(header);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    payload.ensureTotalCapacity(allocator, rows * 215) catch return error.OutOfMemory;

    var buf: [256]u8 = undefined;
    for (0..rows) |index| {
        const absolute = start + index;
        if (index > 0) try appendText(&payload, allocator, "\n");
        const day_num = absolute % 28 + 1;
        const ok_str = if (absolute % 2 == 0) "true" else "false";
        const score = @as(f64, @floatFromInt(absolute)) / 3.0;
        const row = if (absolute % 7 == 0)
            std.fmt.bufPrint(
                &buf,
                "{{\"id\":{d},\"name\":null,\"score\":{d},\"ok\":{s},\"day\":{{\"$\":\"date\",\"v\":\"2026-01-{d:0>2}\"}},\"amount\":{{\"$\":\"dec\",\"v\":\"12.34\"}},\"ts\":{{\"$\":\"ts\",\"v\":\"2026-10-28T12:00:00+00:00\"}},\"blob\":{{\"$\":\"bin\",\"v\":\"AAEC\"}}}}",
                .{ absolute, score, ok_str, day_num },
            ) catch return error.BadFrame
        else
            std.fmt.bufPrint(
                &buf,
                "{{\"id\":{d},\"name\":\"row-{d}\",\"score\":{d},\"ok\":{s},\"day\":{{\"$\":\"date\",\"v\":\"2026-01-{d:0>2}\"}},\"amount\":{{\"$\":\"dec\",\"v\":\"12.34\"}},\"ts\":{{\"$\":\"ts\",\"v\":\"2026-10-28T12:00:00+00:00\"}},\"blob\":{{\"$\":\"bin\",\"v\":\"AAEC\"}}}}",
                .{ absolute, absolute, score, ok_str, day_num },
            ) catch return error.BadFrame;
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

const TaggedObj = struct {
    @"$": []const u8,
    v: []const u8,
};

const FixtureRow = struct {
    id: i64,
    name: ?[]const u8 = null,
    score: f64,
    ok: bool,
    day: TaggedObj,
    amount: TaggedObj,
    ts: TaggedObj,
    blob: TaggedObj,
};

fn isTaggedObj(value: TaggedObj, tag: []const u8) bool {
    return std.mem.eql(u8, value.@"$", tag);
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
    var row_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&row_buf);
    var lines = std.mem.splitScalar(u8, parsed_frame.payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        fba.reset();
        const row_alloc = fba.allocator();
        const row = std.json.parseFromSliceLeaky(FixtureRow, row_alloc, line, .{ .ignore_unknown_fields = false }) catch return error.BadPayload;
        if (!isTaggedObj(row.day, "date")) return error.BadPayload;
        if (!isTaggedObj(row.amount, "dec")) return error.BadPayload;
        if (!isTaggedObj(row.ts, "ts")) return error.BadPayload;
        if (!isTaggedObj(row.blob, "bin")) return error.BadPayload;
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
