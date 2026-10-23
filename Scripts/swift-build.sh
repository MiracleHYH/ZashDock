#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
sdkPath="$(xcrun --sdk macosx --show-sdk-path)"
# CLT 6.4 lacks SwiftUIMacros shipped with the 27 SDK. Prefer the installed 26 SDK for this target.
if [[ "$sdkPath" == /Library/Developer/CommandLineTools/* && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdkPath=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --sdk "$sdkPath" --disable-sandbox --cache-path build/cache --config-path build/config --security-path build/security --scratch-path build/swift26 -Xswiftc -target -Xswiftc arm64-apple-macosx26.0 "$@"
