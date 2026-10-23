#!/bin/bash
# Real, separate macOS application processes; no production store, Keychain or native website snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
test_mode=${1:-full}
[[ "$test_mode" == full || "$test_mode" == --persistence-only ]] || { printf '%s\n' 'Usage: Scripts/test-storage-processes.sh [--persistence-only]' >&2; exit 2; }
build_variant=full
if [[ "$test_mode" == --persistence-only ]]; then build_variant=persistence-only; fi
build_root="$PWD/build/OriginStorageProcessHarness/$build_variant"
mkdir -p "$build_root" "$PWD/build/verification"
report_root=$(mktemp -d "$PWD/build/verification/storage-processes.XXXXXX")
app="$build_root/OriginStorageProcessHarness.app"
binary="$app/Contents/MacOS/OriginStorageProcessHarness"
mkdir -p "$app/Contents/MacOS"
cp Tests/OriginStorageProcessHarness/Info.plist "$app/Contents/Info.plist"
compile_arguments=(-parse-as-library -swift-version 6 -target arm64-apple-macos26.0
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$build_root/ModuleCache"
  Tests/OriginStorageProcessHarness/Harness.swift)
if [[ "$test_mode" == full ]]; then
  [[ -f Sources/ZashDock/OriginStorageTransfer.swift ]] || { printf '%s\n' 'OriginStorageTransfer.swift is required for the full process regression.' >&2; exit 2; }
  compile_arguments+=(-D PROCESS_TRANSFER Sources/ZashDock/OriginStorageTransfer.swift)
fi
xcrun swiftc "${compile_arguments[@]}" -o "$binary"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
scenario_roots=()
harness_pids=()
active_harness_pid=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$active_harness_pid" ]]; then kill -KILL "$active_harness_pid" 2>/dev/null || true; fi
  local scenario_root
  for scenario_root in "${scenario_roots[@]}"; do
    if [[ -f "$scenario_root/fixture.json" ]]; then
      if ! "$binary" cleanup-profile "$scenario_root" > "$scenario_root/cleanup.log" 2>&1; then
        printf 'FAIL: cleanup of isolated fixture profile in %s\n' "$scenario_root" >&2
        if [[ "$result" == 0 ]]; then result=1; fi
      fi
    fi
  done
  printf 'Process evidence: %s\n' "$report_root"
  exit "$result"
}
trap cleanup EXIT
run_process() {
  local harness_phase=$1 scenario_root=$2
  shift 2
  "$binary" "$harness_phase" "$scenario_root" "$@" > "$scenario_root/$harness_phase.log" 2>&1 &
  active_harness_pid=$!
  harness_pids+=("$active_harness_pid")
  if ! wait "$active_harness_pid"; then
    active_harness_pid=
    cat "$scenario_root/$harness_phase.log" >&2
    return 1
  fi
  active_harness_pid=
  cat "$scenario_root/$harness_phase.log"
  [[ -f "$scenario_root/$harness_phase.json" ]]
}
kill_at_boundary() {
  local harness_phase=$1 scenario_root=$2
  "$binary" "$harness_phase" "$scenario_root" --hold > "$scenario_root/$harness_phase.log" 2>&1 &
  active_harness_pid=$!
  harness_pids+=("$active_harness_pid")
  local attempt
  for ((attempt=0; attempt<1500; attempt++)); do
    if [[ -f "$scenario_root/$harness_phase.json" ]]; then break; fi
    if ! kill -0 "$active_harness_pid" 2>/dev/null; then cat "$scenario_root/$harness_phase.log" >&2; return 1; fi
    sleep 0.02
  done
  [[ -f "$scenario_root/$harness_phase.json" ]] || { printf 'Timeout before %s readiness marker\n' "$harness_phase" >&2; return 1; }
  kill -KILL "$active_harness_pid"
  wait "$active_harness_pid" 2>/dev/null || true
  active_harness_pid=
  cat "$scenario_root/$harness_phase.log"
  printf 'PASS: external SIGKILL at %s boundary\n' "$harness_phase"
}
new_scenario() {
  current_scenario="$report_root/$1"
  mkdir -p "$current_scenario"
  scenario_roots+=("$current_scenario")
  run_process prepare "$current_scenario"
}
new_scenario normal
run_process seed "$current_scenario"
run_process verify-old "$current_scenario" --expect-old
if [[ "$test_mode" == full ]]; then
  run_process transfer "$current_scenario"
  run_process verify-current "$current_scenario" --expect-new
  run_process finish-cleanup "$current_scenario" --expect-new
  # A fresh process, after the cleanup process exits, still sees the new current configuration.
  rm "$current_scenario/verify-current.json"
  run_process verify-current "$current_scenario" --expect-new

  new_scenario killed-writer
  kill_at_boundary seed "$current_scenario"
  run_process verify-old "$current_scenario" --expect-old

  new_scenario killed-before-port-commit
  run_process seed "$current_scenario"
  kill_at_boundary before-commit "$current_scenario"
  run_process verify-current "$current_scenario" --expect-old

  new_scenario killed-after-port-commit
  run_process seed "$current_scenario"
  kill_at_boundary after-commit "$current_scenario"
  run_process verify-current "$current_scenario" --expect-new
  run_process finish-cleanup "$current_scenario" --expect-new
fi
unique_pids=$(printf '%s\n' "${harness_pids[@]}" | sort -u | wc -l | tr -d ' ')
printf '%s\n' "${harness_pids[@]}" > "$report_root/process-pids.txt"
[[ "$unique_pids" == "${#harness_pids[@]}" ]] || { printf '%s\n' 'Fixture process PIDs unexpectedly repeated.' >&2; exit 1; }
printf 'PASS: %s distinct app process PIDs; real process exit/relaunch, no OS-reboot claim.\n' "$unique_pids"
if [[ "$test_mode" == full ]]; then
  printf '%s\n' 'The commit-boundary cases model only primary port metadata; they do not yet establish production AppModel crash recovery.'
fi
