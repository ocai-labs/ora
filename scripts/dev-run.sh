#!/usr/bin/env bash
#
# dev-run.sh — build and launch ora from the command line.
#
# Why: skip Xcode's run loop entirely. Streams stderr/stdout straight to
# the terminal (so runtime crashes like the NSApp IUO trap we hit earlier
# are visible immediately), and makes it easy to kill/relaunch without
# navigating Xcode's debug session.
#
# Usage:
#   ./scripts/dev-run.sh
#
# Ctrl-C to quit the running app.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/ora.xcodeproj"
SCHEME="ora"
CONFIG="Debug"

cd "$REPO_ROOT"

# 1. Kill any stale ora instances. This is a Debug-only dev script, so
#    SIGKILL is fine and avoids the "app writes stale defaults on quit"
#    problem when we want a clean relaunch.
echo "[dev-run] killing any running ora instances..."
pkill -9 -f 'ora\.app/Contents/MacOS/ora' 2>/dev/null || true

# 2. Build. Capture full output, only surface it on failure so a clean
#    build doesn't flood the terminal.
echo "[dev-run] building ($CONFIG)..."
BUILD_LOG="$(mktemp -t ora-build.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT

if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        build >"$BUILD_LOG" 2>&1; then
    echo "[dev-run] BUILD FAILED — last 80 lines:"
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
    echo "[dev-run] could not locate built .app at: $APP_PATH"
    exit 1
fi

echo "[dev-run] launching: $APP_PATH"
echo "[dev-run] stderr/stdout streams below. Ctrl-C to quit."
echo "-----"

# 4. exec the binary directly so stdout/stderr stream to this terminal
#    and Ctrl-C propagates as SIGINT to kill the app cleanly.
exec "$APP_PATH/Contents/MacOS/ora"
