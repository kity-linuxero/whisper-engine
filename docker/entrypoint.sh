#!/bin/bash
# Baja los modelos que falten (WHISPER_MODELS=small,medium) y el VAD, carga el
# entorno de OpenVINO si la imagen lo trae, y arranca la API.
set -euo pipefail

: "${WHISPER_MODELS:=small}"
: "${WHISPER_DEFAULT_MODEL:=${WHISPER_MODELS%%,*}}"
export WHISPER_DEFAULT_MODEL

IFS=',' read -r -a models <<< "$WHISPER_MODELS"
for m in "${models[@]}"; do
  if [[ ! -s "$MODELS_DIR/ggml-$m.bin" ]]; then
    echo "[entrypoint] descargando modelo $m"
    bash /usr/local/bin/download-ggml-model.sh "$m" "$MODELS_DIR" >/tmp/download.log 2>&1 \
      || { cat /tmp/download.log >&2; echo "[entrypoint] no se pudo bajar el modelo $m" >&2; exit 1; }
  fi
done
if [[ ! -s "$VAD_MODEL" ]]; then
  echo "[entrypoint] descargando modelo VAD"
  curl -fsSL -o "$VAD_MODEL" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$(basename "$VAD_MODEL")"
fi

if [[ -f /opt/intel/openvino/setupvars.sh ]]; then
  # setupvars.sh de OpenVINO no soporta `set -u`.
  set +u
  # shellcheck disable=SC1091
  source /opt/intel/openvino/setupvars.sh >/dev/null
  set -u
  for m in "${models[@]}"; do
    [[ -s "$MODELS_DIR/ggml-$m-encoder-openvino.xml" ]] || \
      echo "[entrypoint] aviso: falta el IR de OpenVINO de '$m' (corre en CPU). Ver README: docker compose run --rm tools $m"
  done
fi

exec node /app/src/server.js
