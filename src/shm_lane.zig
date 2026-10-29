//! POSIX shared memory descriptor and segment operations for the `shm` lane.
//!
//! The descriptor travels in the frame payload as JSON. The Arrow IPC payload
//! lives in a POSIX segment file under `/dev/shm` or `ARROWLAND_SHM_DIR`.
//! Windows reports `isReady() == false` and rejects segment creation with
//! `error.LaneUnavailable`.

const builtin = @import("builtin");
const std = @import("std");
const fixture_schema = @import("fixture_schema.zig");
const frame = @import("frame.zig");
const ipc_fixture = @import("ipc_fixture.zig");

pub const NAME_PREFIX = "al-";
pub const MAX_SEGMENT_BYTES: usize = 536_870_912;
pub const MIN_TOKEN_LEN: usize = 16;

pub const Error = error{
    LaneUnavailable,
    SegmentError,
    AuthError,
    ChecksumMismatch,
    BadFrame,
    BadHeader,
    BadSchema,
    OversizeFrame,
    OutOfMemory,
};

pub const Descriptor = struct {
    name: []const u8,
    length: u64,
    crc32: u32,
    token: []const u8,
    offset: u64 = 0,

    pub fn deinit(self: Descriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.token);
    }

    pub fn toBytes(self: Descriptor, allocator: std.mem.Allocator) Error![]u8 {
        try validateName(self.name);
        try validateToken(self.token);
        if (self.length == 0 or self.length > MAX_SEGMENT_BYTES) return error.SegmentError;
        return std.fmt.allocPrint(
            allocator,
            "{{\"crc32\":{d},\"length\":{d},\"name\":\"{s}\",\"offset\":{d},\"token\":\"{s}\"}}",
            .{ self.crc32, self.length, self.name, self.offset, self.token },
        ) catch error.OutOfMemory;
    }

    pub fn fromBytes(allocator: std.mem.Allocator, raw: []const u8) Error!Descriptor {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.SegmentError;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.SegmentError,
        };

        var it = obj.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!std.mem.eql(u8, k, "name") and
                !std.mem.eql(u8, k, "length") and
                !std.mem.eql(u8, k, "crc32") and
                !std.mem.eql(u8, k, "token") and
                !std.mem.eql(u8, k, "offset"))
            {
                return error.SegmentError;
            }
        }

        const name_val = obj.get("name") orelse return error.SegmentError;
        const name_str = switch (name_val) {
            .string => |s| s,
            else => return error.SegmentError,
        };
        try validateName(name_str);

        const len_val = obj.get("length") orelse return error.SegmentError;
        const length: u64 = switch (len_val) {
            .integer => |i| if (i > 0 and i <= MAX_SEGMENT_BYTES) @intCast(i) else return error.SegmentError,
            else => return error.SegmentError,
        };

        var offset: u64 = 0;
        if (obj.get("offset")) |off_val| {
            offset = switch (off_val) {
                .integer => |i| if (i >= 0) @intCast(i) else return error.SegmentError,
                else => return error.SegmentError,
            };
        }

        const crc_val = obj.get("crc32") orelse return error.SegmentError;
        const crc32: u32 = switch (crc_val) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return error.SegmentError,
            else => return error.SegmentError,
        };

        const tok_val = obj.get("token") orelse return error.SegmentError;
        const tok_str = switch (tok_val) {
            .string => |s| s,
            else => return error.SegmentError,
        };
        try validateToken(tok_str);

        const owned_name = allocator.dupe(u8, name_str) catch return error.OutOfMemory;
        errdefer allocator.free(owned_name);
        const owned_token = allocator.dupe(u8, tok_str) catch return error.OutOfMemory;

        return .{
            .name = owned_name,
            .length = length,
            .crc32 = crc32,
            .token = owned_token,
            .offset = offset,
        };
    }
};

pub fn validateName(name: []const u8) Error!void {
    if (!std.mem.startsWith(u8, name, NAME_PREFIX)) return error.SegmentError;
    if (name.len <= NAME_PREFIX.len) return error.SegmentError;
    for (name) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0 or ch == '"' or ch < 0x20) return error.SegmentError;
    }
}

