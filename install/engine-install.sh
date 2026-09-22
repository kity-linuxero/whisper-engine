#!/usr/bin/env bash
# whisper-engine — instalador nativo para Debian 12/13 (LXC, VM o bare metal).
#
#   sudo ./install/engine-install.sh --device intel --models small,medium
#
# Compila whisper.cpp (CPU u OpenVINO), instala el runtime de Intel si hace
# falta, baja los modelos, instala la API como servicio systemd y la prueba.
# Es idempotente: se puede volver a correr (con --upgrade para recompilar y
# actualizar la app) sin perder el token ni los modelos ya bajados.
set -euo pipefail

# ---------------------------------------------------------------- defaults
DEVICE="cpu"                # cpu | intel
MODELS="small"
INTEL_RUNTIME="auto"        # auto | legacy | current
WHISPER_REF="v1.9.4"
LANGUAGE="es"
PORT="8080"
UPGRADE=0
SKIP_TEST=0
APP_SRC=""                  # checkout local de whisper-engine; si falta, se clona APP_REPO
APP_REPO="https://github.com/kity-linuxero/whisper-engine.git"
APP_REF="main"

WHISPER_DIR=/opt/whisper.cpp
APP_DIR=/opt/whisper-engine
DATA_DIR=/var/lib/whisper-engine
MODELS_DIR=$DATA_DIR/models
JOBS_DIR=$DATA_DIR/jobs
ETC_DIR=/etc/whisper-engine
ENV_FILE=$ETC_DIR/engine.env
SVC_USER=whisper-engine
OPENVINO_DIR=/opt/intel/openvino
OPENVINO_URL="https://storage.openvinotoolkit.org/repositories/openvino/packages/2025.4/linux/openvino_toolkit_ubuntu24_2025.4.0.20398.8fdad55727d_x86_64.tgz"
VAD_FILE=ggml-silero-v5.1.2.bin
# Último compute-runtime con soporte para iGPU Gen9–Gen11 (Skylake..Ice Lake).
NEO_LEGACY=(
  "https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-core_1.0.17537.24_amd64.deb"
  "https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-opencl_1.0.17537.24_amd64.deb"
  "https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb"
  "https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/intel-level-zero-gpu-legacy1_1.5.30872.36_amd64.deb"
  "https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/libigdgmm12_22.5.0_amd64.deb"
)

usage() {
  cat <<EOF
Uso: $0 [opciones]

  --device cpu|intel         Motor de cómputo (default: cpu). "intel" = iGPU vía OpenVINO.
  --models small,medium      Modelos a bajar (default: small). Ver: tiny base small medium large-v3-turbo ...
  --language es|auto|<iso>   Idioma por defecto (default: es).
  --port 8080                Puerto de la API (default: 8080).
  --intel-runtime auto|legacy|current
                             Driver OpenCL de Intel. legacy = Gen9-Gen11 (ej. HD 630),
                             current = Gen12+ (Xe, Arc). auto detecta por PCI ID.
  --whisper-ref v1.9.4       Tag/commit de whisper.cpp a compilar.
  --app-src DIR              Usar este checkout de whisper-engine en vez de clonarlo.
  --app-ref main             Rama/tag de whisper-engine a clonar.
  --upgrade                  Recompilar whisper.cpp y actualizar la app aunque ya existan.
  --skip-test                No correr la prueba de transcripción al final.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --intel-runtime) INTEL_RUNTIME="$2"; shift 2 ;;
    --whisper-ref) WHISPER_REF="$2"; shift 2 ;;
    --app-src) APP_SRC="$2"; shift 2 ;;
    --app-ref) APP_REF="$2"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

