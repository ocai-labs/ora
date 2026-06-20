#!/bin/bash
# Build ora for release.
#
# Version, build number, and signing team ID are derived at build time
# rather than being checked into project.pbxproj:
#
#   - MARKETING_VERSION       <- latest git tag (e.g. v1.0.0 -> 1.0.0)
#   - CURRENT_PROJECT_VERSION <- total commit count (monotonically increasing)
#   - DEVELOPMENT_TEAM        <- $ORA_DEV_TEAM env var (from
#                                scripts/dev-env.local.sh, gitignored)
#
# Debug builds keep working for any contributor without setup —
# xcodebuild falls back to ad-hoc signing when DEVELOPMENT_TEAM is
# empty, and this script is release-only.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ora.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

cd "$PROJECT_DIR"

# Source the local dev env (gitignored) if present, so ORA_DEV_TEAM
# falls into scope without the user having to export it in every shell.
if [ -f "$PROJECT_DIR/scripts/dev-env.local.sh" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/scripts/dev-env.local.sh"
fi

# ============================================
# Resolve version + build number from git
# ============================================
RAW_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$RAW_TAG" ]; then
    echo "ERROR: No git tag found."
    echo ""
    echo "Create one before releasing, e.g.:"
    echo "  git tag v1.0.0"
    echo ""
    exit 1
fi
VERSION="${RAW_TAG#v}"

TAG_COMMIT=$(git rev-list -n 1 "$RAW_TAG")
HEAD_COMMIT=$(git rev-parse HEAD)
if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "WARNING: HEAD ($HEAD_COMMIT) is not at tag $RAW_TAG ($TAG_COMMIT)."
    echo "         The release will still be labeled $VERSION but may contain"
    echo "         additional uncommitted/untagged changes."
    echo ""
fi

BUILD=$(git rev-list --count HEAD)

# ============================================
# Resolve signing team ID
# ============================================
TEAM_ID="${ORA_DEV_TEAM:-}"
if [ -z "$TEAM_ID" ]; then
    echo "ERROR: No Apple Developer Team ID configured."
    echo ""
    echo "Set ORA_DEV_TEAM in scripts/dev-env.local.sh (copy from"
    echo "scripts/dev-env.local.sh.example if it doesn't exist yet),"
    echo "or export it in your current shell:"
    echo ""
    echo "  export ORA_DEV_TEAM=YOUR_TEAM_ID"
    echo ""
    echo "Find your Team ID at https://developer.apple.com/account"
    echo "(10-character string in the membership details)."
    exit 1
fi

echo "=== Building ora ==="
echo "  Tag:      $RAW_TAG"
echo "  Version:  $VERSION"
echo "  Build:    $BUILD"
echo "  Team ID:  $TEAM_ID"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Archiving..."
xcodebuild archive \
    -project ora.xcodeproj \
    -scheme ora \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo ""
echo "Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo ""
echo "=== Build Complete ==="
echo "  App:     $EXPORT_PATH/ora.app"
echo "  Version: $VERSION (build $BUILD)"
echo ""
echo "Next: ./scripts/create-release.sh"
