#!/bin/bash
# Create a release: notarize, create DMG, sign for Sparkle, generate
# appcast, and upload everything (DMG + appcast.xml) to a GitHub Release.
#
# Releases (DMG + appcast.xml) are published to a dedicated public repo
# so the main source repo can stay private. The Sparkle feed in
# ora/Info.plist points at:
#   https://github.com/KristampsWong/ora/releases/latest/download/appcast.xml
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

# Source the gitignored local dev env so a contributor can point at
# their own notarytool keychain profile without editing this script.
if [ -f "$PROJECT_DIR/scripts/dev-env.local.sh" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/scripts/dev-env.local.sh"
fi

GITHUB_REPO="KristampsWong/ora"

APP_PATH="$EXPORT_PATH/ora.app"
APP_NAME="ora"
KEYCHAIN_PROFILE="${ORA_NOTARY_PROFILE:-ora}"
MIN_SYSTEM_VERSION="14.0"

echo "=== Creating Release ==="
echo ""

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo "Version: $VERSION (build $BUILD)"
echo ""

# ============================================
# Step 0: Validate CHANGELOG entry
# ============================================
# Runs BEFORE notarization so a missing entry fails in seconds rather
# than after a multi-minute notary round-trip.
echo "=== Step 0: Validating CHANGELOG entry ==="

CHANGELOG_PATH="$PROJECT_DIR/CHANGELOG.md"
if [ ! -f "$CHANGELOG_PATH" ]; then
    echo "ERROR: CHANGELOG.md not found at $CHANGELOG_PATH"
    echo "Create it and add a section for v$VERSION before re-running."
    exit 1
fi

RELEASE_NOTES=$(awk -v hdr="## [$VERSION]" '
    /^## \[/ {
        if (in_section) exit
        if (substr($0, 1, length(hdr)) == hdr) { in_section = 1; next }
        next
    }
    in_section { lines[++n] = $0 }
    END {
        first = 1
        while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
        last = n
        while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = first; i <= last; i++) print lines[i]
    }
' "$CHANGELOG_PATH")

if [ -z "$RELEASE_NOTES" ]; then
    echo "ERROR: No CHANGELOG.md entry found for version $VERSION."
    echo ""
    echo "Add a section to CHANGELOG.md (newest first), e.g.:"
    echo ""
    echo "## [$VERSION] - $(date +%Y-%m-%d)"
    echo ""
    echo "### Fixed"
    echo "- ..."
    echo ""
    echo "Then re-run this script."
    exit 1
fi

echo "Found CHANGELOG entry for v$VERSION."
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Notarize the app
# ============================================
echo "=== Step 1: Notarizing app ==="

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"YOUR_TEAM_ID\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com"
    echo ""
    read -p "Skip notarization for now? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZATION=true
    echo "WARNING: Skipping notarization. Users will see Gatekeeper warnings!"
else
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""

# ============================================
# Step 2: Create DMG
# ============================================
echo "=== Step 2: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

if [ -f "$DMG_PATH" ]; then
    echo "Removing existing DMG..."
    rm -f "$DMG_PATH"
fi

if ! command -v create-dmg &> /dev/null; then
    echo "ERROR: create-dmg not found. Install it with:"
    echo "  brew install create-dmg"
    echo ""
    echo "create-dmg is required so the DMG includes a drag-to-Applications"
    echo "shortcut — otherwise users have to open a second Finder window."
    exit 1
fi

# Optional background image. Drop a PNG at scripts/dmg-assets/background.png
# (540x380) and/or background@2x.png (1080x760) to get the Figma-style
# "drag the app onto Applications" arrow layout. If missing, create-dmg
# still lays out the icon + Applications shortcut — just without a backdrop.
DMG_BACKGROUND="$SCRIPT_DIR/dmg-assets/background.png"
CREATE_DMG_ARGS=(
    --volname "Ora"
    --window-size 540 380
    --icon-size 110
    --icon "ora.app" 140 190
    --app-drop-link 400 190
    --hide-extension "ora.app"
)
if [ -f "$DMG_BACKGROUND" ]; then
    echo "Using DMG background: $DMG_BACKGROUND"
    CREATE_DMG_ARGS+=(--background "$DMG_BACKGROUND")
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$APP_PATH"

