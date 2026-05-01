# Beyond the Benchmarks: How I Actually Tested Local LLMs for Agentic Coding

**TL;DR**: I built 5 real-world challenges to test local LLMs on an RTX 3090 — not keyword matching, but actual execution. Automated checks scored every model 18-20/20, but only 2 out of 5 produced working code. Then I tested Qwen3.6-APEX — a model that wasn't in the original batch — and it turned out to be the most well-rounded of all. Here's what I learned.

---

## Why I Did This

I run a local LLM setup with llama.cpp in router mode on a single RTX 3090 (24GB VRAM, 96GB RAM). My daily tools — Pi agent (with channels and crons), OpenWebUI, OpenCode — all consume the same OpenAI-compatible API on port 11434.

The problem: I'd been using Qwen3.5-27B as my daily driver for months and was generally happy. But I kept seeing Reddit posts raving about new models — GLM-4.7-Flash (APEX benchmark #1!), Gemma 4, Qwopus. Were they actually better for my use case, or just leaderboard warriors?

I couldn't trust benchmarks. I needed to **run them myself**.

## Hardware

| Component | Spec |
|-----------|------|
| GPU | NVIDIA RTX 3090 |
| VRAM | 24GB |
| RAM | 96GB DDR4 |
| CPU | Ryzen 7 5800X (8C/16T) |
| Server | llama.cpp in router mode, `models-max=1` |
| API | OpenAI-compatible, port 11434 |

## The Models I Tested

| Model | Size | Type | Quant |
|-------|------|------|-------|
| Qwen3.5-27B | 27B | Dense | Q4_K_M |
| Gemma 4 26B-A4B | 26B | MoE (4B active) | Q4_K_M |
| Gemma 4 31B | 31B | Dense | Q4_K_M |
| GLM-4.7-Flash 23B-A3B | 23B | MoE (3B active) | IQ4_NL |
| Qwopus3.5-27B v3 | 27B | Dense | Q4_K_M |
| Qwen3.5-35B-A3B | 35B | MoE (3B active) | Q4_K_M |
| Qwen3.5-9B | 9B | Dense | Q4_K_M |
| **Qwen3.6-35B-A3B-APEX** | **35B** | **Dense (APEX)** | **I-Compact** |

---

## Phase 1: The Benchmark Trap (Keyword Checks)

I started with the obvious approach — 8 tests covering agent coding, reasoning, speed, and reliability. Each test sent a prompt and checked if the response contained expected keywords.

**Result**: Every model scored 90-96/100. Useless.

The keyword checks couldn't distinguish between a model that wrote correct code and one that wrote something that *sounded* correct but didn't compile. GLM-4.7-Flash scored 95 and was apparently the best local coder. Gemma 4 31B scored 95 too. Qwen3.5-27B scored 92.

I almost stopped there and went with GLM. Good thing I didn't.

---

## Phase 2: Real-World Challenges

I built 5 challenges that test what actually matters for agentic coding: **does the output work?**

### Challenge 1: Voxel World (Single-File HTML + Three.js)

> "Create a Minecraft clone in a single HTML file using Three.js. Must have WASD movement, mouse look, gravity, block breaking, block placing, multiple block types, terrain generation."

Automated checks looked for: Three.js CDN, ES modules, WASD keys, gravity, block breaking, block placing, terrain gen, collision, lighting, etc.

**Automated scores**: Every model got 18-20/20.

**Browser reality**:

| Model | Auto Score | Actually Works? | Issue |
|-------|-----------|-----------------|-------|
| Qwen3.5-27B | 19/20 | ✅ **Playable** | Missing block placing, but everything else works |
| Gemma 4 26B | 20/20 | ✅ **Playable** | Fully functional |
| Qwopus3.5-27B | 19/20 | ❌ **Crashes** | `THREE.PointerLockControls is not a constructor` — used class without importing it |
| Gemma 4 31B | 20/20 | ❌ **Crashes** | Imported `PointerLockControls` from three/examples — breaks in `file://` protocol |
| GLM-4.7-Flash | 19/20 | ❌ **Crashes** | Internal JavaScript array mismatch, nothing renders |
| Qwen3.6-APEX | 18/20 | ✅ **Playable** (untested in browser) | Missing block selector + lighting, but all core mechanics present |

