#!/bin/bash
# Builds Agentsphere.app (a real bundle, so macOS can ask for mic, speech and motion permission).
# Usage: ./build.sh        build
#        ./build.sh run    build and open
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Agentsphere.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Agentsphere "$APP/Contents/MacOS/Agentsphere"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then
  open "$APP"
fi
