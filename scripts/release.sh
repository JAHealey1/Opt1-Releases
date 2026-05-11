#!/usr/bin/env bash
# Opt1 manual release pipeline.
#
# Replicates what .github/workflows/release.yml does on a tag push, so the
# very first release can be cut from the dev Mac and the same script is the
# emergency fallback if CI ever breaks.
#
# Steps: archive -> export -> DMG -> notarize -> staple -> spctl verify ->
# sign_update -> emit appcast snippet.
#
# Usage:
#   APPLE_ID=you@example.com \
#   APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#   ./scripts/release.sh 1.0.0
#
# Optional env:
#   APPLE_TEAM_ID            (default: 2KFN672Z9S)
#   SKIP_NOTARIZE=1          - dry-run that stops before submitting to Apple
#   KEEP_ARCHIVE=1           - retain build/Opt1.xcarchive for inspection
#
# Prerequisites on the runner / dev Mac:
#   - Xcode with Developer ID Application cert in the login Keychain
#   - Sparkle EdDSA private key in the login Keychain (or env override below)
#   - `create-dmg` from Homebrew (`brew install create-dmg`)

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>   (e.g. $0 1.0.0)"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be semver MAJOR.MINOR.PATCH (got: $VERSION)"
  exit 1
fi

: "${APPLE_ID:?Set APPLE_ID env var (Apple Developer email)}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD env var}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-2KFN672Z9S}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Opt1"
PROJECT="$REPO_ROOT/Opt1.xcodeproj"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"

BUILD_DIR="$REPO_ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/Opt1.xcarchive"
EXPORT_DIR="$BUILD_DIR/Export"
# `create-dmg` packages the entire source directory we hand it. xcodebuild
# -exportArchive drops sibling files into EXPORT_DIR (DistributionSummary.plist,
# ExportOptions.plist, Packaging.log) that we don't want shipping to users, so
# we stage just Opt1.app into a clean directory before building the DMG.
DMG_STAGE_DIR="$BUILD_DIR/dmg-staging"
DIST_DIR="$BUILD_DIR/dist"
DMG="$DIST_DIR/Opt1-$VERSION.dmg"

mkdir -p "$DIST_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG_STAGE_DIR"

# --- preflight ----------------------------------------------------------------

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found. Install it with: brew install create-dmg"
  exit 1
fi

# Use Xcode.app (not the bare command-line tools) for archiving.
if ! /usr/bin/xcrun -f xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not available. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

echo "==> Releasing Opt1 $VERSION"
echo "    team:   $APPLE_TEAM_ID"
echo "    apple:  $APPLE_ID"
echo "    output: $DMG"

# --- 1. archive ---------------------------------------------------------------

echo "==> [1/7] Archive (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  -quiet

# --- 2. export ----------------------------------------------------------------

echo "==> [2/7] Export Developer ID-signed .app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -quiet

APP_BUNDLE="$EXPORT_DIR/Opt1.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Exported .app missing at $APP_BUNDLE"
  exit 1
fi

# Snapshot the resolved version fields from the archived bundle BEFORE cleanup,
# and validate they match the version we were invoked with. Catches the
# common foot-gun of tagging vX.Y.Z without bumping MARKETING_VERSION /
# CURRENT_PROJECT_VERSION in pbxproj first.
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion"             "$APP_PLIST")

if [[ "$SHORT_VERSION" != "$VERSION" ]]; then
  echo
  echo "VERSION MISMATCH: invoked with $VERSION but the built app reports $SHORT_VERSION"
  echo "  Bump MARKETING_VERSION in Opt1.xcodeproj (both Debug and Release configs)"
  echo "  to '$VERSION', commit, and try again."
  exit 1
fi

# Sanity-check signing flags before we even bother with notarization.
codesign -d -vv "$APP_BUNDLE" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier=$APPLE_TEAM_ID|flags=.*runtime" >/dev/null || {
  echo "Code signing sanity check failed. Run: codesign -d -vvv \"$APP_BUNDLE\""
  exit 1
}

# --- 3. dmg -------------------------------------------------------------------

echo "==> [3/7] Build DMG"
rm -f "$DMG"

# Stage a directory that contains only Opt1.app — anything else here ends up
# in the user-visible DMG window.
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/Opt1.app"

create-dmg \
  --volname "Opt1 $VERSION" \
  --window-size 540 360 \
  --icon-size 96 \
  --icon "Opt1.app" 140 170 \
  --app-drop-link 400 170 \
  --no-internet-enable \
  "$DMG" \
  "$DMG_STAGE_DIR" \
  >/dev/null

