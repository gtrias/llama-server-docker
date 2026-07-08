# Plan: RunPod Cloud Test — Pod + Serverless A/B Comparison

**Date:** 2026-05-10  
**Status:** Ready to execute  
**Author:** genar (via Pi agent)  
**Goal:** Deploy and benchmark Qwen3.6-27B with MTP on RunPod, comparing Pod vs Serverless, to decide deployment model and GPU choice.

---

## Overview

Two-phase test:

| Phase | Type | GPU | Image | Duration | Purpose |
|-------|------|-----|-------|----------|---------|
| **A** | Pod (spot) | A40 (48GB, $0.20/hr) | `arkste/llama-swap-mtp` | ~2 hours | Baseline benchmarks + MTP verification |
| **B** | Serverless | A40 (48GB) | `arkste/llama-swap-mtp` | ~1 day | Real-world agent workload cost measurement |

**Why A40 first, not RTX 6000 Ada?**
- A40 spot: $0.20/hr = $1.60 for an 8-hour test vs $3.12 for RTX 6000 Ada
- Same 48GB VRAM, same slot capacity, just slower bandwidth
- If A40 works well enough, it might be the final choice for single-player
- Can always test RTX 6000 Ada later if A40 is too slow

**Total test cost estimate:** $5-10

---

## Phase A: Pod Test (today, ~2 hours)

### A1. Create Network Volume

1. Go to **Storage → Network Volumes → + New**
2. Name: `llama-models`
3. Size: **50 GB**
4. Region: **EU (closest)** — pick the same region for the pod

### A2. Create Pod

1. **GPU → Deploy → Custom**
2. Settings:
   - **GPU:** A40 (48 GB) — 1 GPU
   - **Pricing:** Spot ($0.20/hr)
   - **Image:** `arkste/llama-swap-mtp:latest`
   - **Volume:** Mount `llama-models` at `/models`
   - **Ports:** Expose **8080** (HTTP) — click "Open" after pod starts
   - **Environment Variables:**
     ```
     CUDA_VISIBLE_DEVICES=0
     ```
3. Click **Deploy**

### A3. Download Model into Pod

Once pod is running, open the **Web Terminal** (or SSH):

```bash
# Check GPU
nvidia-smi

# Download MTP model from HuggingFace
cd /models
wget -q --show-progress "https://huggingface.co/froggeric/Qwen3.6-27B-MTP-GGUF/resolve/main/Qwen3.6-27B-Q5_K_M-mtp.gguf" -O Qwen3.6-27B-Q5_K_M-mtp.gguf

# Verify
ls -lh /models/Qwen3.6-27B-Q5_K_M-mtp.gguf
```

Expected: ~16 GB file, ~3-5 min download on RunPod's network.

### A4. Write Config

In the pod's web terminal:

```bash
cat > /etc/llama-swap/config/config.yaml << 'YAML'
healthCheckTimeout: 900
logLevel: debug
logToStdout: both
ttl: 120

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
      --ctx-size 262144
      --n-gpu-layers -1
      --parallel 2
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
YAML
```

**Note:** Using `parallel 2` with `q8_0` KV for this test (A40 has 48GB, q8_0 with 262K = ~25 GB KV + 16 GB model = fits 2 slots). Can switch to `parallel 4` with `q4_0` KV after verifying baseline.

### A5. Start Server

```bash
# llama-swap should already be running as the container entrypoint
# If not, start it:
llama-swap -config /etc/llama-swap/config/config.yaml

# Watch logs
tail -f /var/log/llama-swap.log
```

Wait for model to load and health check to pass (~30-60s).

### A6. Run Benchmarks

From your LOCAL machine, using the pod's public URL (find in RunPod console → Ports → 8080 → URL):

