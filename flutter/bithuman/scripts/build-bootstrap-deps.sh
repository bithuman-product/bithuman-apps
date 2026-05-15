#!/usr/bin/env bash
# build-bootstrap-deps.sh — package the native dependencies that the
# Flutter plugin's iOS + macOS targets link against, ready to be
# attached to a `bootstrap-deps-vN` GitHub Release on bithuman-apps.
#
# Layout of the produced tarball matches what `scripts/bootstrap.sh`
# expects, so the round-trip is:
#
#   1. (here) build-bootstrap-deps.sh -> bithuman-flutter-deps-<TAG>.tar.gz
#   2. (here) gh release create <TAG> bithuman-flutter-deps-<TAG>.tar.gz
#   3. (external user) bootstrap.sh -> downloads + extracts + symlinks
#
# Usage:
#   ./build-bootstrap-deps.sh <TAG>
#   # e.g. ./build-bootstrap-deps.sh bootstrap-deps-v2
#
# Optional env:
#   SDK_CPP            Path to the sibling bithuman-sdk/cpp tree
#                      (default: ../../../bithuman-sdk/cpp relative to
#                       this script). Override if your checkout layout
#                       differs.
#   OUT_DIR            Where the tarball lands (default: ./dist).
#   PUBLISH=1          Also run `gh release create` after building.
#                      Without it, you get the tarball and a copy-
#                      paste-able command at the end.
#
# Prerequisites:
#   - A built bithuman-sdk/cpp tree with:
#       build/libessence.a                                 (macOS arm64)
#       build-ios/Release-iphoneos/libessence.a            (iOS device)
#       build-ios-sim/Release-iphonesimulator/libessence.a (iOS sim)
#       third_party/{webp,jpeg-turbo,hdf5,ffmpeg}-ios/...
#       third_party/onnxruntime-ios/onnxruntime.xcframework
#   - `gh` CLI logged in (only if PUBLISH=1).
#
# Apache-2.0; (c) bitHuman.

set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    echo "usage: $0 <tag>  (e.g. bootstrap-deps-v2)" >&2
    exit 2
fi
if ! [[ "$TAG" =~ ^bootstrap-deps-v[0-9]+$ ]]; then
    echo "warn: tag '$TAG' doesn't match the expected pattern" >&2
    echo "      'bootstrap-deps-vN' — continuing anyway." >&2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_CPP="${SDK_CPP:-$PLUGIN_ROOT/../../../bithuman-sdk/cpp}"
OUT_DIR="${OUT_DIR:-$PLUGIN_ROOT/dist/bootstrap-deps}"
STAGE="$OUT_DIR/stage-$TAG"
TARBALL="$OUT_DIR/bithuman-flutter-deps-${TAG}.tar.gz"

if [[ ! -d "$SDK_CPP" ]]; then
    echo "error: bithuman-sdk/cpp not found at $SDK_CPP" >&2
    echo "       set SDK_CPP=/path/to/bithuman-sdk/cpp" >&2
    exit 1
fi

log() { printf '\033[1;36m[deps]\033[0m %s\n' "$*"; }

# ----------------------------------------------------------- verify inputs

declare -a REQUIRED=(
    "build/libessence.a"
    "build-ios/Release-iphoneos/libessence.a"
    "build-ios-sim/Release-iphonesimulator/libessence.a"
    "third_party/onnxruntime-ios/onnxruntime.xcframework"
    "third_party/webp-ios/lib/iphoneos/libwebp.a"
    "third_party/jpeg-turbo-ios/lib/iphoneos/libjpeg.a"
    "third_party/hdf5-ios/lib/iphoneos/libhdf5_hl.a"
    "third_party/hdf5-ios/lib/iphoneos/libhdf5.a"
    "third_party/ffmpeg-ios/lib/iphoneos/libavformat.a"
)
missing=0
for rel in "${REQUIRED[@]}"; do
    if [[ ! -e "$SDK_CPP/$rel" ]]; then
        echo "missing: $SDK_CPP/$rel" >&2
        missing=1
    fi
done
[[ "$missing" -eq 0 ]] || { echo "rebuild bithuman-sdk/cpp before retrying." >&2; exit 1; }

# --------------------------------------------------------- stage the tree

