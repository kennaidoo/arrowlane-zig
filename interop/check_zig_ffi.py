"""C ABI check for arrowlane-zig.

Run from the Python package environment:
    python interop/check_zig_ffi.py --lib zig-out/bin/arrowlane_zig.dll
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import json
import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from arrowlane_zig import AlBuffer, Library  # noqa: E402

import arrowlane  # noqa: E402
import pyarrow as pa  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib", required=True, type=Path)
    args = parser.parse_args()
    lib = Library(str(args.lib))
    print("version", lib.version())

    decision = lib.select(1000, 1_000_000, topology=1, policy=0)
    reason = ctypes.string_at(decision.reason).decode("ascii") if decision.reason else ""
    print("select", decision.lane_id, reason, round(decision.predicted_ms, 4))
    lib.free_reason(decision.reason)

    table = pa.table(
        {
            "id": pa.array([0, 1, 2, 3, 4, 5, 6], type=pa.int64()),
            "name": pa.array([None, "row-1", "row-2", "row-3", "row-4", "row-5", "row-6"]),
            "score": pa.array([0.0, 1 / 3, 2 / 3, 1.0, 4 / 3, 5 / 3, 2.0]),
            "ok": [True, False, True, False, True, False, True],
            "day": pa.array([datetime.date(2026, 1, i) for i in range(1, 8)], type=pa.date32()),
            "amount": pa.array([Decimal("12.34")] * 7, type=pa.decimal128(9, 2)),
            "ts": pa.array(
                [datetime.datetime(2026, 10, 28, 12, 0, tzinfo=datetime.UTC)] * 7,
                type=pa.timestamp("us", tz="UTC"),
            ),
            "blob": pa.array([b"\x00\x01\x02"] * 7, type=pa.binary()),
        }
    )
    for lane in ("json", "ipc", "ipc-zstd"):
        wire = arrowlane.pack(table, lane=lane)
        summary = json.loads(lib.inspect(wire))
        print("inspect", lane, summary["rows"], summary["lane"])
        if summary["rows"] != table.num_rows or summary["lane"] != lane:
            raise SystemExit(f"inspect mismatch for {lane}: {summary}")

    source = arrowlane.pack(table, lane="json")
    for lane_id, lane in ((2, "ipc"), (3, "ipc-zstd")):
        repacked = lib.repack(source, lane_id)
        decoded = arrowlane.unpack(repacked)
        if decoded.schema != table.schema or not decoded.equals(table):
            raise SystemExit(f"repack mismatch for {lane}")
        print("repack", lane, len(repacked))

    lib.free(AlBuffer(None, 0, 0))
    print("OK: C ABI select, inspect, repack and free")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
