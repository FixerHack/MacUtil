#!/usr/bin/env bash
# Builds a universal MacUtil.app, zips it and publishes a GitHub release,
# then points the Homebrew cask in FixerHack/homebrew-macutil at it.
#
#   scripts/release.sh           # build and zip only: build/MacUtil-<version>.zip
#   scripts/release.sh publish   # also create the GitHub release and update the cask
#
# Bump MacUtilInfo.version before publishing a new release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="FixerHack/MacUtil"
TAP="FixerHack/homebrew-macutil"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CleanerCore/MacUtilInfo.swift)"
ZIP="build/MacUtil-$VERSION.zip"

UNIVERSAL=1 scripts/build-app.sh release
codesign --verify --strict build/MacUtil.app
lipo -info build/MacUtil.app/Contents/MacOS/MacUtil

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/MacUtil.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$ZIP"
echo "sha256 $SHA"

[[ "${1:-}" == "publish" ]] || exit 0

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: commit your changes first" >&2
    exit 1
fi
git push origin HEAD
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "MacUtil $VERSION" --notes-file - <<NOTES
Install with Homebrew:

\`\`\`bash
brew install --cask fixerhack/macutil/macutil
\`\`\`

Or download **MacUtil-$VERSION.zip** below, unzip it and move MacUtil to Applications.
The app is not notarized by Apple, so the first launch needs one extra step:
see [First launch](https://github.com/$REPO#first-launch).

Requires macOS 14 Sonoma or later, Apple Silicon or Intel.

sha256: \`$SHA\`
NOTES

TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT
gh repo clone "$TAP" "$TAP_DIR" -- --quiet
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$TAP_DIR/Casks/macutil.rb"
git -C "$TAP_DIR" commit -qam "MacUtil $VERSION"
git -C "$TAP_DIR" push -q
echo "Released MacUtil $VERSION"