msg()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Correr como root."
[[ "$DEVICE" =~ ^(cpu|intel)$ ]] || die "--device tiene que ser cpu o intel"
[[ "$INTEL_RUNTIME" =~ ^(auto|legacy|current)$ ]] || die "--intel-runtime tiene que ser auto, legacy o current"
# shellcheck disable=SC1091
. /etc/os-release
[[ "$ID" == "debian" && "$VERSION_ID" =~ ^(12|13)$ ]] || warn "Probado en Debian 12/13; detectado $PRETTY_NAME."
export DEBIAN_FRONTEND=noninteractive
# Debian 13 monta /tmp como tmpfs (en RAM): el venv de PyTorch para convertir
# modelos (~3.5 GB) y las descargas grandes van a disco.
export TMPDIR=/var/tmp

# Si el script se corre desde un checkout, usar ese código.
if [[ -z "$APP_SRC" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$here/package.json" ]] && grep -q '"name": "whisper-engine"' "$here/package.json"; then
    APP_SRC="$here"
  fi
fi

# ---------------------------------------------------------------- paquetes
msg "Instalando dependencias del sistema"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential cmake git ffmpeg curl ca-certificates openssl python3 python3-venv rsync >/dev/null

node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0; }
if [[ "$(node_major)" -lt 20 ]]; then
  apt-get install -y -qq --no-install-recommends nodejs npm >/dev/null || true
fi
if [[ "$(node_major)" -lt 20 ]]; then
  msg "Node.js del sistema es < 20; instalando Node 20 desde NodeSource"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq && apt-get install -y -qq nodejs >/dev/null
fi
echo "node $(node -v)"

# ---------------------------------------------------------------- Intel / OpenVINO
detect_intel_runtime() {
  local id
  id="$(cat /sys/class/drm/renderD128/device/device 2>/dev/null || true)"
  id="${id#0x}"; id="${id,,}"
  if [[ -z "$id" ]]; then
    warn "No se pudo leer el PCI ID de la GPU; asumo runtime 'current'."
    echo current; return
  fi
  # Gen9 (Skylake, Kaby/Coffee/Comet/Whiskey/Amber Lake, Apollo/Gemini Lake) y
  # Gen11 (Ice Lake, Elkhart/Jasper Lake) → rama legacy1. Todo lo demás → current.
  case "$id" in
    19*|59*|3e*|3ea*|9b*|87*|5a*|0a8*|318*|8a*|45*|4e*) echo legacy ;;
    *) echo current ;;
  esac
}

if [[ "$DEVICE" == "intel" ]]; then
  if [[ ! -e /dev/dri/renderD128 ]]; then
    warn "/dev/dri/renderD128 no existe: se instala todo, pero hasta que se pase la iGPU al"
    warn "contenedor/VM la transcripción va a correr por CPU."
  fi
  [[ "$INTEL_RUNTIME" == "auto" ]] && INTEL_RUNTIME="$(detect_intel_runtime)"
  msg "Runtime OpenCL de Intel: $INTEL_RUNTIME"
  apt-get install -y -qq --no-install-recommends ocl-icd-libopencl1 clinfo >/dev/null
  if [[ "$INTEL_RUNTIME" == "legacy" ]]; then
    if ! dpkg -s intel-opencl-icd-legacy1 >/dev/null 2>&1; then
      tmp="$(mktemp -d)"
      for u in "${NEO_LEGACY[@]}"; do curl -fsSL -o "$tmp/$(basename "$u")" "$u"; done
      apt-get install -y -qq "$tmp"/*.deb >/dev/null
      rm -rf "$tmp"
    fi
    # Que un apt upgrade no los reemplace por la rama nueva (que ya no soporta Gen9).
    apt-mark hold intel-igc-core intel-igc-opencl intel-opencl-icd-legacy1 \
      intel-level-zero-gpu-legacy1 libigdgmm12 >/dev/null
  else
    apt-get install -y -qq --no-install-recommends intel-opencl-icd >/dev/null
  fi

  if [[ ! -f "$OPENVINO_DIR/setupvars.sh" ]]; then
    msg "Descargando runtime de OpenVINO 2025.4"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/ov.tgz" "$OPENVINO_URL"
    curl -fsSL -o "$tmp/ov.tgz.sha256" "$OPENVINO_URL.sha256"
    (cd "$tmp" && echo "$(awk '{print $1}' ov.tgz.sha256)  ov.tgz" | sha256sum -c --quiet)
    mkdir -p "$(dirname "$OPENVINO_DIR")"
    tar -xzf "$tmp/ov.tgz" -C "$tmp"
    rm -rf "$OPENVINO_DIR"
    mv "$tmp"/openvino_toolkit_*/ "$OPENVINO_DIR"
    rm -rf "$tmp"
  fi
  # libtbb y pugixml que pide el runtime.
  apt-get install -y -qq --no-install-recommends libtbb12 libpugixml1v5 >/dev/null || true
