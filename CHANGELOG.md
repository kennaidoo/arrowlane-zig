# Changelog

## Unreleased

- Decode `ipc-zstd` with libzstd instead of the Zig standard-library decoder.
- Remove per-row formatting from the IPC name writer.
- Add `-Dstrip` and `-Dc-abi` build options.
- The benchmark image is a static stripped `scratch` image.

## 0.3.0

- Add the 38 byte frame codec with checked prefix lengths, CRC32 and JSON header
  validation.
- Add a byte-for-byte Python frame compatibility test.
- Add the 128 byte int64 Arrow schema spike for both nullable variants.
- Add the canonical eight-column JSON fixture lane with a pinned 480 byte schema
  message.
- Add `pack` and `unpack` for the fixture JSON frame.
- Add the one-field int64 IPC spike, including its lane 2 frame wrapper.
- Add the canonical eight-column IPC fixture with a 504 byte metadata template.
- Add `pack --lane ipc` and fixture IPC validation.
- Add the `ipc-zstd` fixture lane with libzstd encode and decode.
- Add fixture chunk streams for json, ipc and ipc-zstd with ordered `chunk`
  metadata.
- Add the general schema reader and writer for common Arrow types, including
  FlatBuffers default-value handling.
- Add the fixture C ABI and the Python ctypes check.
- Add the deterministic selector with the shipped cost model.
- Add the POSIX `shm` fixture lane with descriptor validation, checked ranges,
  token comparison, CRC and segment cleanup.
- Add the `bench` command and the measured comparison in `docs/performance.md`.
- Add a deterministic parser fuzz gate with 10,000 generated inputs and a
  Linux x86_64 CI job. Zig 0.17's coverage-guided runner is not used because it
  crashes in `fuzzer_new_input` before the target runs.
- Add `describe`, `select`, `pack`, `unpack`, `pack-int64`, `unpack-int64`,
  `schema-int64`, `schema-general-fixture` and `bench` commands.
- Add formatting, test, release build and binary size gates.
- Align the package version with `0.3.0` and accept `--version` as well as
  `version`.

Not included: general JSON lane, general IPC lane and the general record batch
codec. IPC and ipc-zstd are correct but slower than Python and Rust. The
arrow-cpp reference wins those lanes.
