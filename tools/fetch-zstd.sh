#!/usr/bin/env bash
set -euo pipefail

version="1.5.7"
sha256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
url="https://github.com/facebook/zstd/releases/download/v${version}/zstd-${version}.tar.gz"
root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$root/vendor/zstd"

if [[ -f "$vendor/zstd.h" ]]; then
  echo "vendor/zstd already present"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -L --fail --silent --show-error -o "$tmp/zstd.tar.gz" "$url"
if command -v sha256sum >/dev/null 2>&1; then
  echo "$sha256  $tmp/zstd.tar.gz" | sha256sum -c -
elif command -v sha256 >/dev/null 2>&1; then
  actual="$(sha256 -q "$tmp/zstd.tar.gz")"
  if [[ "$actual" != "$sha256" ]]; then
    echo "zstd checksum mismatch" >&2
    exit 1
  fi
elif command -v shasum >/dev/null 2>&1; then
  echo "$sha256  $tmp/zstd.tar.gz" | shasum -a 256 -c -
else
  echo "no SHA-256 tool found" >&2
  exit 1
fi
mkdir -p "$tmp/unpack"
tar -xzf "$tmp/zstd.tar.gz" -C "$tmp/unpack" "zstd-${version}/lib"
mkdir -p "$root/vendor"
cp -R "$tmp/unpack/zstd-${version}/lib" "$vendor"
echo "vendor/zstd fetched"
