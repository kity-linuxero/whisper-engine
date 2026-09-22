#!/usr/bin/env bash
# whisper-engine — crea un LXC Debian 13 en Proxmox VE y lo instala adentro.
# Se corre en el HOST de Proxmox, como root:
#
#   ./install/lxc/whisper-engine.sh --device intel --models small,medium \
#       --ip 192.168.1.50/24 --gw 192.168.1.1
#
# Todo lo que no se pase por flag usa un default razonable; antes de crear
# nada muestra un resumen y pide confirmación (salvo --yes).
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

CTID=""
HOSTNAME_="whisper-engine"
STORAGE=""
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"
VLAN=""
IP="dhcp"
GW=""
DNS=""
CORES=4
MEMORY=4096
SWAP=1024
DISK=20
DEVICE="cpu"
RENDER_NODE="/dev/dri/renderD128"
ONBOOT=1
YES=0
INSTALL_ARGS=()
APP_REPO_RAW="https://raw.githubusercontent.com/kity-linuxero/whisper-engine/main"

usage() {
  cat <<EOF
Uso: $0 [opciones]

Contenedor:
  --ctid N               ID del CT (default: el próximo libre)
  --hostname NAME        (default: whisper-engine)
  --storage NAME         Storage para el rootfs (default: el primero que admita contenedores)
  --template-storage N   Storage de plantillas (default: local)
  --bridge vmbr0         Bridge de red
  --vlan N               Tag de VLAN (opcional)
  --ip dhcp|CIDR         ej. 192.168.1.50/24 (default: dhcp)
  --gw IP                Gateway (obligatorio con IP fija)
  --dns IP               Servidor DNS (default: el del host)
  --cores N              (default: 4)   --memory MB (default: 4096)   --disk GB (default: 20)
  --no-onboot            No arrancar el CT con el host
  --yes                  No pedir confirmación

Motor (se pasan a engine-install.sh):
  --device cpu|intel     intel = pasa $RENDER_NODE al CT y usa OpenVINO
  --models small,medium  --language es   --port 8080
  --intel-runtime auto|legacy|current   --whisper-ref TAG   --app-ref REF
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME_="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --vlan) VLAN="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --gw) GW="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --no-onboot) ONBOOT=0; shift ;;
    --yes|-y) YES=1; shift ;;
    --device) DEVICE="$2"; INSTALL_ARGS+=("$1" "$2"); shift 2 ;;
    --models|--language|--port|--intel-runtime|--whisper-ref|--app-ref)
      INSTALL_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