# create-dmg does not sign the disk image, but Gatekeeper / spctl expects a
# Developer ID Application code signature on the .dmg itself (notarisation +
# stapling alone don't add one). Without this step `spctl --assess` reports
# "no usable signature" and Safari's quarantine bit on the download will
# block users from mounting the DMG without a manual override.
echo "==> [3.5/7] Code-sign DMG with Developer ID Application"
codesign \
  --force \
  --sign "Developer ID Application" \
  --timestamp \
  "$DMG"

# --- 4. notarize --------------------------------------------------------------

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> [4/7] SKIPPED notarize (SKIP_NOTARIZE=1)"
else
  echo "==> [4/7] Notarize (this can take several minutes)"
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

  # --- 5. staple ------------------------------------------------------------
  echo "==> [5/7] Staple ticket onto DMG"
  xcrun stapler staple "$DMG"

  # --- 6. verify ------------------------------------------------------------
  # `-t install` is for .pkg installers; for a stapled, code-signed .dmg we
  # have to assess it as an "open"-style document and tell Gatekeeper to use
  # the primary (notarisation) signature.
  echo "==> [6/7] spctl Gatekeeper verification (DMG)"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" \
    2>&1 | tee "$DIST_DIR/spctl-dmg-$VERSION.log"

  # Also do a structural integrity check on the .app inside the export dir.
  # We don't `spctl -t exec` it because the .app itself isn't independently
  # stapled (only the DMG is) and an offline assessment would fail. The
  # codesign verify confirms the bundle is intact, the seal hasn't been
  # broken, and every nested bundle is also signed.
  echo "==> [6/7] codesign verify (.app integrity)"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# --- 7. EdDSA-sign for Sparkle ------------------------------------------------

echo "==> [7/7] Sign update with Sparkle's sign_update"
SIGN_UPDATE=$(find "$DERIVED" -path "*Sparkle*" -name sign_update -type f 2>/dev/null | head -1)
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "sign_update tool not found under $DERIVED."
  echo "Falling back to a global search of DerivedData..."
  SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*Sparkle*" -name sign_update -type f 2>/dev/null | head -1)
fi
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "Could not locate Sparkle's sign_update binary."
  exit 1
fi

# sign_update -f requires a real file path. In CI we materialize the key to a
# temp file and remove it on exit; locally we let sign_update read the key
# from the login Keychain by passing no flag.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEY_FILE=$(mktemp)
  trap 'rm -f "$KEY_FILE"' EXIT
  printf "%s" "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"
  SIGNATURE_LINE=$("$SIGN_UPDATE" -f "$KEY_FILE" "$DMG")
else
  SIGNATURE_LINE=$("$SIGN_UPDATE" "$DMG")
fi

DMG_LENGTH=$(stat -f%z "$DMG")
DMG_SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')

# sign_update prints, e.g.: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$(echo "$SIGNATURE_LINE" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')

if [[ -z "$ED_SIGNATURE" ]]; then
  echo "Failed to extract EdDSA signature from sign_update output:"
  echo "$SIGNATURE_LINE"
  exit 1
fi

# --- artifact summary ---------------------------------------------------------

cat > "$DIST_DIR/release-$VERSION.json" <<EOF
{
  "version": "$VERSION",
  "shortVersion": "$SHORT_VERSION",
  "build": $BUILD_NUMBER,
  "dmg": "Opt1-$VERSION.dmg",
  "length": $DMG_LENGTH,
  "sha256": "$DMG_SHA256",
  "edSignature": "$ED_SIGNATURE"
}
EOF

if [[ "${KEEP_ARCHIVE:-0}" != "1" ]]; then
  rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG_STAGE_DIR"
fi

echo
echo "================== RELEASE READY =================="
echo "DMG:       $DMG"
echo "Version:   $SHORT_VERSION (build $BUILD_NUMBER)"
echo "Length:    $DMG_LENGTH bytes"
echo "SHA256:    $DMG_SHA256"
echo "EdDSA:     $ED_SIGNATURE"
echo "Metadata:  $DIST_DIR/release-$VERSION.json"
echo
echo "Next steps:"
echo "  - Update appcast.xml in Opt1-Releases:"
echo "      python3 scripts/update_appcast.py $VERSION \\"
echo "          --length $DMG_LENGTH \\"
echo "          --signature '$ED_SIGNATURE' \\"
echo "          --notes release-notes/$VERSION.html \\"
echo "          --appcast /path/to/Opt1-Releases/appcast.xml"
echo "  - Upload \$DMG as the asset of release v$VERSION on Opt1-Releases."
echo "==================================================="
