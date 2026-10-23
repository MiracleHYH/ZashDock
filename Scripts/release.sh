#!/bin/bash
# This script publishes remotely only from the protected, manually dispatched workflow.
set +x
set -euo pipefail
umask 077

fail() { printf 'Release stopped: %s\n' "$*" >&2; exit 1; }
if [[ "$#" != 1 || ( "${1:-}" != --publish && "${1:-}" != --validate-inputs ) ]]; then
  printf '%s\n' 'Usage: Scripts/release.sh --publish | --validate-inputs' \
    'Publish only through the manual Publish signed ZashDock workflow after configuring Docs/RELEASING.md.' \
    '--validate-inputs checks the selected profile and input presence locally; it never builds or publishes.'
  exit 2
fi

action=$1
if [[ "$action" == --publish ]]; then
  [[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] || fail 'manual GitHub Actions invocation required'
  [[ "${GITHUB_REPOSITORY:-}" == MiracleHYH/ZashDock && "${GITHUB_REF:-}" == refs/heads/main ]] || fail 'only MiracleHYH/ZashDock main may publish'
fi
[[ "${RELEASE_CONFIRM:-}" == PUBLISH ]] || fail 'explicit PUBLISH confirmation required'
[[ "${RELEASE_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'version must be a stable version such as 1.0.0'
[[ "${RELEASE_BUILD_NUMBER:-}" =~ ^[1-9][0-9]{0,8}$ ]] || fail 'build number must be an integer between 1 and 999999999'

signing_mode=${RELEASE_SIGNING_MODE:-developer-id}
[[ "$signing_mode" == developer-id || "$signing_mode" == adhoc ]] || fail 'signing mode must be developer-id or explicitly selected adhoc'
required_secrets=(GH_TOKEN SPARKLE_PRIVATE_KEY)
if [[ "$signing_mode" == developer-id ]]; then
  required_secrets+=(DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD APPLE_TEAM_ID NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID)
fi
for secret_name in "${required_secrets[@]}"; do
  [[ -n "${!secret_name:-}" ]] || fail "missing required secret: $secret_name"
done
if [[ "$signing_mode" == developer-id ]]; then
  [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'invalid Apple team identifier'
  [[ "$NOTARY_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'invalid App Store Connect key identifier'
  [[ "$NOTARY_ISSUER_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || fail 'invalid App Store Connect issuer identifier'
else
  # This profile neither needs nor uses any Apple signing or notarization material.
  unset DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD APPLE_TEAM_ID NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID
fi
if [[ "$action" == --validate-inputs ]]; then
  printf 'Release input profile validated: %s. Credentials were not authenticated; no build or remote action was performed.\n' "$signing_mode"
  exit 0
fi
[[ "$(uname -m)" == arm64 ]] || fail 'an Apple Silicon runner is required'

cd "$(dirname "$0")/.."
repository=MiracleHYH/ZashDock
source_commit=$(git rev-parse HEAD)
[[ "$source_commit" == "$GITHUB_SHA" ]] || fail 'checkout does not match workflow source'
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail 'tracked source changes are present'
[[ "$(gh api "repos/$repository" --jq .default_branch)" == main ]] || fail 'default branch must be main'

assert_current_main() {
  local remote_commit
  remote_commit=$(gh api "repos/$repository/git/ref/heads/main" --jq .object.sha)
  [[ "$remote_commit" == "$source_commit" ]] || fail 'main changed during release preparation; dispatch again from its newest commit'
}
assert_unused_release() {
  local releases tags
  releases=$(gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[].tag_name')
  if /usr/bin/grep -Fxq -- "$tag" <<< "$releases"; then
    fail 'this release already exists; existing assets will never be overwritten'
  fi
  tags=$(gh api "repos/$repository/git/matching-refs/tags/$tag" --jq '.[].ref')
  if /usr/bin/grep -Fxq -- "refs/tags/$tag" <<< "$tags"; then
    fail 'this tag already exists; choose a new version'
  fi
}

tag="v$RELEASE_VERSION"
asset_name="ZashDock-$RELEASE_VERSION-arm64.zip"
asset_url="https://github.com/$repository/releases/download/$tag/$asset_name"
feed_url="https://raw.githubusercontent.com/$repository/main/appcast.xml"
diagnostics_basename="ZashDock-$RELEASE_VERSION-build$RELEASE_BUILD_NUMBER-arm64"
diagnostics_dir="${RELEASE_DIAGNOSTICS_DIR:-$PWD/build/ReleaseDiagnostics/$tag-build$RELEASE_BUILD_NUMBER}"
[[ "$diagnostics_dir" == /* && ! -e "$diagnostics_dir" ]] || fail 'release diagnostics need a fresh absolute output directory'
diagnostics_zip="$diagnostics_dir/$diagnostics_basename-dSYMs.zip"
diagnostics_metadata="$diagnostics_dir/$diagnostics_basename-build-metadata.json"
diagnostics_checksums="$diagnostics_dir/$diagnostics_basename-diagnostics-SHA256SUMS.txt"
assert_current_main
assert_unused_release

release_temp=$(mktemp -d "${RUNNER_TEMP:?}/zashdock-release.XXXXXX")
[[ "$diagnostics_dir" != "$release_temp" && "$diagnostics_dir" != "$release_temp/"* ]] || fail 'diagnostics must survive outside the temporary signing directory'
keychain="$release_temp/signing.keychain-db"
original_keychains=()
if [[ "$signing_mode" == developer-id ]]; then
  while IFS= read -r keychain_line; do
    keychain_line="${keychain_line#*\"}"
    keychain_line="${keychain_line%\"*}"
    [[ -z "$keychain_line" ]] || original_keychains+=("$keychain_line")
  done < <(security list-keychains -d user)
fi
release_published=false
feed_pushed=false
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$signing_mode" == developer-id ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    [[ ! -f "$keychain" ]] || security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -rf "$release_temp"
  if [[ "$release_published" == true && "$feed_pushed" != true ]]; then
    printf '%s\n' "Release $tag is public, but the feed was not committed. Follow the recovery steps in Docs/RELEASING.md; do not replace release assets." >&2
  fi
  exit "$result"
}
trap cleanup EXIT

printf '%s' "$SPARKLE_PRIVATE_KEY" > "$release_temp/sparkle-private.key"
unset SPARKLE_PRIVATE_KEY
if [[ "$signing_mode" == developer-id ]]; then
  printf '%s' "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$release_temp/developer-id.p12"
  printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$release_temp/notary.p8"
  unset DEVELOPER_ID_CERTIFICATE_BASE64 NOTARY_KEY_P8_BASE64
fi

# Read the public key from the App source, never from a duplicated repository variable.
cat > "$release_temp/validate-key.swift" <<'SWIFT'
import Foundation
import CryptoKit
let arguments = CommandLine.arguments
let keyText = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: keyText), seed.count == 32,
      let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[2])), format: nil) as? [String: Any],
      let expected = info["SUPublicEDKey"] as? String,
      let expectedData = Data(base64Encoded: expected), expectedData.count == 32,
      try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation == expectedData else {
    fputs("Sparkle private key does not match the App public key, or is not a 32-byte seed.\n", stderr)
    exit(1)
}
SWIFT
xcrun swift "$release_temp/validate-key.swift" "$release_temp/sparkle-private.key" Config/Info.plist

# Pin both the tool release and its digest. No mutable latest URL is used.
sparkle_version=2.10.0
sparkle_digest=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  --output "$release_temp/Sparkle.tar.xz"
[[ "$(shasum -a 256 "$release_temp/Sparkle.tar.xz" | awk '{print $1}')" == "$sparkle_digest" ]] || fail 'Sparkle tool archive checksum mismatch'
mkdir "$release_temp/Sparkle" "$release_temp/updates"
tar -xJf "$release_temp/Sparkle.tar.xz" -C "$release_temp/Sparkle"
sparkle_bin="$release_temp/Sparkle/bin"
[[ -x "$sparkle_bin/generate_appcast" && -x "$sparkle_bin/sign_update" ]] || fail 'Sparkle signing tools are missing'
cp appcast.xml "$release_temp/previous-appcast.xml"
"$sparkle_bin/sign_update" --verify --ed-key-file "$release_temp/sparkle-private.key" "$release_temp/previous-appcast.xml"

cat > "$release_temp/validate-feed.swift" <<'SWIFT'
import Foundation
import CryptoKit
func reject(_ reason: String) -> Never { fputs("Appcast validation failed: \(reason)\n", stderr); exit(1) }
func items(_ path: String) throws -> [XMLElement] {
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodeLoadExternalEntitiesNever])
    guard (try document.nodes(forXPath: "/rss/channel")).count == 1 else { reject("one RSS channel is required") }
    return try document.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
}
func text(_ element: XMLElement, _ name: String) throws -> String? {
    try element.nodes(forXPath: "./*[local-name()='\(name)']").first?.stringValue
}
func version(_ item: XMLElement) throws -> UInt64 {
    let raw = try text(item, "version") ?? item.elements(forName: "enclosure").first?.attribute(forName: "sparkle:version")?.stringValue ?? ""
    guard let result = UInt64(raw), result > 0, String(result) == raw else { reject("build numbers must be positive integers") }
    return result
}
let args = CommandLine.arguments
guard let build = UInt64(args[2]) else { reject("invalid requested build") }
let previous = try items(args[1])
let previousBuilds = try previous.map(version)
guard Set(previousBuilds).count == previousBuilds.count,
      previousBuilds.allSatisfy({ $0 < build }) else { reject("build must exceed every existing feed item") }
if args.count > 3 {
    let current = try items(args[3])
    let builds = try current.map(version)
    guard Set(builds).count == builds.count, Set(builds) == Set(previousBuilds + [build]),
          let item = try current.first(where: { try version($0) == build }),
          try text(item, "shortVersionString") == args[4],
          let enclosure = item.elements(forName: "enclosure").first,
          enclosure.attribute(forName: "url")?.stringValue == args[5],
          enclosure.attribute(forName: "length")?.stringValue == args[6],
          let encodedSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let signature = Data(base64Encoded: encodedSignature), signature.count == 64,
          try text(item, "minimumSystemVersion") == "26.0" else { reject("new item metadata, signature, or retained history is invalid") }
    guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[8])), format: nil) as? [String: Any],
          let encodedPublicKey = info["SUPublicEDKey"] as? String,
          let publicKeyData = Data(base64Encoded: encodedPublicKey),
          try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData).isValidSignature(signature, for: Data(contentsOf: URL(fileURLWithPath: args[7]), options: .mappedIfSafe)) else {
        reject("ZIP signature does not match the App public key")
    }
}
SWIFT
xcrun swift "$release_temp/validate-feed.swift" "$release_temp/previous-appcast.xml" "$RELEASE_BUILD_NUMBER"

if [[ "$signing_mode" == developer-id ]]; then
  keychain_password=$(openssl rand -hex 32)
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 7200 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$release_temp/developer-id.p12" -k "$keychain" -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  unset DEVELOPER_ID_CERTIFICATE_PASSWORD
  security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
  identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/{print $2}')
  [[ "$identity" =~ ^[A-Fa-f0-9]{40}$ ]] || fail 'exactly one valid Developer ID Application identity is required'
  archive_signing_flags=(DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--keychain $keychain")
else
  # Sparkle is a separately loaded framework. With no Developer ID Team, Library
  # Validation cannot establish same-team trust, so allow only this runtime
  # exception for the explicitly selected ad-hoc profile.
  cp Config/ZashDock.entitlements "$release_temp/adhoc.entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$release_temp/adhoc.entitlements"
  archive_signing_flags=(DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES OTHER_CODE_SIGN_FLAGS=--timestamp=none CODE_SIGN_ENTITLEMENTS="$release_temp/adhoc.entitlements")
fi

xcodebuild -project ZashDock.xcodeproj -scheme ZashDock -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$release_temp/ZashDock.xcarchive" \
  -derivedDataPath build/ReleaseDerivedData -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$RELEASE_VERSION" CURRENT_PROJECT_VERSION="$RELEASE_BUILD_NUMBER" \
  "${archive_signing_flags[@]}" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO archive

# Preserve matched symbols immediately after a successful archive, even if export,
# notarization, feed generation, or publication later fails. This separate directory
# survives cleanup and is never scanned by Sparkle's generate_appcast.
diagnostics_args=(--archive "$release_temp/ZashDock.xcarchive" --output "$diagnostics_dir"
  --source-commit "$source_commit" --version "$RELEASE_VERSION" --build-number "$RELEASE_BUILD_NUMBER"
  --workflow-run-id "${GITHUB_RUN_ID:?}" --workflow-run-attempt "${GITHUB_RUN_ATTEMPT:?}")
xcrun swift Scripts/prepare-release-diagnostics.swift "${diagnostics_args[@]}"

if [[ "$signing_mode" == developer-id ]]; then
  cat > "$release_temp/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>manual</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>signingCertificate</key><string>$identity</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$release_temp/ZashDock.xcarchive" \
  -exportPath "$release_temp/export" -exportOptionsPlist "$release_temp/ExportOptions.plist"
else
  # An ad-hoc archive needs no Developer ID export. Preserve the complete bundle,
  # including nested Sparkle code and its signatures, without reassembling it.
  mkdir "$release_temp/export"
  ditto "$release_temp/ZashDock.xcarchive/Products/Applications/ZashDock.app" "$release_temp/export/ZashDock.app"
fi
app="$release_temp/export/ZashDock.app"
info="$app/Contents/Info.plist"
read_info() { /usr/libexec/PlistBuddy -c "Print :$1" "$info"; }
[[ "$(read_info CFBundleIdentifier)" == app.zashdock.mac ]] || fail 'Bundle ID mismatch'
[[ "$(read_info CFBundleShortVersionString)" == "$RELEASE_VERSION" && "$(read_info CFBundleVersion)" == "$RELEASE_BUILD_NUMBER" ]] || fail 'archive version does not match requested release and tag'
[[ "$(read_info SUFeedURL)" == "$feed_url" && "$(read_info SURequireSignedFeed)" == true ]] || fail 'archive requires the official signed update feed'
[[ "$(read_info SUSignedFeedFailureExpirationInterval)" == 0 && "$(read_info SUVerifyUpdateBeforeExtraction)" == true ]] || fail 'archive must reject unsigned feeds and verify updates before extraction'
[[ "$(lipo -archs "$app/Contents/MacOS/ZashDock")" == arm64 ]] || fail 'App executable must contain only arm64'
exported_uuid=$(xcrun dwarfdump --uuid "$app/Contents/MacOS/ZashDock" | awk '{print $2}')
[[ "$exported_uuid" == "$(jq -r .application.executable_uuid "$diagnostics_metadata")" ]] || fail 'retained symbols do not match the exported App UUID'
xcrun swift "$release_temp/validate-key.swift" "$release_temp/sparkle-private.key" "$info"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --verbose=4 "$app" > "$release_temp/codesign.txt" 2>&1
/usr/bin/grep -Eq 'flags=.*runtime' "$release_temp/codesign.txt" || fail 'hardened runtime is missing'
codesign --display --entitlements "$release_temp/app-entitlements.plist" --xml "$app" 2> "$release_temp/entitlements-log.txt"
plutil -lint "$release_temp/app-entitlements.plist" >/dev/null
for entitlement in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server com.apple.security.files.user-selected.read-write; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$release_temp/app-entitlements.plist")" == true ]] || fail "required release entitlement is missing: $entitlement"
done
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$release_temp/app-entitlements.plist" >/dev/null 2>&1; then
  fail 'release App must not contain get-task-allow'
fi
if [[ "$signing_mode" == developer-id ]]; then
  /usr/bin/grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" "$release_temp/codesign.txt" || fail 'signed App team does not match APPLE_TEAM_ID'
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$release_temp/app-entitlements.plist" >/dev/null 2>&1; then
    fail 'Developer ID release must preserve Library Validation'
  fi
else
  /usr/bin/grep -Fxq 'Signature=adhoc' "$release_temp/codesign.txt" || fail 'explicit ad-hoc signature is missing'
  /usr/bin/grep -Fxq 'TeamIdentifier=not set' "$release_temp/codesign.txt" || fail 'ad-hoc App unexpectedly has a signing team'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$release_temp/app-entitlements.plist")" == true ]] || fail 'ad-hoc Sparkle framework requires its Library Validation exception'
fi

if [[ "$signing_mode" == developer-id ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$release_temp/notarization.zip"
  xcrun notarytool submit "$release_temp/notarization.zip" --key "$release_temp/notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m \
    --output-format json > "$release_temp/notary-result.json"
  [[ "$(jq -r .status "$release_temp/notary-result.json")" == Accepted ]] || fail 'Apple notarization was not accepted'
  submission_id=$(jq -r .id "$release_temp/notary-result.json")
  xcrun notarytool log "$submission_id" --key "$release_temp/notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" "$release_temp/notary-log.json"
  jq -e '.status == "Accepted" and ((.issues // []) | all(.severity != "error"))' "$release_temp/notary-log.json" >/dev/null || fail 'notarization log contains errors'
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  codesign --verify --deep --strict "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$release_temp/updates/$asset_name"
cp "$release_temp/previous-appcast.xml" "$release_temp/updates/appcast.xml"
release_notes="$release_temp/updates/${asset_name%.zip}.md"
notes_source="Docs/RELEASE-NOTES-$RELEASE_VERSION.md"
if [[ -f "$notes_source" ]]; then
  [[ ! -L "$notes_source" ]] || fail 'release notes must be a regular source file'
  cat "$notes_source" > "$release_notes"
else
  printf 'ZashDock %s 正式版。\n' "$RELEASE_VERSION" > "$release_notes"
fi
{
  printf '\n---\n\nZashDock %s 正式版（Build %s），macOS 26+，Apple Silicon。\n\n' "$RELEASE_VERSION" "$RELEASE_BUILD_NUMBER"
  printf '源码提交：`%s`。签名模式：`%s`。\n\n' "$source_commit" "$signing_mode"
  if [[ "$signing_mode" == developer-id ]]; then
    printf '%s\n' '应用已使用 Developer ID 签名、通过 Apple 公证并附带公证票据；ZIP 和更新 Feed 另有 Sparkle EdDSA 签名。'
  else
    printf '%s\n' '应用使用 ad-hoc 签名，未使用 Developer ID 证书，也未通过 Apple 公证；ZIP 和更新 Feed 使用 Sparkle EdDSA 签名验证更新完整性。首次打开可能受到 macOS Gatekeeper 限制，请在确认下载来源后使用系统提供的打开许可。'
  fi
  printf '\n%s\n' 'Zashboard 网页资源在应用内独立安装和更新。'
} >> "$release_notes"
"$sparkle_bin/generate_appcast" --ed-key-file "$release_temp/sparkle-private.key" \
  --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
  --embed-release-notes --maximum-versions 0 --maximum-deltas 0 "$release_temp/updates"
"$sparkle_bin/sign_update" --verify --ed-key-file "$release_temp/sparkle-private.key" "$release_temp/updates/appcast.xml"
zip_length=$(stat -f %z "$release_temp/updates/$asset_name")
xcrun swift "$release_temp/validate-feed.swift" "$release_temp/previous-appcast.xml" "$RELEASE_BUILD_NUMBER" \
  "$release_temp/updates/appcast.xml" "$RELEASE_VERSION" "$asset_url" "$zip_length" "$release_temp/updates/$asset_name" "$info"
(
  cd "$release_temp/updates"
  shasum -a 256 "$asset_name" appcast.xml > SHA256SUMS.txt
)

# Finish every validation before the first remote mutation. Draft uploads are
# complete before publishing. If repository release immutability is enabled,
# publication also locks every asset and the tag on GitHub.
assert_current_main
assert_unused_release
gh release create "$tag" --repo "$repository" --target "$source_commit" \
  --title "ZashDock $RELEASE_VERSION" --draft --prerelease=false \
  --notes-file "$release_temp/updates/${asset_name%.zip}.md" \
  "$release_temp/updates/$asset_name" "$release_temp/updates/appcast.xml" "$release_temp/updates/SHA256SUMS.txt" \
  "$diagnostics_zip" "$diagnostics_metadata" "$diagnostics_checksums"
assert_current_main
gh release edit "$tag" --repo "$repository" --draft=false --prerelease=false --latest
release_published=true
[[ "$(gh api "repos/$repository/git/ref/tags/$tag" --jq .object.sha)" == "$source_commit" ]] || fail 'published tag does not point at the built source'

# Never rebase or force-push a feed prepared against an outdated main. A
# concurrent source push leaves the published release intact and the old feed safe.
assert_current_main
cp "$release_temp/updates/appcast.xml" appcast.xml
git add -- appcast.xml
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -m "Update signed appcast for $tag (build $RELEASE_BUILD_NUMBER)"
gh auth setup-git --hostname github.com
git push origin HEAD:refs/heads/main
feed_pushed=true
printf 'Published https://github.com/%s/releases/tag/%s and updated the signed feed.\n' "$repository" "$tag"
