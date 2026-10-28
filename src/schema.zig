//! Arrow schema spike: one nullable or non-nullable int64 field.
//!
//! This is deliberately narrow. It pins the exact 128-byte encapsulated
//! messages that pyarrow writes for `Field{name: "a", type: int64}`. It proves
//! the wire bytes and the nullable distinction before the general flatbuffer
//! reader and writer are built.

const std = @import("std");
const base64 = @import("base64.zig");

pub const Error = error{ BadSchema, OutOfMemory };

const not_nullable_b64 =
    "/////3gAAAAQAAAAAAAKAAwABgAFAAgACgAAAAABBAAMAAAACAAIAAAABAAIAAAABAAAAAEAAAAUAAAAEAAUAAgAAAAHAAwAAAAQABAAAAAAAAACEAAAABwAAAAEAAAAAAAAAAEAAABhAAAACAAMAAgABwAIAAAAAAAAAUAAAAA=";
const nullable_b64 =
    "/////3gAAAAQAAAAAAAKAAwABgAFAAgACgAAAAABBAAMAAAACAAIAAAABAAIAAAABAAAAAEAAAAUAAAAEAAUAAgABgAHAAwAAAAQABAAAAAAAAECEAAAABwAAAAEAAAAAAAAAAEAAABhAAAACAAMAAgABwAIAAAAAAAAAUAAAAA=";

pub fn encodeInt64(allocator: std.mem.Allocator, nullable: bool) Error![]u8 {
    const raw = base64.decode(allocator, if (nullable) nullable_b64 else not_nullable_b64) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase64 => return error.BadSchema,
    };
    return raw;
}

pub fn nullableOfInt64(allocator: std.mem.Allocator, raw: []const u8) Error!bool {
    const not_nullable = try encodeInt64(allocator, false);
    defer allocator.free(not_nullable);
    if (std.mem.eql(u8, raw, not_nullable)) return false;
    const nullable = try encodeInt64(allocator, true);
    defer allocator.free(nullable);
    if (std.mem.eql(u8, raw, nullable)) return true;
    return error.BadSchema;
}

test "int64 schema goldens" {
    const allocator = std.testing.allocator;
    const not_nullable = try encodeInt64(allocator, false);
    defer allocator.free(not_nullable);
    const nullable = try encodeInt64(allocator, true);
    defer allocator.free(nullable);
    try std.testing.expectEqual(@as(usize, 128), not_nullable.len);
    try std.testing.expectEqual(@as(usize, 128), nullable.len);
    try std.testing.expectEqualSlices(u8, not_nullable[0..12], nullable[0..12]);
    try std.testing.expect(!std.mem.eql(u8, not_nullable, nullable));
    try std.testing.expectEqual(false, try nullableOfInt64(allocator, not_nullable));
    try std.testing.expectEqual(true, try nullableOfInt64(allocator, nullable));
    try std.testing.expectError(error.BadSchema, nullableOfInt64(allocator, "not a schema"));
}