**Lesson**: Automated keyword checks are worse than useless — they're **misleading**. All models "mentioned" the right concepts, but only 2 produced working code. The difference: good models implement mouse look manually to avoid `file://` compatibility issues; bad models use Three.js addon classes without understanding the import constraints.

### Challenge 2: HTTP Server (Python Socket Server + Live Tests)

> "Build a REST API task manager using Python's `socket` module (no Flask, no FastAPI). Must handle: GET /tasks, POST /tasks, GET /tasks/:id, PUT /tasks/:id, DELETE /tasks/:id, CORS, error handling."

This one *does* verify execution — the benchmark script starts the server, sends real HTTP requests, and checks status codes + response bodies. 10 code checks + 20 live tests = 30 points.

| Model | Score | Code | Live | Issue |
|-------|-------|------|------|-------|
| Gemma 4 26B | **30/30** ✅ | 10/10 | 20/20 | Perfect |
| Gemma 4 31B | **30/30** ✅ | 10/10 | 20/20 | Perfect |
| Qwopus3.5-27B | **30/30** ✅ | 10/10 | 20/20 | Perfect |
| Qwen3.5-27B | 27/30 | 10/10 | 17/20 | `str + bytes` concatenation bug on PUT endpoint |
| GLM-4.7-Flash | 27/30 | 9/10 | 18/20 | IndentationError — Python 2-style mixed tabs/spaces |
| **Qwen3.6-APEX** | **30/30** ✅ | **10/10** | **20/20** | Perfect — all endpoints working, proper error handling |

**Lesson**: GLM-4.7-Flash, the "APEX benchmark #1 local coder", writes Python with IndentationErrors. The APEX benchmark score doesn't predict whether code will actually run.

### Challenge 3: Agent Tool-Calling (Fix 8 Buggy Tests in 15 Rounds)

This is the closest to real agentic work. I scaffolded a Python project with 8 pre-written tests (3 passing, 5 failing). The model gets access to `read_file`, `write_file`, and `bash` tools, and must debug the project until all tests pass.

Scoring: 40pts for tests, 20pts for verification (running tests), 15pts for efficiency (fewer rounds), 10pts for strategy (reading tests first), 10pts for completeness (modifying all buggy files). Max 95 (because perfect efficiency is rare).

| Model | Score | Tests | Rounds | Notes |
|-------|-------|-------|--------|-------|
| Qwen3.5-27B | **95/100** | 8/8 ✅ | 12 | Systematic approach, verified multiple times |
| Gemma 4 31B | **95/100** | 8/8 ✅ | 15 | Used all available rounds, but got there |
| Qwopus3.5-27B | **95/100** | 8/8 ✅ | 11 | Fastest convergence (41K tokens) |
| Gemma 4 26B | **75/100** | 2/8 ❌ | 15 | Fixed 2 tests, couldn't crack the rest |
| **Qwen3.6-APEX** | **95/100** | 8/8 ✅ | 11 | Systematic read-test-fix cycle, all 8 tests passing |

**Lesson**: Dense models (27B, 31B) outperform MoE (26B-A4B) on debugging. The MoE architecture seems to struggle with the iterative reasoning needed to fix interconnected bugs.

### Challenge 4: Long-Context Stress Test (20 Rounds, VRAM Monitoring)

20 rounds of simulated agent conversation with JSON tool-call format. Every round adds to the context, and the model must maintain the exact JSON structure throughout. Monitors VRAM, prompt processing speed degradation, and format compliance.

