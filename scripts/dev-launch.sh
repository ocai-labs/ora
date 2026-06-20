#!/usr/bin/env bash
#
# dev-launch.sh — build ora and launch it the way a real user would.
#
# Why this exists separately from dev-run.sh:
#   dev-run.sh exec's the Mach-O binary directly so stdout/stderr stream
#   to the terminal — great for crash debugging, terrible for TCC
#   testing. When the binary runs as a child of bash, the OS treats
#   Terminal.app as the *responsible process* for permission requests.
#   The system mic/accessibility prompts then attribute the request to
#   Terminal, not ora — so ora never appears in System Settings →
#   Privacy & Security, and granting access grants it to Terminal.
#
#   This script launches via `open -W`, which goes through Launch
#   Services. LS spawns ora as its own responsible process, the
#   permission prompts attribute to ora, and ora shows up correctly
#   in System Settings with its own icon. Use this script to verify
#   onboarding / permission flows the way a real user will see them.
#
# Trade-off:
#   stdout/stderr no longer stream to your terminal — they go to the
#   unified log system. This script tails `log stream --process ora`
#   in the background so you still see your `print()` calls and
#   os_log output here.
#
# Usage:
#   ./scripts/dev-reset.sh        # optional — wipes TCC + UserDefaults
#   ./scripts/dev-launch.sh
#
# Quit: close the ora app (menu bar → Quit Ora, or Cmd+Q on a focused
# window). The script exits when the app exits.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/ora.xcodeproj"
SCHEME="ora"
CONFIG="Debug"

cd "$REPO_ROOT"

# 1. Kill any stale ora instances. Same logic as dev-run.sh — menu-bar
#    accessory apps are stubborn to quit cleanly when Xcode or a
#    previous launch has orphaned them.
echo "[dev-launch] killing any running ora instances..."
pkill -9 -f 'ora\.app/Contents/MacOS/ora' 2>/dev/null || true

# 2. Build. Capture full output, only surface it on failure.
echo "[dev-launch] building ($CONFIG)..."
BUILD_LOG="$(mktemp -t ora-build.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT

if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        build >"$BUILD_LOG" 2>&1; then
    echo "[dev-launch] BUILD FAILED — last 80 lines:"
    tail -80 "$BUILD_LOG"
    exit 1
fi

# 3. Resolve the built .app path via Xcode build settings (more reliable
#    than hard-coding a DerivedData path or parsing the build log).
BUILT_DIR="$(
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *TARGET_BUILD_DIR = /{print $2; exit}'
)"
APP_PATH="$BUILT_DIR/ora.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[dev-launch] could not locate built .app at: $APP_PATH"
    exit 1
fi

# 4. Re-register with Launch Services. The Xcode build does this as part
#    of `RegisterWithLaunchServices`, but doing it explicitly here is
#    cheap insurance against stale LS entries from a previous build at
#    a different path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
"$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true

# 5. Start the unified-log tail in the background so we still see ora's
#    print()/os_log output. The trap kills it on script exit.
echo "[dev-launch] starting log stream for process 'ora' in background..."
log stream --process ora --level debug --style compact &
LOG_PID=$!
trap 'rm -f "$BUILD_LOG"; kill $LOG_PID 2>/dev/null || true' EXIT

# Give the log stream a moment to attach so we don't miss the first
# few lines from ora's startup.
sleep 0.3

echo "[dev-launch] opening: $APP_PATH"
echo "[dev-launch] (close ora normally to end this session)"
echo "-----"

# 6. Launch via Launch Services and block until the app exits. `-W`
#    waits for the app to terminate. `-n` would force a new instance,
#    but we already killed stale instances in step 1, so it's not
#    needed and would suppress LS's de-dupe logic.
open -W "$APP_PATH"