fi

# ---------------------------------------------------------------- whisper.cpp
BIN="$WHISPER_DIR/build/bin/whisper-cli"
if [[ ! -d "$WHISPER_DIR/.git" ]]; then
  msg "Clonando whisper.cpp ($WHISPER_REF)"
  git clone -q https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
  UPGRADE=1
fi
built_ov=0
grep -qE '^WHISPER_OPENVINO:BOOL=(ON|1|TRUE)$' "$WHISPER_DIR/build/CMakeCache.txt" 2>/dev/null && built_ov=1
want_ov=0; [[ "$DEVICE" == "intel" ]] && want_ov=1
if [[ $UPGRADE == 1 || ! -x "$BIN" || $built_ov != "$want_ov" ]]; then
  msg "Compilando whisper.cpp $WHISPER_REF (OpenVINO=$want_ov) — tarda varios minutos"
  git -C "$WHISPER_DIR" fetch -q --tags origin
  git -C "$WHISPER_DIR" -c advice.detachedHead=false checkout -q "$WHISPER_REF"
  rm -rf "$WHISPER_DIR/build"
  (
    cd "$WHISPER_DIR"
    if [[ $want_ov == 1 ]]; then
      # setupvars.sh de OpenVINO no soporta `set -u`.
      set +u
      # shellcheck disable=SC1091
      source "$OPENVINO_DIR/setupvars.sh" >/dev/null
      set -u
      cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_OPENVINO=1 >/dev/null
    else
      cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
    fi
    cmake --build build -j"$(nproc)" --config Release --target whisper-cli >/dev/null
  )
fi
"$BIN" --help >/dev/null 2>&1 || die "whisper-cli no arranca ($BIN)"

# ---------------------------------------------------------------- usuario y rutas
msg "Creando usuario de servicio y directorios"
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SVC_USER"
fi
if [[ "$DEVICE" == "intel" ]]; then
  getent group render >/dev/null || groupadd --system render
  usermod -aG render "$SVC_USER"
  [[ -e /dev/dri/renderD128 ]] && usermod -aG "$(stat -c %G /dev/dri/renderD128)" "$SVC_USER" 2>/dev/null || true
fi
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$DATA_DIR" "$MODELS_DIR" "$JOBS_DIR"
install -d -m 0750 -g "$SVC_USER" "$ETC_DIR"

# ---------------------------------------------------------------- modelos
msg "Modelos: $MODELS"
IFS=',' read -r -a model_list <<< "$MODELS"
for m in "${model_list[@]}"; do
  if [[ ! -s "$MODELS_DIR/ggml-$m.bin" ]]; then
    echo "Descargando ggml-$m.bin"
    bash "$WHISPER_DIR/models/download-ggml-model.sh" "$m" "$MODELS_DIR" >"$TMPDIR/download.log" 2>&1 \
      || { cat "$TMPDIR/download.log" >&2; die "No se pudo bajar el modelo '$m'"; }
  fi
done
if [[ ! -s "$MODELS_DIR/$VAD_FILE" ]]; then
  curl -fsSL -o "$MODELS_DIR/$VAD_FILE" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_FILE"
