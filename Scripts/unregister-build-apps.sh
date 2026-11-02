#!/bin/zsh
# Request targeted Launch Services unregistration. This alone does not reliably
# remove Spotlight app suggestions; use archive-build-apps.sh after debugging.
set -euo pipefail
cd "${0:A:h:h}"
build_root="$PWD/build"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$build_root" ]] || exit 0
[[ -x "$registrar" ]] || { print -u2 'Launch Services registration tool is unavailable.'; exit 1; }
count=0
while IFS= read -r -d '' candidate; do
    info="$candidate/Contents/Info.plist"
    [[ -f "$info" ]] || continue
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null) || continue
    [[ "$identifier" == app.zashdock.* ]] || continue
    if ! "$registrar" -u "$candidate"; then
        print -u2 "No registration was removed for: $candidate"
    fi
    count=$((count + 1))
done < <(find "$build_root" -type d -name '*.app' -prune -print0)
print "Requested unregistration of $count ZashDock development bundles; application files were retained."
