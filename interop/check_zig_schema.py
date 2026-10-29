"""Check the general schema writer against pyarrow.

Run from the Python package environment:
    python interop/check_zig_schema.py --exe zig-out/bin/arrowlane-zig.exe
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

import pyarrow as pa


def read_schema(executable: Path, command: str) -> pa.Schema:
    result = subprocess.run(
        [str(executable), command],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return pa.ipc.read_schema(pa.py_buffer(result.stdout))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()

    one = read_schema(args.exe, "schema-general-int64")
    expected_one = pa.schema([pa.field("a", pa.int64(), nullable=False)])
    if not one.equals(expected_one, check_metadata=True):
        raise SystemExit(f"one-field schema mismatch: {one}")

    fixture = read_schema(args.exe, "schema-general-fixture")
    expected_fixture = pa.schema(
        [
            ("id", pa.int64()),
            ("name", pa.string()),
            ("score", pa.float64()),
            ("ok", pa.bool_()),
            ("day", pa.date32()),
            ("amount", pa.decimal128(9, 2)),
            ("ts", pa.timestamp("us", tz="UTC")),
            ("blob", pa.binary()),
        ]
    )
    if not fixture.equals(expected_fixture, check_metadata=True):
        raise SystemExit(f"fixture schema mismatch: {fixture}")

    defaults = read_schema(args.exe, "schema-general-types")
    expected_defaults = pa.schema(
        [
            pa.field("n", pa.null(), nullable=True),
            pa.field("lb", pa.large_binary(), nullable=False),
            pa.field("lu", pa.large_string(), nullable=False),
            pa.field("u32", pa.uint32(), nullable=False),
            pa.field("f16", pa.float16(), nullable=False),
            pa.field("d64", pa.date64(), nullable=False),
            pa.field("t32", pa.time32("ms"), nullable=False),
            pa.field("t64", pa.time64("ns"), nullable=False),
            pa.field("ts", pa.timestamp("s"), nullable=False),
            pa.field("dur", pa.duration("ms"), nullable=False),
        ]
    )
    if not defaults.equals(expected_defaults, check_metadata=True):
        raise SystemExit(f"default schema mismatch: {defaults}")
    print("OK: general schema writer matches pyarrow for one field, eight fields and defaults")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
