#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# SwiftPM cannot find the Testing framework on its own, so we point it there.
set -euo pipefail
source "$(dirname "$0")/env.sh"

# With an SDK pinned for the app, the toolchain stops finding the Testing framework's macro
# plugin on its own, so it is pointed at directly.
PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
PLUGIN_FLAGS=()
if [[ -n "${SDKROOT:-}" && -f "$PLUGIN" ]]; then
    PLUGIN_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
cd "$(dirname "$0")/.."

DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$DEV" == *CommandLineTools* ]]; then
    D="$DEV/Library/Developer"
    exec swift test \
        -Xswiftc -F -Xswiftc "$D/Frameworks" \
        -Xlinker -F -Xlinker "$D/Frameworks" \
        -Xlinker -rpath -Xlinker "$D/Frameworks" \
        -Xlinker -rpath -Xlinker "$D/usr/lib" \
        ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} "$@"
fi
exec swift test ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} "$@"
