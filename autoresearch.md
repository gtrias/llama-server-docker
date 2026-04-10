# Autoresearch: Optimal 3-Model Setup for Developer Workflow

## Objective
Find the best 3 models to run on a single RTX 3090 (24GB VRAM) via llama.cpp router mode, covering all developer needs: agentic coding (Pi agent, OpenCode), reasoning + vision (OpenWebUI), and fast tasks (pi-crons, quick Q&A). Reduce reliance on cloud LLM providers.

## Hardware
- GPU: NVIDIA RTX 3090 (24GB VRAM)
- RAM: 96GB DDR4
- CPU: AMD Ryzen 7 5800X (8C/16T)
- Server: llama.cpp in router mode, models-max=1, port 11434

## Metrics
- **Primary**: `composite_score` (score, higher is better) — weighted composite of quality + speed + reliability per slot
- **Secondary**: `prefill_ms` (prompt processing time), `decode_tps` (tokens/sec), `vram_gb`, `task_success` (binary per task)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=value` lines. Requires llama-server running on localhost:11434.

## 3 Slots
1. **Slot 1 — Agent King**: Pi agent, OpenCode. Needs tool calling, fast prefill, code quality.
2. **Slot 2 — Deep Thinker**: OpenWebUI, complex reasoning. Needs vision, long context, high quality.
3. **Slot 3 — Speed Demon**: pi-crons, quick tasks. Needs low latency, throughput, reliability.

## Candidates
- Slot 1: Qwen3.5-35B-A3B, Qwen3.5-27B, GLM-4.7-23B, Qwen3-Coder-Flash 30B
- Slot 2: Gemma 4 31B, Gemma 4 26B-A4B, Qwen3.5-27B (reuse)
- Slot 3: Qwen3.5-9B, Gemma 4 26B-A4B, GLM-4.7-23B

## Files in Scope
- `config/models.ini` — model presets
- `autoresearch.sh` — benchmark script
- `scripts/benchmark/` — benchmark task definitions and helpers
- `.env` — server configuration

## Off Limits
- `docker-compose.yml` networking/proxy config
- Custom llama.cpp binary modifications
- Any model exceeding 24GB VRAM

## Constraints
- All models must run via OpenAI-compatible API on port 11434
- models-max=1 (one model loaded at a time)
- Benchmark must be reproducible (same prompts, deterministic scoring)
- Models must have GGUF quantizations available from HuggingFace

## What's Been Tried
- Reddit research complete (r/LocalLLaMA, r/llamacpp): community strongly recommends Qwen3.5-35B-A3B for agentic coding on 3090, Gemma 4 31B for reasoning, Qwen3.5-9B for speed
- Current setup: Qwen3.5-27B as daily driver (solid quality, slow prefill), Qwen3.5-9B as fast model (fast but hallucinates)
- APEX benchmark data shows GLM-4.7-Flash quantized = highest ELO for local coding (1572), Qwen3.5-27B = 1384, Qwen3.5-35B-A3B = 1256
- Key insight: MoE models (35B-A3B, GLM-4.7) have faster prefill due to fewer active params, but lower quality on multi-step tasks
