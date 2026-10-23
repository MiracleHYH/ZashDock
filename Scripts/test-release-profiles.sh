#!/bin/bash
# Exercise profile selection with synthetic inputs. Never use real credentials,
# build an App, access a Keychain, make a network request, or mutate a repository.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/Scripts/release.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/zashdock-release-profiles.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT
mkdir "$fixture_root/bin"
for command_name in security xcrun xcodebuild gh curl git uname; do
  cat > "$fixture_root/bin/$command_name" <<'MOCK'
#!/bin/bash
printf 'Unexpected external operation during input validation: %s\n' "${0##*/}" >&2
exit 97
MOCK
  chmod +x "$fixture_root/bin/$command_name"
done
canary=ZASHDOCK_SYNTHETIC_CREDENTIAL_CANARY_5791
common=(PATH="$fixture_root/bin" RELEASE_VERSION=1.0.0 RELEASE_BUILD_NUMBER=2 RELEASE_CONFIRM=PUBLISH GH_TOKEN="$canary" SPARKLE_PRIVATE_KEY="$canary")
apple=(DEVELOPER_ID_CERTIFICATE_BASE64="$canary" DEVELOPER_ID_CERTIFICATE_PASSWORD="$canary" APPLE_TEAM_ID=ABCDEFGHIJ NOTARY_KEY_P8_BASE64="$canary" NOTARY_KEY_ID=KLMNOPQRST NOTARY_ISSUER_ID=12345678-1234-1234-1234-123456789abc)
checks=0
assert_no_sensitive_output() {
  if /usr/bin/grep -Fq "$canary" "$fixture_root/result.log"; then
    printf '%s\n' 'FAIL: input validation printed a credential value' >&2
    exit 1
  fi
  if /usr/bin/grep -Fq 'Unexpected external operation' "$fixture_root/result.log"; then
    cat "$fixture_root/result.log" >&2
    exit 1
  fi
}
expect_success() {
  local label=$1
  shift
  /usr/bin/env -i "${common[@]}" "$@" /bin/bash "$script" --validate-inputs > "$fixture_root/result.log" 2>&1
  assert_no_sensitive_output
  /usr/bin/grep -Fq 'Credentials were not authenticated; no build or remote action was performed.' "$fixture_root/result.log"
  checks=$((checks + 1))
  printf 'PASS: %s\n' "$label"
}
expect_failure() {
  local label=$1 expected=$2
  shift 2
  if /usr/bin/env -i "${common[@]}" "$@" /bin/bash "$script" --validate-inputs > "$fixture_root/result.log" 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  assert_no_sensitive_output
  /usr/bin/grep -Fq "$expected" "$fixture_root/result.log"
  checks=$((checks + 1))
  printf 'PASS: %s\n' "$label"
}
expect_success 'explicit ad-hoc profile needs no Apple credentials' RELEASE_SIGNING_MODE=adhoc
expect_success 'ad-hoc profile ignores unusable Apple credential inputs' RELEASE_SIGNING_MODE=adhoc APPLE_TEAM_ID=invalid NOTARY_KEY_ID=invalid NOTARY_ISSUER_ID=invalid
expect_failure 'default Developer ID profile cannot silently downgrade' 'missing required secret: DEVELOPER_ID_CERTIFICATE_BASE64'
expect_failure 'explicit Developer ID profile requires Apple credentials' 'missing required secret: DEVELOPER_ID_CERTIFICATE_BASE64' RELEASE_SIGNING_MODE=developer-id
expect_success 'Developer ID profile accepts complete synthetic input presence' RELEASE_SIGNING_MODE=developer-id "${apple[@]}"
expect_failure 'Developer ID profile validates the team identifier' 'invalid Apple team identifier' RELEASE_SIGNING_MODE=developer-id "${apple[@]}" APPLE_TEAM_ID=invalid
expect_failure 'unknown signing profile is rejected' 'signing mode must be developer-id or explicitly selected adhoc' RELEASE_SIGNING_MODE=automatic
expect_failure 'ad-hoc profile still requires the Sparkle key' 'missing required secret: SPARKLE_PRIVATE_KEY' RELEASE_SIGNING_MODE=adhoc SPARKLE_PRIVATE_KEY=
expect_failure 'ad-hoc profile still requires GitHub authorization' 'missing required secret: GH_TOKEN' RELEASE_SIGNING_MODE=adhoc GH_TOKEN=
expect_failure 'prerelease version is rejected' 'version must be a stable version' RELEASE_SIGNING_MODE=adhoc RELEASE_VERSION=1.0.0-beta
expect_failure 'invalid build is rejected' 'build number must be an integer' RELEASE_SIGNING_MODE=adhoc RELEASE_BUILD_NUMBER=0
expect_failure 'publication still requires explicit confirmation' 'explicit PUBLISH confirmation required' RELEASE_SIGNING_MODE=adhoc RELEASE_CONFIRM=
if /usr/bin/env -i "${common[@]}" RELEASE_SIGNING_MODE=adhoc /bin/bash "$script" --publish > "$fixture_root/result.log" 2>&1; then
  printf '%s\n' 'FAIL: publishing outside manual GitHub Actions unexpectedly succeeded' >&2
  exit 1
fi
assert_no_sensitive_output
/usr/bin/grep -Fq 'manual GitHub Actions invocation required' "$fixture_root/result.log"
checks=$((checks + 1))
printf '%s\n' 'PASS: local publish invocation is rejected before any operation'

# Ensure workflow-level isolation as well as the shell-level profile selection.
/usr/bin/ruby -ryaml -e '
workflow = YAML.load_file(".github/workflows/release.yml")
steps = workflow.fetch("jobs").fetch("publish").fetch("steps")
adhoc = steps.find { |step| step["if"] == "inputs.signing_mode == '\''adhoc'\''" }
developer = steps.find { |step| step["if"] == "inputs.signing_mode == '\''developer-id'\''" }
abort "ad-hoc publishing step is missing" unless adhoc
abort "Developer ID publishing step is missing" unless developer
apple = %w[DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD APPLE_TEAM_ID NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID]
abort "ad-hoc step loads Apple credentials" unless (apple & adhoc.fetch("env").keys).empty?
abort "ad-hoc step does not explicitly select its profile" unless adhoc.fetch("env")["RELEASE_SIGNING_MODE"] == "adhoc"
abort "Developer ID step is missing Apple inputs" unless (apple - developer.fetch("env").keys).empty?
abort "Developer ID step does not explicitly select its profile" unless developer.fetch("env")["RELEASE_SIGNING_MODE"] == "developer-id"
puts "PASS: workflow isolates Apple secrets to Developer ID publication"
'
checks=$((checks + 1))
printf 'Release profile checks passed: %s.\n' "$checks"
