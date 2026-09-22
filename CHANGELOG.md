# Changelog

Todos los cambios relevantes de este proyecto se documentan acá.
Formato [Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/),
versionado [SemVer](https://semver.org/lang/es/).

## [1.0.0] - 2026-09-22

Primera versión pública. Reemplaza el acceso por SSH con comandos forzados
(`MKJOBDIR`/`RUNJOB`/`KILLJOB`/`CLEANJOB` + rsync) que usaba whisper-idep 1.x.

### Agregado
- API REST con token Bearer: `POST/GET/DELETE /v1/jobs`, resultado en
  txt/json/srt/vtt, `GET /v1/models` y `GET /health` (público).
- Endpoint síncrono compatible con OpenAI (`POST /v1/audio/transcriptions`).
- Cola FIFO de un solo worker, progreso real leído de `whisper-cli -pp` y
  detección de si cada trabajo corrió en GPU (OpenVINO) o CPU.
- Conversión automática de cualquier formato a WAV 16 kHz mono con ffmpeg.
- Idioma y modelo por defecto configurables (`WHISPER_LANGUAGE`, default `es`).
- Limpieza automática de trabajos terminados (`JOB_TTL_HOURS`) y de restos de
  una ejecución anterior al arrancar.
- Instalador nativo para Debian 12/13 (`install/engine-install.sh`) e
  instalador de LXC para Proxmox VE (`install/lxc/whisper-engine.sh`) con
  pasaje de iGPU Intel y verificación de IP duplicada.
- Imágenes Docker `cpu`, `openvino` (runtime Intel actual o legacy) y `tools`
  (conversión a OpenVINO), compose para CPU/Intel y "todo en uno" con el frontend.
- Tests (`npm test`) con un `whisper-cli` falso, sin GPU ni modelos.
