# arrowlane-zig

A pure Zig implementation of the arrowlane frame and lane selector.

Status: candidate 0.3.0. The frame codec, the int64 schema spike, the general
schema codec for common Arrow types, the canonical eight-column JSON fixture,
the one-field IPC spike, the eight-column IPC fixture, the `ipc-zstd` fixture,
fixture chunk streams, the selector, the C ABI, the POSIX `shm` fixture lane,
the `bench` command and the fuzz targets are implemented and tested. The
general JSON lane, general IPC lane and general record batch codec are not
implemented yet. The `describe` manifest reports those capabilities honestly.

The IPC and `ipc-zstd` lanes are correct but slower than Python and Rust. See
[docs/performance.md](docs/performance.md). Do not claim IPC parity.

## Build

```bash
bash tools/fetch-zstd.sh
zig build
zig build test
```

The benchmark image uses a stripped CLI-only build:

```bash
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dc-abi=false
```

`-Dc-abi=false` omits the shared and static C ABI libraries. The default build
keeps them enabled. The `ipc-zstd` decoder now uses libzstd; the earlier Zig
standard-library decoder was much slower.

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
| IPC chunk streams | Done, fixture scoped | json, ipc and ipc-zstd each yield 4 batches at 1,000 rows; Python values equal |
| C ABI | Done, fixture scoped | Python ctypes checks version, select, inspect all lanes, repack and safe frees |
| General schema codec | Done, common types | Reader and writer for null, int, float, binary, large binary, utf8, large utf8, bool, decimal, date, time, timestamp and duration; pyarrow reads the fixture and one-field schemas |
| Deterministic selector | Done | 324 of 324 Python selector cases agree on lane and reason |
| POSIX `shm` fixture lane | Done, POSIX only | Descriptor validation, checked range arithmetic, token check, CRC and segment cleanup; Windows reports unavailable; FreeBSD needs `ARROWLAND_SHM_DIR` |
| `bench` command | Done | Median and spread for json, ipc and ipc-zstd; see `docs/performance.md` |
| Fuzz targets | Linux | Deterministic 10,000-input mutation gate over frame, shm and schema parsers; Zig 0.17 coverage-guided runner is not used |
| `describe` | Done | Machine-readable JSON with honest capability flags |
| General JSON lane | Not started | The fixture path is the only JSON table this build accepts |
| General IPC lane | Not started | The eight-column path is pinned to the canonical fixture |
| General record batch codec | Not started | Record-batch metadata is still the pinned fixture template |

## Architecture support

| Architecture | Status |
|---|---|
| Linux x86_64 | Existing CI |
| Linux aarch64 | CI test and fuzz |
| macOS arm64 | CI test |
| Windows x86_64 | CI test |
| Windows aarch64 | Cross-build only |
| FreeBSD 15 aarch64 | CI test |

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

`pack` also accepts `--lane ipc` and `--lane ipc-zstd` for the same fixture.

## Performance

The canonical fixture at 200,000 rows, median of five runs, is recorded in
[docs/performance.md](docs/performance.md). JSON is the clear Zig win. IPC and
`ipc-zstd` are correct but slower than Python and Rust. The reference
implementation for those lanes is arrow-cpp through the Rust port. Do not
claim IPC parity.

## POSIX shared memory

`src/shm_lane.zig` implements the `shm` descriptor and segment operations for
Linux and macOS. It validates the name, token, checksum and checked range, and
unlinks the segment after a successful read. Windows reports
`LaneUnavailable` and `isReady() == false`.

The fixture lane is available through the Zig module and its tests. It is not
yet wired to a `pack --lane shm` CLI command.

## Compatibility boundary

The frame layout matches the Python and Rust implementations. The int64 schema
spike matches the exact pyarrow encapsulated messages. The JSON and IPC lanes
are pinned to the canonical eight-column fixture and its 480 byte schema
message. The general schema codec covers the common flat types, but the
record-batch codec is still fixture scoped. This build does not claim general
Arrow table wire compatibility.

## Development

- `zig fmt --check --exclude src/vendor .`
- `zig build test`
- `zig build -Doptimize=ReleaseSafe`
- `bash scripts/gate.sh` runs the same checks and records the binary size.

The agent surface is `llms.txt` and `docs/ai/`. There is no root `AGENTS.md`.

## License

Apache License 2.0. See `LICENSE`.
