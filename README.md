# arrowlane-zig

Pure Zig implementation of the arrowlane frame, schema codec and lane selector.

> Status: Alpha source preview. No release artifacts yet.
>
> The JSON, IPC and record-batch paths are fixture-scoped. This is not a
> general Arrow table codec yet.

## Why arrowlane-zig

- A small Zig implementation of the same frame format as Python and Rust.
- A deterministic selector that matches the Python cost model.
- Common flat Arrow types through a general schema reader and writer.
- A C ABI, fixture chunk streams and a POSIX shared-memory fixture lane.
- A parser fuzz gate and an honest `describe` manifest.

## Build

```bash
bash tools/fetch-zstd.sh
zig build
zig build test
```

Release build:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arrowlane-zig describe
```

## Quick start

```bash
./zig-out/bin/arrowlane-zig select \
  --rows 1000 --bytes 1000000 \
  --topology same_network --policy latency --json
```

Fixture frame:

```bash
./zig-out/bin/arrowlane-zig pack --lane json --rows 500 --out fixture.aln
./zig-out/bin/arrowlane-zig unpack fixture.aln --json
```

`pack` also accepts `--lane ipc` and `--lane ipc-zstd` for the same fixture.

## What works

- The 38 byte frame prefix, header and payload limits, CRC32 and frame validation.
- The general schema reader and writer for common flat Arrow types.
- The canonical eight-column JSON, IPC and `ipc-zstd` fixture lanes.
- Fixture chunk streams, the deterministic selector, the C ABI and `describe`.
- The POSIX `shm` fixture lane through the module and tests.
- The parser fuzz gate on Linux.

## Not yet

- General JSON lane.
- General IPC lane.
- General record-batch codec.
- A `pack --lane shm` CLI command.
- Competitive IPC performance. The IPC lanes are correct but slower than Python and Rust.

## Lanes

| Lane | Status |
|---|---|
| `json` | Fixture only |
| `ipc` | Fixture only |
| `ipc-zstd` | Fixture only |
| `shm` | POSIX fixture only, no CLI |

## Platforms

| Architecture | Support |
|---|---|
| Linux x86_64 | Supported |
| Linux aarch64 | Supported |
| macOS arm64 | Supported |
| Windows x86_64 | Supported |
| Windows aarch64 | Cross-build only |

## Performance

The maintained cross-language record is
[`arrowlane/docs/docker-benchmark.md`](https://github.com/kennaidoo/arrowlane/blob/main/docs/docker-benchmark.md).
JSON is the clear Zig win. IPC and `ipc-zstd` are correct but slower than Python
and Rust. Do not claim IPC parity.

## Documentation

- [docs/ai/quickstart.md](docs/ai/quickstart.md): build and first command.
- [docs/ai/api.md](docs/ai/api.md): implemented calls and limits.
- [docs/ai/manifest.json](docs/ai/manifest.json): static capability manifest.
- [llms.txt](llms.txt): short entry point for retrieval tools.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the process and [AGENTS.md](AGENTS.md)
for the coding-agent commands.

## Security

Report vulnerabilities privately through the repository Security tab. Do not
open a public issue. See [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
