#!/bin/bash
# Convierte el encoder de uno o más modelos a OpenVINO IR y lo deja en /models.
#   docker compose -f docker-compose.yml -f docker-compose.intel.yml run --rm tools small medium
set -euo pipefail
[[ $# -gt 0 ]] || { echo "uso: convert <modelo> [modelo...]" >&2; exit 1; }
for m in "$@"; do
  echo "[convert] $m"
  python convert-whisper-to-openvino.py --model "$m"
  mv "ggml-$m-encoder-openvino.xml" "ggml-$m-encoder-openvino.bin" /models/
done
# El engine corre como uid 10001 y OpenVINO escribe su caché al lado del modelo.
chown -R 10001:10001 /models
