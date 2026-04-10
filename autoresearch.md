# Autoresearch: Optimal 3-Model Setup for Developer Workflow

## Objective
Find the best 3 models to run on a single RTX 3090 (24GB VRAM) via llama.cpp router mode, covering all developer needs: agentic coding (Pi agent, OpenCode), reasoning + vision (OpenWebUI), and fast tasks (pi-crons, quick Q&A). Reduce reliance on cloud LLM providers.

## Hardware
- GPU: NVIDIA RTX 3090 (24GB VRAM)
- RAM: 96GB DDR4
- CPU: AMD Ryzen 7 5800X (8C/16T)
- Server: llama.cpp in router mode, models-max=1, port 11434

## Metrics
- **Primary**: `composite_score` (score, higher is better) — weighted: agent 40%, think 25%, speed 20%, reliability 15% + time penalty
- **Secondary**: `avg_tps`, per-test scores, quality percentages

## How to Run
`bash autoresearch.sh <model-alias> [slot]` — outputs METRIC lines.

## Final Recommendation

| Slot | Model | t/s | Speed Avg | Why |
|------|-------|-----|-----------|-----|
| **1 — Agent** | GLM-4.7-Flash 23B-A3B | 100 | 2.6s | APEX #1 coder. Same quality as 27B, 3.7x faster |
| **2 — Thinker** | Gemma 4 31B + mmproj | 25 | 4.2s | Only vision model. Perfect agent+think quality |
| **3 — Speed** | Gemma 4 26B-A4B | 81 | **1.4s** | Fastest speed tasks. 90 t/s, perfect quality |

See `docs/plans/2026-04-10-optimal-3-model-setup-results.md` for full analysis.

## All Results (11 runs, 7 models)

| Model | Composite | Agent% | Think% | Speed% | Rel% | Avg t/s |
|-------|-----------|--------|--------|--------|------|---------|
| GLM-4.7-Flash | 95 | 95 | 93 | 96 | 100 | 100 |
| Gemma 4 26B | 92 | 95 | 100 | 100 | 100 | 81 |
| Qwen3.5-27B | 92 | 95 | 93 | 80 | 100 | 27 |
| Gemma 4 31B | 95 | 100 | 100 | 79 | 100 | 25 |
| Qwopus3.5-27B | 96* | 95 | 100 | 92 | 100 | 26 |
| Qwen3.5-35B-A3B | 89 | 95 | 87 | 76 | 100 | 38 |
| Qwen3.5-9B | 31 | 52 | 43 | 7 | 0 | 49 |

## What's Been Tried
- Reddit research: r/LocalLLaMA, r/llamacpp — community recommendations compiled
- 8 benchmark tests: tool use, bug fix, planning, algorithm, debugging, QA, completion, hallucination
- Fixed GLM scoring: models that use `reasoning_content` field now handled correctly
- Added time-weighted penalty: slow speed tasks (>2s) penalize composite score
- Qwen3.5-35B-A3B MoE eliminated: slower AND lower quality than alternatives
- Qwen3.5-9B eliminated: unreliable (hallucinates on fake prompts)
- GLM-4.7 is the hidden gem: APEX #1 local coder, 100 t/s, matches Qwen quality
- Gemma 4 family dominates: both 26B and 31B outperform Qwen on speed+quality combo

## Files in Scope
- `autoresearch.sh` — benchmark script (8 tests, ~55-150s per run)
- `config/models.ini` — model presets
- `docs/plans/2026-04-10-optimal-3-model-setup-results.md` — full analysis

## Off Limits
- `docker-compose.yml` networking/proxy config

## Constraints
- 24GB VRAM hard limit, models-max=1
