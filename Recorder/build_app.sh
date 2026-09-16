#!/bin/bash
# Builds the Recorder Swift package and assembles it into Recorder.app.
#
# We sign with a fixed --identifier (ad hoc, no Developer ID needed) so macOS
# TCC recognizes this as the *same* app across rebuilds and doesn't forget
# your Screen Recording / Microphone permission grants each time.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Recorder.app"
BUNDLE_ID="dev.local.meeting-recorder"

swift build -c release

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
cp ".build/release/Recorder" "$APP_NAME/Contents/MacOS/Recorder"
cp "Info.plist" "$APP_NAME/Contents/Info.plist"

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_NAME"

echo "Built $APP_NAME"
echo "Run it with: open $APP_NAME"
echo "On first run, macOS will prompt for Screen Recording and Microphone access."
echo "Grant both in System Settings > Privacy & Security, then start recording again."
