#!/bin/bash
# Test only local archive preparation; this script contains no publish/tag/network operation.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && -d "$1" ]] || { printf '%s\n' 'Usage: Scripts/test-release-diagnostics.sh /path/to/ZashDock.xcarchive' >&2; exit 2; }
archive_path=$(cd "$1" && pwd)
source_commit=$(git rev-parse HEAD)
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/zashdock-diagnostics-test.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT
xcrun swiftc -module-cache-path build/ModuleCache Scripts/prepare-release-diagnostics.swift -o "$fixture_root/prepare-diagnostics"
tool="$fixture_root/prepare-diagnostics"
app_info="$archive_path/Products/Applications/ZashDock.app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_info")
base="$fixture_root/fixture.xcarchive"
mkdir -p "$base/Products/Applications/ZashDock.app/Contents/MacOS" "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF"
cp "$app_info" "$base/Products/Applications/ZashDock.app/Contents/Info.plist"
cp "$archive_path/Products/Applications/ZashDock.app/Contents/MacOS/ZashDock" "$base/Products/Applications/ZashDock.app/Contents/MacOS/ZashDock"
cp "$archive_path/dSYMs/ZashDock.app.dSYM/Contents/Info.plist" "$base/dSYMs/ZashDock.app.dSYM/Contents/Info.plist"
cp "$archive_path/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock" "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock"
canary="ZASHDOCK_TEST_SECRET_MUST_NEVER_BE_PACKAGED_8ce57ed9"
printf '%s' "$canary" > "$base/signing-private.key"
printf '%s' "$canary" > "$base/dSYMs/ZashDock.app.dSYM/secret.p8"
/usr/libexec/PlistBuddy -c "Add :TEST_PRIVATE_KEY string $canary" "$base/dSYMs/ZashDock.app.dSYM/Contents/Info.plist"
# A resource fork/xattr is also excluded, even if build filesystem metadata contains unrelated bytes.
xattr -w app.zashdock.test-canary "$canary" "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock"
run_tool() {
  "$tool" --archive "$base" --output "$1" --source-commit "$source_commit" --version "$version" --build-number "$build_number" "${@:2}"
}
expect_failure() {
  local label=$1 output=$2
  shift 2
  if run_tool "$output" "$@" > "$fixture_root/failure.log" 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2; exit 1
  fi
  [[ ! -e "$output" ]] || { printf 'FAIL: %s left partial artifacts\n' "$label" >&2; exit 1; }
  printf 'PASS: %s rejected without partial output\n' "$label"
}
output="$fixture_root/diagnostics"
run_tool "$output" --workflow-run-id 12345 --workflow-run-attempt 2
metadata=$(find "$output" -name '*-build-metadata.json')
symbol_zip=$(find "$output" -name '*-dSYMs.zip')
checksums=$(find "$output" -name '*-diagnostics-SHA256SUMS.txt')
[[ $(find "$output" -type f | wc -l | tr -d ' ') == 3 ]]
jq -e --arg commit "$source_commit" --arg version "$version" --arg build "$build_number" '
  (keys | sort) == ["application","archived_executable_sha256","schema","source","symbols","toolchain","workflow"] and
  .schema == 1 and .source.commit == $commit and .application.version == $version and
  .application.build_number == $build and .application.architecture == "arm64" and
  .workflow.run_url == "https://github.com/MiracleHYH/ZashDock/actions/runs/12345" and .workflow.attempt == "2"
' "$metadata" >/dev/null
(cd "$output" && shasum -a 256 -c "${checksums##*/}")
unzip -p "$symbol_zip" > "$fixture_root/unpacked-symbol-bytes"
! LC_ALL=C grep -aFq "$canary" "$fixture_root/unpacked-symbol-bytes"
! LC_ALL=C grep -aFq "$canary" "$metadata"
unzip -Z1 "$symbol_zip" > "$fixture_root/zip-entries.txt"
! grep -Eq '(^|/)(\._|secret|signing|.*\.app/)|__MACOSX' "$fixture_root/zip-entries.txt"
mkdir "$fixture_root/unpacked"
unzip -q "$symbol_zip" -d "$fixture_root/unpacked"
actual_uuid=$(xcrun dwarfdump --uuid "$fixture_root/unpacked/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock" | awk '{print $2}')
[[ "$actual_uuid" == "$(jq -r .application.executable_uuid "$metadata")" ]]
[[ $(find "$fixture_root/unpacked" -type f | wc -l | tr -d ' ') == 2 ]]
printf '%s\n' 'PASS: matched dSYM, hashes, provenance and exactly two whitelisted ZIP files; key/file/plist/xattr canaries excluded'
# Existing output must remain untouched.
printf 'keep' > "$fixture_root/existing"
if run_tool "$fixture_root/existing" > "$fixture_root/failure.log" 2>&1; then exit 1; fi
[[ $(cat "$fixture_root/existing") == keep ]]
printf '%s\n' 'PASS: existing output preserved'
expect_failure 'unknown credential argument' "$fixture_root/unknown" --private-key "$canary"
expect_failure 'invalid workflow provenance' "$fixture_root/bad-provenance" --workflow-run-id 'not-a-run' --workflow-run-attempt 1
mv "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock" "$fixture_root/original-dwarf"
expect_failure 'missing dSYM' "$fixture_root/missing"
ln -s "$fixture_root/original-dwarf" "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock"
expect_failure 'symlink dSYM' "$fixture_root/symlink"
rm "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock"
# A different valid arm64 Mach-O is readable by dwarfdump but must fail UUID pairing.
printf '%s\n' 'int main(void) { return 0; }' > "$fixture_root/other.c"
xcrun clang -arch arm64 "$fixture_root/other.c" -o "$base/dSYMs/ZashDock.app.dSYM/Contents/Resources/DWARF/ZashDock"
expect_failure 'mismatched executable UUID' "$fixture_root/mismatched"
printf '%s\n' 'All 7 release-diagnostics checks passed. No publish operation was executed.'
