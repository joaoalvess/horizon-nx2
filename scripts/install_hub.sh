#!/bin/sh
set -eu
cd "$(dirname "$0")/../apps"
destination="${HORIZON_HUB_APP_DIR:-$HOME/Applications}"
if [ ! -f Config/Signing.local.xcconfig ]; then
    echo "install_hub.sh: copy apps/Config/Signing.local.xcconfig.example to apps/Config/Signing.local.xcconfig and put your team ID in it" >&2
    exit 2
fi
xcodegen generate --quiet
xcodebuild -project Horizon.xcodeproj -scheme HorizonHub -configuration Release \
    -derivedDataPath .build/xcode COMPILER_INDEX_STORE_ENABLE=NO -quiet build
app=.build/xcode/Build/Products/Release/HorizonHub.app
codesign --verify --strict "$app"
if pgrep -xq HorizonHub; then
    if [ -f "$HOME/Library/Application Support/HorizonHub/games/session.json" ]; then
        echo "install_hub.sh: HorizonHub is running a game; close it from the menu bar, then run this again" >&2
        exit 1
    fi
    osascript -e 'tell application id "dev.joaoalvess.horizon.hub" to quit'
    while pgrep -xq HorizonHub; do sleep 0.2; done
fi
mkdir -p "$destination"
rm -rf "$destination/HorizonHub.app"
ditto "$app" "$destination/HorizonHub.app"
open "$destination/HorizonHub.app"
echo "installed $destination/HorizonHub.app"
