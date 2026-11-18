"""Install the uploaded TingX artwork into the generated iOS app icon catalog.

Uses macOS's built-in sips; no third-party image dependency required.
"""
import json
import subprocess
from pathlib import Path

SOURCE = Path("assets/IMG_2691.png")
CATALOG = Path("ios/Runner/Assets.xcassets/AppIcon.appiconset")
CONTENTS = CATALOG / "Contents.json"


def main():
    if not SOURCE.is_file():
        raise SystemExit(f"Missing uploaded icon: {SOURCE}")
    if not CONTENTS.is_file():
        raise SystemExit(f"Missing iOS app icon catalog: {CONTENTS}")

    data = json.loads(CONTENTS.read_text())
    installed = 0
    for image in data.get("images", []):
        name = image.get("filename")
        if not name:
            continue
        size = image.get("size", "1024x1024").split("x")[0]
        scale = image.get("scale", "1x").rstrip("x")
        pixels = round(float(size) * float(scale))
        if pixels <= 0:
            raise ValueError(f"Invalid icon size: {image}")
        output = CATALOG / name
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", str(pixels),
             str(pixels), str(SOURCE), "--out", str(output)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        installed += 1

    # Flutter/Xcode versions may use a single 1024px universal icon entry.
    if installed == 0:
        output = CATALOG / "AppIcon-1024.png"
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", "1024", "1024",
             str(SOURCE), "--out", str(output)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        data["images"] = [{"filename": output.name, "idiom": "universal",
                           "platform": "ios", "size": "1024x1024"}]
        CONTENTS.write_text(json.dumps(data, indent=2) + "\n")
        installed = 1
    print(f"Installed TingX icon in {installed} iOS asset slot(s)")


if __name__ == "__main__":
    main()