pub fn validateToken(token: []const u8) Error!void {
    if (token.len < MIN_TOKEN_LEN) return error.SegmentError;
    for (token) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20) return error.SegmentError;
    }
}

pub fn constantTimeEq(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var diff: u8 = 0;
    for (left, right) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Validate a descriptor's [offset, offset + length) range against a known file size.
pub fn validateRange(descriptor: Descriptor, file_size: u64) Error!struct { offset: usize, length: usize } {
    const end_u64 = std.math.add(u64, descriptor.offset, descriptor.length) catch return error.SegmentError;
    if (end_u64 != file_size) return error.SegmentError;
    const offset = std.math.cast(usize, descriptor.offset) orelse return error.SegmentError;
    const length = std.math.cast(usize, descriptor.length) orelse return error.SegmentError;
    _ = std.math.add(usize, offset, length) catch return error.SegmentError;
    return .{ .offset = offset, .length = length };
}

pub fn isPosixTag(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .linux, .macos, .freebsd => true,
        else => false,
    };
}

pub fn isPosix() bool {
    return isPosixTag(builtin.os.tag);
}

pub fn isReady() bool {
    return isPosix();
}

/// Write a segment into `dir_path` (POSIX only) and return a Descriptor.
pub fn writeSegmentInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
    token: []const u8,
    data: []const u8,
) Error!Descriptor {
    if (!isPosix()) return error.LaneUnavailable;
    if (data.len == 0 or data.len > MAX_SEGMENT_BYTES) return error.SegmentError;
    try validateName(name);
    try validateToken(token);

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch return error.OutOfMemory;
    defer allocator.free(path);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return error.SegmentError;

    const owned_name = allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer allocator.free(owned_name);
    const owned_token = allocator.dupe(u8, token) catch return error.OutOfMemory;

    return .{
        .name = owned_name,
        .length = @intCast(data.len),
        .crc32 = std.hash.Crc32.hash(data),
        .token = owned_token,
        .offset = 0,
    };
}

/// Read, verify, and unlink a segment from `dir_path` (POSIX only).
pub fn readSegmentFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    descriptor: Descriptor,
    token: []const u8,
    verify_crc: bool,
) Error![]u8 {
    if (!isPosix()) return error.LaneUnavailable;
    try validateName(descriptor.name);
    if (!constantTimeEq(descriptor.token, token)) return error.AuthError;

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, descriptor.name }) catch return error.OutOfMemory;
    defer allocator.free(path);

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_SEGMENT_BYTES)) catch return error.SegmentError;
    defer allocator.free(file_bytes);

    const range = try validateRange(descriptor, @intCast(file_bytes.len));
    const slice = file_bytes[range.offset .. range.offset + range.length];

    if (verify_crc and std.hash.Crc32.hash(slice) != descriptor.crc32) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return error.ChecksumMismatch;
    }

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return allocator.dupe(u8, slice) catch error.OutOfMemory;
}

/// Encode the canonical 8-column fixture into a segment and return the lane-4 wire frame.
pub fn encodeFixtureFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
    token: []const u8,
    rows: usize,
) Error![]u8 {
    if (!isPosix()) return error.LaneUnavailable;
    const raw = ipc_fixture.encodeRange(allocator, 0, rows) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFrame,
    };
    defer allocator.free(raw);

    const desc = try writeSegmentInDir(allocator, io, dir_path, name, token, raw);
    defer desc.deinit(allocator);

    const payload = try desc.toBytes(allocator);
    defer allocator.free(payload);

    const header = std.fmt.allocPrint(
        allocator,
        "{{\"media_type\":\"application/vnd.arrowlane.shm\",\"ncols\":8,\"producer\":\"arrowlane-zig/0.3.0\",\"schema\":\"{s}\",\"segment\":\"{s}\"}}",
        .{ fixture_schema.schema_b64, name },
    ) catch return error.OutOfMemory;
    defer allocator.free(header);

    return frame.encode(allocator, .{
        .lane_id = 4,
        .header_json = header,
        .payload = payload,
        .rows = @intCast(rows),
        .uncompressed_len = @intCast(raw.len),
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFrame,
    };
}

