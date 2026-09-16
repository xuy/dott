#!/bin/bash
# Builds the Dott Swift package and assembles it into Dott.app.
#
# We sign with a fixed --identifier (ad hoc, no Developer ID needed) so macOS
# TCC recognizes this as the *same* app across rebuilds and doesn't forget
# your Screen Recording / Microphone permission grants each time.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Dott.app"
BUNDLE_ID="dev.local.dott"

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

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_NAME"

echo "Built $APP_NAME"
echo
echo "Install it:"
echo "  cp -R $APP_NAME /Applications/"
echo "Then launch from Spotlight/Launchpad, or: open /Applications/$APP_NAME"
echo
echo "On first run, macOS will prompt for Screen Recording and Microphone access."
echo "Grant both in System Settings > Privacy & Security, then start recording again."
