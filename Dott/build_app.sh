#!/bin/bash
# Builds the Dott Swift package and assembles it into Dott.app.
#
# Signed with a local self-signed certificate (not ad hoc) so its code
# identity is stable across rebuilds -- ad-hoc signing (`--sign -`) produces
# a new identity every build, which makes macOS forget Screen Recording /
# Microphone grants each time you rebuild. A real (if self-signed)
# certificate's key pair doesn't change, so TCC's grant sticks permanently.
# One-time setup: Keychain Access > Certificate Assistant > Create a
# Certificate... > Identity Type: Self Signed Root, Certificate Type: Code
# Signing. Name must match SIGNING_IDENTITY below.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Dott.app"
BUNDLE_ID="dev.local.dott"
SIGNING_IDENTITY="Dott Local Signing"

swift build -c release

if [ ! -f "Dott.icns" ]; then
    echo "Generating app icon..."
    swift "$(pwd)/generate_icon.swift"
fi

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"
cp ".build/release/Dott" "$APP_NAME/Contents/MacOS/Dott"
cp "Info.plist" "$APP_NAME/Contents/Info.plist"
cp "Dott.icns" "$APP_NAME/Contents/Resources/Dott.icns"

codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_NAME"

echo "Built $APP_NAME"
echo
echo "Install it:"
echo "  cp -R $APP_NAME /Applications/"
echo "Then launch from Spotlight/Launchpad, or: open /Applications/$APP_NAME"
echo
echo "On first run, macOS will prompt for Screen Recording and Microphone access."
echo "Grant both in System Settings > Privacy & Security, then start recording again."
