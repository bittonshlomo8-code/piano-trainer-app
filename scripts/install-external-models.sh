#!/usr/bin/env bash
# install-external-models.sh — installs the two external piano-transcription
# backends so the corresponding Piano Trainer modes stop running on the
# Piano-Focused fallback.
#
# Usage:
#   bash scripts/install-external-models.sh           # both
#   bash scripts/install-external-models.sh basic     # just Basic Pitch
#   bash scripts/install-external-models.sh bytedance # just ByteDance
#
# Exit 0 on success. Prints the path to the installed binary and the
# environment variable to export so Piano Trainer picks it up without a
# rebuild.

set -euo pipefail

OK="\033[0;32m✓\033[0m"
WARN="\033[0;33m!\033[0m"
ERR="\033[0;31m✗\033[0m"
log_ok()   { echo -e "$OK $1"; }
log_warn() { echo -e "$WARN $1"; }
log_err()  { echo -e "$ERR $1"; }

want="${1:-both}"

# ── Locate a Python in the supported range ───────────────────────────────────
# Basic Pitch's transitive deps build cleanly on CPython 3.10–3.11 (numpy /
# tflite-runtime / coremltools all ship wheels for those). Versions < 3.10
# lack `match` (used by basic-pitch internals) and >= 3.13 break old numpy.
SUPPORTED_PY=""
for cand in python3.11 python3.10; do
    if command -v "$cand" >/dev/null 2>&1; then
        SUPPORTED_PY="$(command -v "$cand")"
        break
    fi
done

if [[ -z "$SUPPORTED_PY" ]]; then
    log_err "No supported Python (3.10 or 3.11) found on PATH."
    echo "    brew install python@3.11"
    echo "  then re-run this script."
    exit 1
fi
log_ok "Using $SUPPORTED_PY ($($SUPPORTED_PY --version))"

VENV="$HOME/.piano-trainer/external-models"
mkdir -p "$(dirname "$VENV")"

if [[ ! -d "$VENV" ]]; then
    log_ok "Creating venv at $VENV"
    "$SUPPORTED_PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel

# ── Basic Pitch ───────────────────────────────────────────────────────────────
install_basic_pitch() {
    log_ok "Installing Spotify Basic Pitch …"
    "$VENV/bin/pip" install --quiet "basic-pitch"
    BIN="$VENV/bin/basic-pitch"
    if [[ ! -x "$BIN" ]]; then
        log_err "basic-pitch binary not produced at $BIN"
        exit 1
    fi
    log_ok "basic-pitch installed: $BIN"
    echo ""
    echo "  Add to your shell profile so Piano Trainer can find it:"
    echo "    export BASIC_PITCH_PATH=\"$BIN\""
    echo ""
}

# ── ByteDance Piano Transcription ─────────────────────────────────────────────
# Reference implementation is a Python module exposing a `PianoTranscription`
# class. We install it and ship a thin wrapper script that takes
# `wrapper <input.wav> <output.mid>` so the Swift adapter doesn't need to
# know about Python.
install_bytedance() {
    log_ok "Installing ByteDance Piano Transcription …"
    "$VENV/bin/pip" install --quiet "piano-transcription-inference"
    WRAPPER="$VENV/bin/piano-transcription"
    cat > "$WRAPPER" <<'PYEOF'
#!/usr/bin/env bash
# Auto-generated wrapper. Forwards (<input.wav> <output.mid>) to the
# piano-transcription-inference Python package.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/python" -m piano_transcription_inference.transcribe \
    --audio_path "$1" --output_midi_path "$2"
PYEOF
    chmod +x "$WRAPPER"
    if [[ ! -x "$WRAPPER" ]]; then
        log_err "ByteDance wrapper not executable at $WRAPPER"
        exit 1
    fi
    log_ok "ByteDance wrapper at: $WRAPPER"
    echo ""
    echo "  Add to your shell profile so Piano Trainer can find it:"
    echo "    export PIANO_TRANSCRIPTION_PATH=\"$WRAPPER\""
    echo ""
}

case "$want" in
    basic)     install_basic_pitch ;;
    bytedance) install_bytedance ;;
    both)      install_basic_pitch; install_bytedance ;;
    *) log_err "Unknown target: $want (use basic | bytedance | both)"; exit 1 ;;
esac

cat <<'NOTE'
Once the env vars are in your shell, restart Piano Trainer. The Run
Diagnostics → "Backend ran" line in the sidebar should change from
"Piano-Focused (fallback)" to the dedicated model name.
NOTE
