#!/bin/bash
set -euo pipefail
archive=$1
unzip -tq "$archive"
# Check exactly what a plain ZIP extractor puts on disk. AppleDouble files in
# Sparkle.framework's root invalidate its seal even when the ticket is valid.
python3 - "$archive" <<'PY'
from pathlib import PurePosixPath
from zipfile import ZipFile
import sys
with ZipFile(sys.argv[1]) as z:
    for entry in z.infolist():
        mode = entry.external_attr >> 16
        if mode & 0o444 != 0o444 or (mode & 0o100 and mode & 0o111 != 0o111):
            sys.exit(f"Application files must be readable and executables runnable by all users: {entry.filename}")
        path = PurePosixPath(entry.filename)
        if not path.parts or path.parts[0] != "Folio.app" or ".." in path.parts or any(p.startswith("._") for p in path.parts):
            sys.exit(f"Unexpected release ZIP entry: {entry.filename}")
PY
checkdir=$(mktemp -d)
unzip -q "$archive" -d "$checkdir"
app="$checkdir/Folio.app"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");FolioReleaseCheck;$(uuidgen)" "$app"
codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
if command -v syspolicy_check >/dev/null; then syspolicy_check distribution "$app"; fi
# Only remove the private extraction directory created above.
python3 - "$checkdir" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
