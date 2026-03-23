# Llama Server Docker

A Docker setup for running [llama.cpp](https://github.com/ggml-org/llama.cpp) in **router mode** — multiple models defined in a preset file, loaded on-demand, with automatic GPU offloading and a built-in WebUI.

## Features

- **Router mode** with lazy model loading — define multiple models, only load what's needed
- **Model presets** via INI config — per-model context size, sampling, GPU layers
- **Built-in WebUI** (SvelteKit) with vision support, conversation branching, LaTeX rendering
- **OpenAI-compatible API** on `/v1/chat/completions`
- **Auto-offload scripts** to unload idle models and free VRAM
- **CUDA GPU acceleration** with flash attention

## Requirements

- Docker with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- Docker Compose
- NVIDIA GPU with sufficient VRAM for your models
- GGUF model files (downloaded separately)

## Quick Start

### 1. Configure

```bash
cp .env.example .env
# Edit .env if you want to change server defaults
```

### 2. Add models

Download GGUF models to a local directory (e.g. `~/.cache/llama.cpp/`), then configure them in `config/models.ini`:

```ini
[my-model]
alias = my-model
model = /root/.cache/llama.cpp/MyModel-Q4_K_M.gguf
ctx-size = 32768
n-gpu-layers = -1
flash-attn = on
cache-type-k = q8_0
cache-type-v = q8_0
temp = 0.7
top-p = 0.95
parallel = 2
```

### 3. Update docker-compose.yml

Point the volume mount to your local model cache:

```yaml
volumes:
  - /path/to/your/models:/root/.cache/llama.cpp:ro
```

### 4. Start

```bash
docker compose build
docker compose up -d
```

The server runs on port **11434** by default. Access:

- **WebUI**: http://localhost:11434
- **API**: http://localhost:11434/v1/chat/completions
- **Health**: http://localhost:11434/health

## API Usage

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "my-model",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Model Management

The `scripts/` directory includes utilities for managing models at runtime:

| Script | Description |
|--------|-------------|
| `scripts/load-model.sh <alias>` | Pre-load a model into memory |
| `scripts/unload-model.sh <alias>` | Unload a model to free VRAM |
| `scripts/check-models.sh` | Show status of all configured models |
| `scripts/model-manager.sh` | Auto-offload idle models after timeout |
| `scripts/track-usage.sh <alias>` | Record usage timestamp for a model |

## Configuration

### Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMA_ARG_HOST` | `0.0.0.0` | Server bind address |
| `LLAMA_ARG_PORT` | `8080` | Server port (inside container) |
| `LLAMA_ARG_MODELS_MAX` | `1` | Max models loaded simultaneously |
| `LLAMA_ARG_N_GPU_LAYERS` | `-1` | GPU layers (-1 = all) |
| `LLAMA_ARG_FLASH_ATTN` | `on` | Flash attention |
| `LLAMA_ARG_PARALLEL` | `2` | Parallel request slots |

### Model Presets (`config/models.ini`)

Each `[section]` defines a model with its own settings. See the included `models.ini` for examples with Qwen 3.5 and GLM configurations.

Key per-model settings: `model`, `ctx-size`, `n-gpu-layers`, `flash-attn`, `cache-type-k`, `cache-type-v`, `temp`, `top-p`, `top-k`, `parallel`.

### Reverse Proxy (optional)

The included `docker-compose.yml` has commented-out Traefik labels. Uncomment and adjust for your domain if you want HTTPS/reverse proxy support.

## Troubleshooting

```bash
# Check logs
docker compose logs -f llama-server

# Check GPU access
nvidia-smi
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# Container resource usage
docker stats llama-server

# Memory issues? Reduce context or parallel slots in models.ini
```

## Project Structure

```
├── Dockerfile              # Based on official llama.cpp CUDA image
├── docker-compose.yml      # Service definition with GPU support
├── entrypoint.sh           # Builds llama-server CLI args from env
├── .env.example            # Default environment variables
├── config/
│   └── models.ini          # Model presets (per-model config)
└── scripts/
    ├── healthcheck.sh      # Container health check
    ├── load-model.sh       # Load model on demand
    ├── unload-model.sh     # Unload model to free VRAM
    ├── check-models.sh     # Show all model statuses
    ├── model-manager.sh    # Auto-offload idle models
    └── track-usage.sh      # Track model usage timestamps
```

## Resources

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama.cpp Docker guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- [llama.cpp server docs](https://github.com/ggml-org/llama.cpp/blob/master/examples/server/README.md)

## License

MIT — same as llama.cpp.