echo "DMG created: $DMG_PATH"
echo ""

# ============================================
# Step 3: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 3: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 4: Sign DMG for Sparkle
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

SPARKLE_SIGN=""
POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ora-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "ERROR: Could not find Sparkle's sign_update tool."
    echo "Build the project in Xcode first to download the Sparkle SPM package."
    exit 1
fi

if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "ERROR: No Sparkle private key at $KEYS_DIR/eddsa_private_key"
    echo "Run ./scripts/generate-keys.sh first."
    exit 1
fi

echo "Signing DMG with Sparkle EdDSA key..."
SIGN_OUTPUT=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")

ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
DMG_LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ -z "$DMG_LENGTH" ]; then
    DMG_LENGTH=$(stat -f%z "$DMG_PATH")
fi

if [ -z "$ED_SIGNATURE" ]; then
    echo "ERROR: Could not parse signature from sign_update output:"
    echo "$SIGN_OUTPUT"
    exit 1
fi

echo "  Signature: $ED_SIGNATURE"
echo "  Length:    $DMG_LENGTH bytes"
echo ""

# ============================================
# Step 5: Generate single-item appcast.xml
# ============================================
echo "=== Step 5: Generating appcast.xml ==="

APPCAST_PATH="$RELEASE_DIR/appcast.xml"
# Stable asset name on GitHub so /releases/latest/download/Ora.dmg always
# resolves to the newest build. The local $DMG_PATH keeps its versioned
# name as an on-disk archive.
DMG_FILENAME="Ora.dmg"
UPLOAD_DMG_PATH="$BUILD_DIR/$DMG_FILENAME"
cp "$DMG_PATH" "$UPLOAD_DMG_PATH"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_FILENAME"
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$APPCAST_PATH" << EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
    <channel>
        <title>ora</title>
        <link>https://github.com/$GITHUB_REPO</link>
        <description>Most recent changes for ora.</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <link>https://github.com/$GITHUB_REPO/releases/tag/v$VERSION</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
            <pubDate>$PUB_DATE</pubDate>
            <enclosure
                url="$DOWNLOAD_URL"
                length="$DMG_LENGTH"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIGNATURE" />
        </item>
    </channel>
</rss>
EOF

echo "Appcast written to: $APPCAST_PATH"
echo ""

# ============================================
# Step 6: Create GitHub Release
# ============================================
echo "=== Step 6: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi

RELEASE_BODY="## ora v$VERSION

$RELEASE_NOTES

### Installation
1. Download \`$DMG_FILENAME\`
2. Open the DMG and drag Ora onto the Applications shortcut
3. Launch Ora from Applications

### Auto-updates
After installation, ora will automatically check for updates."

if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "Release v$VERSION already exists. Updating assets..."
    gh release upload "v$VERSION" "$UPLOAD_DMG_PATH" "$APPCAST_PATH" \
        --repo "$GITHUB_REPO" --clobber
    echo "Updating release notes from CHANGELOG.md..."
    gh release edit "v$VERSION" --repo "$GITHUB_REPO" --notes "$RELEASE_BODY"
else
    echo "Creating release v$VERSION..."
    gh release create "v$VERSION" "$UPLOAD_DMG_PATH" "$APPCAST_PATH" \
        --repo "$GITHUB_REPO" \
        --title "ora v$VERSION" \
        --notes "$RELEASE_BODY"
fi

echo ""
echo "GitHub release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo ""

echo "=== Release Complete ==="
echo ""
echo "Artifacts:"
echo "  - DMG:      $DMG_PATH"
echo "  - Appcast:  $APPCAST_PATH"
echo "  - GitHub:   https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo ""
echo "Sparkle feed URL (configured in ora/Info.plist):"
echo "  https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