/// Decode a lane-4 wire frame, read and unlink its segment, and validate the fixture IPC payload.
pub fn decodeFixtureFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    token: []const u8,
    wire: []const u8,
) Error!ipc_fixture.Summary {
    if (!isPosix()) return error.LaneUnavailable;
    const parsed = frame.decode(allocator, wire, .{}) catch return error.BadFrame;
    if (parsed.lane_id != 4) return error.BadFrame;

    const desc = try Descriptor.fromBytes(allocator, parsed.payload);
    defer desc.deinit(allocator);

    if (desc.length != parsed.uncompressed_len) return error.SegmentError;

    const raw = try readSegmentFromDir(allocator, io, dir_path, desc, token, true);
    defer allocator.free(raw);

    const summary = ipc_fixture.validateRange(allocator, raw, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSchema => return error.BadSchema,
        else => return error.BadFrame,
    };
    if (summary.rows != parsed.rows) return error.BadFrame;
    return .{ .rows = summary.rows, .lane = "shm" };
}

test "shm descriptor roundtrip" {
    const allocator = std.testing.allocator;
    const desc = Descriptor{
        .name = "al-abc123",
        .length = 10,
        .crc32 = 7,
        .token = "0123456789abcdef",
        .offset = 0,
    };
    const raw = try desc.toBytes(allocator);
    defer allocator.free(raw);

    const parsed = try Descriptor.fromBytes(allocator, raw);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings(desc.name, parsed.name);
    try std.testing.expectEqual(desc.length, parsed.length);
    try std.testing.expectEqual(desc.crc32, parsed.crc32);
    try std.testing.expectEqualStrings(desc.token, parsed.token);
    try std.testing.expectEqual(desc.offset, parsed.offset);
}

test "shm descriptor rejects bad name, short token, and unknown keys" {
    const allocator = std.testing.allocator;
    const bad_name = "{\"name\":\"evil\",\"length\":10,\"crc32\":1,\"token\":\"0123456789abcdef\",\"offset\":0}";
    try std.testing.expectError(error.SegmentError, Descriptor.fromBytes(allocator, bad_name));

    const path_sep = "{\"name\":\"al-../x\",\"length\":10,\"crc32\":1,\"token\":\"0123456789abcdef\",\"offset\":0}";
    try std.testing.expectError(error.SegmentError, Descriptor.fromBytes(allocator, path_sep));

    const short_tok = "{\"name\":\"al-x\",\"length\":10,\"crc32\":1,\"token\":\"short\",\"offset\":0}";
    try std.testing.expectError(error.SegmentError, Descriptor.fromBytes(allocator, short_tok));

    const extra_key = "{\"name\":\"al-x\",\"length\":10,\"crc32\":1,\"token\":\"0123456789abcdef\",\"extra\":1}";
    try std.testing.expectError(error.SegmentError, Descriptor.fromBytes(allocator, extra_key));
}

test "shm descriptor range overflow is rejected" {
    const desc = Descriptor{
        .name = "al-overflow",
        .length = 1,
        .crc32 = 0,
        .token = "0123456789abcdef",
        .offset = std.math.maxInt(u64),
    };
    try std.testing.expectError(error.SegmentError, validateRange(desc, 0));
}

test "shm posix segment roundtrip and wrong token rejection" {
    if (!isPosix()) return;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const wire = try encodeFixtureFrame(allocator, io, "/tmp", "al-zig-test-seg", "token-0123456789", 7);
    defer allocator.free(wire);

    try std.testing.expectError(
        error.AuthError,
        decodeFixtureFrame(allocator, io, "/tmp", "token-9876543210", wire),
    );

    const summary = try decodeFixtureFrame(allocator, io, "/tmp", "token-0123456789", wire);
    try std.testing.expectEqual(@as(u64, 7), summary.rows);
    try std.testing.expectEqualStrings("shm", summary.lane);
}

test "posix platform tags include FreeBSD and reject NetBSD" {
    try std.testing.expect(isPosixTag(.linux));
    try std.testing.expect(isPosixTag(.macos));
    try std.testing.expect(isPosixTag(.freebsd));
    try std.testing.expect(!isPosixTag(.netbsd));
    try std.testing.expect(!isPosixTag(.windows));
}