```bash
export POD_URL="https://<your-pod-id>-8080.proxy.runpod.net"

# 1. Health check
curl -s "$POD_URL/health" | jq

# 2. List models
curl -s "$POD_URL/v1/models" | jq

# 3. Simple generation — check MTP is active
curl -s "$POD_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen36-27b-mtp",
    "messages": [{"role": "user", "content": "Write a Python function to reverse a linked list"}],
    "max_tokens": 200,
    "temperature": 0.6
  }' | jq '{usage, timings: .timings}'

# 4. Speed benchmark — short context
time curl -s "$POD_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen36-27b-mtp",
    "messages": [{"role": "user", "content": "Count from 1 to 100"}],
    "max_tokens": 500,
    "temperature": 0
  }' > /tmp/bench-short.json

# Calculate tok/s from response
cat /tmp/bench-short.json | jq '{tokens: .usage.completion_tokens, total_time_s: (.timings.prompt_n / .timings.prompt_per_second + .usage.completion_tokens / .timings.predicted_per_second), prompt_t/s: .timings.prompt_per_second, gen_t/s: .timings.predicted_per_second, mtp_acceptance: .timings.speculative_accepted_percent}'

# 5. Speed benchmark — longer context
time curl -s "$POD_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen36-27b-mtp",
    "messages": [
      {"role": "system", "content": "You are a helpful coding assistant."},
      {"role": "user", "content": "Write a complete Express.js REST API for a todo app with CRUD operations, validation, error handling, and JWT auth. Include all middleware."}
    ],
    "max_tokens": 1000,
    "temperature": 0.6
  }' > /tmp/bench-long.json

cat /tmp/bench-long.json | jq '{tokens: .usage.completion_tokens, gen_t/s: .timings.predicted_per_second, mtp_acceptance: .timings.speculative_accepted_percent}'

# 6. VRAM check (inside pod)
nvidia-smi
```

### A7. Record Results

Fill in this table after the test:

```
╔══════════════════════════════════════════════════╗
║           POD TEST RESULTS (Phase A)             ║
╠══════════════════════════════════════════════════╣
║ GPU:         A40 (48GB, 696 GB/s)                ║
║ Model:       Qwen3.6-27B-Q5_K_M-mtp.gguf        ║
║ Context:     262,144 tokens                      ║
║ Parallel:    2                                   ║
║ KV cache:    q8_0                                ║
╠══════════════════════════════════════════════════╣
║ VRAM used:       ___ / 48 GB                     ║
║ Prompt speed:    ___ tok/s                       ║
║ Gen speed (short): ___ tok/s (MTP ___x)          ║
║ Gen speed (long):  ___ tok/s (MTP ___x)          ║
║ MTP acceptance:  ___%                            ║
║ TTFT (short):    ___ seconds                     ║
║ TTFT (long):     ___ seconds                     ║
║ Cost this test:  $___                            ║
╠══════════════════════════════════════════════════╣
║ LOCAL 3090 BASELINE (for comparison)             ║
║ Gen speed:       28.4 tok/s (no MTP)             ║
║ TTFT:            9.3s                            ║
║ Speedup:         ___x vs local                   ║
╚══════════════════════════════════════════════════╝
```

### A8. Decision Gate

After Phase A results:

| If A40 speed is... | Next step |
|---------------------|-----------|
| **>40 tok/s** with MTP | Proceed to Phase B (serverless test) |
| **30-40 tok/s** | Consider testing RTX 6000 Ada pod instead |
| **<30 tok/s** | Skip serverless, go straight to RTX 6000 Ada pod |

---

## Phase B: Serverless Test (next day, ~24 hours)

### B1. Create Serverless Endpoint

1. Go to **Serverless → Create Endpoint**
2. Settings:
   - **Name:** `qwen36-27b-mtp`
   - **GPU:** A40 (48 GB)
   - **Min Workers:** 0 (scale to zero)
   - **Max Workers:** 1
   - **Idle Timeout:** 300 seconds (5 min)
   - **Image:** `arkste/llama-swap-mtp:latest`
   - **Volume:** Attach `llama-models` at `/models` (reuse from Phase A!)
   - **Environment Variables:**
     ```
     CUDA_VISIBLE_DEVICES=0
     MODEL_PATH=/models/Qwen3.6-27B-Q5_K_M-mtp.gguf
     ```
3. Click **Deploy**

### B2. Configure llama-swap for Serverless

The config needs to be baked into a custom image OR mounted via Network Volume. Simplest: write it to the Network Volume in the start command.

