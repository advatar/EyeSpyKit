#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product EyeSpy "$@"
eye_spy_bin_dir="$(swift build --show-bin-path "$@")"
eye_spy_app="$PWD/.build/EyeSpy.app"
mkdir -p "$eye_spy_app/Contents/MacOS"
cp "$eye_spy_bin_dir/EyeSpy" "$eye_spy_app/Contents/MacOS/EyeSpy"
cp Examples/EyeSpy/Info.plist "$eye_spy_app/Contents/Info.plist"
codesign --force --sign - "$eye_spy_app"
printf 'Built %s\n' "$eye_spy_app"
