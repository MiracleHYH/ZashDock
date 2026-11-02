#!/bin/zsh
# Preserve development bundles as verified ZIPs, then remove their launchable copies.
# Deliberately confined to this checkout's build directory; never visits user data.
set -euo pipefail
cd "${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: Scripts/archive-build-apps.sh'; exit 2; }
build_root="$PWD/build"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$build_root" ]] || exit 0
[[ ! -L "$build_root" ]] || { print -u2 'Refusing a symlinked build directory.'; exit 1; }
[[ -x "$registrar" ]] || { print -u2 'Launch Services registration tool is unavailable.'; exit 1; }
# Fail closed if process inspection is unavailable, or a development app is running.
process_commands=$(/bin/ps -axo comm=)
typeset -a candidates
while IFS= read -r -d '' candidate; do
    info="$candidate/Contents/Info.plist"
    [[ -f "$info" ]] || continue
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null) || continue
    [[ "$identifier" == app.zashdock.* ]] || continue
    if [[ "$process_commands" == *"$candidate/Contents/"* ]]; then
        print -u2 "Quit the development app before archiving: $candidate"
        exit 1
    fi
    candidates+=("$candidate")
done < <(find "$build_root" -type d -name '*.app' -prune -print0)
(( ${#candidates} > 0 )) || { print 'No launchable ZashDock development bundles found.'; exit 0; }
mkdir -p "$build_root/DevelopmentAppArchives"
archive_root=$(mktemp -d "$build_root/DevelopmentAppArchives/batch.XXXXXXXX")
verify_root=$(mktemp -d "$archive_root/.verify.XXXXXXXX")
trap 'rm -rf "$verify_root"' EXIT
xcrun swiftc -module-cache-path "$build_root/ModuleCache" Scripts/verify-bundle-copy.swift -o "$archive_root/verify-bundle-copy"
for candidate in "${candidates[@]}"; do
    relative="${candidate#"$build_root/"}"
    archive="$archive_root/$relative.zip"
    mkdir -p "${archive:h}"
    ditto -c -k --sequesterRsrc --keepParent "$candidate" "$archive"
    # Extraction and complete content comparison must succeed before removing anything.
    ditto -x -k "$archive" "$verify_root"
    restored="$verify_root/${candidate:t}"
    "$archive_root/verify-bundle-copy" "$candidate" "$restored"
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$candidate/Contents/Info.plist")
    [[ ! -x "$candidate/Contents/MacOS/$executable" || -x "$restored/Contents/MacOS/$executable" ]]
    (cd "${archive:h}" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
    print -r -- "$candidate" > "$archive.original-path.txt"
    process_commands=$(/bin/ps -axo comm=)
    if [[ "$process_commands" == *"$candidate/Contents/"* ]]; then
        print -u2 "App started while archiving; leaving it in place: $candidate"
        exit 1
    fi
    if ! "$registrar" -u "$candidate"; then
        print -u2 "No registration was removed for $relative; its verified archive is retained."
    fi
    rm -rf "$candidate"
    rm -rf "$restored"
    print "Archived and removed: $relative"
done
print "Verified archives: $archive_root"
print "Removed ${#candidates} launchable development bundles; installed apps and website data were not accessed."
