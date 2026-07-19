#!/bin/bash
# Packages HyperVibe.app into a distributable DMG.
# Usage: ./make_dmg.sh [version]   (default: 0.2.0)

set -e

VERSION="${1:-0.2.0}"
APP_BUNDLE="HyperVibe.app"
DMG_NAME="HyperVibe-${VERSION}.dmg"
STAGING="$(mktemp -d)/HyperVibe"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run ./build.sh && ./create_app_bundle.sh first."
    exit 1
fi

mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_NAME"
hdiutil create -volname "HyperVibe" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"
rm -rf "$(dirname "$STAGING")"

echo ""
echo "✓ Created $DMG_NAME"
