#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f vendor/zstd/zstd.h ]]; then
  bash tools/fetch-zstd.sh
fi

zig fmt --check --exclude src/vendor .
zig build test
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dc-abi=false

binary="zig-out/bin/arrowlane-zig"
if [[ -f "$binary.exe" ]]; then
  binary="$binary.exe"
fi

bytes="$(wc -c < "$binary" | tr -d ' ')"
echo "binary=$binary bytes=$bytes"
if (( bytes > 8388608 )); then
  echo "resource gate failed: binary exceeds 8 MiB" >&2
  exit 1
fi
