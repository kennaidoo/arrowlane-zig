# Changelog

## 0.1.0

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
- Add the `ipc-zstd` fixture lane with libzstd encode and std decode.
- Add JSON fixture chunk streams with ordered `chunk` metadata.
- Add the deterministic selector with the shipped cost model.
- Add `describe`, `select`, `pack`, `unpack`, `pack-int64`, `unpack-int64` and
  `schema-int64` commands.
- Add formatting, test and release build gates.

Not included: JSON lane, IPC lane, chunks, zstd, shared memory and the C ABI.
