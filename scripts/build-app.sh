#!/usr/bin/env bash
# Builds build.noindex/UniMacHub.app from the Swift package.
#
#   scripts/build-app.sh            # debug build → build.noindex/UniMacHub.app
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

ARCH_FLAGS=(--arch arm64)
if [[ -n "${UNIVERSAL:-}" ]]; then
    # The Command Line Tools ship the Swift compatibility libraries for Apple Silicon only, so
    # the Intel half cannot be linked without Xcode. Say so plainly instead of failing at link time.
    if [[ -z "${DEVELOPER_DIR:-}" || "$DEVELOPER_DIR" != *Xcode* ]]; then
        echo "error: building for Intel needs Xcode; the Command Line Tools carry Apple Silicon libraries only" >&2
        echo "       install Xcode, or build for this Mac only by leaving UNIVERSAL unset" >&2
        exit 1
    fi
    # Both architectures in one pass: the build puts them in the same place, so building them
    # one after the other would leave only the one built last.
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" --product MacUtil "${ARCH_FLAGS[@]}"
swift build -c "$CONFIG" --product mucli "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$ROOT/build.noindex/UniMacHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacUtil" "$APP/Contents/MacOS/UniMacHub"
cp "$BIN_DIR/mucli" "$APP/Contents/Resources/mucli"
if [[ -n "${UNIVERSAL:-}" ]]; then
    # A silent half-build would ship a release that will not open on half the Macs.
    for binary in "$APP/Contents/MacOS/UniMacHub" "$APP/Contents/Resources/mucli"; do
        archs="$(lipo -archs "$binary")"
        for want in arm64 x86_64; do
            [[ "$archs" == *"$want"* ]] || { echo "error: $binary has no $want ($archs)" >&2; exit 1; }
        done
    done
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
