#!/usr/bin/env bash
# Builds an optimized MacUtil.app and installs it into /Applications.
# Permissions such as Full Disk Access belong to the app at that location,
# so always run the installed copy rather than build/MacUtil.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build-app.sh" release

if pgrep -x MacUtil >/dev/null; then
    osascript -e 'quit app "MacUtil"' 2>/dev/null || pkill -x MacUtil || true
    sleep 1
fi

ditto "$ROOT/build/MacUtil.app" /Applications/MacUtil.app
echo "Installed /Applications/MacUtil.app"
open /Applications/MacUtil.app
