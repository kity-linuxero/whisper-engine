#!/usr/bin/env bash
# Stand-in for whisper-cli in tests: understands the flags whisper-engine
# passes, prints progress to stderr the way `whisper-cli -pp` does, and writes
# the -otxt/-oj/-osrt/-ovtt outputs. FAKE_STEP_DELAY controls speed;
# FAKE_FAIL=1 makes it exit non-zero halfway through.
set -euo pipefail
ALL_ARGS="$*"
OUT=""; IN=""; GPU=0; LANG_="es"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -of) OUT="$2"; shift 2 ;;
    -f) IN="$2"; shift 2 ;;
    -l) LANG_="$2"; shift 2 ;;
    -oved) GPU=1; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f "$IN" ]] || { echo "error: input file not found: $IN" >&2; exit 2; }
echo "$ALL_ARGS" > "$OUT.args"
if [[ $GPU == 1 ]]; then echo "whisper_ctx_init_openvino_encoder_with_state: OpenVINO model loaded" >&2; fi
for p in 10 30 50 70 90; do
  sleep "${FAKE_STEP_DELAY:-0.05}"
  echo "whisper_print_progress_callback: progress = ${p}%" >&2
  if [[ "${FAKE_FAIL:-0}" == 1 && $p == 50 ]]; then echo "boom" >&2; exit 3; fi
done
echo "[00:00:00.000 --> 00:00:02.000]   Hola mundo."
printf ' Hola mundo.\n Segunda linea.\n' > "$OUT.txt"
cat > "$OUT.json" <<JSON
{"result":{"language":"$LANG_"},"transcription":[
 {"timestamps":{"from":"00:00:00,000","to":"00:00:02,000"},"offsets":{"from":0,"to":2000},"text":" Hola mundo."},
 {"timestamps":{"from":"00:00:02,000","to":"00:00:03,500"},"offsets":{"from":2000,"to":3500},"text":" Segunda linea."}]}
JSON
printf '1\n00:00:00,000 --> 00:00:02,000\n Hola mundo.\n\n' > "$OUT.srt"
printf 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n Hola mundo.\n\n' > "$OUT.vtt"
