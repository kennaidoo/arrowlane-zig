# Quickstart

## Build

```bash
zig build
zig build test
```

Requires Zig 0.17.0 or newer.

## Version

```bash
./zig-out/bin/arrowlane-zig version
./zig-out/bin/arrowlane-zig --version
```

## Describe

```bash
./zig-out/bin/arrowlane-zig describe
```

The manifest prints the implemented capabilities. Unimplemented fields are
`false`; fixture-scoped paths are marked `fixture` or `fixture-posix`.

## Select a lane

```bash
./zig-out/bin/arrowlane-zig select \
  --rows 1000 --bytes 1000000 \
  --topology same_network --policy latency --json
```

The response names the chosen lane, the reason, the predicted latency, the
predicted wire bytes, every score and every rejected lane.

## Emit schema messages

```bash
./zig-out/bin/arrowlane-zig schema-int64 > schema.bin
./zig-out/bin/arrowlane-zig schema-int64 --nullable > schema-nullable.bin
./zig-out/bin/arrowlane-zig schema-general-fixture > schema-general.bin
./zig-out/bin/arrowlane-zig schema-general-int64 > schema-general-int64.bin
```

The int64 files are the pinned 128-byte variants. The general files use the
forward schema writer and pyarrow reads both of them. The record-batch lanes
still accept only the canonical eight-column fixture.

## Fixture JSON frame

```bash
./zig-out/bin/arrowlane-zig pack --lane json --rows 500 --out fixture.aln
./zig-out/bin/arrowlane-zig unpack fixture.aln --json
```

The fixture is the canonical eight-column table from the Python and Rust
projects. `pack` accepts `json`, `ipc` and `ipc-zstd` for this fixture. `unpack`
validates the schema and every row, then prints the row count.

A one-column int64 frame is also available:

```bash
./zig-out/bin/arrowlane-zig pack-int64 --values 1,-2,null,4 > one.aln
./zig-out/bin/arrowlane-zig unpack-int64 --in one.aln
```

The one-field IPC spike is separate:

```bash
./zig-out/bin/arrowlane-zig ipc-int64 --values 1,2,3 > one.arrow
./zig-out/bin/arrowlane-zig ipc-int64 --in one.arrow
./zig-out/bin/arrowlane-zig pack-ipc-int64 --values 1,2,3 > one-ipc.aln
./zig-out/bin/arrowlane-zig unpack-ipc-int64 --in one-ipc.aln
```

Python reads the raw stream with `pyarrow.ipc.open_stream` and the frame with
`arrowlane.unpack`.

The zstd fixture lane is available with `pack --lane ipc-zstd --rows 500`.
Run `bash tools/fetch-zstd.sh` once before building.

## JSON chunks

```bash
./zig-out/bin/arrowlane-zig pack-chunks --rows 1000 --chunk-rows 250 --lane json --out chunks.aln
./zig-out/bin/arrowlane-zig unpack-chunks --in chunks.aln --json
```

The result is four ordered frames. The same commands accept `--lane ipc` and
`--lane ipc-zstd`. Python `read_chunks` returns four 250-row batches and
`write_chunks` produces streams Zig accepts.

## Benchmark

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arrowlane-zig bench --rows 200000 --repeats 3
```

The command prints `lane wire_bytes enc_ms dec_ms` for `json`, `ipc` and
`ipc-zstd`. The measured comparison is in `docs/performance.md`. JSON wins.
IPC and `ipc-zstd` are correct but slower than Python and Rust, and the
arrow-cpp reference wins those lanes.

## POSIX shared memory

The `shm` fixture lane is available through `src/shm_lane.zig` and its tests on
Linux and macOS. It is not wired to the CLI. Windows returns
`error.LaneUnavailable`.

## Fuzz

On Linux x86_64:

```bash
zig build fuzz --fuzz=10000
```

Windows and macOS do not support Zig 0.17 fuzz mode. Normal `zig build test`
runs only the seed corpus.

## C ABI

Build, then run the ctypes check from the Python package environment:

```bash
zig build
python ../arrowlane-zig/interop/check_zig_ffi.py --lib ../arrowlane-zig/zig-out/bin/arrowlane_zig.dll
```

The check covers select, inspect on all three lanes, repack and safe frees.

## Gate

```bash
bash scripts/gate.sh
```

The gate runs formatting, unit tests, a release build and a binary size check.
