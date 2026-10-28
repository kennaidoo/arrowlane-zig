//! The wire frame: a 38 byte prefix, a JSON header and an opaque payload.
//!
//! The prefix is fixed width so a reader can reject bad lengths and a bad
//! checksum before it parses the header or allocates for the payload.

const std = @import("std");

pub const MAGIC = "ALN1";
pub const VERSION: u8 = 1;
pub const HEADER_SIZE: usize = 38;
pub const MAX_HEADER_BYTES: usize = 65_535;
pub const MAX_PAYLOAD_BYTES: usize = 536_870_912;
pub const MAX_UNCOMPRESSED_BYTES: usize = 1_073_741_824;
pub const MAX_CHUNKS: u64 = 1_000_000;

pub const FRAME_MEDIA_TYPE = "application/vnd.arrowlane.frame";

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    UnknownLane,
    Truncated,
    TrailingBytes,
    HeaderTooLarge,
    PayloadTooLarge,
    UncompressedTooLarge,
    ChecksumMismatch,
    BadHeader,
    OutOfMemory,
};

/// Where one frame sits in a chunked stream.
pub const ChunkInfo = struct {
    id: []const u8,
    index: u64,
    last: bool,

    pub fn validate(self: ChunkInfo) Error!void {
        if (self.id.len != 32) return error.BadHeader;
        for (self.id) |byte| {
            const lower = byte >= 'a' and byte <= 'f';
            const digit = byte >= '0' and byte <= '9';
            if (!lower and !digit) return error.BadHeader;
        }
        if (self.index >= MAX_CHUNKS) return error.BadHeader;
    }
};

/// One frame. The header and payload slices are borrowed from the caller.
pub const Frame = struct {
    lane_id: u8,
    header_json: []const u8,
    payload: []const u8,
    rows: u64,
    uncompressed_len: u64,
    flags: u16 = 0,

    pub fn lane(self: Frame) ?[]const u8 {
        return laneName(self.lane_id);
    }
};

pub const EncodeOptions = struct {
    max_payload: usize = MAX_PAYLOAD_BYTES,
    max_uncompressed: usize = MAX_UNCOMPRESSED_BYTES,
};

pub const DecodeOptions = struct {
    max_payload: usize = MAX_PAYLOAD_BYTES,
    max_uncompressed: usize = MAX_UNCOMPRESSED_BYTES,
};

pub fn laneId(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "json")) return 1;
    if (std.mem.eql(u8, name, "ipc")) return 2;
    if (std.mem.eql(u8, name, "ipc-zstd")) return 3;
    if (std.mem.eql(u8, name, "shm")) return 4;
    return null;
}

pub fn laneName(id: u8) ?[]const u8 {
    return switch (id) {
        1 => "json",
        2 => "ipc",
        3 => "ipc-zstd",
        4 => "shm",
        else => null,
    };
}

fn putU16(out: []u8, value: u16) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
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

fn getU16(in: []const u8) u16 {
    return @as(u16, in[0]) | (@as(u16, in[1]) << 8);
}

fn getU32(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

fn getU64(in: []const u8) u64 {
    var value: u64 = 0;
    for (in[0..8], 0..) |byte, index| {
        value |= @as(u64, byte) << @intCast(index * 8);
    }
    return value;
}

fn isJsonObject(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return text.len >= 2 and text[0] == '{' and text[text.len - 1] == '}';
}

fn checkOptions(options: EncodeOptions) Error!void {
    if (options.max_payload > MAX_PAYLOAD_BYTES) return error.PayloadTooLarge;
    if (options.max_uncompressed > MAX_UNCOMPRESSED_BYTES) return error.UncompressedTooLarge;
}

/// Encode one frame. The returned buffer is owned by the caller.
pub fn encode(allocator: std.mem.Allocator, frame: Frame, options: EncodeOptions) Error![]u8 {
    try checkOptions(options);
    if (laneName(frame.lane_id) == null) return error.UnknownLane;
    if (frame.header_json.len > MAX_HEADER_BYTES) return error.HeaderTooLarge;
    if (frame.payload.len > options.max_payload) return error.PayloadTooLarge;
    if (frame.uncompressed_len > options.max_uncompressed) return error.UncompressedTooLarge;
    if (!isJsonObject(frame.header_json)) return error.BadHeader;
    if (!std.unicode.utf8ValidateSlice(frame.header_json)) return error.BadHeader;
    const valid = std.json.validate(allocator, frame.header_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!valid) return error.BadHeader;

    const total = HEADER_SIZE + frame.header_json.len + frame.payload.len;
    const out = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    @memcpy(out[0..4], MAGIC);
    out[4] = VERSION;
    out[5] = frame.lane_id;
    putU16(out[6..8], frame.flags);
    putU64(out[8..16], @intCast(frame.payload.len));
    putU64(out[16..24], frame.uncompressed_len);
    putU64(out[24..32], frame.rows);
    putU32(out[32..36], std.hash.Crc32.hash(frame.payload));
    putU16(out[36..38], @intCast(frame.header_json.len));
    @memcpy(out[HEADER_SIZE .. HEADER_SIZE + frame.header_json.len], frame.header_json);
    @memcpy(out[HEADER_SIZE + frame.header_json.len ..], frame.payload);
    return out;
}

/// Decode one exact frame. The returned slices point into `data`.
pub fn decode(allocator: std.mem.Allocator, data: []const u8, options: DecodeOptions) Error!Frame {
    if (options.max_payload > MAX_PAYLOAD_BYTES) return error.PayloadTooLarge;
    if (options.max_uncompressed > MAX_UNCOMPRESSED_BYTES) return error.UncompressedTooLarge;
    if (data.len < HEADER_SIZE) return error.Truncated;
    if (!std.mem.eql(u8, data[0..4], MAGIC)) return error.BadMagic;
    if (data[4] != VERSION) return error.UnsupportedVersion;
    const lane_id = data[5];
    if (laneName(lane_id) == null) return error.UnknownLane;

    const flags = getU16(data[6..8]);
    const payload_len_u64 = getU64(data[8..16]);
    const uncompressed_len = getU64(data[16..24]);
    const rows = getU64(data[24..32]);
    const checksum = getU32(data[32..36]);
    const header_len = getU16(data[36..38]);

    if (header_len > MAX_HEADER_BYTES) return error.HeaderTooLarge;
    if (payload_len_u64 > options.max_payload) return error.PayloadTooLarge;
    if (uncompressed_len > options.max_uncompressed) return error.UncompressedTooLarge;

    const payload_len: usize = std.math.cast(usize, payload_len_u64) orelse return error.PayloadTooLarge;
    const expected = std.math.add(usize, HEADER_SIZE + @as(usize, header_len), payload_len) catch return error.Truncated;
    if (data.len < expected) return error.Truncated;
    if (data.len > expected) return error.TrailingBytes;

    const header = data[HEADER_SIZE .. HEADER_SIZE + header_len];
    const payload = data[HEADER_SIZE + header_len .. expected];
    if (!isJsonObject(header)) return error.BadHeader;
    if (!std.unicode.utf8ValidateSlice(header)) return error.BadHeader;
    const valid = std.json.validate(allocator, header) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!valid) return error.BadHeader;
    if (std.hash.Crc32.hash(payload) != checksum) return error.ChecksumMismatch;

    return .{
        .lane_id = lane_id,
        .header_json = header,
        .payload = payload,
        .rows = rows,
        .uncompressed_len = uncompressed_len,
        .flags = flags,
    };
}

