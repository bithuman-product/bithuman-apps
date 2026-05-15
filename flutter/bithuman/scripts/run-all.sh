#!/usr/bin/env bash
# run-all.sh — build + install + launch the bithuman Flutter example
# on every connected target in parallel.
#
# Targets:
#   macos    — this Mac (always reachable)
#   iphone   — paired iPhone via devicectl
#   ipad     — paired iPad via devicectl
#   android  — physical Android via adb (non-emulator)
#
# All four surfaces ship from the same Flutter codebase + the same
# libessence native lib, so the script:
#   1. validates each target is actually reachable
#   2. builds 3 artifacts (macOS / iOS universal / Android APK)
#   3. installs + launches each surface in parallel with the right
#      per-device config (dart-defines + env vars)
#   4. prints a pass/skip/fail summary
#
# Usage:
#   scripts/run-all.sh                              # everything reachable
#   scripts/run-all.sh --surfaces=macos,android     # subset
#   scripts/run-all.sh --imx=/path/to/avatar.imx    # push this .imx to mobile sandboxes
#   scripts/run-all.sh --skip-build                 # reuse last build artifacts
#   scripts/run-all.sh --no-launch                  # build + install only
#
# Env overrides (also read from ~/.env if present):
#   OPENAI_API_KEY       (required for voice)
#   BITHUMAN_API_SECRET  (required for libessence auth)
#
# Logs:
#   /tmp/bithuman-run-all/<surface>.log per target
#
# Apache-2.0; (c) bitHuman.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/example"
LOG_DIR="${LOG_DIR:-/tmp/bithuman-run-all}"
mkdir -p "$LOG_DIR"

# Identity of each surface in our app bundle catalogue.
IOS_BUNDLE="ai.bithuman.bithumanAvatarExample"
ANDROID_BUNDLE="ai.bithuman.bithuman_example"
ANDROID_ACTIVITY="$ANDROID_BUNDLE/.MainActivity"
MACOS_APP_NAME="bithuman_example.app"

# --------------------------------------------------------------- args
SURFACES_ARG=""
IMX_PUSH=""
SKIP_BUILD=0
NO_LAUNCH=0
for arg in "$@"; do
    case "$arg" in
        --surfaces=*) SURFACES_ARG="${arg#--surfaces=}" ;;
        --imx=*)      IMX_PUSH="${arg#--imx=}" ;;
        --skip-build) SKIP_BUILD=1 ;;
        --no-launch)  NO_LAUNCH=1 ;;
        -h|--help)
            sed -n '2,28p' "$0"; exit 0 ;;
        *)  echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Pull keys from ~/.env if not already in the environment. The file is
# expected to be `KEY=value` per line (no quoting needed).
if [ -f "$HOME/.env" ]; then
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Z_]+$ ]] || continue
        [ -z "${!k:-}" ] && export "$k=$v" || true
    done < "$HOME/.env"
fi

if [ -z "${OPENAI_API_KEY:-}" ] || [ -z "${BITHUMAN_API_SECRET:-}" ]; then
    echo "WARN: OPENAI_API_KEY / BITHUMAN_API_SECRET missing — apps will boot"
    echo "      but the mic button stays disabled until you fill them in."
fi

# Auto-discover an avatar.imx if the user didn't pass --imx. Without
# one the mobile apps boot to the first-run "drop an .imx here" sheet,
# which defeats the point of the launcher. Search order:
#   1. ./avatar.imx in the current dir
#   2. ./avatar.imx in the example dir
#   3. The path the macOS app already resolved (its app-support dir) —
#      following symlinks (sample-avatar.imx is typically symlinked).
if [ -z "$IMX_PUSH" ]; then
    macos_imx="$HOME/Library/Containers/$IOS_BUNDLE/Data/Library/Application Support/$IOS_BUNDLE/avatar.imx"
    for cand in \
        "./avatar.imx" \
        "$EXAMPLE_DIR/avatar.imx" \
        "$macos_imx"; do
        if [ -e "$cand" ]; then
            # readlink -f follows the symlink; ls -L tolerates a real file.
            resolved=$(readlink -f "$cand" 2>/dev/null || echo "$cand")
            [ -f "$resolved" ] && { IMX_PUSH="$resolved"; break; }
        fi
    done
    if [ -n "$IMX_PUSH" ]; then
        printf 'auto-discovered avatar.imx: %s (%s)\n' \
            "$IMX_PUSH" "$(du -h "$IMX_PUSH" | cut -f1)"
    else
        echo "WARN: no avatar.imx found — mobile apps will show the"
        echo "      first-run drop sheet. Pass --imx=/path/to/avatar.imx"
        echo "      to push one onto each mobile sandbox automatically."
    fi
