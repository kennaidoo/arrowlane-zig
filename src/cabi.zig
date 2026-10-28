//! C ABI for the fixture build.
//!
//! Exports use C primitives and `extern struct` values only. Returned buffers
//! and reason strings are owned by the caller and released with `al_free` or
//! `al_free_reason`.

const std = @import("std");
const arrowlane = @import("arrowlane");

pub const AL_OK: c_int = 0;
pub const AL_ERR_INVALID: c_int = -1;
pub const AL_ERR_FRAME: c_int = -2;
pub const AL_ERR_PANIC: c_int = -3;
pub const AL_ERR_BUFFER: c_int = -4;

pub const AlBuffer = extern struct {
    data: ?[*]u8,
    len: usize,
    cap: usize,
};

pub const AlDecision = extern struct {
    lane_id: u8,
    predicted_ms: f64,
    predicted_bytes: u64,
    reason: ?[*:0]const u8,
};

const allocator = std.heap.c_allocator;

fn emptyBuffer() AlBuffer {
    return .{ .data = null, .len = 0, .cap = 0 };
}

fn bufferFrom(bytes: []const u8) AlBuffer {
    const storage = allocator.alloc(u8, bytes.len) catch return emptyBuffer();
    @memcpy(storage, bytes);
    return .{ .data = storage.ptr, .len = storage.len, .cap = storage.len };
}

fn reasonFrom(text: []const u8) ?[*:0]const u8 {
    const storage = allocator.allocSentinel(u8, text.len, 0) catch return null;
    @memcpy(storage[0..text.len], text);
    return storage.ptr;
}

fn laneName(id: u8) ?[]const u8 {
    return arrowlane.frame.laneName(id);
}

fn summaryFor(allocator_arg: std.mem.Allocator, wire: []const u8) ?struct { rows: u64, lane: []const u8 } {
    const parsed = arrowlane.frame.decode(allocator_arg, wire, .{}) catch return null;
    return switch (parsed.lane_id) {
        1 => blk: {
            const value = arrowlane.fixture_json.validate(allocator_arg, wire) catch break :blk null;
            break :blk .{ .rows = value.rows, .lane = "json" };
        },
        2 => blk: {
            const value = arrowlane.ipc_fixture.summaryFrame(allocator_arg, wire) catch break :blk null;
            break :blk .{ .rows = value.rows, .lane = "ipc" };
        },
        3 => blk: {
            const value = arrowlane.ipc_zstd.summaryFrame(allocator_arg, wire) catch break :blk null;
            break :blk .{ .rows = value.rows, .lane = "ipc-zstd" };
        },
        else => null,
    };
}

export fn al_version() [*:0]const u8 {
    return "0.1.0";
}

export fn al_select(
    rows: u64,
    arrow_bytes: u64,
    topology: u8,
    policy: u8,
    shm_ready: bool,
    out: ?*AlDecision,
) c_int {
    const destination = out orelse return AL_ERR_INVALID;
    const topology_value: arrowlane.select.Topology = switch (topology) {
        0 => .same_host,
        1 => .same_network,
        2 => .wide_area,
        else => return AL_ERR_INVALID,
    };
    const policy_value: arrowlane.select.Policy = switch (policy) {
        0 => .latency,
        1 => .throughput,
        2 => .cpu,
        else => return AL_ERR_INVALID,
    };
    const decision = arrowlane.select.select(
        &arrowlane.costmodel.default_model,
        .{ .rows = rows, .arrow_bytes = arrow_bytes },
        topology_value,
        policy_value,
        null,
        shm_ready,
        0.10,
    ) catch return AL_ERR_INVALID;
    const reason = reasonFrom(decision.reason) orelse return AL_ERR_BUFFER;
    destination.* = .{
        .lane_id = arrowlane.frame.laneId(decision.lane) orelse 0,
        .predicted_ms = decision.predicted_ms,
        .predicted_bytes = decision.predicted_bytes,
        .reason = reason,
    };
    return AL_OK;
}

export fn al_inspect(data: ?[*]const u8, len: usize) AlBuffer {
    if (data == null or len == 0) return emptyBuffer();
    const wire = data.?[0..len];
    const summary = summaryFor(allocator, wire) orelse return emptyBuffer();
    const parsed = arrowlane.frame.decode(allocator, wire, .{}) catch return emptyBuffer();
    const output = std.fmt.allocPrint(
        allocator,
        "{{\"lane\":\"{s}\",\"rows\":{d},\"columns\":8,\"wire_bytes\":{d},\"uncompressed_bytes\":{d}}}",
        .{ summary.lane, summary.rows, len, parsed.uncompressed_len },
    ) catch return emptyBuffer();
    defer allocator.free(output);
    return bufferFrom(output);
}

export fn al_repack(data: ?[*]const u8, len: usize, lane_id: u8) AlBuffer {
    if (data == null or len == 0) return emptyBuffer();
    const wire = data.?[0..len];
    const parsed = arrowlane.frame.decode(allocator, wire, .{}) catch return emptyBuffer();
    if (parsed.lane_id != 1 and parsed.lane_id != 2 and parsed.lane_id != 3) return emptyBuffer();
    const output = switch (lane_id) {
        1 => arrowlane.fixture_json.encodeSample(allocator, @intCast(parsed.rows)) catch return emptyBuffer(),
        2 => arrowlane.ipc_fixture.encodeFrame(allocator, @intCast(parsed.rows)) catch return emptyBuffer(),
        3 => arrowlane.ipc_zstd.encodeFrame(allocator, @intCast(parsed.rows)) catch return emptyBuffer(),
        else => return emptyBuffer(),
    };
    defer allocator.free(output);
    return bufferFrom(output);
}

export fn al_free(buffer: AlBuffer) void {
    if (buffer.data) |data| {
        if (buffer.cap > 0) allocator.free(data[0..buffer.cap]);
    }
}

export fn al_free_reason(reason: ?[*:0]const u8) void {
    const pointer = reason orelse return;
    const length = std.mem.len(pointer);
    allocator.free(pointer[0 .. length + 1]);
}

comptime {
    std.debug.assert(@sizeOf(AlBuffer) == 24);
    std.debug.assert(@sizeOf(AlDecision) == 32);
    std.debug.assert(@offsetOf(AlDecision, "predicted_ms") == 8);
    std.debug.assert(@offsetOf(AlDecision, "reason") == 24);
}
