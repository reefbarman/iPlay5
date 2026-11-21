#!/bin/sh
# Builds and runs fgbench (see main.swift) against the app's generator sources.
#   scripts/fgbench/run.sh [custom|flyhigh] [--save NAME | --compare NAME] [--iters N]
set -e
cd "$(dirname "$0")/../.."
out=build/fgbench
mkdir -p "$out"
xcrun -sdk macosx metal -O3 -ffast-math -o "$out/fg.metallib" App/Streaming/FrameGen.metal App/Streaming/FlyHigh.metal
xcrun -sdk macosx swiftc -O -o "$out/fgbench" scripts/fgbench/main.swift scripts/fgbench/shim.swift \
	App/Streaming/FrameGenerator.swift App/Streaming/FlyHighGenerator.swift
cp App/Resources/FlyHigh/flyhighfg.bin App/Resources/FlyHigh/flyhighfg.json "$out/"
exec "$out/fgbench" "$@"