fi

# --------------------------------------------------------- target picker
want() {
    [ -z "$SURFACES_ARG" ] && return 0
    case ",$SURFACES_ARG," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Detected device IDs, blank => surface unreachable.
DEV_MACOS=""
DEV_IPHONE=""
DEV_IPAD=""
DEV_ANDROID=""

detect_devices() {
    # macOS: always this host.
    if want macos; then DEV_MACOS="this-mac"; fi

    if want iphone || want ipad; then
        # `xcrun devicectl list devices` column layout is whitespace
        # padded and the iPhone/iPad model column itself contains
        # spaces — so `-F'  +'` mis-splits. Scan every token on
        # "available (paired)" rows for a UUID-shaped string instead.
        local pairs
        pairs=$(xcrun devicectl list devices 2>/dev/null | awk '
            /available \(paired\)/ {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) uuid=$i
                }
                if (uuid == "") next
                if ($0 ~ /iPhone/)     print "iphone " uuid
                else if ($0 ~ /iPad/)  print "ipad "   uuid
                uuid=""
            }')
        if want iphone; then
            DEV_IPHONE=$(awk '$1=="iphone"{print $2; exit}' <<<"$pairs")
        fi
        if want ipad; then
            DEV_IPAD=$(awk '$1=="ipad"{print $2; exit}' <<<"$pairs")
        fi
    fi

    if want android; then
        # First non-emulator, status "device" (not "unauthorized" / "offline").
        DEV_ANDROID=$(adb devices 2>/dev/null \
            | awk '$2 == "device" && $1 !~ /^emulator-/ {print $1; exit}')
    fi
}

print_status_table() {
    echo
    echo "==================== device discovery ===================="
    printf "  %-9s  %-12s  %s\n" "surface" "status" "id"
    printf "  %-9s  %-12s  %s\n" "-------" "------" "--"
    row() {
        local name="$1" id="$2"
        if [ -n "$id" ]; then printf "  %-9s  %-12s  %s\n" "$name" "READY" "$id"
        else                  printf "  %-9s  %-12s  %s\n" "$name" "skip"  "(not reachable)"
        fi
    }
    row macos   "$DEV_MACOS"
    row iphone  "$DEV_IPHONE"
    row ipad    "$DEV_IPAD"
    row android "$DEV_ANDROID"
    echo
}

# ---------------------------------------------------------------- build
common_defines() {
    local out=()
    out+=("--dart-define=OPENAI_API_KEY=${OPENAI_API_KEY:-}")
    out+=("--dart-define=BITHUMAN_API_SECRET=${BITHUMAN_API_SECRET:-}")
    printf '%s\n' "${out[@]}"
}

build_macos() {
    [ -n "$DEV_MACOS" ] || return 0
    [ "$SKIP_BUILD" = "1" ] && return 0
    echo "[build] macos…"
    cd "$EXAMPLE_DIR" || return 1
    flutter build macos --debug $(common_defines | xargs) \
        >"$LOG_DIR/build-macos.log" 2>&1 &
}

build_ios() {
    # One iOS build covers iPhone + iPad (universal bundle).
    [ -n "$DEV_IPHONE" ] || [ -n "$DEV_IPAD" ] || return 0
    [ "$SKIP_BUILD" = "1" ] && return 0
    echo "[build] ios (universal: iphone+ipad)…"
    cd "$EXAMPLE_DIR" || return 1
    # Release mode is required: devicectl process launch on iOS 14+
    # refuses Debug-mode Flutter apps without the Flutter tooling
    # attached. See feedback_ios_devicectl_provisioning + the iPhone
    # Release-mode memory entry.
    flutter build ios --release $(common_defines | xargs) \
        >"$LOG_DIR/build-ios.log" 2>&1 &
}

build_android() {
    [ -n "$DEV_ANDROID" ] || return 0
    [ "$SKIP_BUILD" = "1" ] && return 0
    echo "[build] android apk…"
    cd "$EXAMPLE_DIR" || return 1
    flutter build apk --debug $(common_defines | xargs) \
        >"$LOG_DIR/build-android.log" 2>&1 &
}

