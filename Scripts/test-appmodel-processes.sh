#!/bin/bash
# Separate AppKit processes running production AppModel; no product hooks or default WebKit profile.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 0 ]] || { printf '%s\n' 'Usage: Scripts/test-appmodel-processes.sh' >&2; exit 2; }
command -v jq > /dev/null || { printf '%s\n' 'jq is required for external primary-metadata observation.' >&2; exit 2; }
build_root="$PWD/build/AppModelProcessHarness"
mkdir -p "$build_root" "$PWD/build/verification"
report_root=$(mktemp -d "$PWD/build/verification/appmodel-processes.XXXXXX")
app="$build_root/AppModelProcessHarness.app"
binary="$app/Contents/MacOS/AppModelProcessHarness"
mkdir -p "$app/Contents/MacOS"
cp Tests/AppModelProcessHarness/Info.plist "$app/Contents/Info.plist"
# Build Core in this harness's own scratch tree, independent of concurrent xcodebuild.
xcrun swift build --package-path Packages/ZashDockCore --scratch-path "$build_root/Core" -c debug > "$build_root/core-build.log" 2>&1
core_bin=$(xcrun swift build --package-path Packages/ZashDockCore --scratch-path "$build_root/Core" -c debug --show-bin-path)
core_modules="$core_bin/Modules"
core_objects=("$core_bin"/ZashDockCore.build/*.swift.o)
# Current SwiftPM may select the Xcode build backend and emit one merged object.
if [[ -f "$core_bin/ZashDockCore.o" ]]; then
  core_objects=("$core_bin/ZashDockCore.o")
  core_modules="$core_bin"
fi
[[ -f "${core_objects[0]}" ]] || { printf '%s\n' 'Core object files missing.' >&2; exit 2; }
production_sources=(Sources/ZashDock/AppModel.swift Sources/ZashDock/WebSession.swift
  Sources/ZashDock/WebInteractionCoordinator.swift Sources/ZashDock/OriginStorageTransfer.swift)
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$build_root/ModuleCache" \
  -I "$core_modules" -I Packages/ZashDockCore/Sources/CZlib \
  Tests/AppModelProcessHarness/Harness.swift "${production_sources[@]}" "${core_objects[@]}" -lz -o "$binary"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
shasum -a 256 "${production_sources[@]}" Packages/ZashDockCore/Sources/ZashDockCore/*.swift > "$report_root/source-SHA256SUMS.txt"
fixture_root="$report_root/fixture"
mkdir -p "$fixture_root"
harness_pids=()
active_harness_pid=
sentinel_pid=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$active_harness_pid" ]]; then kill -KILL "$active_harness_pid" 2>/dev/null || true; wait "$active_harness_pid" 2>/dev/null || true; fi
  if [[ -n "$sentinel_pid" ]]; then kill -TERM "$sentinel_pid" 2>/dev/null || true; wait "$sentinel_pid" 2>/dev/null || true; fi
  if [[ -f "$fixture_root/fixture.json" ]]; then
    if ! "$binary" cleanup-profile "$fixture_root" > "$fixture_root/cleanup.log" 2>&1; then
      printf 'FAIL: cleanup of isolated fixture profile in %s\n' "$fixture_root" >&2
      if [[ "$result" == 0 ]]; then result=1; fi
    fi
  fi
  printf 'AppModel process evidence: %s\n' "$report_root"
  exit "$result"
}
trap cleanup EXIT
run_process() {
  local phase=$1
  "$binary" "$phase" "$fixture_root" > "$fixture_root/$phase.log" 2>&1 &
  active_harness_pid=$!
  harness_pids+=("$active_harness_pid")
  if ! wait "$active_harness_pid"; then
    active_harness_pid=
    cat "$fixture_root/$phase.log" >&2
    return 1
  fi
  active_harness_pid=
  cat "$fixture_root/$phase.log"
  [[ -f "$fixture_root/$phase.json" ]]
}
run_process prepare
run_process seed
run_process verify-old

# The sentinel owns oldPort in a different process before the real AppModel starts.
"$binary" sentinel "$fixture_root" > "$fixture_root/sentinel.log" 2>&1 &
sentinel_pid=$!
harness_pids+=("$sentinel_pid")
for ((attempt=0; attempt<1500; attempt++)); do
  if [[ -f "$fixture_root/sentinel.json" ]]; then break; fi
  if ! kill -0 "$sentinel_pid" 2>/dev/null; then cat "$fixture_root/sentinel.log" >&2; exit 1; fi
  sleep 0.02
done
[[ -f "$fixture_root/sentinel.json" ]]
target_port=$(jq -er .newPort "$fixture_root/fixture.json")
"$binary" transfer "$fixture_root" > "$fixture_root/transfer.log" 2>&1 &
active_harness_pid=$!
harness_pids+=("$active_harness_pid")
commit_observed=false
for ((attempt=0; attempt<3000; attempt++)); do
  if ! kill -0 "$active_harness_pid" 2>/dev/null; then cat "$fixture_root/transfer.log" >&2; exit 1; fi
  if [[ -f "$fixture_root/transfer-started.json" ]] && \
      jq -e --argjson port "$target_port" '.port == $port' "$fixture_root/app-root/configuration.json" > /dev/null; then
    # Observe the production primary commit externally; no product callback or test hook.
    jq --argjson pid "$active_harness_pid" '{writerPID:$pid,observedConfiguration:.}' \
      "$fixture_root/app-root/configuration.json" > "$fixture_root/commit-observed.json"
    commit_observed=true
    break
  fi
  sleep 0.01
done
[[ "$commit_observed" == true ]] || { printf '%s\n' 'Timeout before actual AppModel port commit.' >&2; exit 1; }
kill -KILL "$active_harness_pid"
if wait "$active_harness_pid" 2>/dev/null; then
  printf '%s\n' 'FAIL: expected SIGKILL did not terminate writer.' >&2; exit 1
else
  [[ $? == 137 ]] || { printf '%s\n' 'FAIL: writer did not terminate with SIGKILL status.' >&2; exit 1; }
fi
active_harness_pid=
printf '%s\n' 'PASS: external SIGKILL after observing actual AppModel configuration commit'

# Old port stays occupied across writer death and both independent cold starts.
run_process verify-new
run_process verify-new-again
sleep 0.1
jq -e '.connections == 0' "$fixture_root/sentinel-count.json" > /dev/null
unique_pids=$(printf '%s\n' "${harness_pids[@]}" | sort -u | wc -l | tr -d ' ')
printf '%s\n' "${harness_pids[@]}" > "$report_root/process-pids.txt"
[[ "$unique_pids" == "${#harness_pids[@]}" ]]
printf 'PASS: %s distinct process PIDs; production AppModel normal restart, occupied-port migration and committed-port SIGKILL restart; sentinel connections 0.\n' "$unique_pids"
printf '%s\n' 'This fixture has no App Sandbox entitlement; xcodebuild integration suites cover the sandboxed app. No OS-reboot or pre-commit crash coverage is claimed.'
