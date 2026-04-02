# Design: Simplified llama-server-docker

**Date:** 2026-04-02  
**Status:** Approved

## Problem

The current setup has grown organically and is now confusing:

- Three Dockerfiles (`Dockerfile`, `Dockerfile.rotorquant`, `Dockerfile.rotorquant-local`)
- Two docker-compose files with inconsistent Traefik labels (wrong domain, wrong entrypoint)
- Two model config files (`models.ini`, `models.conf`) with different key formats
- RotorQuant version mounts the binary via Docker volume — fragile, breaks on any path change
- Rebuilds are slow because the image recompiles everything each time

## Goal

One compose file, two pre-built images, one model config. Switch versions instantly without rebuilding.

## Architecture

### Images

**`llama-server:standard`**
- Built from `Dockerfile` (unchanged)
- Uses the llama.cpp binary compiled inside the image
- Rebuild only when updating llama.cpp version

**`llama-server:rotorquant`**
- Built from `Dockerfile.rotorquant`
- `COPY`s the pre-built RotorQuant binary from the local build path at build time
- No volume mounts for binaries
- Rebuild only when updating the RotorQuant binary (`docker compose build rotorquant-image` or similar)

Both images share the same `entrypoint.sh`, `config/`, and `scripts/`.

### Version switching

A `.env` file controls which image is active:

```
IMAGE_TAG=standard   # or: rotorquant
```

`switch-version.sh` updates `.env` and restarts the container:

```bash
./switch-version.sh standard    # switch to standard llama.cpp
./switch-version.sh rotorquant  # switch to RotorQuant
```

No rebuild needed. Switch is instant (`docker compose up -d`).

### Model configuration

Single `config/models.ini` — the format llama.cpp understands. Both image variants mount the same file. If a model uses a quantization only supported by RotorQuant, it simply won't load on the standard image (llama.cpp errors on that model, does not crash the server).

### Traefik

Single set of correct labels in `docker-compose.yml`:
- Domain: `llama.casa.genar.me`
- Entrypoint: `https`
- Cert resolver: `default`
- Basic auth middleware

## Files

| File | Action |
|------|--------|
| `docker-compose.yml` | Keep — becomes the only compose file |
| `docker-compose.rotorquant.yml` | **Delete** |
| `Dockerfile` | Keep — standard image |
| `Dockerfile.rotorquant` | Keep — rewrite to COPY binary instead of volume mount |
| `Dockerfile.rotorquant-local` | **Delete** |
| `config/models.ini` | Keep — single source of truth, add Gemma 4 entries |
| `config/models.conf` | **Delete** |
| `.env` | Add `IMAGE_TAG` variable |
| `switch-version.sh` | Simplify to update `.env` and run `docker compose up -d` |

## Adding new models (e.g. Gemma 4)

Edit `config/models.ini` and add a new section following the existing format. No Docker changes needed.

## Updating RotorQuant binary

1. Rebuild from source in `/home/genar/src/rotorquant-test/llama-cpp-turboquant/`
2. Run `docker compose build` (builds only the rotorquant image, fast since it just COPYs the binary)
3. Run `./switch-version.sh rotorquant` to restart with the new image
