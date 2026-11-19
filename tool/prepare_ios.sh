#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
template=$(mktemp -d)
trap 'rm -rf "$template"' EXIT
flutter create --no-pub --platforms=ios --org com.tingx --project-name tingx "$template/tingx"
cp -R "$template/tingx/ios" .
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName TingX' ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes array' ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes:0 string audio' ios/Runner/Info.plist
python3 scripts/install_ios_icon.py
