#!/bin/bash
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
swift_executable="$(xcrun --find swift)"
# The 2026-08-14 Swift 6.4 snapshot asserts while round-tripping FileHandle.AsyncBytes debug types.
"$swift_executable" build --package-path "$package_root" -c release -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types
binary_directory="$("$swift_executable" build --package-path "$package_root" -c release --show-bin-path)"
app_path="${1:-$package_root/.build/MusicPlaygournd.app}"
bundle_id="${2:-com.1amageek.MusicPlaygournd}"
resources="$app_path/Contents/Resources/SwiftMusic"
mkdir -p "$resources"
cp "$package_root/../Package.swift" "$resources/Package.swift"
cp -R "$package_root/../Sources" "$resources/"
cp -R "$package_root/../Tests" "$resources/"
mkdir -p "$app_path/Contents/MacOS" "$resources/MusicPlaygournd"
cp "$binary_directory/MusicPlaygournd" "$app_path/Contents/MacOS/MusicPlaygournd"
cp "$package_root/Package.swift" "$resources/MusicPlaygournd/Package.swift"
cp -R "$package_root/Sources" "$resources/MusicPlaygournd/"
cp -R "$package_root/Tests" "$resources/MusicPlaygournd/"
/usr/bin/python3 - "$app_path" "$swift_executable" "$bundle_id" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {
    'CFBundleExecutable': 'MusicPlaygournd',
    'CFBundleIdentifier': sys.argv[3],
    'CFBundleName': 'MusicPlaygournd',
    'CFBundleDisplayName': 'MusicPlaygournd',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '15.0',
    'NSHighResolutionCapable': True,
    'SwiftExecutable': sys.argv[2],
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --deep --sign - "$app_path"
printf '%s\n' "$app_path"
