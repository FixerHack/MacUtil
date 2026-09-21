#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# SwiftPM cannot find the Testing framework on its own, so we point it there.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
    D="$DEV/Library/Developer"
    exec swift test \
        -Xswiftc -F -Xswiftc "$D/Frameworks" \
        -Xlinker -F -Xlinker "$D/Frameworks" \
        -Xlinker -rpath -Xlinker "$D/Frameworks" \
        -Xlinker -rpath -Xlinker "$D/usr/lib" "$@"
fi
exec swift test "$@"
