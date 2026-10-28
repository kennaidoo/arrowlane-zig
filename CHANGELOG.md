# Changelog

## 0.1.0

- Add the 38 byte frame codec with checked prefix lengths, CRC32 and JSON header
  validation.
- Add a byte-for-byte Python frame compatibility test.
- Add the 128 byte int64 Arrow schema spike for both nullable variants.
- Add the deterministic selector with the shipped cost model.
- Add `describe`, `select` and `schema-int64` commands.
- Add formatting, test and release build gates.

Not included: JSON lane, IPC lane, chunks, zstd, shared memory and the C ABI.
