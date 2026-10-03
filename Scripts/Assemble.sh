#!/bin/bash
# Builds Build/MacSpace.app from the Swift package: the app, its shared libraries and one bundle per module.
#
#   Scripts/Assemble.sh                      local build into Build/MacSpace.app; copy it to /Applications to run it. Signed with
#                                            the first Developer ID / Apple Development identity found (ad-hoc without one). A stable identity keeps Full Disk Access across rebuilds:
#                                            macOS ties the permission to the signature, and an ad-hoc signature changes every build.
#   SIGN_IDENTITY=- Scripts/Assemble.sh      force an ad-hoc signature
#   CONFIG=release VERSION=1.0.0 BUILD=42 SIGN_IDENTITY="Developer ID Application: …" Scripts/Assemble.sh
#   ICON=/path/to/MacSpace.icon Scripts/Assemble.sh   the app icon, an Icon Composer document (default: the design folder below;
#                                            without it, App/Resources/AppIcon.icns)
#   NOTARY_PROFILE=MacSpace Scripts/Assemble.sh   also notarize the app and staple the ticket, so it opens on any Mac (another Mac, a
#                                            VM). Needs a Developer ID identity and a notarytool profile in the keychain, made once with
#                                            xcrun notarytool store-credentials MacSpace --apple-id … --team-id … (app-specific password)
#
# Signing with a real identity enables the hardened runtime. The identity and any notarization credentials are
# supplied by the release pipeline; nothing secret lives in this repository.
set -euo pipefail
# A failed step leaves Build/MacSpace.app half made (unsigned, say): say so, so it is not copied and run.
trap 'echo "error: the build failed at line $LINENO; Build/MacSpace.app is incomplete, do not copy it" >&2' ERR
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
# A local build gets a build number of its own, 1.<year and day>.<time>: macOS keeps an app's icon by its identity and build
# number, and every build being "1" kept the icon it first cached (the generic one). It stays below any release build (2 and up).
BUILD=${BUILD:-1.$(date +%y%j).$((10#$(date +%H%M%S)))}
AUTO_IDENTITY=0
if [ -z "${SIGN_IDENTITY+x}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "((Developer ID Application|Apple Development):.*)"$/\1/p' | head -1 || true)
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
  [ "$SIGN_IDENTITY" = "-" ] || AUTO_IDENTITY=1
fi
# codesign is given the certificate's SHA-1 hash, not its name: with two certificates of the same name in the keychain (a renewed
# or re-imported Developer ID), signing by name failed as "ambiguous" at the first item, and the app was left half signed.
SIGN_KEY=$SIGN_IDENTITY
if [ "$SIGN_IDENTITY" != "-" ] && ! printf '%s' "$SIGN_IDENTITY" | grep -qE '^[0-9A-Fa-f]{40}$'; then
  HASH=$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="$SIGN_IDENTITY" '
    { line = $0; sub(/^ *[0-9]+\) /, "", line); hash = substr(line, 1, 40); rest = substr(line, 43); sub(/"$/, "", rest)
      if (rest == name) { print hash; exit } }' || true)
  [ -n "$HASH" ] && SIGN_KEY=$HASH
fi
# Public half of the Sparkle update key. Without it the built app never checks for updates.
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-}
# The team that signs the app; the helper accepts only clients signed by it. Not a secret (it is in every signed binary).
TEAM_ID=${TEAM_ID:-$(printf '%s' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')}
TEAM_ID=${TEAM_ID:-UNSIGNED}
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ] && ! xcode-select -p 2>/dev/null | grep -q Xcode; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# The app icon, made in Icon Composer. It lives with the design files, outside the repository.
ICON=${ICON:-"$HOME/Library/CloudStorage/OneDrive-Pessoal/Em andamento/DESIGN/MACSPACE/MacSpace.icon"}

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP=Build/MacSpace.app
rm -rf Build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Resources"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|" App/Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN/MacSpaceMain" "$APP/Contents/MacOS/MacSpace"
# The Icon Composer document is compiled by actool into the asset catalog (the icon macOS 26 and later draw, with its light, dark
# and tinted looks) and an .icns for older places; Info.plist names both. Without it, the old .icns.
if [ -d "$ICON" ]; then
  ICON_NAME=$(basename "$ICON" .icon)
  PARTIAL=$(mktemp -d)
  xcrun actool "$ICON" --compile "$APP/Contents/Resources" --app-icon "$ICON_NAME" --include-all-app-icons \
    --output-partial-info-plist "$PARTIAL/Info.plist" --platform macosx --target-device mac --minimum-deployment-target 27.0 \
    --enable-on-demand-resources NO --development-region en --errors --warnings --output-format human-readable-text
  # actool can finish without writing the icon (an Icon Composer document whose files OneDrive has not downloaded, say); then the
  # app would name an icon it does not carry and show the generic one. Fall back to the old .icns instead, and say so.
  if [ -f "$APP/Contents/Resources/Assets.car" ] && [ -f "$APP/Contents/Resources/$ICON_NAME.icns" ]; then
    plutil -replace CFBundleIconFile -string "$ICON_NAME" "$APP/Contents/Info.plist"
    plutil -replace CFBundleIconName -string "$ICON_NAME" "$APP/Contents/Info.plist"
    echo "App icon: $ICON"
  else
    cp App/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    echo "warning: actool wrote no icon from $ICON (is it downloaded from OneDrive?); using App/Resources/AppIcon.icns" >&2
    ls -la "$APP/Contents/Resources" >&2
  fi
  rm -rf "$PARTIAL"
else
  cp App/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "App icon: App/Resources/AppIcon.icns ($ICON not found)"
fi
cp "$BIN/MacSpaceCli" "$APP/Contents/MacOS/MacSpaceCli"
cp "$BIN/MacSpaceHelper" "$APP/Contents/MacOS/MacSpaceHelper"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
sed "s/__TEAM_ID__/$TEAM_ID/" Packaging/com.macspace.helper.plist > "$APP/Contents/Library/LaunchDaemons/com.macspace.helper.plist"
cp "$BIN/libMacSpaceSdk.dylib" "$BIN/libMacSpacePlatform.dylib" "$APP/Contents/Frameworks/"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"

# Drop the build machine's rpaths and point everything at the app's Frameworks folder.
reroot() { # file, new rpath
  otool -l "$1" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$1" 2>/dev/null || true
  done
  install_name_tool -add_rpath "$2" "$1"
}
reroot "$APP/Contents/MacOS/MacSpace" "@executable_path/../Frameworks"
reroot "$APP/Contents/MacOS/MacSpaceCli" "@executable_path/../Frameworks"
reroot "$APP/Contents/MacOS/MacSpaceHelper" "@executable_path/../Frameworks"
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
  # A local build needs no secure timestamp (that is a network call and only notarization requires it).
  if [ "$AUTO_IDENTITY" = 1 ] && [ -z "${NOTARY_PROFILE:-}" ]; then STAMP=--timestamp=none; else STAMP=--timestamp; fi
  FLAGS=(--force --options runtime "$STAMP" --sign "$SIGN_KEY")
fi
# Sparkle ships helpers that must be signed first, inside out, with the same identity (see Sparkle's documentation).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
  [ -e "$item" ] && codesign "${FLAGS[@]}" "$item"
done
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
for lib in "$APP"/Contents/Frameworks/*.dylib; do codesign "${FLAGS[@]}" "$lib"; done
for bundle in "${MODULES[@]}"; do codesign "${FLAGS[@]}" "$bundle"; done
codesign "${FLAGS[@]}" "$APP/Contents/MacOS/MacSpaceCli"
codesign "${FLAGS[@]}" --identifier com.macspace.helper "$APP/Contents/MacOS/MacSpaceHelper"
codesign "${FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP" || { echo "error: the signed app does not verify; do not copy Build/MacSpace.app" >&2; exit 1; }

# Notarization: Gatekeeper opens a Developer ID app copied from elsewhere only once Apple has notarized it. The ticket is stapled to
# the app, so it also opens offline.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  case "$SIGN_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "error: notarization needs a Developer ID Application identity (signed with $SIGN_IDENTITY)" >&2; exit 1 ;;
  esac
  ZIP=$(mktemp -d)/MacSpace.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarizing (this usually takes a few minutes)…"
  RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  STATUS=$(printf '%s' "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
  SUBMISSION=$(printf '%s' "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || echo "")
  rm -f "$ZIP"
  if [ "$STATUS" != "Accepted" ]; then
    echo "error: notarization $STATUS" >&2
    [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP"
fi
# The helper daemon can only be registered from an app that sits in an Applications folder: from Build/ macOS reports it as
# "not found". INSTALL=1 copies the build to /Applications, the one in Finder's sidebar (INSTALL_DIR chooses another), asking for
# an administrator password when the folder is not writable, and removes the copy earlier builds put in ~/Applications.
if [ "${INSTALL:-0}" = 1 ]; then
  INSTALL_DIR=${INSTALL_DIR:-/Applications}
  TARGET="$INSTALL_DIR/MacSpace.app"
  # A plain string, not an array: macOS's bash 3.2 treats an empty array as unbound under set -u.
  AS_ADMIN=""
  if [ ! -w "$INSTALL_DIR" ] || { [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; }; then
    echo "Installing into $INSTALL_DIR needs an administrator password."
    AS_ADMIN=sudo
  fi
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pkill -i -x MacSpace 2>/dev/null || true
  # One installed copy only: two copies with the same identifier left macOS free to pick either for the helper.
  for other in /Applications/MacSpace.app "$HOME/Applications/MacSpace.app"; do
    if [ "$other" != "$TARGET" ] && [ -d "$other" ]; then
      "$LSREGISTER" -u "$other" 2>/dev/null || true
      if rm -rf "$other" 2>/dev/null || sudo rm -rf "$other"; then echo "Removed the earlier copy at $other"; fi
    fi
  done
  $AS_ADMIN rm -rf "$TARGET"
  $AS_ADMIN ditto "$APP" "$TARGET"
  # Only the installed copy is known to Launch Services. The build's own copy, once seen (Finder registers any app it shows),
  # has the same identifier and version, and macOS could resolve the app to it when installing the helper: that copy is deleted and
  # rewritten by every build, and the helper failed with "Codesigning failure loading plist … -67056" (resources not found).
  # Registering the installed copy again also makes Finder and the Dock read its icon again.
  "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
  $AS_ADMIN touch "$TARGET"
  "$LSREGISTER" -f "$TARGET" 2>/dev/null || true
  echo "Installed $TARGET"
fi
# The build's own copy is not an app to run: macOS is told to forget it, so that the copy in Applications is the only one it
# knows. Two copies with the same identifier let macOS tie the helper to this one, which the next build replaces ("Codesigning
# failure loading plist … -67056"). Finder registers it again when it shows the folder; the helper refuses to install from it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
echo "Built $APP (version $VERSION, signed with ${SIGN_IDENTITY/#-/ad-hoc})"
[ "${INSTALL:-0}" = 1 ] || echo "Copy it to /Applications to run it (quit MacSpace first)."
