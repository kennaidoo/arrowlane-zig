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

## Not implemented

The general JSON lane, IPC lane, chunk stream, zstd, shared memory and C ABI are
not in this build. The `describe` manifest reports them as false.
