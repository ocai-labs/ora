#!/bin/bash
# Generate EdDSA signing keys for Sparkle updates.
#
# Run this ONCE on the machine that will cut releases. The private key
# lives in .sparkle-keys/ (gitignored) and your macOS Keychain; the
# public key goes into ora/Info.plist as SUPublicEDKey.
#
# The public key in Info.plist MUST remain stable across releases once
# users install the app — regenerating keys means existing installs
# will reject all future updates (they verify signatures against the
# baked-in public key). Treat this as a one-time operation per
# release channel.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

echo "=== Sparkle EdDSA Key Generation ==="
echo ""

if [ -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "WARNING: Keys already exist at $KEYS_DIR"
    echo "If you regenerate keys, existing users won't be able to update!"
    read -p "Do you want to regenerate? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

mkdir -p "$KEYS_DIR"

# Locate Sparkle's generate_keys tool. It ships inside the SPM artifact
# bundle, which only exists after Xcode has resolved the Sparkle package
# once (open the project and build, or run dev-run.sh).
GENERATE_KEYS=""
POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ora-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
    "/usr/local/bin/generate_keys"
    "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path" ]; then
            GENERATE_KEYS="$path"
            break 2
        fi
    done
done

if [ -z "$GENERATE_KEYS" ]; then
    echo "Could not find Sparkle's generate_keys tool."
    echo ""
    echo "You need to:"
    echo "1. Open ora.xcodeproj in Xcode and build once (to download the"
    echo "   Sparkle SPM package), or"
    echo "2. Download Sparkle manually from:"
    echo "   https://github.com/sparkle-project/Sparkle/releases"
    echo ""
    exit 1
fi

echo "Using generate_keys from: $GENERATE_KEYS"
echo ""

echo "Generating EdDSA key pair..."
PUBLIC_KEY=$("$GENERATE_KEYS" | grep -oE '[A-Za-z0-9+/=]{40,}')

echo "Exporting private key to file..."
"$GENERATE_KEYS" -x "$KEYS_DIR/eddsa_private_key"

echo ""
echo "=== IMPORTANT ==="
echo ""
echo "Private key saved to: $KEYS_DIR/eddsa_private_key"
echo "The file is gitignored. The same key is also stored in your"
echo "macOS Keychain. KEEP BOTH SAFE — losing them means you can"
echo "never ship a Sparkle-verifiable update again."
echo ""
echo "Your PUBLIC key (paste into ora/Info.plist as SUPublicEDKey):"
echo ""
echo "  $PUBLIC_KEY"
echo ""

if ! grep -q ".sparkle-keys" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
    {
        echo ""
        echo "# Sparkle signing keys (NEVER commit these!)"
        echo ".sparkle-keys/"
    } >> "$PROJECT_DIR/.gitignore"
    echo "Added .sparkle-keys/ to .gitignore"
fi

echo ""
echo "Next steps:"
echo "1. Open ora/Info.plist and replace REPLACE_ME_WITH_OUTPUT_OF_generate-keys.sh"
echo "   with the public key above."
echo "2. Commit the updated ora/Info.plist (public key is safe to commit)."
echo "3. When ready to ship a release, run ./scripts/build.sh and then"
echo "   ./scripts/create-release.sh."
