#!/bin/sh
# Builds and runs fgcapture (see convert.swift): a phone frame capture -> PNGs.
#   scripts/fgcapture/run.sh CAPTURE_DIR [--out DIR] [--crop X,Y,W,H] [--from SEQ] [--to SEQ]
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/build/fgcapture"
mkdir -p "$out"
xcrun -sdk macosx swiftc -O -o "$out/fgcapture" "$root/scripts/fgcapture/convert.swift"
exec "$out/fgcapture" "$@"
