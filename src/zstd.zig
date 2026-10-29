//! libzstd compression and decompression.
//!
//! Decode is bounded by the caller's expected output length. This is faster
//! than Zig 0.17's std zstd decoder and uses the same vendored library.

const std = @import("std");

pub const Error = error{
    CompressFailed,
    DecompressFailed,
    OutOfMemory,
};

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize, level: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;

pub fn compress(allocator: std.mem.Allocator, input: []const u8, level: c_int) Error![]u8 {
    const bound = ZSTD_compressBound(input.len);
    const storage = allocator.alloc(u8, bound) catch return error.OutOfMemory;
    defer allocator.free(storage);
    const code = ZSTD_compress(storage.ptr, storage.len, input.ptr, input.len, level);
    if (ZSTD_isError(code) != 0) return error.CompressFailed;
    return allocator.dupe(u8, storage[0..code]) catch return error.OutOfMemory;
}

pub fn decompress(
    allocator: std.mem.Allocator,
    input: []const u8,
    expected_len: usize,
) Error![]u8 {
    if (expected_len == 0) return error.DecompressFailed;
    const out = allocator.alloc(u8, expected_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    const code = ZSTD_decompress(out.ptr, out.len, input.ptr, input.len);
    if (code == 0 or ZSTD_isError(code) != 0 or code != expected_len) {
        return error.DecompressFailed;
    }
    return out;
}

test "zstd compresses text" {
    const allocator = std.testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog";
    const output = try compress(allocator, input, 3);
    defer allocator.free(output);
    try std.testing.expect(output.len > 0);
}

test "zstd decompresses compressed text" {
    const allocator = std.testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog";
    const compressed = try compress(allocator, input, 3);
    defer allocator.free(compressed);
    const output = try decompress(allocator, compressed, input.len);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(input, output);
}

test "zstd rejects corrupted input" {
    const allocator = std.testing.allocator;
    const corrupted = [_]u8{0x00};
    try std.testing.expectError(
        error.DecompressFailed,
        decompress(allocator, &corrupted, 100),
    );
}
