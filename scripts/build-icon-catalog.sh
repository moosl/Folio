#!/bin/bash
# Compile a split catalog with Xcode 26+: classic bitmaps and the same-named modern icon stack.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=$(xcrun --find actool)
work=.build/icon-catalog
catalog="$work/Assets.xcassets"
icons="$catalog/FolioAppIcon.appiconset"
mkdir -p "$icons" "$work/out"
echo '{"info":{"author":"xcode","version":1}}' > "$catalog/Contents.json"
python3 - "$icons" <<'PY'
from pathlib import Path
import json, subprocess, sys

directory = Path(sys.argv[1])
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        points = f"{size}x{size}"
        name = f"icon_{points}" + ("@2x" if scale == 2 else "") + ".png"
        pixels = str(size * scale)
        subprocess.run(["sips", "-z", pixels, pixels, "app/Resources/FolioClassicIcon.png",
                        "--out", str(directory / name)], check=True, stdout=subprocess.DEVNULL)
        images.append(dict(size=points, idiom="mac", scale=f"{scale}x", filename=name))
(directory / "Contents.json").write_text(json.dumps(dict(images=images, info=dict(author="xcode", version=1))))
PY
"$compiler" "$catalog" app/Resources/FolioAppIcon.icon --compile "$work/out" --platform macosx --target-device mac \
  --lightweight-asset-runtime-mode=enabled --enable-icon-stack-fallback-generation=disabled --include-all-app-icons \
  --minimum-deployment-target 13.0 --app-icon FolioAppIcon --output-partial-info-plist "$work/info.plist"
cp "$work/out/Assets.car" app/Resources/Assets.car