fi

if [[ "$DEVICE" == "intel" ]]; then
  need=()
  for m in "${model_list[@]}"; do
    [[ -s "$MODELS_DIR/ggml-$m-encoder-openvino.xml" ]] || need+=("$m")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    # PyTorch carga el modelo completo en RAM para exportarlo: ~2 GB para small,
    # ~6 GB para medium, ~10 GB para large (medido: medium murió por OOM con 4 GB + 1 GB swap). Mejor avisar que morir por OOM.
    need_mb=2500
    for m in "${need[@]}"; do
      case "$m" in
        medium*) (( need_mb < 6000 )) && need_mb=6000 ;;
        large*) (( need_mb < 10000 )) && need_mb=10000 ;;
      esac
    done
    avail_mb=$(( ( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) + $(awk '/^SwapFree:/ {print $2}' /proc/meminfo) ) / 1024 ))
    if (( avail_mb < need_mb )); then
      die "Convertir ${need[*]} a OpenVINO necesita ~${need_mb} MB de RAM+swap libres y hay ${avail_mb} MB. Subí la memoria temporalmente (en Proxmox: pct set <ctid> -memory $need_mb) y volvé a correr el instalador; después se puede bajar."
    fi
    msg "Convirtiendo encoder(s) a OpenVINO: ${need[*]} (usa PyTorch CPU en un venv temporal)"
    venv_dir="$(mktemp -d)"
    venv="$venv_dir/venv"
    trap 'rm -rf "$venv_dir"' EXIT
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip
    "$venv/bin/pip" install -q --extra-index-url https://download.pytorch.org/whl/cpu \
      -r "$WHISPER_DIR/models/requirements-openvino.txt"
    for m in "${need[@]}"; do
      (cd "$WHISPER_DIR/models" && "$venv/bin/python" convert-whisper-to-openvino.py --model "$m" >/dev/null)
      mv "$WHISPER_DIR/models/ggml-$m-encoder-openvino."{xml,bin} "$MODELS_DIR/"
    done
    rm -rf "$venv_dir" /root/.cache/whisper
    trap - EXIT
  fi
fi
# OpenVINO escribe su caché de kernels compilados al lado del modelo
# (<modelo>-encoder-openvino-cache/). Si el servicio no puede escribir ahí, la
# GPU falla al inicializar y whisper.cpp cae a CPU sin avisar.
chown -R "$SVC_USER:$SVC_USER" "$MODELS_DIR"

# ---------------------------------------------------------------- app
msg "Instalando whisper-engine en $APP_DIR"
if [[ -n "$APP_SRC" ]]; then
  rsync -a --delete --exclude node_modules --exclude .git --exclude models --exclude jobs \
    "$APP_SRC/" "$APP_DIR/"
elif [[ ! -d "$APP_DIR/.git" ]]; then
  git clone -q --branch "$APP_REF" "$APP_REPO" "$APP_DIR"
elif [[ $UPGRADE == 1 ]]; then
  git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" checkout -q "$APP_REF" && git -C "$APP_DIR" pull -q --ff-only || true
fi
(cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund --loglevel=error)

# El token se genera una sola vez; los re-run conservan el existente.
if [[ -f "$ENV_FILE" ]] && grep -q '^ENGINE_TOKEN=.\+' "$ENV_FILE"; then
  TOKEN="$(sed -n 's/^ENGINE_TOKEN=//p' "$ENV_FILE")"
else
  TOKEN="$(openssl rand -hex 32)"
fi
WHISPER_DEVICE="cpu"; [[ "$DEVICE" == "intel" ]] && WHISPER_DEVICE="auto"
DEFAULT_MODEL="${model_list[0]}"
if [[ -f "$ENV_FILE" ]]; then
  # Respetar ajustes manuales: solo completar claves que falten.
  add_if_missing() { grep -q "^$1=" "$ENV_FILE" || echo "$1=$2" >> "$ENV_FILE"; }
