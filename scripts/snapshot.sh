#!/usr/bin/env bash
# Saves a PNG of the app window for visual checks (debug builds only).
#   scripts/snapshot.sh out.png [module] [language]
#   SNAPSHOT_SCAN=~/Downloads SNAPSHOT_DELAY=5 scripts/snapshot.sh /tmp/lens.png spaceLens
#   SNAPSHOT_SCAN=junk|security ... scans before the snapshot (read-only)
#
# Uses `screencapture -l` when the calling app has Screen Recording permission,
# otherwise asks the app to draw its own window (Liquid Glass areas come out blank).
set -euo pipefail
OUT="$1"; MODULE="${2:-dashboard}"; LANGUAGE="${3:-en}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(ls -d "$ROOT"/build/*.app | head -1)"
BINARY="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info.plist" CFBundleExecutable)"
DELAY="${SNAPSHOT_DELAY:-2}"
ID_FILE="$(mktemp)"
trap 'rm -f "$ID_FILE"' EXIT
rm -f "$OUT"
if [[ -n "${SNAPSHOT_SCAN:-}" ]]; then export MACUTIL_SNAPSHOT_SCAN="$SNAPSHOT_SCAN"; fi
NAME="$(basename "$BINARY")"

pkill -f "$BINARY" 2>/dev/null || true
MACUTIL_SNAPSHOT_MODULE="$MODULE" MACUTIL_WINDOW_ID_FILE="$ID_FILE" \
    "$BINARY" -AppleLanguages "($LANGUAGE)" >/dev/null 2>&1 &
PID=$!
sleep "$DELAY"
WINDOW="$(cat "$ID_FILE" 2>/dev/null || true)"
if [[ -n "$WINDOW" && "$WINDOW" != 0 ]] && screencapture -x -o -l "$WINDOW" "$OUT" 2>/dev/null; then
    kill $PID 2>/dev/null || true
    wait $PID 2>/dev/null || true
    echo "saved $OUT (screencapture)"
    exit 0
fi
kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true

MACUTIL_SNAPSHOT="$OUT" MACUTIL_SNAPSHOT_MODULE="$MODULE" MACUTIL_SNAPSHOT_QUIT=1 \
MACUTIL_SNAPSHOT_DELAY="$DELAY" "$BINARY" -AppleLanguages "($LANGUAGE)" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
kill $PID 2>/dev/null || true
[[ -f "$OUT" ]] && echo "saved $OUT (in-app render, glass areas blank)" || { echo "no snapshot"; exit 1; }
