#!/usr/bin/env bash
# Builds an unsigned build/iPlay5.ipa for sideloading. SideStore, AltStore and
# Sideloadly re-sign it with the installer's own Apple ID.
#
#   scripts/package-ipa.sh
#   VERSION=0.2.0 BUILD_NUMBER=7 scripts/package-ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.reefbarman.iplay5}"
# Settings › About › Source code links here. Tagged releases point at their tag
if [ "$VERSION" = 0.0.0 ]; then SOURCE_REF="${SOURCE_REF:-main}"; else SOURCE_REF="${SOURCE_REF:-v$VERSION}"; fi
DERIVED="$ROOT/build/DerivedData-ipa"
STAGE="$ROOT/build/ipa"
OUT="$ROOT/build/iPlay5.ipa"

[ -d Frameworks/ChiakiKit.xcframework ] || scripts/build-chiaki.sh
xcodegen generate

xcodebuild -project iPlay5.xcodeproj -scheme iPlay5 -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
	IPLAY5_BUNDLE_ID="$BUNDLE_ID" IPLAY5_SOURCE_REF="$SOURCE_REF" \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	build

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/Payload"
cp -R "$DERIVED/Build/Products/Release-iphoneos/iPlay5.app" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Built $OUT"
