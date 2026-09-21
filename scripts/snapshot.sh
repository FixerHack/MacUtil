#!/usr/bin/env bash
# Saves a PNG of the app window for visual checks (debug builds only).
#   scripts/snapshot.sh out.png [module] [language]
#   scripts/snapshot.sh /tmp/lens.png spaceLens uk
#
# Uses `screencapture -l` when the calling app has Screen Recording permission,
# otherwise asks the app to draw its own window (Liquid Glass areas come out blank).
set -euo pipefail
OUT="$1"; MODULE="${2:-dashboard}"; LANGUAGE="${3:-en}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacCleaner.app/Contents/MacOS/MacCleaner"
DELAY="${SNAPSHOT_DELAY:-2}"
rm -f "$OUT"

pkill -x MacCleaner 2>/dev/null || true
MACCLEANER_SNAPSHOT_MODULE="$MODULE" "$APP" -AppleLanguages "($LANGUAGE)" >/dev/null 2>&1 &
PID=$!
sleep "$DELAY"
WINDOW="$(swift "$ROOT/scripts/window-id.swift" 2>/dev/null || true)"
if [[ -n "$WINDOW" ]] && screencapture -x -o -l "$WINDOW" "$OUT" 2>/dev/null; then
    kill $PID 2>/dev/null || true
    echo "saved $OUT (screencapture)"
    exit 0
fi
kill $PID 2>/dev/null || true
sleep 0.5

MACCLEANER_SNAPSHOT="$OUT" MACCLEANER_SNAPSHOT_MODULE="$MODULE" MACCLEANER_SNAPSHOT_QUIT=1 \
MACCLEANER_SNAPSHOT_DELAY="$DELAY" "$APP" -AppleLanguages "($LANGUAGE)" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
kill $PID 2>/dev/null || true
[[ -f "$OUT" ]] && echo "saved $OUT (in-app render, glass areas blank)" || { echo "no snapshot"; exit 1; }
