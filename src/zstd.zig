//! libzstd compression for the encode side only.
//!
//! Decode stays in `std.compress.zstd.Decompress`. That split is deliberate:
//! Zig 0.17 has no zstd compressor, but it does have a decoder.

const std = @import("std");

pub const Error = error{ CompressFailed, OutOfMemory };

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize, level: c_int) usize;
extern fn ZSTD_isError(code: usize) c_uint;

pub fn compress(allocator: std.mem.Allocator, input: []const u8, level: c_int) Error![]u8 {
    const bound = ZSTD_compressBound(input.len);
    const storage = allocator.alloc(u8, bound) catch return error.OutOfMemory;
    defer allocator.free(storage);
    const code = ZSTD_compress(storage.ptr, storage.len, input.ptr, input.len, level);
    if (ZSTD_isError(code) != 0) return error.CompressFailed;
    return allocator.dupe(u8, storage[0..code]) catch return error.OutOfMemory;
}

test "zstd compresses text" {
    const allocator = std.testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog";
    const output = try compress(allocator, input, 3);
    defer allocator.free(output);
    try std.testing.expect(output.len > 0);
}
