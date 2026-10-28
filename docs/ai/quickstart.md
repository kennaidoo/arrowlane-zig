# Quickstart

## Build

```bash
zig build
zig build test
```

Requires Zig 0.17.0 or newer.

## Describe

```bash
./zig-out/bin/arrowlane-zig describe
```

The manifest prints the implemented capabilities. Every unimplemented field is
`false`.

## Select a lane

```bash
./zig-out/bin/arrowlane-zig select \
  --rows 1000 --bytes 1000000 \
  --topology same_network --policy latency --json
```

The response names the chosen lane, the reason, the predicted latency, the
predicted wire bytes, every score and every rejected lane.

## Emit the int64 schema spike

```bash
./zig-out/bin/arrowlane-zig schema-int64 > schema.bin
./zig-out/bin/arrowlane-zig schema-int64 --nullable > schema-nullable.bin
```

Both files are 128 byte encapsulated Arrow schema messages. They are the only
schema messages this build supports for the one-column path.

## Fixture JSON frame

```bash
./zig-out/bin/arrowlane-zig pack --lane json --rows 500 --out fixture.aln
./zig-out/bin/arrowlane-zig unpack fixture.aln --json
```

The fixture is the canonical eight-column table from the Python and Rust
projects. `pack` accepts only the `json` lane at this stage. `unpack` validates
the schema and every row, then prints the row count.

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
./zig-out/bin/arrowlane-zig pack-chunks --rows 1000 --chunk-rows 250 --out chunks.aln
./zig-out/bin/arrowlane-zig unpack-chunks --in chunks.aln --json
```

The result is four ordered frames. Python `read_chunks` returns four 250-row
batches and `write_chunks` produces a stream Zig accepts.

## Gate

```bash
bash scripts/gate.sh
```

The gate runs formatting, unit tests, a release build and a binary size check.
