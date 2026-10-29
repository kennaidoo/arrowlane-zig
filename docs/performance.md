# Performance

Measurements on the canonical eight-column fixture at 200,000 rows, median of
three runs. The Zig build is `ReleaseSafe`. The Python, Rust and Zig numbers
come from the same fixture.

| Lane | Zig encode | Zig decode | Python encode | Python decode | Rust encode | Rust decode |
|---|---:|---:|---:|---:|---:|---:|
| json | 132.4 ms | 374.7 ms | 3084.4 ms | 2328.1 ms | 357.9 ms | 1473.8 ms |
| ipc | 35.1 ms | 25.2 ms | 6.9 ms | 3.5 ms | 7.1 ms | 5.7 ms |
| ipc-zstd | 51.5 ms | 176.4 ms | 29.5 ms | 23.5 ms | 29.8 ms | 14.9 ms |

## Verdicts

- JSON is the clear Zig win. Encode is about 23x faster than Python and 2.7x
  faster than Rust. Decode is about 6.2x faster than Python and 3.9x faster
  than Rust.
- IPC is correct but not competitive. Zig encode is about 5x slower than
  Python, and decode is about 7x slower. Zig is also slower than Rust on both
  paths.
- `ipc-zstd` encode is about 1.7x slower than Python. Decode is about 7.5x
  slower than Python and about 11.8x slower than Rust.

Wire bytes match Python within a few bytes on every lane. The encoding is
correct. The IPC and `ipc-zstd` speed gap is an implementation limit, not a
wire-format defect.

The reference implementation for the IPC lanes is arrow-cpp through the Rust
port. It wins `ipc` and `ipc-zstd`. Do not describe the Zig IPC lanes as parity
or as a speed win.

## Reproduce

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arrowlane-zig bench --rows 200000 --repeats 3
```

The local `bench` command measures the Zig side. The Python and Rust columns
come from the same fixture in the other two ports.
