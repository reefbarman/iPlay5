#!/usr/bin/env bash
# Build the isolated ChiakiKit and generate the Debug project for a physical iPhone or iPad.
# Install and run from Xcode using the normal Config/Local.xcconfig signing setup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/build/input-latency"

"$ROOT/scripts/build-chiaki.sh" --input-latency-probe

# XcodeGen resolves these paths from the spec directory, not from the directory
# running the command. Override the plist destination before XcodeGen writes it.
cat > "$PROBE/project.yml" <<'EOF'
include:
  - ../../project.yml
name: iPlay5InputLatencyProbe
configs:
  Debug: debug
targets:
  iPlay5:
    sources:REPLACE:
      - path: ../../App
        excludes:
          - Info.plist
    dependencies:REPLACE:
      - framework: Frameworks/ChiakiKit.xcframework
        embed: false
    configFiles:REPLACE:
      Debug: ../../Config/Signing.xcconfig
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(IPLAY5_BUNDLE_ID).inputprobe
        INFOPLIST_FILE: Info.plist
        SUPPORTED_PLATFORMS: iphoneos
        SUPPORTS_MACCATALYST: NO
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
      configs:
        Debug:
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) INPUT_LATENCY_PROBE
          OTHER_SWIFT_FLAGS: $(inherited) -Xcc -DCK_INPUT_LATENCY_PROBE=1
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: iPlay5 Probe
schemes:
  iPlay5InputLatencyProbe:
    build:
      targets:
        iPlay5: all
    run:
      config: Debug
    # XcodeGen otherwise looks for a Release configuration for these actions.
    profile:
      config: Debug
    archive:
      config: Debug
EOF

xcodegen generate --spec "$PROBE/project.yml"
echo "Open build/input-latency/iPlay5InputLatencyProbe.xcodeproj and run iPlay5InputLatencyProbe on a physical device."
