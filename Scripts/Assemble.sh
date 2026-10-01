#!/bin/bash
# Builds Build/MACSPACE.app from the Swift package: the app, its shared libraries and one bundle per module.
#
#   Scripts/Assemble.sh                      debug-friendly build, ad-hoc signed (runs on this Mac only)
#   CONFIG=release VERSION=1.0.0 BUILD=42 SIGN_IDENTITY="Developer ID Application: …" Scripts/Assemble.sh
#
# Signing with a real identity enables the hardened runtime. The identity and any notarization credentials are
# supplied by the release pipeline; nothing secret lives in this repository.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-1}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ] && ! xcode-select -p 2>/dev/null | grep -q Xcode; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP=Build/MACSPACE.app
rm -rf Build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Resources"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN/MacSpaceMain" "$APP/Contents/MacOS/MACSPACE"
cp "$BIN/MacSpaceCli" "$APP/Contents/MacOS/MacSpaceCli"
cp "$BIN/libMacSpaceSdk.dylib" "$BIN/libMacSpacePlatform.dylib" "$APP/Contents/Frameworks/"

# Drop the build machine's rpaths and point everything at the app's Frameworks folder.
reroot() { # file, new rpath
  otool -l "$1" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null || true
  done
  install_name_tool -add_rpath "$2" "$1"
}
reroot "$APP/Contents/MacOS/MACSPACE" "@executable_path/../Frameworks"
reroot "$APP/Contents/MacOS/MacSpaceCli" "@executable_path/../Frameworks"
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
  reroot "$lib" "@loader_path"
done

MODULES=()
for dir in Modules/*/; do
  name=$(basename "$dir")
  bundle="$APP/Contents/PlugIns/$name.macspacemodule"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$BIN/lib$name.dylib" "$bundle/Contents/MacOS/$name"
  install_name_tool -id "@rpath/$name" "$bundle/Contents/MacOS/$name"
  reroot "$bundle/Contents/MacOS/$name" "@loader_path/../../../../Frameworks"
  cp "$dir/Bundle/Info.plist" "$bundle/Contents/Info.plist"
  cp "$dir/Bundle/Manifest.json" "$bundle/Contents/Resources/Manifest.json"
  MODULES+=("$bundle")
done

# Sign inside out. A real identity gets the hardened runtime and a secure timestamp, as notarization requires.
if [ "$SIGN_IDENTITY" = "-" ]; then
  FLAGS=(--force --sign -)
else
  FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
for lib in "$APP"/Contents/Frameworks/*.dylib; do codesign "${FLAGS[@]}" "$lib"; done
for bundle in "${MODULES[@]}"; do codesign "${FLAGS[@]}" "$bundle"; done
codesign "${FLAGS[@]}" "$APP/Contents/MacOS/MacSpaceCli"
codesign "${FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (version $VERSION, signed with ${SIGN_IDENTITY/#-/ad-hoc})"