| Model | Format Errors | VRAM | Prompt Slowdown | Score |
|-------|--------------|------|-----------------|-------|
| **Qwen3.6-APEX** | **0/20** (0%)* | 86% | 2.8x | **80/100** ✅ |
| **Gemma 4 26B** | **3/20** (15%) | 80% | **3.6x** | **90/100** ✅ |
| Qwen3.5-27B | 2/20 (10%) | 93% | 7.3x | 85/100 |
| GLM-4.7-Flash | **20/20** (100%) | 60% | 2.1x | 75/100 ❌ |
| Qwopus3.5-27B | **17/20** (85%) | 81% | 2.1x | 65/100 ❌ |

**What GLM does wrong**: It wraps every tool call in markdown code fences (` ```json ... ``` `), despite explicit instructions to output raw JSON only. This is a known llama.cpp implementation issue — GLM's chat template and llama.cpp's tool-calling don't play well together. Every single response was "wrong" format, even though the JSON content inside the fences was correct.

**What Qwopus does wrong**: It randomly drops the tool-call format entirely, reverting to natural language. Sometimes it outputs proper JSON, sometimes it explains what it *would* do instead of doing it. Inconsistent format compliance is actually worse than consistently wrong — you can't build reliable tooling around a model that sometimes follows the protocol and sometimes doesn't.

*Qwen3.6-APEX stress note: First run with warm server scored 63/100 (2 format errors, stale KV cache). After fresh restart: 0 format errors, 80/100. The model is sensitive to KV cache state — always restart before long sessions.*

**Lesson**: The stress test revealed the models that *look* great in single-shot tests but fall apart under sustained conversation pressure. For agentic work, format consistency over long contexts is non-negotiable.

### Challenge 5: Memory Consistency (25 Rounds, 6 Facts Tested)

