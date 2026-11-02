#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
artifacts=$(mktemp -d)
trap 'rm -rf "$artifacts"' EXIT
swiftc "$root/images/ImageDecoder.swift" -o "$artifacts/image-decoder"
swift "$root/tests/ImageDecoderTests.swift" "$artifacts/image-decoder"
