#!/usr/bin/env bash
# Archives a signed Release build and uploads it to App Store Connect, where it
# appears in TestFlight. Signing is cloud-managed through the App Store Connect
# API key, so there's no certificate or provisioning profile to install.
#
#   TEAM_ID=ABCDE12345 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=uuid \
#   ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8 VERSION=0.2.0 BUILD_NUMBER=7 \
#     scripts/upload-testflight.sh
#
# Build numbers must increase for every upload of the same version. CI uses
# the workflow run number.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${TEAM_ID:?Set TEAM_ID to the Apple developer team ID}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect issuer ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH to the AuthKey_*.p8 file}"
: "${VERSION:?Set VERSION, e.g. 0.2.0 (store builds come from tags)}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to a number higher than any earlier upload}"

# App Store Connect only accepts up to three dot-separated integers
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
	echo "VERSION '$VERSION' isn't valid for App Store Connect (use e.g. 1.2.3)" >&2
	exit 1
fi
[ -f "$ASC_KEY_PATH" ] || { echo "No API key at $ASC_KEY_PATH" >&2; exit 1; }
KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"

BUNDLE_ID="${BUNDLE_ID:-io.github.reefbarman.iplay5}"
# Settings › About › Source code links to the tag this build came from
SOURCE_REF="${SOURCE_REF:-v$VERSION}"
DERIVED="$ROOT/build/DerivedData-testflight"
ARCHIVE="$ROOT/build/iPlay5.xcarchive"
EXPORT="$ROOT/build/testflight"
EXPORT_OPTIONS="$ROOT/build/ExportOptions-testflight.plist"

AUTH=(
	-allowProvisioningUpdates
	-authenticationKeyPath "$KEY_PATH"
	-authenticationKeyID "$ASC_KEY_ID"
	-authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

[ -d Frameworks/ChiakiKit.xcframework ] || scripts/build-chiaki.sh
xcodegen generate

rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project iPlay5.xcodeproj -scheme iPlay5 -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	-archivePath "$ARCHIVE" "${AUTH[@]}" \
	CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
	IPLAY5_BUNDLE_ID="$BUNDLE_ID" IPLAY5_SOURCE_REF="$SOURCE_REF" \
	MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	archive

# destination=upload sends the exported build straight to App Store Connect
cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
	-exportOptionsPlist "$EXPORT_OPTIONS" "${AUTH[@]}"

echo "Uploaded iPlay5 $VERSION ($BUILD_NUMBER) to App Store Connect"
