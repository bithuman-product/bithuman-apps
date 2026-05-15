#!/usr/bin/env bash
# Build, sign, notarise, staple, and DMG-wrap bitHuman.app for macOS.
#
# This is the .app analogue of release.sh (which ships the bare CLI).
# The two pipelines share the same signing identity + notary profile;
# only the artefact layout differs.
#
#   Output: dist/bitHuman-<version>.dmg
#
# Prerequisites:
#
#   1. A "Developer ID Application" identity in your login keychain.
#      Pass the full identity string via $SIGNING_IDENTITY, e.g.
#        export SIGNING_IDENTITY="Developer ID Application: Your Org (ABCDE12345)"
#      If not set, the script falls back to a generic "Developer ID
#      Application" lookup (works only if there's exactly one such cert
#      in your keychain). See the repo root README → "Set your Apple
#      signing team" for finding your team ID.
#   2. notarytool credentials stored under profile name $NOTARY_PROFILE
#      (default: `bithuman-notary`). Create with:
#        xcrun notarytool store-credentials bithuman-notary \
#            --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-pw>
#   3. (For Sparkle release builds) export SU_FEED_URL and
#      SU_PUBLIC_ED_KEY before running, e.g.
#        export SU_FEED_URL="https://updates.bithuman.ai/mac/appcast.xml"
#        export SU_PUBLIC_ED_KEY="$(cat ~/.bithuman-sparkle/public.pem)"
#      If you skip these, the placeholder __SU_*__ tokens stay in the
#      built Info.plist and the auto-updater will be inert (safe — the
#      app still launches and runs locally, it just won't self-update).
#   4. (Optional) `create-dmg` from Homebrew:  brew install create-dmg
#      Falls back to `hdiutil` if create-dmg isn't installed.
#
# Phase B status: Sparkle SPM dependency is NOT yet wired in
# Package.swift — see ../PACKAGE_INTEGRATION.md. Until that lands, the
# built .app has no embedded `Sparkle.framework` and the appcast
# values in Info.plist are inert. The .app still ships fine for manual
# DMG-based distribution; auto-updates kick in once Sparkle is added.

set -euo pipefail

# Resolve paths relative to *this script*, not the caller's $PWD.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"           # .../Apps/BithumanMac
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"   # .../swift-voice-chat
cd "$REPO_ROOT"

VERSION="${1:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-bithuman-notary}"
SCHEME="${SCHEME:-BithumanMac}"
APP_NAME="bitHuman"
BUNDLE_ID="ai.bithuman.app.mac"

SU_FEED_URL="${SU_FEED_URL:-__SU_FEED_URL__}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-__SU_PUBLIC_ED_KEY__}"

DIST="$REPO_ROOT/dist"
STAGE="$DIST/mac-staging-$VERSION"
APP_BUNDLE="$STAGE/${APP_NAME}.app"
DMG_OUT="$DIST/${APP_NAME}-${VERSION}.dmg"

mkdir -p "$DIST"
rm -rf "$STAGE" "$DMG_OUT"
mkdir -p "$STAGE"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "🧹 Cleaning DerivedData (avoids stale resource bundles from a"
echo "   previously-named target leaking into the .app)."
# -skipMacroValidation matches the build invocation below — without it,
# MLXHuggingFaceMacros trips xcodebuild's macro-trust prompt and fails
# unattended (CI / script context).
xcodebuild clean \
  -scheme "$SCHEME" \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  -skipMacroValidation \
  > /tmp/bithuman-mac.clean.log 2>&1 || {
    echo "warn: xcodebuild clean failed; continuing — stale artefacts" >&2
    echo "      may surface, but the build will still produce a fresh .app." >&2
    tail -5 /tmp/bithuman-mac.clean.log >&2
}

echo "🔨 Release build — $SCHEME"
xcodebuild \
  -scheme "$SCHEME" \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  -skipMacroValidation \
  build > /tmp/bithuman-mac.build.log 2>&1
tail -5 /tmp/bithuman-mac.build.log

# Locate the built executable + its sibling resource bundles. xcodebuild
# stamps the DerivedData folder with the *enclosing project name*
# (bithuman-kit, since this is an SPM root). Glob both that and the
# raw directory name for resilience.
shopt -s nullglob
project_dirname="$(basename "$REPO_ROOT")"
candidates=(
  "$HOME"/Library/Developer/Xcode/DerivedData/"${project_dirname}"-*/Build/Products/Release/"$SCHEME"
  "$HOME"/Library/Developer/Xcode/DerivedData/bithuman-kit-*/Build/Products/Release/"$SCHEME"
)
shopt -u nullglob

BIN=""
for c in "${candidates[@]}"; do
  if [[ -x "$c" ]]; then
    BIN="$c"; break
  fi
done
if [[ -z "$BIN" ]]; then
  echo "error: couldn't locate built BithumanMac binary under DerivedData" >&2
  exit 1
fi
PRODUCTS_DIR="$(dirname "$BIN")"
echo "binary: $BIN"
echo "products: $PRODUCTS_DIR"

