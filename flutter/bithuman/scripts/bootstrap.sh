#!/usr/bin/env bash
# bootstrap.sh — fetch the native dependencies the bithuman Flutter
# plugin links against (iOS + macOS only).
#
# Background: the plugin's macOS pod links against `libessence.a` and
# Homebrew dylibs at runtime; the iOS pod links against `libessence.a`
# slices for device + simulator plus a few prebuilt C++ deps. Those
# binaries are too large to commit directly, so they live as a tarball
# on this repo's GitHub Releases under the `bootstrap-deps-vN` tag.
#
# This script:
#   1. Detects your host (macOS / Linux) and target platforms.
#   2. Downloads the right tarball if you don't already have it cached.
#   3. Extracts it into `flutter/bithuman/{ios,macos}/Vendor/` and
#      `flutter/bithuman/ios/Frameworks/`.
#
# Re-running is safe — already-fresh files are skipped.
#
# Override the release tag (e.g. for testing a pre-release):
#   BOOTSTRAP_DEPS_TAG=bootstrap-deps-v2 ./bootstrap.sh
#
# Apache-2.0; (c) bitHuman.

set -euo pipefail

REPO_OWNER="bithuman-product"
REPO_NAME="bithuman-apps"
DEFAULT_TAG="bootstrap-deps-v1"
TAG="${BOOTSTRAP_DEPS_TAG:-$DEFAULT_TAG}"
TARBALL_NAME="bithuman-flutter-deps-${TAG}.tar.gz"

PLUGIN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${BOOTSTRAP_CACHE_DIR:-$HOME/.cache/bithuman/flutter-deps}"
mkdir -p "$CACHE_DIR"

# Where the tarball will be extracted to. Layout after extraction:
#   <CACHE_DIR>/<TAG>/
#     ├── ios/
#     │   ├── build-ios/Release-iphoneos/libessence.a
#     │   ├── build-ios-sim/Release-iphonesimulator/libessence.a
#     │   ├── third_party/...
#     │   └── onnxruntime.xcframework/
#     └── macos/
#         └── build/libessence.a
EXTRACT_DIR="$CACHE_DIR/$TAG"

# ---------------------------------------------------------------- helpers

log()  { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# Symlink target -> destination, replacing existing links/dirs at dest.
# Targets are made RELATIVE to the destination's parent so the symlink
# survives moving the workspace and contains no absolute personal paths.
relink() {
    local target="$1" dest="$2"
    [ -e "$target" ] || { warn "missing $target — tarball layout mismatch?"; return 1; }
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    # Use python for portable abs→rel conversion (`realpath --relative-to`
    # is GNU-only; macOS BSD `realpath` doesn't support it).
    local rel_target
    rel_target=$(python3 -c \
        "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
        "$target" "$(dirname "$dest")")
    ln -s "$rel_target" "$dest"
}

# ---------------------------------------------------- platform detection

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) HOST_OS=mac ;;
    Linux)  HOST_OS=linux ;;
    *)      die "unsupported host: $HOST_OS — only macOS and Linux are supported" ;;
esac

# On Linux, the only native target we can build for is Android — and that
# pulls its libraries from Maven Central automatically. Nothing for this
# script to do.
if [ "$HOST_OS" = linux ]; then
    log "Linux host detected — Android builds use Maven Central and need no bootstrap. Nothing to do."
    exit 0
fi

# --------------------------------------------------- bithuman-sdk shortcut

# If a sibling `bithuman-sdk` clone exists with a built `cpp/` tree, use
# it directly. This is the dev path for contributors who work on the
# native SDK and the Flutter plugin side-by-side.
SIBLING_SDK_CPP="$PLUGIN_ROOT/../../../bithuman-sdk/cpp"
if [ -d "$SIBLING_SDK_CPP/build" ] && [ -f "$SIBLING_SDK_CPP/build/libessence.a" ]; then
    log "Sibling bithuman-sdk build found at $SIBLING_SDK_CPP — using it directly."
    relink "$SIBLING_SDK_CPP/build"          "$PLUGIN_ROOT/macos/Vendor/build"
    relink "$SIBLING_SDK_CPP/build-ios"      "$PLUGIN_ROOT/ios/Vendor/build-ios"
    relink "$SIBLING_SDK_CPP/build-ios-sim"  "$PLUGIN_ROOT/ios/Vendor/build-ios-sim"
    relink "$SIBLING_SDK_CPP/third_party"    "$PLUGIN_ROOT/ios/Vendor/third_party"
    if [ -d "$SIBLING_SDK_CPP/third_party/onnxruntime-ios/onnxruntime.xcframework" ]; then
        relink "$SIBLING_SDK_CPP/third_party/onnxruntime-ios/onnxruntime.xcframework" \
               "$PLUGIN_ROOT/ios/Frameworks/onnxruntime.xcframework"
    fi
    log "Done."
    exit 0
fi

# ---------------------------------------- download from GitHub Releases

TARBALL_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${TAG}/${TARBALL_NAME}"
TARBALL_PATH="$CACHE_DIR/$TARBALL_NAME"

if [ ! -f "$TARBALL_PATH" ]; then
    log "Downloading $TARBALL_NAME from GitHub Releases…"
    log "  $TARBALL_URL"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --progress-bar -o "$TARBALL_PATH" "$TARBALL_URL" || {
            rm -f "$TARBALL_PATH"
            die "download failed — check that the release tag '$TAG' exists at https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "$TARBALL_PATH" "$TARBALL_URL" || {
            rm -f "$TARBALL_PATH"
            die "download failed — check the release tag exists"
        }
    else
        die "neither curl nor wget found — install one and rerun"
    fi
else
    log "Using cached tarball at $TARBALL_PATH"
fi

# ------------------------------------------------------------- extract

if [ ! -d "$EXTRACT_DIR" ]; then
    log "Extracting to $EXTRACT_DIR…"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$TARBALL_PATH" -C "$EXTRACT_DIR" || die "extraction failed"
else
    log "Already extracted at $EXTRACT_DIR (delete and rerun to refresh)."
fi

# ------------------------------------------------------------- link in

log "Linking deps into plugin tree…"
relink "$EXTRACT_DIR/macos/build"                     "$PLUGIN_ROOT/macos/Vendor/build"
relink "$EXTRACT_DIR/ios/build-ios"                   "$PLUGIN_ROOT/ios/Vendor/build-ios"
relink "$EXTRACT_DIR/ios/build-ios-sim"               "$PLUGIN_ROOT/ios/Vendor/build-ios-sim"
relink "$EXTRACT_DIR/ios/third_party"                 "$PLUGIN_ROOT/ios/Vendor/third_party"
relink "$EXTRACT_DIR/ios/onnxruntime.xcframework"     "$PLUGIN_ROOT/ios/Frameworks/onnxruntime.xcframework"

log "Done. You can now build the example app:"
log "    cd $PLUGIN_ROOT/example && flutter pub get && flutter run"
