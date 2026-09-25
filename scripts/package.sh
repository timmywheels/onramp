#!/usr/bin/env bash
# Builds Onramp.dmg: a universal (Apple Silicon + Intel) app, signed with
# your Developer ID, notarized by Apple and stapled.
#   ./scripts/package.sh                 # full release
#   ./scripts/package.sh --no-notarize   # signed, not notarized (quick local check)
# Needs: the Developer ID certificate in your keychain, and a notarytool
# profile: xcrun notarytool store-credentials pairprogram --apple-id … --team-id …
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${IDENTITY:-Developer ID Application: Timothy Wheeler (S3RY6Q3EW2)}"
PROFILE="${NOTARY_PROFILE:-pairprogram}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
NOTARIZE=1; [ "${1:-}" = "--no-notarize" ] && NOTARIZE=0
DIST="$ROOT/dist"
APP="$DIST/Onramp.app"
DMG="$DIST/Onramp-$VERSION.dmg"
step() { printf '\n==> %s\n' "$1"; }

step "Build (universal)"
"$ROOT/scripts/build-core.sh"
(cd "$ROOT/app" && swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|warning: .*(deprecated|unused)|Build complete" || true)
BIN="$ROOT/app/.build/apple/Products/Release"
lipo -info "$BIN/pairprogram"

step "Assemble Onramp.app"
rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/pairprogram" "$APP/Contents/MacOS/Onramp"
RES="$BIN/pairprogram_pairprogram.bundle"
[ -d "$RES/Contents/Resources" ] && RES="$RES/Contents/Resources"            # universal builds nest it
cp -R "$RES/." "$APP/Contents/Resources/"                                     # fonts, themes, languages, icon
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && [ -d "$APP/Contents/Resources/Extensions" ] || { echo "resources missing"; exit 1; }
cp -R "$ROOT/integrations" "$APP/Contents/Resources/integrations"           # the Claude Code plugin
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Onramp</string>
  <key>CFBundleDisplayName</key><string>Onramp</string>
  <key>CFBundleIdentifier</key><string>com.timwheeler.pairprogram</string>
  <key>CFBundleExecutable</key><string>Onramp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Tim Wheeler</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.timwheeler.pairprogram</string>
    <key>CFBundleURLSchemes</key><array><string>onramp</string><string>pairprogram</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict></array>
</dict>
</plist>
PLIST

step "Sign"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# The app itself is notarized and stapled too: the in-app updater downloads
# Onramp.zip and checks it with Gatekeeper before installing.
ZIP="$DIST/Onramp.zip"
if [ "$NOTARIZE" = 1 ]; then
  step "Notarize the app (Apple, usually 1-5 minutes)"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$DIST/notarize.zip"
fi
# LEGACY_ZIP=1: name the app PairProgram.app inside the zip, for updaters from
# before the rename (0.2.0 looks for that name; the app renames itself on launch).
if [ "${LEGACY_ZIP:-0}" = 1 ]; then
  mkdir -p "$DIST/legacy" && cp -R "$APP" "$DIST/legacy/PairProgram.app"
  ditto -c -k --keepParent "$DIST/legacy/PairProgram.app" "$ZIP" && rm -rf "$DIST/legacy"
else
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

step "Make the DMG"
STAGE="$DIST/dmg"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swiftc -O "$ROOT/scripts/dmg-background.swift" -o "$DIST/dmg-background" 2>/dev/null
"$DIST/dmg-background" "$STAGE/.background/background.png"
RW="$DIST/rw.dmg"
hdiutil create -quiet -volname "Onramp" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
# Finder layout: icon view, background, app on the left, Applications on the right.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "Onramp"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:background.png"
    set position of item "Onramp.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then echo "note: couldn't lay out the DMG window (Finder automation not allowed); it still works"; fi
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  step "Notarize the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  step "Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
rm -rf "$STAGE" "$DIST/dmg-background"
step "Done: $DMG ($(du -h "$DMG" | cut -f1)) and $ZIP ($(du -h "$ZIP" | cut -f1), for the updater)"
