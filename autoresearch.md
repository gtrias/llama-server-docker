# Autoresearch: Optimal 3-Model Setup for Developer Workflow

## Objective
Find the best 3 models to run on a single RTX 3090 (24GB VRAM) via llama.cpp router mode, covering all developer needs: agentic coding (Pi agent, OpenCode), reasoning + vision (OpenWebUI), and fast tasks (pi-crons, quick Q&A). Reduce reliance on cloud LLM providers.

## Hardware
- GPU: NVIDIA RTX 3090 (24GB VRAM)
- RAM: 96GB DDR4
- CPU: AMD Ryzen 7 5800X (8C/16T)
- Server: llama.cpp in router mode, models-max=1, port 11434

## Metrics
- **Primary**: `composite_score` (score, higher is better) — weighted: agent 40%, think 25%, speed 20%, reliability 15%
- **Secondary**: `avg_tps`, per-test scores, quality percentages

## How to Run
`bash autoresearch.sh <model-alias> [slot]` — outputs METRIC lines.
Slots: agent, thinker, speed, all (default).

## 3 Slots
1. **Slot 1 — Agent King**: Pi agent, OpenCode. Needs tool calling, fast prefill, code quality.
2. **Slot 2 — Deep Thinker**: OpenWebUI, complex reasoning, vision. Needs quality + vision.
3. **Slot 3 — Speed Demon**: pi-crons, quick tasks. Needs low latency, throughput, reliability.

## Results (7 models tested)

| Rank | Model | Composite | Agent% | Think% | Speed% | Rel% | Avg t/s |
|------|-------|-----------|--------|--------|--------|------|---------|
| 1 | **Gemma 4 26B-A4B** | **98** | 95 | 100 | 100 | 100 | 81 |
| 2 | Qwen3.5-27B | 95 | 100 | 93 | 85 | 100 | 27 |
| 3 | Gemma 4 31B | 96 | 100 | 93 | 92 | 100 | 24 |
| 3 | Qwopus3.5-27B | 96 | 95 | 100 | 92 | 100 | 25 |
| 5 | Qwen3.5-35B-A3B | 45 | 52 | 37 | 7 | 100 | 62 |
| 6 | Qwen3.5-9B | 31 | 52 | 43 | 7 | 0 | 49 |
| 7 | GLM-4.7-Flash* | 14 | 30 | 0 | 14 | 0 | 80 |

*GLM-4.7 scored low due to keyword matching issues — it's actually the APEX benchmark #1 local coder and runs at 100 t/s. Needs manual evaluation.

## Current Recommendation (preliminary)

Based on benchmark data:

| Slot | Model | Rationale |
|------|-------|-----------|
| **1 (Agent)** | Qwen3.5-27B | Highest agent quality (100%), best tool use. Slow (27 t/s) but most capable for complex agentic tasks. |
| **2 (Thinker)** | Gemma 4 31B | Vision capability, quality=100%, debugging=8/9. Slower but this slot prioritizes quality. |
| **3 (Speed)** | Gemma 4 26B | Perfect scores on think/speed/reliability. 872ms QA, 90 t/s. Best speed demon. |

**Alternative**: If you don't need vision, use Gemma 4 26B for both Slot 2 and Slot 3 (it scores highest overall) and keep 27B for Slot 1.

**Caveats**:
- GLM-4.7 needs manual re-evaluation (benchmark keyword matching failed)
- Qwen3.5-35B-A3B underperformed expectations (MoE lower active params hurt quality)
- Speed benchmarks should add time-weighted scoring (current scoring barely penalizes slow models)

## Files in Scope
- `autoresearch.sh` — benchmark script (8 tests across 3 categories)
- `config/models.ini` — model presets
- `scripts/benchmark/` — benchmark task definitions

## Off Limits
- `docker-compose.yml` networking/proxy config

## Constraints
- All models via OpenAI-compatible API on port 11434
- models-max=1 (one model at a time)
- 24GB VRAM hard limit

## What's Been Tried
- Reddit research complete: community recommends Qwen3.5-35B-A3B for agents, Gemma 4 for reasoning, 9B for speed
- 7 models benchmarked on real developer tasks (tool use, bug fix, planning, algorithms, debugging, QA, completion, hallucination)
- Gemma 4 26B is the surprise winner: fastest + highest quality combo
- Qwen3.5-27B is the quality king for complex tasks but 3x slower
- GLM-4.7-Flash benchmark broken — needs manual evaluation
- Qwen3.5-9B unreliable (hallucinates) — not suitable for automated workflows
- Qwen3.5-35B-A3B MoE disappointing — only 3B active params hurts on complex tasks