**Option A: Start command in endpoint settings:**
```bash
cat > /etc/llama-swap/config/config.yaml << 'YAML'
healthCheckTimeout: 900
logLevel: info
logToStdout: both
ttl: 120

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
      --ctx-size 262144
      --n-gpu-layers -1
      --parallel 1
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
YAML
```

**Note:** `parallel 1` for serverless — single-user, no concurrent slot sharing needed.

### B3. Wire Pi Agent to Serverless

Update your Pi config to use the serverless endpoint:

```yaml
# In your Pi provider/model config
baseURL: "https://qwen36-27b-mtp-<endpoint-id>.runpod.net/v1"
apiKey: "<your-runpod-api-key>"
model: "qwen36-27b-mtp"
```

### B4. Run Normal Workload for 24 Hours

- Use Pi as you normally would
- Don't optimize for cost — behave naturally
- Let the serverless endpoint cold-start and warm-cycle naturally

### B5. Collect Metrics

After 24 hours:

1. **RunPod Dashboard → Billing:** Check total cost for the test period
2. **RunPod Dashboard → Serverless → Metrics:** Check:
   - Total requests processed
   - Average latency
   - Cold start count
   - Total GPU seconds billed
3. **Pi logs:** Check for timeouts or errors during cold starts

### B6. Record Results

```
╔══════════════════════════════════════════════════╗
║       SERVERLESS TEST RESULTS (Phase B)          ║
╠══════════════════════════════════════════════════╣
║ Test duration:       ___ hours                    ║
║ Total requests:      ___                          ║
║ Total tokens out:    ~___K                        ║
║ Cold starts:         ___                          ║
║ Avg cold start time: ___ seconds                  ║
║ Avg gen speed:       ___ tok/s                    ║
║ Total GPU seconds:   ___                          ║
║ Total cost:          $___                         ║
║ Extrapolated monthly: $___ (if this were 30 days) ║
║ Agent errors/timeouts: ___                        ║
╠══════════════════════════════════════════════════╣
║ POD COMPARISON (same period extrapolated)         ║
║ A40 spot 24/7:       $146/mo                      ║
║ A40 spot 16hr/day:   $97/mo                       ║
║ RTX 6000 Ada 24/7:  $282/mo                       ║
╚══════════════════════════════════════════════════╝
```

---

## Phase C: Decision Matrix

After both tests, pick one:

| Option | When to pick | Monthly cost |
|--------|-------------|-------------|
| **A40 Serverless** | <8hr/day active, cost < $100/mo, cold starts tolerable | $50-105 |
| **A40 Pod (spot 24/7)** | Multi-user, always-on needed, >12hr/day | $146 |
| **A40 Pod (spot, timed)** | Single player, turn on/off manually | $73-97 |
| **RTX 6000 Ada Pod (spot)** | Need max speed, 2-4 friends sharing | $282 |
| **Buy 2nd RTX 3090** | Cloud proves stable after 2 months | $500 one-time |

---

## Quick Reference: RunPod Pricing

| GPU | VRAM | BW | Spot $/hr | Spot 24/7 | MTP t/s est. |
|-----|------|-----|-----------|-----------|-------------|
| A40 | 48GB | 696 GB/s | $0.20 | $146/mo | ~46 tok/s |
| L40S | 48GB | 768 GB/s | $0.26 | $190/mo | ~55 tok/s |
| RTX A6000 | 48GB | 768 GB/s | $0.33 | $241/mo | ~55 tok/s |
| RTX 6000 Ada | 48GB | 960 GB/s | $0.39 | $282/mo | ~73 tok/s |

---

## Pre-flight Checklist

Before starting:

- [ ] RunPod account exists (confirmed: yes)
- [ ] RunPod billing set up (credit card on file)
- [ ] Local Pi agent working on RTX 3090 (fallback ready)
- [ ] `config-cloud.yaml` prepared
- [ ] Telegram notifications set up for cost alerts

## Cleanup

After testing:
- [ ] Delete the pod (stop billing)
- [ ] Keep the Network Volume (has the model cached, saves re-download)
- [ ] Delete the serverless endpoint
- [ ] Revert Pi config to local endpoint
- [ ] Record final cost in this document
