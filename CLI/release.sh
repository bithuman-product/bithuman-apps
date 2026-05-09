#!/usr/bin/env bash
# Build, sign, notarise, and staple the bithuman-cli binary for distribution.
#
# Prerequisites — run once on a fresh machine:
#
#   1. Developer ID Application certificate installed in the login
#      keychain. Verify with:
#        security find-identity -v -p codesigning
#      You should see a line like:
#        "Developer ID Application: bitHuman Inc. (G64NFNZX84)"
#
#   2. notarytool credentials stored in the keychain under the profile
#      name `bithuman-notary`. Either an App Store Connect API key
#      (preferred):
#        xcrun notarytool store-credentials "bithuman-notary" \
#          --key   /path/to/AuthKey_XXXXXX.p8 \
#          --key-id   XXXXXXXXXX \
#          --issuer   ISSUER-UUID
#      …or an Apple ID + app-specific password:
#        xcrun notarytool store-credentials "bithuman-notary" \
#          --apple-id   you@example.com \
#          --team-id    G64NFNZX84 \
#          --password   abcd-efgh-ijkl-mnop  # app-specific password
#
#   The Apple Developer Team ID for bitHuman Inc. is G64NFNZX84 — change
#   IDENTITY / PROFILE below if you ship under a different team.
#
# Output: dist/bithuman-cli-<version>.zip — a signed, notarised, stapled
# bundle containing the binary plus its sibling resource bundles
# (bitHumanKit resources, mlx-swift_Cmlx with default.metallib).
# Users can extract this anywhere on their disk and run ./bithuman-cli.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.1.0}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: bitHuman Inc. (G64NFNZX84)}"
PROFILE="${NOTARY_PROFILE:-bithuman-notary}"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SIGNING_IDENTITY="$IDENTITY"

echo "🧹 Cleaning DerivedData so we don't ship stale artifacts (e.g. resource"
echo "   bundles from a prior package/target name)."
# `-skipMacroValidation` matches build.sh — without it,
# MLXHuggingFaceMacros trips xcodebuild's macro-trust prompt and
# fails the clean step in non-interactive contexts (this script).
xcodebuild clean \
  -scheme bithuman-cli \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  -skipMacroValidation \
  > /tmp/bithuman-cli.clean.log 2>&1
tail -3 /tmp/bithuman-cli.clean.log

echo "🔨 Release build with Developer ID signing"
./build.sh Release > /tmp/bithuman-cli.release.log 2>&1
tail -3 /tmp/bithuman-cli.release.log

# Find the products dir from the wrapper script that build.sh leaves behind.
shim=$(cat ./bithuman-cli)
real_bin=$(echo "$shim" | sed -nE 's/.*exec[[:space:]]+"([^"]+)".*/\1/p')
products_dir=$(dirname "$real_bin")
echo "binary: $real_bin"

# Stage the artefacts in a clean dir so the zip layout is predictable.
stage="dist/staging-$VERSION"
out="dist/bithuman-cli-$VERSION.zip"
rm -rf "$stage" "$out"
mkdir -p "$stage"
cp "$real_bin" "$stage/"
# All sibling .bundle directories MLX needs (resource bundles +
# mlx-swift_Cmlx with default.metallib).
find "$products_dir" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$stage/" \;
# Sibling .framework dirs the binary loads at runtime via the
# `@executable_path` rpath baked in by build.sh. Currently this is
# `WebRTC.framework` (libwebrtc, used by the OpenAI Realtime
# backend); any future framework deps land here automatically.
# `cp -RH` follows symlinks so codesign sees a valid framework
# layout to sign.
find "$products_dir" -maxdepth 1 -name "*.framework" -exec cp -RH {} "$stage/" \;

echo "🔏 Re-signing every .bundle, .framework, and the binary"
# Sign nested bundles + frameworks first, then the main binary, so
# codesign sees a valid signed graph. --options runtime is required
# for notarisation; --timestamp embeds a secure timestamp.
find "$stage" -name "*.bundle" -print0 | while IFS= read -r -d '' bundle; do
  codesign -f -s "$IDENTITY" --options runtime --timestamp --deep "$bundle" >/dev/null
done
find "$stage" -maxdepth 1 -name "*.framework" -print0 | while IFS= read -r -d '' fw; do
  codesign -f -s "$IDENTITY" --options runtime --timestamp --deep "$fw" >/dev/null
done
# Hardened runtime by default rejects loading dylibs signed by a
# different Team ID than the host binary. WebRTC.framework is signed
# by Google's team (it ships pre-built); re-signing it with our cert
# updates the wrapper but the inner Mach-O still carries Google's
# Team ID in its signature. The cleanest fix is to grant the binary
# `com.apple.security.cs.disable-library-validation`, which lets it
# load third-party-signed frameworks at runtime. Microphone access
# also needs the audio-input entitlement explicitly under hardened
# runtime.
ent_plist="$(mktemp -t bithuman-cli-ents).plist"
cat > "$ent_plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF
codesign -f -s "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ent_plist" \
  --identifier "ai.bithuman.cli" "$stage/bithuman-cli" >/dev/null
rm -f "$ent_plist"

echo "📦 Zipping for notarytool"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$out"

echo "🚀 Submitting to Apple notarisation service (this can take a few minutes)"
xcrun notarytool submit "$out" --keychain-profile "$PROFILE" --wait

echo "📎 Stapling the notarisation ticket"
# `stapler` only works on .app/.dmg/.kext directly. For a CLI shipped
# in a zip, the staple must be applied to each individual .bundle
# inside (and to the binary if it were inside a .app). Apple's
# notarisation result is checked online by Gatekeeper at first launch
# anyway, so the staple is a nice-to-have not a must-have for CLI
# tools — we still try to staple anything stapleable.
for b in "$stage"/*.bundle; do
  xcrun stapler staple "$b" 2>/dev/null || true
done
for fw in "$stage"/*.framework; do
  xcrun stapler staple "$fw" 2>/dev/null || true
done

# Re-zip after stapling so the distributed archive contains the
# embedded tickets.
rm -f "$out"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$out"

echo
echo "✅ done. Distribute: $out ($(du -sh "$out" | awk '{print $1}'))"
echo "   sha256: $(shasum -a 256 "$out" | awk '{print $1}')"
echo
echo "Smoke-test on a fresh-state Mac:"
echo "    unzip -d /tmp/bithuman-cli-smoke $out && /tmp/bithuman-cli-smoke/staging-$VERSION/bithuman-cli --help"
