# Performance

The maintained cross-language record is `arrowlane/docs/docker-benchmark.md` in
the Python repository. It uses the canonical eight-column fixture, 200,000 rows
and five repeats.

The local `bench` command measures the Zig side only:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arrowlane-zig bench --rows 200000 --repeats 5
```

JSON is the clear Zig win. IPC and `ipc-zstd` are correct but slower than Python
and Rust. arrow-cpp through the Rust port is the reference implementation that
wins the IPC lanes. Do not describe the Zig IPC lanes as parity or as a speed
win.