msg()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Correr como root en el host de Proxmox."
command -v pct >/dev/null || die "No se encontró 'pct': esto se corre en un host Proxmox VE."
[[ "$DEVICE" =~ ^(cpu|intel)$ ]] || die "--device tiene que ser cpu o intel"
[[ "$IP" == "dhcp" || "$IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "--ip tiene que ser dhcp o una dirección CIDR (ej. 192.168.1.50/24)"
[[ "$IP" == "dhcp" || -n "$GW" ]] || die "Con IP fija hace falta --gw"

[[ -n "$CTID" ]] || CTID="$(pvesh get /cluster/nextid)"
pct status "$CTID" >/dev/null 2>&1 && die "Ya existe un CT con ID $CTID"
if [[ -z "$STORAGE" ]]; then
  STORAGE="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
  [[ -n "$STORAGE" ]] || die "No encontré un storage para contenedores; pasar --storage"
fi
if [[ "$DEVICE" == "intel" && ! -e "$RENDER_NODE" ]]; then
  die "$RENDER_NODE no existe en el host. Sin iGPU usar --device cpu."
fi

# Código del motor: el checkout donde vive este script, o lo bajamos de GitHub.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "$SRC_DIR/install/engine-install.sh" ]]; then
  SRC_DIR=""
fi

# Plantilla Debian 13 más nueva disponible.
pveam update >/dev/null 2>&1 || warn "pveam update falló; uso las plantillas ya conocidas"
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard_.*_amd64' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" | awk -F'[/ ]' '/debian-13-standard/ {print $2}' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || die "No encontré la plantilla debian-13-standard"

NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[[ -n "$GW" ]] && NET+=",gw=$GW"
[[ -n "$VLAN" ]] && NET+=",tag=$VLAN"

cat <<EOF

Se va a crear:
  CT $CTID ($HOSTNAME_)  Debian: $TEMPLATE
  Storage: $STORAGE  Disco: ${DISK}G  CPU: $CORES  RAM: ${MEMORY}MB
  Red: $NET
  Motor: ${INSTALL_ARGS[*]:-(defaults: --device cpu --models small)}
  Código: ${SRC_DIR:-GitHub (kity-linuxero/whisper-engine)}
EOF
if [[ $YES == 0 ]]; then
  read -r -p "¿Continuar? [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]] || exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  msg "Descargando plantilla $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
fi

msg "Creando CT $CTID"
create_args=(
  --hostname "$HOSTNAME_"
  --ostype debian
  --unprivileged 1
  --features nesting=1
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP"
  --rootfs "$STORAGE:$DISK"
  --net0 "$NET"
  --onboot "$ONBOOT"
  --description "whisper-engine — API de transcripción (whisper.cpp). https://github.com/kity-linuxero/whisper-engine"
)
[[ -n "$DNS" ]] && create_args+=(--nameserver "$DNS")
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" "${create_args[@]}" >/dev/null
pct start "$CTID"

# Esperar red.
for _ in $(seq 1 30); do
  pct exec "$CTID" -- bash -c 'ip -4 route | grep -q default' 2>/dev/null && break
  sleep 1
done

if [[ "$IP" != "dhcp" ]]; then
  # Detección de IP duplicada (ARP DAD) antes de seguir: una IP fija ya usada por
  # otro equipo da cortes intermitentes muy difíciles de diagnosticar.
  pct exec "$CTID" -- bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iputils-arping >/dev/null' \
    || warn "No se pudo instalar arping; salteo la verificación de IP duplicada"
  # arping -D: 0 = nadie más responde por esa IP, 1 = duplicada, otro = no se pudo verificar.
  rc=0; pct exec "$CTID" -- arping -D -q -c 3 -I eth0 "${IP%/*}" || rc=$?
  [[ $rc -gt 1 ]] && warn "No se pudo verificar si la IP está duplicada (arping rc=$rc)"
  if [[ $rc -eq 1 ]]; then
    pct stop "$CTID"
    die "La IP ${IP%/*} ya está en uso por otro equipo. El CT $CTID quedó creado y apagado: cambiá la IP con 'pct set $CTID -net0 ...' o borralo con 'pct destroy $CTID'."
  fi
fi

if [[ "$DEVICE" == "intel" ]]; then
  msg "Pasando $RENDER_NODE al CT"
  RENDER_GID="$(pct exec "$CTID" -- getent group render | cut -d: -f3)"
  [[ -n "$RENDER_GID" ]] || die "No existe el grupo 'render' dentro del CT"
  pct stop "$CTID"
  pct set "$CTID" -dev0 "$RENDER_NODE,gid=$RENDER_GID,mode=0660"
  pct start "$CTID"
  for _ in $(seq 1 30); do
    pct exec "$CTID" -- bash -c 'ip -4 route | grep -q default' 2>/dev/null && break
    sleep 1
  done
fi

msg "Copiando instalador al CT"
pct exec "$CTID" -- mkdir -p /root/whisper-engine-src
if [[ -n "$SRC_DIR" ]]; then
  tarball="$(mktemp --suffix=.tgz)"
  tar -C "$SRC_DIR" --exclude=node_modules --exclude=.git --exclude=./models --exclude=./jobs -czf "$tarball" .
  pct push "$CTID" "$tarball" /root/whisper-engine-src.tgz
  rm -f "$tarball"
  pct exec "$CTID" -- tar -C /root/whisper-engine-src -xzf /root/whisper-engine-src.tgz
  pct exec "$CTID" -- rm -f /root/whisper-engine-src.tgz
  INSTALL_ARGS+=(--app-src /root/whisper-engine-src)
else
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null && \
    mkdir -p /root/whisper-engine-src/install && \
    curl -fsSL -o /root/whisper-engine-src/install/engine-install.sh $APP_REPO_RAW/install/engine-install.sh"
fi

# Convertir modelos grandes a OpenVINO carga el modelo entero en RAM con PyTorch
# (~6 GB medium, ~10 GB large). Se sube la memoria del CT solo durante la
# instalación (en caliente, sin reiniciar) y después se restaura.
install_mem="$MEMORY"
if [[ "$DEVICE" == "intel" ]]; then
  models="$(printf '%s\n' "${INSTALL_ARGS[@]}" | grep -A1 -x -- --models | tail -1)"
  [[ "$models" == *medium* ]] && (( install_mem < 8192 )) && install_mem=8192
  [[ "$models" == *large* ]] && (( install_mem < 12288 )) && install_mem=12288
fi
if (( install_mem > MEMORY )); then
  msg "Subiendo la RAM del CT a ${install_mem} MB mientras dura la instalación (después vuelve a ${MEMORY} MB)"
  pct set "$CTID" -memory "$install_mem"
fi
restore_mem() { (( install_mem > MEMORY )) && pct set "$CTID" -memory "$MEMORY" || true; }
trap restore_mem EXIT

msg "Instalando whisper-engine dentro del CT $CTID (compila whisper.cpp: puede tardar 10-30 min)"
pct exec "$CTID" -- bash /root/whisper-engine-src/install/engine-install.sh "${INSTALL_ARGS[@]}"

echo
echo "Listo. CT $CTID ($HOSTNAME_). Consola: pct enter $CTID"
