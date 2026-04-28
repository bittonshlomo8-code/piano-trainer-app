#!/usr/bin/env bash
# setup-transcription-deps.sh — install everything the three transcription
# pipelines need, into a self-contained per-repo location.
#
# Outputs:
#   .transcription-venv/                         the Python venv
#   tools/transcription/bin/basic-pitch-wrapper  Basic Pitch wrapper
#   tools/transcription/bin/demucs-wrapper       Demucs source-separation wrapper
#   tools/transcription/bin/piano-transcription-wrapper
#                                                ByteDance (Qiuqiang Kong)
#                                                piano transcription wrapper
#
# After running this, the Swift app finds the wrappers automatically —
# `ExternalCommandRunner.locate(...)` searches `tools/transcription/bin`
# relative to the repo root before falling back to PATH.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.transcription-venv"
BIN_DIR="$ROOT_DIR/tools/transcription/bin"

mkdir -p "$BIN_DIR"

# ── 1. Resolve a Python 3.10–3.12 ─────────────────────────────────────────────
# Basic Pitch pins numpy<1.24 (no 3.13 wheels) and several deps don't
# build under 3.13 either. We hunt for 3.12 first, then 3.11, then 3.10.
# If none is found we fall back to a portable build from python-build-standalone.

PY=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then
    PY="$(command -v "$cand")"
    break
  fi
done

# Try common Homebrew/python.org locations not on PATH.
if [ -z "$PY" ]; then
  for cand in \
      /opt/homebrew/opt/python@3.12/bin/python3.12 \
      /opt/homebrew/opt/python@3.11/bin/python3.11 \
      /opt/homebrew/opt/python@3.10/bin/python3.10 \
      /usr/local/opt/python@3.12/bin/python3.12 \
      /usr/local/opt/python@3.11/bin/python3.11 \
      /usr/local/opt/python@3.10/bin/python3.10 \
      /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
      /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 \
      /Library/Frameworks/Python.framework/Versions/3.10/bin/python3.10; do
    if [ -x "$cand" ]; then
      PY="$cand"
      break
    fi
  done
fi

# Last resort: download a portable python-build-standalone Python 3.11.
if [ -z "$PY" ]; then
  echo "Python 3.10–3.12 not found on PATH or in standard locations."
  echo "Downloading a portable Python 3.11 from astral-sh/python-build-standalone…"
  PORT_DIR="$ROOT_DIR/.python-portable"
  mkdir -p "$PORT_DIR"
  ARCH="x86_64-apple-darwin"
  if [ "$(uname -m)" = "arm64" ]; then ARCH="aarch64-apple-darwin"; fi
  TARBALL="cpython-3.11.13+20250918-${ARCH}-install_only.tar.gz"
  URL="https://github.com/astral-sh/python-build-standalone/releases/download/20250918/${TARBALL}"
  if [ ! -d "$PORT_DIR/python" ]; then
    curl -fsSL -o "$PORT_DIR/$TARBALL" "$URL"
    tar -xzf "$PORT_DIR/$TARBALL" -C "$PORT_DIR"
    rm -f "$PORT_DIR/$TARBALL"
  fi
  PY="$PORT_DIR/python/bin/python3.11"
fi

if [ ! -x "$PY" ]; then
  echo "FATAL: could not resolve a usable Python 3.10–3.12."
  exit 1
fi
echo "Using Python: $PY ($("$PY" --version 2>&1))"

# ── 2. ffmpeg — Demucs needs it for non-WAV inputs ───────────────────────────
# Optional for the WAV-only path used by Basic Pitch + ByteDance, but Demucs
# loads via torchaudio which falls back to ffmpeg for many formats.
if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "ffmpeg not found, installing via Homebrew…"
    brew install ffmpeg || echo "Warning: brew install ffmpeg failed; continuing — Demucs will work for WAV input."
  else
    echo "ffmpeg not found and Homebrew is not installed."
    echo "Demucs only needs ffmpeg for non-WAV inputs; the app pre-converts to WAV so this is usually fine."
    echo "If you want full format coverage: install Homebrew, then run 'brew install ffmpeg'."
  fi
fi

# ── 3. venv + base toolchain ─────────────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
  "$PY" -m venv "$VENV_DIR"
fi
# Pin setuptools<80 because resampy (a librosa dep) imports `pkg_resources`
# which was unbundled in setuptools 80+.
"$VENV_DIR/bin/python" -m pip install --upgrade "pip" "setuptools<80" "wheel"

# ── 4. Basic Pitch (ONNX) ────────────────────────────────────────────────────
# `--only-binary=llvmlite,numba` because llvmlite has no source build path
# under modern macOS without the full Xcode CLT and we don't need it.
"$VENV_DIR/bin/python" -m pip install --only-binary=llvmlite,numba "basic-pitch[onnx]"

# ── 5. Demucs (CPU torch is fine — htdemucs is fast enough to run locally) ──
"$VENV_DIR/bin/python" -m pip install demucs

# Pin numpy<2 — torch and the coremltools subgraph in basic_pitch were
# compiled against numpy 1.x and emit "_ARRAY_API not found" warnings (and
# in some paths actually crash) under numpy 2.x. Done after demucs install
# so demucs's transitive numpy gets downgraded.
"$VENV_DIR/bin/python" -m pip install "numpy<2"

# ── 6. ByteDance piano transcription ────────────────────────────────────────
# The PyPI package name is `piano_transcription_inference`. It depends on
# torch/torchaudio (already pulled in by Demucs) and downloads a ~500 MB
# model checkpoint on first use (cached under ~/piano_transcription_inference_data
# by default, or PIANO_TRANSCRIPTION_DATA_DIR if set).
"$VENV_DIR/bin/python" -m pip install piano_transcription_inference || true

