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

# Copy icon if present
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

# ── 3. Ad-hoc code sign (no certificate required; lets Gatekeeper identify it) ─
echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$BUNDLE_DIR"

echo ""
echo "✓  $BUNDLE_DIR"
