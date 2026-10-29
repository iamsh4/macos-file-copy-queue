#!/bin/bash
# Builds FileQueue.app into ./build. Usage: ./build.sh [install]
#   install  also copies the app to ~/Applications and refreshes the Services menu.
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK's SwiftUI needs a macro plugin that ships only with Xcode, so with just the
# Command Line Tools, build against the newest older SDK that's available.
if ! xcodebuild -version >/dev/null 2>&1; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FileQueue"

[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources/AppIcon.icns

APP=build/FileQueue.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileQueue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/FileQueue.app
    cp -R "$APP" ~/Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/FileQueue.app
    /System/Library/CoreServices/pbs -update || true
    echo "Installed to ~/Applications/FileQueue.app"
fi
