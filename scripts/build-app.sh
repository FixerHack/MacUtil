#!/usr/bin/env bash
# Builds build/MacCleaner.app from the Swift package.
#
#   scripts/build-app.sh            # debug build
#   scripts/build-app.sh release    # optimized build
#
# Signing: uses $MACCLEANER_SIGN_IDENTITY, else the first "Apple Development"
# certificate in the keychain, else ad-hoc. With ad-hoc signing macOS forgets
# Full Disk Access after every rebuild, because the signature changes.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CleanerCore/MacCleanerInfo.swift)"
BUNDLE_ID="$(sed -n 's/.*bundleIdentifier = "\(.*\)".*/\1/p' Sources/CleanerCore/MacCleanerInfo.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --product MacCleaner
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/MacCleaner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacCleaner" "$APP/Contents/MacOS/MacCleaner"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

IDENTITY="${MACCLEANER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "note: no signing certificate found, signing ad-hoc (Full Disk Access resets on each rebuild)"
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"

echo "Built $APP ($VERSION build $BUILD_NUMBER, signed: $IDENTITY)"