else
  add_if_missing() { echo "$1=$2" >> "$ENV_FILE"; }
  : > "$ENV_FILE"
fi
add_if_missing ENGINE_TOKEN "$TOKEN"
add_if_missing PORT "$PORT"
add_if_missing HOST "0.0.0.0"
add_if_missing WHISPER_BIN "$BIN"
add_if_missing MODELS_DIR "$MODELS_DIR"
add_if_missing VAD_MODEL "$MODELS_DIR/$VAD_FILE"
add_if_missing JOBS_DIR "$JOBS_DIR"
add_if_missing WHISPER_LANGUAGE "$LANGUAGE"
add_if_missing WHISPER_DEFAULT_MODEL "$DEFAULT_MODEL"
add_if_missing WHISPER_DEVICE "$WHISPER_DEVICE"
add_if_missing WHISPER_EXTRA_ARGS "-vmsd 20 -mc 0"
add_if_missing MAX_UPLOAD_MB 2048
add_if_missing MAX_JOB_MINUTES 90
add_if_missing JOB_TTL_HOURS 24
chown root:"$SVC_USER" "$ENV_FILE"
chmod 0640 "$ENV_FILE"

# Wrapper: carga el entorno de OpenVINO (libtbb, plugins) si está instalado.
cat > "$APP_DIR/run.sh" <<EOF
#!/bin/bash
[[ -f $OPENVINO_DIR/setupvars.sh ]] && source $OPENVINO_DIR/setupvars.sh >/dev/null
exec /usr/bin/env node $APP_DIR/src/server.js
EOF
chmod 0755 "$APP_DIR/run.sh"
install -m 0644 "$APP_DIR/install/whisper-engine.service" /etc/systemd/system/whisper-engine.service
systemctl daemon-reload
systemctl enable -q whisper-engine
systemctl restart whisper-engine

# ---------------------------------------------------------------- prueba
msg "Esperando a que la API responda"
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null || { journalctl -u whisper-engine -n 30 --no-pager; die "La API no levantó"; }

DEVICE_USED="(sin probar)"
if [[ $SKIP_TEST == 0 ]]; then
  msg "Prueba: transcribiendo samples/jfk.wav con '$DEFAULT_MODEL'"
  out="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    -F file=@"$WHISPER_DIR/samples/jfk.wav" -F model="$DEFAULT_MODEL" -F language=en \
    "http://127.0.0.1:$PORT/v1/jobs")"
  id="$(echo "$out" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  status=""
  for _ in $(seq 1 300); do
    job="$(curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/jobs/$id")"
    status="$(echo "$job" | sed -E 's/.*"status":"([^"]+)".*/\1/')"
    [[ "$status" =~ ^(done|failed|cancelled)$ ]] && break
    sleep 2
  done
  [[ "$status" == "done" ]] || die "La prueba terminó en '$status': $job"
  DEVICE_USED="$(echo "$job" | sed -E 's/.*"device":"([^"]+)".*/\1/')"
  echo "Transcripción: $(curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/jobs/$id/result?format=txt" | tr '\n' ' ')"
  curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/jobs/$id" >/dev/null
  if [[ "$DEVICE" == "intel" && "$DEVICE_USED" != "GPU" ]]; then
    warn "Se pidió --device intel pero la prueba corrió en CPU. Revisar: journalctl -u whisper-engine"
  fi
fi

IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

────────────────────────────────────────────────────────────
 whisper-engine $(sed -nE 's/.*"version": "([^"]+)".*/\1/p' "$APP_DIR/package.json") instalado
   URL:      http://$IP:$PORT
   Token:    $TOKEN
   Device:   $DEVICE_USED
   Modelos:  $MODELS
   Config:   $ENV_FILE   (systemctl restart whisper-engine tras editar)
   Logs:     journalctl -u whisper-engine -f
────────────────────────────────────────────────────────────
EOF
