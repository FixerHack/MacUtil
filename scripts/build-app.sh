#!/usr/bin/env bash
# Builds build.noindex/MacUtil.app from the Swift package.
#
#   scripts/build-app.sh            # debug build → build.noindex/MacUtil.app
#   scripts/build-app.sh release    # optimized build
#   UNIVERSAL=1 scripts/build-app.sh release   # Apple Silicon + Intel
#
# Signing: uses $MACUTIL_SIGN_IDENTITY, else the first "Apple Development"
# certificate in the keychain, else ad-hoc. With ad-hoc signing macOS forgets
# Full Disk Access after every rebuild, because the signature changes.
set -euo pipefail
source "$(dirname "$0")/env.sh"

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CleanerCore/MacUtilInfo.swift)"
BUNDLE_ID="$(sed -n 's/.*bundleIdentifier = "\(.*\)".*/\1/p' Sources/CleanerCore/MacUtilInfo.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# A build for both architectures in one pass needs Xcode's own build tool, so each one is
# built on its own and the two are joined afterwards. That way the Command Line Tools are enough.
ARCHS=(arm64)
if [[ -n "${UNIVERSAL:-}" ]]; then ARCHS=(arm64 x86_64); fi

BIN_DIRS=()
for arch in "${ARCHS[@]}"; do
    swift build -c "$CONFIG" --product MacUtil --arch "$arch"
    swift build -c "$CONFIG" --product mucli --arch "$arch"
    BIN_DIRS+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)")
done
BIN_DIR="${BIN_DIRS[0]}"

APP="$ROOT/build.noindex/MacUtil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if (( ${#BIN_DIRS[@]} > 1 )); then
    lipo -create "${BIN_DIRS[@]/%//MacUtil}" -output "$APP/Contents/MacOS/MacUtil"
    lipo -create "${BIN_DIRS[@]/%//mucli}" -output "$APP/Contents/Resources/mucli"
else
    cp "$BIN_DIR/MacUtil" "$APP/Contents/MacOS/MacUtil"
    cp "$BIN_DIR/mucli" "$APP/Contents/Resources/mucli"
fi
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

IDENTITY="${MACUTIL_SIGN_IDENTITY:-}"
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
