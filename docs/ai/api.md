# API

## Frame

`arrowlane.frame.encode(allocator, frame, options) ![]u8`

Encode one frame. The caller owns the returned buffer. The header must be a JSON
object and at most 65,535 bytes. The payload is checked against `max_payload`.

`arrowlane.frame.decode(allocator, data, options) !Frame`

Decode one exact frame. The returned header and payload slices point into
`data`. The function rejects a short buffer, a trailing byte, a bad magic, an
unknown lane, an unsupported version, an oversize header or payload, malformed
JSON and a bad CRC32.

`arrowlane.frame.Frame`

| Field | Meaning |
|---|---|
| `lane_id` | 1 json, 2 ipc, 3 ipc-zstd, 4 shm |
| `header_json` | raw UTF-8 JSON object |
| `payload` | opaque bytes |
| `rows` | row count from the prefix |
| `uncompressed_len` | uncompressed payload length |
| `flags` | 16 bit flags |

## Selector

`arrowlane.select.select(model, workload, topology, policy, allowed, shm_ready, min_gain) !Decision`

The rule order is non-tabular, empty, candidate filtering, score, gain floor and
the tie break. `allowed` is `null` for every model lane, or a slice of lane
names. `shm_ready` must be true before `shm` can be scored. `min_gain` is in
`[0, 1)`.

`Decision`

| Field | Meaning |
|---|---|
| `lane` | chosen lane |
| `reason` | `BEST`, `EMPTY`, `NON_TABULAR`, `NO_CANDIDATE` or `GAIN_TOO_SMALL` |
| `predicted_ms` | predicted end to end latency |
| `predicted_bytes` | predicted wire bytes |
| `scores` | considered lanes, in model order |
| `rejected` | rejected lanes and the reason |

## Schema spike

`arrowlane.schema.encodeInt64(allocator, nullable) ![]u8`

Return the exact 128 byte encapsulated message for
`Field{name: "a", type: int64}`. `nullable` selects the variant.

`arrowlane.schema.nullableOfInt64(allocator, raw) !bool`

Return the nullable flag when `raw` is one of the two pinned messages. Any other
message returns `BadSchema`.

## Fixture JSON lane

`arrowlane.fixture_json.encodeSample(allocator, rows) ![]u8`

Encode the canonical eight-column fixture as one JSON frame. The schema message
is pinned to the 480 byte canonical message. The values follow the Python
fixture rules.

`arrowlane.fixture_json.validate(allocator, wire) !Summary`

Validate one canonical fixture frame. It checks the lane, the schema message, the
column count, every row shape and the tag types. The summary carries the row
count and lane name.

`arrowlane.json_int64`

The one-column int64 path remains available for the smaller schema spike. It
uses the same frame and header rules.

## IPC int64 spike

`arrowlane.ipc_int64.encode(allocator, values) ![]u8`

Write a one-field int64 Arrow IPC stream with no nulls. The stream is the exact
layout pyarrow writes for 1, 2 and 3: 304 bytes, byte-for-byte equal.

`arrowlane.ipc_int64.decode(allocator, raw) ![]i64`

Read the same stream. It rejects a different schema, a changed length, a bad
body length and a missing EOS marker.

`arrowlane.ipc_int64.encodeFrame` and `decodeFrame`

Wrap the stream in a lane 2 arrowlane frame. Python `IpcLane` reads the Zig
frame, and Zig reads the Python frame. This is a one-column spike, not a general
IPC codec.

## Fixture IPC lane

`arrowlane.ipc_fixture.encodeSample(allocator, rows) ![]u8`

Encode the canonical eight-column fixture as one Arrow IPC stream. The schema is
the pinned 480 byte message and the record-batch metadata is a pinned 504 byte
template with 8 field nodes and 18 buffer descriptors.

`arrowlane.ipc_fixture.validate` and `decodeFrame`

Validate one stream or one lane 2 frame. The body plan checks the row count, name
null count, every buffer offset and every buffer length.

Python reads the Zig IPC fixture at 14, 500, 20,000 and 200,000 rows with every
column equal. Zig reads Python IPC frames at 500 and 20,000 rows. This is a
fixture-scoped lane, not a general IPC codec.

## IPC zstd fixture lane

`arrowlane.ipc_zstd.encodeFrame(allocator, rows) ![]u8`

Compress the canonical eight-column IPC stream with libzstd level 3. The frame
is lane 3 and carries `codec:"zstd"` and `zstd_level:3`.

`arrowlane.ipc_zstd.decodeFrame(allocator, wire) !Summary`

Decompress with `std.compress.zstd.Decompress`, bounded by the declared
uncompressed length, then validate the IPC fixture. Python reads Zig frames and
Zig reads Python frames. Full `check_wire.py` passes at 500, 20,000 and 200,000
rows for json, ipc and ipc-zstd.

`tools/fetch-zstd.sh` fetches the pinned source. libzstd is encode only; decode
stays in Zig's standard library.

## Chunk stream

`arrowlane.chunks.packLane(allocator, rows, chunk_rows, lane) ![]u8`

Split the canonical fixture into sequential frames on `json`, `ipc` or
`ipc-zstd`. Each frame carries `chunk.id`, `chunk.index` and `chunk.last`. The
stream id is 32 lowercase hex characters.

`arrowlane.chunks.validate(allocator, data) !Summary`

Validate every frame, the lane, the stream id, the index sequence, the last
marker and the row totals. JSON rows are checked field by field. For IPC and
ipc-zstd chunks, Zig validates the frame envelope, schema and row totals, while
Python validates the column values. This accepts pyarrow's padded binary
buffers without pretending the padding is fixture data.

Python `read_chunks` yields four 250-row batches for each of the three lanes;
Zig accepts Python `write_chunks` streams for all three.

## Not implemented

The general JSON lane, general IPC lane, IPC chunk stream, zstd, shared memory
and C ABI are not in this build. The `describe` manifest reports them as false.
