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
python3 - <<'PY'
import json, pathlib, subprocess
icons = pathlib.Path("ios/Runner/Assets.xcassets/AppIcon.appiconset")
for item in json.loads((icons / "Contents.json").read_text())["images"]:
    if "filename" in item:
        pixels = round(float(item["size"].split("x")[0]) * float(item.get("scale", "1x")[:-1]))
        subprocess.run(["sips", "-s", "format", "png", "-z", str(pixels), str(pixels),
                        "assets/icon.jpg", "--out", str(icons / item["filename"])], check=True)
PY