run_all_builds() {
    if [ "$SKIP_BUILD" = "1" ]; then
        echo "[build] --skip-build set, reusing existing artifacts"
        return 0
    fi
    # Parallel: different output dirs (build/macos, build/ios, build/app)
    # so they don't race on outputs. They share .dart_tool/, but flutter's
    # build system handles concurrent reads of that fine in practice.
    build_macos
    build_ios
    build_android
    wait
    local failed=0
    for f in build-macos build-ios build-android; do
        local log="$LOG_DIR/$f.log"
        [ -f "$log" ] || continue
        if grep -qE "(Built |✓ )" "$log"; then
            echo "  ✓ $f"
        elif grep -qE "(Error|FAILURE|error:)" "$log"; then
            echo "  ✗ $f  (see $log)"
            failed=$((failed+1))
        fi
    done
    [ "$failed" -eq 0 ] || { echo "[build] $failed build(s) failed."; return 1; }
}

# --------------------------------------------------------- install + launch
#
# Each launch function runs under `&` so the parent shell can't observe
# variable assignments (subshell isolation). Results are written to
# small one-line files under $LOG_DIR and read back in the summary.
RESULTS_DIR="$LOG_DIR/results"
rm -rf "$RESULTS_DIR" && mkdir -p "$RESULTS_DIR"
set_result() { printf '%s\n' "$2" >"$RESULTS_DIR/$1"; }
get_result() { [ -f "$RESULTS_DIR/$1" ] && cat "$RESULTS_DIR/$1" || echo skip; }

# Optional: pre-position avatar.imx onto each mobile sandbox.
push_imx_ios() {
    local udid="$1"
    [ -n "$IMX_PUSH" ] && [ -f "$IMX_PUSH" ] || return 0
    xcrun devicectl device copy to \
        --device "$udid" --domain-type appDataContainer \
        --domain-identifier "$IOS_BUNDLE" \
        --source "$IMX_PUSH" \
        --destination "Library/Application Support/avatar.imx" \
        >>"$LOG_DIR/push-ios-$udid.log" 2>&1 || true
}

push_imx_android() {
    local serial="$1"
    [ -n "$IMX_PUSH" ] && [ -f "$IMX_PUSH" ] || return 0
    # Flutter's getApplicationSupportDirectory() resolves to
    #   /data/user/0/<pkg>/files
    # on Android — the internal app sandbox. `adb push` can't write
    # there directly on non-rooted devices. The external-storage path
    # (/sdcard/Android/data/...) is a DIFFERENT location and the app
    # does NOT look there. Reliable path:
    #   1. push the .imx to /sdcard/Download (public, adb-writable)
    #   2. run-as <pkg> cp it into files/avatar.imx (app's uid)
    #   3. clean up the /sdcard staging copy.
    #
    # Why not `adb exec-out run-as <pkg> sh -c 'cat > files/...'`?
    # Empirically the binary stdin stalls on large payloads (120 MB
    # never landed; size stuck at 0 throughout). `adb push` has its
    # own binary-safe transport so this two-step is reliable.
    local log="$LOG_DIR/push-android-$serial.log"
    local stage="/sdcard/Download/bithuman-staging-avatar.imx"
    echo "[push-imx] android <- $IMX_PUSH" >"$log"
    # Same `pm clear` + `install -r` issue: files/ may not exist yet
    # because Flutter only creates it on first
    # getApplicationSupportDirectory() call. Pre-create.
    adb -s "$serial" shell \
        "run-as $ANDROID_BUNDLE mkdir -p files" >>"$log" 2>&1 || true
    if ! adb -s "$serial" push "$IMX_PUSH" "$stage" >>"$log" 2>&1; then
        echo "[push-imx] android push to /sdcard FAILED" >>"$log"; return 1
    fi
    if ! adb -s "$serial" shell \
            "run-as $ANDROID_BUNDLE cp '$stage' files/avatar.imx" \
            >>"$log" 2>&1; then
        echo "[push-imx] android run-as cp FAILED" >>"$log"; return 1
    fi
    adb -s "$serial" shell "rm -f '$stage'" >>"$log" 2>&1 || true
    # Verify size.
    adb -s "$serial" shell \
        "run-as $ANDROID_BUNDLE stat -c %s files/avatar.imx" \
        >>"$log" 2>&1 || true
}

