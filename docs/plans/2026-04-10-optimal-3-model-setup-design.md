# Design: Optimal 3-Model Setup for Developer Workflow

**Date**: 2026-04-10
**Hardware**: RTX 3090 (24GB VRAM), 96GB RAM, Ryzen 7 5800X (8C/16T)
**Constraint**: llama.cpp router mode, 1 model loaded at a time (models-max=1)

## Objective

Identify the 3 best models to configure in this NAS to cover all developer needs as a daily driver, reducing reliance on cloud providers. Build a reproducible benchmark framework to continuously evaluate models, quantization levels, and llama.cpp server configurations.

## User Context

- **Primary tool**: Pi agent (agentic coding via channels/crons)
- **Secondary**: OpenWebUI (conversational), OpenCode (v1.3.17, parallel sessions), pi-channels/pi-crons (automated)
- **Current daily driver**: Qwen3.5-27B-Q4_K_M — solid results but slow prompt processing (prefill)
- **Current fast model**: Qwen3.5-9B-Q8_0 — super fast but "dementia" (hallucinates, loses instructions)
- **Untested**: Qwen3.5-35B-A3B — community raves about it on RTX 3090 but user suspects 27B is higher quality

## Reddit Research Findings (r/LocalLLaMA, r/llamacpp)

### Slot 1 — Agent King (agentic coding, tool use, Pi/OpenCode)

| Model | Community Signal | Fit for 3090 |
|-------|-----------------|---------------|
| Qwen3.5-35B-A3B MoE | 1.2K upvotes, "gamechanger for agentic coding" on RTX 3090, 100+ t/s, ~22GB VRAM. BUT APEX benchmark shows it's worse than 27B on multi-step agentic (1256 vs 1384 ELO) | ✅ Fits VRAM, MoE = fast prefill |
| Qwen3.5-27B dense | APEX: 1384 ELO, "genuinely decent on single GPU", consistent on hard tasks. Currently user's daily driver | ✅ 16GB, but slow prefill |
| GLM-4.7-Flash-REAP-23B-A3B | APEX: 1572 ELO, "still the local GOAT", beats all Qwen3.5 models | ✅ 13GB, MoE architecture |
| Qwen3-Coder-Flash 30B-A3B | New release, purpose-built for Cline/Roo/Kilo Code, 256K context | ⚠️ May be tight on 24GB at Q4 |

**Key tradeoff**: MoE models (35B-A3B, GLM-4.7) have much faster prefill but lower active parameters = potentially weaker on hard multi-step tasks. Dense 27B has more active params but slower.

### Slot 2 — Deep Thinker (reasoning, vision, complex tasks)

| Model | Community Signal | Vision |
|-------|-----------------|--------|
| Gemma 4 31B | 1824 upvotes, "destroyed every model except Opus 4.6", 100% survival on agentic benchmark | ✅ mmproj available |
| Qwen3.5-27B | Same as Slot 1 — could serve double duty | ✅ mmproj available |
| Gemma 4 26B-A4B | 668 upvotes, 80-110 t/s, "mindblowingly good if configured right" | ❌ No vision |

### Slot 3 — Speed Demon (fast Q&A, pi-crons, quick tasks)

| Model | Community Signal | Speed |
|-------|-----------------|-------|
| Qwen3.5-9B Q8_0 | Current fast model, works as agent on even 16GB M1 Pro | ~150+ t/s |
| Gemma 4 26B-A4B | 80-110 t/s on 3090, surprisingly capable | Fast for its size |
| GLM-4.7-Flash 23B-A3B | MoE, 1572 ELO — could double as both agent and fast model | Fast prefill |

## 3-Slot Architecture

```
┌─────────────────┬───────────────────┬───────────────────┐
│  SLOT 1         │  SLOT 2           │  SLOT 3           │
│  AGENT KING      │  DEEP THINKER     │  SPEED DEMON      │
│  Pi, OpenCode    │  OpenWebUI,       │  pi-crons,        │
│                  │  complex reasoning│  quick tasks      │
├─────────────────┼───────────────────┼───────────────────┤
│  PRIORITY:       │  PRIORITY:        │  PRIORITY:        │
│  • Tool calling  │  • Reasoning      │  • Latency        │
│  • Prefill speed │  • Vision         │  • Throughput     │
│  • Code quality  │  • Long context   │  • Reliability    │
│                  │  • Writing        │                   │
├─────────────────┼───────────────────┼───────────────────┤
│  TO TEST:        │  TO TEST:         │  TO TEST:         │
│  1. Qwen3.5-27B  │  1. Gemma 4 31B  │  1. Qwen3.5-9B   │
│  2. Qwen3.5-35B  │  2. Gemma 4 26B  │  2. Gemma 4 26B  │
│     -A3B         │  3. Qwen3.5-27B  │  3. GLM-4.7-23B  │
│  3. GLM-4.7-23B  │     (reuse)      │                   │
│  4. Qwen3-Coder  │                   │                   │
│     Flash 30B    │                   │                   │
└─────────────────┴───────────────────┴───────────────────┘
```

## Benchmark Framework (autoresearch.sh)

### Tests Per Slot

**Slot 1 — Agent Benchmark**
- Real agentic task: "Fix the bug in this file" / "Add endpoint X to this API"
- Measure: task success (binary), tokens/sec, prefill time, total time
- Test via OpenAI-compatible API on localhost:11434

**Slot 2 — Reasoning + Vision Benchmark**
- Coding question requiring multi-step reasoning
- Vision task: read a screenshot/diagram, describe what to implement
- Measure: quality (LLM-as-judge scoring 1-5), tokens/sec, prefill time

**Slot 3 — Speed Benchmark**
- Simple Q&A and code completion tasks
- Measure: latency (ttft), tokens/sec, parallel throughput
- Also test "reliability" — does it hallucinate on simple tasks?

### Metrics

- **Primary**: Composite score (weighted: agent_quality * 0.4 + speed * 0.3 + reliability * 0.3)
- **Secondary**: prefill_ms (prompt processing time), decode_tps (tokens/sec), vram_gb, ctx_tokens

### Optimization Loop

After picking winners per slot:
1. Test different quantization levels (Q4_K_M, Q4_K_XL, Q5_K_M, Q6_K, Q8_0 where VRAM allows)
2. Optimize llama.cpp settings (cache-type-k/v, flash-attn, parallel, ctx-size, speculative decoding)
3. Test different llama.cpp versions (bleeding edge vs stable)
4. Measure impact on composite score

## Constraints

- 24GB VRAM hard limit (single GPU)
- models-max=1 (router mode, one model at a time)
- Must work via OpenAI-compatible API on port 11434
- Models must have GGUF quantizations available
- No changes to docker-compose.yml networking/proxy setup
- Benchmark must be reproducible (same prompts, same scoring)

## Files in Scope

- `config/models.ini` — model presets (main deliverable)
- `autoresearch.sh` — benchmark script
- `autoresearch.md` — experiment session docs
- `scripts/` — helper scripts for benchmarking
- `.env` — server configuration
- `entrypoint.sh` — server startup (if config changes needed)

## Off Limits

- `docker-compose.yml` network/proxy/traefik config
- Custom llama.cpp binary modifications
- Any model > 24GB VRAM at target quantization