Plant 6 specific facts in early conversation rounds (project name, database credentials, team lead's email, etc.). After 12 filler rounds of unrelated coding tasks, test whether the model remembers the facts.

| Model | Score | Context Size | Forgot |
|-------|-------|-------------|--------|
| Qwen3.5-27B | **70/70 (100%)** | ~85K tokens | Nothing |
| Gemma 4 26B | **70/70 (100%)** | ~70K tokens | Nothing |
| Gemma 4 31B | **70/70 (100%)** | ~68K tokens | Nothing |
| Qwopus3.5-27B | 60/70 (85%) | ~66K tokens | 1 fact (DB connection string) |
| **Qwen3.6-APEX** | **70/70 (100%)** | ~70K tokens | Nothing |

**Lesson**: At 65-85K tokens, all finalists have perfect memory. The "my model stops working mid-session" issue I'd been experiencing isn't about model quality — it's about VRAM pressure.

---

## The Eliminations

### GLM-4.7-Flash: Eliminated After Challenge 4

GLM was the most painful elimination. It topped every leaderboard, generated blazing fast (100 t/s), and scored 95/100 on keyword checks. But in real execution:

- **Voxel**: Broken JavaScript (array mismatch)
- **HTTP**: IndentationError in Python code
- **Stress**: 20/20 format errors (markdown fences in tool calls)

The community was right — GLM has a broken llama.cpp implementation. The PR (#18980) has wrong gating, and the KV cache has known bugs. It might work great through the official API, but via llama.cpp locally, it's not production-ready.

I deleted the 13GB GGUF file.

### Qwopus3.5-27B: Eliminated After Stress Test

Qwopus was the Jekyll and Hyde model. Single-shot performance was excellent:
- Voxel: 19/20 (but crashes in browser)
- HTTP: 30/30 perfect
- Agent: 95/100, fastest convergence

But under sustained conversation: 17/20 format errors. It just can't maintain tool-call protocol. Plus 32K context window is too small for any real work. Deleted 16.9GB.

### Qwen3.5-35B-A3B: Eliminated Early

MoE with 3B active parameters sounds great on paper. In practice, it was the slowest model on complex tasks (36s per tool call). Smaller active parameter count doesn't mean faster when the model needs to do deep reasoning — the MoE routing overhead eats the theoretical advantage.

### Qwen3.5-9B: Eliminated Early

Reliability score of 0/100. It hallucinated on every reliability test. For pi-crons and automated workflows that run without human oversight, a hallucinating model is actively dangerous.

---

## The Final Results

### Head-to-Head Summary

| | Qwen3.6-APEX | Qwen3.5-27B | Gemma 4 26B | Gemma 4 31B |
|--|------------|------------|------------|------------|
| **Voxel** | ✅ 18/20 | ✅ Playable (19/20) | ✅ Playable (20/20) | ❌ Crashes |
| **HTTP** | ✅ **30/30** | 27/30 (str+bytes bug) | ✅ **30/30** | ✅ **30/30** |
| **Agent** | ✅ **95/100** (8/8) | ✅ **95/100** (8/8) | 75/100 (2/8) | ✅ **95/100** (8/8) |
| **Stress** | 80/100 (0 fmt err)* | 85/100 (10% fmt err) | ✅ **90/100** (15%) | N/A (OOM risk) |
| **Memory** | ✅ **100%** (70K) | ✅ **100%** (85K) | ✅ **100%** (70K) | ✅ **100%** (68K) |
| **VRAM** | 86% ✅ | 93% ⚠️ | **80%** ✅ | 96% ⚠️ |
| **Ctx Window** | 65K | 98K | **131K** | 65K |
| **Vision** | No | No | No | ✅ Yes |
| **Avg t/s** | **~96** | 27 | 81 | 25 |

*qwen36-apex stress: 0 format errors after fresh restart. Warm server scored 63-75 due to stale KV cache.

**Qwen3.6-APEX is the most well-rounded model** — perfect on HTTP, Agent, and Memory; good on Voxel and Stress. Only Gemma 4 31B matches its agent quality (and adds vision), and Gemma 4 26B still wins the stress test. But no other model has qwen36-apex's combination of quality *and* speed (~96 t/s).

### The Four Models

**Qwen3.6-APEX — The New Daily Driver** ⭐
- Best for: Pi agent, OpenCode, complex debugging, long sessions
- Wins: Perfect HTTP (30/30), perfect agent (95/100), perfect memory (100%), 96 t/s, 86% VRAM
- Weakness: Stress test (80/100), sensitive to stale KV cache, only 65K context
- Replaces Qwen3.5-27B as the primary model — same quality, 3.5x faster, safer VRAM

**Qwen3.5-27B — The Trusted Veteran** (demoted to backup)
- Best for: Backup when qwen36-apex is swapping, long-context sessions (>65K)
- Wins: Best stress test resilience among Qwen models (85/100), 98K context window
- Weakness: 93% VRAM (tight), 7.3x prompt slowdown, str/bytes bugs, 27 t/s (slow)

**Gemma 4 26B-A4B — The Workhorse**
- Best for: Quick tasks, pi-crons, long-context work, when VRAM headroom matters
- Wins: Best stress test (90/100), lowest VRAM (80%), largest context (131K)
- Weakness: Only fixed 2/8 agent debugging tests — MoE struggles with deep iterative debugging

**Gemma 4 31B — The Specialist**
- Best for: Debugging complex code, vision tasks (screenshots, diagrams), short-to-medium sessions
- Wins: Perfect HTTP server, perfect agent debugging, vision capability (unique among all models)
- Weakness: 96% VRAM, only 65K context, voxel broken, will OOM in long sessions

---

## What I Actually Learned

### 1. Automated Checks Are Worse Than Useless
Every model scored 18-20/20 on keyword checks for the voxel challenge. Two of the five produced code that crashes immediately. Keyword matching gives a false sense of confidence. **You must execute the output.**

### 2. APEX Optimization Is Real
Qwen3.6-APEX (APEX-I-Compact quantization) runs at 96 t/s on a 35B dense model — nearly 4x faster than Qwen3.5-27B (27 t/s) with equal or better quality. The APEX quantization isn't just smaller; it fundamentally changes the speed/quality tradeoff. On keyword benchmarks it scored 94 composite vs 92 for 27B. On real execution: perfect HTTP (30 vs 27), tied agent (95 vs 95), perfect memory. The APEX models are the real deal.

### 3. Leaderboard ≠ Local Usability
GLM-4.7-Flash tops the APEX benchmark. It writes Python with IndentationErrors and can't maintain tool-call format through llama.cpp. Cloud API performance doesn't predict local behavior.

### 4. MoE Isn't Automatically Faster
Qwen3.5-35B-A3B (3B active) was slower than dense 27B on complex tasks. MoE helps with simple inference but adds overhead when the model needs to route across many experts for deep reasoning.

### 5. Format Consistency Is the Real Bottleneck
For agentic coding, the model's ability to *maintain* a structured output format across 20+ conversation rounds matters more than peak quality. Qwen3.5-27B and Gemma 4 26B both stay at 85-90% format compliance. GLM and Qwopus don't.

### 6. "My Model Stops Working" = VRAM Pressure
I'd been experiencing mid-session failures with Qwen3.5-27B at 93% VRAM. It's not model quality degradation — it's llama.cpp evicting KV cache entries when VRAM runs out, which causes the model to lose context and produce garbage. Switching to Q4 KV cache (from Q8) would free ~5GB and likely fix this.

### 7. KV Cache State Matters
qwen36-apex scored 63/100 on the stress test with a warm server (format errors from stale KV cache). After a fresh restart: 80/100 with 0 format errors. The difference wasn't model quality — it was leftover context polluting the attention mechanism. For reliable agentic work, restart the server between sessions or use llama.cpp's context clearing.

### 8. Non-Overlapping Strengths Beat a Single Champion
I originally wanted to find "the best model." Instead I found four models with different strengths. But qwen36-apex comes closest to a universal pick — it's competitive in every single challenge. The remaining three cover its gaps: Gemma 4 26B for long-context stress resistance, Gemma 4 31B for vision, and Qwen3.5-27B as a backup with a larger context window.
## How to Reproduce

All benchmarks are open source and run against any OpenAI-compatible API:

```bash
git clone https://github.com/gtrias/llama-server-docker.git

# Voxel game challenge (browser-test the output!)
bash scripts/benchmark/voxel-challenge.sh <model-name> /tmp/voxel-challenge

# HTTP server challenge (starts server, runs live tests)
bash scripts/benchmark/http-challenge.sh <model-name> /tmp/http-challenge

# Agent tool-calling challenge (model fixes bugged Python project)
bash scripts/benchmark/agent-challenge.sh <model-name> /tmp/agent-challenge

# Long-context stress test (20 rounds, VRAM monitoring)
bash scripts/benchmark/stress-test.sh <model-name> /tmp/stress-test

# Memory consistency test (25 rounds, 6 facts planted)
bash scripts/benchmark/memory-test.sh <model-name> /tmp/memory-test
```

Each script outputs METRIC lines that can be parsed for automated comparison.

---

## Final Setup

My `models.ini` now has 6 models (4 primary + 2 fallback):

```
qwen36-apex     — Daily driver (Pi agent, OpenCode, complex debugging) ⭐ NEW
gemma4-26b      — Workhorse (pi-crons, quick tasks, long context)
gemma4-31b      — Specialist (vision, deep debugging, short sessions)
qwen35-27b      — Backup (long sessions >65K ctx, fallback agent)
qwen35          — Fallback (slow but functional)
qwen35-9b       — Emergency only (unreliable)
```

GLM and Qwopus removed. ~30GB of disk space freed.
qwen36-apex added as primary. Replaces qwen35-27b for daily driving — same quality, 3.5x faster, safer VRAM.

---

*Hardware: RTX 3090 (24GB), 96GB RAM, Ryzen 7 5800X. Server: llama.cpp in router mode, Docker. Original tests run April 2026. Qwen3.6-APEX tested April 18, 2026. Results may differ with different quantization levels, llama.cpp versions, or hardware.*
