# whisper-engine

API REST de transcripción de audio sobre [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
pensada para correr en un homelab: **CPU** en cualquier x86_64, o **iGPU Intel** vía OpenVINO
(probado en una HD 630 de 7ª gen). Es el motor detrás de
[whisper-idep](https://github.com/kity-linuxero/whisper-idep), pero sirve para cualquier cliente.

- **Cola de trabajos asíncrona**: subís el audio, recibís un `id` y consultás el progreso.
  Ninguna conexión queda abierta durante los minutos que dura una reunión larga, así que
  no hay timeouts de proxies, túneles o SDKs.
- **Progreso real**: leído en vivo de `whisper-cli --print-progress`, no estimado.
- **Cualquier formato de entrada**: mp3, m4a, ogg, video… se convierte con ffmpeg.
- **Resultados en txt, json (segmentos con timestamps), srt y vtt.**
- **Endpoint compatible con OpenAI** (`/v1/audio/transcriptions`) para Buzz, los SDK de
  OpenAI y similares, pensado para audios cortos.
- **Detección de GPU/CPU por trabajo**: si OpenVINO no logra inicializar la iGPU,
  whisper.cpp cae a CPU sin avisar. La API te dice en qué corrió cada trabajo.
- Un trabajo a la vez (FIFO): correr dos en paralelo sobre la misma CPU o iGPU solo
  hace que ambos tarden más.
- **El audio no se guarda**: el archivo subido y su conversión se borran apenas termina
  el trabajo (bien, con error o cancelado). Solo quedan las transcripciones, hasta que el
  cliente borra el trabajo o pasan `JOB_TTL_HOURS`.
- Autenticación con un token Bearer. Sin base de datos: el historial es cosa del cliente.

## Instalación

Hay tres caminos. Todos terminan con la API escuchando en el puerto `8080` y un token
para usarla.

### Opción A: LXC en Proxmox VE (un comando)

En el **host** de Proxmox, como root:

```bash
git clone https://github.com/kity-linuxero/whisper-engine.git
cd whisper-engine
./install/lxc/whisper-engine.sh --device intel --models small,medium \
    --ip 192.168.1.50/24 --gw 192.168.1.1
```

El script:
1. Crea un CT Debian 13 **unprivileged**.
2. Con `--device intel`, pasa `/dev/dri/renderD128` con el GID correcto del grupo `render`.
3. Verifica que la IP fija no esté ya en uso (ARP).
4. Compila whisper.cpp, baja y convierte los modelos, instala el servicio y hace una
   prueba real de transcripción.

Al final muestra la URL, el token y si la prueba corrió en **GPU** o en **CPU**.

| Flag | Default | |
|---|---|---|
| `--device cpu\|intel` | `cpu` | `intel` = iGPU vía OpenVINO |
| `--models` | `small` | Separados por coma: `tiny`, `base`, `small`, `medium`, `large-v3-turbo`… El primero es el default |
| `--language` | `es` | Código ISO-639-1 o `auto` |
| `--ctid`, `--hostname`, `--storage` | próximo libre, `whisper-engine`, autodetectado | |
| `--bridge`, `--vlan`, `--ip`, `--gw`, `--dns` | `vmbr0`, –, `dhcp`, –, el del host | |
| `--cores`, `--memory`, `--disk` | `4`, `4096`, `20` | |
| `--intel-runtime auto\|legacy\|current` | `auto` | Ver [iGPU Intel](#igpu-intel) |
| `--yes` | | Sin pedir confirmación |

Sin iGPU usá `--device cpu`. La instalación compila whisper.cpp, así que tarda entre 10 y
30 minutos según el hardware. Convertir los modelos a OpenVINO suma unos minutos más,
porque instala PyTorch en un entorno temporal que después se borra.

### Opción B: Debian 12/13 existente (VM, bare metal o un LXC propio)

```bash
git clone https://github.com/kity-linuxero/whisper-engine.git
cd whisper-engine
sudo ./install/engine-install.sh --device cpu --models small
```

Acepta los mismos flags de motor que el script de LXC, más `--upgrade` (recompila y
actualiza la app) y `--skip-test`. Se puede volver a correr cuantas veces haga falta:
conserva el token, la configuración y los modelos.

Queda instalado así:

| | |
|---|---|
| App | `/opt/whisper-engine` |
| whisper.cpp | `/opt/whisper.cpp` |
| Modelos y trabajos | `/var/lib/whisper-engine/{models,jobs}` |
| Config | `/etc/whisper-engine/engine.env` |
| Servicio | `systemctl status whisper-engine` · `journalctl -u whisper-engine -f` |

### Opción C: Docker

```bash
git clone https://github.com/kity-linuxero/whisper-engine.git
cd whisper-engine
cp .env.example .env
sed -i "s/^ENGINE_TOKEN=.*/ENGINE_TOKEN=$(openssl rand -hex 32)/" .env

# CPU
docker compose up -d

# iGPU Intel: agregar RENDER_GID al .env y usar el override
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" >> .env
docker compose -f docker-compose.yml -f docker-compose.intel.yml up -d
# una sola vez por modelo: convertir el encoder a OpenVINO
docker compose -f docker-compose.yml -f docker-compose.intel.yml run --rm tools small
docker compose -f docker-compose.yml -f docker-compose.intel.yml restart engine
```

- Al arrancar, el contenedor baja los modelos que falten según `WHISPER_MODELS` (en el
  volumen `models`).
- Las imágenes se publican en GHCR: `ghcr.io/kity-linuxero/whisper-engine:<versión>-cpu`,
  `-openvino` (Gen12+) y `-openvino-legacy` (Gen9–Gen11). Para construirlas localmente
  en vez de bajarlas: `docker compose build`.
- Si Docker corre adentro de un LXC de Proxmox, el CT necesita `nesting=1` y el
  `/dev/dri/renderD128` pasado desde el host.

#### Todo en uno: motor + frontend

`docker-compose.full.yml` suma [whisper-idep](https://github.com/kity-linuxero/whisper-idep),
la interfaz web, conectada al motor por la red interna del compose:

```bash
docker compose -f docker-compose.yml -f docker-compose.full.yml up -d
# con iGPU Intel:
docker compose -f docker-compose.yml -f docker-compose.intel.yml -f docker-compose.full.yml up -d
```

La web queda en `http://<host>:3000`. **No tiene login propio**: para exponerla a internet,
ponela detrás de un reverse proxy con autenticación.

## iGPU Intel

- whisper.cpp con OpenVINO corre el **encoder** en la iGPU y el decoder en CPU. En una
  HD 630 la mejora medida fue de ~15% end-to-end: sirve, pero no es mágico.
- El driver OpenCL de Intel viene en dos ramas:
  - **legacy** para Gen9–Gen11 (Skylake, Kaby Lake, Coffee Lake, Ice Lake…). Queda
    fijado con `apt-mark hold`, porque la rama nueva ya no soporta esas GPUs.
  - **current** para Gen12+ (Tiger Lake, Alder Lake, Xe, Arc).

  `--intel-runtime auto` elige según el PCI ID. **Solo se probó en Gen9.5 (HD 630)**; Gen12+
  debería andar pero no está verificado.
- Para confirmar que la GPU se usa: el campo `device` de cada trabajo dice `GPU`, y en el
  host `intel_gpu_top` muestra la cola *Render/3D* activa.
- Si `device` dice `CPU` con `--device intel`, casi siempre es una de estas dos:
  - El servicio no tiene permiso de escritura en `MODELS_DIR`, donde OpenVINO guarda su
    caché de kernels (`*-encoder-openvino-cache/`).
  - Al proceso le falta el grupo del device `/dev/dri/renderD128`.

  El log (`journalctl -u whisper-engine`) muestra `OpenVINO init failed…`.

## API

Todo lo que está bajo `/v1` requiere `Authorization: Bearer <ENGINE_TOKEN>`. `/health` es público.

| Método | Ruta | |
|---|---|---|
| `GET` | `/health` | `{ok, version, busy, queue_length, device, gpu_available, models}` |
| `GET` | `/v1/models` | Modelos instalados: `{default, language, data: [{id, openvino}]}` |
| `POST` | `/v1/jobs` | multipart: `file` (obligatorio), `model`, `language` → `202` con el trabajo |
| `GET` | `/v1/jobs` | Trabajos en memoria |
| `GET` | `/v1/jobs/:id` | Estado del trabajo (ver abajo) |
| `GET` | `/v1/jobs/:id/result?format=txt\|json\|srt\|vtt` | Resultado (`409` si no terminó) |
| `DELETE` | `/v1/jobs/:id` | Cancela si está en curso y borra el trabajo con sus archivos → `204` |
| `POST` | `/v1/audio/transcriptions` | Compatible con OpenAI, **síncrono**. `response_format`: `json`, `text`, `srt`, `vtt`, `verbose_json`. Un `model` desconocido (ej. `whisper-1`) usa el default |

Estado de un trabajo:

```json
{
  "id": "Qm3xY0a1b2c3",
  "status": "transcribing",
  "progress": 45,
  "model": "small",
  "language": "es",
  "device": null,
  "error": null,
  "original_name": "reunion.m4a",
  "audio_duration": 2196.4,
  "created_at": "2026-09-22T18:00:00.000Z",
  "started_at": "2026-09-22T18:00:01.000Z",
  "finished_at": null,
  "queue_position": 0
}
```

`status`: `queued → converting → transcribing → done | failed | cancelled`. `device`
(`GPU`/`CPU`) se completa al terminar.

Ejemplo con curl:

```bash
T=<token>; E=http://192.168.1.50:8080
id=$(curl -s -H "Authorization: Bearer $T" -F file=@reunion.m4a -F model=small $E/v1/jobs | jq -r .id)
curl -s -H "Authorization: Bearer $T" $E/v1/jobs/$id | jq '{status, progress}'
curl -s -H "Authorization: Bearer $T" "$E/v1/jobs/$id/result?format=srt" -o reunion.srt
curl -s -X DELETE -H "Authorization: Bearer $T" $E/v1/jobs/$id
```

**Los trabajos viven en memoria.** Si el motor se reinicia, se pierden: `GET` responde
`404` y el cliente tiene que tratarlo como fallido. Los trabajos terminados que nadie
borra se eliminan solos pasadas `JOB_TTL_HOURS` horas.

**Sobre el endpoint síncrono**: la conexión queda abierta hasta que termina la
transcripción. Con audios largos, los proxies (Cloudflare corta a los ~100 s) y los SDK
(el de OpenAI, 600 s) terminan dando timeout. Para esos casos está `/v1/jobs`.

## Configuración

Variables de entorno (`/etc/whisper-engine/engine.env` en la instalación nativa, `.env` en
Docker). Ver [`.env.example`](.env.example).

| Variable | Default | |
|---|---|---|
| `ENGINE_TOKEN` | — | **Obligatorio**, mínimo 16 caracteres (`openssl rand -hex 32`) |
| `PORT` / `HOST` | `8080` / `0.0.0.0` | |
| `WHISPER_BIN` | `/opt/whisper.cpp/build/bin/whisper-cli` | |
| `MODELS_DIR` | `./models` | Modelos `ggml-*.bin` e IR de OpenVINO |
| `VAD_MODEL` | `$MODELS_DIR/ggml-silero-v5.1.2.bin` | Silero VAD |
| `JOBS_DIR` | `./jobs` | Archivos temporales por trabajo |
| `WHISPER_DEFAULT_MODEL` | `small` | |
| `WHISPER_LANGUAGE` | `es` | ISO-639-1 o `auto` |
| `WHISPER_DEVICE` | `auto` | `auto` usa la iGPU si hay IR de OpenVINO y acceso al render node; `cpu` y `gpu` fuerzan |
| `WHISPER_THREADS` | `0` | `0` = default de whisper.cpp |
| `WHISPER_EXTRA_ARGS` | `-vmsd 20 -mc 0` | Ver abajo |
| `MAX_UPLOAD_MB` | `2048` | |
| `MAX_JOB_MINUTES` | `90` | Timeout duro por trabajo |
| `JOB_TTL_HOURS` | `24` | |

Los defaults de `WHISPER_EXTRA_ARGS` salen de pruebas con reuniones reales de 30–40 min:
- `-vmsd 20` corta los tramos de voz del VAD en 20 s como máximo.
- `-mc 0` hace que no se arrastre contexto entre ventanas.

Sin ellos, el modelo entraba en loops de repetición de varios minutos en tramos de audio
poco claro. Un beam search más grande (`-bs 5 -bo 5`) **empeoró** ese problema.

### Modelos: referencia en un i5-7500T (3 cores) + HD 630

| Modelo | Velocidad | Comentario |
|---|---|---|
| `small` | ~3x tiempo real (36 min de audio → ~12 min) | Buen equilibrio; default |
| `medium` | ~5x más lento que `small` | Mejor con cruces de voces; para lotes sin apuro |

Para agregar un modelo en una instalación nativa, volver a correr
`engine-install.sh --models small,medium,<nuevo>`. En Docker, agregarlo a `WHISPER_MODELS`.

## Seguridad

- El token es la única barrera. Si exponés el motor fuera de tu red, hacelo con HTTPS
  (reverse proxy) y un token largo.
- El servicio nativo corre con un usuario sin privilegios y el sandboxing de systemd
  (`ProtectSystem=strict`). En Docker, corre como uid 10001.

## Desarrollo

```bash
npm install
npm test        # usa un whisper-cli falso (test/fake-whisper-cli.sh); necesita ffmpeg
```

Versionado [SemVer](https://semver.org/lang/es/); ver [AGENTS.md](AGENTS.md) y
[CHANGELOG.md](CHANGELOG.md).

## Licencia

[MIT](LICENSE). whisper.cpp es MIT; OpenVINO es Apache-2.0.
