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
schema messages this build supports.

## Gate

```bash
bash scripts/gate.sh
```

The gate runs formatting, unit tests, a release build and a binary size check.
