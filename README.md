# arrowlane-zig

A pure Zig implementation of the arrowlane frame and lane selector.

Status: first build. The frame codec, the int64 schema spike and the selector are
implemented and tested. The JSON and IPC lanes, chunks, zstd, shared memory and
the C ABI are not implemented yet. The `describe` manifest reports those
capabilities as `false`.

## Build

```bash
zig build
zig build test
```

The release artifact is `zig-out/bin/arrowlane-zig` on POSIX and
`zig-out/bin/arrowlane-zig.exe` on Windows.

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arrowlane-zig describe
```

## Implemented

| Area | State | Evidence |
|---|---|---|
| 38 byte frame prefix | Done | Byte-for-byte match with the Python encoder for an empty header |
| Header and payload limits | Done | Unit tests for truncation, trailing bytes, bad magic and bad checksum |
| int64 Arrow schema | Spike | Both nullable variants match pyarrow and read back with `pa.ipc.read_schema` |
| Deterministic selector | Done | 324 of 324 Python selector cases agree on lane and reason |
| `describe` | Done | Machine-readable JSON with honest capability flags |
| JSON lane | Not started | Planned |
| IPC lane | Not started | Planned |
| Chunks, zstd, shm | Not started | Planned |
| C ABI | Not started | Planned |

## Frame layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `ALN1` |
| 4 | 1 | format version, 1 |
| 5 | 1 | lane id |
| 6 | 2 | flags, little endian |
| 8 | 8 | payload length |
| 16 | 8 | uncompressed length |
| 24 | 8 | row count |
| 32 | 4 | CRC32 over the payload |
| 36 | 2 | header length |
| 38 | n | UTF-8 JSON header |
| 38+n | p | payload |

The prefix is fixed width so a reader rejects a bad length or checksum before it
parses the header. The header is a raw JSON object; lane code owns its keys.

## Selector

```bash
./zig-out/bin/arrowlane-zig select \
  --rows 1000 --bytes 1000000 \
  --topology same_network --policy latency --json
```

The selector uses the shipped Python cost model, the same rule order and the
same gain floor. On Windows, `shm` is rejected as
`NOT_AVAILABLE_ON_PLATFORM`; on POSIX it is rejected as `SHM_UNAVAILABLE` unless
`--shm-ready` is set.

## Compatibility boundary

The frame layout matches the Python and Rust implementations. The int64 schema
spike matches the exact pyarrow encapsulated messages. General Arrow schema and
record batch encoding are not built yet, so this build does not claim wire
compatibility for tables.

## Development

- `zig fmt --check --exclude src/vendor .`
- `zig build test`
- `zig build -Doptimize=ReleaseSafe`
- `bash scripts/gate.sh` runs the same checks and records the binary size.

The agent surface is `llms.txt` and `docs/ai/`. There is no root `AGENTS.md`.

## License

Apache License 2.0. See `LICENSE`.