log "Staging deps under ${STAGE}…"
rm -rf "$STAGE"
mkdir -p "$STAGE/macos" "$STAGE/ios"

# macOS: just libessence.a (Homebrew dylibs are user-installed).
cp "$SDK_CPP/build/libessence.a" "$STAGE/macos/build/libessence.a" 2>/dev/null \
  || { mkdir -p "$STAGE/macos/build" && cp "$SDK_CPP/build/libessence.a" "$STAGE/macos/build/"; }

# iOS device + sim libessence.
mkdir -p "$STAGE/ios/build-ios/Release-iphoneos" \
         "$STAGE/ios/build-ios-sim/Release-iphonesimulator"
cp "$SDK_CPP/build-ios/Release-iphoneos/libessence.a" \
   "$STAGE/ios/build-ios/Release-iphoneos/libessence.a"
cp "$SDK_CPP/build-ios-sim/Release-iphonesimulator/libessence.a" \
   "$STAGE/ios/build-ios-sim/Release-iphonesimulator/libessence.a"

# iOS third-party libs — copy the device + simulator slices the podspec
# references. Skip Android-only and unused third parties to keep tarball lean.
for tp in webp-ios jpeg-turbo-ios hdf5-ios ffmpeg-ios; do
    mkdir -p "$STAGE/ios/third_party/$tp/lib"
    if [[ -d "$SDK_CPP/third_party/$tp/lib" ]]; then
        cp -R "$SDK_CPP/third_party/$tp/lib" "$STAGE/ios/third_party/$tp/"
    fi
    # Headers if the lib provides them and the pod consumes them
    if [[ -d "$SDK_CPP/third_party/$tp/include" ]]; then
        cp -R "$SDK_CPP/third_party/$tp/include" "$STAGE/ios/third_party/$tp/"
    fi
done

# onnxruntime xcframework (large but unavoidable — it's the prebuilt
# inference runtime for the lipsync model on iOS).
cp -R "$SDK_CPP/third_party/onnxruntime-ios/onnxruntime.xcframework" \
      "$STAGE/ios/onnxruntime.xcframework"

# --------------------------------------------------------------- tar it up

log "Compressing to ${TARBALL}…"
mkdir -p "$OUT_DIR"
tar -czf "$TARBALL" -C "$STAGE" macos ios
tar_size=$(du -h "$TARBALL" | cut -f1)
log "Built $TARBALL ($tar_size)"

# ---------------------------------------------- (optional) publish step

if [[ "${PUBLISH:-0}" == "1" ]]; then
    log "Creating GitHub Release $TAG on bithuman-product/bithuman-apps…"
    if gh release view "$TAG" --repo bithuman-product/bithuman-apps >/dev/null 2>&1; then
        log "Release exists — uploading asset with --clobber."
        gh release upload "$TAG" "$TARBALL" --clobber \
            --repo bithuman-product/bithuman-apps
    else
        gh release create "$TAG" "$TARBALL" \
            --repo bithuman-product/bithuman-apps \
            --title "Flutter native deps — $TAG" \
            --notes "Native dependencies (libessence.a iOS device/sim + macOS, onnxruntime.xcframework, third-party .a slices) consumed by scripts/bootstrap.sh on this repo. Layout: \`macos/build/libessence.a\`, \`ios/build-ios/Release-iphoneos/...\`, \`ios/build-ios-sim/Release-iphonesimulator/...\`, \`ios/third_party/{webp,jpeg-turbo,hdf5,ffmpeg}-ios/lib/...\`, \`ios/onnxruntime.xcframework\`. Refresh by rerunning \`scripts/build-bootstrap-deps.sh\` with \`PUBLISH=1\`."
    fi
    log "Done — release URL:"
    gh release view "$TAG" --repo bithuman-product/bithuman-apps \
        --json url --jq .url
else
    cat <<HINT

Tarball is ready. To publish it as the $TAG release:

  PUBLISH=1 $0 $TAG

…or do it manually:

  gh release create $TAG "$TARBALL" \\
      --repo bithuman-product/bithuman-apps \\
      --title "Flutter native deps — $TAG" \\
      --notes "Layout: macos/build/libessence.a + ios/* mirrors what scripts/bootstrap.sh expects."

HINT
fi
