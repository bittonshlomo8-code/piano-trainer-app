#!/usr/bin/env bash
# setup.sh — One-shot developer environment setup for Piano Trainer.
# Run once after cloning: bash scripts/setup.sh
set -euo pipefail

OK="\033[0;32m✓\033[0m"
WARN="\033[0;33m!\033[0m"
ERR="\033[0;31m✗\033[0m"

check() { echo -e "$OK $1"; }
warn()  { echo -e "$WARN $1"; }
fail()  { echo -e "$ERR $1"; exit 1; }

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Piano Trainer — Developer Setup          ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# ── macOS version ─────────────────────────────────────────────────────────────
MACOS=$(sw_vers -productVersion)
MAJOR=$(echo "$MACOS" | cut -d. -f1)
echo "macOS $MACOS"
if [[ $MAJOR -lt 13 ]]; then
    fail "macOS 13 (Ventura) or later is required. Found: $MACOS"
fi
check "macOS $MACOS"

# ── Xcode ─────────────────────────────────────────────────────────────────────
if ! xcodebuild -version &>/dev/null 2>&1; then
    warn "Xcode not found."
    echo ""
    echo "  Install Xcode from the App Store:"
    echo "  https://apps.apple.com/app/xcode/id497799835"
    echo ""
    echo "  Or with xcodes:"
    echo "    brew install robotsandpencils/made/xcodes"
    echo "    xcodes install --latest"
    echo ""
    fail "Please install Xcode and re-run this script."
fi
XCODE_VER=$(xcodebuild -version | head -1)
check "$XCODE_VER"

# Accept Xcode license (suppresses build warnings)
sudo xcodebuild -license accept 2>/dev/null || warn "Could not auto-accept Xcode license (run: sudo xcodebuild -license accept)"

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
check "Homebrew $(brew --version | head -1 | cut -d' ' -f2)"

# ── create-dmg ────────────────────────────────────────────────────────────────
if ! command -v create-dmg &>/dev/null; then
    echo "Installing create-dmg…"
    brew install create-dmg
fi
check "create-dmg $(create-dmg --version 2>/dev/null || echo installed)"

# ── xcodegen ─────────────────────────────────────────────────────────────────
if ! command -v xcodegen &>/dev/null; then
    echo "Installing xcodegen…"
    XGVER=$(curl -sL "https://api.github.com/repos/yonaskolb/XcodeGen/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
    mkdir -p /tmp/xcodegen-setup
    curl -sL "https://github.com/yonaskolb/XcodeGen/releases/download/$XGVER/xcodegen.zip" -o /tmp/xcodegen-setup/xcodegen.zip
    unzip -q /tmp/xcodegen-setup/xcodegen.zip -d /tmp/xcodegen-setup
    cp /tmp/xcodegen-setup/xcodegen/bin/xcodegen /usr/local/bin/xcodegen
    rm -rf /tmp/xcodegen-setup
fi
check "xcodegen $(xcodegen version)"

# ── Generate icon (if not already present) ───────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "Generating app icon…"
    swift "$ROOT/scripts/make-icon.swift"
else
    check "AppIcon.icns (already present)"
fi

# ── Generate Xcode project ────────────────────────────────────────────────────
echo "Generating Xcode project…"
cd "$ROOT"
xcodegen generate --spec project.yml --project . 2>&1 | tail -3
check "PianoTrainer.xcodeproj generated"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Setup complete!                          ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "  make open    — Open in Xcode"
echo "  make build   — Build release .app"
echo "  make dmg     — Build + package as DMG"
echo "  make release — Tag + push release to GitHub"
echo ""
