#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/Debug/ZashDock.app"
xcodebuild -version >/dev/null
xcodebuild -project ZashDock.xcodeproj -scheme ZashDock -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DebugApp \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
mkdir -p build/Debug
# Copy the complete Xcode product, including Sparkle and its signed XPC services.
# Remove only the previous generated product, including any stale test plug-ins.
rm -rf "$app"
ditto build/DebugApp/Build/Products/Debug/ZashDock.app "$app"
codesign --verify --strict "$app"
file "$app/Contents/MacOS/ZashDock"
# Xcode registers its DerivedData product, not this copied trial App. Refresh only
# this final bundle's metadata so Launch Services can discover its current icon.
xcrun swift Scripts/register-debug-app.swift "$app"