launch_macos() {
    [ -n "$DEV_MACOS" ] || return 0
    local app="$EXAMPLE_DIR/build/macos/Build/Products/Debug/$MACOS_APP_NAME"
    if [ ! -d "$app" ]; then
        set_result macos "fail (no build)"; return 1
    fi
    pkill -f "$MACOS_APP_NAME/Contents/MacOS" 2>/dev/null || true
    if [ "$NO_LAUNCH" = "1" ]; then
        set_result macos "built"; return 0
    fi
    open "$app" >"$LOG_DIR/macos.log" 2>&1
    set_result macos "launched"
}

launch_ios_one() {
    local udid="$1" label="$2"
    local app="$EXAMPLE_DIR/build/ios/iphoneos/Runner.app"
    if [ ! -d "$app" ]; then
        set_result "$label" "fail (no build)"; return 1
    fi
    local log="$LOG_DIR/$label.log"
    echo "[install] $label ($udid)…" >"$log"
    if ! xcrun devicectl device install app \
            --device "$udid" "$app" >>"$log" 2>&1; then
        set_result "$label" "fail (install)"; return 1
    fi
    push_imx_ios "$udid"
    if [ "$NO_LAUNCH" = "1" ]; then
        set_result "$label" "installed"; return 0
    fi
    if xcrun devicectl device process launch \
            --device "$udid" \
            --environment-variables \
                "{\"BITHUMAN_API_SECRET\":\"${BITHUMAN_API_SECRET:-}\"}" \
            "$IOS_BUNDLE" >>"$log" 2>&1; then
        set_result "$label" "launched"
    else
        set_result "$label" "fail (launch)"
    fi
}

launch_iphone() {
    [ -n "$DEV_IPHONE" ] || return 0
    launch_ios_one "$DEV_IPHONE" iphone
}

launch_ipad() {
    [ -n "$DEV_IPAD" ] || return 0
    launch_ios_one "$DEV_IPAD" ipad
}

launch_android() {
    [ -n "$DEV_ANDROID" ] || return 0
    local apk="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-debug.apk"
    if [ ! -f "$apk" ]; then
        set_result android "fail (no apk)"; return 1
    fi
    local log="$LOG_DIR/android.log"
    echo "[install] android ($DEV_ANDROID)…" >"$log"
    adb -s "$DEV_ANDROID" shell pm clear "$ANDROID_BUNDLE" >>"$log" 2>&1 || true
    if ! adb -s "$DEV_ANDROID" install -r "$apk" >>"$log" 2>&1; then
        set_result android "fail (install)"; return 1
    fi
    push_imx_android "$DEV_ANDROID"
    if [ "$NO_LAUNCH" = "1" ]; then
        set_result android "installed"; return 0
    fi
    if adb -s "$DEV_ANDROID" shell am start \
            -n "$ANDROID_ACTIVITY" >>"$log" 2>&1; then
        set_result android "launched"
    else
        set_result android "fail (launch)"
    fi
}

run_all_installs_and_launches() {
    echo
    echo "==================== install + launch ===================="
    launch_macos   &
    launch_iphone  &
    launch_ipad    &
    launch_android &
    wait
}

# ---------------------------------------------------------------- summary
print_summary() {
    echo
    echo "===================== run-all summary ====================="
    printf "  %-9s  %s\n" "macOS"   "$(get_result macos)"
    printf "  %-9s  %s\n" "iPhone"  "$(get_result iphone)"
    printf "  %-9s  %s\n" "iPad"    "$(get_result ipad)"
    printf "  %-9s  %s\n" "Android" "$(get_result android)"
    echo
    echo "  build logs:   $LOG_DIR/build-{macos,ios,android}.log"
    echo "  device logs:  $LOG_DIR/{macos,iphone,ipad,android}.log"
    echo
}

# ------------------------------------------------------------------- main
detect_devices
print_status_table

if [ -z "$DEV_MACOS$DEV_IPHONE$DEV_IPAD$DEV_ANDROID" ]; then
    echo "No reachable targets. Plug something in or pass --surfaces=…" >&2
    exit 1
fi

run_all_builds || { print_summary; exit 1; }
run_all_installs_and_launches
print_summary
