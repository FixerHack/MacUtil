#!/usr/bin/env bash
# Builds an optimized MacCleaner.app and installs it into /Applications.
# Permissions such as Full Disk Access belong to the app at that location,
# so always run the installed copy rather than build/MacCleaner.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build-app.sh" release

if pgrep -x MacCleaner >/dev/null; then
    osascript -e 'quit app "MacCleaner"' 2>/dev/null || pkill -x MacCleaner || true
    sleep 1
fi

ditto "$ROOT/build/MacCleaner.app" /Applications/MacCleaner.app
echo "Installed /Applications/MacCleaner.app"
open /Applications/MacCleaner.app