test "crc32 known vector" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

test "round trip" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .lane_id = 1,
        .header_json = "{\"media_type\":\"application/x-ndjson\",\"ncols\":1}",
        .payload = "[{\"a\":1}]",
        .rows = 1,
        .uncompressed_len = 9,
    };
    const bytes = try encode(allocator, frame, .{});
    defer allocator.free(bytes);
    const decoded = try decode(allocator, bytes, .{});
    try std.testing.expectEqual(@as(u8, 1), decoded.lane_id);
    try std.testing.expectEqualStrings(frame.header_json, decoded.header_json);
    try std.testing.expectEqualStrings(frame.payload, decoded.payload);
    try std.testing.expectEqual(@as(u64, 1), decoded.rows);
    try std.testing.expectEqual(@as(u64, 9), decoded.uncompressed_len);
    try std.testing.expectEqualStrings("json", decoded.lane().?);
}

test "prefix layout" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .lane_id = 2,
        .header_json = "{}",
        .payload = "",
        .rows = 0,
        .uncompressed_len = 0,
        .flags = 0x1234,
    };
    const bytes = try encode(allocator, frame, .{});
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("ALN1", bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 1), bytes[4]);
    try std.testing.expectEqual(@as(u8, 2), bytes[5]);
    try std.testing.expectEqual(@as(u16, 0x1234), getU16(bytes[6..8]));
    try std.testing.expectEqual(@as(u64, 0), getU64(bytes[8..16]));
    try std.testing.expectEqual(@as(u64, 0), getU64(bytes[16..24]));
    try std.testing.expectEqual(@as(u64, 0), getU64(bytes[24..32]));
    try std.testing.expectEqual(@as(u16, 2), getU16(bytes[36..38]));
}

test "python frame compatibility" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .lane_id = 1,
        .header_json = "{}",
        .payload = "abc",
        .rows = 0,
        .uncompressed_len = 3,
    };
    const bytes = try encode(allocator, frame, .{});
    defer allocator.free(bytes);
    const expected = [_]u8{
        0x41, 0x4c, 0x4e, 0x31, 0x01, 0x01, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xc2, 0x41, 0x24, 0x35, 0x02, 0x00, 0x7b, 0x7d,
        0x61, 0x62, 0x63,
    };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "bad magic" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, HEADER_SIZE);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "XXXX");
    try std.testing.expectError(error.BadMagic, decode(allocator, bytes, .{}));
}

test "bad checksum" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .lane_id = 1,
        .header_json = "{}",
        .payload = "abc",
        .rows = 1,
        .uncompressed_len = 3,
    };
    const bytes = try encode(allocator, frame, .{});
    defer allocator.free(bytes);
    bytes[HEADER_SIZE + 2] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, decode(allocator, bytes, .{}));
}

test "trailing bytes" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .lane_id = 1,
        .header_json = "{}",
        .payload = "a",
        .rows = 1,
        .uncompressed_len = 1,
    };
    const bytes = try encode(allocator, frame, .{});
    defer allocator.free(bytes);
    const longer = try allocator.alloc(u8, bytes.len + 1);
    defer allocator.free(longer);
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try std.testing.expectError(error.TrailingBytes, decode(allocator, longer, .{}));
}
