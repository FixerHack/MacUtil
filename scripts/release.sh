#!/usr/bin/env bash
# Builds a universal MacUtil.app, packs it as a DMG and a zip, publishes a GitHub
# release and points the Homebrew cask in FixerHack/homebrew-macutil at the DMG.
#
#   scripts/release.sh           # build only: build/MacUtil-<version>.dmg and .zip
#   scripts/release.sh publish   # also create the GitHub release and update the cask
#
# Bump MacUtilInfo.version before publishing a new release. The DMG window is laid out by
# scripts/dmg-settings.py; its background comes from scripts/make-dmg-background.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="FixerHack/MacUtil"
TAP="FixerHack/homebrew-macutil"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CleanerCore/MacUtilInfo.swift)"
APP="build/MacUtil.app"
ZIP="build/MacUtil-$VERSION.zip"
DMG="build/MacUtil-$VERSION.dmg"

UNIVERSAL=1 scripts/build-app.sh release
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/MacUtil"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# dmgbuild lays out the Finder window without scripting Finder.
VENV=".build/dmg-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet dmgbuild
fi
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D root="$ROOT" MacUtil "$DMG" 2>&1 \
    | grep -v "is deprecated" || true
if [[ -n "$IDENTITY" ]]; then codesign --sign "$IDENTITY" --timestamp=none "$DMG"; fi
hdiutil verify -quiet "$DMG"
# The copy people drag out of the DMG must still pass a strict signature check.
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -quiet "$DMG" -mountpoint "$MOUNT"
codesign --verify --strict --deep "$MOUNT/MacUtil.app" || { hdiutil detach -quiet "$MOUNT"; exit 1; }
hdiutil detach -quiet "$MOUNT"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$DMG  sha256 $SHA"
echo "$ZIP  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

[[ "${1:-}" == "publish" ]] || exit 0

# GitHub's CDN keeps serving a replaced asset under the same name for a while, and the
# cask checksum would then fail. Every published build gets a new version instead.
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: v$VERSION is already released; bump MacUtilInfo.version" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: commit your changes first" >&2
    exit 1
fi
git push origin HEAD

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<NOTES
> [!IMPORTANT]
> **First launch / Перший запуск.** MacUtil is not notarized by Apple, so macOS blocks it the first time.
> Open MacUtil once, then go to **System Settings → Privacy & Security → Open Anyway**.
>
> MacUtil не нотаризований Apple, тому macOS блокує перший запуск. Відкрийте MacUtil один раз, потім
> **Системні параметри → Приватність і безпека → Все одно відкрити**.
>
> [Step-by-step guide](https://github.com/$REPO#first-launch) · [Покрокова інструкція](https://github.com/$REPO/blob/main/README.uk.md#перший-запуск)

### Install / Встановлення

**DMG:** download **MacUtil-$VERSION.dmg** below, open it and drag MacUtil to Applications.
Завантажте **MacUtil-$VERSION.dmg** нижче, відкрийте його й перетягніть MacUtil у Програми.

**Homebrew:**

\`\`\`bash
brew tap fixerhack/macutil
brew install macutil
\`\`\`

macOS 14 Sonoma or later · Apple Silicon and Intel

| File | sha256 |
|---|---|
| MacUtil-$VERSION.dmg | \`$SHA\` |
| MacUtil-$VERSION.zip | \`$(shasum -a 256 "$ZIP" | cut -d' ' -f1)\` |
NOTES

gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "MacUtil $VERSION" --notes-file "$NOTES"

TAP_DIR="$(mktemp -d)"
trap 'rm -f "$NOTES"; rm -rf "$TAP_DIR"' EXIT
gh repo clone "$TAP" "$TAP_DIR" -- --quiet
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$TAP_DIR/Casks/macutil.rb"
if ! git -C "$TAP_DIR" diff --quiet; then
    git -C "$TAP_DIR" commit -qam "MacUtil $VERSION"
    git -C "$TAP_DIR" push -q
fi
echo "Released MacUtil $VERSION"
