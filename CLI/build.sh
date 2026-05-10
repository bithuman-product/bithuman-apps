#!/usr/bin/env bash
# Build bithuman-cli via Xcode.
#
# Why not `swift build`: mlx-swift's Package.swift expects a
# `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` next to
# the executable, but only Xcode's build system actually produces that
# bundle from the .metal source files. Running `swift build` leaves the
# metallib unbuilt, so the binary dies at first GPU call with
# "Failed to load the default metallib".
#
# -skipMacroValidation accepts mlx-swift-lm's macro packages without the
# interactive Xcode.app first-run prompt.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ "$CONFIG" == "Debug" ]]; then
  echo "⚠️  Building Debug — MLX without -O is 3–5× slower than Release." >&2
  echo "   Unless you're attaching a debugger, rerun with:  ./build.sh Release" >&2
  echo "" >&2
fi

# (Removed: previous bundled-key injection step. Hard-coding the
# bitHuman API key into the Mach-O binary made it discoverable via
# `strings`, which is the wrong shape for a credential. The CLI now
# resolves the key only from environment + on-disk file at runtime;
# users without one fall through to dev-mode unmetered avatar.)

# Resolve SwiftPM dependencies first so the WebRTC xcframework is
# extracted into DerivedData's SourcePackages/artifacts cache. Then
# patch the macOS slice headers (the LiveKitWebRTC xcframework's
# macOS slice ships only the umbrella header — see
# ../../bithuman-sdk/swift/scripts/patch-webrtc-macos.sh, kept next to the SDK package
# that owns the libwebrtc dep).
# The subsequent `xcodebuild build` uses the cached resolution so
# our patches survive.
xcodebuild \
  -scheme bithuman-cli \
  -destination 'platform=macOS,arch=arm64' \
  -configuration "$CONFIG" \
  -skipMacroValidation \
  -resolvePackageDependencies > /tmp/bithuman-cli.resolve.log 2>&1
../../bithuman-sdk/swift/scripts/patch-webrtc-macos.sh

xcodebuild \
  -scheme bithuman-cli \
  -destination 'platform=macOS,arch=arm64' \
  -configuration "$CONFIG" \
  -skipMacroValidation \
  build > /tmp/bithuman-cli.build.log 2>&1
tail -5 /tmp/bithuman-cli.build.log

# Locate the just-built binary via DerivedData. The DerivedData folder
# basename comes from xcodebuild's *project directory* name, NOT the
# SPM package name — so we glob both the current dir name and the SPM
# package name to cover either layout. nullglob keeps an unmatched
# pattern from leaking through as a literal, which would trip set -e.
shopt -s nullglob
project_dirname=$(basename "$(pwd)")
candidates=(
  ~/Library/Developer/Xcode/DerivedData/"${project_dirname}"-*/Build/Products/"$CONFIG"/bithuman-cli
  ~/Library/Developer/Xcode/DerivedData/bithuman-kit-*/Build/Products/"$CONFIG"/bithuman-cli
)
shopt -u nullglob
BIN=""
if (( ${#candidates[@]} > 0 )); then
  BIN=$(ls -t "${candidates[@]}" | head -1)
fi
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  echo "error: couldn't locate built binary under DerivedData" >&2
  exit 1
fi

# Codesign. For local development the ad-hoc identity ("-") is fine —
# TCC permissions persist and Gatekeeper isn't involved. For release
# builds destined for distribution, set SIGNING_IDENTITY to the
# Developer ID Application certificate, e.g.
#   SIGNING_IDENTITY="Developer ID Application: bitHuman Inc. (G64NFNZX84)" ./build.sh Release
# xcodebuild stamps the executable with `@executable_path/../lib` as
# the library search path — but our distributable layout (release.sh)
# puts WebRTC.framework SIBLING to the binary, not in `../lib`. Add
# `@executable_path` so the binary finds frameworks next to it. (The
# `swift build` path uses `@loader_path` for the same reason; this
# is the xcodebuild equivalent.) Idempotent — install_name_tool's
# `-add_rpath` errors on duplicates so we silently swallow that.
install_name_tool -add_rpath "@executable_path" "$BIN" 2>/dev/null || true

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign -f -s "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  "$BIN" >/dev/null 2>&1 || codesign -f -s "$SIGNING_IDENTITY" "$BIN" >/dev/null

# Write an exec-wrapper rather than a symlink. MLX's runtime resource
# lookup (mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib) is
# relative to the binary's actual path — running via symlink from the
# project dir makes MLX look for the bundle next to the symlink's
# parent, not next to the real binary, and loading fails.
cat > ./bithuman-cli <<EOF
#!/usr/bin/env bash
exec "$BIN" "\$@"
EOF
chmod +x ./bithuman-cli

# Remove any stale wrappers from previous binary names so we don't
# accidentally launch an out-of-date target.
rm -f ./voice-chat ./bithuman ./bitchat

echo "built: $BIN"
echo "wrapper: ./bithuman-cli"
