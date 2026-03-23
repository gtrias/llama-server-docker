# Llama Server Docker - Quick Start Guide

Router mode with lazy model loading - uses your **local** downloaded models from `~/.cache/llama.cpp`.

## Quick Start

```bash
cd ~/src/llama-server-docker
./start.sh
```

That's it! The server starts in router mode and uses your existing models.

## How Router Mode Works

| Feature | Description |
|---------|-------------|
| **Local models** | Mounts your `~/.cache/llama.cpp` directory |
| **Auto-discovery** | Scans for GGUF models in your cache |
| **Lazy loading** | Models load on first API request |
| **LRU eviction** | Unloads least-recently-used models when max (4) reached |
| **Request routing** | Specify `model` in your request to use specific model |
| **Built-in Web UI** | Manage models at http://localhost:11434/ |

## Your Local Models

Based on your `~/.cache/llama.cpp` and `config/models.ini`:

### qwen (Qwen3-Coder-Next)
- **Size**: ~79B parameters (4-bit quantized)
- **Context**: 160K tokens
- **Best for**: Coding, long-context tasks
- **Parameters**: temp=0.3, top-p=0.9
- **File**: `Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M`

### glm (GLM-4-7-Flash-REAP)
- **Size**: ~23B parameters (4-bit quantized)
- **Context**: 16K tokens
- **Best for**: Fast responses, general chat
- **Parameters**: temp=0.5, top-p=0.95
- **File**: `unsloth/GLM-4.7-Flash-REAP-23B-A3B-GGUF:IQ4_NL`

## API Usage

### List Models
```bash
curl http://localhost:11434/models | jq
```

### Chat with Qwen
```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen",
    "messages": [{"role": "user", "content": "Write Python code to sort a list"}]
  }'
```

### Chat with GLM
```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Use full model identifier
```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Model Management API

### Load a Model Manually
```bash
curl -X POST http://localhost:11434/models/load \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen"}'
```

### Unload a Model
```bash
curl -X POST http://localhost:11434/models/unload \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen"}'
```

## Web UI

Visit **http://localhost:11434/** (or http://localhost:11434) for:

- View all discovered models from your local cache
- See which models are loaded in memory
- Load/unload models manually
- Monitor GPU memory usage
- Interactive chat interface

## Common Commands

```bash
# Start server (uses your local models)
./start.sh

# Stop server
docker-compose down

# Restart server
docker-compose restart

# View logs
docker-compose logs -f

# Check health
curl http://localhost:11434/health

# List all models (from your cache)
curl http://localhost:11434/models | jq
```

## Configuration

### Volume Mount
Your local models are mounted read-only:
```yaml
volumes:
  - ~/.cache/llama.cpp:/root/.cache/llama.cpp:ro
```

This means:
- Docker uses your existing downloaded models
- No duplicate storage
- New models downloaded locally appear automatically

### Server Settings (`.env`)
```bash
LLAMA_ARG_HOST=0.0.0.0           # Bind address
LLAMA_ARG_PORT=8080              # Internal port
LLAMA_ARG_MODELS_MAX=4           # Max loaded models simultaneously
LLAMA_ARG_MODELS_AUTOLOAD=true    # Lazy loading
LLAMA_ARG_N_GPU_LAYERS=-1        # All layers to GPU
LLAMA_ARG_FLASH_ATTN=on          # Flash attention
```

### Model Presets (`config/models.ini`)
Per-model settings that match your local `~/models/llama/models.ini`:
- Context size
- Temperature, top-p
- Repeat penalty
- Parallel decoding
- GPU layers

## Downloading New Models

Since the cache is mounted, download models **outside** Docker and they'll be available:

```bash
# Download using llama-server (local)
llama-server -hf Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M

# Or download via Docker API
curl -X POST http://localhost:11434/models/download \
  -H "Content-Type: application/json" \
  -d '{"model": "user/repo:quantization"}'
```

The new models will appear in `~/.cache/llama.cpp` and be auto-discovered.

## Troubleshooting

**Models not showing up:**
```bash
# Check your local cache
ls -la ~/.cache/llama.cpp/*.gguf

# Check what Docker sees
docker exec llama-server ls -la /root/.cache/llama.cpp/*.gguf

# List discovered models via API
curl http://localhost:11434/models | jq
```

**Permission denied:**
```bash
# Make sure ~/.cache/llama.cpp is readable
chmod -R +r ~/.cache/llama.cpp

# Check SELinux/AppArmor if issues persist
ls -lZ ~/.cache/llama.cpp
```

**Server not responding:**
```bash
docker-compose logs llama-server
```

**Out of memory:**
```bash
# Reduce max loaded models in .env
LLAMA_ARG_MODELS_MAX=2

# Or unload models manually via Web UI or API
curl -X POST http://localhost:11434/models/unload -d '{"model": "..."}'
```

## Directory Structure

```
~/
├── .cache/llama.cpp/          # Your local models (mounted)
│   ├── Qwen_Qwen3-...gguf
│   └── unsloth_GLM-...gguf
│
~/src/llama-server-docker/
├── config/
│   └── models.ini              # Model presets (matches local)
├── .env                       # Server settings
├── docker-compose.yml
└── start.sh
```

## Comparison with Local Setup

| Feature | Local llama-server | Docker (this setup) |
|---------|------------------|---------------------|
| Models location | `~/.cache/llama.cpp` | Same (mounted) |
| Config file | `~/models/llama/models.ini` | `./config/models.ini` |
| Router mode | `--models-preset` | `--models-preset` |
| Auto-load | `--models-autoload` | `--models-autoload` |
| Web UI | http://localhost:8081/ | http://localhost:11434/ |
| Network | Host | Containerized + Traefik |

The Docker setup mirrors your local configuration exactly!

## Endpoints

- **API**: http://localhost:11434/v1
- **Health**: http://localhost:11434/health
- **Models**: http://localhost:11434/models
- **Web UI**: http://localhost:11434/ or http://localhost:11434

## OpenAI Compatibility

Fully OpenAI-compatible - just change the base URL:

```bash
# Before (OpenAI)
export OPENAI_API_BASE=https://api.openai.com/v1

# After (local Docker)
export OPENAI_API_BASE=http://localhost:11434/v1
```

Most OpenAI SDKs work out of the box!
