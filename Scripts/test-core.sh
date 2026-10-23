#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
plugin="$(xcrun --find swiftc)"
plugin="${plugin:h}/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=()
if [[ -f "$plugin" ]]; then args=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test --package-path Packages/ZashDockCore --disable-sandbox --cache-path "$PWD/build/cache" --config-path "$PWD/build/config" --security-path "$PWD/build/security" --scratch-path "$PWD/build/core-tests" "${args[@]}" "$@"
