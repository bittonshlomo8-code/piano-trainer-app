#!/usr/bin/env bash
# build-app.sh — Compile Piano Trainer and assemble the .app bundle.
# Usage: bash scripts/build-app.sh [--build-path PATH]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Piano Trainer"
BINARY_NAME="MacApp"
DIST_DIR="$ROOT/dist"
BUILD_PATH="${BUILD_PATH:-$ROOT/.build}"
RELEASE_BIN="$BUILD_PATH/release/$BINARY_NAME"
BUNDLE_DIR="$DIST_DIR/$APP_NAME.app"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "==> swift build -c release"
cd "$ROOT"
swift build -c release --build-path "$BUILD_PATH"

# ── 2. Assemble bundle ────────────────────────────────────────────────────────
echo "==> Assembling $APP_NAME.app"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$RELEASE_BIN" "$BUNDLE_DIR/Contents/MacOS/$BINARY_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$BINARY_NAME"
cp "$ROOT/Resources/BundleInfo.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Stamp a unique build number so local rebuilds are visibly distinct in the UI.
# Format: YYYYMMDDHHMM. CI releases override this with the workflow run number.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE_DIR/Contents/Info.plist"
echo "==> Stamped CFBundleVersion = $BUILD_NUMBER"

# Copy icon if present
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

# Bundled piano SoundFont — copied directly to Contents/Resources so the app
# can locate it via Bundle.main.url(forResource:withExtension:). The file is
# also discoverable via Bundle.module during `swift run` thanks to the
# resource declaration in Package.swift.
if [[ -f "$ROOT/Sources/MacApp/Resources/PianoSoundFont.sf2" ]]; then
    cp "$ROOT/Sources/MacApp/Resources/PianoSoundFont.sf2" \
       "$BUNDLE_DIR/Contents/Resources/PianoSoundFont.sf2"
fi

# Copy the SwiftPM-generated resource bundle (if any) alongside the binary so
# Bundle.module continues to resolve when the app runs from inside the bundle.
RESOURCE_BUNDLE="$BUILD_PATH/release/MacApp_MacApp.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$BUNDLE_DIR/Contents/Resources/"
fi

# ── 3. Ad-hoc code sign (no certificate required; lets Gatekeeper identify it) ─
echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$BUNDLE_DIR"

echo ""
echo "✓  $BUNDLE_DIR"
