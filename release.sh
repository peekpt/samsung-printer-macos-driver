#!/bin/bash
#
# Build everything and publish a GitHub release with the DMG (and zip).
#
#   bash release.sh            # build + create/refresh release v<version>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
           "$ROOT/dist/Samsung SpliX Installer.app/Contents/Info.plist" 2>/dev/null || echo 1.0)"
TAG="v$VERSION"
DMG="$ROOT/dist/SamsungSpliXInstaller-$VERSION.dmg"
ZIP="$ROOT/dist/Samsung SpliX Installer.zip"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

say "Building app + DMG"
bash "$ROOT/app/build.sh"

say "Checking git state"
cd "$ROOT"
if [ ! -d .git ]; then
  echo "Not a git repository. Run: git init && git add -A && git commit" >&2
  exit 1
fi
git push origin HEAD

say "Publishing release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$ZIP" --clobber
else
  gh release create "$TAG" "$DMG" "$ZIP" \
     --title "Samsung SpliX Installer $VERSION" \
     --notes "One-click macOS driver for old Samsung (SpliX/QPDL) laser printers. Universal (Apple Silicon + Intel). Fixes the \"unplug the USB cable to print again\" bug.

Download **SamsungSpliXInstaller-$VERSION.dmg**, open it, drag the app to Applications, then right-click → Open the first time (the app is not notarized)."
fi

say "Done: $(gh release view "$TAG" --json url -q .url)"