# ---------------------------------------------------------------------
# Build the .app bundle structure
# ---------------------------------------------------------------------
#   bitHuman.app/
#     Contents/
#       Info.plist
#       MacOS/BithumanMac
#       Resources/AppIcon.icns
#       Resources/*.bundle      ← every MLX/SPM resource bundle
#       _CodeSignature/         ← populated by codesign
# ---------------------------------------------------------------------
echo "📦 Assembling $APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Executable.
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/BithumanMac"
chmod +x "$APP_BUNDLE/Contents/MacOS/BithumanMac"

# Resource bundles MLX needs (same set release.sh ships next to the CLI).
# Inside a .app these go in Contents/Resources/ — Bundle.module +
# Bundle.allBundles look there before falling back to the executable
# directory, so MLX's metallib lookup keeps working.
find "$PRODUCTS_DIR" -maxdepth 1 -name "*.bundle" \
  -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# App icon. Convert the brand AppIcon.png → .icns. iconutil wants a
# specific iconset layout; we synthesise one quickly via sips.
ICON_SRC="$REPO_ROOT/Sources/bitHumanKit/Resources/Brand/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$STAGE/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z "$sz" "$sz"     "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"   >/dev/null
    dbl=$(( sz * 2 ))
    sips -z "$dbl" "$dbl"   "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "warn: $ICON_SRC missing — skipping app icon" >&2
fi

# Info.plist — substitute __VERSION__ / __BUILD__ / Sparkle tokens.
PLIST_SRC="$APP_DIR/Resources/Info.plist"
PLIST_DST="$APP_BUNDLE/Contents/Info.plist"
sed \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__BUILD__|$BUILD_NUMBER|g" \
  -e "s|__SU_FEED_URL__|$SU_FEED_URL|g" \
  -e "s|__SU_PUBLIC_ED_KEY__|$SU_PUBLIC_ED_KEY|g" \
  "$PLIST_SRC" > "$PLIST_DST"

# ---------------------------------------------------------------------
# Code-sign — inside-out, then the .app, with hardened runtime + the
# entitlements that grant mic + MLX JIT.
# ---------------------------------------------------------------------
echo "🔏 Signing nested bundles + .app with $IDENTITY"
ENTITLEMENTS="$APP_DIR/Resources/BithumanMac.entitlements"

# Sign every nested .bundle first (codesign requires inside-out order).
find "$APP_BUNDLE/Contents/Resources" -name "*.bundle" -print0 |
  while IFS= read -r -d '' bundle; do
    codesign -f -s "$IDENTITY" --options runtime --timestamp --deep "$bundle" >/dev/null
  done

# Sign the main executable (with entitlements).
codesign -f -s "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE/Contents/MacOS/BithumanMac" >/dev/null

# Finally, sign the .app wrapper itself.
codesign -f -s "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE" >/dev/null

# Sanity: verify the signature graph is well-formed before we waste
# a notarisation submission on a mis-signed bundle.
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || {
  echo "warn: spctl assessment failed (expected pre-notarisation)" >&2
}

# ---------------------------------------------------------------------
# Notarise. We zip the .app for upload (notarytool accepts .zip/.dmg),
# then staple the ticket to the .app inside the staging dir.
# ---------------------------------------------------------------------
NOTARY_ZIP="$STAGE/${APP_NAME}-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"

echo "🚀 Submitting to Apple notarisation (this can take a few minutes)"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$NOTARY_ZIP"

echo "📎 Stapling notarisation ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# ---------------------------------------------------------------------
# Wrap into a DMG. create-dmg gives us a polished installer-style DMG
# (drag-to-Applications shortcut). hdiutil is the no-deps fallback.
# ---------------------------------------------------------------------
echo "💿 Building DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    --window-size 540 360 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 140 180 \
    --app-drop-link 400 180 \
    --hdiutil-quiet \
    "$DMG_OUT" \
    "$APP_BUNDLE" >/dev/null
else
  echo "  (create-dmg not installed; falling back to hdiutil. brew install create-dmg for the prettier DMG.)"
  TMP_DMG_DIR="$STAGE/dmg-src"
  rm -rf "$TMP_DMG_DIR"; mkdir -p "$TMP_DMG_DIR"
  cp -R "$APP_BUNDLE" "$TMP_DMG_DIR/"
  ln -s /Applications "$TMP_DMG_DIR/Applications"
  hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$TMP_DMG_DIR" \
    -ov -format UDZO \
    "$DMG_OUT" >/dev/null
fi

# Sign + notarise the DMG itself so Gatekeeper accepts the download
# without quarantine prompts. (The .app inside is already stapled.)
echo "🔏 Signing DMG"
codesign -f -s "$IDENTITY" --timestamp "$DMG_OUT" >/dev/null

echo "🚀 Notarising DMG"
xcrun notarytool submit "$DMG_OUT" --keychain-profile "$PROFILE" --wait

echo "📎 Stapling DMG"
xcrun stapler staple "$DMG_OUT"
xcrun stapler validate "$DMG_OUT"

echo
echo "✅ done"
echo "   .app : $APP_BUNDLE"
echo "   .dmg : $DMG_OUT  ($(du -sh "$DMG_OUT" | awk '{print $1}'))"
echo "   sha256: $(shasum -a 256 "$DMG_OUT" | awk '{print $1}')"
echo
echo "Smoke-test on a fresh Mac:"
echo "    hdiutil attach \"$DMG_OUT\" && open \"/Volumes/${APP_NAME} ${VERSION}/${APP_NAME}.app\""
