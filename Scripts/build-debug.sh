#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
keep_app=false
case "${1:-}" in
    '') ;;
    --keep-app) keep_app=true; shift ;;
    *) print -u2 'Usage: Scripts/build-debug.sh [--keep-app]'; exit 2 ;;
esac
[[ $# == 0 ]] || { print -u2 'Usage: Scripts/build-debug.sh [--keep-app]'; exit 2; }
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
# Search Privacy and unregistering alone do not reliably hide Spotlight's app list.
# Keep runnable development copies only for an explicitly requested debug session.
if [[ "$keep_app" == true ]]; then
    zsh Scripts/unregister-build-apps.sh
    print "Debug app retained: $app"
    print 'After debugging, run Scripts/archive-build-apps.sh to archive and remove development apps.'
else
    zsh Scripts/archive-build-apps.sh
fi
