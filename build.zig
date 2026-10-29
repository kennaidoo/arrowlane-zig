const std = @import("std");

const zstd_sources = &.{
    "common/debug.c",
    "common/entropy_common.c",
    "common/error_private.c",
    "common/fse_decompress.c",
    "common/pool.c",
    "common/threading.c",
    "common/xxhash.c",
    "common/zstd_common.c",
    "compress/fse_compress.c",
    "compress/hist.c",
    "compress/huf_compress.c",
    "compress/zstd_compress.c",
    "compress/zstd_compress_literals.c",
    "compress/zstd_compress_sequences.c",
    "compress/zstd_compress_superblock.c",
    "compress/zstd_double_fast.c",
    "compress/zstd_fast.c",
    "compress/zstd_lazy.c",
    "compress/zstd_ldm.c",
    "compress/zstd_opt.c",
    "compress/zstd_preSplit.c",
    "compress/zstdmt_compress.c",
    "decompress/huf_decompress.c",
    "decompress/zstd_ddict.c",
    "decompress/zstd_decompress.c",
    "decompress/zstd_decompress_block.c",
};

fn addZstd(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/zstd"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/zstd"),
        .files = zstd_sources,
        .flags = &.{ "-DZSTD_MULTITHREAD=0", "-DZSTD_DISABLE_ASM" },
    });
    module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip binary symbols") orelse false;
    const c_abi = b.option(bool, "c-abi", "Build the C ABI shared and static libraries") orelse true;
    const debug_tests = b.option(bool, "debug-tests", "Build unit tests with Debug optimization") orelse false;

    const library = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addZstd(b, library);

    const exe = b.addExecutable(.{
        .name = "arrowlane-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("arrowlane", library);
    exe.root_module.strip = strip;
    b.installArtifact(exe);

    if (c_abi) {
        const ffi_module = b.createModule(.{
            .root_source_file = b.path("src/cabi.zig"),
            .target = target,
            .optimize = optimize,
        });
        ffi_module.addImport("arrowlane", library);
        const shared = b.addLibrary(.{
            .name = "arrowlane_zig",
            .linkage = .dynamic,
            .root_module = ffi_module,
        });
        b.installArtifact(shared);
        const static = b.addLibrary(.{
            .name = "arrowlane_zig_static",
            .linkage = .static,
            .root_module = ffi_module,
        });
        b.installArtifact(static);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = if (debug_tests) .Debug else .ReleaseSafe,
        }),
    });
    addZstd(b, tests.root_module);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    if (target.result.os.tag == .linux) {
        const fuzz_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = .Debug,
            }),
            .filters = &.{"fuzz wire parsers"},
        });
        const fuzz_run = b.addRunArtifact(fuzz_tests);
        const fuzz_step = b.step("fuzz", "Deterministic parser fuzz gate");
        fuzz_step.dependOn(&fuzz_run.step);
    }
}
