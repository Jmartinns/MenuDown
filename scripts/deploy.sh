#!/usr/bin/env bash
set -euo pipefail

# ─── MenuDown Deploy Script ────────────────────────────────────────────
# Usage: ./scripts/deploy.sh <version> "<release notes>"
# Example: ./scripts/deploy.sh 0.4.0 "Added new feature X, fixed bug Y"
#
# This script handles the full release pipeline:
#   1. Bump version in Info.plist
#   2. Clean archive with Developer ID signing
#   3. Export archive
#   4. Notarize and staple
#   5. Create DMG with Applications symlink
#   6. Sign DMG for Sparkle auto-update
#   7. Update appcast.xml
#   8. Git commit, push, and create GitHub release
# ────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PLIST="MenuDown/App/Info.plist"
PROJECT="MenuDown.xcodeproj"
SCHEME="MenuDown"
EXPORT_OPTS="ExportOptions.plist"
APPCAST="docs/appcast.xml"
TEAM_ID="X3F5N7Z2MF"
KEYCHAIN_PROFILE="MenuDown-notarize"
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData/MenuDown-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)"

# ─── Validate arguments ────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <version> \"<release notes>\""
    echo "Example: $0 0.4.0 \"Added feature X, fixed bug Y\""
    exit 1
fi

VERSION="$1"
NOTES="$2"

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in X.Y.Z format (got: $VERSION)"
    exit 1
fi

# Validate sign_update tool exists
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
    echo "Error: Sparkle sign_update tool not found. Build the project first to fetch SPM packages."
    exit 1
fi

# Validate gh CLI
if ! command -v gh &>/dev/null; then
    echo "Error: GitHub CLI (gh) not found. Install with: brew install gh"
    exit 1
fi

# ─── Compute build number ──────────────────────────────────────────────

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
BUILD=$((CURRENT_BUILD + 1))

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  MenuDown Deploy                                 ║"
echo "║  Version: $VERSION (build $BUILD)                "
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Release notes:"
echo "  $NOTES"
echo ""
read -p "Continue? [Y/n] " confirm
if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
    echo "Aborted."
    exit 0
fi

# ─── Step 1: Bump version ──────────────────────────────────────────────

echo ""
echo "▸ Step 1/8: Bumping version to $VERSION (build $BUILD)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "  ✓ Info.plist updated"

# ─── Step 2: Archive ───────────────────────────────────────────────────

echo ""
echo "▸ Step 2/8: Archiving..."
rm -rf build
mkdir -p build

xcodebuild clean archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath build/MenuDown.xcarchive \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    -quiet

echo "  ✓ Archive succeeded"

# ─── Step 3: Export ────────────────────────────────────────────────────

echo ""
echo "▸ Step 3/8: Exporting..."
xcodebuild -exportArchive \
    -archivePath build/MenuDown.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -quiet 2>/dev/null || \
xcodebuild -exportArchive \
    -archivePath build/MenuDown.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist "$EXPORT_OPTS"

echo "  ✓ Export succeeded"

# ─── Step 4: Notarize ─────────────────────────────────────────────────

echo ""
echo "▸ Step 4/8: Notarizing..."
ditto -c -k --keepParent build/export/MenuDown.app build/MenuDown.zip

xcrun notarytool submit build/MenuDown.zip \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "  ✓ Notarization accepted"

# ─── Step 5: Staple ───────────────────────────────────────────────────

echo ""
echo "▸ Step 5/8: Stapling..."
xcrun stapler staple build/export/MenuDown.app
echo "  ✓ Stapled"

# ─── Step 6: Create DMG ───────────────────────────────────────────────

echo ""
echo "▸ Step 6/8: Creating DMG..."
rm -rf build/dmg-staging
mkdir -p build/dmg-staging
cp -R build/export/MenuDown.app build/dmg-staging/
ln -s /Applications build/dmg-staging/Applications

hdiutil create build/MenuDown.dmg \
    -volname "MenuDown" \
    -srcfolder build/dmg-staging \
    -ov -format UDZO \
    -quiet

echo "  ✓ DMG created"

# ─── Step 7: Sign for Sparkle & update appcast ────────────────────────

echo ""
echo "▸ Step 7/8: Signing for Sparkle & updating appcast..."
SIGN_OUTPUT=$("$SIGN_UPDATE" build/MenuDown.dmg)
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)

if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
    echo "Error: Failed to parse sign_update output: $SIGN_OUTPUT"
    exit 1
fi

PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Format release notes as HTML list items
NOTES_HTML=""
IFS=$'\n'
# Split on commas or newlines for multi-item notes
for note in $(echo "$NOTES" | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
    if [[ -n "$note" ]]; then
        NOTES_HTML="$NOTES_HTML          <li>$note</li>\n"
    fi
done
unset IFS

NEW_ITEM="    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
$(echo -e "$NOTES_HTML")        </ul>
      ]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url=\"https://github.com/Jmartinns/MenuDown/releases/download/v$VERSION/MenuDown.dmg\"
        sparkle:edSignature=\"$ED_SIGNATURE\"
        length=\"$LENGTH\"
        type=\"application/octet-stream\"
      />
    </item>"

# Insert new item after <language>en</language>
ESCAPED_ITEM=$(echo "$NEW_ITEM" | sed 's/[&/\]/\\&/g')
sed -i '' "/<language>en<\/language>/a\\
$NEW_ITEM
" "$APPCAST"

echo "  ✓ appcast.xml updated (signature: ${ED_SIGNATURE:0:20}...)"

# ─── Step 8: Git & GitHub release ─────────────────────────────────────

echo ""
echo "▸ Step 8/8: Committing, pushing & creating GitHub release..."
git add -A
git commit -m "v$VERSION: $NOTES"
git push

gh release create "v$VERSION" build/MenuDown.dmg \
    --title "v$VERSION" \
    --notes "$NOTES"

RELEASE_URL="https://github.com/Jmartinns/MenuDown/releases/tag/v$VERSION"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Deploy complete!                                ║"
echo "║  Version: $VERSION (build $BUILD)                "
echo "║  Release: $RELEASE_URL"
echo "╚══════════════════════════════════════════════════╝"
echo ""
