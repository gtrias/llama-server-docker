# Llama Server Benchmark Design

**Date**: 2026-04-19
**Status**: Approved
**Goal**: Identify why the PI agent session stops after context compaction, and measure real model performance for future comparison with ik_llama.cpp.

## Background

The PI agent uses the local Qwen 3.6 (APEX I-Compact, 17GB) as its primary model. After extended work sessions, the agent's context fills up, compaction triggers, and the session stops — it doesn't resume work. The root cause is unknown (could be model timeout, OOM, framework bug, or context-related).

## Components

### Part 1 — Model Benchmark (`scripts/bench-model.sh`)

Measures raw model performance across different context sizes.

**What it tests:**
- Token generation speed (tok/s) at context sizes: 4K, 16K, 32K, 64K, 128K
- Time to first token (TTFT) at each context size
- VRAM usage at each context size
- Detects OOM, timeouts, or errors

**How it works:**
1. Sends a completion request with increasing `n_predict` to fill context
2. Then measures generation speed on a follow-up prompt
3. Records VRAM via `nvidia-smi` before and after each test
4. Uses the existing llama-server API at `localhost:11434`

**Output format:**
```
=== Model Benchmark (Qwen3.6-35B-A3B-APEX-I-Compact) ===
| Context | Tok/s gen | TTFT (ms) | VRAM (MB) | Status |
|---------|-----------|-----------|-----------|--------|
| 4K      | 28.5      | 120       | 19760     | OK     |
| 32K     | 22.1      | 450       | 21200     | OK     |
| 128K    | 5.2       | 8500      | 24100     | SLOW   |
```

### Part 2 — Session Benchmark (`scripts/bench-session.sh`)

Simulates a real PI agent work session and monitors when/why it stops.

**What it tests:**
- Sequential API calls with increasing context (simulating agent work)
- Monitors: tok/s per call, accumulated context size, VRAM usage
- Detects exactly when the session fails: timeout, HTTP error, OOM, or post-compaction
- Captures llama-server logs during the session

**How it works:**
1. Makes sequential chat completion calls, each adding ~2K tokens to context
2. After each call, records: tokens used, generation speed, VRAM
3. When context approaches limit, observes compaction behavior
4. Continues calling after compaction to see if session resumes
5. Captures `docker logs llama-server` throughout

**Output format:**
```
=== Session Benchmark ===
Call  1:   4K ctx, 28 t/s, 19.7GB VRAM → OK
Call  2:   8K ctx, 26 t/s, 20.1GB VRAM → OK
...
Call 12:  52K ctx, 15 t/s, 22.8GB VRAM → COMPACTION triggered
Call 13:   8K ctx (post-compaction), ??? t/s → SESSION STOPPED (timeout 30s)

=== Server Logs (last 20 lines at failure point) ===
[timestamp] ...
```

## Files

| File | Purpose |
|------|---------|
| `scripts/bench-model.sh` | Model performance benchmark |
| `scripts/bench-session.sh` | PI session simulation benchmark |
| `docs/plans/2026-04-19-llama-benchmark-design.md` | This design doc |

## YAGNI

- No ik_llama comparison yet (need baseline first)
- No changes to models.ini, Dockerfile, or docker-compose.yml
- No new software installed
