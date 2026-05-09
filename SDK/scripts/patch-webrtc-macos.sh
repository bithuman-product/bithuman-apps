#!/usr/bin/env bash
# Repair stasel/WebRTC's macOS slice headers.
#
# Their xcframework's macOS slice ships only the umbrella header
# (`WebRTC.h`) — the 280-odd individual headers it `#import`s are
# missing. The umbrella fails to parse and the Swift module won't
# build. This script copies the iOS slice's headers into the macOS
# slice (the Objective-C interfaces are 90% platform-agnostic),
# strips the iOS-only ones (anything that touches AVAudioSession,
# UIView, UIKit), and edits the umbrella to drop their imports.
#
# The script searches every plausible location where SwiftPM /
# xcodebuild caches the framework — the local `.build/artifacts/`
# directory used by `swift build`, and DerivedData's
# `SourcePackages/artifacts/` directory used by `xcodebuild`. Both
# paths get the same treatment so the build works regardless of
# which build system the caller invoked.
#
# Idempotent — re-running on a patched tree is a no-op.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Headers that reference iOS-only APIs (AVAudioSession, UIKit). The
# binary still has their symbols, but the Obj-C declarations don't
# compile on macOS so we can't include them.
IOS_ONLY=(
  RTCAudioDevice.h
  RTCAudioSession.h
  RTCAudioSessionConfiguration.h
  RTCCameraPreviewView.h
  RTCDispatcher.h
  RTCEAGLVideoView.h
  RTCMTLVideoView.h
  RTCVideoRenderer.h
  UIDevice+RTCDevice.h
)

patched_count=0

# Patch one xcframework. Takes the full path to the .xcframework
# directory; tolerates missing slices (some package layouts include
# only iOS, some only macOS — patch what's there).
patch_xcframework() {
  local xc="$1"
  local mac_slice="$xc/macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers"
  local ios_slice="$xc/ios-arm64/WebRTC.framework/Headers"

  [[ -d "$mac_slice" && -d "$ios_slice" ]] || return 0

  for src in "$ios_slice"/*.h; do
    local base
    base="$(basename "$src")"
    local skip=0
    for ban in "${IOS_ONLY[@]}"; do
      [[ "$base" == "$ban" ]] && skip=1 && break
    done
    [[ "$skip" -eq 1 ]] && continue
    if [[ ! -f "$mac_slice/$base" ]] || ! cmp -s "$src" "$mac_slice/$base"; then
      cp "$src" "$mac_slice/$base"
    fi
  done

  local umbrella="$mac_slice/WebRTC.h"
  if grep -qE "RTCAudioSession\.h|UIDevice\+RTCDevice\.h|RTCMTLVideoView\.h" "$umbrella"; then
    [[ -f "$umbrella.bak" ]] || cp "$umbrella" "$umbrella.bak"
    sed -E -i '' \
      '/RTCAudioDevice\.h|RTCAudioSession\.h|RTCAudioSessionConfiguration\.h|RTCCameraPreviewView\.h|RTCDispatcher\.h|RTCEAGLVideoView\.h|RTCMTLVideoView\.h|RTCVideoRenderer\.h|UIDevice\+RTCDevice\.h/d' \
      "$umbrella"
  fi

  patched_count=$((patched_count + 1))
}

# Hunt for every WebRTC.xcframework under known cache roots. macOS
# ships bash 3.2 which doesn't support `globstar`, so use `find`
# (which traverses recursively without that option).
project_name="$(basename "$ROOT")"
search_roots=()
[[ -d "$ROOT/.build/artifacts" ]] && search_roots+=("$ROOT/.build/artifacts")
for d in "$HOME"/Library/Developer/Xcode/DerivedData/"${project_name}"-*/SourcePackages/artifacts \
         "$HOME"/Library/Developer/Xcode/DerivedData/bithuman-kit-*/SourcePackages/artifacts; do
  [[ -d "$d" ]] && search_roots+=("$d")
done

candidates=()
if (( ${#search_roots[@]} > 0 )); then
  while IFS= read -r line; do
    [[ -n "$line" ]] && candidates+=("$line")
  done < <(find "${search_roots[@]}" -name "WebRTC.xcframework" -type d 2>/dev/null)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "skip: no WebRTC.xcframework found yet (resolve packages first)"
  exit 0
fi

# Dedup by sorting + unique. bash 3.2 (the macOS default) lacks
# associative arrays, so use a sorted list pipe.
seen_paths=""
for xc in "${candidates[@]}"; do
  case "$seen_paths" in
    *":$xc:"*) ;;
    *)
      seen_paths="${seen_paths}:$xc:"
      patch_xcframework "$xc"
      ;;
  esac
done

# Drop any stale staged copies so the next build re-stages with the
# patched headers.
shopt -s nullglob
rm -rf "$ROOT"/.build/*-apple-macosx/*/WebRTC.framework
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/"${project_name}"-*/Build/Products/*/WebRTC.framework
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/bithuman-kit-*/Build/Products/*/WebRTC.framework
shopt -u nullglob

echo "ok: patched $patched_count WebRTC.xcframework slice(s)"
