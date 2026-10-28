# arrowlane-zig

A pure Zig implementation of the arrowlane frame and lane selector.

Status: first build. The frame codec, the int64 schema spike, the canonical
eight-column JSON fixture, the one-field IPC spike, the eight-column IPC fixture,
the `ipc-zstd` fixture, the JSON chunk stream and the selector are implemented
and tested. The general JSON lane, general IPC lane, IPC chunk stream, shared
memory and the C ABI are not implemented yet. The `describe` manifest reports
those capabilities honestly.

## Build

```bash
bash tools/fetch-zstd.sh
zig build
zig build test
```

`tools/fetch-zstd.sh` downloads the pinned libzstd 1.5.7 tarball, verifies its
SHA256 and copies `lib` into untracked `vendor/zstd`. The build needs that
directory for the `ipc-zstd` encoder. The source tarball is not committed.

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
| Eight-column schema | Fixture only | The canonical 480 byte message is pinned for the JSON fixture |
| JSON fixture lane | Done, fixture scoped | Python matches all 8 columns at 500, 20,000 and 200,000 rows; Zig validates Python frames at 500 and 20,000 |
| IPC int64 lane | Spike, one column | Zig and pyarrow agree byte-for-byte on 304 byte streams; frames decode both ways |
| IPC fixture lane | Done, fixture scoped | Python matches all 8 columns at 14, 500, 20,000 and 200,000 rows; Zig decodes Python frames at 500 and 20,000 |
| IPC zstd fixture lane | Done, fixture scoped | Full three-lane `check_wire.py` passes at 500, 20,000 and 200,000 rows, both directions |
| JSON chunk stream | Done, fixture scoped | 1,000 rows in 250-row chunks yields 4 frames; Python and Zig read each other's streams |
| Deterministic selector | Done | 324 of 324 Python selector cases agree on lane and reason |
| `describe` | Done | Machine-readable JSON with honest capability flags |
| General JSON lane | Not started | The fixture path is the only JSON table this build accepts |
| General IPC lane | Not started | The eight-column path is pinned to the canonical fixture |
| IPC chunk stream, shm | Not started | Planned |
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

## Fixture JSON lane

```bash
./zig-out/bin/arrowlane-zig pack --lane json --rows 500 --out fixture.aln
./zig-out/bin/arrowlane-zig unpack fixture.aln --json
```

Python reads the Zig frame with `arrowlane.unpack`. The 500 row check compares
every column and the schema against `interop/check_wire.sample_table`.

## Compatibility boundary

The frame layout matches the Python and Rust implementations. The int64 schema
spike matches the exact pyarrow encapsulated messages. The JSON and IPC lanes
are pinned to the canonical eight-column fixture and its 480 byte schema
message. General Arrow schema and record batch encoding are not built yet, so
this build does not claim wire compatibility beyond that fixture.

## Development

- `zig fmt --check --exclude src/vendor .`
- `zig build test`
- `zig build -Doptimize=ReleaseSafe`
- `bash scripts/gate.sh` runs the same checks and records the binary size.

The agent surface is `llms.txt` and `docs/ai/`. There is no root `AGENTS.md`.

## License

Apache License 2.0. See `LICENSE`.
