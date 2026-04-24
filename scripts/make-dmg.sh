#!/usr/bin/env bash
# make-dmg.sh — Create a distributable DMG from the assembled .app bundle.
# Requires: create-dmg  (brew install create-dmg)  OR  hdiutil fallback
# Usage: bash scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Piano Trainer"
DIST_DIR="$ROOT/dist"
BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION=$(defaults read "$ROOT/Resources/BundleInfo.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_NAME="PianoTrainer-$VERSION"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"

if [[ ! -d "$BUNDLE" ]]; then
    echo "Error: $BUNDLE not found — run scripts/build-app.sh first"
    exit 1
fi

rm -f "$DMG_PATH"

if command -v create-dmg &>/dev/null; then
    echo "==> create-dmg $DMG_NAME.dmg"
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$ROOT/Resources/AppIcon.icns" \
        --background "$ROOT/Resources/dmg-background.png" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 120 \
        --icon "$APP_NAME.app" 160 185 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 430 185 \
        "$DMG_PATH" \
        "$BUNDLE" 2>/dev/null \
    || {
        # Fallback: run without background (background image optional)
        echo "  (retrying without background image)"
        create-dmg \
            --volname "$APP_NAME" \
            --window-size 600 400 \
            --icon-size 120 \
            --icon "$APP_NAME.app" 160 185 \
            --hide-extension "$APP_NAME.app" \
            --app-drop-link 430 185 \
            "$DMG_PATH" \
            "$BUNDLE"
    }
else
    echo "==> hdiutil (install create-dmg for a prettier DMG)"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$BUNDLE" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo ""
echo "✓  $DMG_PATH"
echo "   Size: $(du -sh "$DMG_PATH" | cut -f1)"
