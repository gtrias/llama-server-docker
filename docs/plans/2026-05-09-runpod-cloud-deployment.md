# Plan: RunPod Cloud Deployment for Multi-User LLM Serving

**Date:** 2026-05-09  
**Status:** Draft  
**Author:** genar (via Pi agent)

## Goal

Deploy **llama-swap-mtp** (with MTP speculative decoding) on RunPod with an RTX 6000 Ada (48GB) to serve Qwen3.6-27B with full 262K native context to 2-4 friends running Pi agents and Hermes harnesses. Spot pricing (~241 EUR/mo). **MTP gives ~2x speedup**, making the RTX 6000 Ada faster than an A100 without MTP.

## Why

- Current RTX 3090 (24GB): only 1 slot at 131K (half native context)
- Friends paying 180 EUR/mo to Anthropic for nerfed models
- RTX 6000 Ada + MTP: 4 slots at 262K, **~60-73 tok/s** (2x base), uncensored, private
- RTX 6000 Ada with MTP is **faster than an A100 without MTP** (50 tok/s) at **half the price**

---

## Phase 1: RunPod Pod Setup

### 1.1 Create RunPod Pod

- **Template:** Custom (bring your own Docker image)
- **GPU:** RTX 6000 Ada (48 GB)
- **Pricing:** Spot ($0.39/hr)
- **Storage:** Attach a Network Volume (50 GB minimum) for model cache persistence across pod restarts
- **Ports:** Expose 8080 (llama-swap) via RunPod's public proxy or TCP
- **Environment variables:** Same as current `docker-compose.yml`

### 1.2 Docker Image

**Use `arkste/llama-swap-mtp:latest` from Docker Hub.**

