//! Standard base64, without dependencies. Used for the Arrow schema header.

const std = @import("std");

pub const Error = error{ InvalidBase64, OutOfMemory };

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn valueOf(byte: u8) ?u6 {
    return switch (byte) {
        'A'...'Z' => @intCast(byte - 'A'),
        'a'...'z' => @intCast(byte - 'a' + 26),
        '0'...'9' => @intCast(byte - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

pub fn encodedSize(input_len: usize) usize {
    return ((input_len + 2) / 3) * 4;
}

pub fn encode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const out = allocator.alloc(u8, encodedSize(input.len)) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var in_index: usize = 0;
    var out_index: usize = 0;
    while (in_index + 3 <= input.len) : (in_index += 3) {
        const chunk = (@as(u32, input[in_index]) << 16) |
            (@as(u32, input[in_index + 1]) << 8) |
            @as(u32, input[in_index + 2]);
        out[out_index] = alphabet[(chunk >> 18) & 0x3F];
        out[out_index + 1] = alphabet[(chunk >> 12) & 0x3F];
        out[out_index + 2] = alphabet[(chunk >> 6) & 0x3F];
        out[out_index + 3] = alphabet[chunk & 0x3F];
        out_index += 4;
    }
    const remaining = input.len - in_index;
    if (remaining == 1) {
        const chunk = @as(u32, input[in_index]) << 16;
        out[out_index] = alphabet[(chunk >> 18) & 0x3F];
        out[out_index + 1] = alphabet[(chunk >> 12) & 0x3F];
        out[out_index + 2] = '=';
        out[out_index + 3] = '=';
    } else if (remaining == 2) {
        const chunk = (@as(u32, input[in_index]) << 16) |
            (@as(u32, input[in_index + 1]) << 8);
        out[out_index] = alphabet[(chunk >> 18) & 0x3F];
        out[out_index + 1] = alphabet[(chunk >> 12) & 0x3F];
        out[out_index + 2] = alphabet[(chunk >> 6) & 0x3F];
        out[out_index + 3] = '=';
    }
    return out;
}

pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len % 4 != 0) return error.InvalidBase64;
    var padding: usize = 0;
    if (input.len > 0 and input[input.len - 1] == '=') padding += 1;
    if (input.len > 1 and input[input.len - 2] == '=') padding += 1;
    if (padding > 2) return error.InvalidBase64;
    const out_len = (input.len / 4) * 3 - padding;
    const out = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    var in_index: usize = 0;
    var out_index: usize = 0;
    while (in_index < input.len) : (in_index += 4) {
        const last = in_index + 4 == input.len;
        const a = valueOf(input[in_index]) orelse return error.InvalidBase64;
        const b = valueOf(input[in_index + 1]) orelse return error.InvalidBase64;
        const third_char = input[in_index + 2];
        const fourth_char = input[in_index + 3];
        const c: u6 = if (third_char == '=') 0 else (valueOf(third_char) orelse return error.InvalidBase64);
        const d: u6 = if (fourth_char == '=') 0 else (valueOf(fourth_char) orelse return error.InvalidBase64);
        const chunk = (@as(u24, a) << 18) |
            (@as(u24, b) << 12) |
            (@as(u24, c) << 6) |
            @as(u24, d);
        if (out_index < out_len) {
            out[out_index] = @truncate(chunk >> 16);
            out_index += 1;
        }
        if (out_index < out_len) {
            out[out_index] = @truncate(chunk >> 8);
            out_index += 1;
        }
        if (out_index < out_len) {
            out[out_index] = @truncate(chunk);
            out_index += 1;
        }
        if (last and third_char == '=' and fourth_char != '=') return error.InvalidBase64;
    }
    return out;
}

test "base64 vectors" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "f");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("Zg==", encoded);
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("f", decoded);

    const two = try encode(allocator, "fo");
    defer allocator.free(two);
    try std.testing.expectEqualStrings("Zm8=", two);

    const three = try encode(allocator, "foo");
    defer allocator.free(three);
    try std.testing.expectEqualStrings("Zm9v", three);
}

test "base64 rejects bad input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidBase64, decode(allocator, "Zg="));
    try std.testing.expectError(error.InvalidBase64, decode(allocator, "Zg==="));
    try std.testing.expectError(error.InvalidBase64, decode(allocator, "Z!=="));
}