# Verify the import works — if it doesn't, the wrapper would silently fall
# through and the app would think the backend was available when it isn't.
if ! "$VENV_DIR/bin/python" -c "import piano_transcription_inference" 2>/dev/null; then
  echo "piano_transcription_inference failed to import via PyPI install."
  echo "Attempting source install from GitHub (qiuqiangkong/piano_transcription_inference)…"
  "$VENV_DIR/bin/python" -m pip install \
      "git+https://github.com/qiuqiangkong/piano_transcription_inference.git"
  "$VENV_DIR/bin/python" -c "import piano_transcription_inference" || {
    echo "FATAL: piano_transcription_inference still cannot be imported."
    exit 2
  }
fi

# ── 7. Wrappers ──────────────────────────────────────────────────────────────
# Each wrapper sources the venv and runs the model with a positional CLI
# the Swift adapter calls directly. Wrappers are versioned on disk so a
# future model swap doesn't require an app rebuild.

cat > "$BIN_DIR/basic-pitch-wrapper" <<'SH'
#!/usr/bin/env bash
# basic-pitch-wrapper <input_audio> <output_dir>
#   Runs Spotify Basic Pitch via the venv's `basic-pitch` console script,
#   writing <basename>_basic_pitch.mid into <output_dir>.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENV_DIR="$ROOT_DIR/.transcription-venv"

INPUT="$1"
OUTPUT_DIR="$2"
mkdir -p "$OUTPUT_DIR"

# Use the console script directly — basic_pitch has no __main__.py so
# `python -m basic_pitch` does not work.
exec "$VENV_DIR/bin/basic-pitch" \
  --save-midi --model-serialization onnx \
  "$OUTPUT_DIR" "$INPUT"
SH
chmod +x "$BIN_DIR/basic-pitch-wrapper"

cat > "$BIN_DIR/demucs-wrapper" <<'SH'
#!/usr/bin/env bash
# demucs-wrapper <input_audio> <output_dir>
#   Splits the input into htdemucs two-stems "other" / "no_other" and writes
#   them into <output_dir>/htdemucs/<basename>/{other,no_other}.wav.
#   The Swift app uses `no_other.wav` as the piano-isolated stem.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENV_DIR="$ROOT_DIR/.transcription-venv"

INPUT="$1"
OUTPUT_DIR="$2"
mkdir -p "$OUTPUT_DIR"

# htdemucs --two-stems other emits:
#   no_other.wav  → everything except "other" (= drums + bass + vocals stripped)
#   other.wav     → just "other"
# For piano isolation we want everything *except* drums/bass/vocals, which
# is closer to `no_other.wav` than to a literal piano stem.
exec "$VENV_DIR/bin/python" -m demucs.separate \
  -n htdemucs --two-stems other \
  -o "$OUTPUT_DIR" \
  "$INPUT"
SH
chmod +x "$BIN_DIR/demucs-wrapper"

cat > "$BIN_DIR/piano-transcription-wrapper" <<'SH'
#!/usr/bin/env bash
# piano-transcription-wrapper <input_audio> <output_midi>
#   Runs Qiuqiang Kong / ByteDance high-resolution piano transcription.
#   The model auto-downloads on first run (~500 MB) into the cache dir
#   ($PIANO_TRANSCRIPTION_DATA_DIR or ~/piano_transcription_inference_data).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENV_DIR="$ROOT_DIR/.transcription-venv"

INPUT="$1"
OUTPUT_MIDI="$2"

exec "$VENV_DIR/bin/python" - "$INPUT" "$OUTPUT_MIDI" <<'PY'
import sys
from pathlib import Path

input_audio = sys.argv[1]
output_midi = sys.argv[2]

try:
    from piano_transcription_inference import PianoTranscription, sample_rate
except Exception as e:
    print(f"Failed to import piano_transcription_inference: {e}", file=sys.stderr)
    sys.exit(2)

# `piano_transcription_inference.load_audio` routes through audioread which
# needs ffmpeg/gstreamer/CoreAudio backends. We bypass it via librosa
# (already in the venv) — the input WAV is pre-normalized by the Swift
# kit's AudioNormalizer so a direct librosa.load is correct.
try:
    import librosa
    audio, _ = librosa.load(input_audio, sr=sample_rate, mono=True)
except Exception as e:
    import traceback
    print(f"audio load failed: {type(e).__name__}: {e}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    sys.exit(5)

try:
    transcriptor = PianoTranscription(device="cpu")
    transcriptor.transcribe(audio, output_midi)
except Exception as e:
    import traceback
    print(f"piano_transcription_inference failed: {type(e).__name__}: {e}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    sys.exit(3)

if not Path(output_midi).exists():
    print(f"Expected MIDI was not created: {output_midi}", file=sys.stderr)
    sys.exit(4)
PY
SH
chmod +x "$BIN_DIR/piano-transcription-wrapper"

# ── 8. Final summary ─────────────────────────────────────────────────────────
echo
echo "Transcription dependencies installed. Wrappers:"
ls -1 "$BIN_DIR"
echo
echo "Verify installation:"
echo "  $BIN_DIR/basic-pitch-wrapper           # prints CLI usage on no-args"
echo "  $BIN_DIR/demucs-wrapper                # prints CLI usage on no-args"
echo "  $BIN_DIR/piano-transcription-wrapper   # prints model-load error if no args"