This image already contains:
- `llama-swap` v211 (model hot-swapping, on-demand loading)
- `llama-server` built with MTP support (PR #22673 merged)
- CUDA 12.9.1 runtime, Ubuntu 24.04
- Supports CUDA archs: 75;80;86;89;90;100;120 (covers all NVIDIA GPUs including RTX 6000 Ada)

Source: https://github.com/arkste/llama-swap-mtp

This is the SAME image already running locally at `~/src/llama-swap-mtp/`.

**Why llama-swap over raw llama-server?**
- Hot-swaps models on demand (only loads what's needed)
- TTL-based auto-unload (frees VRAM when idle)
- Single port, multiple models behind the scenes
- Already tested locally

### 1.3 Model Storage

- Attach a **RunPod Network Volume** (persistent across pod restarts)
- Mount at `/models/`
- Download MTP-enabled GGUF from HuggingFace on first start
- Recommended: `froggeric/Qwen3.6-27B-MTP-GGUF` (Q6_K-mtp or Q5_K_M-mtp)
- Subsequent starts: models already cached, instant load

---

## Phase 2: Configuration Changes

### 2.1 llama-swap config for cloud (with MTP)

Create `config-cloud.yaml` based on the working local config at `~/src/llama-swap-mtp/config.yaml`:

```yaml
healthCheckTimeout: 900
logLevel: info
logToStdout: both
ttl: 120

globalTTL: 300              # Unload after 5 min idle (save spot cost)

models:
  qwen36-27b-mtp:
    proxy: "http://127.0.0.1:${PORT}"
    checkEndpoint: /health
    cmd: >
      llama-server
      -m /models/Qwen3.6-27B-Q5_K_M-mtp.gguf
      --no-mmproj
      --alias qwen36-27b
      --host 127.0.0.1
      --port ${PORT}
      --spec-type mtp
      --spec-draft-n-max 3
      --ctx-size 262144              # Full native context!
      --n-gpu-layers -1
      --parallel 4                   # 4 simultaneous agent slots
      --jinja
      --chat-template-kwargs '{"preserve_thinking": true}'
      --cache-type-k q8_0
      --cache-type-v q8_0
      --flash-attn on
      --batch-size 2048
      --ubatch-size 512
      --reasoning on
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0.0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --perf
      --metrics
```

### 2.2 MTP Speedup Data

From Reddit (1,155 upvotes) and llama-swap-mtp README benchmarks:

| GPU | Quant | Without MTP | With MTP | Speedup | Acceptance |
|-----|-------|-------------|----------|---------|------------|
| RTX 5090 | Q6_K-mtp | 57.4 tok/s | 116.1 tok/s | **2.02x** | 70.2% |
| RTX 5090 | UD Q6_K_XL | 53.3 tok/s | 111.1 tok/s | **2.08x** | 69.9% |
| RTX Pro 6000 | Q8_K_XL | 41 tok/s | 100 tok/s | **2.44x** | - |
| RTX 3090 Ti | IQ4_XS | ~40 tok/s | ~100 tok/s | **~2.5x** | - |
| RTX Pro 6000 MaxQ | Q8_0 | 36 tok/s | 78 tok/s | **2.17x** | - |

**Projected for RTX 6000 Ada (48GB, 960 GB/s, same arch as RTX Pro 6000):**

| Metric | Without MTP | With MTP (2.2x) |
|--------|-------------|------------------|
| Generation (short ctx) | ~33 tok/s | **~73 tok/s** |
| Generation (32K ctx) | ~22 tok/s | **~48 tok/s** |
| With 4 slots (1 active) | ~33 tok/s | **~73 tok/s** |
| With 4 slots (2 active) | ~17 tok/s each | **~37 tok/s each** |
| With 4 slots (3 active) | ~11 tok/s each | **~24 tok/s each** |
| With 4 slots (4 active) | ~8 tok/s each | **~18 tok/s each** |

**RTX 6000 Ada + MTP is faster than A100 without MTP (50 tok/s) at half the price!**

### 2.3 MTP model selection

| GGUF | Source | Notes |
|------|--------|-------|
| `Qwen3.6-27B-Q5_K_M-mtp.gguf` | [froggeric](https://huggingface.co/froggeric/Qwen3.6-27B-MTP-GGUF) | Good balance, fits 48GB with room |
| `Qwen3.6-27B-Q6_K-mtp.gguf` | froggeric | Higher quality, ~22GB model |
| `Qwen3.6-27B-MTP-UD-Q6_K_XL.gguf` | [havenoammo](https://huggingface.co/havenoammo/Qwen3.6-27B-MTP-UD-GGUF) | Unsloth UD XL quant + MTP graft |

**Recommendation:** Q6_K-mtp for quality, Q5_K_M-mtp for speed. Both support full 262K context on 48GB with q8_0 KV.

### 2.4 Docker Compose override

```yaml
services:
  llama-swap-mtp:
    image: arkste/llama-swap-mtp:latest
    ports:
      - "8080:8080"
    volumes:
      - runpod-network-volume:/models
      - ./config-cloud.yaml:/etc/llama-swap/config/config.yaml:ro
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

---

## Phase 3: Auth Proxy

### 3.1 nginx with API key validation

Add an nginx container in front of llama-server:

```nginx
# nginx.conf
server {
    listen 8081;
    
    location /v1/ {
        # Validate API key
        if ($http_authorization != "Bearer <user-key>") {
            return 401;
        }
        proxy_pass http://llama-server:8080;
        proxy_set_header Host $host;
        proxy_read_timeout 300s;
    }
}
```

### 3.2 Per-user keys

- Generate a random API key per friend
- Store in a simple `.htpasswd`-style file or env vars
- Friends use `apiKey: <their-key>` in their Pi/Hermes config

**Simpler alternative:** Use a single shared Bearer token. Rotate if compromised. Less overhead for 3-4 trusted friends.

---

## Phase 4: Auto-Restart & Resilience

### 4.1 Spot preemption handler

RunPod provides a preemption signal before killing the pod. Use it:

```bash
#!/bin/bash
# scripts/spot-handler.sh
# RunPod calls this when preemption is imminent

while true; do
    if curl -s http://localhost:8080/health > /dev/null 2>&1; then
        sleep 30
    else
        echo "Server down, waiting for restart..."
        sleep 10
    fi
done
```

### 4.2 Startup script

The existing `entrypoint.sh` already handles:
- Model download from HuggingFace
- Router mode startup
- Health checks

Add to `entrypoint.sh`:
- Log GPU info on startup (verify correct GPU assigned)
- Log VRAM available vs model requirements
- Set `--host 0.0.0.0` for external access

### 4.3 Local fallback routing

For genar's own Pi agents:
- Configure primary endpoint as `https://<runpod-endpoint>/v1`
- Configure fallback endpoint as `http://localhost:11434/v1`
- Pi already supports fallback routing via provider config

---

## Phase 5: Validation & Testing

### 5.1 Smoke tests

After deployment, run:

```bash
# Health check
curl https://<endpoint>/health

# List models
curl https://<endpoint>/v1/models

# Generation test (without MTP)
curl https://<endpoint>/v1/chat/completions \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen36-27b-mtp","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# Benchmark — compare with/without MTP
# Adapt scripts/bench-model.sh to measure tok/s from timings header
```

### 5.2 MTP verification

- Confirm `--spec-type mtp` is active in server logs
- Check `spec-draft-n-max 3` and acceptance rate in metrics
- Verify 2x+ speedup vs local 3090 baseline (28 tok/s)
- Target: >55 tok/s on short context with MTP

### 5.3 Multi-user stress test

- Launch 3 concurrent agent sessions
- Verify all 3 get responses simultaneously
- Check VRAM usage with `nvidia-smi` inside container
- With MTP: target >20 tok/s per user with 3 active (vs ~11 without MTP)

### 5.4 Preemption recovery test

- Manually stop the pod
- Verify auto-restart brings it back within ~2 min
- Verify model reloads from cached Network Volume (MTP GGUF persists)

---

## Phase 6: Monitoring

### 6.1 Usage tracking

The existing `scripts/track-usage.sh` can be adapted:
- Log per-user request counts (via auth proxy access logs)
- Track token throughput
- Alert on VRAM exhaustion

### 6.2 Cost tracking

- RunPod provides billing API
- Script to pull daily/monthly costs
- Split automatically by user count

---

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `config-cloud.yaml` | **Create** | llama-swap config: MTP + parallel=4 + ctx=262144 |
| `docker-compose.cloud.yml` | **Create** | RunPod-specific compose using `arkste/llama-swap-mtp` |
| `scripts/deploy-runpod.sh` | **Create** | One-command deploy to RunPod |
| `scripts/spot-handler.sh` | **Create** | Preemption resilience |
| `config/nginx-proxy.conf` | **Create** | Auth proxy config |
| `docs/plans/2026-05-09-runpod-cloud-deployment.md` | **Create** | This file |

---

## Timeline

| Phase | Effort | Depends on |
|-------|--------|-----------|
| Phase 1: Pod setup | 2 hours | RunPod account + GHCR push |
| Phase 2: Config | 30 min | Phase 1 |
| Phase 3: Auth proxy | 1 hour | Phase 1 |
| Phase 4: Resilience | 1 hour | Phase 1 |
| Phase 5: Validation | 1 hour | Phases 1-4 |
| Phase 6: Monitoring | 2 hours | Phase 5 stable |

**Total: ~7-8 hours of work. Can be done in one evening.**

---

## Rollback Plan

If cloud doesn't work out:
- Friends continue using Anthropic (or switch back)
- genar continues using local 3090 (unchanged)
- All changes are additive (new config files, not modifying existing ones)
- No risk to current local setup

---

## MTP (Multi-Token Prediction) — Key Findings

**What it is:** Qwen3.6 was trained with 3 MTP heads that predict future tokens in parallel. llama.cpp PR #22673 enables speculative decoding using these heads, verifying draft tokens against the main model. When acceptance is high (70-90%), generation speed roughly doubles.

**Why it matters for this project:**
- RTX 6000 Ada at $0.39/hr + MTP = **~73 tok/s** (faster than A100 at $0.82/hr without MTP at 50 tok/s)
- 4 friends with agents get **20+ tok/s each** instead of 8-11 tok/s
- MTP acceptance is highest on code/math tasks (agent workloads) — exactly what Pi/Hermes do

**Constraints:**
- Requires MTP-enabled GGUF (not standard GGUF files)
- Vision (mmproj) currently crashes with MTP enabled — text-only for now
- ~20% slower prompt processing (prefill) with MTP
- MTP acceptance varies: code ~88%, creative ~45%

**Sources:**
- Reddit: r/LocalLLaMA/comments/1t57xuu/ (1,155 upvotes)
- Reddit: r/LocalLLaMA/comments/1t5ageq/ (169 upvotes)
- Docker image: https://github.com/arkste/llama-swap-mtp
- MTP GGUFs: https://huggingface.co/froggeric/Qwen3.6-27B-MTP-GGUF
- llama.cpp PR: https://github.com/ggml-org/llama.cpp/pull/22673

## Future Improvements (Post-Launch)

- **2nd RTX 3090 at home:** Buy for 500 EUR, move everything back home. MTP would give ~50 tok/s on 2x 3090.
- **A100 upgrade:** If 4 users become 6+, upgrade to A100 80GB (with MTP: projected ~110 tok/s!)
- **Multiple models:** llama-swap supports hot-swapping — add qwen35-9b for quick tasks
- **Rate limiting:** Per-user token limits if fairness becomes an issue
- **Vision support:** Once llama.cpp MTP+vision crash is fixed, enable mmproj for image tasks
