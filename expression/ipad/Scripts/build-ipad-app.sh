#!/bin/bash
# build-ipad-app.sh — archive + (optionally) upload BithumanPad to
# TestFlight.
#
# Usage:
#   Apps/BithumanPad/Scripts/build-ipad-app.sh <version>
#
#   <version>  CFBundleShortVersionString to stamp into the build,
#              e.g. 0.1.0. The CFBundleVersion (build number) is
#              taken from CFBundleVersion in App/project.yml — bump
#              it by hand or via a one-liner sed before each upload.
#
# What it does:
#   1. xcodegen generate            — regen the .xcodeproj from the
#                                     project.yml spec.
#   2. xcodebuild archive           — Release archive signed for
#                                     iOS device, dSYMs included.
#   3. xcodebuild -exportArchive    — produces the .ipa via
#                                     ExportOptions.plist
#                                     (method = app-store-connect).
#   4. xcrun altool / Transporter   — uploads to App Store Connect
#                                     (best-effort; falls back to
#                                     "use Xcode Organizer" if no
#                                     ASC API key is configured).
#
# Prerequisites (one-time):
#   - Xcode 16+ on PATH; xcodegen on PATH (`brew install xcodegen`).
#   - Bundle ID `ai.bithuman.app.ipad` registered in App Store
#     Connect under your team. Export $DEVELOPMENT_TEAM in the shell
#     before running this script — see repo root README "Set your
#     Apple signing team" for how to find your 10-char team ID.
#   - Apple Distribution cert + App Store provisioning profile
#     installed in your login keychain (Xcode → Settings →
#     Accounts → Manage Certificates can install both, or Apple
#     Developer portal → Profiles).
#   - The two memory entitlements
#       com.apple.developer.kernel.increased-memory-limit
#       com.apple.developer.kernel.extended-virtual-addressing
#     are special-permission entitlements. They must be approved by
#     Apple at developer.apple.com before the distribution profile
#     will include them. If the archive fails with "provisioning
#     profile doesn't include the … entitlement", that's why.
#
# Optional environment variables for fully-automated TestFlight
# upload (App Store Connect API key, NOT a notary keychain profile):
#   ASC_API_KEY_PATH    Path to the .p8 private key file from ASC
#                       (Users + Access → Keys → API Keys → "+").
#   ASC_API_KEY_ID      Key ID (10-char string from the same page).
#   ASC_API_ISSUER_ID   Issuer ID (UUID at the top of the Keys page).
#
# If those aren't set, the script stops after producing the .ipa and
# tells you to drag it into Xcode → Window → Organizer → Distribute.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>"
    echo "  e.g. $0 0.1.0"
    exit 2
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "error: DEVELOPMENT_TEAM env var is not set."
    echo "  Find your 10-char Apple team ID at developer.apple.com/account,"
    echo "  then: export DEVELOPMENT_TEAM=ABCDE12345"
    echo "  (See repo root README → 'Set your Apple signing team'.)"
    exit 2
fi

# Resolve paths relative to the script (`..` = Apps/BithumanPad/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PAD_DIR/App"
DIST_DIR="$PAD_DIR/dist"
ARCHIVE="$DIST_DIR/BithumanPad-$VERSION.xcarchive"
EXPORT_DIR="$DIST_DIR/BithumanPad-$VERSION-export"

mkdir -p "$DIST_DIR"

# Substitute the team ID placeholder in ExportOptions.plist with the
# current $DEVELOPMENT_TEAM. The committed plist holds a sentinel so
# the repo doesn't bake in any organisation's team identifier.
EXPORT_PLIST="$DIST_DIR/ExportOptions.plist"
sed -e "s/__DEVELOPMENT_TEAM__/$DEVELOPMENT_TEAM/g" \
    "$APP_DIR/ExportOptions.plist" > "$EXPORT_PLIST"

echo "==> [1/4] regenerating Xcode project"
(cd "$APP_DIR" && xcodegen generate)

# Stamp the version into the generated project (for this run only).
# project.yml is the source of truth; we patch the marketing version
# at archive-time so callers can release without editing the spec.
PBXPROJ="$APP_DIR/BithumanPad.xcodeproj/project.pbxproj"

echo "==> [2/4] archiving Release ($VERSION) — this takes 2–5 min"
xcodebuild \
    -project "$APP_DIR/BithumanPad.xcodeproj" \
    -scheme BithumanPad \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -skipMacroValidation \
    MARKETING_VERSION="$VERSION" \
    archive

echo "==> [3/4] exporting .ipa"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates

# Find the produced .ipa (export folder names it after the scheme).
IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)"
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
    echo "error: no .ipa found in $EXPORT_DIR — export failed"
    exit 1
fi

# Rename for clarity.
FINAL_IPA="$DIST_DIR/BithumanPad-$VERSION.ipa"
cp "$IPA" "$FINAL_IPA"
echo "    → $FINAL_IPA"

echo "==> [4/4] uploading to App Store Connect"
if [[ -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    # `xcrun altool --upload-app` is still the supported path on
    # current Xcode. notarytool is for notarisation, NOT TestFlight
    # uploads — different service.
    xcrun altool --upload-app \
        --type ios \
        --file "$FINAL_IPA" \
        --apiKey "$ASC_API_KEY_ID" \
        --apiIssuer "$ASC_API_ISSUER_ID" \
        --verbose
    echo "    → uploaded; processing in App Store Connect (~10 min)."
else
    cat <<EOF
    ASC API key env vars not set — skipping automatic upload.

    Set these to enable upload from this script:
      export ASC_API_KEY_PATH=~/path/to/AuthKey_XXXXXXXXXX.p8
      export ASC_API_KEY_ID=XXXXXXXXXX
      export ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000

    Or upload manually:
      open -a Xcode "$ARCHIVE"
      # then: Window → Organizer → select archive → Distribute App

    The .ipa is ready at:
      $FINAL_IPA
EOF
fi

echo "==> done"
