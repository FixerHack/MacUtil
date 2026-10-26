#!/usr/bin/env bash
# Builds an optimized UniMacHub.app and installs it into /Applications.
# Permissions such as Full Disk Access belong to the app at that location,
# so always run the installed copy rather than build.noindex/UniMacHub.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build-app.sh" release

if pgrep -x UniMacHub >/dev/null; then
    osascript -e 'quit app "UniMacHub"' 2>/dev/null || pkill -x UniMacHub || true
    sleep 1
fi

ditto "$ROOT/build.noindex/UniMacHub.app" /Applications/UniMacHub.app
echo "Installed /Applications/UniMacHub.app"
open /Applications/UniMacHub.app
