#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
sdkPath="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "$sdkPath" == /Library/Developer/CommandLineTools/* && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then sdkPath=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
plugin="$(xcrun --find swiftc)"
plugin="${plugin:h}/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=()
if [[ -f "$plugin" ]]; then args=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test --sdk "$sdkPath" --disable-sandbox --cache-path build/cache --config-path build/config --security-path build/security --scratch-path build/integration-tests "${args[@]}" "$@"
