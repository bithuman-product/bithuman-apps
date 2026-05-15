#!/usr/bin/env bash
# build-iphone-app.sh — Archive + export the BithumanPhone iOS app
# for TestFlight / App Store distribution. Optionally upload to ASC.
#
# Usage:   ./build-iphone-app.sh <version>      # e.g. 0.1.0
#          ./build-iphone-app.sh 0.1.0 --upload # also push to TestFlight
#
# Required tools: xcodegen, xcodebuild (Xcode 26+), xcrun altool (or
# notarytool for newer flows). All shipped with Xcode + Homebrew xcodegen.
#
# Required env vars (only for `--upload`):
#   ASC_API_KEY_PATH    Path to the .p8 App Store Connect API key
#   ASC_API_ISSUER_ID   ASC API key issuer UUID
#   ASC_API_KEY_ID      ASC API key ID
#
# Without those, the .ipa is still produced — just not uploaded. The
# .ipa is the deliverable; you can drag it into Transporter.app to
# upload manually.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version> [--upload]" >&2
    exit 64
fi

VERSION="$1"
UPLOAD="${2:-}"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "error: DEVELOPMENT_TEAM env var is not set." >&2
    echo "  Find your 10-char Apple team ID at developer.apple.com/account," >&2
    echo "  then: export DEVELOPMENT_TEAM=ABCDE12345" >&2
    echo "  (See repo root README → 'Set your Apple signing team'.)" >&2
    exit 2
fi

# Locations — script is at Apps/BithumanPhone/Scripts/, App project
# at Apps/BithumanPhone/App/. Resolve from script dir so it works
# regardless of cwd.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="$( cd "$SCRIPT_DIR/../App" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../../.." && pwd )"
DIST_DIR="$REPO_ROOT/dist/iphone"
ARCHIVE_PATH="$DIST_DIR/BithumanPhone-$VERSION.xcarchive"
EXPORT_DIR="$DIST_DIR/BithumanPhone-$VERSION"
IPA_PATH="$EXPORT_DIR/BithumanPhone.ipa"

mkdir -p "$DIST_DIR"

# Substitute the team ID placeholder in ExportOptions.plist. The
# committed plist holds a sentinel so the repo doesn't bake in any
# organisation's team identifier.
EXPORT_PLIST="$DIST_DIR/ExportOptions.plist"
sed -e "s/__DEVELOPMENT_TEAM__/$DEVELOPMENT_TEAM/g" \
    "$APP_DIR/ExportOptions.plist" > "$EXPORT_PLIST"

echo "==> [1/4] xcodegen — regenerating BithumanPhone.xcodeproj"
( cd "$APP_DIR" && xcodegen generate )

echo "==> [2/4] xcodebuild archive (Release, generic/iOS)"
xcodebuild archive \
    -project "$APP_DIR/BithumanPhone.xcodeproj" \
    -scheme BithumanPhone \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -skipMacroValidation \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$(date +%s)" \
    | xcbeautify || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "ERROR: archive failed — $ARCHIVE_PATH does not exist" >&2
    exit 1
fi

echo "==> [3/4] xcodebuild -exportArchive → .ipa"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    | xcbeautify || true

if [[ ! -f "$IPA_PATH" ]]; then
    echo "ERROR: export failed — $IPA_PATH does not exist" >&2
    exit 1
fi

echo "==> [4/4] IPA produced: $IPA_PATH"
ls -lh "$IPA_PATH"

if [[ "$UPLOAD" != "--upload" ]]; then
    echo
    echo "Skipping upload (no --upload flag). Drag the .ipa into"
    echo "Transporter.app to ship to TestFlight, or re-run with"
    echo "  $0 $VERSION --upload"
    exit 0
fi

# Upload step — requires ASC API key creds.
if [[ -z "${ASC_API_KEY_PATH:-}" || -z "${ASC_API_ISSUER_ID:-}" || -z "${ASC_API_KEY_ID:-}" ]]; then
    echo
    echo "WARNING: --upload requested but ASC_API_* env vars not set."
    echo "  ASC_API_KEY_PATH    path to .p8 file"
    echo "  ASC_API_ISSUER_ID   issuer UUID"
    echo "  ASC_API_KEY_ID      key ID"
    echo
    echo "The .ipa is still at: $IPA_PATH"
    echo "Upload manually with Transporter.app or:"
    echo "  xcrun altool --upload-app -f $IPA_PATH -t ios \\"
    echo "    --apiKey \$ASC_API_KEY_ID --apiIssuer \$ASC_API_ISSUER_ID"
    exit 0
fi

echo "==> Uploading to App Store Connect (TestFlight pipeline)"
# Modern API — `xcrun altool --upload-app` honours the API key when
# placed at ~/.appstoreconnect/private_keys/ or via env. Newer Xcode
# also supports `xcrun notarytool` for Mac, but for iOS we still use
# altool.
mkdir -p ~/.appstoreconnect/private_keys
cp "$ASC_API_KEY_PATH" "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"

xcrun altool --upload-app \
    -f "$IPA_PATH" \
    -t ios \
    --apiKey "$ASC_API_KEY_ID" \
    --apiIssuer "$ASC_API_ISSUER_ID"

echo
echo "==> Uploaded to App Store Connect. Processing usually completes"
echo "    within 15 minutes; check appstoreconnect.apple.com → TestFlight."
