#!/usr/bin/env bash
# Copies the licence texts of iPlay5 and everything bundled into it to
# App/Resources/Licenses, where Settings › About › Licences shows them.
# The output is committed so builds don't need the submodules checked out.
# Run it again after bumping a submodule and commit any changes.
#
#   scripts/update-licenses.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT=App/Resources/Licenses
TP=vendor/chiaki-ng/third-party

copy() { # source, destination name
	if [ ! -f "$1" ]; then
		echo "Missing $1. Run: git submodule update --init" >&2
		exit 1
	fi
	cp "$1" "$OUT/$2"
}

rm -rf "$OUT"
mkdir -p "$OUT"

copy LICENSE iPlay5.txt
copy vendor/chiaki-ng/COPYING chiaki-ng.txt
copy vendor/mbedtls/LICENSE MbedTLS.txt
copy vendor/opus/COPYING Opus.txt
copy "$TP/nanopb/LICENSE.txt" nanopb.txt
copy "$TP/jerasure/COPYING" jerasure.txt
copy "$TP/gf-complete/COPYING" gf-complete.txt

# P5M is plain AGPL-3.0, without the OpenSSL exception iPlay5 and chiaki-ng add
awk '/^Additional permission under GNU AGPL version 3 section 7/ { exit } { print }' LICENSE |
	sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$OUT/AGPL-3.0.txt"

echo "Updated $OUT"
