#!/bin/bash
#
# Build "Samsung SpliX Installer.app".
#
#   - builds the universal splixreset helper
#   - (re)builds the universal SpliX filters if missing
#   - assembles the app bundle with the payload (filters, PPDs, backend,
#     scripts, licence + source)
#   - ad-hoc signs the bundle
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
APP_NAME="Samsung SpliX Installer"
EXE="SamsungSpliXInstaller"
BUNDLE_ID="org.splix.samsung-printer-installer"
VERSION="1.0"

RES="$APP_DIR/Resources"
VENDOR="$ROOT/vendor"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. splixreset (universal)
# ---------------------------------------------------------------------------
say "Building splixreset (arm64 + x86_64)"
mkdir -p "$RES/bin" "$ROOT/build"
for arch in arm64 x86_64; do
  clang -O2 -Wall -arch "$arch" -framework IOKit -framework CoreFoundation \
        -o "$ROOT/build/splixreset.$arch" "$ROOT/src/splixreset.c"
done
lipo -create "$ROOT/build/splixreset.arm64" "$ROOT/build/splixreset.x86_64" \
     -output "$RES/bin/splixreset"
rm -f "$ROOT/build/splixreset.arm64" "$ROOT/build/splixreset.x86_64"

# ---------------------------------------------------------------------------
# 2. SpliX filters (universal) - build only if not already present
# ---------------------------------------------------------------------------
if [ ! -x "$VENDOR/build/rastertoqpdl" ] || [ ! -x "$VENDOR/build/pstoqpdl" ]; then
  say "Building SpliX filters (arm64 + x86_64)"
  if ! ls /opt/homebrew/opt/cups/include/cups/cups.h >/dev/null 2>&1; then
    echo "ERROR: CUPS headers not found. Run: brew install cups" >&2
    exit 1
  fi
  export PATH="$VENDOR/tools:$PATH"
  mkdir -p "$VENDOR/build"
  for arch in arm64 x86_64; do
    ( cd "$VENDOR/splix"
      make clean >/dev/null 2>&1 || true
      make -j4 DISABLE_JBIG=1 CC="clang -arch $arch" CXX="clang++ -arch $arch" >/dev/null
    )
    cp "$VENDOR/splix/optimized/rastertoqpdl" "$VENDOR/build/rastertoqpdl.$arch"
    cp "$VENDOR/splix/optimized/pstoqpdl"     "$VENDOR/build/pstoqpdl.$arch"
  done
  lipo -create "$VENDOR/build/rastertoqpdl.arm64" "$VENDOR/build/rastertoqpdl.x86_64" -output "$VENDOR/build/rastertoqpdl"
  lipo -create "$VENDOR/build/pstoqpdl.arm64"     "$VENDOR/build/pstoqpdl.x86_64"     -output "$VENDOR/build/pstoqpdl"
  rm -f "$VENDOR"/build/*.arm64 "$VENDOR"/build/*.x86_64
fi
cp "$VENDOR/build/rastertoqpdl" "$VENDOR/build/pstoqpdl" "$RES/bin/"

# ---------------------------------------------------------------------------
# 3. PPDs + licences/source
# ---------------------------------------------------------------------------
say "Copying PPDs and licence"
mkdir -p "$RES/ppd" "$RES/licenses"
cp "$VENDOR/splix/ppd"/*.ppd "$RES/ppd/"
cp "$VENDOR/splix/COPYING" "$RES/licenses/COPYING.splix"
tar -C "$VENDOR" -czf "$RES/licenses/splix-source.tar.gz" splix

chmod +x "$RES/scripts"/*.sh "$RES/backend/splixusb" "$RES/bin/"*

# ---------------------------------------------------------------------------
# 4. Compile the GUI
# ---------------------------------------------------------------------------
say "Compiling the app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/$EXE" "$APP_DIR/src/main.swift" \
       -framework AppKit -framework Foundation

# ---------------------------------------------------------------------------
# 5. Payload + Info.plist
# ---------------------------------------------------------------------------
cp -R "$RES/"* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
	<key>CFBundleExecutable</key>      <string>$EXE</string>
	<key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key> <string>$VERSION</string>
	<key>CFBundleVersion</key>         <string>$VERSION</string>
	<key>CFBundleDevelopmentRegion</key> <string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>pt</string>
	</array>
	<key>LSMinimumSystemVersion</key>  <string>11.0</string>
	<key>NSHighResolutionCapable</key> <true/>
	<key>NSPrincipalClass</key>        <string>NSApplication</string>
	<key>CFBundleIconFile</key>        <string>AppIcon</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# 6. Icon (optional)
# ---------------------------------------------------------------------------
if [ -f "$APP_DIR/icon/make-icon.sh" ] && command -v iconutil >/dev/null 2>&1; then
  say "Building icon"
  bash "$APP_DIR/icon/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" || true
fi

# ---------------------------------------------------------------------------
# 7. Sign (ad-hoc) + zip
# ---------------------------------------------------------------------------
say "Signing (ad-hoc)"
codesign --force --deep -s - "$APP" 2>/dev/null || true

say "Packaging"
( cd "$DIST" && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP" "$APP_NAME.zip" )

# ---------------------------------------------------------------------------
# 8. Styled DMG
# ---------------------------------------------------------------------------
say "Building DMG"
DMG="$DIST/SamsungSpliXInstaller-$VERSION.dmg"
BG="$DIST/dmg-bg.png"
STAGE="$DIST/dmg-stage"

swiftc -O -o "$DIST/draw-bg" "$APP_DIR/icon/draw-dmg-bg.swift" -framework AppKit
"$DIST/draw-bg" "$BG"
rm -f "$DIST/draw-bg"

rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
rm -f "$DMG"

make_plain_dmg() {
  ln -sf /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
}

if /usr/bin/python3 -c "import dmgbuild" >/dev/null 2>&1; then
  # dmgbuild writes the .DS_Store itself -> no Finder/Automation permission needed
  rm -f "$DMG"
  /usr/bin/python3 -m dmgbuild -s "$APP_DIR/icon/dmg-settings.py" \
      -D app="$APP" -D background="$BG" "$APP_NAME" "$DMG" >/dev/null
elif command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --background "$BG" \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 140 190 \
    --app-drop-link 400 190 \
    "$DMG" "$STAGE" || make_plain_dmg
else
  make_plain_dmg
fi
rm -rf "$STAGE" "$BG"
rm -f "$DIST"/rw.*.dmg

say "Done: $APP"
ls -la "$DIST"/*.dmg "$DIST"/*.zip 2>/dev/null
du -sh "$APP"
