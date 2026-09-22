# AGENTS.md

Guía para cualquier agente (o persona) que trabaje en este repo.

## Versionado (SemVer)

Este proyecto sigue [SemVer](https://semver.org/lang/es/) de forma estricta:
`MAJOR.MINOR.PATCH`. La API HTTP (`/v1/*`, `/health`) es el contrato público.

- **PATCH** (`x.y.Z`): correcciones de bugs, cambios en los instaladores que no
  cambian su interfaz, retoques de defaults, refactors internos. **Por defecto,
  si hay duda, es PATCH.**
- **MINOR** (`x.Y.0`): funcionalidad nueva compatible hacia atrás (un endpoint
  o campo nuevo en una respuesta, un flag nuevo en un instalador, una variable
  de entorno nueva con default).
- **MAJOR** (`X.0.0`): cambios incompatibles en la API (sacar o renombrar un
  endpoint o campo, cambiar el significado de un estado) o en la configuración
  (renombrar/sacar variables de entorno obligatorias).

Cada bump de versión (`package.json`) va acompañado de una entrada en
[`CHANGELOG.md`](CHANGELOG.md) con el mismo número, formato
[Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/), y de un tag `vX.Y.Z`
(que dispara la publicación de imágenes en GHCR).

## Pruebas

- `npm test` tiene que pasar (no requiere GPU ni modelos; sí `ffmpeg`).
- Cambios en `install/` se prueban creando un LXC nuevo con el script, nunca
  sobre una instalación en producción.
