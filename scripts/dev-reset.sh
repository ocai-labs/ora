#!/usr/bin/env bash
#
# dev-reset.sh — wipe ora's local state so the next launch behaves
# exactly like a fresh install.
#
# What gets reset:
#   1. Any running ora process (SIGKILL — Debug-only, no graceful quit).
#   2. Microphone TCC entry for ora.
#   3. Accessibility TCC entry for ora.
#   4. ora's UserDefaults plist (selectedModelId, hasCompletedOnboarding,
#      showInDock, showInStatusBar, launchAtLogin, autoPaste, …).
#
# What does NOT get reset:
#   - Downloaded model files in Application Support. Wipe those manually
#     if you want to test the "no model installed" branch of onboarding.
#     Path: ~/Library/Application Support/ora/Models/<model-id>/
#
# Usage:
#   ./scripts/dev-reset.sh
#
# After running, launch with `./scripts/dev-run.sh` (or from Xcode) and
# you should see the floating "Get Started" window with both permission
# cards in the .notRequested state.

set -euo pipefail

# Debug builds use a distinct bundle id (com.oceanai.ora.debug) so the dev
# app coexists with an installed release Ora and gets its own TCC + defaults.
# Reset must target the DEBUG id — resetting com.oceanai.ora would wipe the
# *release* app's permissions, not the dev one.
BUNDLE_ID="com.oceanai.ora.debug"

echo "[dev-reset] killing any running ora instances..."
pkill -9 -f 'ora\.app/Contents/MacOS/ora' 2>/dev/null || true

echo "[dev-reset] resetting Microphone TCC for $BUNDLE_ID..."
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || \
    echo "  (no existing entry — that's fine)"

echo "[dev-reset] resetting Accessibility TCC for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || \
    echo "  (no existing entry — that's fine)"

echo "[dev-reset] wiping UserDefaults for $BUNDLE_ID..."
defaults delete "$BUNDLE_ID" 2>/dev/null || \
    echo "  (no existing defaults — that's fine)"

# `cfprefsd` caches defaults aggressively; without nudging it, the next
# ora launch can see stale values for a few seconds. Killing the user's
# cfprefsd flushes the cache without affecting other apps.
killall -u "$USER" cfprefsd 2>/dev/null || true

echo "[dev-reset] done. Launch ora to see the first-run flow."
