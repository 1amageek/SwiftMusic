#!/bin/bash
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
swift_executable="$(xcrun --find swift)"
"$swift_executable" build --package-path "$package_root" -c release
binary_directory="$("$swift_executable" build --package-path "$package_root" -c release --show-bin-path)"
app_path="$package_root/.build/MusicPlaygournd.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/MusicPlaygournd"
cp "$binary_directory/MusicPlaygournd" "$app_path/Contents/MacOS/MusicPlaygournd"
cp "$package_root/Package.swift" "$app_path/Contents/Resources/MusicPlaygournd/Package.swift"
cp -R "$package_root/Sources" "$app_path/Contents/Resources/MusicPlaygournd/"
cp -R "$package_root/Tests" "$app_path/Contents/Resources/MusicPlaygournd/"
/usr/bin/python3 - "$app_path" "$swift_executable" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {
    'CFBundleExecutable': 'MusicPlaygournd',
    'CFBundleIdentifier': 'com.1amageek.MusicPlaygournd',
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
